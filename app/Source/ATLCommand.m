#import "ATLCommand.h"
#import "ATLPaths.h"
#import <CoreFoundation/CoreFoundation.h>

void ATLSendCommand(NSString *action, NSString *scriptNameOrNil) {
    if (!action.length) return;
    NSMutableDictionary *cmd = [NSMutableDictionary dictionaryWithObject:action forKey:@"cmd"];
    if (scriptNameOrNil) cmd[@"script"] = scriptNameOrNil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    if (data) [data writeToFile:ATLCommandPath() atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)ATLDarwinNotifyName,
                                         NULL, NULL, YES);
}

void ATLSendStop(void) {
    // 通道 2（兜底）：文件标志。脚本在 hook / sleep 分片里会自己检查它。
    [@"1" writeToFile:ATLStopFlagPath() atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    // 通道 1（快）：通知 + command.json
    ATLSendCommand(@"stop", nil);
}
