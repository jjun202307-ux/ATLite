#import "ATLRegistrationCLI.h"
#import "ATLRegistrationJob.h"
#import "ATLRegistrationStorage.h"
#import <CoreFoundation/CoreFoundation.h>
int ATLRegistrationCLI(NSString *directory,NSString *operation,NSData *input,NSData **output) {
 if(!output) return 1;
 NSDictionary *result=nil;NSError *error=nil;
 if(![input isKindOfClass:NSData.class] || input.length==0 || input.length>ATL_REG_MAX_BYTES){
  result=@{@"error":@"请求无效",@"code":@400};
 } else {
  id request=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
  if(![request isKindOfClass:NSDictionary.class]) result=@{@"error":@"请求无效",@"code":@400};
  else if([operation isEqual:@"create"]) result=ATLRegistrationCreate(directory,request,&error);
  else if([operation isEqual:@"status"] && [request count]==1 && [request[@"id"] isKindOfClass:NSString.class]) result=ATLRegistrationStatus(directory,request[@"id"],&error);
  else if([operation isEqual:@"code"] && [request count]==2 && [request[@"id"] isKindOfClass:NSString.class] && [request[@"code"] isKindOfClass:NSString.class]) {
   if(ATLRegistrationSetCode(directory,request[@"id"],request[@"code"],&error)) result=@{@"state":@"code_ready"};
  }
  else if([operation isEqual:@"resume"] && [request count]==2 && [request[@"id"] isKindOfClass:NSString.class] && (request[@"confirmed"] && CFGetTypeID((__bridge CFTypeRef)request[@"confirmed"])==CFBooleanGetTypeID() && [request[@"confirmed"] boolValue])) {
   if(ATLRegistrationResumeVerification(directory,request[@"id"],&error)) result=@{@"state":@"wait_code"};
  }
  else if([operation isEqual:@"clear"] && [request count]==2 && [request[@"id"] isKindOfClass:NSString.class] && (request[@"confirmed"] && CFGetTypeID((__bridge CFTypeRef)request[@"confirmed"])==CFBooleanGetTypeID() && [request[@"confirmed"] boolValue])) {
   if(ATLRegistrationClear(directory,request[@"id"],&error)) result=@{@"state":@"cleared"};
  } else result=@{@"error":@"请求无效",@"code":@400};
 }
 if(!result) result=@{@"error":@"操作未完成，请核对任务状态",@"code":@(error.code?:500)};
 *output=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
 return result[@"error"]?1:0;
}
