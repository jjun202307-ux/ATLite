#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
static int fail_at, calls;
static int test_fsync(int fd) { calls++; if(calls==fail_at){errno=EIO;return -1;}return fsync(fd); }
#define ATL_REG_FSYNC test_fsync
#include "../shared/ATLRegistrationStorage.h"
int main(void) {
 char dir[]="/tmp/atlregfault-XXXXXX";assert(mkdtemp(dir));ATLRegStore s;assert(ATLRegOpen(&s,dir));
 const char old[]="old",updated[]="new";char out[10];size_t n;
 fail_at=0;calls=0;assert(ATLRegWrite(&s,old,3,"one")==1);
 fail_at=1;calls=0;assert(ATLRegWrite(&s,updated,3,"two")==0);assert(ATLRegRead(&s,out,sizeof(out),&n)&&n==3&&!memcmp(out,old,3));
 fail_at=2;calls=0;assert(ATLRegWrite(&s,updated,3,"three")==-1);assert(ATLRegRead(&s,out,sizeof(out),&n)&&n==3&&!memcmp(out,updated,3));
 assert(unlinkat(s.dirfd,"registration-job.json",0)==0);ATLRegClose(&s);
 char path[256];snprintf(path,sizeof(path),"%s/registration-job.lock",dir);assert(unlink(path)==0);assert(rmdir(dir)==0);return 0;
}
