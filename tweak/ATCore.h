#ifndef ATL_CORE_H
#define ATL_CORE_H
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

/* Length-aware UTF-8 validation without allocating on the Lua error path. */
static inline int ATValidUTF8Text(const unsigned char *s, size_t length) {
    size_t i=0;
    while (i<length) {
        uint32_t cp=s[i++], min=0; unsigned extra=0;
        if (cp<0x80) { if(cp<0x20 || cp==0x7f) return 0; continue; }
        if (cp>=0xc2 && cp<=0xdf) { cp&=0x1f; extra=1; min=0x80; }
        else if (cp>=0xe0 && cp<=0xef) { cp&=0xf; extra=2; min=0x800; }
        else if (cp>=0xf0 && cp<=0xf4) { cp&=7; extra=3; min=0x10000; }
        else return 0;
        if (extra>length-i) return 0;
        while (extra--) { unsigned c=s[i++]; if((c&0xc0)!=0x80) return 0; cp=(cp<<6)|(c&0x3f); }
        if(cp<min || cp>0x10ffff || (cp>=0xd800 && cp<=0xdfff) || (cp>=0x80 && cp<=0x9f)) return 0;
    }
    return 1;
}

/* USB HID US-layout printable ASCII. Emails are ASCII; Unicode is rejected. */
static inline int ATASCIIKey(unsigned char ch, uint16_t *usage, int *shift) {
    *shift=0;
    if (ch>='a' && ch<='z') { *usage=(uint16_t)(4+ch-'a'); return 1; }
    if (ch>='A' && ch<='Z') { *usage=(uint16_t)(4+ch-'A'); *shift=1; return 1; }
    if (ch>='1' && ch<='9') { *usage=(uint16_t)(0x1e + ch-'1'); return 1; }
    if (ch=='0') { *usage=0x27; return 1; }
    if (ch==' ') { *usage=0x2c; return 1; }
    const char *numbers="!@#$%^&*()";
    const char *found=ch ? strchr(numbers,(int)ch) : NULL;
    if (found) { *usage=(uint16_t)(0x1e + (found-numbers)); *shift=1; return 1; }
    const char *pairs="-_=+[{]}\\|;:'\",<.>/?`~";
    const uint16_t keys[]={0x2d,0x2e,0x2f,0x30,0x31,0x33,0x34,0x36,0x37,0x38,0x35};
    found=ch ? strchr(pairs,(int)ch) : NULL;
    if (!found) return 0;
    size_t index=(size_t)(found-pairs); *usage=keys[index/2]; *shift=(int)(index%2); return 1;
}

/* Portable production helpers; tests/native_core.c compiles this same file. */
static inline uint64_t ATNanosecondsToTicks(uint64_t ns, uint32_t numer, uint32_t denom) {
    if (!numer || !denom) return 0;
    return (uint64_t)(((__uint128_t)ns * denom) / numer);
}

typedef struct { size_t used, limit; } ATMemoryBudget;
static inline void *ATBudgetRealloc(ATMemoryBudget *b, void *ptr, size_t oldSize, size_t newSize) {
    /* Lua uses oldSize as a type tag when ptr is NULL. */
    if (!ptr) oldSize = 0;
    if (!newSize) { free(ptr); b->used -= oldSize; return NULL; }
    size_t retained = b->used - oldSize;
    if (retained > b->limit || newSize > b->limit - retained) return NULL;
    void *p = realloc(ptr, newSize);
    if (p) b->used = retained + newSize;
    return p;
}

static inline int ATPointToDigitizer(double x,double y,double width,double height,double *outX,double *outY) {
    if(!outX || !outY || !isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || width<=0 || height<=0)return 0;
    *outX=fmax(0,fmin(1,x/width));*outY=fmax(0,fmin(1,y/height));return 1;
}

/* Convert an in-screen point rectangle into an inclusive/exclusive pixel crop. */
static inline int ATCorePointRegion(double x,double y,double width,double height,double scale,int sw,int sh,
                                    int *outX,int *outY,int *outW,int *outH) {
    if(!outX || !outY || !outW || !outH || !isfinite(x) || !isfinite(y) ||
       !isfinite(width) || !isfinite(height) || !isfinite(scale) || scale<=0 ||
       x<0 || y<0 || width<=0 || height<=0 || sw<=0 || sh<=0 || sw>8192 || sh>8192 ||
       !isfinite(x+width) || !isfinite(y+height) || (x+width)*scale>sw || (y+height)*scale>sh) return 0;
    double left=floor(x*scale),top=floor(y*scale),right=ceil((x+width)*scale),bottom=ceil((y+height)*scale);
    if(left<0 || top<0 || right>sw || bottom>sh || right<=left || bottom<=top) return 0;
    *outX=(int)left;*outY=(int)top;*outW=(int)(right-left);*outH=(int)(bottom-top);return 1;
}

