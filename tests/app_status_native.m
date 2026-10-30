// Run on macOS: clang -fobjc-arc -framework Foundation tests/app_status_native.m -o /tmp/atl-status-test && /tmp/atl-status-test
#import <Foundation/Foundation.h>
#import "../app/Source/ATLStatusText.h"
int main(void) {
    @autoreleasepool {
        NSArray *invalid = @[@"{}", @"{\"running\":null}", @"{\"running\":[]}", @"{\"running\":{}}", @"{\"running\":\"yes\"}", @"[]", @"broken"];
        for (NSString *json in invalid) {
            NSCAssert([ATLStatusTextFromData([json dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"状态: 未知"], @"invalid record: %@", json);
        }
        NSCAssert([ATLStatusTextFromData(nil) containsString:@"未知"], @"missing");
        NSCAssert([ATLStatusTextFromData([@"{\"running\":false}" dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"状态: 空闲"], @"idle");
        NSCAssert([ATLStatusTextFromData([@"{\"running\":true,\"script\":\"test.at\"}" dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"状态: 运行中 · test.at"], @"running");
        NSCAssert([ATLStatusTextFromData([@"{\"running\":true,\"script\":null}" dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"状态: 未知"], @"bad script");
        NSLog(@"App status fixture tests passed");
    }
    return 0;
}
