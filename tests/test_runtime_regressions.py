"""iOS wiring contracts; these do not execute UIKit or the Lua C bridge."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / 'tweak/Tweak.xm').read_text(encoding='utf-8')

class RuntimeContracts(unittest.TestCase):
    def test_text_loading_and_quota(self):
        self.assertIn('luaL_loadbufferx', SRC)
        self.assertNotIn('luaL_dostring(', SRC)
        self.assertIn('ATLuaAllocator', SRC)
        self.assertNotIn('luaL_openlibs(', SRC)
        self.assertIn('luaopen_table', SRC)
        self.assertIn('luaopen_math', SRC)
        self.assertIn('ATExecuteLoadedChunk', SRC)

    def test_atomic_admission_and_finally(self):
        self.assertIn('__sync_bool_compare_and_swap(&gRunningScripts, 0, 1)', SRC)
        self.assertNotIn('ATWaitForPreviousScripts(3.0)', SRC)
        self.assertIn('@finally', SRC)
        self.assertIn('ATReleaseAllInputs();', SRC)
        self.assertNotIn('ATClearStopFlag();', SRC[SRC.index('static void ATPlayLuaFile'):SRC.index('#pragma mark - Command handling')])

    def test_stop_does_not_remove_flag_or_claim_idle(self):
        start=SRC.index('if ([action isEqualToString:@"stop"])')
        body=SRC[start:SRC.index('return;',start)]
        self.assertNotIn('removeItemAtPath', body)
        self.assertNotIn('ATWriteStatus(NO', body)
        self.assertIn('if (!ATIsSpringBoard()) return;',SRC[SRC.index('static void ATHandleCommand'):start])

    def test_deadline_sleep_and_search(self):
        sleep=SRC[SRC.index('static int l_usleep'):SRC.index('static int l_log')]
        self.assertIn('ATScriptExpired()',sleep)
        self.assertIn('isfinite',sleep)
        ncc=SRC[SRC.index('static int ATSearchCancelled'):SRC.index('// 模板 PNG')]
        self.assertIn('ATScriptExpired()',ncc)
        self.assertNotIn('similarity - 0.15',ncc)

    def test_abi_and_opaque_alpha(self):
        typedefs=SRC[SRC.index('static IOHIDEventSystemClientRef (*'):SRC.index('static IOHIDEventSystemClientRef gHIDClient')]
        self.assertNotIn('Float32',typedefs)
        self.assertIn('double',typedefs)
        self.assertIn('dst[x*4+3] = 255;',SRC)
        self.assertIn('uint32_t *);',SRC[SRC.index('static int32_t (*_AT_IOSurfaceUnlock'):])

    def test_files_and_probe_path(self):
        self.assertIn('ATValidScriptName',SRC)
        self.assertIn('Applications/ATLite.app/ATLiteProbe',SRC)
        self.assertIn('stringByResolvingSymlinksInPath',SRC)

    def test_injection_scope(self):
        filt=(ROOT/'tweak/ATLiteTweak.plist').read_text(encoding='utf-8')
        self.assertNotIn('<string>com.apple.UIKit</string>',filt)

    def test_email_flow_and_ocr(self):
        for entry in ['{"getEmailJob",', '{"sendEmailResult",', '{"failEmailJob",']:
            self.assertIn(entry,SRC)
        self.assertIn('{"ocrText",        l_ocrText}',SRC)
        self.assertIn('{"inputText",      l_inputText}',SRC)
        self.assertIn('ATLEmailClaimJob',SRC)
        self.assertIn('ATLEmailFinishJob',SRC)
        self.assertIn('ATRecognizeScreen',SRC)

    def test_native_buffers_freed_before_lua_tables(self):
        for name in ['l_findColor','l_findImage']:
            body=SRC[SRC.index('static int '+name):]
            body=body[:body.index('\n}')]
            self.assertLess(body.index('ATFreeBitmap'),body.index('lua_newtable'))
        body=SRC[SRC.index('static int l_findText'):]
        body=body[:body.index('\n}')]
        self.assertNotIn('ATBitmap',body)

if __name__ == '__main__': unittest.main()
