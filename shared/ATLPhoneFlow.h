#import <Foundation/Foundation.h>
typedef BOOL (^ATLPhoneFlowStopped)(void);
FOUNDATION_EXPORT NSDictionary *ATLPhoneFlow(NSString *base, NSString *action, NSInteger stage, ATLPhoneFlowStopped stopped, NSError **error);
// 2026-11-06 接码模块重构：Lua 侧解析判新后直接提交验证码（走 Registration 状态机，状态须 wait_code）。
FOUNDATION_EXPORT NSDictionary *ATLPhoneFlowCommitCode(NSString *base, NSString *code, NSError **error);
FOUNDATION_EXPORT NSString *ATLPhoneMailCode(NSString *page);
FOUNDATION_EXPORT NSString *ATLPhoneMailNewCode(NSString *page, NSString *baselineCode);
