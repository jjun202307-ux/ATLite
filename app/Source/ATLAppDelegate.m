#import <UIKit/UIKit.h>
#import "ATLAppDelegate.h"
#import "ATLRootViewController.h"

@implementation ATLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    CGRect bounds = [UIScreen mainScreen].bounds;
    self.window = [[UIWindow alloc] initWithFrame:bounds];
    ATLRootViewController *vc = [[ATLRootViewController alloc] initWithStyle:UITableViewStylePlain];
    // E23：必须包 UINavigationController，否则 self.title 与 navigationItem 上的刷新按钮无处渲染
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:vc];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
