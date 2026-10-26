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

typedef int (*ATCoreCancel)(void *);
/* 1 match, 0 no match/degenerate input, -1 cancelled. Full-resolution baseline. */
static inline int ATCoreNCCBest(const uint8_t *hay, int hw, int hh,
        const uint8_t *needle, int nw, int nh, double threshold,
        int *outX, int *outY, double *outScore, ATCoreCancel cancel, void *context) {
    if (!hay || !needle || nw < 2 || nh < 2 || hw < nw || hh < nh ||
        !isfinite(threshold) || threshold < -1 || threshold > 1) return 0;
    size_t count = (size_t)nw * (size_t)nh;
    double mean = 0, variance = 0;
    for (size_t i=0; i<count; i++) mean += needle[i];
    mean /= (double)count;
    for (size_t i=0; i<count; i++) { double d=needle[i]-mean; variance += d*d; }
    if (variance < 1e-6) return 0;
    double best = -2; int bx=-1, by=-1;
    for (int y=0; y<=hh-nh; y++) {
        for (int x=0; x<=hw-nw; x++) {
            if (cancel && cancel(context)) return -1;
            double sum=0, squares=0, numerator=0;
            for (int j=0; j<nh; j++) {
                if ((j & 31)==0 && cancel && cancel(context)) return -1;
                const uint8_t *row=hay+(size_t)(y+j)*hw+x;
                for (int i=0; i<nw; i++) {
                    double v=row[i]; sum += v; squares += v*v;
                    numerator += v*(needle[(size_t)j*nw+i]-mean);
                }
            }
            double wvar=squares-sum*sum/(double)count;
            if (wvar < 1e-6) continue;
            double score=numerator/sqrt(variance*wvar);
            if (score>best) { best=score; bx=x; by=y; }
        }
    }
    if (bx<0 || best<threshold) return 0;
    *outX=bx; *outY=by; *outScore=fmin(1.0,best);
    return 1;
}
#endif
