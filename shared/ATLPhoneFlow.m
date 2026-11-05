#import "ATLPhoneFlow.h"
#import "ATLRegistrationJob.h"
#import "ATLRegistrationBackup.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import "ATLPhoneNames.h"

static void PFError(NSError **e,NSString *s){if(e)*e=[NSError errorWithDomain:@"ATLPhoneFlow" code:1 userInfo:@{NSLocalizedDescriptionKey:s}];}
static NSString *PFHash(NSString *s){NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding];unsigned char b[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,b);NSMutableString *r=[NSMutableString string];for(unsigned i=0;i<sizeof b;i++)[r appendFormat:@"%02x",b[i]];return r;}

// No redirects and no unbounded buffered response; request URLs are never logged.
@interface ATLPhoneMailRequest:NSObject<NSURLSessionDataDelegate>
@property(nonatomic,strong) NSMutableData *bytes;
@property(nonatomic,strong) NSError *failure;
@property(nonatomic,strong) dispatch_semaphore_t finished;
@property(nonatomic) NSInteger status;
@end
@implementation ATLPhoneMailRequest
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void (^)(NSURLRequest *))done{done(q);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))done{self.status=[r isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)r statusCode]:0;done(self.status==200?NSURLSessionResponseAllow:NSURLSessionResponseCancel);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d{if(self.bytes.length+d.length>2000000){[t cancel];return;}[self.bytes appendData:d];}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e{self.failure=e;dispatch_semaphore_signal(self.finished);}
@end
static NSString *PFFetch(NSString *email,NSString *link,ATLPhoneFlowStopped stopped,NSError **error){
 NSURLComponents *parts=[NSURLComponents componentsWithString:link];NSMutableArray *mailboxes=[NSMutableArray array];
 for(NSURLQueryItem *q in parts.queryItems)if([q.name isEqual:@"e"])[mailboxes addObject:[[q.value componentsSeparatedByString:@":"] firstObject]?:@""];
 if(![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString] || !parts.host.length){PFError(error,@"取信链接不是有效HTTP/HTTPS地址");return nil;}
 ATLPhoneMailRequest *delegate=[ATLPhoneMailRequest new];delegate.bytes=[NSMutableData data];delegate.finished=dispatch_semaphore_create(0);
 NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=12;config.timeoutIntervalForResource=12;config.URLCache=nil;
 NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
 NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:queue];
 NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:parts.URL];[request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
 NSURLSessionDataTask *task=[session dataTaskWithRequest:request];[task resume];
 BOOL completed=NO;NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:13];
 while(deadline.timeIntervalSinceNow>0){if(dispatch_semaphore_wait(delegate.finished,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))==0){completed=YES;break;}if(stopped && stopped())break;}
 [session invalidateAndCancel];
 if(!completed || delegate.failure || delegate.status!=200){PFError(error,@"手机取信失败或已停止；未重新提交注册");return nil;}
 NSString *page=[[NSString alloc]initWithData:delegate.bytes encoding:NSUTF8StringEncoding];if(!page)PFError(error,@"邮件不是有效UTF-8文本");return page;
}

