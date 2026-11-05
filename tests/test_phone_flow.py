from pathlib import Path
import subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
try:
 from lupa.lua53 import LuaRuntime
except ImportError:
 LuaRuntime=None

SCRIPT=(ROOT/'app/Resources/美国完整流程.at').read_text(encoding='utf-8')

def _lua_runtime(lua,extra='',msleep=None):
 lua.execute('screenWidth=function() return 414 end;screenHeight=function() return 896 end;log=function() end;tap=function() error("unexpected UI") end;ocrText=function() return {} end'+extra)
 lua.globals()['msleep']=msleep or (lambda ms: None)

@unittest.skipUnless(LuaRuntime,'requires Lua runtime')
class PhoneFlowLua(unittest.TestCase):
 def test_completed_local_account_has_no_ui_side_effects(self):
  lua=LuaRuntime(unpack_returned_tuples=True)
  lua.execute('screenWidth=function() return 414 end;screenHeight=function() return 896 end;log=function() end;msleep=function() end;phoneFlow=function(op) assert(op=="begin");return {state="done",next=14} end;tap=function() error("unexpected UI") end')
  lua.execute(SCRIPT)
 def test_missing_configuration_does_not_touch_screen(self):
  lua=LuaRuntime(unpack_returned_tuples=True)
  lua.execute('screenWidth=function() return 414 end;screenHeight=function() return 896 end;log=function() end;phoneFlow=function() error("missing config") end;tap=function() error("unexpected UI") end')
  with self.assertRaisesRegex(Exception,'missing config'):lua.execute(SCRIPT)
 def test_loop_runs_second_new_account(self):
  begins=[];finishes=[];sleeps=[]
  def phoneflow(op):
   if op=='begin':
    begins.append(1)
    return {'state':'ready','next':14,'email':'first@example.com' if len(begins)==1 else 'second@example.com','job':''}
   if op=='finish':
    finishes.append(1);return {}
   raise AssertionError('unexpected phoneFlow op: %r'%(op,))
  lua=LuaRuntime(unpack_returned_tuples=True);_lua_runtime(lua,msleep=lambda ms: sleeps.append(ms));lua.globals()['phoneFlow']=phoneflow
  lua.execute(SCRIPT)
  self.assertEqual(len(begins),2)
  self.assertEqual(len(finishes),2)
  self.assertEqual(sum(sleeps),15000)
 def test_loop_ends_normally_when_begin_reports_no_new_account(self):
  begins=[];finishes=[]
  def phoneflow(op):
   if op=='begin':
    begins.append(1)
    if len(begins)==1:return {'state':'ready','next':14,'email':'first@example.com','job':''}
    raise RuntimeError('sync timeout, no new account')
   if op=='finish':
    finishes.append(1);return {}
   raise AssertionError('unexpected phoneFlow op: %r'%(op,))
  lua=LuaRuntime(unpack_returned_tuples=True);_lua_runtime(lua);lua.globals()['phoneFlow']=phoneflow
  with self.assertRaisesRegex(Exception,'no new account'):lua.execute(SCRIPT)
  self.assertEqual(len(begins),2)
  self.assertEqual(len(finishes),1)
 def test_loop_continues_after_blocked_or_review_account(self):
  # 场景一：服务端阻止（blocked）记录后进入下一个账号
  begins=[];blocked=[];finishes=[]
  def blocked_flow(op):
   if op=='begin':
    begins.append(1)
    first=len(begins)==1
    return {'state':'blocked' if first else 'ready','next':0 if first else 14,'email':'blocked@example.com' if first else 'next@example.com','job':''}
   if op=='blocked':
    blocked.append(1);return {}
   if op=='finish':
    finishes.append(1);return {}
   raise AssertionError('unexpected phoneFlow op: %r'%(op,))
  lua=LuaRuntime(unpack_returned_tuples=True);_lua_runtime(lua);lua.globals()['phoneFlow']=blocked_flow
  lua.execute(SCRIPT)
  self.assertEqual(len(begins),2)
  self.assertEqual(len(blocked),1)
  self.assertEqual(len(finishes),1)
  # 场景二：结果待核对（review 且不在验证码页）后进入下一个账号
  begins=[];finishes=[];job_status=[]
  def review_flow(op):
   if op=='begin':
    begins.append(1)
    first=len(begins)==1
    return {'state':'ready','next':13 if first else 14,'email':'review@example.com' if first else 'next@example.com','job':'job1' if first else ''}
   if op=='job_status':
    job_status.append(1);return {'state':'review'}
   if op=='finish':
    finishes.append(1);return {}
   raise AssertionError('unexpected phoneFlow op: %r'%(op,))
  lua=LuaRuntime(unpack_returned_tuples=True);_lua_runtime(lua);lua.globals()['phoneFlow']=review_flow
  lua.execute(SCRIPT)
  self.assertEqual(len(begins),2)
  self.assertEqual(len(job_status),1)
  self.assertEqual(len(finishes),1)
 def test_rerun_of_completed_account_has_no_ui_side_effects(self):
  begins=[];finishes=[]
  def phoneflow(op):
   if op=='begin':
    begins.append(1)
    return {'state':'done','next':14,'email':'done@example.com','job':''}
   if op=='finish':
    finishes.append(1);return {}
   raise AssertionError('unexpected phoneFlow op: %r'%(op,))
  lua=LuaRuntime(unpack_returned_tuples=True);_lua_runtime(lua);lua.globals()['phoneFlow']=phoneflow
  lua.execute(SCRIPT)
  self.assertEqual(len(begins),2)
  self.assertEqual(finishes,[])
 def _run_slider(self,icon_hits,handle_hits,retry_hits):
  marker="parts['slider']=function()\n"
  start=SCRIPT.index(marker)+len(marker)
  chunk=SCRIPT[start:SCRIPT.index('-- 滑块部分结束',start)]
  logs=[];touches={'down':[],'move':[],'up':[],'tap':[]};sleeps=[]
  queues={'PHONE_slider_shield.png':list(icon_hits),'PHONE_slider_handle.png':list(handle_hits),'PHONE_slider_retry.png':list(retry_hits)}
  lua=LuaRuntime(unpack_returned_tuples=True)
  def hits_table(*items):
   return lua.table_from([lua.table_from(list(item)) for item in items])
  def findImage(name,sim,region=None):
   queue=queues.get(name,[])
   return hits_table(*queue.pop(0)) if queue else hits_table()
  lua.execute('screenWidth=function() return 414 end;screenHeight=function() return 896 end')
  lua.globals()['log']=lambda *a: logs.append(' '.join(str(x) for x in a))
  lua.globals()['findImage']=findImage
  lua.globals()['tap']=lambda x,y: touches['tap'].append((x,y))
  lua.globals()['touchDown']=lambda i,x,y: touches['down'].append((x,y))
  lua.globals()['touchMove']=lambda i,x,y: touches['move'].append((x,y))
  lua.globals()['touchUp']=lambda i,x,y: touches['up'].append((x,y))
  lua.globals()['msleep']=lambda ms: sleeps.append(ms)
  lua.execute(chunk)
  return logs,touches,sleeps
 def test_slider_part_passes_on_first_drag(self):
  logs,touches,sleeps=self._run_slider([[[203,222,0.91]]],[[[98,485,0.9]]],[])
  self.assertIn('SLIDER_DETECTED',logs)
  self.assertIn('SLIDER_PASSED',logs)
  self.assertEqual(len(touches['down']),1)
  self.assertEqual(len(touches['up']),1)
  self.assertGreaterEqual(len(touches['move']),4)
  sx,sy=touches['down'][0]
  self.assertTrue(95<=sx<=101 and 482<=sy<=488,(sx,sy))
  final_x,final_y=touches['move'][-1]
  self.assertTrue(314<=final_x<=326,(final_x,final_y))
  deltas=[touches['move'][i+1][0]-touches['move'][i][0] for i in range(len(touches['move'])-1)]
  self.assertGreaterEqual(len(set(deltas)),2,'拖动应有变速')
  self.assertGreaterEqual(len(set(y for _,y in touches['move'])),2,'拖动应有像素抖动')
 def test_slider_part_follows_handle_when_default_position_moved(self):
  logs,touches,sleeps=self._run_slider([[[203,222,0.91]]],[[[176,485,0.9]]],[])
  self.assertIn('SLIDER_PASSED',logs)
  sx,sy=touches['down'][0]
  self.assertTrue(173<=sx<=179,(sx,sy))
  final_x,_=touches['move'][-1]
  self.assertTrue(392<=final_x<=404,'终点应=新手柄位置+222，实际 %r'%final_x)
 def test_slider_part_taps_retry_waits_and_passes(self):
  logs,touches,sleeps=self._run_slider([[[203,222,0.9]]],[[[98,485,0.9]],[[98,485,0.9]]],[[[207,457]],[]])
  self.assertIn('SLIDER_RETRY_TAPPED',logs)
  self.assertIn('SLIDER_PASSED',logs)
  self.assertEqual(touches['tap'],[(207,457)])
  self.assertIn(10000,sleeps)
 def test_slider_part_no_icon_does_nothing(self):
  logs,touches,sleeps=self._run_slider([[]],[[]],[[]])
  self.assertNotIn('SLIDER_DETECTED',logs)
  self.assertEqual(touches['down'],[])
  self.assertEqual(touches['move'],[])
  self.assertEqual(touches['up'],[])
  self.assertEqual(touches['tap'],[])

@unittest.skipUnless(sys.platform=='darwin','requires macOS Foundation')
class PhoneFlowNative(unittest.TestCase):
 def test_mail_and_durable_checkpoints(self):
  with tempfile.TemporaryDirectory() as directory:
   exe=Path(directory)/'flow-test'
   p=subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(ROOT/'tests/native_phone_flow.m'),str(ROOT/'shared/ATLPhoneFlow.m'),str(ROOT/'shared/ATLRegistrationJob.m'),'-o',str(exe)],capture_output=True,text=True,timeout=60)
   self.assertEqual(p.returncode,0,p.stderr)
   p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=20)
   self.assertEqual(p.returncode,0,p.stderr)
