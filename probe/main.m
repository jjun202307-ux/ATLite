// ATLiteProbe v0.3.10 —— 阶段 0 诊断探针（纯新增，不改现有任何行为）
//
// 只回答 docs/PLAN_P0_DAEMON.md §7 的 P3 / P4 / P5：
//   P3 root 身份：spawn 出来的进程 geteuid() 是不是 0（setuid 是否生效）
//   P4 HID 注入：euid=0 下能否创建 HID client 并 dispatch 一次触摸
//   P5 抓屏：能否 IOMobileFramebufferOpen 直读主屏 layer surface；失败则回退 RenderDisplay
// P1（App 侧 spawn）与 P2（SpringBoard 侧 spawn）由调用方回答，本文件不参与。
//
// 两条纪律：
//   1) 路径零推导：由调用方通过 --base 传入，避开命令行工具 mainBundle 的不确定行为。
//   2) 绝不依赖 SDK 私有头：IOSurface/IOMobileFramebuffer 类型与 HID 常量全部自定义名，
//      符号一律 dlsym 惰性取。已有教训（E27：undeclared identifier 会把构建直接打挂）。

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

// 自定义类型名：与 SDK 任何声明都不冲突
typedef struct __ATIOSurface *ATSurfaceRef;
typedef struct __ATFBConn *ATFBConn;
typedef struct __ATIOHIDEvent *ATEventRef;
typedef struct __ATIOHIDClient *ATClientRef;

static FILE *gOut = NULL;

static void P(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    printf("%s\n", s.UTF8String);
    if (gOut) { fprintf(gOut, "%s\n", s.UTF8String); fflush(gOut); }
}

#pragma mark - P3: 我是谁

// setuid 在 roothide 下是否生效的唯一判据
static void probe_identity(void) {
    P(@"PROBE_P3 uid=%d euid=%d gid=%d egid=%d pid=%d ppid=%d",
      getuid(), geteuid(), getgid(), getegid(), getpid(), getppid());
    P(@"PROBE_P3 verdict=%@", geteuid() == 0 ? @"ROOT" : @"NOT-ROOT");
}

#pragma mark - P4: HID 触摸注入

static ATClientRef (*_ATClientCreate)(CFAllocatorRef);
static void (*_ATClientDispatch)(ATClientRef, ATEventRef);
static ATEventRef (*_ATCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                        uint32_t, uint32_t, Float32, Float32, Float32, Float32,
                                        Float32, Boolean, Boolean, uint32_t);
static ATEventRef (*_ATCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                     Float32, Float32, Float32, Float32, Float32,
                                     Boolean, Boolean, uint32_t);
static void (*_ATAppendEvent)(ATEventRef, ATEventRef, uint32_t);
static void (*_ATSetInt)(ATEventRef, uint32_t, int);
static void (*_ATSetFloat)(ATEventRef, uint32_t, double);

// 自定义名：不假设 IOKit 私有头可见（ForkEvent 13 参 / DigitizerEvent 15 参，
// 逐参数对齐 Tweak.xm L289-L306 的实证装配）
enum { AT_TRANSDUCER_HAND = 3 };
enum { AT_EV_RANGE = 0x00000001, AT_EV_TOUCH = 0x00000002, AT_EV_POSITION = 0x00000004 };
#define AT_FIELD_IS_DISPLAY_INTEGRATED 0x000B0019
#define AT_FIELD_MAJOR_RADIUS          0x000B0014
#define AT_FIELD_MINOR_RADIUS          0x000B0015

