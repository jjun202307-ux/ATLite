"""Execute production capture allocation/conversion and Lua logger on macOS.
Only the OS renderer and IOSurface storage are test doubles; no phone is emulated.
"""
from pathlib import Path
import re, subprocess, sys, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]

class CaptureNative(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin','requires macOS Foundation; CI executes this')
    def test_production_capture_and_utf8_log(self):
        src=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        def function(name):
            match=re.search(r'static [^\n]+ '+name+r'\([^\n]*\) \{.*?\n\}',src,re.S)
            self.assertIsNotNone(match,name)
            return match.group(0)
        code=r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdarg.h>
#include <string.h>
#include "ATCaptureValidation.h"
/* CoreGraphics already declares IOSurfaceRef. */
static int mode=0, lockFailure=0, locked=0;
static size_t width=0,height=0,pitch=0;
static uint32_t format=0x42475241u;
static NSString *lastLog;
static void ATLog(NSString *fmt, ...) { va_list args; va_start(args,fmt); lastLog=[[NSString alloc] initWithFormat:fmt arguments:args]; va_end(args); }
static CGSize ATScreenPixelSize(void) { return CGSizeMake(3,2); }
static IOSurfaceRef create(CFDictionaryRef props) {
 int w=0,h=0,p=0; CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(props,CFSTR("IOSurfaceWidth")),kCFNumberIntType,&w);
 CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(props,CFSTR("IOSurfaceHeight")),kCFNumberIntType,&h);
 CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(props,CFSTR("IOSurfaceBytesPerRow")),kCFNumberIntType,&p);
 uint32_t f=0; CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(props,CFSTR("IOSurfacePixelFormat")),kCFNumberSInt32Type,&f); assert(f==0x42475241u);
 width=w; height=h; pitch=p; CFMutableDataRef data=CFDataCreateMutable(NULL,p*h); CFDataSetLength(data,p*h); return (IOSurfaceRef)data;
}
static void *base(IOSurfaceRef s) { return CFDataGetMutableBytePtr((CFMutableDataRef)s); }
static size_t getWidth(IOSurfaceRef s) { return width; }
static size_t getHeight(IOSurfaceRef s) { return height; }
static size_t getPitch(IOSurfaceRef s) { return pitch; }
static uint32_t getFormat(IOSurfaceRef s) { return format; }
static int32_t lockSurface(IOSurfaceRef s,uint32_t flags,uint32_t *seed) { if(lockFailure)return 1; assert(!locked); locked=1; return 0; }
static int32_t unlockSurface(IOSurfaceRef s,uint32_t flags,uint32_t *seed) { assert(locked);locked=0;return 0; }
static void render(uint32_t port,CFStringRef display,IOSurfaceRef s,uint32_t x,uint32_t y) {
 assert(!locked); if(mode==0)return; uint8_t *p=(uint8_t *)base(s); memset(p,0,pitch*height);
 if(mode==2) { p[0]=0x12;p[1]=0x34;p[2]=0x56;p[3]=0x78; }
}
static IOSurfaceRef (*_AT_IOSurfaceCreate)(CFDictionaryRef)=create;
static void (*_AT_CARenderServerRenderDisplay)(uint32_t,CFStringRef,IOSurfaceRef,uint32_t,uint32_t)=render;
static void *(*_AT_IOSurfaceGetBaseAddress)(IOSurfaceRef)=base;
static size_t (*_AT_IOSurfaceGetWidth)(IOSurfaceRef)=getWidth;
static size_t (*_AT_IOSurfaceGetHeight)(IOSurfaceRef)=getHeight;
static size_t (*_AT_IOSurfaceGetBytesPerRow)(IOSurfaceRef)=getPitch;
static uint32_t (*_AT_IOSurfaceGetPixelFormat)(IOSurfaceRef)=getFormat;
static int32_t (*_AT_IOSurfaceLock)(IOSurfaceRef,uint32_t,uint32_t *)=lockSurface;
static int32_t (*_AT_IOSurfaceUnlock)(IOSurfaceRef,uint32_t,uint32_t *)=unlockSurface;
static BOOL gCaptureReady=YES;
typedef struct { uint8_t *rgba;int w,h; } ATBitmap;
'''+function('ATRenderIntoNewSurface')+r'''
static IOSurfaceRef ATCaptureSurfaceWithTimeout(void) { return ATRenderIntoNewSurface(); }
'''+function('ATCaptureScreen')+r'''
typedef struct { const char *bytes[3]; size_t len[3]; int n; } lua_State;
static int lua_gettop(lua_State *L) { return L->n; }
static const char *lua_tolstring(lua_State *L,int i,size_t *n) { *n=L->len[i-1];return L->bytes[i-1]; }
static int lua_type(lua_State *L,int i) { return 0; }
static const char *lua_typename(lua_State *L,int t) { return "nil"; }
'''+function('l_log')+r'''
int main(void) { @autoreleasepool {
 ATBitmap b={0}; assert(!ATCaptureScreen(&b)); // void render returned but wrote nothing
 mode=1;assert(ATCaptureScreen(&b));assert(b.w==3&&b.h==2);assert(b.rgba[0]==0&&b.rgba[3]==255);free(b.rgba);b={0}; // black frame is legitimate
 mode=2;assert(ATCaptureScreen(&b));assert(b.rgba[0]==0x56&&b.rgba[1]==0x34&&b.rgba[2]==0x12&&b.rgba[3]==255);free(b.rgba);b={0};
 format=0x1234;assert(!ATCaptureScreen(&b));format=0x42475241u;
 lockFailure=1;assert(!ATCaptureScreen(&b));lockFailure=0;assert(!locked);
 lua_State L={{"中文邮箱测试","test@example.com",NULL},{strlen("中文邮箱测试"),strlen("test@example.com"),0},3};l_log(&L);
 assert([lastLog isEqualToString:@"[lua] 中文邮箱测试 test@example.com nil"]);
 L.bytes[0]="\xff";L.len[0]=1;L.n=1;l_log(&L);assert([lastLog isEqualToString:@"[lua] [invalid UTF-8]"]);
 puts("production capture and UTF-8 logger OK"); return 0;
}}
'''
        with tempfile.TemporaryDirectory() as tmp:
            f=Path(tmp)/'capture.mm';f.write_text(code,encoding='utf-8'); exe=Path(tmp)/'capture'
            p=subprocess.run(['clang++','-std=gnu++11','-fno-modules','-fobjc-arc','-framework','Foundation','-framework','CoreGraphics','-I',str(ROOT/'tweak'),str(f),'-o',str(exe)],capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            self.assertIn('production capture and UTF-8 logger OK',p.stdout)
