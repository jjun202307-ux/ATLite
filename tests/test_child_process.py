import pathlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]

class ChildProcess(unittest.TestCase):
 def test_real_process_deadline_cancel_and_output(self):
  header=ROOT/'shared/ATLChildProcess.h'
  self.assertTrue(header.exists(),'missing bounded production child-process supervisor')
  cc=shutil.which('cc')
  if not cc:self.skipTest('C compiler required')
  code=r'''#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
static int forceReadError;
static ssize_t failingRead(int fd,void *b,size_t n) { if(forceReadError){errno=EIO;return -1;}return read(fd,b,n); }
#define read failingRead
#include "ATLChildProcess.h"
#undef read
static double cancelAt;
static int cancelled(void *p) { (void)p;return ATLChildNow()>=cancelAt; }
int main(int argc,char **argv) {
 if(argc>2 && !strcmp(argv[1],"--request-id")) {
  const char *mode=argv[2];
  if(!strcmp(mode,"hang") || !strcmp(mode,"cancel")) { sleep(30);return 0; }
  if(!strcmp(mode,"signal")) { raise(SIGTERM);return 1; }
  if(!strcmp(mode,"exit"))return 7;
  if(!strcmp(mode,"large")) { char b[4096];memset(b,'x',sizeof(b));for(int i=0;i<20;i++)write(1,b,sizeof(b));return 0; }
  char b[6]={0};assert(read(0,b,5)==5 && !strcmp(b,"input"));assert(write(1,"output",6)==6);return 0;
 }
 char path[]="/tmp/atl-child-XXXXXX";int fd=mkstemp(path);assert(fd>=0);unlink(path);assert(write(fd,"input",5)==5);
 char out[256];lseek(fd,0,SEEK_SET);
 ATLChildResult r=ATLRunChild(argv[0],"ok",fd,out,sizeof(out)-1,1,NULL,NULL);
 assert(r.status==ATL_CHILD_OK && r.reaped && r.exitCode==0 && r.length==6 && !memcmp(out,"output",6));
 r=ATLRunChild("/missing/ATLWorker","ok",fd,out,sizeof(out)-1,1,NULL,NULL);assert(r.status==ATL_CHILD_SPAWN_FAILED && !r.spawned);
 r=ATLRunChild(argv[0],"exit",fd,out,sizeof(out)-1,1,NULL,NULL);assert(r.status==ATL_CHILD_EXIT_FAILED && r.exitCode==7 && r.reaped);
 r=ATLRunChild(argv[0],"signal",fd,out,sizeof(out)-1,1,NULL,NULL);assert(r.status==ATL_CHILD_SIGNALED && r.signal==SIGTERM && r.reaped);
 double before=ATLChildNow();r=ATLRunChild(argv[0],"hang",fd,out,sizeof(out)-1,.15,NULL,NULL);assert(r.status==ATL_CHILD_TIMEOUT && r.reaped && ATLChildNow()-before<1);
 cancelAt=ATLChildNow()+.05;r=ATLRunChild(argv[0],"cancel",fd,out,sizeof(out)-1,1,cancelled,NULL);assert(r.status==ATL_CHILD_CANCELLED && r.reaped);
 r=ATLRunChild(argv[0],"large",fd,out,sizeof(out)-1,1,NULL,NULL);assert(r.status==ATL_CHILD_OUTPUT_LIMIT && r.reaped && r.length<=sizeof(out)-1);
 forceReadError=1;r=ATLRunChild(argv[0],"hang",fd,out,sizeof(out)-1,1,NULL,NULL);forceReadError=0;
 assert(r.status==ATL_CHILD_IO_ERROR && r.systemError==EIO && r.reaped);
 int savedIn=dup(0),savedOut=dup(1);close(0);close(1);lseek(fd,0,SEEK_SET);
 r=ATLRunChild(argv[0],"ok",fd,out,sizeof(out)-1,1,NULL,NULL);
 dup2(savedIn,0);dup2(savedOut,1);close(savedIn);close(savedOut);
 assert(r.status==ATL_CHILD_OK && r.reaped && r.length==6);
 close(fd);return 0;
}'''
  with tempfile.TemporaryDirectory() as d:
   src=pathlib.Path(d)/'child.c';src.write_text(code);exe=src.with_suffix('')
   subprocess.run([cc,'-std=gnu11','-Wall','-Wextra','-Werror','-I',str(ROOT/'shared'),str(src),'-o',str(exe)],check=True)
   subprocess.run([str(exe)],check=True,timeout=10)
