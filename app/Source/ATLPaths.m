#import "ATLPaths.h"
#import <UIKit/UIKit.h>

NSString * const ATLDarwinNotifyName = @"me.atlite.command";

// jbroot 推导（RESEARCH D1 的 App 侧落实）：
// 自身安装于 <jbroot>/Applications/ATLite.app —— 以 mainBundle.bundlePath 去后缀推导
// （与安装路径天然一致，不依赖探测），探测仅作回退。结果缓存，与 tweak 侧同模式。
NSString *ATLJBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bp = [NSBundle mainBundle].bundlePath;
        NSRange r = [bp rangeOfString:@"/Applications/ATLite.app" options:NSBackwardsSearch];
        if (r.location != NSNotFound && r.location > 0) {
            root = [bp substringToIndex:r.location];
            return;
        }
        // 回退：探测（未知安装方式下的兜底）
        // Dopamine-roothide 实证（DOBootstrapper.m）：/var/jb 是指向 jbroot 的 symlink；
        // jbroot 真实位置 /var/containers/Bundle/Application/.jbroot-<16hex>
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:@"/var/jb"]) { root = @"/var/jb"; return; }
        for (NSString *n in [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil]) {
            if ([n hasPrefix:@".jbroot-"]) {
                root = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:n];
                return;
            }
        }
        root = @"/var/jb"; // fallback
    });
    return root;
}

NSString *ATLBaseDir(void)    { return [ATLJBRoot() stringByAppendingString:@"/var/mobile/Library/ATLite"]; }
NSString *ATLScriptsDir(void) { return [ATLBaseDir() stringByAppendingPathComponent:@"Scripts"]; }
NSString *ATLImagesDir(void)  { return [ATLBaseDir() stringByAppendingPathComponent:@"Images"]; }
NSString *ATLLogsDir(void)    { return [ATLBaseDir() stringByAppendingPathComponent:@"logs"]; }
NSString *ATLCommandPath(void){ return [ATLBaseDir() stringByAppendingPathComponent:@"command.json"]; }

NSArray<NSString *> *ATLLogCandidatePaths(void) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    [roots addObject:ATLJBRoot()];
    [roots addObject:@"/var/jb"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil]) {
        if ([n hasPrefix:@".jbroot-"]) {
            [roots addObject:[@"/var/containers/Bundle/Application" stringByAppendingPathComponent:n]];
        }
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *r in roots) {
        NSString *p = [[[r stringByAppendingString:@"/var/mobile/Library/ATLite"]
                        stringByAppendingPathComponent:@"logs"]
                       stringByAppendingPathComponent:@"tweak.log"];
        if (![seen containsObject:p]) { [seen addObject:p]; [out addObject:p]; }
    }
    return out;
}

NSString *ATLExistingLogPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in ATLLogCandidatePaths()) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}