static void probe_hid(void) {
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!io) { P(@"PROBE_P4 FAIL dlopen IOKit: %s", dlerror()); return; }
    _ATClientCreate    = dlsym(io, "IOHIDEventSystemClientCreate");
    _ATClientDispatch  = dlsym(io, "IOHIDEventSystemClientDispatchEvent");
    _ATCreateDigitizer = dlsym(io, "IOHIDEventCreateDigitizerEvent");
    _ATCreateFinger    = dlsym(io, "IOHIDEventCreateDigitizerFingerEvent");
    _ATAppendEvent     = dlsym(io, "IOHIDEventAppendEvent");
    _ATSetInt          = dlsym(io, "IOHIDEventSetIntegerValue");
    _ATSetFloat        = dlsym(io, "IOHIDEventSetFloatValue");
    if (!_ATClientCreate || !_ATClientDispatch || !_ATCreateDigitizer || !_ATCreateFinger) {
        P(@"PROBE_P4 FAIL symbols missing (euid=%d)", geteuid()); return;
    }
    ATClientRef client = _ATClientCreate(kCFAllocatorDefault);
    if (!client) { P(@"PROBE_P4 FAIL client create returned NULL (euid=%d)", geteuid()); return; }
    P(@"PROBE_P4 client=ok euid=%d", geteuid());

    uint64_t ts = mach_absolute_time();
    ATEventRef hand = _ATCreateDigitizer(kCFAllocatorDefault, ts, AT_TRANSDUCER_HAND,
        0, 0, AT_EV_TOUCH, 0, 0, 0, 0, 0, 0, 0, true, 0);
    ATEventRef fg = _ATCreateFinger(kCFAllocatorDefault, ts, 1, 2,
        (uint32_t)(AT_EV_RANGE | AT_EV_TOUCH), 160, 300, 0, 0, 0, 1, 1, 0);
    if (!hand || !fg) { P(@"PROBE_P4 FAIL event create NULL"); return; }
    _ATAppendEvent(hand, fg, 0);
    if (_ATSetInt)   { _ATSetInt(hand, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
                       _ATSetInt(fg,   AT_FIELD_IS_DISPLAY_INTEGRATED, 1); }
    if (_ATSetFloat) { _ATSetFloat(fg, AT_FIELD_MAJOR_RADIUS, 4.0);
                       _ATSetFloat(fg, AT_FIELD_MINOR_RADIUS, 3.0); }
    _ATClientDispatch(client, hand);
    P(@"PROBE_P4 dispatched touchDown(160,300)");
    usleep(60000);
    uint64_t ts2 = mach_absolute_time();
    ATEventRef hand2 = _ATCreateDigitizer(kCFAllocatorDefault, ts2, AT_TRANSDUCER_HAND,
        0, 0, AT_EV_TOUCH, 0, 0, 0, 0, 0, 0, 0, true, 0);
    ATEventRef fg2 = _ATCreateFinger(kCFAllocatorDefault, ts2, 1, 2,
        (uint32_t)AT_EV_TOUCH, 160, 300, 0, 0, 0, 0, 0, 0);
    if (hand2 && fg2) {
        _ATAppendEvent(hand2, fg2, 0);
        if (_ATSetInt) _ATSetInt(hand2, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
        _ATClientDispatch(client, hand2);
        P(@"PROBE_P4 dispatched touchUp");
    }
    P(@"PROBE_P4 verdict=DISPATCHED (以屏幕是否出现点击反馈为准)");
}

#pragma mark - P5: 抓屏（Framebuffer 主 + RenderDisplay 回退）

static int (*_ATFBOpen)(mach_port_t, task_t, unsigned int, ATFBConn *);
static int (*_ATFBGetLayerDefaultSurface)(ATFBConn, int, ATSurfaceRef *);
static ATSurfaceRef (*_ATSurfaceCreate)(CFDictionaryRef);
static size_t (*_ATSurfaceGetWidth)(ATSurfaceRef);
static size_t (*_ATSurfaceGetHeight)(ATSurfaceRef);
static void *(*_ATSurfaceGetBase)(ATSurfaceRef);
static int32_t (*_ATSurfaceLock)(ATSurfaceRef, uint32_t, uint32_t *);
static void (*_ATSurfaceUnlock)(ATSurfaceRef, uint32_t, uint32_t);
static int (*_ATRenderDisplay)(uint32_t, CFStringRef, ATSurfaceRef, uint32_t, uint32_t);

// R33-B：常见 iPhone 物理像素尺寸表。SpringBoard 侧 spawn 时不方便取 UIScreen
// （要跳主线程，得再套一层 E30 超时），所以这里不依赖调用方传尺寸：
// 单一硬编码分辨率会让非该分辨率的机型**必然**失败，从而把 "BOTH-FAILED"
// 误报给阶段 2 的决策依据。逐个尝试，命中即止。
static const int kATFallbackSizes[][2] = {
    {1170, 2532}, {1179, 2556}, {1284, 2778}, {1290, 2796}, {1080, 2400},
    {828, 1792}, {750, 1334}, {640, 1136}, {1125, 2436}, {1242, 2688},
    {1668, 2388}
};
#define AT_TRY_SIZES ((size_t)(sizeof(kATFallbackSizes) / sizeof(kATFallbackSizes[0])))

// 单次 RenderDisplay 尝试；kr==0 即成功（调用方自建 IOSurface，AutoTouch 实证路径）
static BOOL ATRenderOne(int w, int h) {
    if (w <= 0 || h <= 0) return NO;
    uint32_t argb = 0x41524742u; // 'ARGB'
    NSDictionary *props = @{
        @"IOSurfaceIsGlobal":        @YES,
        @"IOSurfaceBytesPerElement": @4,
        @"IOSurfaceBytesPerRow":     @(w * 4),
        @"IOSurfaceWidth":           @(w),
        @"IOSurfaceHeight":          @(h),
        @"IOSurfacePixelFormat":     @(argb),
        @"IOSurfaceAllocSize":       @(w * h * 4),
    };
    ATSurfaceRef sf = _ATSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!sf) { P(@"PROBE_P5 RenderDisplay %dx%d surface=NULL", w, h); return NO; }
    uint32_t seed = 0;
    if (_ATSurfaceLock) _ATSurfaceLock(sf, 0, &seed);
    int krr = _ATRenderDisplay(0, CFSTR("LCD"), sf, 0, 0);
    uint8_t *p = (krr == 0 && _ATSurfaceGetBase) ? (uint8_t *)_ATSurfaceGetBase(sf) : NULL;
    P(@"PROBE_P5 RenderDisplay %dx%d kr=%d first_pixel=%02x%02x%02x%02x",
      w, h, krr, p ? p[0] : 0, p ? p[1] : 0, p ? p[2] : 0, p ? p[3] : 0);
    if (_ATSurfaceUnlock) _ATSurfaceUnlock(sf, 0, seed);
    return krr == 0;
}

