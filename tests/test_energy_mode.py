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

    def test_energy_ocr_level_independent_and_no_downsample(self):
        source = (ROOT / 'tweak/Tweak.xm').read_text(encoding='utf-8')
        # A 方案已移除：降采样会破坏主屏小图标文字识别（Shadowrocket→Shadowro¢ket），
        # OCR 输入保持全分辨率 bitmap，不再有降采样分支。
        self.assertNotIn('ATDownsampleBitmapHalf', source)
        self.assertIn('ATCreateCGImageFromBitmap(&bitmap)', source)
        # OCR 级别独立于节能开关：读 gOCRLevel（默认 accurate），不再由 gEnergyEnabled 决定。
        self.assertIn('static NSString *gOCRLevel=@"accurate"', source)
        self.assertIn('gOCRLevel=ATLEnergyOCRLevel(ATBaseDir())', source)
        self.assertIn('int ocrFast=[gOCRLevel isEqualToString:@"fast"]', source)
        # findImage 默认阈值可调：读 gImageSimilarity（默认 0.8）。
        self.assertIn('static double gImageSimilarity=0.8', source)
        self.assertIn('lua_isnumber(L, 2) ? lua_tonumber(L, 2) : gImageSimilarity', source)
        worker = (ROOT / 'ocr/main.m').read_text(encoding='utf-8')
        self.assertIn('--level', worker)
        self.assertIn('VNRequestTextRecognitionLevelFast', worker)
        child = (ROOT / 'shared/ATLChildProcess.h').read_text(encoding='utf-8')
        self.assertIn('--level', child)
        self.assertIn('"fast"', child)

    def test_energy_default_is_off_when_preference_missing(self):
        settings = (ROOT / 'shared/ATLEnergySettings.h').read_text(encoding='utf-8')
        self.assertIn('return NO', settings)
        # 可调参数默认值：识图阈值 0.8，OCR 级别 accurate
        self.assertIn('return 0.8', settings)
        self.assertIn('return @"accurate"', settings)


if __name__ == '__main__':
    unittest.main()
