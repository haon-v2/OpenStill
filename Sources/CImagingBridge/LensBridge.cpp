#include "CImagingBridge.h"
#include <lensfun.h>
#include <algorithm>
#include <cmath>
#include <memory>
static const lfLens *lens_at(OSLensDatabase db, int index) {
    if (!db || index < 0) return nullptr;
    const auto lenses = lf_db_get_lenses(static_cast<lfDatabase *>(db));
    if (!lenses) return nullptr;
    for (int i=0;lenses[i];++i) if (i==index) return lenses[i];
    return nullptr;
}
OSLensDatabase os_lens_open(const char *directory) {
    auto db = lf_db_new();
    if (!lf_db_load_directory(db,directory)) { lf_db_destroy(db); return nullptr; }
    return db;
}
void os_lens_close(OSLensDatabase db) { if(db) lf_db_destroy(static_cast<lfDatabase *>(db)); }
int os_lens_count(OSLensDatabase db) {
    if (!db) return 0;
    auto lenses=lf_db_get_lenses(static_cast<lfDatabase *>(db));
    int n=0; if(lenses) while(lenses[n]) ++n; return n;
}
const char *os_lens_name(OSLensDatabase db,int i) { auto l=lens_at(db,i); return l ? l->Model : ""; }
const char *os_lens_maker(OSLensDatabase db,int i) { auto l=lens_at(db,i); return l ? l->Maker : ""; }
float os_lens_crop(OSLensDatabase db,int i) { auto l=lens_at(db,i); return l ? l->CropFactor : 1; }
float os_camera_crop(OSLensDatabase db,const char *maker,const char *model) {
    if (!db || !*maker || !*model) return 0;
    auto cameras=lf_db_find_cameras(static_cast<lfDatabase *>(db),maker,model);
    float result=cameras && cameras[0] && !cameras[1] ? cameras[0]->CropFactor : 0;
    lf_free(cameras); return result;
}
int os_lens_capabilities(OSLensDatabase db,int i) {
    auto l=lens_at(db,i); if(!l) return 0;
    return (l->CalibDistortion && l->CalibDistortion[0] ? LF_MODIFY_DISTORTION:0) |
           (l->CalibTCA && l->CalibTCA[0] ? LF_MODIFY_TCA:0) |
           (l->CalibVignetting && l->CalibVignetting[0] ? LF_MODIFY_VIGNETTING:0);
}
int os_lens_maps(OSLensDatabase db,int index,float crop,int width,int height,float focal,float aperture,float distance,int flags,int gw,int gh,float *maps) {
    auto lens=lens_at(db,index);
    if(!lens || !maps || width<2 || height<2 || gw<2 || gh<2 || gw>1025 || gh>1025 || focal<=0 || crop<=0) return -1;
    auto mod=std::unique_ptr<lfModifier,decltype(&lf_modifier_destroy)>(lf_modifier_new(lens,crop,width,height),lf_modifier_destroy);
    // Lensfun scale=0 chooses the profile's automatic crop; no fisheye projection conversion.
    const int enabled=lf_modifier_initialize(mod.get(),lens,LF_PF_F32,focal,aperture,distance,0,lens->Type,flags|LF_MODIFY_SCALE,false);
    const size_t plane=size_t(gw)*gh*4;
    for(int y=0;y<gh;++y) for(int x=0;x<gw;++x) {
        const float px=float(x)*(width-1)/(gw-1), py=(1-float(y)/(gh-1))*(height-1);
        float coords[6]={px,py,px,py,px,py};
        lf_modifier_apply_subpixel_geometry_distortion(mod.get(),px,py,1,1,coords);
        const size_t off=(size_t(y)*gw+x)*4;
        for(int c=0;c<3;++c) {
            float *p=maps+c*plane+off;
            p[0]=(coords[2*c]+0.5f)/width; p[1]=1-(coords[2*c+1]+0.5f)/height; p[2]=0;p[3]=1;
        }
        // Vignetting is evaluated in source coordinates before optical warping.
        float gain[4]={1,1,1,1};
        lf_modifier_apply_color_modification(mod.get(),gain,coords[2],coords[3],1,1,LF_CR_4(RED,GREEN,BLUE,UNKNOWN),16);
        for(int c=0;c<4;++c) maps[3*plane+off+c]=std::isfinite(gain[c]) ? gain[c] : 1;
    }
    return enabled;
}
