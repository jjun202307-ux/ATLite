#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

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

// 读取 energy-mode.plist 中已存在的字典（文件缺失/损坏返回空字典）。
static inline NSDictionary *ATLEnergySettingsDict(NSString *base) {
    NSString *path=[base stringByAppendingPathComponent:@"energy-mode.plist"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return @{};
    NSDictionary *value=[NSDictionary dictionaryWithContentsOfFile:path];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

// 识图（findImage）默认相似度阈值，UI 可调；未配置时默认 0.8。
// 仅影响 findImage 未显式传 similarity 参数的调用。
static inline double ATLEnergyImageSimilarity(NSString *base) {
    NSDictionary *d=ATLEnergySettingsDict(base);
    id v=d[@"imageSimilarity"];
    if ([v isKindOfClass:NSNumber.class]) {
        double s=[v doubleValue];
        if (isfinite(s) && s>0 && s<=1) return s;
    }
    return 0.8;
}

// OCR 识别级别，UI 可调，独立于节能开关；取值 @"fast" 或 @"accurate"。
// 未配置或非法时默认 @"accurate"（老模式行为）。语言跟 level 走：
// fast→en-US，accurate→zh-Hans+en-US。
static inline NSString *ATLEnergyOCRLevel(NSString *base) {
    NSDictionary *d=ATLEnergySettingsDict(base);
    id v=d[@"ocrLevel"];
    if ([v isKindOfClass:NSString.class]) {
        NSString *s=(NSString *)v;
        if ([s isEqualToString:@"fast"]) return @"fast";
        if ([s isEqualToString:@"accurate"]) return @"accurate";
    }
    return @"accurate";
}

// 保存可调参数（保留 enabled 字段，只更新给定键）。
// 参数以键值对传入，例如 @{@"imageSimilarity":@0.8, @"ocrLevel":@"fast"}。
static inline BOOL ATLSaveEnergySettings(NSString *base, NSDictionary *updates, NSError **error) {
    if (!base.length || ![updates isKindOfClass:NSDictionary.class]) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSMutableDictionary *merged=[ATLEnergySettingsDict(base) mutableCopy];
    [merged addEntriesFromDictionary:updates];
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:merged format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:[base stringByAppendingPathComponent:@"energy-mode.plist"] options:NSDataWritingAtomic error:error];
}
