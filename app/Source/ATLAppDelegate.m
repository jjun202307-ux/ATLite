#import <UIKit/UIKit.h>
#import "ATLAppDelegate.h"
#import "ATLRootViewController.h"

@implementation ATLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    CGRect bounds = [UIScreen mainScreen].bounds;
    self.window = [[UIWindow alloc] initWithFrame:bounds];
    self.window.rootViewController = [[ATLRootViewController alloc] initWithStyle:UITableViewStylePlain];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
