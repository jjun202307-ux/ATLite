#import <Foundation/Foundation.h>
#import "../shared/ATLPhoneFlow.h"
#import "../shared/ATLRegistrationJob.h"
#import <sys/stat.h>
#import <dispatch/dispatch.h>
// 记录已应答过的 nonce：多场景连续调用时，磁盘上的 request 可能是上一场景的残留，
// 必须跳过旧 nonce 等本轮 begin 写出的新 request，否则本轮永远等不到匹配回复(11-05 CI 实证超时)。
static NSString *gAnsweredNonce=nil;
static void workbenchReply(NSString *files,NSString *email){
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
  // PFWorkbench 原生等待上限 20 秒；辅助线程窗口必须更长，否则高负载 CI 运行器上
  // begin 还没写出 request 轮询就已结束，PFWorkbench 干等满 20s 撞测试超时(11-05 实证)。
  for(int i=0;i<800;i++){
   NSString *path=[files stringByAppendingPathComponent:@"workbench-request.json"];
   NSDictionary *r=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path]?:[NSData data] options:0 error:nil];
   if(r[@"nonce"] && ![r[@"nonce"] isEqual:gAnsweredNonce]){
    NSDictionary *reply=@{@"nonce":r[@"nonce"],@"ok":@YES,@"replace":@YES,@"old_email":r[@"email"],@"old_job":r[@"job"],@"old_status":@"done",@"config":@{@"EMAIL":email,@"PICKUP_API":[@"https://api.wdmail.top/m?e=" stringByAppendingString:email],@"USERNAME":@"",@"PASSWORD":@"",@"FULL_NAME":@"",@"COUNTRY":@"美国",@"ZIP":@"11714"}};
    // 与管理器一致: 先写临时文件并 chmod 0600, 再 rename 覆盖, rename 保持权限无竞态窗口。
    // 注意 moveItemAtPath 对已存在目标可能报错, 先删除再移动, 并打日志便于 CI 诊断。
    NSString *out=[files stringByAppendingPathComponent:@"workbench-reply.json"];
    NSString *tmp=[files stringByAppendingPathComponent:@"workbench-reply.json.tmp"];
    NSData *rd=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if(![rd writeToFile:tmp atomically:NO]){fprintf(stderr,"helper: tmp write failed\n");return;}
    chmod(tmp.fileSystemRepresentation,0600);
    [NSFileManager.defaultManager removeItemAtPath:out error:nil];
    NSError *moveErr=nil;
    if(![NSFileManager.defaultManager moveItemAtPath:tmp toPath:out error:&moveErr]){fprintf(stderr,"helper: move failed: %s\n",moveErr.localizedDescription.UTF8String);return;}
    fprintf(stderr,"helper: replied nonce %s\n",((NSString *)r[@"nonce"]).UTF8String);
    gAnsweredNonce=r[@"nonce"];return;
   }
   [NSThread sleepForTimeInterval:0.05];
  }
  fprintf(stderr,"helper: gave up waiting for fresh request\n");
 });
}
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
 NSCAssert(ATLPhoneFlow(base,@"begin",0,nil,&error),@"provider URL is user configured");[NSFileManager.defaultManager removeItemAtPath:[base stringByAppendingPathComponent:@"PhoneFlow/registration-job.json"] error:nil];
 [@"[phone]\nEMAIL=demo@example.invalid\nPICKUP_API=https://api.wdmail.top/m?e=demo@example.invalid\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];chmod(path.fileSystemRepresentation,0600);
 NSString *results=[files stringByAppendingPathComponent:@"results.txt"];unsigned char invalid[]={0xff};[[NSData dataWithBytes:invalid length:1] writeToFile:results atomically:YES];chmod(results.fileSystemRepresentation,0600);
 NSCAssert(!ATLPhoneFlow(base,@"begin",0,nil,&error),@"invalid result file must stop before preparation");[NSFileManager.defaultManager removeItemAtPath:results error:nil];
 NSDictionary *s=ATLPhoneFlow(base,@"begin",0,nil,&error);NSCAssert([s[@"next"] integerValue]==0 && [s[@"state"] isEqual:@"ready"],@"start");
 NSCAssert(ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"first attempt");
 
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
 NSString *reg=[base stringByAppendingPathComponent:@"Registration"];
 [NSFileManager.defaultManager createDirectoryAtPath:reg withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 NSDictionary *payload=@{@"id":@"stale-wait-code",@"email":@"demo@example.invalid",@"username":@"demo_user12",@"password":@"DummyPass123",@"fullName":@"Demo User",@"zip":@"99999",@"pickup_api":@"https://api.wdmail.top/m?e=demo@example.invalid",@"country":@"美国"};
 NSCAssert(ATLRegistrationCreate(reg,payload,&error),@"create stale fixture");NSCAssert(ATLRegistrationClaimPending(reg,&error),@"claim stale fixture");
 NSCAssert(ATLRegistrationAdvance(reg,@"stale-wait-code",ATL_REG_FIELDS_READY,&error),@"fields");NSCAssert(ATLRegistrationAdvance(reg,@"stale-wait-code",ATL_REG_BEGIN_SUBMIT,&error),@"submit");NSCAssert(ATLRegistrationAdvance(reg,@"stale-wait-code",ATL_REG_VERIFICATION_SEEN,&error),@"wait_code");
 NSString *flowPath=[base stringByAppendingPathComponent:@"PhoneFlow/registration-job.json"];
 NSMutableDictionary *stale=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:flowPath] options:0 error:nil] mutableCopy];stale[@"job"]=@"stale-wait-code";stale[@"next"]=@13;stale[@"state"]=@"running";
 [[NSJSONSerialization dataWithJSONObject:stale options:0 error:nil] writeToFile:flowPath atomically:YES];chmod(flowPath.fileSystemRepresentation,0600);
 NSString *marker=[files stringByAppendingPathComponent:@"workbench.enabled"];[@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];chmod(marker.fileSystemRepresentation,0600);
 workbenchReply(files,@"new@example.invalid");
 NSDictionary *fresh=ATLPhoneFlow(base,@"begin",0,nil,&error);
 NSCAssert(fresh && [fresh[@"next"] integerValue]==0 && [fresh[@"email"] isEqual:@"new@example.invalid"],@"workbench terminal account must archive and start fresh: %@",error);
 NSCAssert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:[base stringByAppendingPathComponent:@"PhoneFlow"] error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'archived-'"]].count==1,@"old state retained");
 NSCAssert([NSFileManager.defaultManager contentsOfDirectoryAtPath:[reg stringByAppendingPathComponent:@"Retired"] error:nil].count==1,@"stale wait_code retained in archive");
 NSCAssert(ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"first step");NSCAssert(ATLPhoneFlow(base,@"stage_begin",0,nil,&error),@"stopped running checkpoint can resume within retry count");
 // 场景A（2026-11-05 规则）：无断点 + 残留注册任务 → 按失败归档后开始新账号，不再拒绝
 [NSFileManager.defaultManager removeItemAtPath:flowPath error:nil];
 NSMutableDictionary *payload2=[payload mutableCopy];payload2[@"id"]=@"stale-pending-2";
 NSCAssert(ATLRegistrationCreate(reg,payload2,&error),@"create second stale fixture");
 workbenchReply(files,@"second@example.invalid");
 NSDictionary *second=ATLPhoneFlow(base,@"begin",0,nil,&error);
 NSCAssert(second && [second[@"email"] isEqual:@"second@example.invalid"] && [second[@"next"] integerValue]==0,@"orphaned registration job must be archived as failed and the new account must start: %@",error);
 NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:[reg stringByAppendingPathComponent:@"registration-job.json"]],@"stale registration job cleared");
 NSCAssert([NSFileManager.defaultManager contentsOfDirectoryAtPath:[reg stringByAppendingPathComponent:@"Retired"] error:nil].count==2,@"stale pending job archived");
 // 场景B：断点内容损坏（权限正确）→ rename 旁路归档后开始新账号，原文件保留可查
 unsigned char junk[]={0xff,0xfe};[[NSData dataWithBytes:junk length:2] writeToFile:flowPath atomically:YES];chmod(flowPath.fileSystemRepresentation,0600);
 workbenchReply(files,@"third@example.invalid");
 NSDictionary *third=ATLPhoneFlow(base,@"begin",0,nil,&error);
 NSCAssert(third && [third[@"email"] isEqual:@"third@example.invalid"] && [third[@"state"] isEqual:@"ready"],@"corrupt checkpoint must be bypassed and archived: %@",error);
 NSCAssert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:[base stringByAppendingPathComponent:@"PhoneFlow"] error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'archived-corrupt-'"]].count==1,@"corrupt checkpoint preserved as archive");
 [NSFileManager.defaultManager removeItemAtPath:marker error:nil];
 [@"[phone]\nEMAIL=local@example.invalid\nPICKUP_API=http://mail.example.invalid/custom-token\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];chmod(path.fileSystemRepresentation,0600);
 NSDictionary *local=ATLPhoneFlow(base,@"begin",0,nil,&error);
 NSCAssert(local && [local[@"email"] isEqual:@"local@example.invalid"] && [local[@"next"] integerValue]==0,@"explicit local account change has no stale-state/provider lock: %@",error);
 [NSFileManager.defaultManager removeItemAtPath:base error:nil];return 0;
}}
