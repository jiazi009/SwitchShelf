#include "CDBIBridge.h"
#include "libmtp_abi.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* One process-wide gate, including multiple DeviceService instances. Loaded code stays
   resident: libmtp owns a process-global USB context with no public shutdown function. */
static atomic_flag gate = ATOMIC_FLAG_INIT;
static struct {
    void *handle;
    void (*init)(void);
    void (*debug)(int);
    ss_abi_device *(*open)(ss_abi_raw_device *);
    void (*release)(ss_abi_device *);
    int (*storage)(ss_abi_device *, int);
    int (*children)(ss_abi_device *, uint32_t, uint32_t, uint32_t **);
    ss_abi_file *(*metadata)(ss_abi_device *, uint32_t);
    void (*destroy_file)(ss_abi_file *);
    ss_abi_error *(*errors)(ss_abi_device *);
    void (*clear_errors)(ss_abi_device *);
    int (*usb_init)(ss_usb_context **);
    void (*usb_exit)(ss_usb_context *);
    ssize_t (*usb_list)(ss_usb_context *, ss_usb_device ***);
    void (*usb_free_list)(ss_usb_device **, int);
    int (*usb_descriptor)(ss_usb_device *, ss_usb_descriptor *);
    uint8_t (*usb_bus)(ss_usb_device *);
    uint8_t (*usb_address)(ss_usb_device *);
} api;
struct ss_mtp_session { ss_abi_device *device; };

static int fail(ss_mtp_error *e, int code, int native) {
    if (e) { e->code = code; e->native_code = native; }
    return code;
}
static int load_runtime(const char *override, ss_mtp_error *e) {
    if (api.handle) return SS_MTP_OK;
    const char *paths[] = {
        "@executable_path/../Frameworks/libmtp.dylib",
        "@executable_path/../Frameworks/libmtp.9.dylib",
        "/opt/homebrew/lib/libmtp.9.dylib", "/usr/local/lib/libmtp.9.dylib", NULL
    };
    void *handle = NULL;
    if (override && *override) handle = dlopen(override, RTLD_NOW | RTLD_LOCAL);
    else for (size_t i = 0; paths[i] && !handle; ++i) handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
    if (!handle) return fail(e, SS_MTP_RUNTIME_MISSING, 0);
#define LOAD(field, symbol) do { \
    *(void **)(&api.field) = dlsym(handle, symbol); \
    if (!api.field) { dlclose(handle); memset(&api, 0, sizeof(api)); \
        return fail(e, SS_MTP_RUNTIME_INCOMPATIBLE, 0); } \
} while (0)
    LOAD(init, "LIBMTP_Init");
    LOAD(debug, "LIBMTP_Set_Debug");
    LOAD(open, "LIBMTP_Open_Raw_Device_Uncached");
    LOAD(release, "LIBMTP_Release_Device");
    LOAD(storage, "LIBMTP_Get_Storage");
    LOAD(children, "LIBMTP_Get_Children");
    LOAD(metadata, "LIBMTP_Get_Filemetadata");
    LOAD(destroy_file, "LIBMTP_destroy_file_t");
    LOAD(errors, "LIBMTP_Get_Errorstack");
    LOAD(clear_errors, "LIBMTP_Clear_Errorstack");
    /* dlsym searches libmtp's linked dependencies. Descriptor enumeration uses cached
       libusb descriptors only, avoiding libmtp's probes/logs for unrelated USB devices. */
    LOAD(usb_init, "libusb_init");
    LOAD(usb_exit, "libusb_exit");
    LOAD(usb_list, "libusb_get_device_list");
    LOAD(usb_free_list, "libusb_free_device_list");
    LOAD(usb_descriptor, "libusb_get_device_descriptor");
    LOAD(usb_bus, "libusb_get_bus_number");
    LOAD(usb_address, "libusb_get_device_address");
#undef LOAD
    api.handle = handle;
    api.init();
    api.debug(0);
    return SS_MTP_OK;
}

static int stack_error(ss_mtp_session *s) {
    ss_abi_error *e = api.errors(s->device);
    if (!e) return 0;
    int number = e->errornumber;
    api.clear_errors(s->device);
    return number ? number : -1;
}

