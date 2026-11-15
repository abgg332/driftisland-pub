#ifndef DI_REFERENCE_SPECTRUM_H
#define DI_REFERENCE_SPECTRUM_H
#include <math.h>
#include <stdint.h>
#include <string.h>
/* Static reconstruction of the verified iOS16 visual spectrum algorithm.
   Separate from the legacy 24-band/kick channel to avoid changing island consumers. */
static void diReferenceSpectrum(const float *samples, float *peaks, uint8_t *out) {
    float re[512], im[512] = {}, values[72];
    for (int i=0;i<512;i++) {
        float v=samples[i];
        if (!isfinite(v)) v=0;
        v=fmaxf(-1,fminf(1,v));
        re[i]=v*(0.5f-0.5f*cosf(6.28318530718f*i/511.0f));
    }
    for (unsigned i=1,j=0;i<512;i++) {
        unsigned bit=256;
        for (;j&bit;bit>>=1) j^=bit;
        j^=bit;
        if(i<j) {float v=re[i];re[i]=re[j];re[j]=v;}
    }
    for(int len=2;len<=512;len<<=1) {
        float a=-6.28318530718f/len, wr0=cosf(a), wi0=sinf(a);
        for(int i=0;i<512;i+=len) {
            float wr=1,wi=0;
            for(int j=0;j<len/2;j++) {
                int p=i+j,q=p+len/2;
                float tr=wr*re[q]-wi*im[q],ti=wr*im[q]+wi*re[q];
                re[q]=re[p]-tr;im[q]=im[p]-ti;re[p]+=tr;im[p]+=ti;
                float w=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;wr=w;
            }
        }
    }
    float maximum=0.0001f;
    for(int b=0;b<72;b++) {
        float u=b/72.0f;
        int lo=(int)floorf((powf(22,u)-1)/21*254);
        int hi=(int)ceilf((powf(22,(b+1)/72.0f)-1)/21*254);
        if(hi<=lo)hi=lo+2;
        if(hi>255)hi=255;
        float pk=0,ss=0;
        for(int k=lo;k<hi;k++) {
            float v=hypotf(re[k+1],im[k+1]);pk=fmaxf(pk,v);ss+=v*v;
        }
        values[b]=(0.7f*pk+0.3f*sqrtf(ss/fmaxf(1,hi-lo)))*(1+3.5f*u);
        maximum=fmaxf(maximum,values[b]);
    }
    float normalized[72], shaped[72];
    for(int b=0;b<72;b++) {
        float v=values[b];
        peaks[b]=v>peaks[b]?v:0.985f*peaks[b]+0.015f*v;
        float denom=fmaxf(0.001f,fmaxf(peaks[b],maximum*0.12f));
        normalized[b]=powf(fminf(1,v/denom),1.35f);
    }
    for(int i=0;i<72;i++) {
        float t=i/72.0f;
        float tri=1-fabsf(2*fmodf(t*2,1)-1);
        float pos=(0.055f+0.705f*tri)*71;
        int j=(int)floorf(pos); float frac=pos-j;
        float main=normalized[j]*(1-frac)+normalized[j<70?j+1:71]*frac;
        float pos2=(fmodf(0.11f+0.47f*t,0.52f)+0.08f)*71;
        int k=(int)floorf(pos2);float g=pos2-k;
        float secondary=normalized[k]*(1-g)+normalized[k<70?k+1:71]*g;
        float nearby=fmaxf(main,fmaxf(normalized[j>0?j-1:0],normalized[j<69?j+2:71]));
        shaped[i]=fminf(1,fmaxf(secondary*0.16f,0.72f*main+0.20f*secondary+0.08f*nearby));
    }
    for(int i=0;i<72;i++) {
        float v=0.84f*shaped[i]+0.08f*shaped[(i+71)%72]+0.08f*shaped[(i+1)%72];
        out[i]=(uint8_t)lrintf(255*fminf(1,fmaxf(0,v)));
    }
}
#endif
