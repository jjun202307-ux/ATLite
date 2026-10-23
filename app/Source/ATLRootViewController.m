#import <UIKit/UIKit.h>
#import "ATLRootViewController.h"
#import "ATLWebServer.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

// 与 tweak 共享的路径逻辑（App 侧独立实现）
static NSString *ATLJBRoot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/var/jb"]) return @"/var/jb";
    for (NSString *n in [fm contentsOfDirectoryAtPath:@"/var/mobile" error:nil]) {
        if ([n hasPrefix:@".jbroot-"]) return [@"/var/mobile/" stringByAppendingString:n];
    }
    return @"/var/jb";
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

    [self startServer];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top + 8;
    self.statusLabel.frame = CGRectMake(8, top, self.view.bounds.size.width - 16, 40);
    self.table.contentInset = UIEdgeInsetsMake(48, 0, 0, 0);
}

#pragma mark - Server

- (NSString *)deviceIPAddress {
    ifaddrs *ifs = NULL;
    NSMutableString *ip = [NSMutableString stringWithString:@"未获取到 IP"];
    if (getifaddrs(&ifs) == 0) {
        for (ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            NSString *name = [NSString stringWithUTF8String:i->ifa_name];
            if ([name hasPrefix:@"en"]) {
                char buf[INET_ADDRSTRLEN] = {0};
                struct sockaddr_in *sa = (struct sockaddr_in *)i->ifa_addr;
                inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf));
                ip = [NSString stringWithUTF8String:buf];
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
