import pathlib, plistlib, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class OCRPolicy(unittest.TestCase):
 def test_springboard_does_not_execute_vision(self):
  s=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
  body=s[s.index('static BOOL ATRecognizeScreen'):s.index('static int l_findText')]
  self.assertNotIn('performRequests:',body)
  self.assertIn('ATLRunChild',body)
  self.assertIn('ATLDecodeOCRReply',body)
 def test_worker_has_device_verified_permission_and_language_policy(self):
  d=plistlib.loads((ROOT/'ocr/entitlements.plist').read_bytes())
  self.assertIn('H11ANEInDirectPathClient',d['com.apple.security.iokit-user-client-class'])
  s=(ROOT/'ocr/main.m').read_text(encoding='utf-8')
  self.assertIn('VNRequestTextRecognitionLevelAccurate',s)
  self.assertNotIn('usesCPUOnly=YES',s)
  self.assertIn('supportedRecognitionLanguagesAndReturnError:',s)
  self.assertIn('getppid()',s)
