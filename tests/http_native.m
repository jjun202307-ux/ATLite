#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import "../app/Source/ATLWebServer.h"
#import "../shared/ATLEmailJob.h"
static void Emit(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout); putchar('\n'); fflush(stdout);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        ATLWebServer *server = [[ATLWebServer alloc] initWithRootPath:root port:0];
        if (![server start]) return 3;
        int fd = [[server valueForKey:@"listenFD"] intValue];
        struct sockaddr_in addr; socklen_t len=sizeof(addr);
        if (getsockname(fd,(struct sockaddr *)&addr,&len) != 0) return 4;
        Emit(@{@"port":@(ntohs(addr.sin_port))});
        char *line=NULL; size_t capacity=0;
        while (getline(&line,&capacity,stdin)>0) {
            @autoreleasepool {
                NSData *input = [[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
                NSError *error=nil; id result=nil;
                if ([cmd[@"action"] isEqual:@"claim"]) result=ATLEmailClaimJob(root,&error);
                else if ([cmd[@"action"] isEqual:@"finish"]) {
                    BOOL ok=ATLEmailFinishJob(root,cmd[@"jobId"],cmd[@"email"],cmd[@"username"],cmd[@"ocrLines"],nil,&error);
                    if (ok) result=@{@"ok":@YES};
                }
                Emit(result ?: @{@"error":@(error.code),@"message":error.localizedDescription ?: @"invalid control command"});
            }
        }
        free(line); [server shutdownServer];
    }
    return 0;
}
