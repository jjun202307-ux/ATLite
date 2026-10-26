"""Execute the actual embedded Extensions.lua in Lua 5.3 (optional local wheel)."""
from pathlib import Path
import re, unittest
try:
    from lupa.lua53 import LuaRuntime
except ImportError:
    LuaRuntime=None

@unittest.skipUnless(LuaRuntime, 'install lupa (CI does) for Lua 5.3 execution')
class ExtensionsLua(unittest.TestCase):
    def setUp(self):
        src=(Path(__file__).resolve().parents[1]/'tweak/Tweak.xm').read_text(encoding='utf-8')
        code=re.search(r'ATExtensionsLua = @R"\((.*?)\)";',src,re.S).group(1)
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''events={}; _atlSeed=123; log=function() end
            touchDown=function(...) events[#events+1]={"down",...} end
            touchUp=function(...) events[#events+1]={"up",...} end
            touchMove=function(...) events[#events+1]={"move",...} end
            msleep=function(n) end
            usleep=function(n) events[#events+1]={"sleep",n} end
            rootDir=function() return "/data/Scripts" end
            stop=function() error("STOP") end
            findImage=function() return {{20,30,.99}} end
            findColor=function() return {} end
            findText=function() return {{10,40}} end''')
        self.lua.execute(code)
    def test_tap_order_and_duration(self):
        self.lua.execute('tap(11,22)')
        self.assertTrue(self.lua.eval('events[1][1]=="down" and events[3][1]=="up"'))
        self.assertTrue(self.lua.eval('events[2][2]>=60000 and events[2][2]<=120000'))
    def test_paths_and_helpers(self):
        self.assertEqual(self.lua.eval('imagePath("a.png")'),'/data/Images/a.png')
        self.lua.execute('findImageTap("a.png",.9)')
        self.assertEqual(self.lua.eval('events[1][3]'),20)
        self.assertEqual(self.lua.eval('events[1][4]'),30)
    def test_empty_search_does_not_tap(self):
        self.lua.execute('findColorTap(0,0)')
        self.assertEqual(self.lua.eval('#events'),0)

    def test_swipe_and_interrupted_tap_release(self):
        self.lua.execute('swipe(1,2,21,42,32)')
        self.assertTrue(self.lua.eval('events[1][1]=="down" and events[#events][1]=="up"'))
        self.assertEqual(self.lua.eval('events[#events][3]'),21)
        self.lua.execute('events={}; usleep=function() error("STOP") end; local ok=pcall(tap,11,22); assert(not ok)')
        self.assertTrue(self.lua.eval('events[#events][1]=="up"'))

if __name__=='__main__': unittest.main()
