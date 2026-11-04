import pathlib
import re
import unittest
from lupa.lua53 import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parents[1]


class EnergyModeTests(unittest.TestCase):
    def test_script_uses_optional_scope_and_keeps_old_runner_compatible(self):
        script = (ROOT / 'app/Resources/美国完整流程.at').read_text(encoding='utf-8')
        lua = LuaRuntime()
        lua.execute('assert(load(...))', script)
        self.assertIn('pcall(function() return readFrame(parts[name]) end)', script)
        helper = re.search(r'local function readFrame\(body\).*?\nend', script, re.S).group()
        lua.execute(helper + '\nassert(readFrame(function() return 4,5 end)==4)')
        lua.execute('withScreen=function(f) called=true;return f() end\n' + helper + '\nlocal a,b=readFrame(function() return 4,5 end);assert(called and a==4 and b==5)')

    def test_legacy_capture_path_and_cleanup_are_explicit(self):
        source = (ROOT / 'tweak/Tweak.xm').read_text(encoding='utf-8')
        self.assertIn('if (!gEnergyEnabled || !gEnergyDepth) return ATCaptureScreen(out);', source)
        self.assertIn('if (!gEnergyDepth) ATEnergyInvalidate();', source)
        for name in ['ATSimulateTouch', 'ATSimulateKey', 'ATASCIIKeyEvent', 'l_usleep', 'l_msleep']:
            prefix = 'void ' if name.startswith('ATSimulate') else ('BOOL ' if name=='ATASCIIKeyEvent' else 'int ')
            body = source[source.index('static ' + prefix + name):]
            self.assertIn('ATEnergyInvalidate();', body[:500])
        self.assertIn('gEnergyEnabled=ATLEnergyEnabled(ATBaseDir());', source)
        self.assertIn('gEnergyTemplates=nil;', source)


if __name__ == '__main__':
    unittest.main()
