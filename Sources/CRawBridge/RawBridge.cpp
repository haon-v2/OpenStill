#include "CRawBridge.h"
#include "libraw/libraw.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <new>

static int fail(int code, char *error, size_t capacity) {
    if (error && capacity) snprintf(error, capacity, "%s", libraw_strerror(code));
    return code;
}
static void metadata(LibRaw &raw, OSRawImage *out) {
    snprintf(out->make, sizeof(out->make), "%s", raw.imgdata.idata.make);
    snprintf(out->model, sizeof(out->model), "%s", raw.imgdata.idata.model);
    for (int i=0; i<4; ++i) out->camera_white_balance[i] = raw.imgdata.color.cam_mul[i];
}
int os_raw_probe(const char *path, OSRawImage *out, char *error, size_t capacity) {
    if (!path || !out) return fail(LIBRAW_UNSPECIFIED_ERROR, error, capacity);
    memset(out, 0, sizeof(*out));
    std::unique_ptr<LibRaw> owned(new (std::nothrow) LibRaw());
    if (!owned) return fail(LIBRAW_UNSUFFICIENT_MEMORY, error, capacity);
    LibRaw &raw = *owned;
    int status = raw.open_file(path);
    if (status) return fail(status, error, capacity);
    metadata(raw, out);
    out->width = raw.imgdata.sizes.width; out->height = raw.imgdata.sizes.height;
    return 0;
}
int os_raw_decode(const char *path, const float *wb, int highlights, double temperature, double tint, int half_size, OSRawImage *out, char *error, size_t capacity) {
    if (!path || !out) return fail(LIBRAW_UNSPECIFIED_ERROR, error, capacity);
    memset(out, 0, sizeof(*out));
    std::unique_ptr<LibRaw> owned(new (std::nothrow) LibRaw());
    if (!owned) return fail(LIBRAW_UNSUFFICIENT_MEMORY, error, capacity);
    LibRaw &raw = *owned;
    int status = raw.open_file(path);
    if (status) return fail(status, error, capacity);
    metadata(raw, out);
    auto &p = raw.imgdata.params;
    p.half_size = half_size ? 1 : 0;
    p.output_bps = 16; p.output_color = 8; p.gamm[0] = p.gamm[1] = 1;
    p.use_camera_wb = 1; p.use_camera_matrix = 1; p.no_auto_bright = 1;
    p.highlight = std::clamp(highlights, 0, 9);
    if (wb || temperature != 6500 || tint != 0) {
        p.use_camera_wb = 0;
        for (int i=0; i<4; ++i) p.user_mul[i] = wb ? wb[i] : raw.imgdata.color.cam_mul[i];
        if (p.user_mul[3] <= 0) p.user_mul[3] = p.user_mul[1];
        // Relative chromatic adaptation about the as-shot camera white balance.
        double warmth = std::clamp(temperature,2500.0,10000.0)/6500.0;
        p.user_mul[0] *= warmth; p.user_mul[2] /= warmth;
        double green = pow(2.0, -std::clamp(tint,-100.0,100.0)/200.0);
        p.user_mul[1] *= green; p.user_mul[3] *= green;
    }
    status = raw.unpack();
    if (status) return fail(status, error, capacity);
    // Count sensor saturation before demosaicing/WB. Unsupported layouts report -1.
    out->sensor_clipped_fraction = -1;
    if (raw.imgdata.rawdata.raw_image && raw.imgdata.color.maximum > 0) {
        uint64_t count = 0, clipped = 0;
        const auto &s = raw.imgdata.sizes;
        const unsigned stride = s.raw_pitch / sizeof(uint16_t);
        if (stride >= s.raw_width) {
            for (unsigned y=s.top_margin; y<unsigned(s.top_margin)+s.height && y<s.raw_height; ++y)
                for (unsigned x=s.left_margin; x<unsigned(s.left_margin)+s.width && x<s.raw_width; ++x) {
                    ++count;
                    if (raw.imgdata.rawdata.raw_image[size_t(y)*stride+x] >= raw.imgdata.color.maximum) ++clipped;
                }
            if (count) out->sensor_clipped_fraction = double(clipped)/double(count);
        }
    }
    status = raw.dcraw_process();
    if (status) return fail(status, error, capacity);
    libraw_processed_image_t *image = raw.dcraw_make_mem_image(&status);
    if (!image) return fail(status ? status : LIBRAW_UNSPECIFIED_ERROR, error, capacity);
    if (image->type != LIBRAW_IMAGE_BITMAP || image->colors != 3 || image->bits != 16) {
        LibRaw::dcraw_clear_mem(image); return fail(LIBRAW_NOT_IMPLEMENTED, error, capacity);
    }
    const size_t bytes = size_t(image->width)*image->height*3*sizeof(uint16_t);
    if (bytes != image->data_size) {
        LibRaw::dcraw_clear_mem(image); return fail(LIBRAW_DATA_ERROR, error, capacity);
    }
    out->pixels = static_cast<uint16_t *>(malloc(bytes));
    if (!out->pixels) { LibRaw::dcraw_clear_mem(image); return fail(LIBRAW_UNSUFFICIENT_MEMORY, error, capacity); }
    memcpy(out->pixels, image->data, bytes); out->width = image->width; out->height = image->height;
    LibRaw::dcraw_clear_mem(image); return 0;
}
void os_raw_release(OSRawImage *image) { if (image) { free(image->pixels); image->pixels = nullptr; } }
const char *os_raw_version(void) { return LibRaw::version(); }
