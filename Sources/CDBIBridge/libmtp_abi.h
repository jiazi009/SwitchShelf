#ifndef SS_LIBMTP_ABI_H
#define SS_LIBMTP_ABI_H
/* Minimal ABI declarations checked against official libmtp 1.1.23 (ABI 9) and
   libusb 1.0.30 headers. These are layouts/constants, not copied implementation.
   libmtp header: LGPL-2.0-or-later; distributed COPYING: LGPL-2.1.
   Upstream: https://github.com/libmtp/libmtp/tree/v1.1.23
   Compile bridge.c with SS_VERIFY_LIBMTP_ABI and official include paths to check. */
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

typedef struct {
    char *vendor; uint16_t vendor_id; char *product; uint16_t product_id; uint32_t device_flags;
} ss_abi_device_entry;
typedef struct {
    ss_abi_device_entry device_entry; uint32_t bus_location; uint8_t devnum;
} ss_abi_raw_device;
typedef struct ss_abi_storage {
    uint32_t id; uint16_t StorageType, FilesystemType, AccessCapability;
    uint64_t MaxCapacity, FreeSpaceInBytes, FreeSpaceInObjects;
    char *StorageDescription, *VolumeIdentifier;
    struct ss_abi_storage *next, *prev;
} ss_abi_storage;
typedef struct {
    uint8_t object_bitsize; void *params, *usbinfo; ss_abi_storage *storage;
    void *errorstack; uint8_t maximum_battery_level;
    uint32_t default_music_folder, default_playlist_folder, default_picture_folder;
    uint32_t default_video_folder, default_organizer_folder, default_zencast_folder;
    uint32_t default_album_folder, default_text_folder;
    void *cd, *extensions; int cached; void *next;
} ss_abi_device;
typedef struct ss_abi_file {
    uint32_t item_id, parent_id, storage_id; char *filename;
    uint64_t filesize; time_t modificationdate; int filetype; struct ss_abi_file *next;
} ss_abi_file;
typedef struct ss_abi_error {
    int errornumber; char *error_text; struct ss_abi_error *next;
} ss_abi_error;
typedef struct ss_usb_context ss_usb_context;
typedef struct ss_usb_device ss_usb_device;
typedef struct {
    uint8_t bLength, bDescriptorType; uint16_t bcdUSB;
    uint8_t bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize0;
    uint16_t idVendor, idProduct, bcdDevice;
    uint8_t iManufacturer, iProduct, iSerialNumber, bNumConfigurations;
} ss_usb_descriptor;

#ifdef SS_VERIFY_LIBMTP_ABI
#include <libmtp.h>
#include <libusb.h>
#define SS_SIZE(a,b) _Static_assert(sizeof(a) == sizeof(b), "ABI size: " #a)
#define SS_OFFSET(a,b,f) _Static_assert(offsetof(a,f) == offsetof(b,f), "ABI offset: " #a "." #f)
SS_SIZE(ss_abi_device_entry, LIBMTP_device_entry_t);
SS_OFFSET(ss_abi_device_entry, LIBMTP_device_entry_t, vendor_id);
SS_OFFSET(ss_abi_device_entry, LIBMTP_device_entry_t, product_id);
SS_OFFSET(ss_abi_device_entry, LIBMTP_device_entry_t, device_flags);
SS_SIZE(ss_abi_raw_device, LIBMTP_raw_device_t);
SS_OFFSET(ss_abi_raw_device, LIBMTP_raw_device_t, bus_location);
SS_OFFSET(ss_abi_raw_device, LIBMTP_raw_device_t, devnum);
SS_SIZE(ss_abi_storage, LIBMTP_devicestorage_t);
SS_OFFSET(ss_abi_storage, LIBMTP_devicestorage_t, StorageDescription);
SS_OFFSET(ss_abi_storage, LIBMTP_devicestorage_t, next);
SS_OFFSET(ss_abi_storage, LIBMTP_devicestorage_t, id);
SS_SIZE(ss_abi_device, LIBMTP_mtpdevice_t);
SS_OFFSET(ss_abi_device, LIBMTP_mtpdevice_t, storage);
SS_OFFSET(ss_abi_device, LIBMTP_mtpdevice_t, cached);
SS_OFFSET(ss_abi_device, LIBMTP_mtpdevice_t, next);
SS_SIZE(ss_abi_file, LIBMTP_file_t);
SS_OFFSET(ss_abi_file, LIBMTP_file_t, item_id);
SS_OFFSET(ss_abi_file, LIBMTP_file_t, parent_id);
SS_OFFSET(ss_abi_file, LIBMTP_file_t, storage_id);
SS_OFFSET(ss_abi_file, LIBMTP_file_t, filename);
SS_OFFSET(ss_abi_file, LIBMTP_file_t, filesize);
SS_OFFSET(ss_abi_file, LIBMTP_file_t, filetype);
SS_SIZE(ss_abi_error, LIBMTP_error_t);
SS_OFFSET(ss_abi_error, LIBMTP_error_t, errornumber);
SS_SIZE(ss_usb_descriptor, struct libusb_device_descriptor);
SS_OFFSET(ss_usb_descriptor, struct libusb_device_descriptor, idVendor);
SS_OFFSET(ss_usb_descriptor, struct libusb_device_descriptor, idProduct);
_Static_assert(LIBMTP_FILETYPE_FOLDER == 0, "folder enum ABI");
_Static_assert(LIBMTP_FILES_AND_FOLDERS_ROOT == UINT32_MAX, "root ABI");
#endif
#endif
