#pragma once
#import <Foundation/Foundation.h>

// 勾选即启用（enabled=true）；文件不存在/损坏时默认关闭（老模式），
// 避免未勾选却意外启用优化。默认模式 = 关闭节能 = 走 legacy 路径。
static inline BOOL ATLEnergyEnabled(NSString *base) {
    NSString *path=[base stringByAppendingPathComponent:@"energy-mode.plist"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;
    NSDictionary *value=[NSDictionary dictionaryWithContentsOfFile:path];
    return [value[@"enabled"] isKindOfClass:NSNumber.class] && [value[@"enabled"] boolValue];
}
static inline BOOL ATLSaveEnergyEnabled(NSString *base, BOOL enabled, NSError **error) {
    if (!base.length) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"enabled":@(enabled)} format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:[base stringByAppendingPathComponent:@"energy-mode.plist"] options:NSDataWritingAtomic error:error];
}
