#ifndef ATL_OCR_GEOMETRY_H
#define ATL_OCR_GEOMETRY_H
#include <math.h>

/* Vision's own observations may straddle an image edge (for example a
 * partially visible navigation label). Emit only their visible intersection;
 * the receiver still validates the resulting normalized protocol strictly. */
static inline int ATLClipVisionOCRBox(double *x,double *y,double *width,double *height) {
    if (!x || !y || !width || !height || !isfinite(*x) || !isfinite(*y) ||
        !isfinite(*width) || !isfinite(*height) || *width<=0 || *height<=0) return 0;
    double right=*x+*width,bottom=*y+*height;
    if (!isfinite(right) || !isfinite(bottom)) return 0;
    double left=fmax(0.0,*x),top=fmax(0.0,*y);
    right=fmin(1.0,right);bottom=fmin(1.0,bottom);
    if (right<=left || bottom<=top) return 0;
    *x=left;*y=top;*width=right-left;*height=bottom-top;
    return 1;
}

/* Vision can report a fraction of a pixel outside the image for clipped text.
 * Permit at most one pixel at an edge, then intersect with the actual frame. */
static inline int ATLNormalizeOCRBox(double *x,double *y,double *width,double *height,int frameW,int frameH) {
    if (!x || !y || !width || !height || frameW<=0 || frameH<=0 ||
        !isfinite(*x) || !isfinite(*y) || !isfinite(*width) || !isfinite(*height) ||
        *width<0 || *height<0) return 0;
    double left=*x,top=*y,right=left+*width,bottom=top+*height;
    double tx=1.0/(double)frameW,ty=1.0/(double)frameH;
    if (!isfinite(right) || !isfinite(bottom) || left < -tx || top < -ty ||
        right > 1.0+tx || bottom > 1.0+ty || left > 1.0+tx || top > 1.0+ty ||
        right < -tx || bottom < -ty) return 0;
    left=fmax(0.0,fmin(1.0,left));right=fmax(0.0,fmin(1.0,right));
    top=fmax(0.0,fmin(1.0,top));bottom=fmax(0.0,fmin(1.0,bottom));
    if (right<left || bottom<top) return 0;
    *x=left;*y=top;*width=right-left;*height=bottom-top;
    return 1;
}
#endif
