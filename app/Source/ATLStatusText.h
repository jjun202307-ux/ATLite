#import <Foundation/Foundation.h>

// Treat disk JSON as untrusted even when normally produced by the tweak.
static inline NSString *ATLStatusTextFromData(NSData *data) {
    if (!data) return @"状态: 未知（tweak 未运行过脚本）";
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return @"状态: 未知";
    id running = value[@"running"];
    if (![running isKindOfClass:NSNumber.class]) return @"状态: 未知";
    if (![running boolValue]) return @"状态: 空闲";
    id script = value[@"script"];
    if (![script isKindOfClass:NSString.class]) return @"状态: 未知";
    return [NSString stringWithFormat:@"状态: 运行中 · %@", script];
}
