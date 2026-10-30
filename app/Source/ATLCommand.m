#import "ATLCommand.h"
#import "ATLPaths.h"
#import <CoreFoundation/CoreFoundation.h>

BOOL ATLSendCommand(NSString *action, NSString *scriptNameOrNil) {
    NSString *path = ATLCommandPath();
    if (!action.length || !path.length) return NO;
    NSMutableDictionary *cmd = [NSMutableDictionary dictionaryWithObject:action forKey:@"cmd"];
    if (scriptNameOrNil) cmd[@"script"] = scriptNameOrNil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    if (!data || ![data writeToFile:path atomically:YES]) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)ATLDarwinNotifyName,
                                         NULL, NULL, YES);
    return YES;
}

BOOL ATLSendStop(void) {
    // 通道 2（兜底）：文件标志。脚本在 hook / sleep 分片里会自己检查它。
    NSString *stopPath = ATLStopFlagPath();
    BOOL flagSaved = stopPath.length && [@"1" writeToFile:stopPath atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    // 通道 1（快）：通知 + command.json
    BOOL commandSaved = ATLSendCommand(@"stop", nil);
    return flagSaved || commandSaved;
}
