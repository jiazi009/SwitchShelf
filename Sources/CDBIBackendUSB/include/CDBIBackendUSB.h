#ifndef SWITCHSHELF_BACKEND_USB_H
#define SWITCHSHELF_BACKEND_USB_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Opaque session. Calls are serialized by the caller. No function runs on import.
   open is explicit; a failed close fences the process lease until process exit. */
typedef struct ss_usb_session ss_usb_session;
enum { SS_USB_OK=0, SS_USB_INVALID=1, SS_USB_BUSY=2, SS_USB_UNAVAILABLE=3,
       SS_USB_AMBIGUOUS=4, SS_USB_DESCRIPTOR=5, SS_USB_TIMEOUT=6,
       SS_USB_DISCONNECTED=7, SS_USB_IO=8, SS_USB_RELEASE=9 };
/* Shared lease path must also be used by the MTP owner before its session opens.
   No serial strings or per-device identifiers are exposed. */
int ss_usb_open(ss_usb_session **out, int32_t *native_code);
int ss_usb_read(ss_usb_session *session, void *buffer, uint32_t *length,
                uint32_t timeout_ms, int32_t *native_code);
int ss_usb_write(ss_usb_session *session, const void *buffer, uint32_t length,
                 uint32_t timeout_ms, int32_t *native_code);
int ss_usb_close(ss_usb_session *session, int32_t *native_code);
/* Pure descriptor predicate, used without hardware by tests. */
int ss_usb_is_backend(uint16_t vendor, uint16_t product, uint8_t interface_class,
                      uint8_t alternate, uint8_t endpoints,
                      uint8_t out_address, uint8_t out_type,
                      uint8_t in_address, uint8_t in_type);
#ifdef __cplusplus
}
#endif
#endif
