#import <Foundation/Foundation.h>
#import <assert.h>
#import <sys/stat.h>
#import <unistd.h>
#import "../shared/ATLRegistrationJob.h"
int main(void){@autoreleasepool{
 char temp[]="/tmp/atlbackup-XXXXXX";assert(mkdtemp(temp));NSString *root=[NSString stringWithUTF8String:temp];
 NSFileManager *fm=NSFileManager.defaultManager;NSString *jobs=[root stringByAppendingPathComponent:@"Registration"];
 NSString *files=[root stringByAppendingPathComponent:@"Local/Files"];
 assert([fm createDirectoryAtPath:jobs withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
 assert([fm createDirectoryAtPath:files withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
 NSDictionary *p=@{@"id":@"offline-test",@"username":@"dummy_user",@"email":@"dummy@example.invalid",@"password":@"Aa1!",@"fullName":@"Test User",@"zip":@"02203",@"pickup_api":@"https://example.invalid/mail",@"country":@"美国"};
 NSError *e=nil;assert(ATLRegistrationCreate(jobs,p,&e));
 assert(ATLRegistrationClaimPending(jobs,&e));assert(ATLRegistrationAdvance(jobs,p[@"id"],ATL_REG_FIELDS_READY,&e));
 // Simulate unavailable Files storage at the instant the job ends.
 NSString *moved=[root stringByAppendingPathComponent:@"saved-files"];assert([fm moveItemAtPath:files toPath:moved error:nil]);
 assert(ATLRegistrationAdvance(jobs,p[@"id"],ATL_REG_INTERRUPTED,&e));
 NSString *jobText=[NSString stringWithContentsOfFile:[jobs stringByAppendingPathComponent:@"registration-job.json"] encoding:NSUTF8StringEncoding error:nil];assert(![jobText containsString:@"Aa1!"]);
 assert([fm moveItemAtPath:moved toPath:files error:nil]);
 assert(ATLRegistrationStatus(jobs,p[@"id"],&e));
 NSString *path=[files stringByAppendingPathComponent:@"results.txt"];
 NSString *first=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
 assert([first containsString:@"dummy_user----dummy@example.invalid----Aa1!----https://example.invalid/mail----美国----待核对----"]);
 assert(ATLRegistrationStatus(jobs,p[@"id"],&e));assert([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:first]);
 assert(ATLRegistrationClear(jobs,p[@"id"],&e));assert([fm fileExistsAtPath:path]);
 struct stat st;assert(stat(path.fileSystemRepresentation,&st)==0 && (st.st_mode&0777)==0600);
 // A symlink must never cause another file to be overwritten.
 assert([fm removeItemAtPath:path error:nil]);NSString *sentinel=[root stringByAppendingPathComponent:@"sentinel"];
 assert([@"keep" writeToFile:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil]);assert(symlink(sentinel.fileSystemRepresentation,path.fileSystemRepresentation)==0);
 assert(ATLRegistrationCreate(jobs,p,&e));assert([[NSString stringWithContentsOfFile:sentinel encoding:NSUTF8StringEncoding error:nil] isEqual:@"keep"]);
 assert([fm removeItemAtPath:path error:nil]);
 assert(ATLRegistrationClaimPending(jobs,&e));assert(ATLRegistrationAdvance(jobs,p[@"id"],ATL_REG_FIELDS_READY,&e));assert(ATLRegistrationAdvance(jobs,p[@"id"],ATL_REG_BEGIN_SUBMIT,&e));assert(ATLRegistrationAdvance(jobs,p[@"id"],ATL_REG_VERIFICATION_SEEN,&e));
 assert(ATLRegistrationSetCode(jobs,p[@"id"],@"1234",&e));assert(ATLRegistrationClaimCode(jobs,&e));assert(ATLRegistrationAdvance(jobs,p[@"id"],ATL_REG_SUCCESS_CONFIRMED,&e));
 NSString *completed=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];assert([completed containsString:@"----完成----20"]);
 assert(ATLRegistrationStatus(jobs,p[@"id"],&e));assert([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:completed]);
 [fm removeItemAtPath:root error:nil];return 0;
}}
