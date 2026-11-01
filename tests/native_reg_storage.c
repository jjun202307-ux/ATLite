#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include "../shared/ATLRegistrationStorage.h"
int main(void) {
 char dir[]="/tmp/atlreg-XXXXXX";assert(mkdtemp(dir));
 ATLRegStore s;assert(ATLRegOpen(&s,dir));
 ATLRegStore second;assert(!ATLRegOpen(&second,dir));
 const char data[]="{\"id\":\"dummy\"}";
 assert(ATLRegWrite(&s,data,sizeof(data)-1,"first") == 1);
 char result[128]={0};size_t n=0;assert(ATLRegRead(&s,result,sizeof(result),&n));assert(n==sizeof(data)-1 && !memcmp(result,data,n));
 struct stat st;assert(fstatat(s.dirfd,"registration-job.json",&st,AT_SYMLINK_NOFOLLOW)==0);assert((st.st_mode&0777)==0600);
 assert(!ATLRegWrite(&s,data,sizeof(data)-1,"../bad"));
 assert(!ATLRegWrite(&s,data,ATL_REG_MAX_BYTES+1,"huge"));
 assert(!ATLRegRead(&s,result,1,&n));
 assert(linkat(s.dirfd,"registration-job.json",s.dirfd,"hardlink",0)==0);
 assert(!ATLRegRead(&s,result,sizeof(result),&n));assert(!ATLRegWrite(&s,data,sizeof(data)-1,"hard"));
 assert(unlinkat(s.dirfd,"hardlink",0)==0);
 int stale=openat(s.dirfd,".registration-stale.tmp",O_CREAT|O_EXCL|O_WRONLY,0600);assert(stale>=0);close(stale);
 assert(!ATLRegWrite(&s,data,sizeof(data)-1,"stale"));assert(unlinkat(s.dirfd,".registration-stale.tmp",0)==0);
 assert(ATLRegRead(&s,result,sizeof(result),&n));
 assert(unlinkat(s.dirfd,"registration-job.json",0)==0);
 assert(symlinkat("/etc/passwd",s.dirfd,"registration-job.json")==0);
 assert(!ATLRegRead(&s,result,sizeof(result),&n));assert(!ATLRegWrite(&s,data,sizeof(data)-1,"second"));
 assert(unlinkat(s.dirfd,"registration-job.json",0)==0);
 ATLRegClose(&s);assert(ATLRegOpen(&second,dir));ATLRegClose(&second);
 assert(chmod(dir,0755)==0);assert(!ATLRegOpen(&second,dir));assert(chmod(dir,0700)==0);
 char lock[256];assert(snprintf(lock,sizeof(lock),"%s/registration-job.lock",dir)>0);assert(unlink(lock)==0);assert(rmdir(dir)==0);
 return 0;
}
