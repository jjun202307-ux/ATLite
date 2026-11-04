#import "ATLRegistrationJob.h"
#import <dispatch/dispatch.h>
#import "ATLRegistrationStorage.h"
#import "ATLRegistrationBackup.h"

static void ATLRegError(NSError **error, NSInteger code, NSString *message) {
 if(error) *error=[NSError errorWithDomain:@"ATLRegistrationJob" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL ATLRegText(id value,NSUInteger max,NSString *pattern) {
 if(![value isKindOfClass:NSString.class] || ![value length] || [value length]>max) return NO;
 NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
 NSTextCheckingResult *match=[regex firstMatchInString:value options:0 range:NSMakeRange(0,[value length])];
 return match && match.range.location==0 && match.range.length==[value length];
}
static BOOL ATLRegEmail(id value) {
 if(!ATLRegText(value,254,@"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")) return NO;
 NSString *local=[[value componentsSeparatedByString:@"@"] firstObject];
 return local.length<=64 && ![local hasPrefix:@"."] && ![local hasSuffix:@"."] && ![local containsString:@".."]; 
}
static BOOL ATLRegValidPayload(NSDictionary *p) {
 if(![p isKindOfClass:NSDictionary.class] || (p.count!=6 && p.count!=8)) return NO;
 NSSet *allowed=[NSSet setWithArray:@[@"id",@"email",@"username",@"password",@"fullName",@"zip",@"pickup_api",@"country"]];
 for(NSString *key in p)if(![allowed containsObject:key])return NO;
 if(p.count==8 && (!ATLBackupField(p[@"pickup_api"],4096) || !ATLBackupField(p[@"country"],80) || !ATLBackupField(p[@"password"],254) || !ATLBackupField(p[@"email"],254) || !ATLBackupField(p[@"username"],64)))return NO;
 return ATLRegText(p[@"id"],80,@"^[A-Za-z0-9-]+$") &&
  ATLRegEmail(p[@"email"]) &&
  ATLRegText(p[@"username"],64,@"^[\\x20-\\x7e]+$") &&
  ATLRegText(p[@"password"],254,@"^[\\x20-\\x7e]+$") &&
  ATLRegText(p[@"fullName"],100,@"^[\\x20-\\x7e]+$") &&
  ATLRegText(p[@"zip"],5,@"^[0-9]{5}$");
}
BOOL ATLRegistrationPayloadValid(NSDictionary *payload){return ATLRegValidPayload(payload);}
static NSString *ATLRegName(ATLRegState s) {
 switch(s){case ATL_REG_PENDING:return @"pending";case ATL_REG_PREPARING:return @"preparing";case ATL_REG_READY:return @"ready";case ATL_REG_SUBMITTING:return @"submitting";case ATL_REG_WAIT_CODE:return @"wait_code";case ATL_REG_CODE_READY:return @"code_ready";case ATL_REG_ENTERING_CODE:return @"entering_code";case ATL_REG_DONE:return @"done";case ATL_REG_ERROR:return @"error";case ATL_REG_REVIEW:return @"review";}
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
 if(!ATLRegRead(store,bytes,sizeof(bytes),&n)){
  memset(bytes,0,sizeof(bytes));struct stat st;int status=fstatat(store->dirfd,"registration-job.json",&st,AT_SYMLINK_NOFOLLOW);
  ATLRegError(error,status!=0 && errno==ENOENT?404:500,@"任务记录不存在或不可读取");return nil;
 }
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
  if(payload[@"pickup_api"] && !ATLBackupCapture(directory,payload)){ATLRegError(error,500,@"本机备份未保存，任务未接收");return nil;}
  NSMutableDictionary *job=[payload mutableCopy];job[@"state"]=@"pending";job[@"usernameFilled"]=@NO;if(!ATLRegSave(&store,job,error))return nil;ATLBackupExport(directory,job);return ATLRegPublic(job);
 } @finally {ATLRegClose(&store);}
}
NSDictionary *ATLRegistrationStatus(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return nil;
 @try {NSDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return nil;ATLBackupExport(directory,job);return ATLRegPublic(job);} @finally {ATLRegClose(&store);}
}
static NSDictionary *ATLRegClaim(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return nil;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || (jobID && !ATLRegMatch(job,jobID,error)))return nil;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,ATL_REG_CLAIM,&next)){ATLRegError(error,409,@"任务不能重复领取");return nil;}
  NSMutableDictionary *p=[job mutableCopy];[p removeObjectForKey:@"state"];[p removeObjectForKey:@"usernameFilled"];if(!ATLRegValidPayload(p)){ATLRegError(error,500,@"任务资料无效");return nil;}
  job[@"state"]=ATLRegName(next);if(!ATLRegSave(&store,job,error))return nil;ATLBackupExport(directory,job);return [job copy];
 } @finally {ATLRegClose(&store);}
}
NSDictionary *ATLRegistrationClaim(NSString *directory,NSString *jobID,NSError **error){
 if(!jobID){ATLRegError(error,400,@"任务编号无效");return nil;}return ATLRegClaim(directory,jobID,error);
}
NSDictionary *ATLRegistrationClaimPending(NSString *directory,NSError **error){return ATLRegClaim(directory,nil,error);}
BOOL ATLRegistrationAdvance(NSString *directory,NSString *jobID,ATLRegEvent event,NSError **error){
 if(error)*error=nil;if(event==ATL_REG_CLAIM || event==ATL_REG_CODE_STAGED || event==ATL_REG_CLAIM_CODE || event==ATL_REG_RESUME_VERIFICATION){ATLRegError(error,400,@"请通过领取接口操作");return NO;}ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,event,&next)){ATLRegError(error,409,@"任务阶段不允许此操作");return NO;}
  job[@"state"]=ATLRegName(next);
  if(event==ATL_REG_FIELDS_READY)job[@"usernameFilled"]=@YES; // Compatibility with older form scripts.
  if(next==ATL_REG_REVIEW || next==ATL_REG_ERROR || next==ATL_REG_DONE || next==ATL_REG_WAIT_CODE)
   for(NSString *key in @[@"password",@"email",@"username",@"fullName",@"zip",@"code",@"pickup_api",@"country"]) [job removeObjectForKey:key];
  if(!ATLRegSave(&store,job,error))return NO;ATLBackupExport(directory,job);return YES;
 } @finally {ATLRegClose(&store);}
}