NSString *ATLPhoneMailCode(NSString *page){
 if(![page isKindOfClass:NSString.class] || page.length>2000000)return nil;
 // WDMail's iframe srcdoc is HTML-escaped. Decode before stripping tags.
 NSString *s=page;
 for(NSArray *pair in @[@[@"&lt;",@"<"],@[@"&gt;",@">"],@[@"&quot;",@"\""],@[@"&#39;",@"'"],@[@"&nbsp;",@" "],@[@"&amp;",@"&"]])s=[s stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
 NSRegularExpression *tags=[NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
 s=[tags stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0,s.length) withTemplate:@" "];
 NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"(?:verification\\s+code|security\\s+code|confirmation\\s+code|your\\s+code|验证码|验证代码)[^0-9]{0,100}(?<![A-Za-z0-9_])([0-9]{6}|[0-9]{4})(?![A-Za-z0-9_]|[-/:][0-9])" options:NSRegularExpressionCaseInsensitive error:nil];
 NSMutableSet *codes=[NSMutableSet set];for(NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0,s.length)])[codes addObject:[s substringWithRange:[m rangeAtIndex:1]]];
 return codes.count==1?codes.anyObject:nil;
}
NSString *ATLPhoneMailNewCode(NSString *page,NSString *baselineCode){NSString *code=ATLPhoneMailCode(page);return code && ![code isEqual:baselineCode]?code:nil;}
static NSString *PFReadText(NSString *file,NSUInteger limit,BOOL missingOK,NSError **error){
 int fd=open(file.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
 if(fd<0 && missingOK && errno==ENOENT)return @"";
 if(fd<0 || !ATLRegPrivateFile(fd) || fstat(fd,&st)!=0 || st.st_size<0 || (NSUInteger)st.st_size>limit){if(fd>=0)close(fd);PFError(error,@"本机文件不可读取、权限不正确或内容过大，未执行界面操作");return nil;}
 NSMutableData *bytes=[NSMutableData data];unsigned char b[2048];BOOL valid=YES;
 for(;;){ssize_t n=read(fd,b,sizeof b);if(n<0 && errno==EINTR)continue;if(n<0){valid=NO;break;}if(!n)break;if(bytes.length+(NSUInteger)n>limit){valid=NO;break;}[bytes appendBytes:b length:(NSUInteger)n];}close(fd);
 NSString *text=valid?[[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding]:nil;if(!text)PFError(error,@"本机文件读取失败或不是有效UTF-8，保留文件并停止");return text;
}
static NSMutableDictionary *PFConfig(NSString *base,NSError **error){
 NSString *text=PFReadText([base stringByAppendingPathComponent:@"Local/Files/config.txt"],16384,NO,error);if(!text)return nil;
 NSMutableDictionary *result=[NSMutableDictionary dictionary];NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
 for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){NSString *v=[line stringByTrimmingCharactersInSet:space];if(!v.length || [v hasPrefix:@"#"] || [v hasPrefix:@";"] || [v hasPrefix:@"["])continue;NSRange eq=[v rangeOfString:@"="];if(eq.location==NSNotFound)continue;NSString *key=[[v substringToIndex:eq.location] uppercaseString];result[key]=[[v substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:space];}
 for(NSString *key in @[@"EMAIL",@"PICKUP_API"])if(![result[key] length]){PFError(error,@"先在本机配置填写EMAIL和PICKUP_API，再运行完整流程");return nil;}
 return result;
}
static BOOL PFSave(ATLRegStore *store,NSDictionary *state,NSError **error){if(!ATLBackupSave(store,state)){PFError(error,@"手机断点保存失败，停止后续动作");return NO;}return YES;}
static NSDictionary *PFSummary(NSDictionary *s){return @{@"next":s[@"next"]?:@0,@"state":s[@"state"]?:@"ready",@"email":s[@"config"][@"EMAIL"]?:@"",@"job":s[@"job"]?:@"",@"retry_ms":@((NSInteger)ceil(MAX(0,[s[@"retryAfter"] doubleValue]-NSDate.date.timeIntervalSince1970)*1000))};}
static NSDictionary *PFPayload(NSDictionary *c,NSString *identifier){return @{@"id":identifier,@"email":c[@"EMAIL"]?:@"",@"username":c[@"USERNAME"]?:@"",@"fullName":c[@"FULL_NAME"]?:@"",@"password":c[@"PASSWORD"]?:@"",@"zip":[c[@"ZIP"] length]?c[@"ZIP"]:@"11714",@"pickup_api":c[@"PICKUP_API"]?:@"",@"country":[c[@"COUNTRY"] length]?c[@"COUNTRY"]:@"美国"};}
// 残留注册任务按失败归档（2026-11-05 规则：停止重启=上个账号标失败，不允许以"请先核对"拒绝开始）。
// 任务文件可读则走状态机归档（写 results.txt 标记"失败"）；不可读则旁路移动到 Retired/。永不删数据。
static BOOL PFArchiveStaleRegistration(NSString *reg,NSError **error){
 NSString *path=[reg stringByAppendingPathComponent:@"registration-job.json"];
 struct stat st;if(lstat(path.fileSystemRepresentation,&st)!=0){if(errno==ENOENT)return YES;PFError(error,@"注册任务目录不可读取，未执行新的准备操作");return NO;}
 NSData *data=[NSData dataWithContentsOfFile:path];id job=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
 NSString *jobID=[job isKindOfClass:NSDictionary.class]?job[@"id"]:nil;
 if(jobID && ATLRegistrationArchiveResult(reg,jobID,@"error",error)){
  struct stat gone;if(lstat(path.fileSystemRepresentation,&gone)!=0 && errno==ENOENT)return YES;
 }
 if(error)*error=nil;
 NSString *retired=[reg stringByAppendingPathComponent:@"Retired"];
 if(![NSFileManager.defaultManager createDirectoryAtPath:retired withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
 NSString *target=[retired stringByAppendingPathComponent:[NSString stringWithFormat:@"orphaned-%@.json",NSUUID.UUID.UUIDString]];
 if(![NSFileManager.defaultManager moveItemAtPath:path toPath:target error:error]){PFError(error,@"旧注册任务无法归档，未执行新的准备操作");return NO;}
 chmod(target.fileSystemRepresentation,0600);return YES;
}

static NSDictionary *PFWorkbench(NSString *base,NSDictionary *state,ATLPhoneFlowStopped stopped,NSError **error){
 NSString *files=[base stringByAppendingPathComponent:@"Local/Files"],*nonce=NSUUID.UUID.UUIDString;
 NSDictionary *request=@{@"nonce":nonce,@"at":@(NSDate.date.timeIntervalSince1970),@"email":state[@"config"][@"EMAIL"]?:@"",@"job":state[@"job"]?:@""};
 NSString *path=[files stringByAppendingPathComponent:@"workbench-request.json"];
 NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:error];
 if(!data || ![data writeToFile:path options:NSDataWritingAtomic error:error] || chmod(path.fileSystemRepresentation,0600)!=0){PFError(error,@"工作台启动请求保存失败");return nil;}
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
 while(deadline.timeIntervalSinceNow>0){
  if(stopped && stopped()){PFError(error,@"启动同步已停止");return nil;}
  // 读取失败的错误分支多半是管理器正在写入的权限竞态(先 rename 后 chmod 的窗口)，
  // 清错等待下轮重读，而不是立刻判 begin 失败(11-05 CI 实证命中该竞态)。
  NSString *text=PFReadText([files stringByAppendingPathComponent:@"workbench-reply.json"],16384,YES,error);if(!text){if(error&&*error){*error=nil;[NSThread sleepForTimeInterval:0.2];continue;}return nil;}
  NSDictionary *reply=text.length?[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]:nil;
  if([reply isKindOfClass:NSDictionary.class] && [reply[@"nonce"] isEqual:nonce]){
   if(![reply[@"ok"] isEqual:@YES]){PFError(error,[reply[@"message"] isKindOfClass:NSString.class]?reply[@"message"]:@"工作台未分配账号");return nil;}
   if(![reply[@"old_email"] isEqual:request[@"email"]] || ![reply[@"old_job"] isEqual:request[@"job"]] || ![reply[@"config"] isKindOfClass:NSDictionary.class]){PFError(error,@"工作台响应与当前任务不一致");return nil;}
   return reply;
  }
  [NSThread sleepForTimeInterval:0.2];
 }
 PFError(error,@"工作台启动同步超时，请保持电脑管理器运行、手机与电脑在同一局域网；未使用旧账号");return nil;
}

NSDictionary *ATLPhoneFlow(NSString *base,NSString *action,NSInteger stage,ATLPhoneFlowStopped stopped,NSError **error){
 if(error)*error=nil;NSString *directory=[base stringByAppendingPathComponent:@"PhoneFlow"];
 if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return nil;
 ATLRegStore store;if(!ATLRegOpen(&store,directory.fileSystemRepresentation)){PFError(error,@"手机流程状态正在使用或权限不正确");return nil;}
 @try{
  NSMutableDictionary *s=[ATLBackupRead(&store) mutableCopy];
  BOOL staleUnreadable=NO;
  struct stat existing;if(!s && fstatat(store.dirfd,"registration-job.json",&existing,AT_SYMLINK_NOFOLLOW)==0)staleUnreadable=YES;
  if([action isEqual:@"begin"]){
   NSMutableDictionary *config=nil;NSDictionary *workbench=nil;
   if([NSFileManager.defaultManager fileExistsAtPath:[base stringByAppendingPathComponent:@"Local/Files/workbench.enabled"]]){
    workbench=PFWorkbench(base,s,stopped,error);if(!workbench)return nil;
    config=[workbench[@"config"] mutableCopy];
    for(NSString *key in @[@"EMAIL",@"PICKUP_API",@"USERNAME",@"FULL_NAME",@"PASSWORD",@"COUNTRY",@"ZIP"]){id v=config[key];if(![v isKindOfClass:NSString.class] || [v length]>4096 || [v rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){PFError(error,@"工作台账号字段格式无效");return nil;}}
   }else config=PFConfig(base,error);
   if(!config)return nil;
   NSString *first=PFFIRST()[arc4random_uniform(200)],*last=PFLAST()[arc4random_uniform(200)];
   if(![config[@"USERNAME"] length]){unsigned length=2+arc4random_uniform(3);unsigned lo=length==2?10:(length==3?100:1000);config[@"USERNAME"]=[NSString stringWithFormat:@"%@_%@%u",first.lowercaseString,last.lowercaseString,lo+arc4random_uniform(9*lo)];}
   if(![config[@"FULL_NAME"] length])config[@"FULL_NAME"]=[NSString stringWithFormat:@"%@ %@",first,last];
   if(![config[@"PASSWORD"] length]){NSMutableString *password=[NSMutableString stringWithString:@"A"];NSString *alphabet=@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@-_";for(int i=0;i<14;i++)[password appendString:[alphabet substringWithRange:NSMakeRange(arc4random_uniform((uint32_t)alphabet.length),1)]];[password appendString:@"7"];config[@"PASSWORD"]=password;}
   if(!ATLRegistrationPayloadValid(PFPayload(config,@"preflight"))){PFError(error,@"邮箱、姓名、用户名、密码或ZIP配置格式不正确，未执行准备操作");return nil;}
   NSURLComponents *mailURL=[NSURLComponents componentsWithString:config[@"PICKUP_API"]];NSMutableArray *mailboxes=[NSMutableArray array];for(NSURLQueryItem *q in mailURL.queryItems)if([q.name isEqual:@"e"])[mailboxes addObject:[[q.value componentsSeparatedByString:@":"] firstObject]?:@""];
   if(![@[@"http",@"https"] containsObject:mailURL.scheme.lowercaseString] || !mailURL.host.length){PFError(error,@"取信链接不是有效HTTP/HTTPS地址");return nil;}
   if(s && [workbench[@"replace"] isEqual:@YES]){
    // 用户规则（2026-11-05）：工作台是唯一权威——管理器只在旧账号已标终态且确有下一条
    // draft 时才回 replace=true，手机端不再二次校验（旧的白名单/同邮箱校验属于"没用的
    // 限制"，11-05 实证会误拒、白白烧掉一个账号）。直接归档旧任务、换新账号继续跑。
    NSString *archive=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"archived-%@.json",workbench[@"nonce"]]];
    NSData *old=[NSJSONSerialization dataWithJSONObject:s options:0 error:error];
    if(!old || ![old writeToFile:archive options:NSDataWritingAtomic error:error] || chmod(archive.fileSystemRepresentation,0600)!=0)return nil;
    if([s[@"job"] length]){
     NSString *reg=[base stringByAppendingPathComponent:@"Registration"];NSError *lookup=nil;NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],&lookup);
     if(job){if(!ATLRegistrationArchiveResult(reg,s[@"job"],workbench[@"old_status"],error))return nil;}
     else if(lookup.code!=404){if(error)*error=lookup;return nil;}
     NSString *resultState=[workbench[@"old_status"] isEqual:@"cancelled"]?@"error":workbench[@"old_status"];
     if(!ATLBackupExport(reg,@{@"id":s[@"job"],@"state":resultState})){PFError(error,@"旧账号最终状态写入手机TXT失败，未切换账号");return nil;}
    }
    if(ATLRegRemove(&store)!=1){PFError(error,@"旧断点归档未确认，未启动新账号");return nil;}s=nil;
   }
   if(s && ![s[@"config"][@"EMAIL"] isEqual:config[@"EMAIL"]]){
    // blocked 不再整体停脚本：与正常旧断点同等归档，按取消记录后领新账号继续跑。
    NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"archived-local-%@.json",NSUUID.UUID.UUIDString]];
    NSData *old=[NSJSONSerialization dataWithJSONObject:s options:0 error:error];
    if(!old || ![old writeToFile:path options:NSDataWritingAtomic error:error] || chmod(path.fileSystemRepresentation,0600)!=0)return nil;
    if([s[@"job"] length]){NSString *reg=[base stringByAppendingPathComponent:@"Registration"];NSError *readError=nil;NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],&readError);if(job){if(!ATLRegistrationArchiveResult(reg,s[@"job"],@"cancelled",error))return nil;}else if(readError.code!=404){if(error)*error=readError;return nil;}}
    if(ATLRegRemove(&store)!=1){PFError(error,@"旧断点文件无法移除");return nil;}
    s=nil;
   }
   // 断点不可读（权限或内容损坏）：按中断处理，rename 旁路归档原文件后照常开始；数据保留在 archived-corrupt-*。
   if(!s && staleUnreadable){
    NSString *corrupt=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"archived-corrupt-%@.json",NSUUID.UUID.UUIDString]];
    if(renameat(store.dirfd,"registration-job.json",store.dirfd,corrupt.lastPathComponent.UTF8String)!=0 && errno!=ENOENT){PFError(error,@"旧断点无法归档，未开始新账号");return nil;}
    chmod(corrupt.fileSystemRepresentation,0600);staleUnreadable=NO;
   }
   if(!s){
    if(!PFArchiveStaleRegistration([base stringByAppendingPathComponent:@"Registration"],error))return nil;
    NSString *results=PFReadText([base stringByAppendingPathComponent:@"Local/Files/results.txt"],16*1024*1024,YES,error);if(!results)return nil;
    for(NSString *line in [results componentsSeparatedByString:@"\n"]){NSArray *f=[line componentsSeparatedByString:@"----"];if(f.count==7 && [[f[1] lowercaseString] isEqual:[config[@"EMAIL"] lowercaseString]] && [@[@"完成",@"已完成",@"需要接短信码"] containsObject:f[5]]){PFError(error,@"该邮箱已有完成结果，不会再次注册");return nil;}}
    s=[@{@"config":config,@"next":@0,@"state":@"ready",@"attempts":@{}} mutableCopy];if(!PFSave(&store,s,error))return nil;
   }
   return PFSummary(s);
  }
  if(!s){PFError(error,@"请先启动完整流程");return nil;}
  if([action isEqual:@"status"])return PFSummary(s);
  if([action isEqual:@"blocked"]){s[@"state"]=@"blocked";if(!PFSave(&store,s,error))return nil;return PFSummary(s);}
  if([action isEqual:@"stage_begin"]){
   if([s[@"retryAfter"] doubleValue]>NSDate.date.timeIntervalSince1970){PFError(error,@"当前断点仍需等待15秒重试间隔");return nil;}
   if(stage==[s[@"next"] integerValue] && [s[@"state"] isEqual:@"running"])s[@"state"]=@"ready";
   if(stage==13 && [s[@"state"] isEqual:@"running"]){NSDictionary *job=ATLRegistrationStatus([base stringByAppendingPathComponent:@"Registration"],s[@"job"],error);if(!job)return nil;if([@[@"wait_code",@"code_ready"] containsObject:job[@"state"]])s[@"state"]=@"ready";}
   if(stage!=[s[@"next"] integerValue] || [s[@"state"] isEqual:@"running"]){PFError(error,@"断点阶段不匹配或上次动作未确认，停止重放");return nil;}
   NSMutableDictionary *attempts=[s[@"attempts"] mutableCopy];NSString *key=[@(stage) stringValue];NSInteger count=[attempts[key] integerValue];if(count>=3){PFError(error,@"当前步骤已执行3次，请查看日志");return nil;}
   attempts[key]=@(count+1);s[@"attempts"]=attempts;s[@"state"]=@"running";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  if([action isEqual:@"stage_done"] || [action isEqual:@"stage_failed"]){
   if(stage!=[s[@"next"] integerValue] || ![s[@"state"] isEqual:@"running"]){PFError(error,@"阶段保存状态不匹配");return nil;}
   s[@"state"]=@"ready";if([action isEqual:@"stage_done"]){s[@"next"]=@(stage+1);[s removeObjectForKey:@"retryAfter"];}else s[@"retryAfter"]=@(NSDate.date.timeIntervalSince1970+15);if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  NSString *reg=[base stringByAppendingPathComponent:@"Registration"];NSDictionary *c=s[@"config"];
  if([action isEqual:@"sms"]){
   if(![s[@"state"] isEqual:@"sms_pending"]){NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);if(!job)return nil;if(![job[@"state"] isEqual:@"review"] && !ATLRegistrationAdvance(reg,s[@"job"],ATL_REG_FAILED,error))return nil;s[@"state"]=@"sms_pending";if(!PFSave(&store,s,error))return nil;}
   NSError *readError=nil;NSDictionary *existingJob=ATLRegistrationStatus(reg,s[@"job"],&readError);
   if(existingJob){if(![existingJob[@"state"] isEqual:@"review"] || !ATLRegistrationClear(reg,s[@"job"],error))return nil;}
   else if(readError.code!=404){if(error)*error=readError;return nil;}
   if(!ATLBackupExport(reg,@{@"id":s[@"job"],@"state":@"sms_required"})){PFError(error,@"短信验证结果保存失败，保留本机备份");return nil;}
   s[@"state"]=@"sms_required";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  if([action isEqual:@"resume_mail"]){
   if(!ATLRegistrationResumeVerification(reg,s[@"job"],error))return nil;
   s[@"next"]=@13;s[@"state"]=@"ready";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  if([action isEqual:@"prepare_account"]){
   if(s[@"job"]){NSError *readError=nil;NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],&readError);if(job)return @{@"state":job[@"state"],@"job":s[@"job"]};if(readError.code!=404){if(error)*error=readError;return nil;}}
   NSString *page=PFFetch(c[@"EMAIL"],c[@"PICKUP_API"],stopped,error);if(!page)return nil;
   NSString *username=c[@"USERNAME"],*full=c[@"FULL_NAME"],*password=c[@"PASSWORD"];
   if(!username.length || !full.length || !password.length){PFError(error,@"本机配置还需填写USERNAME、FULL_NAME和PASSWORD；此版本不自动猜测资料");return nil;}
   NSString *identifier=s[@"job"]?:NSUUID.UUID.UUIDString;
   NSDictionary *payload=PFPayload(c,identifier);
   // Save the identity before creation; a crash never silently generates a second job.
   s[@"job"]=identifier;s[@"baseline"]=PFHash(page);s[@"baseline_code"]=ATLPhoneMailCode(page)?:@"";if(!PFSave(&store,s,error))return nil;
   NSDictionary *job=ATLRegistrationCreate(reg,payload,error);return job?@{@"state":job[@"state"],@"job":identifier}:nil;
  }
  if([action isEqual:@"job_status"]){NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);return job?@{@"state":job[@"state"]}:nil;}
  if([action isEqual:@"mail"]){
   NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);if(!job)return nil;
   if([job[@"state"] isEqual:@"code_ready"])return @{@"state":@"code_ready"};
   if(![job[@"state"] isEqual:@"wait_code"]){PFError(error,@"当前任务不在等待邮箱验证码阶段");return nil;}
   NSString *page=PFFetch(c[@"EMAIL"],c[@"PICKUP_API"],stopped,error);if(!page)return nil;
   if([PFHash(page) isEqual:s[@"baseline"]])return @{@"state":@"wait_code"};
   NSString *code=ATLPhoneMailNewCode(page,s[@"baseline_code"]?:@"");if(!code)return @{@"state":@"wait_code"};
   return ATLRegistrationSetCode(reg,s[@"job"],code,error)?@{@"state":@"code_ready"}:nil;
  }
  if([action isEqual:@"finish"]){
   if([s[@"state"] isEqual:@"sms_required"])return PFSummary(s);
   NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);if(![job[@"state"] isEqual:@"done"]){PFError(error,@"手机任务尚未确认完成，不能标记成功");return nil;}
   if(!ATLBackupExport(reg,job)){PFError(error,@"已完成但TXT写入失败，保留任务供补写");return nil;}
   s[@"state"]=@"done";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  PFError(error,@"不支持的手机流程操作");return nil;
 }@finally{ATLRegClose(&store);}
}
