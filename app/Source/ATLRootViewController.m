#import <UIKit/UIKit.h>
#import "ATLRootViewController.h"
#import "ATLWebServer.h"
#import "ATLPaths.h"
#import "ATLCommand.h"
#import "ATLLogViewController.h"
#import <ifaddrs.h>
#import <arpa/inet.h>

@interface ATLRootViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) ATLWebServer *server;
@property (nonatomic, strong) NSMutableArray<NSString *> *scripts;
@end

@implementation ATLRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ATLite";
    self.scripts = [NSMutableArray array];

    // E23：IP 状态行作为 tableHeaderView。此前 self.view（UITableViewController 自带 tableView）
    // 上又 addSubview 了自建 table，把先加的 statusLabel 整个盖住（z-order 遮挡），IP 不可见。
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 56)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = [UIColor darkGrayColor];
    self.tableView.tableHeaderView = self.statusLabel;

    // E24：日志入口常驻导航栏，脚本"没反应"时一键查看 tweak 日志
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self action:@selector(refresh)];
    UIBarButtonItem *log = [[UIBarButtonItem alloc] initWithTitle:@"日志"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(openLog)];
    // E26：强停入口。脚本跑在 SpringBoard 里，划掉 App 对它无效 —— 必须给一个显式停止
    UIBarButtonItem *stop = [[UIBarButtonItem alloc] initWithTitle:@"⏹ 停止"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(stopScript)];
    stop.tintColor = [UIColor systemRedColor];
    self.navigationItem.rightBarButtonItems = @[stop, log, refresh];

    // 启动期任何异常都不允许杀死 App（v0.1.0 "打不开"的教训：启动链路必须防御）
    @try {
        [self seedBundledScripts]; // R9/E9：首次启动释放随包自检脚本
        [self startServer];
    } @catch (NSException *e) {
        self.statusLabel.text = [NSString stringWithFormat:@"启动异常: %@", e];
    }
    [self refresh];
}

#pragma mark - Bundled scripts (R9/E9)

// 首次启动：把随包的 test.at 复制进 Scripts 目录（已存在则不覆盖，尊重用户修改）
- (void)seedBundledScripts {
    if (!ATLScriptsDir().length) return;
    // M3：目录必须先建（fresh 环境下 tweak %ctor 可能还没跑过，copy 静默失败即 R9 落空）
    [[NSFileManager defaultManager] createDirectoryAtPath:ATLScriptsDir()
                              withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in @[@"test", @"email_roundtrip"]) {
        NSString *target = [ATLScriptsDir() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"at"]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:target]) continue;
        NSString *bundled = [[NSBundle mainBundle] pathForResource:name ofType:@"at"];
        NSError *error = nil;
        if (bundled && ![[NSFileManager defaultManager] copyItemAtPath:bundled toPath:target error:&error])
            NSLog(@"[ATLite] seed failed: %@", error);
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
    if (!dir.length) {
        self.statusLabel.text = @"无法确定当前越狱根目录，文件服务与命令已禁用";
        return;
    }
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
    BOOL sent = ATLSendCommand(@"run", name);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:sent ? @"已发送运行命令" : @"运行命令写入失败"
                                                                  message:sent ? name : @"请检查共享目录权限；命令尚未投递。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Stop (E26)

- (void)stopScript {
    BOOL sent = ATLSendStop();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:sent ? @"已发送强停" : @"停止命令写入失败"
        message:sent ? @"脚本会在下一个检查点停下（通常 <1 秒）。\n若日志显示仍在跑，说明它卡在抓屏，最多再等 1.5 秒看门狗。" : @"请检查共享目录权限；停止信号尚未投递。" 
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Log (E24)

- (void)openLog {
    [self.navigationController pushViewController:[[ATLLogViewController alloc] init] animated:YES];
}

#pragma mark - Data

- (void)refresh {
    [self.scripts removeAllObjects];
    NSString *scriptsPath = ATLScriptsDir();
    NSArray *files = scriptsPath.length ? [[NSFileManager defaultManager] contentsOfDirectoryAtPath:scriptsPath error:nil] : @[];
    for (NSString *f in files) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"at"] || [ext isEqualToString:@"lua"]) [self.scripts addObject:f];
    }
    [self.scripts sortUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"▶ 运行并查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self runScript:name];
        [self openLog];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[NSFileManager defaultManager] removeItemAtPath:[ATLScriptsDir() stringByAppendingPathComponent:name] error:nil];
        [self refresh];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // iPad action sheets require a source for their popover presentation.
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.sourceView = tableView;
    popover.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
