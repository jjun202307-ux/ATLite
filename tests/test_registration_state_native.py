"""Compile and run the actual portable registration-state transition table."""
import os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
class RegistrationStateTests(unittest.TestCase):
 def test_transition_table(self):
  self.compile_and_run('native_reg_state.c')
 def test_private_atomic_storage(self):
  self.compile_and_run('native_reg_storage.c')
 def compile_and_run(self,source):
  cc=os.environ.get('ATL_CC') or shutil.which('cc') or shutil.which('clang')
  if not cc:self.skipTest('C compiler required')
  with tempfile.TemporaryDirectory() as tmp:
   exe=Path(tmp)/('state.exe' if os.name=='nt' else 'state')
   result=subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror',str(ROOT/'tests'/source),'-o',str(exe)],capture_output=True,text=True,timeout=30)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   result=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__':unittest.main()