static void probe_framebuffer(int reqW, int reqH) {
    void *fb  = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
    void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (ios) {
        _ATSurfaceGetWidth  = dlsym(ios, "IOSurfaceGetWidth");
        _ATSurfaceGetHeight = dlsym(ios, "IOSurfaceGetHeight");
        _ATSurfaceGetBase   = dlsym(ios, "IOSurfaceGetBaseAddress");
        _ATSurfaceLock      = dlsym(ios, "IOSurfaceLock");
        _ATSurfaceUnlock    = dlsym(ios, "IOSurfaceUnlock");
        _ATSurfaceCreate    = dlsym(ios, "IOSurfaceCreate");
    }
    if (fb) {
        _ATFBOpen = dlsym(fb, "IOMobileFramebufferOpen");
        _ATFBGetLayerDefaultSurface = dlsym(fb, "IOMobileFramebufferGetLayerDefaultSurface");
    }

    ATFBConn conn = NULL;
    int kr = -1;
    if (_ATFBOpen) kr = _ATFBOpen(0, mach_task_self(), 0, &conn);
    P(@"PROBE_P5 framebuffer dlopen=%@ open kr=%d conn=%@",
      fb ? @"ok" : @"FAIL", kr, conn ? @"ok" : @"NULL");

    if (kr == 0 && conn && _ATFBGetLayerDefaultSurface) {
        ATSurfaceRef s = NULL;
        int kr2 = _ATFBGetLayerDefaultSurface(conn, 0, &s);
        P(@"PROBE_P5 GetLayerDefaultSurface kr=%d surface=%@", kr2, s ? @"ok" : @"NULL");
        // R33-D：三个读数符号必须全部判空。GetWidth 判了而 GetHeight 没判 →
        // 空函数指针调用 = EXC_BAD_ACCESS = 探针崩溃 = P5 全量结论连回退一起丢
        if (kr2 == 0 && s && _ATSurfaceGetBase && _ATSurfaceGetWidth && _ATSurfaceGetHeight) {
            size_t w = _ATSurfaceGetWidth(s), h = _ATSurfaceGetHeight(s);
            uint32_t seed = 0;
            if (_ATSurfaceLock) _ATSurfaceLock(s, 0, &seed);
            uint8_t *p = (uint8_t *)_ATSurfaceGetBase(s);
            P(@"PROBE_P5 framebuffer %zux%zu first_pixel=%02x%02x%02x%02x",
              w, h, p ? p[0] : 0, p ? p[1] : 0, p ? p[2] : 0, p ? p[3] : 0);
            if (_ATSurfaceUnlock) _ATSurfaceUnlock(s, 0, seed);
            P(@"PROBE_P5 verdict=FRAMEBUFFER-OK (无IPC，阶段2首选)");
            return;
        }
    }

    // 回退：AutoTouch 实证路径（调用方自建 IOSurface → RenderDisplay）
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    _ATRenderDisplay = qc ? dlsym(qc, "CARenderServerRenderDisplay") : NULL;
    if (!_ATSurfaceCreate || !_ATRenderDisplay) {
        P(@"PROBE_P5 FAIL no fallback symbols (surface=%@ render=%@)",
          _ATSurfaceCreate ? @"ok" : @"NULL", _ATRenderDisplay ? @"ok" : @"NULL");
        return;
    }
    // 优先用调用方给的真实分辨率（App 侧会传 nativeBounds）
    if (reqW > 0 && reqH > 0 && ATRenderOne(reqW, reqH)) {
        P(@"PROBE_P5 verdict=FALLBACK-RENDERDISPLAY-OK (size from caller %dx%d)", reqW, reqH);
        return;
    }
    for (size_t i = 0; i < AT_TRY_SIZES; i++) {
        if (ATRenderOne(kATFallbackSizes[i][0], kATFallbackSizes[i][1])) {
            P(@"PROBE_P5 verdict=FALLBACK-RENDERDISPLAY-OK (auto size %dx%d, index=%zu)",
              kATFallbackSizes[i][0], kATFallbackSizes[i][1], i);
            return;
        }
    }
    P(@"PROBE_P5 verdict=BOTH-FAILED");
}

