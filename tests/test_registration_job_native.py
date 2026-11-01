"""Execute the real registration job implementation with Foundation on macOS."""
import pathlib,subprocess,sys,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform=='darwin','requires macOS Foundation')
class RegistrationJobNative(unittest.TestCase):
 def test_lifecycle_and_secret_scrubbing(self):
  with tempfile.TemporaryDirectory() as t:
   exe=pathlib.Path(t)/'test'
   p=subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(ROOT/'tests/native_registration_job.m'),str(ROOT/'shared/ATLRegistrationJob.m'),'-o',str(exe)],capture_output=True,text=True,timeout=60)
   self.assertEqual(p.returncode,0,p.stderr)
   p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10);self.assertEqual(p.returncode,0,p.stderr)
