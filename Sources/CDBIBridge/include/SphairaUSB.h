#ifndef SS_SPHAIRA_USB_H
#define SS_SPHAIRA_USB_H
#include <stddef.h>
#include <stdint.h>
/* Explicit-open USB transport. Isolated installation or read-only probe workers
   may call it only after acquiring DeviceLease. Never detach drivers/reset/configure. */
typedef struct ss_sphaira_usb ss_sphaira_usb;
int ss_sphaira_usb_open(ss_sphaira_usb **out, uint16_t *packet_size, int *native_error);
int ss_sphaira_usb_write(ss_sphaira_usb *, const uint8_t *, size_t, int *native_error);
int ss_sphaira_usb_read(ss_sphaira_usb *, uint8_t *, size_t, size_t *received, int *native_error);
int ss_sphaira_usb_close(ss_sphaira_usb *);
#endif
