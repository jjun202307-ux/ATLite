#import <Foundation/Foundation.h>

// base must already exist. One bounded current job; terminal jobs may be replaced.
// Error codes are HTTP-shaped: 400 invalid input, 404 absent, 409 busy/stale, 500 I/O.
FOUNDATION_EXPORT NSDictionary *ATLEmailCreateJob(NSString *base, NSString *email, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLEmailClaimJob(NSString *base, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLEmailReadJob(NSString *base, NSError **error);
FOUNDATION_EXPORT BOOL ATLEmailFinishJob(NSString *base, NSString *jobId, NSString *email,
    NSString *username, NSArray<NSString *> *ocrLines, NSString *failure, NSError **error);
// Cancels stored state only. Stopping an executing script is a separate operation.
FOUNDATION_EXPORT BOOL ATLEmailCancelJob(NSString *base, NSString *jobId, NSError **error);
