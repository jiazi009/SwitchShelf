#include "CDBIBridge.h"
#include "libmtp_abi.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>

/* libusb 1.0 public descriptor ABI (layout only, no copied implementation).
   Compile with SS_VERIFY_SPHAIRA_USB_ABI against the installed official header. */
typedef struct {
    uint8_t bLength, bDescriptorType, bEndpointAddress, bmAttributes;
    uint16_t wMaxPacketSize;
    uint8_t bInterval, bRefresh, bSynchAddress;
    const unsigned char *extra; int extra_length;
} ss_endpoint;
typedef struct {
    uint8_t bLength, bDescriptorType, bInterfaceNumber, bAlternateSetting, bNumEndpoints;
    uint8_t bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, iInterface;
    const ss_endpoint *endpoint; const unsigned char *extra; int extra_length;
} ss_interface_descriptor;
typedef struct { const ss_interface_descriptor *altsetting; int num_altsetting; } ss_interface;
typedef struct {
    uint8_t bLength, bDescriptorType; uint16_t wTotalLength;
    uint8_t bNumInterfaces, bConfigurationValue, iConfiguration, bmAttributes, MaxPower;
    const ss_interface *interface; const unsigned char *extra; int extra_length;
} ss_config;
#ifdef SS_VERIFY_SPHAIRA_USB_ABI
#include <libusb.h>
#define CHECK(a,b,f) _Static_assert(sizeof(a)==sizeof(b), "USB ABI size"); \
    _Static_assert(offsetof(a,f)==offsetof(b,f), "USB ABI offset")
CHECK(ss_endpoint, struct libusb_endpoint_descriptor, extra);
CHECK(ss_interface_descriptor, struct libusb_interface_descriptor, endpoint);
CHECK(ss_interface, struct libusb_interface, num_altsetting);
CHECK(ss_config, struct libusb_config_descriptor, interface);
#undef CHECK
#endif

typedef struct ss_usb_handle ss_usb_handle;
struct ss_sphaira_usb {
    ss_usb_context *context; ss_usb_handle *handle;
    int interface_number; uint8_t input, output;
};
static atomic_flag upload_gate = ATOMIC_FLAG_INIT;
static struct {
    void *library;
    int (*init)(ss_usb_context **);
    void (*exit)(ss_usb_context *);
    ssize_t (*list)(ss_usb_context *, ss_usb_device ***);
    void (*free_list)(ss_usb_device **, int);
    int (*descriptor)(ss_usb_device *, ss_usb_descriptor *);
    int (*config)(ss_usb_device *, ss_config **);
    void (*free_config)(ss_config *);
    int (*open)(ss_usb_device *, ss_usb_handle **);
    void (*close)(ss_usb_handle *);
    int (*claim)(ss_usb_handle *, int);
    int (*release)(ss_usb_handle *, int);
    int (*bulk)(ss_usb_handle *, unsigned char, unsigned char *, int, int *, unsigned int);
} usb;
static int load_usb(void) {
    if (usb.library) return 0;
    const char *paths[] = {"@executable_path/../Frameworks/libusb-1.0.0.dylib",
        "/opt/homebrew/lib/libusb-1.0.0.dylib", "/usr/local/lib/libusb-1.0.0.dylib", NULL};
    void *library = NULL;
    for (int i = 0; paths[i] && !library; i++) library = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
    if (!library) return SS_MTP_RUNTIME_MISSING;
#define LOAD(field, name) do { *(void **)(&usb.field) = dlsym(library, name); \
    if (!usb.field) { dlclose(library); return SS_MTP_RUNTIME_INCOMPATIBLE; } } while (0)
    LOAD(init, "libusb_init"); LOAD(exit, "libusb_exit");
    LOAD(list, "libusb_get_device_list"); LOAD(free_list, "libusb_free_device_list");
    LOAD(descriptor, "libusb_get_device_descriptor"); LOAD(config, "libusb_get_active_config_descriptor");
    LOAD(free_config, "libusb_free_config_descriptor"); LOAD(open, "libusb_open");
    LOAD(close, "libusb_close"); LOAD(claim, "libusb_claim_interface");
    LOAD(release, "libusb_release_interface"); LOAD(bulk, "libusb_bulk_transfer");
