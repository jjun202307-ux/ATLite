#import "ATLWebServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <pthread.h>

static const size_t ATMaxBody = 8 * 1024 * 1024; // 8MB

@interface ATLWebServer ()
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) BOOL running;
@end

@implementation ATLWebServer

- (instancetype)initWithRootPath:(NSString *)rootPath port:(uint16_t)port {
    if ((self = [super init])) {
        _rootPath = [rootPath copy];
        _port = port;
        _listenFD = -1;
    }
    return self;
}

- (BOOL)isRunning { return _running; }

#pragma mark - Helpers

// 允许: .at/.lua -> Scripts/, .png/.jpg/.jpeg -> Images/
- (NSString *)subdirForExtension:(NSString *)ext {
    if ([ext isEqualToString:@"at"] || [ext isEqualToString:@"lua"]) return @"Scripts";
    if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"Images";
    return nil;
}

- (NSString *)sanitizeName:(NSString *)raw valid:(BOOL *)ok {
    *ok = NO;
    if (!raw.length || raw.length > 128) return nil;
    if ([raw containsString:@"/"] || [raw containsString:@"\\"] || [raw containsString:@".."]) return nil;
    NSString *ext = raw.pathExtension.lowercaseString;
    if (![self subdirForExtension:ext]) return nil;
    *ok = YES;
    return raw;
}

- (NSString *)percentDecode:(NSString *)s {
    return [s stringByRemovingPercentEncoding] ?: s;
}

- (NSString *)pathForName:(NSString *)name {
    NSString *sub = [self subdirForExtension:name.pathExtension.lowercaseString];
    return [[self.rootPath stringByAppendingPathComponent:sub] stringByAppendingPathComponent:name];
}

#pragma mark - HTTP primitives

static void ATSendAll(int fd, const void *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, (const char *)buf + off, len - off, 0);
        if (n <= 0) return;
        off += (size_t)n;
    }
}

static void ATSendResponse(int fd, int code, NSString *contentType, NSData *body) {
    NSString *status = code == 200 ? @"OK" : (code == 400 ? @"Bad Request" :
                       code == 404 ? @"Not Found" : (code == 500 ? @"Internal Server Error" : @"Error"));
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@; charset=utf-8\r\nContent-Length: %lu\r\n"
        @"Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        code, status, contentType, (unsigned long)body.length];
    ATSendAll(fd, head.UTF8String, strlen(head.UTF8String));
    if (body.length) ATSendAll(fd, body.bytes, body.length);
}

static void ATSendText(int fd, int code, NSString *text) {
    ATSendResponse(fd, code, @"text/plain", [text dataUsingEncoding:NSUTF8StringEncoding]);
}

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
    @"li.innerHTML=`<a href='/api/get?dir=${cur}&name=${encodeURIComponent(n)}'>${n}</a>`;"
    @"const d=document.createElement('button');d.textContent='删除';"
    @"d.onclick=async()=>{await fetch('/api/del?dir='+cur+'&name='+encodeURIComponent(n),{method:'DELETE'});load()};"
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
    NSString *sub = [dir isEqualToString:@"images"] ? @"Images" : @"Scripts";
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
            ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
            if (n <= 0) { close(fd); return; }
            [buf appendBytes:tmp length:(NSUInteger)n];
            NSRange r = [self findHeaderEnd:buf];
            if (r.location != NSNotFound) {
                header = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, r.location)]
                                               encoding:NSUTF8StringEncoding];
                headerLen = r.location + 4;
                break;
            }
        }
        if (!header) { ATSendText(fd, 400, @"header too large"); close(fd); return; }

        NSArray *lines = [header componentsSeparatedByString:@"\r\n"];
        NSString *reqLine = lines.firstObject ?: @"";
        NSArray *parts = [reqLine componentsSeparatedByString:@" "];
        if (parts.count < 2) { ATSendText(fd, 400, @"bad request"); close(fd); return; }
        NSString *method = parts[0];
        NSString *target = parts[1];

        unsigned long contentLength = 0;
        for (NSString *l in lines) {
            if ([l.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = [[l substringFromIndex:15] stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]].longLongValue;
            }
        }
        if (contentLength > ATMaxBody) { ATSendText(fd, 400, @"body too large"); close(fd); return; }
        while (buf.length < headerLen + contentLength) {
            char tmp[16384];
            ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n];
        }
        NSData *body = buf.length > headerLen
            ? [buf subdataWithRange:NSMakeRange(headerLen, MIN((unsigned long)buf.length - headerLen, contentLength))]
            : [NSData data];

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
        ATSendResponse(fd, 200, @"text/html", [self indexPage]);
        return;
    }

    NSDictionary *q = [self parseQuery:target];
    NSString *dir = [q[@"dir"] isEqualToString:@"images"] ? @"Images" : @"Scripts";

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/list"]) {
        ATSendResponse(fd, 200, @"application/json", [self listJSONForDir:dir]);
        return;
    }

    NSString *name = [self percentDecode:q[@"name"] ?: @""];
    BOOL valid = NO;
    NSString *safe = [self sanitizeName:name valid:&valid];

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/get"]) {
        if (!valid) { ATSendText(fd, 400, @"invalid name"); return; }
        NSData *d = [NSData dataWithContentsOfFile:[self pathForName:safe]];
        if (!d) { ATSendText(fd, 404, @"not found"); return; }
        ATSendResponse(fd, 200, @"application/octet-stream", d);
        return;
    }
    if ([method isEqualToString:@"PUT"] && [path isEqualToString:@"/api/put"]) {
        if (!valid) { ATSendText(fd, 400, @"invalid name (allowed: .at .lua .png .jpg .jpeg)"); return; }
        if (![body writeToFile:[self pathForName:safe] atomically:YES]) {
            ATSendText(fd, 500, @"write failed");
            return;
        }
        ATSendText(fd, 200, @"OK");
        return;
    }
    if ([method isEqualToString:@"DELETE"] && [path isEqualToString:@"/api/del"]) {
        if (!valid) { ATSendText(fd, 400, @"invalid name"); return; }
        [[NSFileManager defaultManager] removeItemAtPath:[self pathForName:safe] error:nil];
        ATSendText(fd, 200, @"OK");
        return;
    }
    ATSendText(fd, 404, @"not found");
}

#pragma mark - Server loop

typedef struct {
    __strong ATLWebServer *server;
    int fd;
} ATLConnCtx;

static void *ATConnThread(void *rawCtx) {
    ATLConnCtx *ctx = (ATLConnCtx *)rawCtx;
    ATLWebServer *server = ctx->server;
    int fd = ctx->fd;
    free(ctx);
    @autoreleasepool {
        [server handleConnection:fd];
    }
    return NULL;
}

static void *ATServerThread(void *ctx) {
    ATLWebServer *self = (__bridge ATLWebServer *)ctx;
    while (self.running) {
        int conn = accept(self.listenFD, NULL, NULL);
        if (conn < 0) { usleep(100 * 1000); continue; }
        ATLConnCtx *ctx = (ATLConnCtx *)malloc(sizeof(ATLConnCtx));
        ctx->server = self;
        ctx->fd = conn;
        pthread_t t;
        pthread_create(&t, NULL, ATConnThread, ctx);
        pthread_detach(t);
    }
    return NULL;
}

- (BOOL)start {
    if (self.running) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
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
    pthread_create(&t, NULL, ATServerThread, (__bridge void *)self);
    pthread_detach(t);
    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.listenFD >= 0) { close(self.listenFD); self.listenFD = -1; }
}

@end
