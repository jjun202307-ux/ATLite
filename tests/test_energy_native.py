import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class EnergyNative(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Foundation fixture requires macOS')
    def test_actual_scope_ownership_errors_stop_and_preferences(self):
        source = (ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        def function(name):
            return re.search(r'static (?:void|BOOL|int) '+name+r'\([^\n]*\) \{.*?\n\}', source, re.S).group()
        code = r'''
#import <Foundation/Foundation.h>
#import "ATLEnergySettings.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <assert.h>
typedef struct { uint8_t *rgba; int w,h; BOOL borrowed; } ATBitmap;
static BOOL gEnergyEnabled=YES,gEnergyOCRValid=NO;
static unsigned gEnergyDepth=0;
static ATBitmap gEnergyFrame={0};
static unsigned long gEnergyFrameHits=0,gEnergyCaptures=0;
static int captures=0,stopped=0;
static BOOL ATCaptureScreen(ATBitmap *out) {
    captures++;out->rgba=malloc(4);out->w=out->h=1;out->borrowed=NO;return YES;
}
static void ATCheckScript(lua_State *L) { if(stopped) luaL_error(L,"STOP"); }
'''
        code += '\n'.join(function(n) for n in ['ATFreeBitmap','ATEnergyInvalidate','ATCaptureForRead','l_withScreen'])
        code += r'''
static int readPixel(lua_State *L) {
    ATBitmap b={0};assert(ATCaptureForRead(&b));ATFreeBitmap(&b);lua_pushinteger(L,captures);return 1;
}
static int invalidate(lua_State *L) {(void)L;ATEnergyInvalidate();return 0;}
static int stop(lua_State *L) {(void)L;stopped=1;return 0;}
int main(void) { @autoreleasepool {
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert(!ATLEnergyEnabled(dir));NSError *error=nil;
    assert(ATLSaveEnergyEnabled(dir,NO,&error));assert(!ATLEnergyEnabled(dir));
    assert(ATLSaveEnergyEnabled(dir,YES,&error));assert(ATLEnergyEnabled(dir));
    [@"broken" writeToFile:[dir stringByAppendingPathComponent:@"energy-mode.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    assert(!ATLEnergyEnabled(dir));
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    lua_State *L=luaL_newstate();luaL_openlibs(L);
    lua_register(L,"withScreen",l_withScreen);lua_register(L,"pixel",readPixel);
    lua_register(L,"invalidate",invalidate);lua_register(L,"stop",stop);
    assert(luaL_dostring(L,"local a,b=withScreen(function() local x=pixel();assert(pixel()==x);withScreen(function() assert(pixel()==x) end);return 7,8 end);assert(a==7 and b==8)")==0);
    assert(captures==1 && !gEnergyFrame.rgba && !gEnergyDepth);
    assert(luaL_dostring(L,"withScreen(function() local x=pixel();invalidate();assert(pixel()==x+1) end)")==0);
    assert(captures==3 && !gEnergyFrame.rgba);
    assert(luaL_dostring(L,"withScreen(function() pixel();error('ordinary') end)")!=0);lua_pop(L,1);
    assert(!gEnergyFrame.rgba && !gEnergyDepth);
    assert(luaL_dostring(L,"withScreen(function() pixel();stop() end)")!=0);lua_pop(L,1);
    assert(!gEnergyFrame.rgba && !gEnergyDepth);stopped=0;
    gEnergyEnabled=NO;int before=captures;
    assert(luaL_dostring(L,"withScreen(function() pixel();pixel() end)")==0);
    assert(captures==before+2 && !gEnergyFrame.rgba && !gEnergyDepth);
    lua_close(L);puts("energy production scope and preferences OK");
} return 0; }
'''
        with tempfile.TemporaryDirectory() as tmp:
            src=pathlib.Path(tmp)/'energy.m';src.write_text(code,encoding='utf-8')
            lua=ROOT/'tweak/lib/lua53'
            sources=[str(p) for p in lua.glob('*.c') if p.name not in ['lua.c','luac.c']]
            cmd=[shutil.which('clang'),'-fobjc-arc','-Wno-deprecated-declarations','-I'+str(lua),'-I'+str(ROOT/'shared'),str(src),*sources,'-framework','Foundation','-lm','-o',str(pathlib.Path(tmp)/'energy')]
            # ARC is ObjC-only; compile Lua as C separately by letting clang infer .c.
            result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(pathlib.Path(tmp)/'energy')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
