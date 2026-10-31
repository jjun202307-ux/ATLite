from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class ProbeSafetyContracts(unittest.TestCase):
 def setUp(self):
  self.p=(ROOT/'probe/main.m').read_text(encoding='utf-8-sig'); self.a=(ROOT/'app/Source/ATLProbe.m').read_text(encoding='utf-8-sig'); self.u=(ROOT/'app/Source/ATLLogViewController.m').read_text(encoding='utf-8-sig')
 def test_no_privileged_file_sink(self): self.assertNotRegex(self.p,r'\b(fopen|chmod)\s*\(')
 def test_no_default_setuid(self):
  s=(ROOT/'layout/DEBIAN/postinst').read_text(encoding='utf-8-sig'); self.assertNotIn('chmod u+s',s); self.assertIn('chmod 0755',s)
 def test_run_output_and_flush(self): self.assertIn('run_id=%@ from=%@',self.p); self.assertIn('fflush(stdout)',self.p)
 def test_hid_guard_and_abi(self): self.assertIn('|| !_ATAppendEvent',self.p); self.assertNotIn('Float32',self.p)
 def test_surface_contract(self): self.assertIn('kern_return_t (*_ATSurfaceUnlock)(ATSurfaceRef, uint32_t, uint32_t *)',self.p); self.assertIn('BUFFER-READABLE',self.p); self.assertIn('CFRelease(sf)',self.p)
 def test_bounded_capture_and_wait(self): self.assertNotRegex(self.a,r'waitpid\([^;]+,\s*0\)'); self.assertIn('AT_PROBE_MAX_OUTPUT',self.a); self.assertIn('killRC',self.a)
 def test_main_thread_screen(self): self.assertIn('NSThread.isMainThread',self.a); self.assertIn('dispatch_semaphore_wait',self.a)
 def test_no_fake_ui_completion(self): self.assertNotIn('containsString:@"from=springboard"',self.u); self.assertIn('self.autoRefresh = NO',self.u); self.assertIn('P2',self.u)

 def test_probe_save_prepares_its_own_directory(self):
  helper=(ROOT/'app/Source/ATLFileIO.h').read_text(encoding='utf-8-sig')
  self.assertIn('ATLWriteDiagnosticResult',self.a,'probe must save independently of tweak initialization')
  self.assertIn('createDirectoryAtPath:',helper,'diagnostic save must create missing parent directories')
  self.assertNotIn('App 结果保存于 probe-app.log。',self.u,'UI cannot claim save succeeded unconditionally')

 def test_missing_log_does_not_assert_injection_state(self):
  self.assertNotIn('→ tweak 未注入 SpringBoard',self.u)
  self.assertNotIn('→ tweak 已注入，但还没写过日志',self.u)


 def test_release_events_ready_before_touch_down(self):
  dispatch = self.p.index('_ATClientDispatch(client, hand);')
  self.assertLess(self.p.index('ATEventRef hand2 ='), dispatch)
  self.assertLess(self.p.index('ATEventRef fg2 ='), dispatch)
  self.assertLess(self.p.index('if (!hand || !fg || !hand2 || !fg2)'), dispatch)
  self.assertLess(self.p.index('_ATAppendEvent(hand2, fg2, 0);'), dispatch)
 def test_release_uses_same_display_field(self):
  self.assertIn('_ATSetInt(fg2, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);',self.p)
  self.assertIn('_ATSetInt(hand2, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);',self.p)
