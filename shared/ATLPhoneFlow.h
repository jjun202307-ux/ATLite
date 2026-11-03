#import <Foundation/Foundation.h>
typedef BOOL (^ATLPhoneFlowStopped)(void);
FOUNDATION_EXPORT NSDictionary *ATLPhoneFlow(NSString *base, NSString *action, NSInteger stage, ATLPhoneFlowStopped stopped, NSError **error);
FOUNDATION_EXPORT NSString *ATLPhoneMailCode(NSString *page);
