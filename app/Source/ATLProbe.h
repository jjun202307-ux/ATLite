#import <Foundation/Foundation.h>

// 诊断探针：posix_spawn app bundle 内的 ATLiteProbe 并捕获 stdout。
// 不用 NSTask（iOS 私有个类），纯 POSIX + pipe —— 编译期就能暴露类型问题。
NSString *ATLRunProbe(NSString *from);
