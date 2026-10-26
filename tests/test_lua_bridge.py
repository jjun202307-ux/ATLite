"""Run the production C Lua bootstrap (with platform RNG stub only) in Lua 5.3."""
import os, pathlib, re, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]

class LuaBridge(unittest.TestCase):
    def test_bootstrap_stack(self):
        source=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        body=re.search(r'static int ATInitializeLua\(lua_State \*L\) \{(.*?)\n\}',source,re.S).group(1)
        # Fail safely on the inherited null-name bug, rather than launching a crashing process.
        self.assertNotRegex(body,r'lua_pushvalue\(L, -1\);\s*lua_setglobal\(L, lua_tostring\(L, -2\)\)')
        lua_dir=ROOT/'tweak/lib/lua53'
        self.assertTrue((lua_dir/'lua.h').exists(),'vendor Lua source required for real C bridge regression')
        cc=os.environ.get('ATL_CC') or shutil.which('cc') or shutil.which('clang')
        if not cc: self.skipTest('C compiler required (CI provides cc)')
        command=[cc]+(['cc'] if 'zig' in pathlib.Path(cc).stem.lower() else [])
        code='''#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <stdio.h>
static int noop(lua_State *L){(void)L; return 0;}
static const luaL_Reg ATLuaFuncs[]={{"log",noop},{"touchDown",noop},{NULL,NULL}};
static unsigned arc4random_uniform(unsigned n){return n?123:0;}
static int ATInitializeLua(lua_State *L){'''+body+'''}
int main(void){lua_State *L=luaL_newstate(); assert(L);
lua_pushcfunction(L,ATInitializeLua); assert(lua_pcall(L,0,0,0)==0);
assert(luaL_dostring(L,"assert(type(touchDown)=='function'); assert(type(log)=='function'); assert(os==nil and io==nil and debug==nil and package==nil and loadfile==nil and dofile==nil and load==nil); assert(type(table.sort)=='function'); assert(type(math.random)=='function')")==0);
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