BOOL ATLRegistrationUsernameFilled(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try{NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;
  if(![job[@"state"] isEqual:@"preparing"]){ATLRegError(error,409,@"用户名反馈阶段不匹配");return NO;}
  job[@"usernameFilled"]=@YES;if(!ATLRegSave(&store,job,error))return NO;
  if(!ATLBackupExport(directory,job)){ATLRegError(error,500,@"用户名反馈尚未保存，停止提交");return NO;}return YES;
 }@finally{ATLRegClose(&store);}
}

BOOL ATLRegistrationClear(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try {NSDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;ATLRegState state;
  if(!ATLRegStateForName(job[@"state"],&state) || !(state==ATL_REG_DONE || state==ATL_REG_ERROR || state==ATL_REG_REVIEW)){ATLRegError(error,409,@"任务仍在运行，不能清除");return NO;}
  if(!ATLBackupExport(directory,job)){ATLRegError(error,500,@"本机结果尚未导出，保留任务供重试");return NO;}
  if(ATLRegRemove(&store)!=1){ATLRegError(error,500,@"清除结果未确认，请核对");return NO;}return YES;
 } @finally {ATLRegClose(&store);}
}

// A workbench terminal result is authoritative. A stale logical state is not
// evidence that another script is executing; the caller already owns the run.
BOOL ATLRegistrationArchiveResult(NSString *directory,NSString *jobID,NSString *resultState,NSError **error){
 if(error)*error=nil;
 if(![@[@"done",@"error",@"sms_required",@"cancelled"] containsObject:resultState]){ATLRegError(error,400,@"最终结果格式无效");return NO;}
 ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try{
  NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;
  NSString *archiveDir=[directory stringByAppendingPathComponent:@"Retired"];
  if(![NSFileManager.defaultManager createDirectoryAtPath:archiveDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
  NSMutableDictionary *archived=[job mutableCopy];archived[@"workbenchResult"]=resultState;
  NSString *path=[archiveDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.json",jobID,NSUUID.UUID.UUIDString]];
  NSData *data=[NSJSONSerialization dataWithJSONObject:archived options:0 error:error];
  if(!data || ![data writeToFile:path options:NSDataWritingAtomic error:error] || chmod(path.fileSystemRepresentation,0600)!=0){ATLRegError(error,500,@"旧登记归档文件无法保存");return NO;}
  int archivedFD=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
  BOOL durable=archivedFD>=0 && fsync(archivedFD)==0;if(archivedFD>=0)close(archivedFD);
  int archivedDirFD=open(archiveDir.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_DIRECTORY);
  durable=durable && archivedDirFD>=0 && fsync(archivedDirFD)==0;if(archivedDirFD>=0)close(archivedDirFD);
  if(!durable){ATLRegError(error,500,@"旧登记归档文件无法落盘");return NO;}
  NSMutableDictionary *final=[job mutableCopy];final[@"state"]=[resultState isEqual:@"cancelled"]?@"error":resultState;
  if(!ATLBackupExport(directory,final)){ATLRegError(error,500,@"最终结果无法保存到本机文件");return NO;}
  if(ATLRegRemove(&store)!=1){ATLRegError(error,500,@"旧登记文件无法移除");return NO;}
  return YES;
 }@finally{ATLRegClose(&store);}
}

BOOL ATLRegistrationSetCode(NSString *directory,NSString *jobID,NSString *code,NSError **error){
 if(error)*error=nil;if(!ATLRegText(code,6,@"^(?:[0-9]{4}|[0-9]{6})$")){ATLRegError(error,400,@"验证码格式无效");return NO;}
 ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,ATL_REG_CODE_STAGED,&next)){ATLRegError(error,409,@"任务不等待验证码");return NO;}
  job[@"state"]=ATLRegName(next);job[@"code"]=code;if(!ATLRegSave(&store,job,error))return NO;ATLBackupExport(directory,job);return YES;
 } @finally {ATLRegClose(&store);}
}
NSDictionary *ATLRegistrationClaimCode(NSString *directory,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return nil;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job)return nil;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,ATL_REG_CLAIM_CODE,&next)){ATLRegError(error,409,@"验证码不能重复领取");return nil;}
  NSString *code=job[@"code"];if(!ATLRegText(code,6,@"^(?:[0-9]{4}|[0-9]{6})$")){ATLRegError(error,500,@"验证码记录无效");return nil;}
  NSDictionary *result=@{@"id":job[@"id"],@"code":code};[job removeObjectForKey:@"code"];job[@"state"]=ATLRegName(next);
  return ATLRegSave(&store,job,error)?result:nil;
 } @finally {ATLRegClose(&store);}
}