#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *base = nil, *from = @"?";
        int w = 0, h = 0;
        for (int i = 1; i < argc - 1; i++) {
            if (!strcmp(argv[i], "--base")) base = [NSString stringWithUTF8String:argv[i + 1]];
            if (!strcmp(argv[i], "--from")) from = [NSString stringWithUTF8String:argv[i + 1]];
            if (!strcmp(argv[i], "--w"))    w = atoi(argv[i + 1]);
            if (!strcmp(argv[i], "--h"))    h = atoi(argv[i + 1]);
        }
        if (!base) {
            printf("usage: ATLiteProbe --base <dir> --from <app|springboard> [--w px] [--h px]\n");
            return 2;
        }

        NSString *logs = [base stringByAppendingPathComponent:@"logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logs
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *logPath = [logs stringByAppendingPathComponent:@"probe.log"];
        gOut = fopen(logPath.fileSystemRepresentation, "a");
        // R33-G：root 拥有 + 0644 让 mobile 可读即可；0666 额外开放了"任意进程可写"，无必要
        if (gOut) chmod(logPath.fileSystemRepresentation, 0644);

        P(@"=== ATLiteProbe v0.3.10 begin (from=%@) ===", from);
        probe_identity();
        probe_hid();
        probe_framebuffer(w, h);
        P(@"=== ATLiteProbe end ===");
        if (gOut) fclose(gOut);
    }
    return 0;
}
