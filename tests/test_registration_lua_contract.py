"""Security contracts for the registration Lua bridge (native device tests remain required)."""
from pathlib import Path
import re,unittest
ROOT=Path(__file__).resolve().parents[1]
class RegistrationLuaContracts(unittest.TestCase):
 def test_password_is_not_returned_to_lua_and_is_wiped(self):
  s=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
  self.assertIn('{"getRegistrationJob",',s);self.assertIn('{"inputRegistrationPassword",',s)
  body=re.search(r'static int l_getRegistrationJob\(lua_State \*L\) \{(.*?)\n\}',s,re.S).group(1)
  self.assertNotRegex(body,r'lua_setfield\([^\n]*"password"')
  self.assertIn('ATClearRegistrationSecret()',s)
  finish=s.split('static void ATPlayLuaFile',1)[1].split('#pragma mark - Command handling',1)[0]
  self.assertIn('ATL_REG_INTERRUPTED',finish);self.assertIn('ATClearRegistrationSecret()',finish)
 def test_registration_source_linked_into_tweak(self):
  self.assertIn('../shared/ATLRegistrationJob.m',(ROOT/'tweak/Makefile').read_text(encoding='utf-8'))
if __name__=='__main__':unittest.main()