BOOL ATLRegistrationRecover(NSString *directory,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try {NSError *readError=nil;NSMutableDictionary *job=ATLRegLoad(&store,&readError);
  if(!job){if(readError.code==404)return YES;if(error)*error=readError;return NO;}
  ATLRegState state,next;if(!ATLRegStateForName(job[@"state"],&state)){ATLRegError(error,500,@"任务状态无效");return NO;}
  if(!(state==ATL_REG_PREPARING || state==ATL_REG_READY || state==ATL_REG_SUBMITTING || state==ATL_REG_CODE_READY || state==ATL_REG_ENTERING_CODE)){ATLBackupExport(directory,job);return YES;}
  if(!ATLRegStep(state,ATL_REG_INTERRUPTED,&next)){ATLRegError(error,500,@"任务恢复失败");return NO;}
  job[@"state"]=ATLRegName(next);for(NSString *key in @[@"password",@"email",@"username",@"fullName",@"zip",@"code",@"pickup_api",@"country"]) [job removeObjectForKey:key];
  if(!ATLRegSave(&store,job,error))return NO;ATLBackupExport(directory,job);return YES;
 } @finally {ATLRegClose(&store);}
}

BOOL ATLRegistrationResumeVerification(NSString *directory,NSString *jobID,NSError **error){
 if(error)*error=nil;ATLRegStore store;if(!ATLRegAcquire(directory,&store,error))return NO;
 @try {NSMutableDictionary *job=ATLRegLoad(&store,error);if(!job || !ATLRegMatch(job,jobID,error))return NO;ATLRegState state,next;
  if(!ATLRegStateForName(job[@"state"],&state) || !ATLRegStep(state,ATL_REG_RESUME_VERIFICATION,&next)){ATLRegError(error,409,@"任务不在待核对状态");return NO;}
  job[@"state"]=ATLRegName(next);if(!ATLRegSave(&store,job,error))return NO;ATLBackupExport(directory,job);return YES;
 } @finally {ATLRegClose(&store);}
}
