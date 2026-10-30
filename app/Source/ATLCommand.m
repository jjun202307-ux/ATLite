#import "ATLCommand.h"
#import "ATLPaths.h"
#import <CoreFoundation/CoreFoundation.h>
#import "../../shared/ATLStopFile.h"

BOOL ATLSendCommand(NSString *action, NSString *scriptNameOrNil) {
    NSString *path = ATLCommandPath();
    if (!action.length || !path.length) return NO;
    NSMutableDictionary *cmd = [NSMutableDictionary dictionaryWithObject:action forKey:@"cmd"];
    cmd[@"commandId"] = NSUUID.UUID.UUIDString;
    if (scriptNameOrNil) cmd[@"script"] = scriptNameOrNil;
    if ([action isEqualToString:@"run"]) {
        NSString *stopPath = ATLStopFlagPath();
        if (!stopPath.length) return NO;
        unsigned char bytes[256]; size_t length = 0;
        int result = ATLReadStopFile(stopPath.fileSystemRepresentation, bytes, sizeof(bytes), &length);
        if (result < 0) return NO;
        NSData *stop = result ? [NSData dataWithBytes:bytes length:length] : nil;
        cmd[@"stopSnapshot"] = stop ? [stop base64EncodedStringWithOptions:0] : [NSNull null];
    }
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
    BOOL flagSaved = stopPath.length && [NSUUID.UUID.UUIDString writeToFile:stopPath atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    // 通道 1（快）：通知 + command.json
    ATLSendCommand(@"stop", nil);
    return flagSaved;
}
