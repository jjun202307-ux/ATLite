"""Capture watchdog must start after screen-size measurement."""
import pathlib, unittest, re, sys, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
class CaptureTimeoutContract(unittest.TestCase):
    def test_measurement_precedes_capture_dispatch(self):
        s=(ROOT / "tweak/Tweak.xm").read_text(encoding="utf-8")
        section=s[s.index("static IOSurfaceRef ATCaptureSurfaceWithTimeout(void)"):s.index("// 抓主屏 → RGBA8")]
        self.assertIn("ATScreenPixelSize()", section)
        self.assertLess(section.index("ATScreenPixelSize()"), section.index("dispatch_async(gCaptureQueue"))
        self.assertIn("ATRenderIntoNewSurface(px)", section)
    @unittest.skipUnless(sys.platform == "darwin", "requires macOS Foundation; CI executes this")
    def test_dispatch_timeout_recovery_and_late_release(self):
        source=(ROOT / "tweak/Tweak.xm").read_text(encoding="utf-8")
        match=re.search(r"static IOSurfaceRef ATCaptureSurfaceWithTimeout\(void\) \{.*?\n\}", source, re.S)
        self.assertIsNotNone(match)
        code=r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <unistd.h>
static dispatch_queue_t gCaptureQueue;
static BOOL gCaptureBroken=NO;
#define AT_CAPTURE_TIMEOUT_SEC 0.05
static int renderMode=0;
static dispatch_queue_t sizeQueue;
static dispatch_semaphore_t sizeUnblock;
static dispatch_semaphore_t unblock, released;
@interface SurfaceToken : NSObject @end
@implementation SurfaceToken
- (void)dealloc { dispatch_semaphore_signal(released); }
@end
static void ATLog(NSString *format, ...) {}
static CGSize ATScreenPixelSize(void) {
 __block CGSize px=CGSizeZero; dispatch_semaphore_t done=dispatch_semaphore_create(0);
 dispatch_async(sizeQueue, ^{ px=CGSizeMake(3,2); dispatch_semaphore_signal(done); });
 if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,0.05*NSEC_PER_SEC))) return CGSizeZero;
 return px;
}
static IOSurfaceRef ATRenderIntoNewSurface(CGSize px) {
 assert(px.width==3 && px.height==2);
 if(renderMode) dispatch_semaphore_wait(unblock, DISPATCH_TIME_FOREVER);
 return (IOSurfaceRef)CFBridgingRetain([SurfaceToken new]);
}
'''+match.group(0)+r'''
int main() { @autoreleasepool {
 unblock=dispatch_semaphore_create(0); released=dispatch_semaphore_create(0);
 sizeUnblock=dispatch_semaphore_create(0); sizeQueue=dispatch_queue_create("size-test",DISPATCH_QUEUE_SERIAL);
 dispatch_async(sizeQueue, ^{ dispatch_semaphore_wait(sizeUnblock,DISPATCH_TIME_FOREVER); });
 assert(!ATCaptureSurfaceWithTimeout()); assert(!gCaptureBroken);
 dispatch_semaphore_signal(sizeUnblock); IOSurfaceRef ok=ATCaptureSurfaceWithTimeout(); assert(ok); CFRelease(ok);
 assert(dispatch_semaphore_wait(released,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 renderMode=1; assert(!ATCaptureSurfaceWithTimeout()); assert(gCaptureBroken);
 assert(!ATCaptureSurfaceWithTimeout()); dispatch_semaphore_signal(unblock);
 assert(dispatch_semaphore_wait(released,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 puts("watchdog behavior OK"); return 0;
}}
'''
        with tempfile.TemporaryDirectory() as tmp:
            f=pathlib.Path(tmp)/"watchdog.mm"; f.write_text(code,encoding="utf-8")
            exe=pathlib.Path(tmp)/"watchdog"
            p=subprocess.run(["clang++","-std=gnu++11","-fobjc-arc","-framework","Foundation","-framework","CoreGraphics",str(f),"-o",str(exe)],capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=5)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            self.assertIn("watchdog behavior OK",p.stdout)
if __name__ == "__main__": unittest.main()
