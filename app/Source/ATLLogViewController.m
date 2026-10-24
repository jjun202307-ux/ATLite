#import "ATLLogViewController.h"
#import "ATLPaths.h"

// E24：日志查看页。职责：
//  1) 显示 <jbroot>/var/mobile/Library/ATLite/logs/tweak.log（多路径探测，容忍 jbroot 推导差异）
//  2) 找不到时输出诊断信息（候选路径 + 目录是否存在），直接区分
//     "tweak 没注入" 与 "注入了但没收到命令"
//  3) 自动刷新，运行脚本时可实时看到输出

@interface ATLLogViewController ()
@property (nonatomic, strong) UITextView *text;
@property (nonatomic, strong) UILabel *pathLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL autoRefresh;
@end

@implementation ATLLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";
    self.view.backgroundColor = [UIColor whiteColor];
    self.autoRefresh = YES;

    self.pathLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.pathLabel.font = [UIFont systemFontOfSize:10];
    self.pathLabel.textColor = [UIColor darkGrayColor];
    self.pathLabel.numberOfLines = 2;
    self.pathLabel.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    [self.view addSubview:self.pathLabel];

    self.text = [[UITextView alloc] initWithFrame:CGRectZero];
    self.text.editable = NO;
    self.text.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.text];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];
    [self setToolbarItems:@[
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearLog)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:@"自动刷新: 开" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(toggleAuto)]
    ] animated:NO];

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    // 评审 C2：尊重"自动刷新: 关"的状态，否则切后台再回来会复活定时器但按钮仍显示关
    if (self.autoRefresh) [self startTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [self stopTimer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat top = self.view.safeAreaInsets.top;
    // 评审 C1：必须减 bottom（工具栏可见时计入 safeAreaInsets.bottom），
    // 否则 textView 下沿被工具栏压住，最新几行日志（本页核心用途）看不见
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    self.pathLabel.frame = CGRectMake(0, top, w, 34);
    self.text.frame = CGRectMake(0, top + 34, w, MAX(h - top - 34 - bottom, 60));
    self.text.contentInset = UIEdgeInsetsMake(0, 0, 8, 0);
}

#pragma mark - Actions

- (void)toggleAuto {
    self.autoRefresh = !self.autoRefresh;
    self.toolbarItems.lastObject.title = self.autoRefresh ? @"自动刷新: 开" : @"自动刷新: 关";
    if (self.autoRefresh) [self startTimer]; else [self stopTimer];
}

- (void)startTimer {
    [self stopTimer];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                  target:self
                                                selector:@selector(reload)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)clearLog {
    NSString *p = ATLExistingLogPath();
    if (!p) p = [ATLLogsDir() stringByAppendingPathComponent:@"tweak.log"];
    [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self reload];
}

- (void)reload {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p = ATLExistingLogPath();
    if (!p) {
        // 诊断模式：把所有候选路径与目录状态摆出来，一眼区分"没注入"与"没收到命令"
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"未找到 tweak.log —— 诊断信息如下\n\n"];
        [s appendFormat:@"jbroot（App 侧推导）: %@\n", ATLJBRoot()];
        [s appendString:@"\n候选路径：\n"];
        for (NSString *c in ATLLogCandidatePaths()) {
            BOOL dirOK = [fm fileExistsAtPath:[c stringByDeletingLastPathComponent]];
            [s appendFormat:@"  %@\n     → logs 目录%@\n", c, dirOK ? @"存在" : @"不存在"];
        }
        [s appendString:@"\n判断方法：\n"];
        [s appendString:@"  全部『不存在』 → tweak 未注入 SpringBoard（装完需 respring / 重启设备）\n"];
        [s appendString:@"  logs 目录存在但无 log 文件 → tweak 已注入，但还没写过日志\n"];
        [s appendString:@"  有 log 但只有载入行、无 command 行 → 命令没送达（检查 App 与 tweak 的 jbroot 是否一致）\n"];
        self.text.text = s;
        self.text.textColor = [UIColor darkTextColor];
        self.pathLabel.text = @"tweak.log 不存在（诊断模式）";
        return;
    }

    NSData *d = [NSData dataWithContentsOfFile:p];
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    // 评审 C3：存在但读不到（权限/损坏）要与"文件不存在"区分开，否则会被误读为 tweak 没写日志
    if (!s) {
        self.text.text = [NSString stringWithFormat:
                          @"日志文件存在但读取失败（权限不足或内容非 UTF-8）\n路径: %@", p];
        self.text.textColor = [UIColor systemRedColor];
        self.pathLabel.text = p;
        return;
    }
    // 只保留尾部（日志可能很长）
    if (s.length > 100000) {
        s = [@"...（省略前部）\n" stringByAppendingString:[s substringFromIndex:s.length - 100000]];
    }
    self.text.text = s;
    self.text.textColor = [UIColor blackColor];
    self.pathLabel.text = p;
    if (s.length > 0) {
        [self.text scrollRangeToVisible:NSMakeRange(s.length - 1, 1)];
    }
}

@end
