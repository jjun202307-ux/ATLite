#import <UIKit/UIKit.h>
#import "ATLRootViewController.h"
#import "ATLWebServer.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

// jbroot 推导（RESEARCH D1 的 App 侧落实）：
// 自身安装于 <jbroot>/Applications/ATLite.app —— 以 mainBundle.bundlePath 去后缀推导
// （与安装路径天然一致，不依赖探测），探测仅作回退。结果缓存，与 tweak 侧同模式。
static NSString *ATLJBRoot(void) {
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
static NSString *ATLBaseDir(void) {
    return [ATLJBRoot() stringByAppendingString:@"/var/mobile/Library/ATLite"];
}
static NSString *ATLScriptsDir(void) {
    return [ATLBaseDir() stringByAppendingPathComponent:@"Scripts"];
}
static NSString *ATLCommandPath(void) {
    return [ATLBaseDir() stringByAppendingPathComponent:@"command.json"];
}

static NSString * const ATLDarwinNotify = @"me.atlite.command";

@interface ATLRootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) ATLWebServer *server;
@property (nonatomic, strong) NSMutableArray<NSString *> *scripts;
@end

@implementation ATLRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ATLite";
    self.scripts = [NSMutableArray array];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self action:@selector(refresh)];
    self.navigationItem.rightBarButtonItem = refresh;

    // 启动期任何异常都不允许杀死 App（v0.1.0 "打不开"的教训：启动链路必须防御）
    @try {
        [self seedBundledScripts]; // R9/E9：首次启动释放随包自检脚本
        [self startServer];
    } @catch (NSException *e) {
        self.statusLabel.text = [NSString stringWithFormat:@"启动异常: %@", e];
    }
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top + 8;
    self.statusLabel.frame = CGRectMake(8, top, self.view.bounds.size.width - 16, 40);
    self.table.contentInset = UIEdgeInsetsMake(48, 0, 0, 0);
}

#pragma mark - Bundled scripts (R9/E9)

// 首次启动：把随包的 test.at 复制进 Scripts 目录（已存在则不覆盖，尊重用户修改）
- (void)seedBundledScripts {
    // M3：目录必须先建（fresh 环境下 tweak %ctor 可能还没跑过，copy 静默失败即 R9 落空）
    [[NSFileManager defaultManager] createDirectoryAtPath:ATLScriptsDir()
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *testPath = [ATLScriptsDir() stringByAppendingPathComponent:@"test.at"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:testPath]) return;
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"test" ofType:@"at"];
    if (!bundled) return;
    NSError *err = nil;
    if ([[NSFileManager defaultManager] copyItemAtPath:bundled toPath:testPath error:&err]) {
        NSLog(@"[ATLite] seeded test.at -> %@", testPath);
    }
}

#pragma mark - Server

- (NSString *)deviceIPAddress {
    struct ifaddrs *ifs = NULL;
    NSMutableString *ip = [NSMutableString stringWithString:@"未获取到 IP"];
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            NSString *name = [NSString stringWithUTF8String:i->ifa_name];
            if ([name hasPrefix:@"en"]) {
                char buf[INET_ADDRSTRLEN] = {0};
                struct sockaddr_in *sa = (struct sockaddr_in *)i->ifa_addr;
                inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf));
                [ip setString:[NSString stringWithUTF8String:buf]];
                break;
            }
        }
        freeifaddrs(ifs);
    }
    return ip;
}

- (void)startServer {
    NSString *dir = ATLBaseDir();
    for (NSString *sub in @[@"Scripts", @"Images"]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[dir stringByAppendingPathComponent:sub]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    self.server = [[ATLWebServer alloc] initWithRootPath:dir port:8080];
    BOOL ok = [self.server start];
    NSString *ip = [self deviceIPAddress];
    self.statusLabel.text = ok
        ? [NSString stringWithFormat:@"电脑访问: http://%@:8080\n上传 .at 脚本与 .png 搜图模板（同一 Wi-Fi）", ip]
        : @"导入服务器启动失败（端口被占用？）";
}

#pragma mark - Run

- (void)runScript:(NSString *)name {
    NSDictionary *cmd = @{@"cmd": @"run", @"script": name};
    NSData *data = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    [data writeToFile:ATLCommandPath() atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)ATLDarwinNotify, NULL, NULL, YES);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已发送运行命令"
                                                                  message:name
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Data

- (void)refresh {
    [self.scripts removeAllObjects];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ATLScriptsDir() error:nil];
    for (NSString *f in files) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"at"] || [ext isEqualToString:@"lua"]) [self.scripts addObject:f];
    }
    [self.scripts sortUsingSelector:@selector(compare:)];
    [self.table reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.scripts.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *id = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:id];
    cell.textLabel.text = self.scripts[indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = self.scripts[indexPath.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"▶ 运行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self runScript:name];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[NSFileManager defaultManager] removeItemAtPath:[ATLScriptsDir() stringByAppendingPathComponent:name] error:nil];
        [self refresh];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
