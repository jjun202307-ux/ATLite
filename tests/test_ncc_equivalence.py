import pathlib,shutil,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class NCCEquivalence(unittest.TestCase):
 def test_pruning_matches_brute_force(self):
  cc=shutil.which('cc')
  if not cc:self.skipTest('C compiler required')
  code=r'''#include "ATCore.h"
#include <assert.h>
static double brute(const uint8_t*h,int hw,int hh,const uint8_t*t,int nw,int nh,int*ox,int*oy){double best=-2,mean=0,tvar=0;int n=nw*nh;for(int i=0;i<n;i++)mean+=t[i];mean/=n;for(int i=0;i<n;i++){double d=t[i]-mean;tvar+=d*d;}for(int y=0;y<=hh-nh;y++)for(int x=0;x<=hw-nw;x++){double sum=0,sq=0,num=0;for(int j=0;j<nh;j++)for(int i=0;i<nw;i++){double v=h[(y+j)*hw+x+i];sum+=v;sq+=v*v;num+=v*(t[j*nw+i]-mean);}double var=sq-sum*sum/n;if(var>1e-6){double score=num/sqrt(var*tvar);if(score>best){best=score;*ox=x;*oy=y;}}}return best;}
int main(void){uint8_t h[32*35],t[13*14];unsigned state=17;for(int trial=0;trial<100;trial++){int nw=2+trial%12,nh=2+(trial*7)%13;for(int i=0;i<32*35;i++){state=state*1664525u+1013904223u;h[i]=state>>24;}for(int i=0;i<nw*nh;i++){state=state*1664525u+1013904223u;t[i]=state>>24;}int bx=-1,by=-1,x=-1,y=-1;double score=0,expected=brute(h,32,35,t,nw,nh,&bx,&by);double threshold=trial%2?.9:.1;int found=ATCoreNCCBest(h,32,35,t,nw,nh,threshold,&x,&y,&score,0,0);assert(found==(expected>=threshold));if(found)assert(x==bx&&y==by&&fabs(score-expected)<1e-8);}return 0;}
'''
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)/'test.c';p.write_text(code);exe=p.with_suffix('')
   subprocess.run([cc,'-O2','-I',str(ROOT/'tweak'),str(p),'-lm','-o',str(exe)],check=True)
   subprocess.run([str(exe)],check=True,timeout=10)
