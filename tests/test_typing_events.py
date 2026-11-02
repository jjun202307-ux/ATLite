"""Compile actual keyboard helper functions with deterministic HID stubs."""
import pathlib, shutil, subprocess, sys, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
@unittest.skipUnless(shutil.which('clang') or shutil.which('cc'), 'requires a C compiler')
class TypingEvents(unittest.TestCase):
 def test_corrected_character_events_and_no_correction(self):
  text=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
  helpers=text[text.index('static BOOL ATTypeASCIICharacter'):text.index('static int l_inputBackspace')]
  source=r'''
#include <assert.h>
#include <stdint.h>
typedef int BOOL;
typedef struct {} lua_State;
#define YES 1
#define NO 0
static unsigned int choice=0, pauses=0, count=0;
static unsigned int events[16];
unsigned int arc4random_uniform(unsigned int bound) { (void)bound; return choice; }
static void ATTypingPause(lua_State *L) { (void)L; ++pauses; }
static BOOL ATASCIIKeyEvent(BOOL down,uint16_t key) { events[count++]=(down?0x100:0)|key;return YES; }
'''+helpers+r'''
int main(void) {
 assert(ATTypingMaybeCorrect(0,4,1));
 unsigned int expected[]={0x12a,0x02a,0x1e1,0x104,0x004,0x0e1};
 assert(count==6 && pauses==2);
 for(unsigned int i=0;i<6;i++) assert(events[i]==expected[i]);
 choice=1;count=pauses=0;assert(ATTypingMaybeCorrect(0,4,1));assert(count==0 && pauses==0);
 return 0;
}
'''
  with tempfile.TemporaryDirectory() as t:
   c=pathlib.Path(t)/'test.c';exe=pathlib.Path(t)/'test';c.write_text(source,encoding='utf-8')
   p=subprocess.run([shutil.which('clang') or shutil.which('cc'),str(c),'-o',str(exe)],capture_output=True,text=True,timeout=30)
   self.assertEqual(p.returncode,0,p.stderr)
   p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10);self.assertEqual(p.returncode,0,p.stderr)
