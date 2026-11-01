#ifndef ATL_REGISTRATION_STORAGE_H
#define ATL_REGISTRATION_STORAGE_H
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>

#ifndef ATL_REG_FSYNC
#define ATL_REG_FSYNC fsync
#endif
#define ATL_REG_MAX_BYTES 16384u
typedef struct { int dirfd; int lockfd; } ATLRegStore;
static inline void ATLRegClose(ATLRegStore *s) {
 if (!s) return;
 if (s->lockfd>=0) { flock(s->lockfd,LOCK_UN); close(s->lockfd); s->lockfd=-1; }
 if (s->dirfd>=0) { close(s->dirfd); s->dirfd=-1; }
}
static inline int ATLRegPrivateFile(int fd) {
 struct stat st;
 return fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==geteuid() && st.st_nlink==1 && (st.st_mode&0777)==0600;
}
static inline int ATLRegOpen(ATLRegStore *s,const char *dir) {
 struct stat st;
 if (!s || !dir) return 0;
 s->dirfd=-1;s->lockfd=-1;
 s->dirfd=open(dir,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if (s->dirfd<0) return 0;
 if (fstat(s->dirfd,&st)!=0 || !S_ISDIR(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&077)!=0) { ATLRegClose(s);return 0; }
 s->lockfd=openat(s->dirfd,"registration-job.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
 if (s->lockfd<0 || !ATLRegPrivateFile(s->lockfd)) { ATLRegClose(s);return 0; }
 if (flock(s->lockfd,LOCK_EX|LOCK_NB)!=0) { close(s->lockfd);s->lockfd=-1;ATLRegClose(s);return 0; }
 return 1;
}
static inline int ATLRegRead(ATLRegStore *s,void *out,size_t capacity,size_t *length) {
 if (!s || s->lockfd<0 || !out || !length) return 0;
 *length=0;int fd=openat(s->dirfd,"registration-job.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 if (fd<0) return 0;
 struct stat st;
 if (!ATLRegPrivateFile(fd) || fstat(fd,&st)!=0 || st.st_size<=0 || (size_t)st.st_size>ATL_REG_MAX_BYTES || (size_t)st.st_size>capacity) { close(fd);return 0; }
 size_t done=0,want=(size_t)st.st_size;
 while(done<want) { ssize_t n=read(fd,(char *)out+done,want-done);if(n<0 && errno==EINTR) continue;if(n<=0) { close(fd);return 0; }done+=(size_t)n; }
 close(fd);*length=done;return 1;
}
/* 1 committed, 0 failed before replacement, -1 replaced but durability uncertain.
   Caller holds the lock from ATLRegOpen and must reconcile -1, not resend. */
static inline int ATLRegWrite(ATLRegStore *s,const void *data,size_t length,const char *nonce) {
 if (!s || s->lockfd<0 || !data || !length || length>ATL_REG_MAX_BYTES || !nonce) return 0;
 size_t k=strlen(nonce);if (!k || k>48) return 0;
 for(size_t i=0;i<k;i++) if (!((nonce[i]>='0' && nonce[i]<='9')||(nonce[i]>='a' && nonce[i]<='z')||(nonce[i]>='A' && nonce[i]<='Z'))) return 0;
 struct stat st;
 if (fstatat(s->dirfd,"registration-job.json",&st,AT_SYMLINK_NOFOLLOW)==0) {
  if (!S_ISREG(st.st_mode) || st.st_uid!=geteuid() || st.st_nlink!=1 || (st.st_mode&0777)!=0600) return 0;
 } else if (errno!=ENOENT) return 0;
 char temp[80];int count=snprintf(temp,sizeof(temp),".registration-%s.tmp",nonce);
 if(count<0 || (size_t)count>=sizeof(temp)) return 0;
 int fd=openat(s->dirfd,temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
 if(fd<0) return 0;
 int ok=ATLRegPrivateFile(fd);size_t done=0;
 while(ok && done<length) { ssize_t n=write(fd,(const char *)data+done,length-done);if(n<0 && errno==EINTR) continue;if(n<=0){ok=0;break;}done+=(size_t)n; }
 if(ok && ATL_REG_FSYNC(fd)!=0) ok=0;
 if(close(fd)!=0) ok=0;
 if(!ok) { unlinkat(s->dirfd,temp,0);return 0; }
 if(renameat(s->dirfd,temp,s->dirfd,"registration-job.json")!=0) { unlinkat(s->dirfd,temp,0);return 0; }
 return ATL_REG_FSYNC(s->dirfd)==0 ? 1 : -1;
}
/* Remove only the verified regular private record while holding the lock.
   -1 means unlink occurred but directory durability is uncertain. */
static inline int ATLRegRemove(ATLRegStore *s) {
 if(!s || s->lockfd<0) return 0;
 int fd=openat(s->dirfd,"registration-job.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0) return 0;
 int valid=ATLRegPrivateFile(fd);close(fd);if(!valid) return 0;
 if(unlinkat(s->dirfd,"registration-job.json",0)!=0) return 0;
 return ATL_REG_FSYNC(s->dirfd)==0 ? 1 : -1;
}
#endif
