#include "ATCore.h"
#include <assert.h>
#include <stdio.h>

static int cancelled(void *context) { return *(int *)context; }
int main(void) {
    assert(ATValidUTF8Text((const unsigned char *)"abc@example.com",15));
    assert(ATValidUTF8Text((const unsigned char *)"\xe7\x94\xa8\xe6\x88\xb7",6));
    assert(!ATValidUTF8Text((const unsigned char *)"a\0b",3));
    assert(!ATValidUTF8Text((const unsigned char *)"\xed\xa0\x80",3));
    assert(!ATValidUTF8Text((const unsigned char *)"\xc0\x80",2));
    assert(!ATValidUTF8Text((const unsigned char *)"\xf0\x9f",2));
    double dx=0,dy=0;
    assert(ATPointToDigitizer(207,448,414,896,&dx,&dy) && dx==.5 && dy==.5);
    assert(!ATPointToDigitizer(1,2,0,896,&dx,&dy));
    assert(!ATPointToDigitizer(NAN,2,414,896,&dx,&dy));
    assert(ATPointToDigitizer(-1,900,414,896,&dx,&dy) && dx==0 && dy==1);
    uint16_t usage=0; int shift=0;
    assert(ATASCIIKey('@',&usage,&shift) && usage==0x1f && shift==1);
    assert(ATASCIIKey('a',&usage,&shift) && usage==4 && shift==0);
    assert(ATASCIIKey('_',&usage,&shift) && usage==0x2d && shift==1);
    assert(!ATASCIIKey(0xff,&usage,&shift));
    assert(ATNanosecondsToTicks(1000000,125,3)==24000);
    assert(ATNanosecondsToTicks(1000000,1,1)==1000000);
    assert(ATNanosecondsToTicks(1,0,1)==0);
    ATMemoryBudget budget={0,32};
    void *p=ATBudgetRealloc(&budget,NULL,999,16);
    assert(p && budget.used==16);
    assert(!ATBudgetRealloc(&budget,p,16,33) && budget.used==16);
    void *q=ATBudgetRealloc(&budget,p,16,24);
    assert(q && budget.used==24);
    assert(ATBudgetRealloc(&budget,q,24,0)==NULL && budget.used==0);
    uint8_t hay[64*64], needle[16*16];
    uint32_t state=20261026;
    for(int i=0;i<64*64;i++){state=state*1664525u+1013904223u;hay[i]=(uint8_t)(state>>24);}
    for(int i=0;i<16*16;i++){state=state*1664525u+1013904223u;needle[i]=(uint8_t)(state>>24);}
    for(int y=0;y<16;y++) for(int x=0;x<16;x++) hay[(y+1)*64+x+1]=needle[y*16+x];
    int x=-1,y=-1,stop=0;double score=0;
    assert(ATCoreNCCBest(hay,64,64,needle,16,16,.99,&x,&y,&score,cancelled,&stop)==1);
    assert(x==1 && y==1 && score>.99999);
    stop=1;
    assert(ATCoreNCCBest(hay,64,64,needle,16,16,.99,&x,&y,&score,cancelled,&stop)==-1);
    uint8_t small[4]={0,255,128,64};
    stop=0;
    assert(ATCoreNCCBest(small,2,2,small,2,2,.99,&x,&y,&score,cancelled,&stop)==1);
    uint8_t flat[4]={10,10,10,10};
    assert(ATCoreNCCBest(flat,2,2,flat,2,2,.99,&x,&y,&score,cancelled,&stop)==0);
    puts("native core OK: quota, clock conversion, exact off-grid NCC, cancellation, tiny/flat templates");
    return 0;
}
