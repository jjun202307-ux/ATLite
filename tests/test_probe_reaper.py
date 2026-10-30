import pathlib, subprocess, tempfile, unittest, os, shutil
class ProbeReaperTest(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix" and shutil.which("clang"), "requires POSIX and clang")
    def test_reaper_process_lifecycle(self):
        source = (pathlib.Path(__file__).parents[1] / 'tweak' / 'Tweak.xm').read_text(encoding='utf-8')
        start = source.index('typedef struct ATProbeReaper') if 'typedef struct ATProbeReaper' in source else -1
        assert start >= 0, 'probe has no single-owner reaper'
        end = source.index('// P2（阶段 0 探针）', start)
        body = source[start:end]
        harness = r'''
        #include <sys/types.h>
        #include <sys/wait.h>
        #include <signal.h>
        #include <unistd.h>
        #include <stdlib.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <errno.h>
        #define NSEC_PER_MSEC 1000000LL
        #define DISPATCH_TIME_NOW 0
        static void logargs(int n, ...) { (void)n; }
        #define ATLog(fmt,...) logargs(__VA_ARGS__)
        typedef void *dispatch_queue_t;
        static dispatch_queue_t ATReapQueue(void) { return (void *)1; }
        static void (*pending)(void *); static void *context;
        static long long dispatch_time(long long a, long long b) { return a+b; }
        static void dispatch_after_f(long long t, dispatch_queue_t q, void *c, void (*f)(void *)) { (void)t; (void)q; if (pending) abort(); pending=f; context=c; }
        static int kills, forced_stuck, forced_error;
        static pid_t test_waitpid(pid_t p, int *s, int flags) { if (forced_error) { errno=EINVAL; return -1; } return forced_stuck ? 0 : waitpid(p,s,flags); }
        static int test_kill(pid_t p, int sig) { kills++; return forced_stuck ? -1 : kill(p,sig); }
        #define waitpid test_waitpid
        #define kill test_kill
        ''' + body + r'''
        static void tick(void) { void (*f)(void *)=pending; void *c=context; pending=NULL; if (!f) abort(); f(c); }
        static void run(int slow) {
         pid_t p=fork(); if (p==0) { if (slow) sleep(60); _exit(0); }
         ATProbeReaper *r=(ATProbeReaper *)calloc(1,sizeof(*r)); if (!r) abort();
         r->pid=p; ATReapChildAsync(r);
         for (int i=0; pending && i<500; i++) { usleep(10000); tick(); }
         if (pending) { fprintf(stderr,"reaper did not finish\n"); exit(1); }
         if (waitpid(p,NULL,WNOHANG)!=-1 || errno!=ECHILD) { fprintf(stderr,"child not reaped\n"); exit(1); }
        }
        int main(void) { run(0); if (kills) return 2; run(1); if (kills!=1) return 3; pid_t p=fork(); if (!p) _exit(0); waitpid(p,NULL,0); ATProbeReaper *r=calloc(1,sizeof(*r)); r->pid=p; ATReapChildAsync(r); tick(); if (pending || kills!=1) return 4; forced_stuck=1; r=calloc(1,sizeof(*r)); r->pid=123; ATReapChildAsync(r); for (int i=0; pending && i<500; i++) tick(); if (pending || kills!=2) return 5; forced_stuck=0; forced_error=1; r=calloc(1,sizeof(*r)); r->pid=123; ATReapChildAsync(r); tick(); if (pending || kills!=2) return 6; puts("probe reaper exit, timeout, ECHILD and bounded failure passed"); return 0; }
        '''
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'test.c'; p.write_text(harness)
            subprocess.run(['clang', '-std=gnu11', '-Wall', '-Werror', str(p), '-o', str(p.with_suffix(''))], check=True)
            subprocess.run([str(p.with_suffix(''))], check=True)
    @unittest.skipUnless(os.name == "posix" and shutil.which("clang"), "requires POSIX and clang")
    def test_spawn_setup_failures(self):
        source = (pathlib.Path(__file__).parents[1] / 'tweak' / 'Tweak.xm').read_text(encoding='utf-8')
        start = source.index('    ATProbeReaper *reaper = (ATProbeReaper *)calloc')
        end = source.index('    NSString *runId', start)
        body = source[start:end]
        body = body.replace('NSString *probeLog = [ATLogsDir() stringByAppendingPathComponent:@"tweak.log"];', 'const char *probeLog = "test.log";')
        body = body.replace('probeLog.fileSystemRepresentation', 'probeLog')
        harness = r'''
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
typedef struct { int pid; } ATProbeReaper;
typedef int posix_spawn_file_actions_t;
static int fail, allocations, inits, opens, destroys, frees;
static void *alloc_test(size_t n, size_t s) { allocations++; return fail == 1 ? NULL : calloc(n,s); }
static void free_test(void *p) { frees++; free(p); }
static int init_test(posix_spawn_file_actions_t *p) { (void)p; inits++; return fail == 2 ? 12 : 0; }
static int open_test(posix_spawn_file_actions_t *p, int fd, const char *path, int flags, int mode) { (void)p; (void)fd; (void)path; (void)flags; (void)mode; opens++; return fail == 3 ? 13 : 0; }
static int destroy_test(posix_spawn_file_actions_t *p) { (void)p; destroys++; return 0; }
#define calloc alloc_test
#define free free_test
#define posix_spawn_file_actions_init init_test
#define posix_spawn_file_actions_addopen open_test
#define posix_spawn_file_actions_destroy destroy_test
#define ATLog(...) ((void)0)
static void run(void) {
''' + body + r'''
abort(); /* success path is outside this failure test */
}
int main(void) {
  for (fail=1; fail<=3; fail++) {
    allocations=inits=opens=destroys=frees=0; run();
    if (allocations!=1 || inits!=(fail>=2) || opens!=(fail>=3) || destroys!=(fail==3) || frees!=(fail>=2)) return fail;
  }
  puts("spawn setup failure cleanup passed"); return 0;
}
'''
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'test.c'; p.write_text(harness)
            subprocess.run(['clang', '-std=gnu11', '-Wall', '-Werror', str(p), '-o', str(p.with_suffix(''))], check=True)
            subprocess.run([str(p.with_suffix(''))], check=True)

if __name__ == "__main__": unittest.main()
