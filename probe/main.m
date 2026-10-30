#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// 自定义类型名：与 SDK 任何声明都不冲突
typedef struct __ATIOSurface *ATSurfaceRef;
typedef struct __ATFBConn *ATFBConn;
typedef struct __ATIOHIDEvent *ATEventRef;
typedef struct __ATIOHIDClient *ATClientRef;

static NSString *gFrom = @"unknown", *gRunID = @"unknown";

static void P(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *line = [NSString stringWithFormat:@"run_id=%@ from=%@ %@", gRunID, gFrom, s];
    printf("%s\n", line.UTF8String);
    fflush(stdout);
}

#pragma mark - P3: 我是谁

// Identity is diagnostic only; default installation deliberately has no setuid bit.
static void probe_identity(void) {
    P(@"PROBE_P3 uid=%d euid=%d gid=%d egid=%d pid=%d ppid=%d",
      getuid(), geteuid(), getgid(), getegid(), getpid(), getppid());
    P(@"PROBE_P3 verdict=%@", geteuid() == 0 ? @"ROOT" : @"NOT-ROOT diagnostic-limit: default probe has no privileged controller");
}

#pragma mark - P4: HID 触摸注入

static ATClientRef (*_ATClientCreate)(CFAllocatorRef);
static void (*_ATClientDispatch)(ATClientRef, ATEventRef);
static ATEventRef (*_ATCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                        uint32_t, uint32_t, double, double, double, double,
                                        double, boolean_t, boolean_t, uint32_t);
static ATEventRef (*_ATCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                     double, double, double, double, double,
                                     boolean_t, boolean_t, uint32_t);
static void (*_ATAppendEvent)(ATEventRef, ATEventRef, uint32_t);
static void (*_ATSetInt)(ATEventRef, uint32_t, CFIndex);
static void (*_ATSetFloat)(ATEventRef, uint32_t, double);

