import os, pathlib, platform, shutil, subprocess, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class StopRace(unittest.TestCase):
    def test_production_stop_file_native(self):
        if os.name != 'posix':
            self.skipTest('POSIX file APIs required')
        cc = shutil.which('gcc')
        if not cc:
            self.skipTest('gcc required')
        with tempfile.TemporaryDirectory() as tmp:
            exe = pathlib.Path(tmp) / 'stop_file_native'
            subprocess.run([cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'tests/stop_file_native.c'), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_command_dedup_native(self):
        source = (ROOT / 'tweak/Tweak.xm').read_text(encoding='utf-8')
        self.assertIn('static BOOL ATClaimCommandID', source)
        self.assertTrue('ATCommandIDCapacity' in source, 'bounded command ID cache required')
        if platform.system() != 'Darwin':
            self.skipTest('Foundation native fixture requires macOS')
        start = source.index('static BOOL ATClaimCommandID')
        end = source.index('static void ATHandleCommand', start)
        logic = source[start:end]
        fixture = r'''#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
''' + logic + r'''
int main(void) { @autoreleasepool {
    __block int accepted = 0;
    dispatch_apply(1000, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t i) {
        (void)i; if (ATClaimCommandID(@"same")) __sync_fetch_and_add(&accepted, 1);
    });
    NSCAssert(accepted == 1, @"concurrent duplicate");
    NSCAssert(ATClaimCommandID(@"different"), @"different id");
    NSCAssert(!ATClaimCommandID(@"same"), @"delayed duplicate");
    NSCAssert(ATClaimCommandID(nil) && ATClaimCommandID(nil), @"legacy commands remain compatible");
    for (NSUInteger i = 0; i < 4096; i++) {
        NSCAssert(ATClaimCommandID([NSString stringWithFormat:@"id-%lu", (unsigned long)i]), @"unique ID");
    }
    NSCAssert(!ATClaimCommandID(@"id-0"), @"oldest retained ID remains deduplicated");
    NSCAssert(ATClaimCommandID(@"same"), @"old ID was evicted");
    NSCAssert(!ATClaimCommandID(@"same"), @"reinserted ID is deduplicated");
    NSCAssert(ATClaimCommandID(@"id-0"), @"next oldest ID was evicted");
    return 0;
} }
'''
        with tempfile.TemporaryDirectory() as tmp:
            src = pathlib.Path(tmp) / 'dedup.m'; src.write_text(fixture, encoding='utf-8')
            exe = pathlib.Path(tmp) / 'dedup'
            subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', str(src), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_production_stop_logic_native(self):
        if platform.system() != 'Darwin':
            self.skipTest('Foundation native fixture requires macOS')
        source = (ROOT / 'tweak/Tweak.xm').read_text(encoding='utf-8')
        start = source.index('static volatile uint32_t gStopGeneration')
        end = source.index('static void ATWriteStatus', start)
        logic = source[start:end]
        fixture = r'''
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <ATLStopFile.h>
static NSString *flag;
static NSString *ATStopFlagPath(void) { return flag; }
''' + logic + r'''
static void require(BOOL value, NSString *why) { if (!value) { NSLog(@"FAIL: %@", why); exit(1); } }
static void put(NSString *s) { require([s writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write"); }
int main(void) { @autoreleasepool {
 NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 require([[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:nil error:nil], @"mkdir");
 flag = [dir stringByAppendingPathComponent:@"stop.flag"];
 put(@"old");
 gRunStopSnapshot = [[@"old" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
 gRunStopGeneration = __sync_fetch_and_add(&gStopGeneration, 0);
 require(!ATShouldStop(), @"old stop must not block new run");
 put(@"new");
 require(ATShouldStop(), @"stop after run submission, notification lost");
 gRunStopSnapshot = [[@"new" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
 uint32_t beforeCAS = __sync_fetch_and_add(&gStopGeneration, 0);
 __sync_fetch_and_add(&gStopGeneration, 1); // notification between CAS and publication
 gRunStopGeneration = beforeCAS;
 require(ATShouldStop(), @"notification after admission must survive publication");
 gRunStopGeneration = __sync_fetch_and_add(&gStopGeneration, 0);
 require(!ATShouldStop(), @"ordinary run");
 __sync_fetch_and_add(&gStopGeneration, 1);
 require(ATShouldStop(), @"notification-only stop");
 gRunStopGeneration = __sync_fetch_and_add(&gStopGeneration, 0);
 gRunStopSnapshot = nil;
 require(ATShouldStop(), @"legacy request honors existing flag");
 [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
 return 0;
} }
'''
        with tempfile.TemporaryDirectory() as tmp:
            src = pathlib.Path(tmp)/'fixture.m'; src.write_text(fixture, encoding='utf-8')
            exe = pathlib.Path(tmp)/'fixture'
            subprocess.run(['clang','-fobjc-arc','-framework','Foundation','-I',str(ROOT / 'shared'),str(src),'-o',str(exe)],check=True)
            subprocess.run([str(exe)],check=True)

if __name__ == '__main__': unittest.main()
