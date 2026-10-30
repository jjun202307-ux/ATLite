"""Run the production C Lua bootstrap (with platform RNG stub only) in Lua 5.3."""
import os, pathlib, re, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]

class LuaBridge(unittest.TestCase):
    def test_bootstrap_stack(self):
        source=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        body=re.search(r'static int ATInitializeLua\(lua_State \*L\) \{(.*?)\n\}',source,re.S).group(1)
        guards=re.search(r'(static int ATGuardedProtectedCall.*?)(?=static int ATInitializeLua)',source,re.S)
        guard_code=guards.group(1) if guards else ''
        # Fail safely on the inherited null-name bug, rather than launching a crashing process.
        self.assertNotRegex(body,r'lua_pushvalue\(L, -1\);\s*lua_setglobal\(L, lua_tostring\(L, -2\)\)')
        lua_dir=ROOT/'tweak/lib/lua53'
        self.assertTrue((lua_dir/'lua.h').exists(),'vendor Lua source required for real C bridge regression')
        cc=os.environ.get('ATL_CC') or shutil.which('cc') or shutil.which('clang')
        if not cc: self.skipTest('C compiler required (CI provides cc)')
        command=[cc]+(['cc'] if 'zig' in pathlib.Path(cc).stem.lower() else [])
        touch_body=re.search(r'static int l_touchDown\(lua_State \*L\) \{(.*?)\n\}',source,re.S).group(1)
        stop_body=re.search(r'static int l_stop\(lua_State \*L\) \{(.*?)\n\}',source,re.S).group(1)
        code='''#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
static int stopped=0;
static volatile uint32_t gStopGeneration=0;
static uint32_t gRunStopGeneration=0;
static int requestStop(lua_State *L){(void)L;stopped=1;return 0;}
static int noop(lua_State *L){(void)L; return 0;}
static int touches=0;
static void ATSimulateTouch(int a,int f,float x,float y){(void)a;(void)f;(void)x;(void)y;touches++;}
static void ATCheckScript(lua_State *L);
static int l_touchDown(lua_State *L){'''+touch_body+'''}
static int l_stop(lua_State *L){'''+stop_body+'''}
static const luaL_Reg ATLuaFuncs[]={{"log",noop},{"touchDown",l_touchDown},{"stop",l_stop},{"requestStop",requestStop},{NULL,NULL}};
static unsigned arc4random_uniform(unsigned n){return n?123:0;}
static void ATCheckScript(lua_State *L){if(stopped || __sync_fetch_and_add(&gStopGeneration, 0) != gRunStopGeneration) luaL_error(L,"STOP");}
'''+guard_code+'''
static int ATInitializeLua(lua_State *L){'''+body+'''}
int main(void){lua_State *L=luaL_newstate(); assert(L);
lua_pushcfunction(L,ATInitializeLua); assert(lua_pcall(L,0,0,0)==0);
assert(luaL_dostring(L,"assert(type(touchDown)=='function'); assert(type(log)=='function'); assert(os==nil and io==nil and debug==nil and package==nil and loadfile==nil and dofile==nil and load==nil and setmetatable==nil and getmetatable==nil); assert(type(table.sort)=='function'); assert(type(math.random)=='function')")==0);
assert(luaL_dostring(L,"assert(pcall(function() return 7 end)); local ok,e=xpcall(function() error('ordinary') end,function(e) return e end); assert(not ok)")==0);
assert(luaL_dostring(L,"local ok=pcall(stop); resumed=true")!=0); lua_pop(L,1);
lua_getglobal(L,"resumed"); assert(lua_isnil(L,-1)); lua_pop(L,1); gRunStopGeneration=__sync_fetch_and_add(&gStopGeneration, 0);
assert(luaL_dostring(L,"local ok=xpcall(stop,function(e) return e end); resumed=true")!=0); lua_pop(L,1);
lua_getglobal(L,"resumed"); assert(lua_isnil(L,-1)); lua_pop(L,1); gRunStopGeneration=__sync_fetch_and_add(&gStopGeneration, 0);
stopped=1;
assert(luaL_dostring(L,"touchDown(0,1,2)")!=0 && touches==0); lua_pop(L,1);
assert(luaL_dostring(L,"local ok=pcall(function() error('STOP') end); return ok")!=0); lua_pop(L,1);
assert(luaL_dostring(L,"local ok=xpcall(function() error('STOP') end,function(e) return e end); return ok")!=0); lua_pop(L,1);
stopped=0;
assert(luaL_dostring(L,"pcall(function() requestStop() end)")!=0); lua_pop(L,1);
stopped=0;
assert(luaL_dostring(L,"xpcall(function() requestStop(); error('STOP') end,function(e) return e end)")!=0); lua_pop(L,1);
lua_close(L); puts("production Lua bootstrap OK"); return 0;}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c=pathlib.Path(tmp)/'bridge.c'; c.write_text(code,encoding='utf-8')
            exe=pathlib.Path(tmp)/('bridge.exe' if os.name=='nt' else 'bridge')
            files=[str(p) for p in lua_dir.glob('*.c') if p.name not in ('lua.c','luac.c')]
            p=subprocess.run(command+['-std=c99','-I',str(lua_dir),str(c),*files,'-o',str(exe)]+(['-lm'] if os.name!='nt' else []),capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            self.assertIn('production Lua bootstrap OK',p.stdout)

if __name__=='__main__': unittest.main()
