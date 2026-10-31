import json, os, pathlib, subprocess, sys, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform=='darwin','requires macOS Foundation/ImageIO/Vision')
class OCRWorker(unittest.TestCase):
 def test_invalid_input_has_correlated_failure(self):
  with tempfile.TemporaryDirectory() as d:
   binary=pathlib.Path(d)/'worker'
   subprocess.run(['clang','-fobjc-arc','-fblocks','-framework','Foundation','-framework','ImageIO','-framework','CoreGraphics','-framework','Vision',str(ROOT/'ocr/main.m'),'-o',str(binary)],check=True)
   for data in [b'',b'invalid PNG']:
    with tempfile.TemporaryFile() as source:
     source.write(data);source.seek(0)
     result=subprocess.run([str(binary),'--request-id','worker-test','--parent',str(os.getpid())],stdin=source,capture_output=True,timeout=3)
    self.assertEqual(result.returncode,0,result.stderr)
    reply=json.loads(result.stdout)
    self.assertEqual(reply['requestId'],'worker-test');self.assertFalse(reply['ok']);self.assertEqual(reply['errorCode'],'INPUT_INVALID')