// WebKit IOKitSPIIOS.h uses IOHIDFloat = double for these private SPI.
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
    if (!_ATClientCreate || !_ATClientDispatch || !_ATCreateDigitizer || !_ATCreateFinger || !_ATAppendEvent || !_ATSetInt || !_ATSetFloat) {
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
    // Prepare the release before injecting any contact. Allocation failure must
    // never leave a down event without its corresponding ready-to-send up event.
    // Both prepared events use the same monotonic timestamp (nondecreasing).
    ATEventRef hand2 = _ATCreateDigitizer(kCFAllocatorDefault, ts, AT_TRANSDUCER_HAND,
        0, 0, AT_EV_TOUCH, 0, 0, 0, 0, 0, 0, 0, true, 0);
    ATEventRef fg2 = _ATCreateFinger(kCFAllocatorDefault, ts, 1, 2,
        (uint32_t)AT_EV_TOUCH, 160, 300, 0, 0, 0, 0, 0, 0);
    if (!hand || !fg || !hand2 || !fg2) {
        P(@"PROBE_P4 FAIL event allocation; no touch dispatched");
        if (hand) CFRelease(hand); if (fg) CFRelease(fg);
        if (hand2) CFRelease(hand2); if (fg2) CFRelease(fg2);
        CFRelease(client);
        return;
    }
    // All setters and append were validated above; configure both event trees
    // with the same display field and child geometry before dispatch.
    _ATSetInt(hand, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _ATSetInt(fg, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _ATSetInt(hand2, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _ATSetInt(fg2, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _ATSetFloat(fg, AT_FIELD_MAJOR_RADIUS, 4.0);
    _ATSetFloat(fg, AT_FIELD_MINOR_RADIUS, 3.0);
    _ATSetFloat(fg2, AT_FIELD_MAJOR_RADIUS, 4.0);
    _ATSetFloat(fg2, AT_FIELD_MINOR_RADIUS, 3.0);
    _ATAppendEvent(hand, fg, 0);
    _ATAppendEvent(hand2, fg2, 0);
    _ATClientDispatch(client, hand);
    P(@"PROBE_P4 dispatched touchDown(160,300)");
    usleep(60000);
    _ATClientDispatch(client, hand2);
    P(@"PROBE_P4 dispatched touchUp");
    P(@"PROBE_P4 verdict=DISPATCHED (dispatch does not prove input delivery)");
    CFRelease(hand); CFRelease(fg);
    CFRelease(hand2); CFRelease(fg2); CFRelease(client);
}

#pragma mark - P5: RenderDisplay diagnostic (framebuffer discovery unsupported)

static int (*_ATFBOpen)(mach_port_t, task_t, unsigned int, ATFBConn *);
static int (*_ATFBGetLayerDefaultSurface)(ATFBConn, int, ATSurfaceRef *);
static ATSurfaceRef (*_ATSurfaceCreate)(CFDictionaryRef);
static size_t (*_ATSurfaceGetWidth)(ATSurfaceRef);
static size_t (*_ATSurfaceGetHeight)(ATSurfaceRef);
static void *(*_ATSurfaceGetBase)(ATSurfaceRef);
static int32_t (*_ATSurfaceLock)(ATSurfaceRef, uint32_t, uint32_t *);
static kern_return_t (*_ATSurfaceUnlock)(ATSurfaceRef, uint32_t, uint32_t *);
static void (*_ATRenderDisplay)(uint32_t, CFStringRef, ATSurfaceRef, uint32_t, uint32_t);

// R33-B：常见 iPhone 物理像素尺寸表。SpringBoard 侧 spawn 时不方便取 UIScreen
// （要跳主线程，得再套一层 E30 超时），所以这里不依赖调用方传尺寸：
// 单一硬编码分辨率会让非该分辨率的机型**必然**失败，从而把 "NO-READABLE-BUFFER"
// 误报给阶段 2 的决策依据。逐个尝试，命中即止。
static const int kATFallbackSizes[][2] = {
    {1170, 2532}, {1179, 2556}, {1284, 2778}, {1290, 2796}, {1080, 2400},
    {828, 1792}, {750, 1334}, {640, 1136}, {1125, 2436}, {1242, 2688},
    {1668, 2388}
};
#define AT_TRY_SIZES ((size_t)(sizeof(kATFallbackSizes) / sizeof(kATFallbackSizes[0])))

// Render success also requires a locked, nonempty, readable surface; content is unverified.
static BOOL ATRenderOne(int w, int h) {
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return NO;
    uint32_t bgra = 0x42475241u; // 'BGRA'
    NSDictionary *props = @{
        @"IOSurfaceIsGlobal":        @YES,
        @"IOSurfaceBytesPerElement": @4,
        @"IOSurfaceBytesPerRow":     @(w * 4),
        @"IOSurfaceWidth":           @(w),
        @"IOSurfaceHeight":          @(h),
        @"IOSurfacePixelFormat":     @(bgra),
        @"IOSurfaceAllocSize":       @(w * h * 4),
    };
    ATSurfaceRef sf = _ATSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!sf) { P(@"PROBE_P5 RenderDisplay %dx%d surface=NULL", w, h); return NO; }
    _ATRenderDisplay(0, CFSTR("LCD"), sf, 0, 0);
    uint32_t seed = 0;
    kern_return_t lockRC = _ATSurfaceLock(sf, 1, &seed);
    size_t width = _ATSurfaceGetWidth(sf), height = _ATSurfaceGetHeight(sf);
    uint8_t *pixels = lockRC == KERN_SUCCESS ? _ATSurfaceGetBase(sf) : NULL;
    BOOL readable = lockRC == KERN_SUCCESS && width > 0 && height > 0 && pixels;
    unsigned first = readable ? pixels[0] : 0;
    P(@"PROBE_P5 RenderDisplay %dx%d lock=%d size=%zux%zu readable=%d sample=%02x (pixel correctness unverified)", w, h, lockRC, width, height, readable, first);
    if (lockRC == KERN_SUCCESS) _ATSurfaceUnlock(sf, 1, &seed);
    CFRelease(sf);
    return readable;
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

    // No verified service-discovery entry is available here. Calling Open with
    // service=0 is not a permission test; do not infer a framebuffer denial.
    P(@"PROBE_P5 framebuffer entry=UNSUPPORTED (service discovery unimplemented)");

    // 回退：AutoTouch 实证路径（调用方自建 IOSurface → RenderDisplay）
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    _ATRenderDisplay = qc ? dlsym(qc, "CARenderServerRenderDisplay") : NULL;
    if (!_ATSurfaceCreate || !_ATRenderDisplay || !_ATSurfaceLock || !_ATSurfaceUnlock || !_ATSurfaceGetBase || !_ATSurfaceGetWidth || !_ATSurfaceGetHeight) {
        P(@"PROBE_P5 FAIL no fallback symbols (surface=%@ render=%@)",
          _ATSurfaceCreate ? @"ok" : @"NULL", _ATRenderDisplay ? @"ok" : @"NULL");
        return;
    }
    // 优先用调用方给的真实分辨率（App 侧会传 nativeBounds）
    if (reqW > 0 && reqH > 0 && ATRenderOne(reqW, reqH)) {
        P(@"PROBE_P5 verdict=BUFFER-READABLE content=UNVERIFIED (size from caller %dx%d)", reqW, reqH);
        return;
    }
    for (size_t i = 0; i < AT_TRY_SIZES; i++) {
        if (ATRenderOne(kATFallbackSizes[i][0], kATFallbackSizes[i][1])) {
            P(@"PROBE_P5 verdict=BUFFER-READABLE content=UNVERIFIED (auto size %dx%d, index=%zu)",
              kATFallbackSizes[i][0], kATFallbackSizes[i][1], i);
            return;
        }
    }
    P(@"PROBE_P5 verdict=NO-READABLE-BUFFER");
}

#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        int w = 0, h = 0;
        for (int i = 1; i + 1 < argc; i += 2) {
            NSString *value = [NSString stringWithUTF8String:argv[i + 1]] ?: @"invalid";
            // Tags are bounded to a single output token to keep records attributable.
            NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
            NSString *tag = [[value componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
            if (tag.length > 80) tag = [tag substringToIndex:80];
            if (!strcmp(argv[i], "--from")) gFrom = tag;
            if (!strcmp(argv[i], "--run-id")) gRunID = tag;
            if (!strcmp(argv[i], "--w")) w = atoi(argv[i + 1]);
            if (!strcmp(argv[i], "--h")) h = atoi(argv[i + 1]);
        }
        P(@"PROBE_BEGIN");
        probe_identity();
        probe_hid();
        probe_framebuffer(w, h);
        P(@"PROBE_END");
    }
    return 0;
}
