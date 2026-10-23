#ifndef SWITCHSHELF_BACKEND_USB_H
#define SWITCHSHELF_BACKEND_USB_H

/* Bootstrap only. The USB worker owns the native adapter implementation.
   This initial scaffold cannot open or write any device. */
int ss_backend_usb_unavailable(void);

#endif
