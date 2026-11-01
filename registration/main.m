#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import "../app/Source/ATLPaths.h"
#import "../shared/ATLRegistrationCLI.h"
#import "../shared/ATLRegistrationStorage.h"

static int emit(NSData *data) {
 const unsigned char *p=data.bytes;size_t left=data.length;
 while(left){ssize_t n=write(STDOUT_FILENO,p,left);if(n<0 && errno==EINTR)continue;if(n<=0)return 1;p+=n;left-=(size_t)n;}
 return write(STDOUT_FILENO,"\n",1)==1?0:1;
}
int main(int argc,char **argv) { @autoreleasepool {
 if(argc!=2)return 2;
 NSString *operation=[NSString stringWithUTF8String:argv[1]];
 if(![@[@"create",@"status",@"clear",@"code",@"resume"] containsObject:operation])return 2;
 NSString *base=ATLBaseDir();if(!base.length)return 2;
 NSString *directory=[base stringByAppendingPathComponent:@"Registration"];
 if(mkdir(directory.fileSystemRepresentation,0700)!=0 && errno!=EEXIST)return 2;
 NSMutableData *input=[NSMutableData data];unsigned char buffer[1024];
 for(;;){ssize_t n=read(STDIN_FILENO,buffer,sizeof(buffer));if(n<0 && errno==EINTR)continue;if(n<0)return 2;if(!n)break;
  if(input.length+(NSUInteger)n>ATL_REG_MAX_BYTES){memset(buffer,0,sizeof(buffer));if(input.length)memset(input.mutableBytes,0,input.length);return 2;}[input appendBytes:buffer length:(NSUInteger)n];
 }
 memset(buffer,0,sizeof(buffer));NSData *output=nil;
 int result=ATLRegistrationCLI(directory,operation,input,&output);
 if(input.length)memset(input.mutableBytes,0,input.length);
 return output && emit(output)==0 ? result : 2;
} }
