#ifndef ATL_CHILD_PROCESS_H
#define ATL_CHILD_PROCESS_H
#include <spawn.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <poll.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#ifdef __cplusplus
extern "C" { extern char **environ; }
#else
extern char **environ;
#endif

enum { ATL_CHILD_OK, ATL_CHILD_SPAWN_FAILED, ATL_CHILD_IO_ERROR,
       ATL_CHILD_TIMEOUT, ATL_CHILD_CANCELLED, ATL_CHILD_OUTPUT_LIMIT,
       ATL_CHILD_EXIT_FAILED, ATL_CHILD_SIGNALED, ATL_CHILD_REAP_FAILED };
typedef struct {
    int status, systemError, spawned, reaped, exitCode, signal;
    size_t length;
} ATLChildResult;
static inline double ATLChildNow(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec / 1e9;
}
static inline int ATLChildDup(int fd) { return fcntl(fd, F_DUPFD_CLOEXEC, 3); }

// One owner creates, reads, terminates and reaps this child. All waits are bounded.
// The caller retains inputFD; only this routine's duplicates are closed here.
static inline ATLChildResult ATLRunChild(const char *exe, const char *requestID,
        int inputFD, char *output, size_t limit, double timeout,
        int (*cancelled)(void *), void *context) {
    ATLChildResult r; memset(&r, 0, sizeof(r)); r.exitCode = -1;
    int input = -1, readFD = -1, writeFD = -1, raw[2] = {-1,-1};
    pid_t pid = 0; int childStatus = 0, eof = 0;
    posix_spawn_file_actions_t actions; posix_spawnattr_t attr;
    int actionsReady = 0, attrReady = 0, rc = 0;
    double deadline = ATLChildNow() + timeout;
    if (!exe || !requestID || !output || !limit || inputFD < 0 || !isfinite(timeout) || timeout <= 0) {
        r.status = ATL_CHILD_IO_ERROR; r.systemError = EINVAL; return r;
    }
    input = ATLChildDup(inputFD);
    if (input < 0 || pipe(raw)) { r.systemError = errno; r.status = ATL_CHILD_IO_ERROR; goto cleanup; }
    readFD = ATLChildDup(raw[0]); writeFD = ATLChildDup(raw[1]);
    close(raw[0]); close(raw[1]); raw[0] = raw[1] = -1;
    if (readFD < 0 || writeFD < 0 || fcntl(readFD,F_SETFL,O_NONBLOCK) < 0) {
        r.systemError=errno; r.status=ATL_CHILD_IO_ERROR; goto cleanup;
    }
    rc=posix_spawn_file_actions_init(&actions);
    if (rc) goto setupFailure;
    actionsReady=1;
    rc=posix_spawnattr_init(&attr);
    if (rc) goto setupFailure;
    attrReady=1;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    rc=posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (rc) goto setupFailure;
#endif
    rc=posix_spawn_file_actions_adddup2(&actions,input,STDIN_FILENO);
    if (!rc) rc=posix_spawn_file_actions_adddup2(&actions,writeFD,STDOUT_FILENO);
    if (!rc) rc=posix_spawn_file_actions_addclose(&actions,input);
    if (!rc) rc=posix_spawn_file_actions_addclose(&actions,readFD);
    if (!rc) rc=posix_spawn_file_actions_addclose(&actions,writeFD);
    if (rc) goto setupFailure;
    {
        char parent[32]; snprintf(parent,sizeof(parent),"%ld",(long)getpid());
        char *argv[]={(char *)exe,(char *)"--request-id",(char *)requestID,
                      (char *)"--parent",parent,NULL};
        rc=posix_spawn(&pid,exe,&actions,&attr,argv,environ);
    }
    if (rc) goto setupFailure;
    r.spawned=1;
    close(writeFD);writeFD=-1;
    while (!(r.reaped && eof)) {
        if (!r.reaped) {
            pid_t got=waitpid(pid,&childStatus,WNOHANG);
            if (got==pid) r.reaped=1;
            else if (got<0 && errno!=EINTR) { r.status=ATL_CHILD_REAP_FAILED;r.systemError=errno;break; }
        }
        if (!eof) {
            char bytes[4096]; ssize_t n=read(readFD,bytes,sizeof(bytes));
            if (n>0) {
                size_t room=limit-r.length, take=(size_t)n<room?(size_t)n:room;
                memcpy(output+r.length,bytes,take);r.length+=take;
                if (take<(size_t)n) { r.status=ATL_CHILD_OUTPUT_LIMIT;break; }
            } else if (!n) eof=1;
            else if (errno!=EINTR && errno!=EAGAIN && errno!=EWOULDBLOCK) {
                r.status=ATL_CHILD_IO_ERROR;r.systemError=errno;break;
            }
        }
        if (r.reaped && eof) break;
        if (cancelled && cancelled(context)) { r.status=ATL_CHILD_CANCELLED;break; }
        double left=deadline-ATLChildNow();
        if (left<=0) { r.status=ATL_CHILD_TIMEOUT;break; }
        if (left>.02) left=.02;
        struct pollfd ready={readFD,POLLIN,0};
        int selected=poll(eof?NULL:&ready,eof?0:1,(int)(left*1000)+1);
        if (selected<0 && errno!=EINTR) { r.status=ATL_CHILD_IO_ERROR;r.systemError=errno;break; }
    }
    if (!r.reaped && r.status!=ATL_CHILD_REAP_FAILED) {
        // Check ownership immediately before terminating; ECHILD must never kill a reused PID.
        pid_t got=waitpid(pid,&childStatus,WNOHANG);
        if (got==pid) r.reaped=1;
        else if (got<0 && errno!=EINTR) { r.systemError=errno;r.status=ATL_CHILD_REAP_FAILED; }
        else if (!got) {
            if (kill(pid,SIGKILL) && errno!=ESRCH) r.systemError=errno;
            double end=ATLChildNow()+.5;
            while (ATLChildNow()<end) {
                got=waitpid(pid,&childStatus,WNOHANG);
                if (got==pid) { r.reaped=1;break; }
                if (got<0 && errno!=EINTR) { r.systemError=errno;break; }
                struct timespec pause={0,1000000};nanosleep(&pause,NULL);
            }
            if (!r.reaped) r.status=ATL_CHILD_REAP_FAILED;
        } else { r.systemError=EINTR;r.status=ATL_CHILD_REAP_FAILED; }
    }
    if (r.reaped) {
        if (WIFEXITED(childStatus)) r.exitCode=WEXITSTATUS(childStatus);
        if (WIFSIGNALED(childStatus)) r.signal=WTERMSIG(childStatus);
        if (!r.status && r.signal) r.status=ATL_CHILD_SIGNALED;
        else if (!r.status && r.exitCode) r.status=ATL_CHILD_EXIT_FAILED;
    }
    goto cleanup;
setupFailure:
    r.status=ATL_CHILD_SPAWN_FAILED;r.systemError=rc;
cleanup:
    if (attrReady) posix_spawnattr_destroy(&attr);
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    if (input>=0) close(input);
    if (readFD>=0) close(readFD);
    if (writeFD>=0) close(writeFD);
    if (raw[0]>=0) close(raw[0]);
    if (raw[1]>=0) close(raw[1]);
    return r;
}
#endif
