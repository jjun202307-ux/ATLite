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
 e=nil;NSDictionary *claimed=ATLRegistrationClaim(base,@"test-1",&e);assert(claimed && [claimed[@"password"] isEqual:payload[@"password"]]);
 e=nil;assert(!ATLRegistrationClaim(base,@"test-1",&e) && e.code==409);
 e=nil;assert(!ATLRegistrationAdvance(base,@"wrong",ATL_REG_FIELDS_READY,&e) && e.code==409);
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_FIELDS_READY,&e));
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_BEGIN_SUBMIT,&e));
 e=nil;assert(!ATLRegistrationAdvance(base,@"test-1",ATL_REG_BEGIN_SUBMIT,&e) && e.code==409);
 e=nil;assert(ATLRegistrationAdvance(base,@"test-1",ATL_REG_INTERRUPTED,&e));
 e=nil;public=ATLRegistrationStatus(base,@"test-1",&e);assert([public[@"state"] isEqual:@"review"] && !public[@"password"] && !public[@"email"]);
 NSString *job=[base stringByAppendingPathComponent:@"registration-job.json"];NSData *d=[NSData dataWithContentsOfFile:job];NSString *text=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];assert(![text containsString:@"Aa1!@#-_.+"] && ![text containsString:@"dummy@example.invalid"]);
 [[NSFileManager defaultManager] removeItemAtPath:job error:nil];[[NSFileManager defaultManager] removeItemAtPath:[base stringByAppendingPathComponent:@"registration-job.lock"] error:nil];[[NSFileManager defaultManager] removeItemAtPath:base error:nil];
 return 0;
} }