#undef LOAD
    usb.library = library;
    return 0;
}
int ss_sphaira_usb_open(ss_sphaira_usb **out, uint16_t *packet_size, int *native_error) {
    if (!out || !packet_size || !native_error) return SS_MTP_INVALID_METADATA;
    *out = NULL; *packet_size = 0; *native_error = 0;
    if (atomic_flag_test_and_set(&upload_gate)) return SS_MTP_BUSY;
    int status = load_usb();
    if (status) { atomic_flag_clear(&upload_gate); return status; }
    ss_sphaira_usb *s = calloc(1, sizeof(*s));
    if (!s) { atomic_flag_clear(&upload_gate); return SS_MTP_MEMORY; }
    ss_usb_device **devices = NULL;
    ss_config *config = NULL;
    int claimed = 0;
    status = usb.init(&s->context);
    if (status < 0) goto failed;
    ssize_t count = usb.list(s->context, &devices);
    if (count < 0) { status = (int)count; goto failed; }
    ss_usb_device *target = NULL;
    int candidates = 0;
    for (ssize_t i = 0; i < count; i++) {
        ss_usb_descriptor d = {0};
        status = usb.descriptor(devices[i], &d);
        if (status < 0) goto failed;
        if (d.idVendor == 0x057e && d.idProduct == 0x201d) { target = devices[i]; candidates++; }
    }
    if (candidates != 1) { status = candidates ? SS_MTP_MULTIPLE_DEVICES : SS_MTP_NO_DEVICE; goto failed; }
    status = usb.config(target, &config);
    if (status < 0) goto failed;
    int matches = 0;
    if (!config || config->bNumInterfaces > 32 || !config->interface) { status = SS_MTP_INVALID_METADATA; goto failed; }
    for (int i = 0; i < config->bNumInterfaces; i++) {
        const ss_interface *iface = &config->interface[i];
        if (iface->num_altsetting < 0 || iface->num_altsetting > 32 || (iface->num_altsetting && !iface->altsetting)) { status = SS_MTP_INVALID_METADATA; goto failed; }
        for (int j = 0; j < iface->num_altsetting; j++) {
            const ss_interface_descriptor *d = &iface->altsetting[j];
            if (d->bInterfaceClass != 6 || d->bInterfaceSubClass != 1 || d->bInterfaceProtocol != 1 || d->bAlternateSetting != 0) continue;
            uint8_t input = 0, output = 0; uint16_t packet = 0; int inputs = 0, outputs = 0;
            if (d->bNumEndpoints > 16 || !d->endpoint) { status = SS_MTP_INVALID_METADATA; goto failed; }
            for (int k = 0; k < d->bNumEndpoints; k++) {
                const ss_endpoint *e = &d->endpoint[k];
                if ((e->bmAttributes & 3) != 2) continue;
                if ((e->bEndpointAddress & 0x0f) == 0) { status = SS_MTP_INVALID_METADATA; goto failed; }
                if (e->bEndpointAddress & 0x80) { input = e->bEndpointAddress; inputs++; }
                else { output = e->bEndpointAddress; packet = e->wMaxPacketSize & 0x7ff; outputs++; }
            }
            if (inputs == 1 && outputs == 1 && (packet == 64 || packet == 512 || packet == 1024)) {
                matches++; s->interface_number = d->bInterfaceNumber;
                s->input = input; s->output = output; *packet_size = packet;
            }
        }
    }
    if (matches != 1) { status = SS_MTP_INVALID_METADATA; goto failed; }
    status = usb.open(target, &s->handle);
    if (status < 0) goto failed;
    /* Deliberately no auto-detach, reset, configuration change or driver capture. */
    status = usb.claim(s->handle, s->interface_number);
    if (status < 0) goto failed;
    claimed = 1;
    usb.free_config(config); usb.free_list(devices, 1);
    *out = s;
    return SS_MTP_OK;
failed:
    *native_error = status;
    if (config) usb.free_config(config);
    if (devices) usb.free_list(devices, 1);
    if (s->handle) { if (claimed) usb.release(s->handle, s->interface_number); usb.close(s->handle); }
    if (s->context) usb.exit(s->context);
    free(s); atomic_flag_clear(&upload_gate); *packet_size = 0;
    return status > 0 ? status : SS_MTP_OPEN_FAILED;
}
int ss_sphaira_usb_write(ss_sphaira_usb *s, const uint8_t *bytes, size_t count, int *native_error) {
    if (!s || !native_error || (count && !bytes) || count > 4 * 1024 * 1024) return SS_MTP_INVALID_METADATA;
    int transferred = 0;
    int status = usb.bulk(s->handle, s->output, (unsigned char *)bytes, (int)count, &transferred, 20000);
    *native_error = status;
    return status == 0 && transferred == (int)count ? SS_MTP_OK : SS_MTP_IO_FAILED;
}
int ss_sphaira_usb_read(ss_sphaira_usb *s, uint8_t *bytes, size_t count, size_t *received, int *native_error) {
    if (!s || !bytes || !received || !native_error || count == 0 || count > 65536) return SS_MTP_INVALID_METADATA;
    *received = 0; int transferred = 0;
    int status = usb.bulk(s->handle, s->input, bytes, (int)count, &transferred, 20000);
    *native_error = status;
    if (status || transferred <= 0 || transferred > (int)count) return SS_MTP_IO_FAILED;
    *received = (size_t)transferred;
    return SS_MTP_OK;
}
int ss_sphaira_usb_close(ss_sphaira_usb *s) {
    if (!s) return SS_MTP_OK;
    int status = usb.release(s->handle, s->interface_number);
    usb.close(s->handle); usb.exit(s->context); free(s);
    /* A failed release fences this process; parent still verifies helper exit. */
    if (!status) atomic_flag_clear(&upload_gate);
    return status;
}
