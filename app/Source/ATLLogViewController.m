#import "ATLLogViewController.h"
#import "ATLPaths.h"
#import "ATLCommand.h"
#import "ATLProbe.h"
#import "ATLStatusText.h"
#import "ATLFileIO.h"

// E24：日志查看页。职责：
//  1) 显示 <jbroot>/var/mobile/Library/ATLite/logs/tweak.log（多路径探测，容忍 jbroot 推导差异）
//  2) 找不到时输出诊断信息（候选路径 + 目录是否存在），直接区分
//     只报告文件证据，不能仅凭目录存在性判断注入
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
    // E26：日志页是最可能需要强停的地方（看着脚本跑疯了就想停）
    UIBarButtonItem *stopItem = [[UIBarButtonItem alloc] initWithTitle:@"⏹ 停止"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(stopScript)];
    stopItem.tintColor = [UIColor systemRedColor];
    [self setToolbarItems:@[
        stopItem,
        [[UIBarButtonItem alloc] initWithTitle:@"诊断探针" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(runProbe)],
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
    self.pathLabel.frame = CGRectMake(0, top, w, 44); // 两行：运行状态 + 日志路径
    self.text.frame = CGRectMake(0, top + 44, w, MAX(h - top - 44 - bottom, 60));
    self.text.contentInset = UIEdgeInsetsMake(0, 0, 8, 0);
}

#pragma mark - Actions

- (void)stopScript {
    BOOL sent = ATLSendStop();
    [self reload];
    if (!sent) self.pathLabel.text = @"停止信号未能可靠保存，请检查目录权限并重试";
}

// App output is captured directly. P2 is asynchronous and reported in tweak.log;
// a begin line never establishes completion of the SpringBoard probe.
- (void)runProbe {
    if (!ATLBaseDir().length) {
        self.text.text = @"无法确定当前越狱根目录，诊断探针已禁用";
        return;
    }
    self.autoRefresh = NO;
    self.toolbarItems.lastObject.title = @"自动刷新: 关";
    [self stopTimer];
    self.text.text = @"正在运行 App 诊断探针…";
    BOOL probeSent = ATLSendCommand(@"probe", nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = ATLRunProbe(@"app");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.text.text = [(probeSent ? out : [@"SpringBoard 探针命令写入失败；以下仅为 App 探针。\n" stringByAppendingString:out]) stringByAppendingString:probeSent ? @"\n\nP2: 已发送 SpringBoard 探针请求，未确认完成。请点刷新查看 tweak.log 中本次 run_id 的 spawn、PROBE_END 和退出状态；begin 只表示开始。App 结果保存状态见上方输出。" : @"\n\nP2: 未投递，命令文件写入失败。App 结果保存状态见上方输出。"];
            self.text.textColor = [UIColor blackColor];
            self.pathLabel.text = probeSent ? @"App 诊断结果（自动刷新: 关；P2 请查看 tweak.log）" : @"App 诊断结果（P2 投递失败）";
        });
    });
}

// 运行状态（tweak 写 status.json）：让"到底还在不在跑"不再是猜的
- (NSString *)statusText {
    NSString *path = ATLStatusPath();
    return ATLStatusTextFromData(path.length ? [NSData dataWithContentsOfFile:path] : nil);
}

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
    if (!p.length) { self.pathLabel.text = @"无法确定当前越狱根目录，无法清空日志"; return; }
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
        [s appendFormat:@"App 版本: %@\njbroot（App 侧推导）: %@\n", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown", ATLJBRoot()];
        [s appendString:@"\n候选路径：\n"];
        for (NSString *c in ATLLogCandidatePaths()) {
            BOOL dirOK = [fm fileExistsAtPath:[c stringByDeletingLastPathComponent]];
            [s appendFormat:@"  %@\n     → logs 目录%@\n", c, dirOK ? @"存在" : @"不存在"];
        }
        [s appendString:@"\n判断方法：\n"];
        [s appendString:@"  目录不存在：可能未加载、初始化失败、路径不一致或权限不足；安装后需重启桌面。\n"];
        [s appendString:@"  目录存在但无日志：仍不能确认注入，请检查插件加载与写入错误。\n"];
        [s appendString:@"  有 log 但只有载入行、无 command 行 → 命令没送达（检查 App 与 tweak 的 jbroot 是否一致）\n"];
        self.text.text = s;
        self.text.textColor = [UIColor darkTextColor];
        self.pathLabel.text = @"tweak.log 不存在（诊断模式）";
        return;
    }

    NSString *s = ATLReadLogTail(p, 256 * 1024);
    // 评审 C3：存在但读不到（权限/损坏）要与"文件不存在"区分开，否则会被误读为 tweak 没写日志
    if (!s) {
        self.text.text = [NSString stringWithFormat:
                          @"日志文件存在但读取失败（权限不足或内容非 UTF-8）\n路径: %@", p];
        self.text.textColor = [UIColor systemRedColor];
        self.pathLabel.text = p;
        return;
    }
    self.text.text = s;
    self.text.textColor = [UIColor blackColor];
    self.pathLabel.text = [NSString stringWithFormat:@"%@\n%@", [self statusText], p];
    if (s.length > 0) {
        [self.text scrollRangeToVisible:NSMakeRange(s.length - 1, 1)];
    }
}

@end
