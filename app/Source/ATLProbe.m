#import "ATLProbe.h"
#import "ATLPaths.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <signal.h>
#import <sys/select.h>
#import <mach/mach_time.h>

// R33-F：读子进程输出的整体上限。探针做的事（dlopen + 一次 touch + 抓屏）
// 正常几百毫秒完成；卡住的最可能原因正是 RenderDisplay/RenderServer 的同步 IPC
// （E25/E30 同款死锁场景）。R30 铁律：凡跨线程、跨进程的同步等待都必须有超时。
// 超时后 kill 子进程并带着已读到的部分返回，绝不让本线程永久阻塞。
#define AT_PROBE_READ_TIMEOUT_SEC 8.0

// P1：App（mobile, no-sandbox, platform-application）能否 spawn app bundle 内的二进制。
// 三个判据缺一不可：文件是否存在 / 是否可执行 / posix_spawn 的 rc 与 errno。
NSString *ATLRunProbe(NSString *from) {
    NSString *exe = [NSBundle.mainBundle.bundlePath
                     stringByAppendingPathComponent:@"ATLiteProbe"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:exe]) {
        return [NSString stringWithFormat:@"PROBE_P1 FAIL 二进制缺失: %@", exe];
    }
    BOOL execOK = [fm isExecutableFileAtPath:exe];

    int fds[2];
    if (pipe(fds) != 0) return @"PROBE_P1 FAIL pipe() 失败";

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);

    NSString *base = ATLBaseDir();
    NSString *fromStr = from.length ? from : @"app";
    NSString *wStr = @"0", *hStr = @"0";
    UIScreen *sc = UIScreen.mainScreen;
    if (sc) {
        CGSize nb = sc.nativeBounds.size;
        wStr = [NSString stringWithFormat:@"%d", (int)nb.width];
        hStr = [NSString stringWithFormat:@"%d", (int)nb.height];
    }
    char *argv[] = { (char *)"ATLiteProbe",
                     (char *)"--base", (char *)base.UTF8String,
                     (char *)"--from", (char *)fromStr.UTF8String,
                     (char *)"--w",    (char *)wStr.UTF8String,
                     (char *)"--h",    (char *)hStr.UTF8String,
                     NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe.fileSystemRepresentation, &fa, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        return [NSString stringWithFormat:
                @"PROBE_P1 FAIL posix_spawn rc=%d errno=%d (%s) exec=%@ path=%@",
                rc, rc, strerror(rc), execOK ? @"YES" : @"NO", exe];
    }

    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    BOOL timedOut = NO;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + AT_PROBE_READ_TIMEOUT_SEC;
    for (;;) {
        CFAbsoluteTime left = deadline - CFAbsoluteTimeGetCurrent();
        if (left <= 0) { timedOut = YES; break; }
        struct timeval tv;
        tv.tv_sec = (long)left;
        tv.tv_usec = (suseconds_t)((left - (double)tv.tv_sec) * 1000000.0);
        fd_set rd;
        FD_ZERO(&rd);
        FD_SET(fds[0], &rd);
        int sel = select(fds[0] + 1, &rd, NULL, NULL, &tv);
        if (sel < 0) { if (errno == EINTR) continue; break; }
        if (sel == 0) { timedOut = YES; break; }
        ssize_t n = read(fds[0], tmp, sizeof tmp);
        if (n > 0) { [buf appendBytes:tmp length:(NSUInteger)n]; continue; }
        break; // 0 = EOF（子进程关了 stdout），<0 = 读错
    }
    close(fds[0]);

    NSString *partialOut = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    NSString *head = [NSString stringWithFormat:
                      @"PROBE_P1 spawn OK (pid=%d, exec=%@, base=%@, screen=%@x%@)\n",
                      pid, execOK ? @"YES" : @"NO", base, wStr, hStr];

    if (timedOut) {
        // 到点仍无新数据：探针大概率卡在某次同步 IPC 上。这正是需要知道的证据，
        // 但本线程绝不能陪它一起挂 —— kill 后带着已读到的部分返回。
        kill(pid, SIGKILL);
        int st = 0; waitpid(pid, &st, 0);
        return [NSString stringWithFormat:
                @"%@PROBE_P1 TIMEOUT after %.0fs — 已 kill(pid=%d)\n"
                @"判读：探针卡在某次同步调用里没返回。跑完 P3 之前卡住=spawn/exec 问题；"
                @"跑完 P3 之后卡住=P4/P5 的同步 IPC 不可用（这本身就是 P5 的结论：该 API 本机不能用）。\n"
                @"卡住前已读到的输出：\n%@",
                head, AT_PROBE_READ_TIMEOUT_SEC, pid, partialOut];
    }

    int status = 0;
    CFAbsoluteTime waitDeadline = CFAbsoluteTimeGetCurrent() + 2.0;
    while (waitpid(pid, &status, WNOHANG) == 0) {
        if (CFAbsoluteTimeGetCurrent() > waitDeadline) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            break;
        }
        usleep(50000);
    }
    return [NSString stringWithFormat:@"%@PROBE_P1 status=%d\n%@",
            head, status, partialOut];
}
