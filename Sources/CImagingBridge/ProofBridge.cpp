#include "CImagingBridge.h"
#include <lcms2.h>
#include <cmath>
#include <algorithm>

int os_proof_profile_valid(const void *bytes,unsigned length) {
    auto context=cmsCreateContext(nullptr,nullptr);
    auto profile=cmsOpenProfileFromMemTHR(context,bytes,length);
    int valid=profile && (cmsGetColorSpace(profile)==cmsSigRgbData || cmsGetColorSpace(profile)==cmsSigCmykData || cmsGetColorSpace(profile)==cmsSigGrayData);
    if(profile)cmsCloseProfile(profile);cmsDeleteContext(context);return valid;
}
int os_proof_rgba(const void *inputICC,unsigned inputLength,const void *displayICC,unsigned displayLength,
                  const void *proofICC,unsigned proofLength,int intent,int paper,int gamut,float *pixels,unsigned count) {
    auto context=cmsCreateContext(nullptr,nullptr);
    if(!context)return 0;
    auto input=cmsOpenProfileFromMemTHR(context,inputICC,inputLength);
    auto output=cmsOpenProfileFromMemTHR(context,displayICC,displayLength);
    auto proof=cmsOpenProfileFromMemTHR(context,proofICC,proofLength);
    cmsHTRANSFORM transform=nullptr;
    if(input && output && proof) {
        cmsUInt16Number alarm[cmsMAXCHANNELS]={65535,0,65535};cmsSetAlarmCodesTHR(context,alarm);
        unsigned flags=cmsFLAGS_SOFTPROOFING|cmsFLAGS_COPY_ALPHA;
        if(!paper)flags|=cmsFLAGS_BLACKPOINTCOMPENSATION;
        if(gamut)flags|=cmsFLAGS_GAMUTCHECK;
        transform=cmsCreateProofingTransformTHR(context,input,TYPE_RGBA_FLT,output,TYPE_RGBA_FLT,proof,
            std::clamp(intent,0,3),paper ? INTENT_ABSOLUTE_COLORIMETRIC:INTENT_RELATIVE_COLORIMETRIC,flags);
    }
    if(transform) {
        // ICC printer profiles describe bounded reflectance, not scene-referred HDR.
        // This is a preview buffer only; source and export floats are not modified.
        for(unsigned i=0;i<count;++i)for(int c=0;c<3;++c)pixels[4*i+c]=std::clamp(pixels[4*i+c],0.0f,1.0f);
        cmsDoTransform(transform,pixels,pixels,count);
        // Floating-point gamut transforms use negative alarms regardless of 16-bit alarm codes.
        if(gamut)for(unsigned i=0;i<count;++i)if(pixels[4*i]<0 || pixels[4*i+1]<0 || pixels[4*i+2]<0){pixels[4*i]=1;pixels[4*i+1]=0;pixels[4*i+2]=1;}
    }
    const int ok=transform!=nullptr;
    if(transform)cmsDeleteTransform(transform);
    if(input)cmsCloseProfile(input);if(output)cmsCloseProfile(output);if(proof)cmsCloseProfile(proof);
    cmsDeleteContext(context);return ok;
}
