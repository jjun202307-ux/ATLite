#import "ATLLogViewController.h"
#import "ATLPaths.h"
#import "ATLCommand.h"
#import "ATLProbe.h"

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
    ATLSendStop(); // E26 双通道
    [self reload];
}

// R33-E：probe.log 由两个不同进程写（App 侧自己 spawn 的那次 + SpringBoard 侧那次），
// 两者推导 jbroot 的链路不同（bundlePath vs dladdr）。tweak.log 早已用候选路径探测
// 来容忍这个差异，probe.log 必须同样处理，否则 SpringBoard 那份永远读不到，
// P2（B 模式的命脉）会静默丢失且不报错。
- (NSString *)probeLogPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *p = [ATLLogsDir() stringByAppendingPathComponent:@"probe.log"];
    if ([fm fileExistsAtPath:p]) return p;
    for (NSString *c in ATLLogCandidatePaths()) {
        NSString *q = [[c stringByDeletingLastPathComponent]
                       stringByAppendingPathComponent:@"probe.log"];
        if ([fm fileExistsAtPath:q]) return q;
    }
    return p; // 都还不存在时回落到首选路径，让"从未生成过"这件事能显示出来
}

// 阶段 0 探针（P1/P3/P4/P5）：Runner 输出与 probe.log 一起显示，便于一次复制回报
- (void)runProbe {
    if (self.timer) [self stopTimer];   // 自动刷新会覆盖结果，先停
    self.text.text = @"正在运行诊断探针…";
    NSString *logPath = [self probeLogPath];
    NSUInteger startLen = [[NSData dataWithContentsOfFile:logPath] length];
    // 一次点击拿全 P1+P2+P3+P4+P5：
    //   P1/P3/P4/P5 = App 侧 spawn，stdout 直接捕获
    //   P2          = 经现有命令通道让 SpringBoard 侧再 spawn 一次（结果同样进 probe.log）
    ATLSendCommand(@"probe", nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = ATLRunProbe(@"app");
        // R33-A：probe.log 是 append 模式，历史内容里早已存在 "from=springboard"。
        // 若在全文件上做 containsString，第二次点击会立刻命中上一次的残留、
        // 判定"已完成"，然后展示旧结论。下面只在"本次点击之后新增的那一段"里判断。
        NSString *fresh = @"";
        for (int i = 0; i < 40; i++) {
            NSData *d = [NSData dataWithContentsOfFile:logPath];
            if (d && d.length > startLen) {
                NSRange r = NSMakeRange(startLen, d.length - startLen);
                NSString *tail = [[NSString alloc] initWithData:[d subdataWithRange:r]
                                                       encoding:NSUTF8StringEncoding];
                if (tail && [tail containsString:@"from=springboard"]) { fresh = tail; break; }
            }
            [NSThread sleepForTimeInterval:0.2];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *sb;
            if (fresh.length) {
                sb = fresh;
            } else {
                sb = @"（SpringBoard 侧本次没有写入 probe.log）\n"
                     @"可能原因：tweak 未注入 SpringBoard / 命令未送达 / "
                     @"两侧 jbroot 推导不一致。对照下方路径与 tweak.log 的诊断信息判断。";
            }
            self.text.text = [NSString stringWithFormat:
                              @"%@\n\n---- probe.log（本次新增部分）----\n%@\n\n路径: %@",
                              out, sb, logPath];
            self.text.textColor = [UIColor blackColor];
            self.pathLabel.text = @"诊断探针结果（自动刷新已暂停，点『自动刷新』恢复）";
        });
    });
}

// 运行状态（tweak 写 status.json）：让"到底还在不在跑"不再是猜的
- (NSString *)statusText {
    NSData *d = [NSData dataWithContentsOfFile:ATLStatusPath()];
    if (!d) return @"状态: 未知（tweak 未运行过脚本）";
    NSDictionary *s = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![s isKindOfClass:[NSDictionary class]]) return @"状态: 未知";
    BOOL running = [s[@"running"] boolValue];
    NSString *name = s[@"script"] ?: @"";
    return running ? [NSString stringWithFormat:@"状态: 运行中 · %@", name]
                   : @"状态: 空闲";
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
    self.pathLabel.text = [NSString stringWithFormat:@"%@\n%@", [self statusText], p];
    if (s.length > 0) {
        [self.text scrollRangeToVisible:NSMakeRange(s.length - 1, 1)];
    }
}

@end
