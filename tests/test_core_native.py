"""Compile/run the actual portable C core used by the tweak, not a Python model."""
import os, shutil, subprocess, tempfile, unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

class NativeCore(unittest.TestCase):
    def test_native_core(self):
        header=ROOT/'tweak/ATCore.h'
        self.assertTrue(header.exists(),'portable production core is missing')
        cc=os.environ.get('ATL_CC') or shutil.which('cc') or shutil.which('clang')
        if not cc: self.skipTest('Set ATL_CC to a C compiler; CI runs this test')
        command=[cc]+(['cc'] if 'zig' in Path(cc).stem.lower() else [])
        with tempfile.TemporaryDirectory() as tmp:
            exe=Path(tmp)/('native.exe' if os.name=='nt' else 'native')
            p=subprocess.run(command+['-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'tweak'),str(ROOT/'tests/native_core.c'),'-o',str(exe)]+(['-lm'] if os.name!='nt' else []),capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            self.assertIn('native core OK',p.stdout)

if __name__=='__main__': unittest.main()
