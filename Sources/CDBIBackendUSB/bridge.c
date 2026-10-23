#include "CDBIBackendUSB.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdlib.h>

#define MAX_IO (1024u * 1024u)
#define MAX_TIMEOUT 60000u
struct ss_usb_session {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface190 **interface;
    uint8_t out_pipe, in_pipe;
};
static pthread_mutex_t process_lock = PTHREAD_MUTEX_INITIALIZER;
static int occupied = 0;
static void code(int32_t *out, IOReturn value) { if (out) *out = value; }
static int mapped(IOReturn kr) {
    if (kr == kIOReturnTimeout) return SS_USB_TIMEOUT;
    if (kr == kIOReturnNoDevice || kr == kIOReturnNotResponding || kr == kIOReturnOffline) return SS_USB_DISCONNECTED;
    if (kr == kIOReturnExclusiveAccess) return SS_USB_BUSY;
    return SS_USB_IO;
}
int ss_usb_is_backend(uint16_t vendor, uint16_t product, uint8_t cls,
                      uint8_t alt, uint8_t endpoints, uint8_t out_addr,
                      uint8_t out_type, uint8_t in_addr, uint8_t in_type) {
    return vendor == 0x057e && product == 0x3000 && cls == 0xff && alt == 0 &&
           endpoints == 2 && out_addr == 0x01 && in_addr == 0x81 &&
           out_type == kUSBBulk && in_type == kUSBBulk;
}
static int query(io_service_t service, CFUUIDRef type, CFUUIDRef iid, void **result, int32_t *native) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, type, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || !plugin) { code(native, kr); return mapped(kr); }
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(iid), result);
    (*plugin)->Release(plugin);
    if (hr != S_OK || !*result) { code(native, (IOReturn)hr); return SS_USB_IO; }
    return SS_USB_OK;
}
static int select_interface(struct ss_usb_session *s, int32_t *native) {
    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                     kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t iter = IO_OBJECT_NULL;
    IOReturn kr = (*s->device)->CreateInterfaceIterator(s->device, &req, &iter);
    if (kr != kIOReturnSuccess) { code(native, kr); return mapped(kr); }
    int count = 0, result = SS_USB_DESCRIPTOR;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        IOUSBInterfaceInterface190 **iface = NULL;
        int q = query(service, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID190,
                      (void **)&iface, native);
        IOObjectRelease(service);
        if (q != SS_USB_OK) { result = q; break; }
        UInt8 cls=0, alt=0, n=0, outp=0, inp=0;
        kr = (*iface)->GetInterfaceClass(iface, &cls);
        if (kr == kIOReturnSuccess) kr = (*iface)->GetAlternateSetting(iface, &alt);
        if (kr == kIOReturnSuccess) kr = (*iface)->GetNumEndpoints(iface, &n);
        if (kr != kIOReturnSuccess) { code(native, kr); result = mapped(kr); (*iface)->Release(iface); break; }
        if (n == 2 && cls == 0xff && alt == 0) {
            UInt16 packet=0; UInt8 interval=0;
            kr = (*iface)->GetEndpointProperties(iface, 0, 1, kUSBOut, &outp, &packet, &interval);
            if (kr == kIOReturnSuccess)
                kr = (*iface)->GetEndpointProperties(iface, 0, 1, kUSBIn, &inp, &packet, &interval);
        }
        if (ss_usb_is_backend(0x057e, 0x3000, cls, alt, n, 1, outp, 0x81, inp) && kr == kIOReturnSuccess) {
            ++count;
            if (count == 1) s->interface=iface;
            else (*iface)->Release(iface);
        } else (*iface)->Release(iface);
    }
    IOObjectRelease(iter);
    if (result != SS_USB_DESCRIPTOR) return result;
    if (count != 1) return count ? SS_USB_AMBIGUOUS : SS_USB_DESCRIPTOR;
    kr = (*s->interface)->USBInterfaceOpen(s->interface); /* never seize */
    if (kr != kIOReturnSuccess) { code(native, kr); return mapped(kr); }
    /* Pipes exist only after open. Confirm their actual mapping before any I/O. */
    unsigned seen=0;
    for (UInt8 p=1; p<=2; ++p) {
        UInt8 dir=0,num=0,type=0,iv=0; UInt16 packet=0;
        kr=(*s->interface)->GetPipeProperties(s->interface,p,&dir,&num,&type,&packet,&iv);
        if (kr!=kIOReturnSuccess) break;
        if (dir==kUSBOut && num==1 && type==kUSBBulk) { s->out_pipe=p; ++seen; }
        if (dir==kUSBIn && num==1 && type==kUSBBulk) { s->in_pipe=p; ++seen; }
    }
    if (kr!=kIOReturnSuccess || seen!=2) {
        code(native,kr);
        kr=(*s->interface)->USBInterfaceClose(s->interface);
        if (kr!=kIOReturnSuccess) { code(native,kr); return SS_USB_RELEASE; }
        return SS_USB_DESCRIPTOR;
    }
    return SS_USB_OK;
}
int ss_usb_open(ss_usb_session **out, int32_t *native) {
    if (!out) return SS_USB_INVALID;
    *out = NULL; code(native, 0);
    pthread_mutex_lock(&process_lock);
    if (occupied) { pthread_mutex_unlock(&process_lock); return SS_USB_BUSY; }
    occupied = 1;
    pthread_mutex_unlock(&process_lock);
    int result = SS_USB_UNAVAILABLE;
    struct ss_usb_session *s = calloc(1, sizeof(*s));
    if (!s) goto failure;
    /* Cross-process authority is the mandatory caller-supplied shared lease.
       This native process gate must not acquire a second flock on its path. */
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) goto failure;
    io_iterator_t iter = IO_OBJECT_NULL;
    IOReturn kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != kIOReturnSuccess) { code(native, kr); result=mapped(kr); goto failure; }
    io_service_t service, candidate = IO_OBJECT_NULL;
    unsigned matches=0;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBVendorID), kCFAllocatorDefault, 0);
        CFTypeRef p = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);
        int vid=0,pid=0;
        if (v && CFGetTypeID(v)==CFNumberGetTypeID()) CFNumberGetValue(v,kCFNumberIntType,&vid);
        if (p && CFGetTypeID(p)==CFNumberGetTypeID()) CFNumberGetValue(p,kCFNumberIntType,&pid);
        if (v) CFRelease(v); if (p) CFRelease(p);
        if (vid==0x057e && pid==0x3000) { ++matches; if (!candidate) candidate=service; else IOObjectRelease(service); }
        else IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    if (matches != 1) { if (candidate) IOObjectRelease(candidate); result=matches ? SS_USB_AMBIGUOUS : SS_USB_UNAVAILABLE; goto failure; }
    result=query(candidate, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID,
                 (void **)&s->device, native);
    IOObjectRelease(candidate);
    if (result != SS_USB_OK) goto failure;
    UInt16 vid=0,pid=0;
    kr=(*s->device)->GetDeviceVendor(s->device,&vid);
    if (kr==kIOReturnSuccess) kr=(*s->device)->GetDeviceProduct(s->device,&pid);
    if (kr!=kIOReturnSuccess || vid!=0x057e || pid!=0x3000) { code(native,kr); result=SS_USB_DESCRIPTOR; goto failure; }
    /* No device open or configuration change; interface open only after validating descriptors. */
    result=select_interface(s,native);
    if (result != SS_USB_OK) goto failure;
    *out=s;
    return SS_USB_OK;
