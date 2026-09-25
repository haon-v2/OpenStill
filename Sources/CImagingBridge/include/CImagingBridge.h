#ifndef OPENSTILL_IMAGING_H
#define OPENSTILL_IMAGING_H
#ifdef __cplusplus
extern "C" {
#endif
int os_proof_profile_valid(const void *bytes,unsigned length);
int os_proof_rgba(const void *inputICC,unsigned inputLength,const void *displayICC,unsigned displayLength,const void *proofICC,unsigned proofLength,int intent,int paper,int gamut,float *pixels,unsigned count);
typedef void *OSLensDatabase;
OSLensDatabase os_lens_open(const char *directory);
void os_lens_close(OSLensDatabase db);
int os_lens_count(OSLensDatabase db);
const char *os_lens_name(OSLensDatabase db, int index);
const char *os_lens_maker(OSLensDatabase db, int index);
float os_lens_crop(OSLensDatabase db, int index);
float os_camera_crop(OSLensDatabase db, const char *maker, const char *model);
int os_lens_capabilities(OSLensDatabase db, int index);
// Maps use normalized bottom-left coordinates. Four contiguous RGBA float grids:
// red coordinates, green coordinates, blue coordinates, RGB vignette gain.
int os_lens_maps(OSLensDatabase db, int index, float crop, int width, int height,
                 float focal, float aperture, float distance, int flags,
                 int gridWidth, int gridHeight, float *maps);
#ifdef __cplusplus
}
#endif
#endif
