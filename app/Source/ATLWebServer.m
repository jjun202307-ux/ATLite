#import "ATLWebServer.h"
#import "ATLFileIO.h"
#import "../../shared/ATLEmailJob.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <pthread.h>
#import <string.h>
#import <poll.h>
#import <fcntl.h>
#import <sys/time.h>
#import <stdlib.h>
#import <time.h>
#import <errno.h>
#import <dispatch/dispatch.h>

static const double ATLRequestSeconds = 10;
static __thread double ATLDeadline;
static double ATLNow(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
// Nonblocking operations plus the remaining absolute deadline prevent trickle clients
// from resetting a per-operation timeout indefinitely.
static BOOL ATLWait(int fd, short events) {
    for (;;) {
        double remaining = ATLDeadline - ATLNow();
        if (remaining <= 0) return NO;
        struct pollfd p = { fd, events, 0 };
        int n = poll(&p, 1, (int)(remaining * 1000) + 1);
        if (n < 0 && errno == EINTR) continue;
        return n > 0 && (p.revents & (events | POLLHUP));
    }
}
static ssize_t ATLReceive(int fd, void *bytes, size_t count) {
    for (;;) {
        if (!ATLWait(fd, POLLIN)) return -1;
        ssize_t n = recv(fd, bytes, count, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        return n;
    }
}
static const unsigned long ATLMaxBody = 8 * 1024 * 1024; // 8MB

@interface ATLWebServer ()
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, assign) uint16_t port;
@property (atomic, assign) int listenFD;
@property (atomic, assign, getter=isRunning) BOOL running;
@property (nonatomic, strong) dispatch_semaphore_t connectionSlots;
@end

@implementation ATLWebServer

- (instancetype)initWithRootPath:(NSString *)rootPath port:(uint16_t)port {
    if ((self = [super init])) {
        _rootPath = [rootPath copy];
        _port = port;
        _listenFD = -1;
        _connectionSlots = dispatch_semaphore_create(6);
    }
    return self;
}


#pragma mark - Path helpers

// 允许: .at/.lua -> Scripts/, .png/.jpg/.jpeg -> Images/（白名单，防目录穿越）
- (NSString *)subdirForExtension:(NSString *)ext {
    if ([ext isEqualToString:@"at"] || [ext isEqualToString:@"lua"]) return @"Scripts";
    if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"Images";
    return nil;
}

- (NSString *)sanitizeName:(NSString *)raw valid:(BOOL *)ok {
    *ok = NO;
    if (!raw.length || raw.length > 128) return nil;
    if ([raw rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return nil;
    if ([raw containsString:@"/"] || [raw containsString:@"\\"] || [raw containsString:@".."]) return nil;
    NSString *ext = raw.pathExtension.lowercaseString;
    if (![self subdirForExtension:ext]) return nil;
    *ok = YES;
    return raw;
}

- (NSString *)pathForName:(NSString *)name {
    NSString *sub = [self subdirForExtension:name.pathExtension.lowercaseString];
    return [[self.rootPath stringByAppendingPathComponent:sub] stringByAppendingPathComponent:name];
}

#pragma mark - HTTP primitives

static void ATLSendAll(int fd, const void *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        if (!ATLWait(fd, POLLOUT)) return;
        ssize_t n = send(fd, (const char *)buf + off, len - off, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return;
        off += (size_t)n;
    }
}

static void ATLSendResponse(int fd, int code, NSString *contentType, NSData *body) {
    NSString *status = code == 200 ? @"OK" : (code == 400 ? @"Bad Request" :
                       code == 404 ? @"Not Found" : (code == 202 ? @"Accepted" :
                       code == 409 ? @"Conflict" : @"Internal Server Error"));
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@; charset=utf-8\r\nContent-Length: %lu\r\n"
        @"Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        code, status, contentType, (unsigned long)body.length];
    ATLSendAll(fd, head.UTF8String, strlen(head.UTF8String));
    if (body.length) ATLSendAll(fd, body.bytes, body.length);
}

static void ATLSendText(int fd, int code, NSString *text) {
    ATLSendResponse(fd, code, @"text/plain", [text dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - Pages

- (NSData *)indexPage {
    NSString *html = @"<!DOCTYPE html><html><head><meta charset='utf-8'>"
    @"<meta name='viewport' content='width=device-width,initial-scale=1'>"
    @"<title>ATLite</title><style>"
    @"body{font-family:-apple-system,sans-serif;max-width:640px;margin:24px auto;padding:0 16px}"
    @"li{margin:6px 0}button{margin-left:8px}"
    @"#log{color:#666;font-size:12px;margin-top:8px;white-space:pre-wrap}"
    @".dirbtn{margin-right:8px;padding:2px 10px}"
    @"</style></head><body>"
    @"<h2>ATLite 文件管理</h2>"
    @"<span class='dirbtn'><b id='lbl'>脚本</b></span>"
    @"<button class='dirbtn' onclick=\"setDir('scripts')\">脚本(.at)</button>"
    @"<button class='dirbtn' onclick=\"setDir('images')\">搜图模板(png)</button><br><br>"
    @"<input type='file' id='f' multiple><span> 选择文件后点上传</span>"
    @"<button onclick='upload()'>上传</button>"
    @"<ul id='list'></ul>"
    @"<div id='log'></div>"
    @"<script>"
    @"let cur='scripts';"
    @"function setDir(d){cur=d;document.getElementById('lbl').textContent=d==='images'?'搜图模板':'脚本';load()}"
    @"async function load(){const r=await fetch('/api/list?dir='+cur);const a=await r.json();"
    @"const ul=document.getElementById('list');ul.innerHTML='';"
    @"for(const n of a){const li=document.createElement('li');"
    @"const a=document.createElement('a');a.textContent=n;"
    @"a.href='/api/get?dir='+cur+'&name='+encodeURIComponent(n);li.appendChild(a);"
    @"const d=document.createElement('button');d.textContent='删除';"
    @"d.onclick=async()=>{const r=await fetch('/api/del?dir='+cur+'&name='+encodeURIComponent(n),{method:'DELETE'});if(!r.ok)document.getElementById('log').textContent='删除失败 '+r.status;load()};"
    @"li.appendChild(d);ul.appendChild(li)}}"
    @"async function upload(){const fs=document.getElementById('f').files;"
    @"const logEl=document.getElementById('log');logEl.textContent='';"
    @"for(const f of fs){const body=await f.arrayBuffer();"
    @"const r=await fetch('/api/put?name='+encodeURIComponent(f.name),{method:'PUT',body});"
    @"logEl.textContent+=f.name+' -> '+(r.ok?'OK':'FAIL '+r.status)+'\\n';}"
    @"load()}"
    @"load()</script></body></html>";
    return [html dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)listJSONForDir:(NSString *)dir {
    NSString *sub = [dir isEqualToString:@"Images"] ? @"Images" : @"Scripts";
    NSString *path = [self.rootPath stringByAppendingPathComponent:sub];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([sub isEqualToString:@"Scripts"]) {
            if ([ext isEqualToString:@"at"] || [ext isEqualToString:@"lua"]) [names addObject:f];
        } else {
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"])
                [names addObject:f];
        }
    }
    [names sortUsingSelector:@selector(compare:)];
    NSData *d = [NSJSONSerialization dataWithJSONObject:names options:0 error:nil];
    return d ?: [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Request handling

- (NSRange)findHeaderEnd:(NSData *)d {
    const char *b = d.bytes;
    NSUInteger len = d.length;
    for (NSUInteger i = 0; i + 3 < len; i++) {
        if (b[i] == '\r' && b[i+1] == '\n' && b[i+2] == '\r' && b[i+3] == '\n')
            return NSMakeRange(i, 2);
    }
    return NSMakeRange(NSNotFound, 0);
}

- (void)handleConnection:(int)fd {
    @autoreleasepool {
        NSMutableData *buf = [NSMutableData data];
        NSString *header = nil;
        size_t headerLen = 0;
        while (buf.length < 16384) {
            char tmp[4096];
            ssize_t n = ATLReceive(fd, tmp, sizeof(tmp));
            if (n <= 0) { close(fd); return; }
            [buf appendBytes:tmp length:(NSUInteger)n];
            NSRange r = [self findHeaderEnd:buf];
            if (r.location != NSNotFound) {
                header = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, r.location)]
                                               encoding:NSUTF8StringEncoding];
                headerLen = r.location + 4;
                if (headerLen > 16384) header = nil;
                break;
            }
        }
        if (!header) { ATLSendText(fd, 400, @"header too large"); close(fd); return; }

        NSArray *lines = [header componentsSeparatedByString:@"\r\n"];
        NSString *reqLine = lines.firstObject ?: @"";
        NSArray *parts = [reqLine componentsSeparatedByString:@" "];
        if (parts.count != 3 || ![parts[2] hasPrefix:@"HTTP/1."]) { ATLSendText(fd, 400, @"bad request"); close(fd); return; }
        NSString *method = parts[0];
        NSString *target = parts[1];
        if ([reqLine rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
            ATLSendText(fd, 400, @"bad request line"); close(fd); return;
        }

        unsigned long contentLength = 0;
        BOOL seenLength = NO;
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *l = lines[i];
            NSRange colon = [l rangeOfString:@":"];
            if (colon.location == NSNotFound || colon.location == 0) {
                ATLSendText(fd, 400, @"bad header"); close(fd); return;
            }
            NSString *key = [[l substringToIndex:colon.location] lowercaseString];
            if ([key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet]].location != NSNotFound) {
                ATLSendText(fd, 400, @"bad header name"); close(fd); return;
            }
            if ([key isEqualToString:@"transfer-encoding"]) {
                ATLSendText(fd, 400, @"unsupported transfer-encoding"); close(fd); return;
            }
            if ([key isEqualToString:@"content-length"]) {
                if (seenLength) { ATLSendText(fd, 400, @"duplicate content-length"); close(fd); return; }
                seenLength = YES;
                NSString *value = [[l substringFromIndex:colon.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t"]];
                if (!value.length) { ATLSendText(fd, 400, @"bad content-length"); close(fd); return; }
                for (NSUInteger j = 0; j < value.length; j++) {
                    unichar c = [value characterAtIndex:j];
                    if (c < '0' || c > '9' || contentLength > (ATLMaxBody - (c - '0')) / 10) {
                        ATLSendText(fd, 400, @"bad content-length"); close(fd); return;
                    }
                    contentLength = contentLength * 10 + c - '0';
                }
            }
        }
        if (contentLength > ATLMaxBody) { ATLSendText(fd, 400, @"body too large"); close(fd); return; }
        while (buf.length < headerLen + contentLength) {
            char tmp[16384];
            ssize_t n = ATLReceive(fd, tmp, sizeof(tmp));
            if (n <= 0) { ATLSendText(fd, 400, @"short body"); close(fd); return; }
            [buf appendBytes:tmp length:(NSUInteger)n];
        }
        NSData *body = buf.length > headerLen
            ? [buf subdataWithRange:NSMakeRange(headerLen, MIN((unsigned long)buf.length - headerLen, contentLength))]
            : [NSData data];

        if (ATLNow() >= ATLDeadline) { close(fd); return; }
        [self route:method target:target body:body fd:fd];
        close(fd);
    }
}

- (NSDictionary *)parseQuery:(NSString *)target {
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    NSRange range = [target rangeOfString:@"?"];
    if (range.location == NSNotFound) return q;
    NSString *qs = [target substringFromIndex:range.location + 1];
    for (NSString *kv in [qs componentsSeparatedByString:@"&"]) {
        NSRange eq = [kv rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[kv substringToIndex:eq.location] stringByRemovingPercentEncoding] ?: @"";
        NSString *v = [[kv substringFromIndex:eq.location + 1] stringByRemovingPercentEncoding] ?: @"";
        q[k] = v;
    }
    return q;
}

- (void)route:(NSString *)method target:(NSString *)target body:(NSData *)body fd:(int)fd {
    NSString *path = [target componentsSeparatedByString:@"?"].firstObject;

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/"]) {
        ATLSendResponse(fd, 200, @"text/html", [self indexPage]);
        return;
    }

    NSDictionary *q = [self parseQuery:target];
    if ([path isEqualToString:@"/api/job"] || [path isEqualToString:@"/api/result"]) {
        NSError *error = nil;
        NSDictionary *job = nil;
        int code = 200;
        NSString *jobId = q[@"jobId"];
        if ([path isEqualToString:@"/api/job"] && [method isEqualToString:@"PUT"]) {
            id input = body.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
            if ([input isKindOfClass:NSDictionary.class] && [input[@"email"] isKindOfClass:NSString.class])
                job = ATLEmailCreateJob(self.rootPath,input[@"email"],&error);
            else error = [NSError errorWithDomain:@"ATLEmailJob" code:400 userInfo:@{NSLocalizedDescriptionKey:@"expected JSON object with email"}];
            code = 202;
        } else if ([method isEqualToString:@"GET"]) {
            if ([path isEqualToString:@"/api/result"] && (!jobId.length || jobId.length > 80 ||
                [jobId rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)) {
                error = [NSError errorWithDomain:@"ATLEmailJob" code:400 userInfo:@{NSLocalizedDescriptionKey:@"invalid jobId"}];
            } else {
                job = ATLEmailReadJob(self.rootPath,&error);
                if (job && [path isEqualToString:@"/api/result"] && ![job[@"jobId"] isEqual:jobId]) {
                    job = nil;
                    error = [NSError errorWithDomain:@"ATLEmailJob" code:404 userInfo:@{NSLocalizedDescriptionKey:@"result jobId not current"}];
                }
            }
        } else if ([path isEqualToString:@"/api/job"] && [method isEqualToString:@"DELETE"]) {
            if (ATLEmailCancelJob(self.rootPath,jobId,&error))
                job = @{@"jobId":jobId,@"status":@"cancelled",@"note":@"stored job cancelled; script stop is separate"};
        } else {
            error = [NSError errorWithDomain:@"ATLEmailJob" code:400 userInfo:@{NSLocalizedDescriptionKey:@"unsupported job method"}];
        }
        if (!job) {
            code = (error.code == 400 || error.code == 404 || error.code == 409) ? (int)error.code : 500;
            job = @{@"error":error.localizedDescription ?: @"job operation failed"};
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:job options:0 error:nil];
        ATLSendResponse(fd,code,@"application/json",json);
        return;
    }
    NSString *dir = [q[@"dir"] isEqualToString:@"images"] ? @"Images" : @"Scripts";

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/list"]) {
        ATLSendResponse(fd, 200, @"application/json", [self listJSONForDir:dir]);
        return;
    }

    NSString *name = q[@"name"] ?: @""; // parseQuery decodes exactly once
    BOOL valid = NO;
    NSString *safe = [self sanitizeName:name valid:&valid];

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/get"]) {
        if (!valid) { ATLSendText(fd, 400, @"invalid name"); return; }
        NSData *d = [NSData dataWithContentsOfFile:[self pathForName:safe]];
        if (!d) { ATLSendText(fd, 404, @"not found"); return; }
        ATLSendResponse(fd, 200, @"application/octet-stream", d);
        return;
    }
    if ([method isEqualToString:@"PUT"] && [path isEqualToString:@"/api/put"]) {
        if (!valid) { ATLSendText(fd, 400, @"invalid name (allowed: .at .lua .png .jpg .jpeg)"); return; }
        if (![body writeToFile:[self pathForName:safe] atomically:YES]) {
            ATLSendText(fd, 500, @"write failed");
            return;
        }
        ATLSendText(fd, 200, @"OK");
        return;
    }
    if ([method isEqualToString:@"DELETE"] && [path isEqualToString:@"/api/del"]) {
        if (!valid) { ATLSendText(fd, 400, @"invalid name"); return; }
        int code = ATLDeleteFile([self pathForName:safe]);
        ATLSendText(fd, code, code == 200 ? @"OK" : (code == 404 ? @"not found" : @"delete failed"));
        return;
    }
    ATLSendText(fd, 404, @"not found");
}

#pragma mark - Server loop

typedef struct {
    void *server; // retained bridge, consumed exactly once by the worker
    int fd;
    double deadline;
} ATLConnCtx;

static void *ATLConnThread(void *rawCtx) {
    ATLConnCtx *ctx = rawCtx;
    @autoreleasepool {
        ATLWebServer *server = (__bridge_transfer ATLWebServer *)ctx->server;
        int fd = ctx->fd;
        ATLDeadline = ctx->deadline;
        free(ctx);
        [server handleConnection:fd];
        dispatch_semaphore_signal(server.connectionSlots);
    }
    return NULL;
}

static void *ATLServerThread(void *rawCtx) {
    @autoreleasepool {
        ATLConnCtx *serverCtx = rawCtx;
        ATLWebServer *self = (__bridge_transfer ATLWebServer *)serverCtx->server;
        int listener = serverCtx->fd;
        free(serverCtx);
        while (self.running && self.listenFD == listener) {
            // Shutdown polls at most 200ms; no worker is created until a slot is reserved.
            struct pollfd p = {listener, POLLIN, 0};
            int ready = poll(&p, 1, 200);
            if (ready < 0) { if (errno == EINTR) continue; break; }
            if (!ready) continue;
            if (!(p.revents & POLLIN)) {
                if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
                continue;
            }
            int conn = accept(listener, NULL, NULL);
            if (conn < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
                if (!self.running || self.listenFD != listener) break;
                usleep(10000); // avoid spinning on transient accept resource errors
                continue;
            }
            if (dispatch_semaphore_wait(self.connectionSlots, DISPATCH_TIME_NOW) != 0) {
                close(conn); continue;
            }
            int yes = 1;
            struct timeval timeout = {10, 0};
            if (setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0 ||
                setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
                setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) {
                close(conn); dispatch_semaphore_signal(self.connectionSlots); continue;
            }
            ATLConnCtx *ctx = malloc(sizeof(*ctx));
            if (!ctx) { close(conn); dispatch_semaphore_signal(self.connectionSlots); continue; }
            ctx->server = (__bridge_retained void *)self;
            ctx->fd = conn;
            ctx->deadline = ATLNow() + ATLRequestSeconds;
            pthread_t t;
            if (pthread_create(&t, NULL, ATLConnThread, ctx) != 0) {
                id owner = (__bridge_transfer id)ctx->server;
                (void)owner;
                free(ctx); close(conn); dispatch_semaphore_signal(self.connectionSlots);
                continue;
            }
            pthread_detach(t);
        }
        close(listener); // listener thread owns close, avoiding descriptor reuse races
    }
    return NULL;
}

- (BOOL)start {
    if (!self.rootPath.length) return NO;
    if (self.running) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return NO; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(self.port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return NO; }
    if (listen(fd, 16) < 0) { close(fd); return NO; }
    self.listenFD = fd;
    self.running = YES;
    pthread_t t;
    ATLConnCtx *serverCtx = malloc(sizeof(*serverCtx));
    if (!serverCtx) { self.running = NO; self.listenFD = -1; close(fd); return NO; }
    serverCtx->server = (__bridge_retained void *)self;
    serverCtx->fd = fd;
    if (pthread_create(&t, NULL, ATLServerThread, serverCtx) != 0) {
        id releasedOwner = (__bridge_transfer id)serverCtx->server;
        free(serverCtx);
        (void)releasedOwner;
        self.running = NO; self.listenFD = -1; close(fd); return NO;
    }
    pthread_detach(t);
    return YES;
}

- (void)shutdownServer {
    self.running = NO;
    if (self.listenFD >= 0) {
        int fd = self.listenFD; self.listenFD = -1;
        shutdown(fd, SHUT_RDWR); // wake accept/poll; owning listener closes it
    }
}

@end
