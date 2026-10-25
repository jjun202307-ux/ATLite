#import "ATLProbe.h"
#import "ATLPaths.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

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
    char tmp[4096]; ssize_t n;
    while ((n = read(fds[0], tmp, sizeof tmp)) > 0) [buf appendBytes:tmp length:(NSUInteger)n];
    close(fds[0]);
    int status = 0; waitpid(pid, &status, 0);

    NSString *out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    return [NSString stringWithFormat:
            @"PROBE_P1 spawn OK (pid=%d, status=%d, exec=%@, base=%@, screen=%@x%@)\n%@",
            pid, status, execOK ? @"YES" : @"NO", base, wStr, hStr, out];
}
