#import "ATLPhoneFlow.h"
#import "ATLRegistrationJob.h"
#import "ATLRegistrationBackup.h"
#import <CommonCrypto/CommonDigest.h>
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
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void (^)(NSURLRequest *))done{done(nil);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))done{self.status=[r isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)r statusCode]:0;done(self.status==200?NSURLSessionResponseAllow:NSURLSessionResponseCancel);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d{if(self.bytes.length+d.length>2000000){[t cancel];return;}[self.bytes appendData:d];}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e{self.failure=e;dispatch_semaphore_signal(self.finished);}
@end
static NSString *PFFetch(NSString *email,NSString *link,ATLPhoneFlowStopped stopped,NSError **error){
 NSURLComponents *parts=[NSURLComponents componentsWithString:link];NSMutableArray *mailboxes=[NSMutableArray array];
 for(NSURLQueryItem *q in parts.queryItems)if([q.name isEqual:@"e"])[mailboxes addObject:[[q.value componentsSeparatedByString:@":"] firstObject]?:@""];
 if(![parts.scheme.lowercaseString isEqual:@"https"] || ![parts.host.lowercaseString isEqual:@"api.wdmail.top"] || ![parts.path isEqual:@"/m"] || parts.user || parts.password || parts.port || mailboxes.count!=1 || ![[mailboxes[0] lowercaseString] isEqual:email.lowercaseString]){PFError(error,@"取信链接必须是与当前邮箱一致的HTTPS WDMail链接");return nil;}
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
static NSMutableDictionary *PFConfig(NSString *base,NSError **error){
 NSString *file=[base stringByAppendingPathComponent:@"Local/Files/config.txt"];int fd=open(file.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
 if(fd<0 || !ATLRegPrivateFile(fd) || fstat(fd,&st)!=0 || st.st_size>16384){if(fd>=0)close(fd);PFError(error,@"本机配置缺失或权限不正确，请在本机文件编辑配置");return nil;}
 NSMutableData *bytes=[NSMutableData data];unsigned char b[2048];ssize_t n;while((n=read(fd,b,sizeof b))>0)[bytes appendBytes:b length:n];close(fd);
 NSString *text=[[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding];if(!text){PFError(error,@"配置不是UTF-8文本");return nil;}
 NSMutableDictionary *result=[NSMutableDictionary dictionary];NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
 for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){NSString *v=[line stringByTrimmingCharactersInSet:space];if(!v.length || [v hasPrefix:@"#"] || [v hasPrefix:@";"] || [v hasPrefix:@"["])continue;NSRange eq=[v rangeOfString:@"="];if(eq.location==NSNotFound)continue;NSString *key=[[v substringToIndex:eq.location] uppercaseString];result[key]=[[v substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:space];}
 for(NSString *key in @[@"EMAIL",@"PICKUP_API"])if(![result[key] length]){PFError(error,@"先在本机配置填写EMAIL和PICKUP_API，再运行完整流程");return nil;}
 return result;
}
static BOOL PFSave(ATLRegStore *store,NSDictionary *state,NSError **error){if(!ATLBackupSave(store,state)){PFError(error,@"手机断点保存失败，停止后续动作");return NO;}return YES;}
static NSDictionary *PFSummary(NSDictionary *s){return @{@"next":s[@"next"]?:@0,@"state":s[@"state"]?:@"ready",@"email":s[@"config"][@"EMAIL"]?:@"",@"job":s[@"job"]?:@""};}
static NSDictionary *PFPayload(NSDictionary *c,NSString *identifier){return @{@"id":identifier,@"email":c[@"EMAIL"]?:@"",@"username":c[@"USERNAME"]?:@"",@"fullName":c[@"FULL_NAME"]?:@"",@"password":c[@"PASSWORD"]?:@"",@"zip":[c[@"ZIP"] length]?c[@"ZIP"]:@"11714",@"pickup_api":c[@"PICKUP_API"]?:@"",@"country":[c[@"COUNTRY"] length]?c[@"COUNTRY"]:@"美国"};}

NSDictionary *ATLPhoneFlow(NSString *base,NSString *action,NSInteger stage,ATLPhoneFlowStopped stopped,NSError **error){
 if(error)*error=nil;NSString *directory=[base stringByAppendingPathComponent:@"PhoneFlow"];
 if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return nil;
 ATLRegStore store;if(!ATLRegOpen(&store,directory.fileSystemRepresentation)){PFError(error,@"手机流程状态正在使用或权限不正确");return nil;}
 @try{
  NSMutableDictionary *s=[ATLBackupRead(&store) mutableCopy];
  struct stat existing;if(!s && fstatat(store.dirfd,"registration-job.json",&existing,AT_SYMLINK_NOFOLLOW)==0){PFError(error,@"本机断点损坏，保留现场，不重新开始");return nil;}
  if([action isEqual:@"begin"]){
   NSMutableDictionary *config=PFConfig(base,error);if(!config)return nil;
   NSString *first=PFFIRST()[arc4random_uniform(200)],*last=PFLAST()[arc4random_uniform(200)];
   if(![config[@"USERNAME"] length]){unsigned length=2+arc4random_uniform(3);unsigned lo=length==2?10:(length==3?100:1000);config[@"USERNAME"]=[NSString stringWithFormat:@"%@_%@%u",first.lowercaseString,last.lowercaseString,lo+arc4random_uniform(9*lo)];}
   if(![config[@"FULL_NAME"] length])config[@"FULL_NAME"]=[NSString stringWithFormat:@"%@ %@",first,last];
   if(![config[@"PASSWORD"] length]){NSMutableString *password=[NSMutableString stringWithString:@"A"];NSString *alphabet=@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@-_";for(int i=0;i<14;i++)[password appendString:[alphabet substringWithRange:NSMakeRange(arc4random_uniform((uint32_t)alphabet.length),1)]];[password appendString:@"7"];config[@"PASSWORD"]=password;}
   if(!ATLRegistrationPayloadValid(PFPayload(config,@"preflight"))){PFError(error,@"邮箱、姓名、用户名、密码或ZIP配置格式不正确，未执行准备操作");return nil;}
   NSURLComponents *mailURL=[NSURLComponents componentsWithString:config[@"PICKUP_API"]];NSMutableArray *mailboxes=[NSMutableArray array];for(NSURLQueryItem *q in mailURL.queryItems)if([q.name isEqual:@"e"])[mailboxes addObject:[[q.value componentsSeparatedByString:@":"] firstObject]?:@""];
   if(![mailURL.scheme isEqual:@"https"] || ![mailURL.host.lowercaseString isEqual:@"api.wdmail.top"] || ![mailURL.path isEqual:@"/m"] || mailURL.port || mailURL.user || mailURL.password || mailboxes.count!=1 || ![[mailboxes[0] lowercaseString] isEqual:[config[@"EMAIL"] lowercaseString]]){PFError(error,@"取信链接格式不正确或与邮箱不一致，未执行准备操作");return nil;}
   if(s && ![s[@"config"][@"EMAIL"] isEqual:config[@"EMAIL"]]){if(![@[@"done",@"sms_required"] containsObject:s[@"state"]]){PFError(error,@"旧邮箱任务尚未结束，不能换账号覆盖断点");return nil;}s=nil;}
   if(!s){
    NSString *results=[NSString stringWithContentsOfFile:[base stringByAppendingPathComponent:@"Local/Files/results.txt"] encoding:NSUTF8StringEncoding error:nil];
    for(NSString *line in [results componentsSeparatedByString:@"\n"]){NSArray *f=[line componentsSeparatedByString:@"----"];if(f.count==7 && [[f[1] lowercaseString] isEqual:[config[@"EMAIL"] lowercaseString]] && [@[@"完成",@"已完成",@"需要接短信码"] containsObject:f[5]]){PFError(error,@"该邮箱已有完成结果，不会再次注册");return nil;}}
    s=[@{@"config":config,@"next":@0,@"state":@"ready",@"attempts":@{}} mutableCopy];if(!PFSave(&store,s,error))return nil;
   }
   return PFSummary(s);
  }
  if(!s){PFError(error,@"请先启动完整流程");return nil;}
  if([action isEqual:@"status"])return PFSummary(s);
  if([action isEqual:@"stage_begin"]){
   if(stage==13 && [s[@"state"] isEqual:@"running"]){NSDictionary *job=ATLRegistrationStatus([base stringByAppendingPathComponent:@"Registration"],s[@"job"],error);if(!job)return nil;if([@[@"wait_code",@"code_ready"] containsObject:job[@"state"]])s[@"state"]=@"ready";}
   if(stage!=[s[@"next"] integerValue] || [s[@"state"] isEqual:@"running"]){PFError(error,@"断点阶段不匹配或上次动作未确认，停止重放");return nil;}
   NSMutableDictionary *attempts=[s[@"attempts"] mutableCopy];NSString *key=[@(stage) stringValue];NSInteger count=[attempts[key] integerValue];if(count>=3){PFError(error,@"当前步骤已执行3次，请查看日志");return nil;}
   attempts[key]=@(count+1);s[@"attempts"]=attempts;s[@"state"]=@"running";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  if([action isEqual:@"stage_done"] || [action isEqual:@"stage_failed"]){
   if(stage!=[s[@"next"] integerValue] || ![s[@"state"] isEqual:@"running"]){PFError(error,@"阶段保存状态不匹配");return nil;}
   s[@"state"]=@"ready";if([action isEqual:@"stage_done"])s[@"next"]=@(stage+1);if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  NSString *reg=[base stringByAppendingPathComponent:@"Registration"];NSDictionary *c=s[@"config"];
  if([action isEqual:@"sms"]){
   NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);if(!job)return nil;
   if(![job[@"state"] isEqual:@"review"] && !ATLRegistrationAdvance(reg,s[@"job"],ATL_REG_FAILED,error))return nil;
   if(!ATLRegistrationClear(reg,s[@"job"],error))return nil;
   if(!ATLBackupExport(reg,@{@"id":s[@"job"],@"state":@"sms_required"})){PFError(error,@"短信验证结果保存失败，保留本机备份");return nil;}
   s[@"state"]=@"sms_required";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  if([action isEqual:@"resume_mail"]){
   if(!ATLRegistrationResumeVerification(reg,s[@"job"],error))return nil;
   s[@"next"]=@13;s[@"state"]=@"ready";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  if([action isEqual:@"prepare_account"]){
   if(s[@"job"]){NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);return job?@{@"state":job[@"state"],@"job":s[@"job"]}:nil;}
   NSString *page=PFFetch(c[@"EMAIL"],c[@"PICKUP_API"],stopped,error);if(!page)return nil;
   NSString *username=c[@"USERNAME"],*full=c[@"FULL_NAME"],*password=c[@"PASSWORD"];
   if(!username.length || !full.length || !password.length){PFError(error,@"本机配置还需填写USERNAME、FULL_NAME和PASSWORD；此版本不自动猜测资料");return nil;}
   NSString *identifier=NSUUID.UUID.UUIDString;
   NSDictionary *payload=PFPayload(c,identifier);
   // Save the identity before creation; a crash never silently generates a second job.
   s[@"job"]=identifier;s[@"baseline"]=PFHash(page);if(!PFSave(&store,s,error))return nil;
   NSDictionary *job=ATLRegistrationCreate(reg,payload,error);return job?@{@"state":job[@"state"],@"job":identifier}:nil;
  }
  if([action isEqual:@"job_status"]){NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);return job?@{@"state":job[@"state"]}:nil;}
  if([action isEqual:@"mail"]){
   NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);if(!job)return nil;
   if([job[@"state"] isEqual:@"code_ready"])return @{@"state":@"code_ready"};
   if(![job[@"state"] isEqual:@"wait_code"]){PFError(error,@"当前任务不在等待邮箱验证码阶段");return nil;}
   NSString *page=PFFetch(c[@"EMAIL"],c[@"PICKUP_API"],stopped,error);if(!page)return nil;
   if([PFHash(page) isEqual:s[@"baseline"]])return @{@"state":@"wait_code"};
   NSString *code=ATLPhoneMailCode(page);if(!code)return @{@"state":@"wait_code"};
   return ATLRegistrationSetCode(reg,s[@"job"],code,error)?@{@"state":@"code_ready"}:nil;
  }
  if([action isEqual:@"finish"]){
   if([s[@"state"] isEqual:@"sms_required"])return PFSummary(s);
   NSDictionary *job=ATLRegistrationStatus(reg,s[@"job"],error);if(![job[@"state"] isEqual:@"done"]){PFError(error,@"手机任务尚未确认完成，不能标记成功");return nil;}
   s[@"state"]=@"done";if(!PFSave(&store,s,error))return nil;return PFSummary(s);
  }
  PFError(error,@"不支持的手机流程操作");return nil;
 }@finally{ATLRegClose(&store);}
}
