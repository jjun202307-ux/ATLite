#import <Foundation/Foundation.h>
#import <assert.h>
#import <sys/stat.h>
#import "../shared/ATLRegistrationJob.h"
int main(void) { @autoreleasepool {
 char path[]="/tmp/atlregjob-XXXXXX";assert(mkdtemp(path));NSString *base=[NSString stringWithUTF8String:path];
 NSDictionary *payload=@{@"id":@"test-1",@"email":@"dummy@example.invalid",@"username":@"dummy_user1",@"password":@"Aa1!@#-_.+",@"fullName":@"Test User",@"zip":@"02203"};
 NSError *e=nil;
 NSMutableDictionary *bad=[payload mutableCopy];bad[@"zip"]=@"2203";assert(!ATLRegistrationCreate(base,bad,&e) && e.code==400);
 bad=[payload mutableCopy];bad[@"zip"]=@"99999";e=nil;assert(!ATLRegistrationCreate(base,bad,&e) && e.code==400);
 bad=[payload mutableCopy];bad[@"email"]=@"bad..local@example.invalid";e=nil;assert(!ATLRegistrationCreate(base,bad,&e) && e.code==400);
 bad=[payload mutableCopy];bad[@"email"]=@"a@-bad.example";e=nil;assert(!ATLRegistrationCreate(base,bad,&e) && e.code==400);
 bad=[payload mutableCopy];bad[@"password"]=@"bad\nvalue";e=nil;assert(!ATLRegistrationCreate(base,bad,&e) && e.code==400);
 bad=[payload mutableCopy];bad[@"extra"]=@"value";e=nil;assert(!ATLRegistrationCreate(base,bad,&e) && e.code==400);
 e=nil;assert(!ATLRegistrationAdvance(base,@"test-1",ATL_REG_CLAIM,&e));
 e=nil;NSDictionary *public=ATLRegistrationCreate(base,payload,&e);assert(public && !e);assert([public[@"state"] isEqual:@"pending"]);assert(!public[@"password"] && !public[@"email"]);
 e=nil;assert(!ATLRegistrationCreate(base,payload,&e) && e.code==409);
 e=nil;assert(!ATLRegistrationClear(base,@"test-1",&e) && e.code==409);
 e=nil;NSDictionary *claimed=ATLRegistrationClaimPending(base,&e);assert(claimed && [claimed[@"password"] isEqual:payload[@"password"]]);
 e=nil;assert(!ATLRegistrationClaim(base,@"test-1",&e) && e.code==409);
 e=nil;assert(!ATLRegistrationClaimPending(base,&e) && e.code==409);
 e=nil;assert(!ATLRegistrationAdvance(base,@"wrong",ATL_REG_FIELDS_READY,&e) && e.code==409);
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_FIELDS_READY,&e));
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_BEGIN_SUBMIT,&e));
 e=nil;assert(!ATLRegistrationAdvance(base,@"test-1",ATL_REG_BEGIN_SUBMIT,&e) && e.code==409);
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_INTERRUPTED,&e));
 e=nil;public=ATLRegistrationStatus(base,@"test-1",&e);assert([public[@"state"] isEqual:@"review"] && !public[@"password"] && !public[@"email"]);
 e=nil;assert(!ATLRegistrationClear(base,@"wrong",&e) && e.code==409);
 NSString *job=[base stringByAppendingPathComponent:@"registration-job.json"];NSData *d=[NSData dataWithContentsOfFile:job];NSString *text=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];assert(![text containsString:@"Aa1!@#-_.+"] && ![text containsString:@"dummy@example.invalid"]);
 e=nil;assert(ATLRegistrationClear(base,@"test-1",&e));e=nil;assert(!ATLRegistrationStatus(base,@"test-1",&e) && e.code==404);
 e=nil;assert(ATLRegistrationCreate(base,payload,&e));e=nil;assert(ATLRegistrationClaimPending(base,&e));
 assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_FIELDS_READY,&e));assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_BEGIN_SUBMIT,&e));assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_VERIFICATION_SEEN,&e));
 e=nil;assert(!ATLRegistrationSetCode(base,@"wrong",@"001234",&e) && e.code==409);
 e=nil;assert(!ATLRegistrationSetCode(base,@"test-1",@"12a4",&e));e=nil;assert(ATLRegistrationSetCode(base,@"test-1",@"001234",&e));
 e=nil;assert(!ATLRegistrationSetCode(base,@"test-1",@"001234",&e) && e.code==409);
 e=nil;public=ATLRegistrationStatus(base,@"test-1",&e);assert([public[@"state"] isEqual:@"code_ready"] && !public[@"code"]);
 e=nil;NSDictionary *one=ATLRegistrationClaimCode(base,&e);assert([one[@"code"] isEqual:@"001234"]);
 e=nil;assert(!ATLRegistrationClaimCode(base,&e) && e.code==409);
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_INTERRUPTED,&e));d=[NSData dataWithContentsOfFile:job];text=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];assert(![text containsString:@"001234"]);
 e=nil;assert(ATLRegistrationClear(base,@"test-1",&e));
 e=nil;assert(ATLRegistrationCreate(base,payload,&e));assert(ATLRegistrationClaimPending(base,&e));
 e=nil;assert(ATLRegistrationRecover(base,&e));public=ATLRegistrationStatus(base,@"test-1",&e);assert([public[@"state"] isEqual:@"review"] && !public[@"password"]);
 e=nil;assert(!ATLRegistrationResumeVerification(base,@"wrong",&e) && e.code==409);
 e=nil;assert(ATLRegistrationResumeVerification(base,@"test-1",&e));public=ATLRegistrationStatus(base,@"test-1",&e);assert([public[@"state"] isEqual:@"wait_code"]);
 e=nil;assert(!ATLRegistrationResumeVerification(base,@"test-1",&e) && e.code==409);
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_INTERRUPTED,&e));assert(ATLRegistrationClear(base,@"test-1",&e));
 [[NSFileManager defaultManager] removeItemAtPath:job error:nil];[[NSFileManager defaultManager] removeItemAtPath:[base stringByAppendingPathComponent:@"registration-job.lock"] error:nil];[[NSFileManager defaultManager] removeItemAtPath:base error:nil];
 return 0;
} }
