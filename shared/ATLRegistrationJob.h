#import <Foundation/Foundation.h>
#import "ATLRegistrationState.h"
FOUNDATION_EXPORT NSDictionary *ATLRegistrationCreate(NSString *directory, NSDictionary *payload, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLRegistrationStatus(NSString *directory, NSString *jobID, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLRegistrationClaimPending(NSString *directory, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLRegistrationClaim(NSString *directory, NSString *jobID, NSError **error);
FOUNDATION_EXPORT BOOL ATLRegistrationAdvance(NSString *directory, NSString *jobID, ATLRegEvent event, NSError **error);
FOUNDATION_EXPORT BOOL ATLRegistrationClear(NSString *directory, NSString *jobID, NSError **error);
FOUNDATION_EXPORT BOOL ATLRegistrationSetCode(NSString *directory, NSString *jobID, NSString *code, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLRegistrationClaimCode(NSString *directory, NSError **error);
FOUNDATION_EXPORT BOOL ATLRegistrationRecover(NSString *directory, NSError **error);
FOUNDATION_EXPORT BOOL ATLRegistrationResumeVerification(NSString *directory, NSString *jobID, NSError **error);