int ss_mtp_open(const char *override, ss_mtp_session **out, ss_mtp_error *e) {
    if (!out) return fail(e, SS_MTP_INVALID_METADATA, 0);
    *out = NULL;
    if (atomic_flag_test_and_set(&gate)) return fail(e, SS_MTP_BUSY, 0);
    int status = load_runtime(override, e);
    if (status) { atomic_flag_clear(&gate); return status; }
    ss_usb_context *context = NULL;
    ss_usb_device **devices = NULL;
    int result = api.usb_init(&context);
    if (result < 0) { atomic_flag_clear(&gate); return fail(e, SS_MTP_IO_FAILED, result); }
    ssize_t count = api.usb_list(context, &devices);
    if (count < 0) {
        api.usb_exit(context); atomic_flag_clear(&gate);
        return fail(e, SS_MTP_IO_FAILED, (int)count);
    }
    ss_abi_raw_device raw = {0};
    int targets = 0, descriptor_error = 0;
    for (ssize_t i = 0; i < count; ++i) {
        ss_usb_descriptor d = {0};
        result = api.usb_descriptor(devices[i], &d);
        if (result < 0) { descriptor_error = result; continue; }
        if (d.idVendor != 0x057e || d.idProduct != 0x201d) continue;
        ++targets;
        /* Official libmtp 1.1.23 device table: Nintendo 057e:201d, flags NONE.
           USB pair is only a candidate; successful storage traversal is required. */
        raw.device_entry.vendor_id = d.idVendor;
        raw.device_entry.product_id = d.idProduct;
        raw.bus_location = api.usb_bus(devices[i]);
        raw.devnum = api.usb_address(devices[i]);
    }
    api.usb_free_list(devices, 1);
    api.usb_exit(context);
    if (targets != 1 || descriptor_error) {
        atomic_flag_clear(&gate);
        return fail(e, descriptor_error ? SS_MTP_IO_FAILED :
                    targets == 0 ? SS_MTP_NO_DEVICE : SS_MTP_MULTIPLE_DEVICES, descriptor_error);
    }
    ss_mtp_session *s = calloc(1, sizeof(*s));
    if (!s) { atomic_flag_clear(&gate); return fail(e, SS_MTP_MEMORY, 0); }
    s->device = api.open(&raw);
    if (!s->device) {
        free(s); atomic_flag_clear(&gate);
        return fail(e, SS_MTP_OPEN_FAILED, 0);
    }
    /* Do not erase open-time errors: a failed storage query must not look empty. */
    *out = s;
    return fail(e, SS_MTP_OK, 0);
}

void ss_mtp_close(ss_mtp_session *s) {
    if (!s) return;
    api.release(s->device);
    free(s);
    atomic_flag_clear(&gate);
}

int ss_mtp_get_storages(ss_mtp_session *s, ss_mtp_storage **out, size_t *count, ss_mtp_error *e) {
    *out = NULL; *count = 0;
    int native = stack_error(s);
    if (native) return fail(e, SS_MTP_IO_FAILED, native);
    int result = api.storage(s->device, 0);
    native = stack_error(s);
    if (result < 0 || native) return fail(e, SS_MTP_IO_FAILED, native ? native : result);
    size_t n = 0;
    for (ss_abi_storage *p = s->device->storage; p; p = p->next) {
        if (++n > 4096) return fail(e, SS_MTP_INVALID_METADATA, 0);
    }
    if (!n) return SS_MTP_OK;
    ss_mtp_storage *items = calloc(n, sizeof(*items));
    if (!items) return fail(e, SS_MTP_MEMORY, 0);
    size_t i = 0;
    for (ss_abi_storage *p = s->device->storage; p; p = p->next, ++i) {
        if (!p->StorageDescription || strnlen(p->StorageDescription, 4097) > 4096) {
            ss_mtp_free_storages(items, n); return fail(e, SS_MTP_INVALID_METADATA, 0);
        }
        items[i].id = p->id;
        items[i].name = strdup(p->StorageDescription);
        if (!items[i].name) { ss_mtp_free_storages(items, n); return fail(e, SS_MTP_MEMORY, 0); }
    }
    *out = items; *count = n;
    return fail(e, SS_MTP_OK, 0);
}
void ss_mtp_free_storages(ss_mtp_storage *items, size_t count) {
    if (items) for (size_t i = 0; i < count; ++i) free(items[i].name);
    free(items);
}
int ss_mtp_get_children(ss_mtp_session *s, uint32_t storage, uint32_t parent,
                        uint32_t **out, size_t *count, ss_mtp_error *e) {
    *out = NULL; *count = 0;
    int n = api.children(s->device, storage, parent, out);
    int native = stack_error(s);
    if (n < 0 || native || (n > 0 && !*out)) {
        free(*out); *out = NULL;
        return fail(e, SS_MTP_IO_FAILED, native ? native : n);
    }
    *count = (size_t)n;
    return fail(e, SS_MTP_OK, 0);
}
int ss_mtp_get_object(ss_mtp_session *s, uint32_t id, ss_mtp_object *out, ss_mtp_error *e) {
    memset(out, 0, sizeof(*out));
    ss_abi_file *file = api.metadata(s->device, id);
    int native = stack_error(s);
    if (!file || native) {
        if (file) api.destroy_file(file);
        return fail(e, SS_MTP_IO_FAILED, native);
    }
    if (!file->filename || strnlen(file->filename, 4097) > 4096) {
        api.destroy_file(file); return fail(e, SS_MTP_INVALID_METADATA, 0);
    }
    out->id = file->item_id; out->parent_id = file->parent_id; out->storage_id = file->storage_id;
    out->byte_count = file->filesize; out->is_folder = file->filetype == 0;
    out->name = strdup(file->filename);
    api.destroy_file(file);
    if (!out->name) return fail(e, SS_MTP_MEMORY, 0);
    return fail(e, SS_MTP_OK, 0);
}
void ss_mtp_clear_object(ss_mtp_object *object) { free(object->name); memset(object, 0, sizeof(*object)); }
void ss_mtp_free(void *allocation) { free(allocation); }
