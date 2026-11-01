#import <Foundation/Foundation.h>
/* The transport owns stdin/stdout. This core emits only job ID, state or generic errors. */
FOUNDATION_EXPORT int ATLRegistrationCLI(NSString *directory, NSString *operation, NSData *input, NSData **output);
