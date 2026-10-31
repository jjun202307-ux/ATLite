#import "ATLProbe.h"
#import "ATLPaths.h"
#import "ATLFileIO.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <signal.h>
#import <sys/select.h>
#import <mach/mach_time.h>
#define AT_PROBE_MAX_OUTPUT (128 * 1024)
static double ATProbeNow(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
NSString *ATLRunProbe(NSString *from) {
    NSString *exe = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ATLiteProbe"];
    NSString *runID = NSUUID.UUID.UUIDString;
    if (![NSFileManager.defaultManager isExecutableFileAtPath:exe])
        return [NSString stringWithFormat:@"PROBE_P1 FAIL missing/not executable %@", exe];
    // UIKit is touched only on main; a busy main thread cannot block this worker forever.
    __block CGSize size = CGSizeZero;
    void (^snapshot)(void) = ^{ size = UIScreen.mainScreen.nativeBounds.size; };
    if (NSThread.isMainThread) snapshot();
    else {
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{ snapshot(); dispatch_semaphore_signal(ready); });
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
            // Never read a block variable concurrently with a late snapshot.
            return @"PROBE_P1 FAIL main-thread screen snapshot timeout; probe not started";
        }
    }
    NSString *w = [NSString stringWithFormat:@"%d", (int)size.width];
    NSString *h = [NSString stringWithFormat:@"%d", (int)size.height];
    NSString *caller = from.length ? from : @"app";
    int fds[2];
    if (pipe(fds)) return @"PROBE_P1 FAIL pipe";
    posix_spawn_file_actions_t fa;
    int actionRC = posix_spawn_file_actions_init(&fa);
    if (actionRC) { close(fds[0]); close(fds[1]); return @"PROBE_P1 FAIL spawn actions init"; }
    actionRC = posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    if (!actionRC) actionRC = posix_spawn_file_actions_addclose(&fa, fds[0]);
    if (!actionRC) actionRC = posix_spawn_file_actions_addclose(&fa, fds[1]);
    char *argv[] = { "ATLiteProbe", "--from", (char *)caller.UTF8String,
        "--run-id", (char *)runID.UTF8String, "--w", (char *)w.UTF8String,
        "--h", (char *)h.UTF8String, NULL };
    pid_t pid = 0;
    int rc = actionRC ?: posix_spawn(&pid, exe.fileSystemRepresentation, &fa, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&fa); close(fds[1]);
    if (rc) { close(fds[0]); return [NSString stringWithFormat:@"PROBE_P1 FAIL spawn rc=%d (%s)", rc, strerror(rc)]; }
    NSMutableData *buf = NSMutableData.data;
    double deadline = ATProbeNow() + 8.0;
    BOOL timedOut = NO, truncated = NO;
    int readError = 0;
    while (YES) {
        double left = deadline - ATProbeNow();
        if (left <= 0) { timedOut = YES; break; }
        struct timeval tv = { (long)left, (suseconds_t)((left - (long)left) * 1000000) };
        fd_set rd; FD_ZERO(&rd); FD_SET(fds[0], &rd);
        int sel = select(fds[0]+1, &rd, NULL, NULL, &tv);
        if (sel < 0) { if (errno == EINTR) continue; readError = errno; break; }
        if (!sel) { timedOut = YES; break; }
        char chunk[4096]; ssize_t n = read(fds[0], chunk, sizeof(chunk));
        if (n < 0) { if (errno == EINTR) continue; readError = errno; break; }
        if (!n) break;
        NSUInteger room = AT_PROBE_MAX_OUTPUT - buf.length;
        NSUInteger take = MIN(room, (NSUInteger)n);
        if (take) [buf appendBytes:chunk length:take];
        if (take < (NSUInteger)n) truncated = YES; // Drain excess without retaining it.
    }
    close(fds[0]);
    int status = 0, waitError = 0, killRC = 0, killError = 0;
    BOOL reaped = NO, killed = NO;
    double reapDeadline = ATProbeNow() + 1.0;
    while (ATProbeNow() < reapDeadline) {
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) { reaped = YES; break; }
        if (got < 0 && errno != EINTR) { waitError = errno; break; }
        if ((timedOut || readError) && !killed) {
            killed = YES; killRC = kill(pid, SIGKILL); killError = killRC ? errno : 0;
        }
        usleep(20000);
    }
    if (!reaped && !waitError && !killed) {
        killed = YES; killRC = kill(pid, SIGKILL); killError = killRC ? errno : 0;
        double finalDeadline = ATProbeNow() + 0.5;
        while (ATProbeNow() < finalDeadline) {
            pid_t got = waitpid(pid, &status, WNOHANG);
            if (got == pid) { reaped = YES; break; }
            if (got < 0 && errno != EINTR) { waitError = errno; break; }
            usleep(20000);
        }
    }
    NSString *out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"[output is invalid or truncated UTF-8]";
    BOOL terminal = [out containsString:[NSString stringWithFormat:@"run_id=%@ from=%@ PROBE_END", runID, caller]];
    NSString *result = [NSString stringWithFormat:@"PROBE_P1 run_id=%@ spawn pid=%d timeout=%d read_errno=%d reaped=%d wait_errno=%d kill_sent=%d kill_rc=%d kill_errno=%d status=%d terminal=%d truncated=%d\nDefault non-setuid diagnostic; NOT-ROOT limits P4/P5 interpretation. Missing terminal/exit is incomplete, not an API denial.\n%@", runID, pid, timedOut, readError, reaped, waitError, killed, killRC, killError, status, terminal, truncated, out];
    // Save only on the mobile App side. Latest result replaces prior bounded output.
    NSString *path = [ATLLogsDir() stringByAppendingPathComponent:@"probe-app.log"];
    NSError *saveError = nil;
    if (!ATLWriteDiagnosticResult(result, path, &saveError))
        result = [result stringByAppendingFormat:@"\nApp result save failed: %@ (path=%@)", saveError.localizedDescription, path];
    else
        result = [result stringByAppendingFormat:@"\nApp result saved: %@", path];
    return result;
}
