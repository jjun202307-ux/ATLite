#ifndef AT_CAPTURE_VALIDATION_H
#define AT_CAPTURE_VALIDATION_H
#include <stddef.h>
#include <stdint.h>
/* The renderer has no status return. Reject an untouched destination; black is valid.
 * This proves writes occurred, not that the pixels match the visible display. */
static inline int ATCaptureWasWritten(const uint8_t *pixels, size_t width,
                                     size_t height, size_t pitch) {
    if (!pixels || !width || !height || width > 8192 || height > 8192 ||
        pitch < width * 4 || pitch > width * 4 + 65536 || pitch > SIZE_MAX / height) return 0;
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width * 4; ++x)
            if (pixels[y * pitch + x] != 0xa5) return 1;
    return 0;
}
#endif
