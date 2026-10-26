from pathlib import Path
import unittest
try:
    from lupa.lua53 import LuaRuntime
except ImportError:
    LuaRuntime=None

@unittest.skipUnless(LuaRuntime,'install lupa for Lua workflow execution')
class EmailScript(unittest.TestCase):
    def run_script(self,text):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.globals().ocrLine=text
        lua.execute('''log=function() end; msleep=function() end
            getEmailJob=function() return {jobId="test-1",email="demo@example.com"} end
            inputText=function(s) typed=s end
            ocrText=function() return {{text=ocrLine,x=1,y=2}} end
            sendEmailResult=function(id,email,name,lines) result={id=id,email=email,username=name,lines=lines} end
            failEmailJob=function(id,email,reason) failed=reason end''')
        lua.execute((Path(__file__).resolve().parents[1]/'examples/email_roundtrip.at').read_text(encoding='utf-8'))
        return lua
    def test_success_is_from_ocr_not_email_prefix(self):
        lua=self.run_script('用户名：alice_2026')
        self.assertEqual(lua.eval('typed'),'demo@example.com')
        self.assertEqual(lua.eval('result.email'),'demo@example.com')
        self.assertEqual(lua.eval('result.username'),'alice_2026')
    def test_missing_username_reports_failure(self):
        lua=self.run_script('欢迎回来')
        self.assertIsNone(lua.eval('result'))
        self.assertTrue(lua.eval('failed~=nil'))

if __name__=='__main__': unittest.main()
