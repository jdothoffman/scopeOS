#include "cuvc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

struct cuvc_device {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface **interface;
    uint8_t interface_number;
    uint8_t camera_terminal;
    uint8_t processing_unit;
};

static void set_int(CFMutableDictionaryRef dict, CFStringRef key, int value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFDictionarySetValue(dict, key, number);
    CFRelease(number);
}

static io_service_t find_device(uint16_t vendor, uint16_t product, uint32_t location) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return 0;
    set_int(match, CFSTR("idVendor"), vendor);
    set_int(match, CFSTR("idProduct"), product);
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) return 0;

    io_service_t service, found = 0;
    while ((service = IOIteratorNext(iterator))) {
        uint32_t this_location = 0;
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("locationID"), kCFAllocatorDefault, 0);
        if (value) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &this_location);
            CFRelease(value);
        }
        if (!found && (location == 0 || this_location == location)) {
            found = service;
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    return found;
}

static void *plugin_interface(io_service_t service, CFUUIDRef type, CFUUIDRef interface_id) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    void *result = NULL;
    if (IOCreatePlugInInterfaceForService(service, type, kIOCFPlugInInterfaceID, &plugin, &score) == kIOReturnSuccess && plugin) {
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(interface_id), &result);
        IODestroyPlugInInterface(plugin);
    }
    return result;
}

/// Finds the video-control interface number and the camera terminal / processing unit IDs.
static void parse_descriptors(cuvc_device *device) {
    IOUSBConfigurationDescriptorPtr config = NULL;
    if ((*device->device)->GetConfigurationDescriptorPtr(device->device, 0, &config) != kIOReturnSuccess || !config) return;
    const uint8_t *bytes = (const uint8_t *)config;
    uint16_t total = USBToHostWord(config->wTotalLength);
    int in_video_control = 0;
    for (uint16_t i = 0; i + 2 <= total;) {
        uint8_t length = bytes[i], type = bytes[i + 1];
        if (length < 2 || i + length > total) break;
        if (type == kUSBInterfaceDesc && length >= 9) {
            in_video_control = bytes[i + 5] == 14 && bytes[i + 6] == 1; // video class, control subclass
            if (in_video_control) device->interface_number = bytes[i + 2];
        } else if (type == 0x24 && in_video_control && length >= 4) { // class-specific interface descriptor
            uint8_t subtype = bytes[i + 2];
            if (subtype == 0x02 && length >= 8) { // input terminal
                uint16_t terminal_type = bytes[i + 4] | (bytes[i + 5] << 8);
                if (terminal_type == 0x0201) device->camera_terminal = bytes[i + 3];
            } else if (subtype == 0x05) { // processing unit
                device->processing_unit = bytes[i + 3];
            }
        }
        i += length;
    }
}

cuvc_device *cuvc_open(uint16_t vendor, uint16_t product, uint32_t location) {
    io_service_t service = find_device(vendor, product, location);
    if (!service) return NULL;
    cuvc_device *device = calloc(1, sizeof(cuvc_device));
    device->device = plugin_interface(service, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID);
    IOObjectRelease(service);
    if (!device->device) {
        free(device);
        return NULL;
    }
    parse_descriptors(device);

    IOUSBFindInterfaceRequest request = {
        .bInterfaceClass = 14,
        .bInterfaceSubClass = 1,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare,
    };
    io_iterator_t iterator;
    if ((*device->device)->CreateInterfaceIterator(device->device, &request, &iterator) == kIOReturnSuccess) {
        io_service_t interface = IOIteratorNext(iterator);
        if (interface) {
            device->interface = plugin_interface(interface, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID);
            IOObjectRelease(interface);
        }
        IOObjectRelease(iterator);
    }
    if (!device->camera_terminal && !device->processing_unit) {
        cuvc_close(device);
        return NULL;
    }
    return device;
}

void cuvc_close(cuvc_device *device) {
    if (!device) return;
    if (device->interface) (*device->interface)->Release(device->interface);
    if (device->device) (*device->device)->Release(device->device);
    free(device);
}

uint8_t cuvc_camera_terminal(const cuvc_device *device) { return device->camera_terminal; }
uint8_t cuvc_processing_unit(const cuvc_device *device) { return device->processing_unit; }

int32_t cuvc_request(cuvc_device *device, uint8_t request, uint8_t unit, uint8_t selector, void *data, uint16_t length) {
    uint8_t direction = request & 0x80 ? kUSBIn : kUSBOut;
    IOUSBDevRequest r = {
        .bmRequestType = USBmakebmRequestType(direction, kUSBClass, kUSBInterface),
        .bRequest = request,
        .wValue = (uint16_t)(selector << 8),
        .wIndex = (uint16_t)((unit << 8) | device->interface_number),
        .wLength = length,
        .pData = data,
    };
    IOReturn result = kIOReturnNotOpen;
    // Control requests on the default pipe normally work without opening the interface (macOS's video driver
    // owns it while streaming); fall back to opening it, then to a device-level request.
    if (device->interface) {
        result = (*device->interface)->ControlRequest(device->interface, 0, &r);
        if (result != kIOReturnSuccess && (*device->interface)->USBInterfaceOpen(device->interface) == kIOReturnSuccess) {
            r.wLenDone = 0;
            result = (*device->interface)->ControlRequest(device->interface, 0, &r);
            (*device->interface)->USBInterfaceClose(device->interface);
        }
    }
    if (result != kIOReturnSuccess && device->device) {
        r.wLenDone = 0;
        result = (*device->device)->DeviceRequest(device->device, &r);
    }
    return result;
}
