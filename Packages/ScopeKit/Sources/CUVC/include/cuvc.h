#ifndef CUVC_H
#define CUVC_H

#include <stdint.h>

/// Minimal access to a USB Video Class camera's controls (exposure, gain, white balance...) via IOKit.
/// Control requests go over the default pipe, so this works alongside macOS streaming the video.
typedef struct cuvc_device cuvc_device;

enum {
    CUVC_SET_CUR = 0x01,
    CUVC_GET_CUR = 0x81,
    CUVC_GET_MIN = 0x82,
    CUVC_GET_MAX = 0x83,
    CUVC_GET_RES = 0x84,
    CUVC_GET_INFO = 0x86,
    CUVC_GET_DEF = 0x87,
};

/// Opens the camera with this vendor/product ID; `location` picks one of several identical cameras (0 = any).
/// Returns NULL if it isn't found or has no video-control interface.
cuvc_device *cuvc_open(uint16_t vendor, uint16_t product, uint32_t location);
void cuvc_close(cuvc_device *device);

/// IDs of the camera terminal (exposure controls) and processing unit (gain, white balance...); 0 if absent.
uint8_t cuvc_camera_terminal(const cuvc_device *device);
uint8_t cuvc_processing_unit(const cuvc_device *device);

/// Sends one class-specific request to `unit`'s `selector`. Returns 0 on success, else an IOReturn code.
int32_t cuvc_request(cuvc_device *device, uint8_t request, uint8_t unit, uint8_t selector, void *data, uint16_t length);

#endif
