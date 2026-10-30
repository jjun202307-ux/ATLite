"""Contracts for private ABI and UTF-8 logging; actual capture needs a device."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CaptureLogging(unittest.TestCase):
    def test_render_display_has_no_status_return(self):
        tweak = (ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        probe = (ROOT/'probe/main.m').read_text(encoding='utf-8')
        self.assertIn('static void (*_AT_CARenderServerRenderDisplay)', tweak)
        self.assertIn('static void (*_ATRenderDisplay)', probe)
        self.assertNotIn('int kr = _AT_CARenderServerRenderDisplay', tweak)
        self.assertNotIn('int krr = _ATRenderDisplay', probe)
        self.assertNotIn('krr == 0', probe)
        self.assertNotIn('RenderDisplay failed kr=', tweak)

    def test_lua_log_explicit_utf8(self):
        tweak = (ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        body = tweak[tweak.index('static int l_log('):tweak.index('static int l_screenWidth')]
        self.assertIn('lua_tolstring', body)
        self.assertIn('initWithBytes:', body)
        self.assertIn('encoding:NSUTF8StringEncoding', body)
        self.assertNotIn('appendFormat:@"%s', body)

if __name__ == '__main__':
    unittest.main()
