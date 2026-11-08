import pathlib
import re
import unittest
try:
    from lupa.lua53 import LuaRuntime
except ImportError:
    LuaRuntime = None

ROOT = pathlib.Path(__file__).resolve().parents[1]


class EnergyModeTests(unittest.TestCase):
    @unittest.skipUnless(LuaRuntime, 'install lupa for Lua workflow execution')
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
        self.assertRegex(source, r'if \(!gEnergyEnabled \|\| !gEnergyDepth\) \{\s*if \(gEnergyEnabled\) gEnergyCaptures\+\+;\s*return ATCaptureScreen\(out\);')
        self.assertIn('if (!gEnergyDepth) ATEnergyInvalidate();', source)
        for name in ['ATSimulateTouch', 'ATSimulateKey', 'ATASCIIKeyEvent', 'l_usleep', 'l_msleep']:
            prefix = 'void ' if name.startswith('ATSimulate') else ('BOOL ' if name=='ATASCIIKeyEvent' else 'int ')
            body = source[source.index('static ' + prefix + name):]
            self.assertIn('ATEnergyInvalidate();', body[:500])
        self.assertIn('gEnergyEnabled=ATLEnergyEnabled(ATBaseDir());', source)
        self.assertIn('gEnergyTemplates=nil;', source)

    def test_energy_ocr_fast_and_downsample_are_gated_by_energy(self):
        source = (ROOT / 'tweak/Tweak.xm').read_text(encoding='utf-8')
        # A 方案：降采样函数存在，且只在节能模式调用
        self.assertIn('ATDownsampleBitmapHalf', source)
        self.assertIn('if (gEnergyEnabled && gEnergyDepth)', source)
        self.assertIn('ATDownsampleBitmapHalf(&bitmap,&small)', source)
        # B 方案：spawn 传 --energy 与校验传 fast 都由 gEnergyEnabled 决定
        self.assertIn('gEnergyEnabled?@"fast":@"accurate"', source)
        worker = (ROOT / 'ocr/main.m').read_text(encoding='utf-8')
        self.assertIn('--energy', worker)
        self.assertIn('VNRequestTextRecognitionLevelFast', worker)
        child = (ROOT / 'shared/ATLChildProcess.h').read_text(encoding='utf-8')
        self.assertIn('--energy', child)

    def test_energy_default_is_off_when_preference_missing(self):
        settings = (ROOT / 'shared/ATLEnergySettings.h').read_text(encoding='utf-8')
        self.assertIn('return NO', settings)


if __name__ == '__main__':
    unittest.main()
