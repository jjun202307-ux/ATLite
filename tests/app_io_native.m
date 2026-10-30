// macOS: clang -fobjc-arc -framework Foundation -framework CoreFoundation tests/app_io_native.m -o /tmp/atl-io-test && /tmp/atl-io-test
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../app/Source/ATLFileIO.h"
static NSString *commandPath;
static NSString *stopPath;
static NSUInteger notifications;
NSString *const ATLDarwinNotifyName = @"test.atlite.command";
NSString *ATLCommandPath(void) { return commandPath; }
NSString *ATLStopFlagPath(void) { return stopPath; }
// Observe the notification boundary; execute the production command implementation.
#define CFNotificationCenterPostNotification(...) ((void)(notifications++))
#import "../app/Source/ATLCommand.m"
#undef CFNotificationCenterPostNotification
int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSCAssert([fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:nil error:nil], @"temp directory");
        @try {
            commandPath = nil; stopPath = nil;
            NSCAssert(!ATLSendCommand(@"run",@"test.at") && !ATLSendStop() && notifications == 0, @"unknown root must fail closed");
            commandPath = [dir stringByAppendingPathComponent:@"missing/command.json"];
            stopPath = [dir stringByAppendingPathComponent:@"missing/stop.flag"];
            NSCAssert(!ATLSendCommand(@"run",@"test.at") && notifications == 0, @"failed write must not notify");
            NSCAssert(!ATLSendStop() && notifications == 0, @"both stop writes fail");
            commandPath = [dir stringByAppendingPathComponent:@"command.json"];
            NSCAssert(ATLSendCommand(@"run",@"test.at") && notifications == 1, @"successful delivery");
            NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:commandPath] options:0 error:nil];
            NSCAssert([cmd[@"cmd"] isEqual:@"run"] && [cmd[@"script"] isEqual:@"test.at"], @"wire command");
            commandPath = [dir stringByAppendingPathComponent:@"missing/command.json"];
            stopPath = [dir stringByAppendingPathComponent:@"stop.flag"];
            NSCAssert(ATLSendStop() && notifications == 1 && [fm fileExistsAtPath:stopPath], @"flag fallback");
            NSString *log = [dir stringByAppendingPathComponent:@"log"];
            NSMutableString *large = [NSMutableString string];
            for (NSUInteger i=0;i<100000;i++) [large appendString:@"你好\n"];
            [large appendString:@"END"];
            NSCAssert([large writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write log");
            NSString *tail = ATLReadLogTail(log,256*1024);
            NSCAssert(tail && [tail hasSuffix:@"END"] && [tail hasPrefix:@"...（省略前部）\n"] && tail.length < 256*1024+32, @"bounded multibyte tail");
            NSCAssert(ATLReadLogTail(dir,1024)==nil, @"reject directories");
            NSCAssert(ATLReadLogTail(log,0)==nil, @"reject zero bound");
            NSCAssert(ATLDeleteFile(log)==200 && ![fm fileExistsAtPath:log], @"actual deletion");
            NSCAssert(ATLDeleteFile(log)==404, @"missing deletion");
            // ENAMETOOLONG is a real I/O failure independent of user privileges.
            [@"file" writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *tooLong = [@"x" stringByPaddingToLength:300 withString:@"x" startingAtIndex:0];
            NSCAssert(ATLDeleteFile([dir stringByAppendingPathComponent:tooLong])==500, @"failed deletion");
            const unsigned char bad[]={0xff,0xfe};
            [[NSData dataWithBytes:bad length:2] writeToFile:log atomically:YES];
            NSCAssert(ATLReadLogTail(log,1024)==nil, @"invalid UTF8");
            NSLog(@"App I/O fixtures passed");
        } @finally { [fm removeItemAtPath:dir error:nil]; }
    }
    return 0;
}
