import pathlib, subprocess, sys, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class OCRReply(unittest.TestCase):
 def test_reply_validation_native(self):
  self.assertTrue((ROOT/'shared/ATLOCRReply.h').exists(),'missing bounded request-correlated OCR reply validation')
  if sys.platform!='darwin':self.skipTest('Foundation requires macOS')
  code=r'''#import <Foundation/Foundation.h>
#import "ATLOCRReply.h"
int main(void) { @autoreleasepool {
 NSDictionary *line=@{@"text":@"用户名：测试用户",@"x":@.1,@"y":@.2,@"width":@.4,@"height":@.1,@"confidence":@.9};
 NSMutableDictionary *reply=[@{@"version":@1,@"requestId":@"test",@"ok":@YES,@"mode":@"accurate",@"languages":@[@"zh-Hans",@"en-US"],@"lines":@[line]} mutableCopy];
 ATTextResult result={0};NSString *error=nil;
 NSData *(^encode)(void)=^{return [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];};
 NSCAssert(ATLDecodeOCRReply(encode(),@"test",828,1792,2,&result,&error),@"valid reply");
 NSCAssert(result.count==1 && fabs(result.lines[0].x-41.4)<.001 && !strcmp(result.lines[0].text,"用户名：测试用户"),@"point conversion and UTF8");
 NSCAssert(!ATLDecodeOCRReply(encode(),@"old",828,1792,2,&result,&error),@"reject other request");
 reply[@"lines"]=@[@{@"text":@"bad",@"x":@"0.1",@"y":@0,@"width":@1,@"height":@1,@"confidence":@1}];
 NSCAssert(!ATLDecodeOCRReply(encode(),@"test",828,1792,2,&result,&error),@"reject numeric strings");
 reply[@"lines"]=@[@{@"text":@"bad",@"x":@.9,@"y":@0,@"width":@.5,@"height":@1,@"confidence":@1}];
 NSCAssert(!ATLDecodeOCRReply(encode(),@"test",828,1792,2,&result,&error),@"reject out of frame boxes");
 reply[@"lines"]=@{};NSCAssert(!ATLDecodeOCRReply(encode(),@"test",828,1792,2,&result,&error),@"reject malformed lines");
 reply[@"ok"]=@NO;reply[@"errorMessage"]=@"model unavailable";
 NSCAssert(!ATLDecodeOCRReply(encode(),@"test",828,1792,2,&result,&error) && [error isEqual:@"model unavailable"],@"worker failure never becomes empty success");
 NSCAssert(!ATLDecodeOCRReply([NSData dataWithBytes:"bad" length:3],@"test",828,1792,2,&result,&error),@"invalid JSON");
 return 0;
} }'''
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)/'reply.m';p.write_text(code,encoding='utf-8');exe=p.with_suffix('')
   subprocess.run(['clang','-fobjc-arc','-fblocks','-framework','Foundation','-I',str(ROOT/'shared'),str(p),'-o',str(exe)],check=True)
   subprocess.run([str(exe)],check=True,timeout=10)
