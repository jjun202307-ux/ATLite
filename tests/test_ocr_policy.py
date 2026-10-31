"""Check production Vision request configuration, then exercise its native bridge on macOS.
The hardware implementation is replaced; actual CoreML behavior requires the phone.
"""
import pathlib, subprocess, sys, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]

class OCRPolicy(unittest.TestCase):
    def test_springboard_ocr_uses_cpu(self):
        source=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        body=source[source.index('static BOOL ATRecognizeScreen'):source.index('static int l_findText')]
        self.assertTrue('request.usesCPUOnly = YES;' in body,
                        'SpringBoard OCR must avoid the device-failing accelerated path')

    @unittest.skipUnless(sys.platform=='darwin','requires macOS Foundation and CoreGraphics')
    def test_production_ocr_configuration_and_cleanup(self):
        source=(ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        start=source.index('typedef struct { char text[512]')
        body=source[start:source.index('static int l_findText',start)]
        code=r'''#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
typedef struct { unsigned char *rgba; int w,h; } ATBitmap;
static int captures,freed,calls,fail;
static BOOL ATCaptureScreen(ATBitmap *b) { captures++;b->w=100;b->h=200;b->rgba=calloc(100*200,4);return YES; }
static void ATFreeBitmap(ATBitmap *b) { free(b->rgba);freed++; }
static double ATCaptureScale(const ATBitmap *b) { return 2; }
static CGImageRef ATCreateCGImageFromBitmap(const ATBitmap *b) {
 CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
 CGContextRef c=CGBitmapContextCreate(b->rgba,b->w,b->h,8,b->w*4,cs,kCGImageAlphaPremultipliedLast);
 CGImageRef im=CGBitmapContextCreateImage(c);CGContextRelease(c);CGColorSpaceRelease(cs);return im;
}
static void ATLog(NSString *format,...) {}
@interface VNRecognizedText : NSObject
@property CGRect boundingBox;
@property NSString *string;
@property float confidence;
- (NSArray *)topCandidates:(NSUInteger)n;
@end
@implementation VNRecognizedText
- (NSArray *)topCandidates:(NSUInteger)n { return @[self]; }
@end
@interface VNRequest : NSObject
@property NSArray *results;
@end
@implementation VNRequest @end
@interface VNRecognizeTextRequest : VNRequest
@property BOOL usesCPUOnly,usesLanguageCorrection;
@property NSInteger recognitionLevel;
@property NSArray *recognitionLanguages;
@property(copy) void(^completion)(VNRequest*,NSError*);
- (instancetype)initWithCompletionHandler:(void(^)(VNRequest*,NSError*))block;
@end
@implementation VNRecognizeTextRequest
- (instancetype)initWithCompletionHandler:(void(^)(VNRequest*,NSError*))block { self=[super init];if(self)self.completion=block;return self; }
@end
enum { VNRequestTextRecognitionLevelAccurate=0 };
@interface VNImageRequestHandler : NSObject
- (instancetype)initWithCGImage:(CGImageRef)image options:(NSDictionary*)options;
- (BOOL)performRequests:(NSArray*)requests error:(NSError**)error;
@end
@implementation VNImageRequestHandler
- (instancetype)initWithCGImage:(CGImageRef)image options:(NSDictionary*)options { NSCAssert(image,@"real CGImage");return [super init]; }
- (BOOL)performRequests:(NSArray*)requests error:(NSError**)error {
 calls++;VNRecognizeTextRequest *r=requests.firstObject;
 NSCAssert(r.usesCPUOnly && !r.usesLanguageCorrection,@"CPU policy and literal email text");
 NSCAssert([r.recognitionLanguages isEqual:@[@"zh-Hans",@"en-US"]],@"languages preserved");
 if(fail) { *error=[NSError errorWithDomain:@"test" code:1 userInfo:nil];return NO; }
 VNRecognizedText *t=[VNRecognizedText new];t.string=@"Username: ATLiteDebug";t.boundingBox=CGRectMake(.1,.2,.4,.3);t.confidence=.9;r.results=@[t];r.completion(r,nil);return YES;
}
@end
'''+body+r'''
int main(void) { @autoreleasepool {
 ATTextResult result={0};NSCAssert(ATRecognizeScreen(&result),@"OCR success");
 NSCAssert(result.count==1 && !strcmp(result.lines[0].text,"Username: ATLiteDebug"),@"recognized text returned");
 NSCAssert(result.lines[0].x==5 && result.lines[0].width==20,@"point coordinate scale");
 fail=1;result=(ATTextResult){0};NSCAssert(!ATRecognizeScreen(&result),@"OCR error remains failure");
 NSCAssert(calls==2 && captures==2 && freed==2,@"native bitmap released on both paths");return 0;
} }
'''
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'ocr.m';p.write_text(code,encoding='utf-8');exe=p.with_suffix('')
            subprocess.run(['clang','-fobjc-arc','-fblocks','-framework','Foundation','-framework','CoreGraphics',str(p),'-o',str(exe)],check=True)
            subprocess.run([str(exe)],check=True,timeout=15)
