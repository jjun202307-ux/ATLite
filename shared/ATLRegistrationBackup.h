// Phone-local fallback. Caller holds the registration job lock.
#import <Foundation/Foundation.h>
#import "ATLRegistrationStorage.h"
static BOOL ATLBackupField(id v,NSUInteger limit){
 return [v isKindOfClass:NSString.class] && [v length]<=limit && ![v containsString:@"----"] && [v rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
}
static NSString *ATLBackupDirectory(NSString *directory,NSString *jobID){
 return [[directory stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:jobID];
}
static BOOL ATLBackupSave(ATLRegStore *s,NSDictionary *p){
 NSData *d=[NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
 NSString *nonce=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
 return d && ATLRegWrite(s,d.bytes,d.length,nonce.UTF8String)==1;
}
static NSDictionary *ATLBackupRead(ATLRegStore *s){
 unsigned char b[ATL_REG_MAX_BYTES];size_t n=0;if(!ATLRegRead(s,b,sizeof(b),&n))return nil;
 NSData *d=[NSData dataWithBytes:b length:n];memset(b,0,sizeof(b));id p=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
 return [p isKindOfClass:NSDictionary.class]?p:nil;
}
static inline BOOL ATLBackupCapture(NSString *directory,NSDictionary *payload){
 NSString *path=ATLBackupDirectory(directory,payload[@"id"]);
 if(![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return NO;
 ATLRegStore s;if(!ATLRegOpen(&s,path.fileSystemRepresentation))return NO;
 @try{
  NSDictionary *existing=ATLBackupRead(&s);
  NSMutableDictionary *fields=[NSMutableDictionary dictionary];
  for(NSString *key in @[@"id",@"username",@"email",@"password",@"pickup_api",@"country"])fields[key]=payload[key]?:@"";
  if(existing){for(NSString *key in fields)if(![fields[key] isEqual:existing[key]])return NO;return YES;}
  struct stat st;if(fstatat(s.dirfd,"registration-job.json",&st,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT)return NO;
  return ATLBackupSave(&s,fields);
 }@finally{ATLRegClose(&s);}
}
// Failure leaves the private archive intact; Status/Recover retry without rerunning UI.
static BOOL ATLBackupExport(NSString *directory,NSDictionary *job){
 NSString *state=job[@"state"];
 NSDictionary *labels=@{@"pending":@"待手机处理",@"preparing":@"注册中",@"ready":@"注册中",@"submitting":@"注册中",@"code_ready":@"注册中",@"entering_code":@"注册中",@"review":@"待核对",@"error":@"失败",@"done":@"完成",@"wait_code":@"等待验证码"};
 NSString *label=[state isEqual:@"sms_required"]?@"需要接短信码":labels[state];if(!label)return YES;
 NSString *archive=ATLBackupDirectory(directory,job[@"id"]);struct stat st;
 if(lstat(archive.fileSystemRepresentation,&st)!=0)return errno==ENOENT; // Legacy jobs had no archive.
 ATLRegStore s;if(!ATLRegOpen(&s,archive.fileSystemRepresentation))return NO;
 @try{
  NSMutableDictionary *p=[ATLBackupRead(&s) mutableCopy];if(!p || ![p[@"id"] isEqual:job[@"id"]])return NO;
  for(NSString *k in @[@"username",@"email",@"password",@"pickup_api",@"country"])if(!ATLBackupField(p[k],4096))return NO;
  BOOL completed=[state isEqual:@"done"] || [state isEqual:@"sms_required"];
  if(completed && !p[@"completed"]){
   NSDateFormatter *f=[NSDateFormatter new];f.locale=[[NSLocale alloc]initWithLocaleIdentifier:@"en_US_POSIX"];f.dateFormat=@"yyyy/MM/dd HH:mm";
   p[@"completed"]=[f stringFromDate:NSDate.date];if(!ATLBackupSave(&s,p))return NO;
  }
  NSString *line=[[@[p[@"username"],p[@"email"],p[@"password"],p[@"pickup_api"],p[@"country"],label,completed?(p[@"completed"]?:@""):@""] componentsJoinedByString:@"----"] stringByAppendingString:@"\n"];
  NSString *files=[[[directory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Local/Files"] stringByResolvingSymlinksInPath];
  ATLRegStore out;if(!ATLRegOpen(&out,files.fileSystemRepresentation))return NO;
  @try{
   int fd=openat(out.dirfd,"results.txt",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);NSMutableData *all=[NSMutableData data];
   if(fd>=0){
    if(!ATLRegPrivateFile(fd) || fstat(fd,&st)!=0 || st.st_size<0 || st.st_size>16*1024*1024){close(fd);return NO;}
    unsigned char bytes[8192];ssize_t n;while((n=read(fd,bytes,sizeof(bytes)))!=0){if(n<0){if(errno==EINTR)continue;close(fd);return NO;}[all appendBytes:bytes length:(NSUInteger)n];if(all.length>16*1024*1024){close(fd);return NO;}}
    close(fd);
   }else if(errno!=ENOENT)return NO;
   NSString *old=[[NSString alloc]initWithData:all encoding:NSUTF8StringEncoding];if(!old || (old.length && ![old hasSuffix:@"\n"]))return NO;
   // Email is the stable account identity even before a username is generated.
   // Last state wins, including legacy duplicates; preserve unrelated/malformed rows.
   NSMutableArray *order=[NSMutableArray array];NSMutableDictionary *latest=[NSMutableDictionary dictionary];
   NSArray *incoming=[[old stringByAppendingString:line] componentsSeparatedByString:@"\n"];
   NSUInteger rawIndex=0;
   for(NSString *row in incoming){
    if(!row.length)continue;
    NSArray *fields=[row componentsSeparatedByString:@"----"];
    NSString *key=(fields.count==7 && [fields[1] length])?[@"email:" stringByAppendingString:[fields[1] lowercaseString]]:[NSString stringWithFormat:@"raw:%lu",(unsigned long)rawIndex++];
    if(!latest[key])[order addObject:key];latest[key]=row;
   }
   NSMutableString *updated=[NSMutableString string];
   for(NSString *key in order)[updated appendFormat:@"%@\n",latest[key]];
   if([updated isEqual:old])return YES;
   all=[[updated dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
   if(!all || all.length>16*1024*1024)return NO;
   NSString *temp=[@".result-" stringByAppendingString:NSUUID.UUID.UUIDString];
   fd=openat(out.dirfd,temp.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;
   BOOL ok=ATLRegPrivateFile(fd);size_t done=0;while(ok && done<all.length){ssize_t n=write(fd,(const char *)all.bytes+done,all.length-done);if(n<0 && errno==EINTR)continue;if(n<=0){ok=NO;break;}done+=(size_t)n;}
   if(ok && fsync(fd)!=0)ok=NO;if(close(fd)!=0)ok=NO;
   if(ok)ok=renameat(out.dirfd,temp.UTF8String,out.dirfd,"results.txt")==0;
   if(!ok){unlinkat(out.dirfd,temp.UTF8String,0);return NO;}return fsync(out.dirfd)==0;
  }@finally{ATLRegClose(&out);}
 }@finally{ATLRegClose(&s);}
}
