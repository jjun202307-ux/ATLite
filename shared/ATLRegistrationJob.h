#import <Foundation/Foundation.h>
#import "ATLRegistrationState.h"
FOUNDATION_EXPORT NSDictionary *ATLRegistrationCreate(NSString *directory, NSDictionary *payload, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLRegistrationStatus(NSString *directory, NSString *jobID, NSError **error);
FOUNDATION_EXPORT NSDictionary *ATLRegistrationClaim(NSString *directory, NSString *jobID, NSError **error);
FOUNDATION_EXPORT BOOL ATLRegistrationAdvance(NSString *directory, NSString *jobID, ATLRegEvent event, NSError **error);
