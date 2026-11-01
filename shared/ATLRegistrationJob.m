#import "ATLRegistrationJob.h"
#import "ATLRegistrationStorage.h"

static void ATLRegError(NSError **error, NSInteger code, NSString *message) {
 if(error) *error=[NSError errorWithDomain:@"ATLRegistrationJob" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL ATLRegText(id value,NSUInteger max,NSString *pattern) {
 if(![value isKindOfClass:NSString.class] || ![value length] || [value length]>max) return NO;
 return [[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] numberOfMatchesInString:value options:0 range:NSMakeRange(0,[value length])]==1;
}
static BOOL ATLRegValidPayload(NSDictionary *p) {
 if(![p isKindOfClass:NSDictionary.class] || p.count!=6) return NO;
 return ATLRegText(p[@"id"],80,@"^[A-Za-z0-9-]+$") &&
  ATLRegText(p[@"email"],254,@"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$") &&
  ATLRegText(p[@"username"],64,@"^[A-Za-z0-9_.-]+$") &&
  ATLRegText(p[@"password"],254,@"^[\\x20-\\x7e]+$") &&
  ATLRegText(p[@"fullName"],100,@"^[A-Za-z]+ [A-Za-z]+$") &&
  ATLRegText(p[@"zip"],5,@"^[0-9]{5}$");
}
static NSString *ATLRegName(ATLRegState s) {
 switch(s){case ATL_REG_PENDING:return @"pending";case ATL_REG_PREPARING:return @"preparing";case ATL_REG_READY:return @"ready";case ATL_REG_SUBMITTING:return @"submitting";case ATL_REG_WAIT_CODE:return @"wait_code";case ATL_REG_DONE:return @"done";case ATL_REG_ERROR:return @"error";case ATL_REG_REVIEW:return @"review";}
 return nil;
}
static BOOL ATLRegStateForName(id name,ATLRegState *out) {
 if(![name isKindOfClass:NSString.class])return NO;
 for(int i=ATL_REG_PENDING;i<=ATL_REG_REVIEW;i++)if([name isEqual:ATLRegName((ATLRegState)i)]){*out=(ATLRegState)i;return YES;}
 return NO;
}
static BOOL ATLRegAcquire(NSString *directory,ATLRegStore *store,NSError **error) {
 if(![directory isKindOfClass:NSString.class] || !ATLRegOpen(store,directory.fileSystemRepresentation)){ATLRegError(error,500,@"任务目录不可用或正在使用");return NO;}
 return YES;
}
static NSMutableDictionary *ATLRegLoad(ATLRegStore *store,NSError **error) {
 unsigned char bytes[ATL_REG_MAX_BYTES];size_t n=0;
 if(!ATLRegRead(store,bytes,sizeof(bytes),&n)){ATLRegError(error,500,@"任务记录不可读取");return nil;}
 NSData *data=[NSData dataWithBytes:bytes length:n];memset(bytes,0,sizeof(bytes));
 id object=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];ATLRegState state;
 if(![object isKindOfClass:NSMutableDictionary.class] || !ATLRegText(object[@"id"],80,@"^[A-Za-z0-9-]+$") || !ATLRegStateForName(object[@"state"],&state)) {ATLRegError(error,500,@"任务记录无效");return nil;}
 return object;
}
static BOOL ATLRegSave(ATLRegStore *store,NSDictionary *job,NSError **error) {
 NSData *data=[NSJSONSerialization dataWithJSONObject:job options:0 error:nil];
 NSString *nonce=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
 if(!data || ATLRegWrite(store,data.bytes,data.length,nonce.UTF8String)!=1){ATLRegError(error,500,@"任务写入未确认，请核对后再操作");return NO;}
 return YES;
}
static NSDictionary *ATLRegPublic(NSDictionary *job){return @{@"id":job[@"id"],@"state":job[@"state"]};}
static BOOL ATLRegMatch(NSDictionary *job,NSString *jobID,NSError **error){
 if(!ATLRegText(jobID,80,@"^[A-Za-z0-9-]+$") || ![job[@"id"] isEqual:jobID]){ATLRegError(error,409,@"任务编号不匹配");return NO;}return YES;
}
NSDictionary *ATLRegistrationCreate(NSString *directory,NSDictionary *payload,NSError **error){
 if(error)*error=nil;if(!ATLRegValidPayload(payload)){ATLRegError(error,400,@"注册资料格式无效");return nil;}
 ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return nil;
 @try {struct stat st;if(fstatat(store.dirfd,"registration-job.json",&st,AT_SYMLINK_NOFOLLOW)==0){ATLRegError(error,409,@"已有任务，请先核对");return nil;}if(errno!=ENOENT){ATLRegError(error,500,@"任务目录不可读取");return nil;}
  NSMutableDictionary *job=[payload mutableCopy];job[@"state"]=@"pending";return ATLRegSave(&store,job,error)?ATLRegPublic(job):nil;
 } @finally {ATLRegClose(&store);}
}
NSDictionary *ATLRegistrationStatus(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return nil;
 @try {NSDictionary *job=ATLRegLoad(&store,error);return job && ATLRegMatch(job,jobID,error)?ATLRegPublic(job):nil;} @finally {ATLRegClose(&store);}
}
NSDictionary *ATLRegistrationClaim(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return nil;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return nil;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,ATL_REG_CLAIM,&next)){ATLRegError(error,409,@"任务不能重复领取");return nil;}
  NSMutableDictionary *p=[job mutableCopy];[p removeObjectForKey:@"state"];if(!ATLRegValidPayload(p)){ATLRegError(error,500,@"任务资料无效");return nil;}
  job[@"state"]=ATLRegName(next);return ATLRegSave(&store,job,error)?[job copy]:nil;
 } @finally {ATLRegClose(&store);}
}
BOOL ATLRegistrationAdvance(NSString *directory,NSString *jobID,ATLRegEvent event,NSError **error){
 if(error)*error=nil;if(event==ATL_REG_CLAIM){ATLRegError(error,400,@"请通过领取接口操作");return NO;}ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,event,&next)){ATLRegError(error,409,@"任务阶段不允许此操作");return NO;}
  job[@"state"]=ATLRegName(next);
  if(next==ATL_REG_REVIEW || next==ATL_REG_ERROR || next==ATL_REG_DONE || next==ATL_REG_WAIT_CODE)
   for(NSString *key in @[@"password",@"email",@"username",@"fullName",@"zip"]) [job removeObjectForKey:key];
  return ATLRegSave(&store,job,error);
 } @finally {ATLRegClose(&store);}
}
