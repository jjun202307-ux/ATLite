#include "../shared/ATLStopFile.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int main(void) {
 char dir[] = "/tmp/atl-stop-XXXXXX"; assert(mkdtemp(dir));
 char path[256]; snprintf(path,sizeof(path),"%s/stop",dir);
 unsigned char bytes[256]; size_t n=0;
 assert(ATLReadStopFile(path,bytes,sizeof(bytes),&n)==0);
 FILE *f=fopen(path,"w"); assert(f); fputs("unique",f); fclose(f);
 assert(ATLReadStopFile(path,bytes,sizeof(bytes),&n)==1 && n==6 && !memcmp(bytes,"unique",6));
 f=fopen(path,"w"); assert(f); for(int i=0;i<257;i++) fputc('x',f); fclose(f);
 assert(ATLReadStopFile(path,bytes,sizeof(bytes),&n)==-1);
 unlink(path); assert(ATLReadStopFile(dir,bytes,sizeof(bytes),&n)==-1);
 assert(ATLReadStopFile(NULL,bytes,sizeof(bytes),&n)==-1);
 rmdir(dir); puts("stop file tests passed");
}
