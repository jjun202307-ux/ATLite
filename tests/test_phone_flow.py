from pathlib import Path
import subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
try:
 from lupa.lua53 import LuaRuntime
except ImportError:
 LuaRuntime=None

@unittest.skipUnless(LuaRuntime,'requires Lua runtime')
class PhoneFlowLua(unittest.TestCase):
 def test_completed_local_account_has_no_ui_side_effects(self):
  lua=LuaRuntime(unpack_returned_tuples=True)
  lua.execute('screenWidth=function() return 414 end;screenHeight=function() return 896 end;log=function() end;phoneFlow=function(op) assert(op=="begin");return {state="done",next=14} end;tap=function() error("unexpected UI") end')
  lua.execute((ROOT/'app/Resources/美国完整流程.at').read_text(encoding='utf-8'))
 def test_missing_configuration_does_not_touch_screen(self):
  lua=LuaRuntime(unpack_returned_tuples=True)
  lua.execute('screenWidth=function() return 414 end;screenHeight=function() return 896 end;log=function() end;phoneFlow=function() error("missing config") end;tap=function() error("unexpected UI") end')
  with self.assertRaisesRegex(Exception,'missing config'):lua.execute((ROOT/'app/Resources/美国完整流程.at').read_text(encoding='utf-8'))

@unittest.skipUnless(sys.platform=='darwin','requires macOS Foundation')
class PhoneFlowNative(unittest.TestCase):
 def test_mail_and_durable_checkpoints(self):
  with tempfile.TemporaryDirectory() as directory:
   exe=Path(directory)/'flow-test'
   p=subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(ROOT/'tests/native_phone_flow.m'),str(ROOT/'shared/ATLPhoneFlow.m'),str(ROOT/'shared/ATLRegistrationJob.m'),'-o',str(exe)],capture_output=True,text=True,timeout=60)
   self.assertEqual(p.returncode,0,p.stderr)
   p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=20)
   self.assertEqual(p.returncode,0,p.stderr)
