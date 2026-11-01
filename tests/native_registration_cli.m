#import <Foundation/Foundation.h>
#import <assert.h>
#import "../shared/ATLRegistrationCLI.h"
#import "../shared/ATLRegistrationJob.h"
int main(void) { @autoreleasepool {
 char path[]="/tmp/atlregcli-XXXXXX";assert(mkdtemp(path));NSString *dir=[NSString stringWithUTF8String:path];
 NSDictionary *p=@{@"id":@"cli-1",@"email":@"dummy@example.invalid",@"username":@"dummy_user1",@"password":@"Dummy1!",@"fullName":@"Test User",@"zip":@"02203"};
 NSData *input=[NSJSONSerialization dataWithJSONObject:p options:0 error:nil],*out=nil;
 assert(ATLRegistrationCLI(dir,@"create",input,&out)==0);NSString *response=[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];assert(![response containsString:@"Dummy1!"] && ![response containsString:@"dummy@example.invalid"]);
 assert(ATLRegistrationCLI(dir,@"create",input,&out)!=0);
 NSData *query=[@"{\"id\":\"cli-1\"}" dataUsingEncoding:NSUTF8StringEncoding];assert(ATLRegistrationCLI(dir,@"status",query,&out)==0);
 NSDictionary *status=[NSJSONSerialization JSONObjectWithData:out options:0 error:nil];assert([status[@"state"] isEqual:@"pending"] && !status[@"password"]);
 assert(ATLRegistrationCLI(dir,@"clear",query,&out)!=0);assert(ATLRegistrationCLI(dir,@"status",input,&out)!=0);
 assert(ATLRegistrationCLI(dir,@"unsafe",input,&out)!=0);assert(ATLRegistrationCLI(dir,@"create",[NSMutableData dataWithLength:16385],&out)!=0);
 NSError *error=nil;assert(ATLRegistrationClaim(dir,@"cli-1",&error));assert(ATLRegistrationAdvance(dir,@"cli-1",ATL_REG_FIELDS_READY,&error));assert(ATLRegistrationAdvance(dir,@"cli-1",ATL_REG_BEGIN_SUBMIT,&error));assert(ATLRegistrationAdvance(dir,@"cli-1",ATL_REG_VERIFICATION_SEEN,&error));
 NSData *code=[@"{\"id\":\"cli-1\",\"code\":\"001234\"}" dataUsingEncoding:NSUTF8StringEncoding];assert(ATLRegistrationCLI(dir,@"code",code,&out)==0);response=[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];assert(![response containsString:@"001234"]);
 assert(ATLRegistrationClaimCode(dir,&error));assert(ATLRegistrationAdvance(dir,@"cli-1",ATL_REG_INTERRUPTED,&error));
 NSData *numeric=[@"{\"id\":\"cli-1\",\"confirmed\":1}" dataUsingEncoding:NSUTF8StringEncoding];assert(ATLRegistrationCLI(dir,@"clear",numeric,&out)!=0);
 assert(ATLRegistrationCLI(dir,@"resume",numeric,&out)!=0);
 NSData *clear=[@"{\"id\":\"cli-1\",\"confirmed\":true}" dataUsingEncoding:NSUTF8StringEncoding];
 assert(ATLRegistrationCLI(dir,@"resume",clear,&out)==0);assert(ATLRegistrationCLI(dir,@"clear",clear,&out)!=0);
 assert(ATLRegistrationSetCode(dir,@"cli-1",@"001234",&error));assert(ATLRegistrationClaimCode(dir,&error));assert(ATLRegistrationAdvance(dir,@"cli-1",ATL_REG_INTERRUPTED,&error));
 assert(ATLRegistrationCLI(dir,@"clear",clear,&out)==0);assert(ATLRegistrationCLI(dir,@"status",query,&out)!=0);
 NSFileManager *fm=NSFileManager.defaultManager;[fm removeItemAtPath:[dir stringByAppendingPathComponent:@"registration-job.json"] error:nil];[fm removeItemAtPath:[dir stringByAppendingPathComponent:@"registration-job.lock"] error:nil];[fm removeItemAtPath:dir error:nil];return 0;
} }
