#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint16_t *pixels;
    uint32_t width, height;
    double sensor_clipped_fraction;
    float camera_white_balance[4];
    char make[64], model[64];
} OSRawImage;
// RGB16, linear Rec.2020, oriented. Caller releases pixels with os_raw_release.
int os_raw_decode(const char *path, const float *white_balance, int highlights, double temperature, double tint, int half_size,
                  OSRawImage *output, char *error, size_t error_capacity);
int os_raw_probe(const char *path, OSRawImage *output, char *error, size_t error_capacity);
void os_raw_release(OSRawImage *image);
const char *os_raw_version(void);
#ifdef __cplusplus
}
#endif
