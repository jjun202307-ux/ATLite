#pragma once
#import <Foundation/Foundation.h>

// A missing preference means the user-requested default. A damaged file falls
// back to the original path, rather than unexpectedly enabling an optimization.
static inline BOOL ATLEnergyEnabled(NSString *base) {
    NSString *path=[base stringByAppendingPathComponent:@"energy-mode.plist"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    NSDictionary *value=[NSDictionary dictionaryWithContentsOfFile:path];
    return [value[@"enabled"] isKindOfClass:NSNumber.class] && [value[@"enabled"] boolValue];
}
static inline BOOL ATLSaveEnergyEnabled(NSString *base, BOOL enabled, NSError **error) {
    if (!base.length) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"enabled":@(enabled)} format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:[base stringByAppendingPathComponent:@"energy-mode.plist"] options:NSDataWritingAtomic error:error];
}