failure:
    if (result == SS_USB_RELEASE) return result; /* uncertain interface claim: fence and leak */
    if (s) {
        if (s->interface) (*s->interface)->Release(s->interface);
        if (s->device) (*s->device)->Release(s->device);
        free(s);
    }
    pthread_mutex_lock(&process_lock); occupied=0; pthread_mutex_unlock(&process_lock);
    return result;
}
static int valid(ss_usb_session *s, const void *buf, uint32_t n, uint32_t timeout) {
    return s && s->interface && buf && n && n<=MAX_IO && timeout && timeout<=MAX_TIMEOUT;
}
int ss_usb_read(ss_usb_session *s, void *buf, uint32_t *length, uint32_t timeout, int32_t *native) {
    if (!length || !valid(s,buf,*length,timeout)) return SS_USB_INVALID;
    uint32_t requested=*length, n=requested; *length=0; code(native,0);
    IOReturn kr=(*s->interface)->ReadPipeTO(s->interface,s->in_pipe,buf,&n,timeout,timeout);
    if (kr!=kIOReturnSuccess) { code(native,kr); return mapped(kr); }
    if (n==0 || n>requested) return SS_USB_IO;
    *length=n; return SS_USB_OK;
}
int ss_usb_write(ss_usb_session *s, const void *buf, uint32_t length, uint32_t timeout, int32_t *native) {
    if (!valid(s,buf,length,timeout)) return SS_USB_INVALID;
    code(native,0);
    /* Synchronous WritePipeTO has no byte-count result. On success IOKit reports
       completion of the entire transfer; any failure is uncertain and never retried. */
    IOReturn kr=(*s->interface)->WritePipeTO(s->interface,s->out_pipe,(void *)buf,length,timeout,timeout);
    if (kr!=kIOReturnSuccess) { code(native,kr); return mapped(kr); }
    return SS_USB_OK;
}
int ss_usb_close(ss_usb_session *s, int32_t *native) {
    if (!s || !s->interface || !s->device) return SS_USB_INVALID;
    code(native,0);
    IOReturn kr=(*s->interface)->USBInterfaceClose(s->interface);
    if (kr!=kIOReturnSuccess) { code(native,kr); return SS_USB_RELEASE; } /* fence and leak deliberately */
    (*s->interface)->Release(s->interface);
    (*s->device)->Release(s->device);
    free(s);
    pthread_mutex_lock(&process_lock); occupied=0; pthread_mutex_unlock(&process_lock);
    return SS_USB_OK;
}
