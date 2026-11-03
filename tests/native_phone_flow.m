#import <Foundation/Foundation.h>
#import "../shared/ATLPhoneFlow.h"
#import <sys/stat.h>
static void expireRetry(NSString *base){NSString *path=[base stringByAppendingPathComponent:@"PhoneFlow/registration-job.json"];NSMutableDictionary *s=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil] mutableCopy];s[@"retryAfter"]=@0;[[NSJSONSerialization dataWithJSONObject:s options:0 error:nil] writeToFile:path atomically:YES];chmod(path.fileSystemRepresentation,0600);}
int main(){@autoreleasepool{
 NSCAssert([ATLPhoneMailCode(@"Your verification code is 012345") isEqual:@"012345"],@"leading zero");
 NSCAssert(ATLPhoneMailCode(@"Order 123456, 2026/11/03")==nil,@"unrelated digits");
 NSCAssert(ATLPhoneMailCode(@"verification code 123456 security code 654321")==nil,@"ambiguous");
 NSCAssert(ATLPhoneMailNewCode(@"Verification code 123456 footer changed",@"123456")==nil,@"cosmetic changes do not make old code fresh");
 NSCAssert([ATLPhoneMailCode(@"&lt;b&gt;Verification code&lt;/b&gt; 0123") isEqual:@"0123"],@"HTML");
 NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];NSString *files=[base stringByAppendingPathComponent:@"Local/Files"];
 [NSFileManager.defaultManager createDirectoryAtPath:files withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 NSError *error=nil;NSCAssert(!ATLPhoneFlow(base,@"begin",0,nil,&error),@"missing config must stop");
 NSString *path=[files stringByAppendingPathComponent:@"config.txt"];
 [@"[phone]\nEMAIL=demo@example.invalid\nPICKUP_API=https://api.wdmail.top/m?e=other@example.invalid\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];chmod(path.fileSystemRepresentation,0600);
 NSCAssert(!ATLPhoneFlow(base,@"begin",0,nil,&error),@"mismatched mailbox must stop before UI");
 [@"[phone]\nEMAIL=demo@example.invalid\nPICKUP_API=https://api.wdmail.top/m?e=demo@example.invalid\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];chmod(path.fileSystemRepresentation,0600);
 NSString *results=[files stringByAppendingPathComponent:@"results.txt"];unsigned char invalid[]={0xff};[[NSData dataWithBytes:invalid length:1] writeToFile:results atomically:YES];chmod(results.fileSystemRepresentation,0600);
 NSCAssert(!ATLPhoneFlow(base,@"begin",0,nil,&error),@"invalid result file must stop before preparation");[NSFileManager.defaultManager removeItemAtPath:results error:nil];
 NSDictionary *s=ATLPhoneFlow(base,@"begin",0,nil,&error);NSCAssert([s[@"next"] integerValue]==0 && [s[@"state"] isEqual:@"ready"],@"start");
 NSCAssert(ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"first attempt");
 NSCAssert(!ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"no replay of running side effect");
 NSCAssert(ATLPhoneFlow(base,@"stage_failed",0,nil,&error),@"failed");
 NSCAssert(!ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"restart cannot bypass fifteen seconds");expireRetry(base);
 NSCAssert(ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"second attempt");
 NSCAssert(ATLPhoneFlow(base,@"stage_failed",0,nil,&error),@"failed2");
 expireRetry(base);
 NSCAssert(ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"third attempt");
 NSCAssert(ATLPhoneFlow(base,@"stage_failed",0,nil,&error),@"failed3");
 expireRetry(base);
 NSCAssert(!ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"persisted three attempts");
 NSCAssert(!ATLPhoneFlow(base,@"stage_done",1,nil,&error),@"wrong stage rejected");
 [NSFileManager.defaultManager removeItemAtPath:base error:nil];return 0;
}}
