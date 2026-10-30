#import "ATLPaths.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

NSString * const ATLDarwinNotifyName = @"me.atlite.command";

// libroot's documented API returns the active bootstrap, avoiding stale .jbroot
// directory guesses. Source: opa334/libroot src/dyn.c and README.md.
NSString *ATLJBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *bp = [NSBundle mainBundle].bundlePath;
        NSString *suffix = @"/Applications/ATLite.app";
        NSString *ownRoot = [bp hasSuffix:suffix] && bp.length > suffix.length
            ? [bp substringToIndex:bp.length - suffix.length] : nil;
        const char *(*prefix)(void) = dlsym(RTLD_DEFAULT, "libroot_get_jbroot_prefix");
        void *library = NULL;
        if (!prefix) {
            library = dlopen("@rpath/libroot.dylib", RTLD_NOW | RTLD_LOCAL);
            if (!library && ownRoot)
                library = dlopen([[ownRoot stringByAppendingPathComponent:@"usr/lib/libroot.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
            if (library) prefix = dlsym(library, "libroot_get_jbroot_prefix");
        }
        const char *value = prefix ? prefix() : NULL;
        NSString *active = value ? [NSString stringWithUTF8String:value] : nil;
        BOOL directory = NO;
        if ([active hasPrefix:@"/"] && [fm fileExistsAtPath:active isDirectory:&directory] && directory)
            root = active;
        if (library) dlclose(library); // active has copied the provider's static bytes.
        if (root) return;
        directory = NO;
        if (ownRoot && [fm fileExistsAtPath:ownRoot isDirectory:&directory] && directory) {
            root = ownRoot;
            return;
        }
        directory = NO;
        if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&directory] && directory) {
            root = @"/var/jb";
            return;
        }
        // No active bootstrap is known: callers must disable writes and commands.
        root = nil;
    });
    return root;
}

NSString *ATLBaseDir(void)    { return [ATLJBRoot() stringByAppendingString:@"/var/mobile/Library/ATLite"]; }
NSString *ATLScriptsDir(void) { return [ATLBaseDir() stringByAppendingPathComponent:@"Scripts"]; }
NSString *ATLImagesDir(void)  { return [ATLBaseDir() stringByAppendingPathComponent:@"Images"]; }
NSString *ATLLogsDir(void)    { return [ATLBaseDir() stringByAppendingPathComponent:@"logs"]; }
NSString *ATLCommandPath(void){ return [ATLBaseDir() stringByAppendingPathComponent:@"command.json"]; }
NSString *ATLStopFlagPath(void){ return [ATLBaseDir() stringByAppendingPathComponent:@"stop.flag"]; }
NSString *ATLStatusPath(void)  { return [ATLBaseDir() stringByAppendingPathComponent:@"status.json"]; }

NSArray<NSString *> *ATLLogCandidatePaths(void) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (ATLJBRoot()) [roots addObject:ATLJBRoot()];
    // Do not search unrelated bootstrap roots for an old log.
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