typedef int (*ATCoreCancel)(void *);
/* Exact NCC with summed-area statistics and a Cauchy-Schwarz block bound.
 * The bound rejects only candidates mathematically unable to reach the cutoff;
 * surviving positions still use every template pixel, including off-grid positions. */
static inline double ATCoreRect(const double *table,int stride,int x,int y,int w,int h) {
    return table[(size_t)(y+h)*stride+x+w]-table[(size_t)y*stride+x+w]
         - table[(size_t)(y+h)*stride+x]+table[(size_t)y*stride+x];
}
static inline int ATCoreNCCBest(const uint8_t *hay,int hw,int hh,
        const uint8_t *needle,int nw,int nh,double threshold,
        int *outX,int *outY,double *outScore,ATCoreCancel cancel,void *context) {
    if (!hay || !needle || !outX || !outY || !outScore || nw<2 || nh<2 || hw<nw || hh<nh ||
        hw>8192 || hh>8192 || (size_t)hw*hh>16777216 || !isfinite(threshold) || threshold< -1 || threshold>1) return 0;
    size_t count=(size_t)nw*nh;
    double mean=0,variance=0;
    for(size_t i=0;i<count;i++) mean+=needle[i];
    mean/=count;
    for(size_t i=0;i<count;i++){double d=needle[i]-mean;variance+=d*d;}
    if(variance<1e-6) return 0;
    int stride=hw+1;
    size_t cells=(size_t)stride*(hh+1);
    double *table=(double *)calloc(cells*2,sizeof(double));
    if(!table)return -1;
    double *squares=table+cells;
    for(int y=0;y<hh;y++) {
        if(cancel && cancel(context)){free(table);return -1;}
        double sum=0,sq=0;
        for(int x=0;x<hw;x++) {
            double value=hay[(size_t)y*hw+x];sum+=value;sq+=value*value;
            table[(size_t)(y+1)*stride+x+1]=table[(size_t)y*stride+x+1]+sum;
            squares[(size_t)(y+1)*stride+x+1]=squares[(size_t)y*stride+x+1]+sq;
        }
    }
    int gx=nw<8?nw:8,gy=nh<8?nh:8,blocks=0;
    int left[64],top[64],width[64],height[64];double size[64],tSum[64],projectedT=0;
    for(int by=0;by<gy;by++)for(int bx=0;bx<gx;bx++) {
        int k=blocks++;left[k]=bx*nw/gx;top[k]=by*nh/gy;
        width[k]=(bx+1)*nw/gx-left[k];height[k]=(by+1)*nh/gy-top[k];
        size[k]=(double)width[k]*height[k];tSum[k]=0;
        for(int j=top[k];j<top[k]+height[k];j++)for(int i=left[k];i<left[k]+width[k];i++)tSum[k]+=needle[(size_t)j*nw+i]-mean;
        projectedT+=tSum[k]*tSum[k]/size[k];
    }
    double residualT=fmax(0,variance-projectedT),best=-2;int bestX=-1,bestY=-1;
    for(int y=0;y<=hh-nh;y++)for(int x=0;x<=hw-nw;x++) {
        if((x&63)==0 && cancel && cancel(context)){free(table);return -1;}
        double sum=ATCoreRect(table,stride,x,y,nw,nh);
        double var=ATCoreRect(squares,stride,x,y,nw,nh)-sum*sum/count;
        if(var<1e-6)continue;
        double numerator=0,projectedH=0;
        for(int k=0;k<blocks;k++) {
            double block=ATCoreRect(table,stride,x+left[k],y+top[k],width[k],height[k]);
            numerator+=block*tSum[k]/size[k];projectedH+=block*block/size[k];
        }
        projectedH-=sum*sum/count;
        double denominator=sqrt(variance*var);
        double upper=(numerator+sqrt(residualT*fmax(0,var-projectedH)))/denominator;
        if(upper+1e-9<fmax(threshold,best))continue;
        numerator=0;
        for(int j=0;j<nh;j++) {
            if((j&31)==0 && cancel && cancel(context)){free(table);return -1;}
            const uint8_t *row=hay+(size_t)(y+j)*hw+x;
            for(int i=0;i<nw;i++)numerator+=row[i]*(needle[(size_t)j*nw+i]-mean);
        }
        double score=numerator/denominator;
        if(score>best){best=score;bestX=x;bestY=y;}
        if(best>=1-1e-12)goto finished;
    }
finished:
    free(table);
    if(bestX<0 || best<threshold)return 0;
    *outX=bestX;*outY=bestY;*outScore=fmin(1,best);return 1;
}
#endif
