// ATLiteTweak v0.3.5 — AutoTouch-style script runner (roothide/Dopamine, rootless fallback)
//
// 重写版。本文件遵循 docs/ERRORS.md 全部规避规则：
//  - R1/R2/R3/R4/R5：所有私有符号名、枚举值、函数签名均标注权威来源，
//    全部经过真机提取头文件 / WebKit SPI / KIF / SimulateTouch / AutoTouch 反汇编取证，
//    禁止凭记忆新增任何私有 API 调用。
//  - R17：Extensions.lua 带版本标记，版本感知覆写。
//
// 架构（对齐 AutoTouch 8.6.3，见 at_analysis/AutoTouch分析报告.md）：
//  - Lua 5.3 引擎住在 tweak 内（SpringBoard 进程），App 只是管理器
//  - 脚本 .at（Lua 语法），存 <jbroot>/var/mobile/Library/ATLite/Scripts/
//  - App 经 command.json + Darwin 通知指挥 tweak（AutoTouch 同构）
//  - 触摸/按键 = IOHIDEvent 合成；抓屏 = CARenderServer；搜字 = Vision OCR

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <time.h>
#import <math.h>
#import <stdlib.h>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

// ============================================================================
// R14：theos SDK 的 Vision 头缺 VNRecognizedText.h（仅 @class 前置声明）。
// 以下成员 iOS 13+ 运行时存在（部署目标 14.0），仅补编译期声明。
// 来源：Apple 文档 + KIF 实际调用。
// ============================================================================
@interface VNRecognizedText (ATLiteSDKCompat)
- (NSArray<VNRecognizedText *> *)topCandidates:(NSUInteger)maxCandidateCount;
@property (nonatomic, readonly) CGRect boundingBox;
@end

#define AT_DARWIN_NOTIFY @"me.atlite.command"

#pragma mark - Paths

// jbroot 推导（RESEARCH D1）：以自身 dylib 路径推导（与安装路径天然一致），探测仅作回退
static NSString *gJBRootSource = nil; // 诊断用：记录推导方式
static NSString *ATJBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 自身安装于 <jbroot>/Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib
        // ⚠ C1 教训：本 block 内禁止 ATLog（ATLog→ATLogsDir→ATBaseDir→ATJBRoot 重入死锁）
        Dl_info info;
        if (dladdr((void *)ATJBRoot, &info) && info.dli_fname) {
            NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
            NSRange r = [selfPath rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
            if (r.location != NSNotFound && r.location > 0) {
                root = [selfPath substringToIndex:r.location];
                gJBRootSource = @"dladdr";
                return;
            }
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        // Dopamine-roothide 实证（DOBootstrapper.m）：/var/jb 是指向 jbroot 的 symlink；
        // jbroot 真实位置 /var/containers/Bundle/Application/.jbroot-<16hex>
        if ([fm fileExistsAtPath:@"/var/jb"]) { root = @"/var/jb"; gJBRootSource = @"probe:/var/jb"; return; }
        NSArray *cands = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        for (NSString *n in cands) {
            if ([n hasPrefix:@".jbroot-"]) {
                root = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:n];
                gJBRootSource = @"probe:.jbroot";
                return;
            }
        }
        root = @"/var/jb"; // fallback
        gJBRootSource = @"fallback";
    });
    return root;
}

static NSString *ATBaseDir(void)    { return [ATJBRoot() stringByAppendingString:@"/var/mobile/Library/ATLite"]; }
static NSString *ATScriptsDir(void) { return [ATBaseDir() stringByAppendingPathComponent:@"Scripts"]; }
static NSString *ATLibsDir(void)    { return [ATBaseDir() stringByAppendingPathComponent:@"LuaLibraries"]; }
static NSString *ATLogsDir(void)    { return [ATBaseDir() stringByAppendingPathComponent:@"logs"]; }
static NSString *ATImagesDir(void)  { return [ATBaseDir() stringByAppendingPathComponent:@"Images"]; }

#pragma mark - Logging

static void ATLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void ATLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[ATLite] %@", line);
    @try {
        NSString *logPath = [ATLogsDir() stringByAppendingPathComponent:@"tweak.log"];
        FILE *f = fopen(logPath.fileSystemRepresentation, "a");
        if (f) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"HH:mm:ss";
            NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], line];
            fputs(out.UTF8String, f);
            fclose(f);
        }
    } @catch (__unused id e) {}
}

#pragma mark - Touch/key simulation (IOHIDEvent)

// ---- 常量（R2：四方来源一致，写出推导算式）----
// 来源：WebKit IOKitSPIIOS.h、KIF IOHIDEvent+KIF.m、rpc-project consts.py、IDAObjcTypes Types.h
// base = kIOHIDEventTypeDigitizer(11) << 16 = 0x000B0000
//   MajorRadius          = base + 20 = 0x000B0014
//   MinorRadius          = base + 21 = 0x000B0015
//   IsDisplayIntegrated  = MajorRadius + 5 = base + 25 = 0x000B0019
//   ⚠ 0x000B000B 是 BarrelPressure（base+11），E2 的教训
enum {
    kIOHIDDigitizerEventRange    = 0x00000001,
    kIOHIDDigitizerEventTouch    = 0x00000002,
    kIOHIDDigitizerEventPosition = 0x00000004,
};
enum { kIOHIDDigitizerTransducerTypeHand = 3 };

#define AT_FIELD_MAJOR_RADIUS         0x000B0014
#define AT_FIELD_MINOR_RADIUS         0x000B0015
#define AT_FIELD_IS_DISPLAY_INTEGRATED 0x000B0019

// ---- 符号与签名（R1/R5：逐参数对照 nanotech/iphoneheaders IOHIDEvent.h）----
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

static IOHIDEventSystemClientRef (*_AT_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static void (*_AT_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);
// DigitizerEvent(15 参): allocator, ts, transducerType, index, identity, eventMask, options,
//                        x, y, z, tipPressure, barrelPressure, range, touch, options
static IOHIDEventRef (*_AT_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, Float32, Float32, Float32, Float32, Float32, Boolean, Boolean, uint32_t);
// FingerEvent（13 参，E5 的教训——多一个 uint32 都会错位寄存器）:
//   allocator, ts, index, identity, eventMask, x, y, z, tipPressure, twist, range, touch, options
static IOHIDEventRef (*_AT_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Float32, Float32, Float32, Float32, Float32, Boolean, Boolean, uint32_t);
static void (*_AT_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
// ⚠ E1：真实符号名以 ...Value 结尾；"IOHIDEventSetInteger" 不存在
static void (*_AT_IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int32_t);
static void (*_AT_IOHIDEventSetFloatValue)(IOHIDEventRef, uint32_t, Float32);
// 键盘：usagePage/usage 真实类型 uint16_t（F48）
static IOHIDEventRef (*_AT_IOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, Boolean, uint32_t);

static IOHIDEventSystemClientRef gHIDClient = nil;
static BOOL gHIDReady = NO;

static void ATLoadHIDSymbols(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) { ATLog(@"IOKit dlopen failed: %s", dlerror()); return; }
#define ATSYM(var, name) (var = (typeof(var))dlsym(iokit, name))
    ATSYM(_AT_IOHIDEventSystemClientCreate,         "IOHIDEventSystemClientCreate");
    ATSYM(_AT_IOHIDEventSystemClientDispatchEvent,  "IOHIDEventSystemClientDispatchEvent");
    ATSYM(_AT_IOHIDEventCreateDigitizerEvent,       "IOHIDEventCreateDigitizerEvent");
    ATSYM(_AT_IOHIDEventCreateDigitizerFingerEvent, "IOHIDEventCreateDigitizerFingerEvent");
    ATSYM(_AT_IOHIDEventAppendEvent,                "IOHIDEventAppendEvent");
    ATSYM(_AT_IOHIDEventSetIntegerValue,            "IOHIDEventSetIntegerValue");
    ATSYM(_AT_IOHIDEventSetFloatValue,              "IOHIDEventSetFloatValue");
    ATSYM(_AT_IOHIDEventCreateKeyboardEvent,        "IOHIDEventCreateKeyboardEvent");
#undef ATSYM
    if (!_AT_IOHIDEventSystemClientCreate || !_AT_IOHIDEventSystemClientDispatchEvent ||
        !_AT_IOHIDEventCreateDigitizerEvent || !_AT_IOHIDEventCreateDigitizerFingerEvent ||
        !_AT_IOHIDEventAppendEvent || !_AT_IOHIDEventSetIntegerValue ||
        !_AT_IOHIDEventSetFloatValue) {
        ATLog(@"IOHIDEvent symbols incomplete, touch sim disabled");
        return;
    }
    gHIDClient = _AT_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    gHIDReady = (gHIDClient != nil);
    ATLog(@"IOHIDEvent ready: %@ (keyboard: %@)",
          gHIDReady ? @"YES" : @"NO",
          _AT_IOHIDEventCreateKeyboardEvent ? @"YES" : @"NO");
}

// ---- 拟人化三件套（用户需求：坐标抖动/随机时间戳/随机接触面积）----
// 依据：真人落点 ±2pt 噪声、事件时间戳 ±1ms 抖动、指尖椭圆 3.5~6mm（Apple 默认 5mm，单位 mm）

// [-amount, +amount) 均匀抖动
static float ATJitter(float amount) {
    return ((float)arc4random_uniform(2000) / 1999.0f * 2.0f - 1.0f) * amount;
}

// ---------------------------------------------------------------------------
// E25-C：事件节流。脚本若高频合成 HID 事件（死循环 / 无 sleep 的密集点击），
// 会把 SpringBoard 的事件队列淹没 —— 表现正是"整个系统打不开新程序"。
// 这里限制最小事件间隔（默认 8ms ≈ 125 事件/秒），超出就 sleeps 补齐。
// ---------------------------------------------------------------------------
#define AT_MIN_EVENT_INTERVAL_SEC 0.008
static CFAbsoluteTime gLastEventTime = 0.0;
static void ATThrottleEvents(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLastEventTime > 0) {
        double dt = now - gLastEventTime;
        if (dt >= 0 && dt < AT_MIN_EVENT_INTERVAL_SEC) {
            struct timespec ts;
            ts.tv_sec = 0;
            ts.tv_nsec = (long)((AT_MIN_EVENT_INTERVAL_SEC - dt) * 1000000000.0);
            nanosleep(&ts, NULL);
        }
    }
    gLastEventTime = CFAbsoluteTimeGetCurrent();
}

// mach_absolute_time() ± 1ms（mach_timebase 正确换算 ticks）
static uint64_t ATTimestampNow(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    if (tb.numer == 0 || tb.denom == 0) return mach_absolute_time();
    uint64_t half = (1000000ULL * (uint64_t)tb.numer) / (uint64_t)tb.denom; // 1ms → ticks
    if (half == 0 || half > 0x7fffffffULL) return mach_absolute_time();
    return mach_absolute_time() + (int64_t)arc4random_uniform((uint32_t)(half * 2)) - (int64_t)half;
}

// action: 0=down 1=move 2=up
// 事件装配（R4）：与 SimulateTouch/KIF 逐参数一致（F42/F43）——
//   hand（父）：index=0 identity=0 x/y/z=0 压力=0 mask=Touch range=0 touch=true
//   finger（子）：index 从 1 起（finger+1）、identity=2、mask 动态、tipPressure=0
static void ATSimulateTouch(int action, int finger, float x, float y) {
    if (!gHIDReady) return;
    uint64_t ts = ATTimestampNow();
    BOOL isUp = (action == 2);
    uint32_t mask = (action == 1)
        ? (kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventTouch)
        : (kIOHIDDigitizerEventRange   | kIOHIDDigitizerEventTouch);
    Boolean touching = isUp ? 0 : 1;

    // 拟人化 1：坐标抖动（down/up ±2pt、move ±1pt）
    float j = (action == 1) ? 1.0f : 2.0f;
    x += ATJitter(j);
    y += ATJitter(j);

    // 拟人化 3：随机接触面积（major 3.5~6.0mm、minor 2.5~4.5mm，minor ≤ major）
    float major = 3.5f + (float)arc4random_uniform(251) / 100.0f;
    float minor = 2.5f + (float)arc4random_uniform(201) / 100.0f;
    if (minor > major) minor = major;

    IOHIDEventRef hand = _AT_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand,
        0, 0, kIOHIDDigitizerEventTouch, 0,
        0, 0, 0, 0, 0, 0, true, 0);
    IOHIDEventRef fg = _AT_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        (uint32_t)(finger + 1), 2, mask,
        x, y, 0, 0, 0, touching, touching, 0);
    if (!hand || !fg) { if (hand) CFRelease(hand); if (fg) CFRelease(fg); return; }
    _AT_IOHIDEventAppendEvent(hand, fg, 0);
    _AT_IOHIDEventSetIntegerValue(hand, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _AT_IOHIDEventSetIntegerValue(fg,   AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _AT_IOHIDEventSetFloatValue(fg, AT_FIELD_MAJOR_RADIUS, major);
    _AT_IOHIDEventSetFloatValue(fg, AT_FIELD_MINOR_RADIUS, minor);
    ATThrottleEvents(); // E25-C：节流，避免事件风暴拖垮 SpringBoard
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, hand);
    CFRelease(hand);
    CFRelease(fg);
}

// keyDown/keyUp: consumer page (0x0C) 用法码，与 AutoTouch KEY_TYPE 一致
#define AT_HID_USAGE_PAGE_CONSUMER 0x0C
static void ATSimulateKey(BOOL down, int usage) {
    if (!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent) return;
    IOHIDEventRef ev = _AT_IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, ATTimestampNow(),
        AT_HID_USAGE_PAGE_CONSUMER, (uint16_t)usage, down ? TRUE : FALSE, 0);
    if (!ev) return;
    ATThrottleEvents(); // E25-C
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, ev);
    CFRelease(ev);
}

#pragma mark - Screen capture (CARenderServer + IOSurface)

typedef struct CF_BRIDGED_TYPE(id) __IOSurface *IOSurfaceRef;
// R3：真实签名（AutoTouch libATGraphic 反汇编 + ios-mcp 实证，F46/F47）：
//   IOSurfaceRef CARenderServerCaptureDisplay(uint32_t serverPort=0, CFStringRef displayName, CFDictionaryRef options)
//   首参 0 = 默认 server（不是指针！），第二参显示屏名 iOS="LCD"（备选 "Main"）
static IOSurfaceRef (*_AT_CARenderServerCaptureDisplay)(uint32_t, CFStringRef, CFDictionaryRef);
static size_t (*_AT_IOSurfaceGetWidth)(IOSurfaceRef);
static size_t (*_AT_IOSurfaceGetHeight)(IOSurfaceRef);
static size_t (*_AT_IOSurfaceGetBytesPerRow)(IOSurfaceRef);
static uint32_t (*_AT_IOSurfaceGetPixelFormat)(IOSurfaceRef);
static void * (*_AT_IOSurfaceGetBaseAddress)(IOSurfaceRef);
// 可选（缺失不阻塞）：读前 Lock/Unlock（AutoTouch 同模式）
static int32_t (*_AT_IOSurfaceLock)(IOSurfaceRef, uint32_t, uint32_t *);
static void (*_AT_IOSurfaceUnlock)(IOSurfaceRef, uint32_t, uint32_t);
static BOOL gCaptureReady = NO;

static void ATLoadCaptureSymbols(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!qc || !ios) {
        // m1：dlerror 每调用一次清空一次，显式取一次存变量，避免诊断信息被吞
        char *eqc = qc ? NULL : dlerror();
        char *eios = ios ? NULL : dlerror();
        ATLog(@"QuartzCore/IOSurface dlopen failed: %s / %s",
              qc ? "ok" : (eqc ?: "?"), ios ? "ok" : (eios ?: "?"));
        return;
    }
    _AT_CARenderServerCaptureDisplay = (typeof(_AT_CARenderServerCaptureDisplay))dlsym(qc, "CARenderServerCaptureDisplay");
    _AT_IOSurfaceGetWidth            = (typeof(_AT_IOSurfaceGetWidth))dlsym(ios, "IOSurfaceGetWidth");
    _AT_IOSurfaceGetHeight           = (typeof(_AT_IOSurfaceGetHeight))dlsym(ios, "IOSurfaceGetHeight");
    _AT_IOSurfaceGetBytesPerRow      = (typeof(_AT_IOSurfaceGetBytesPerRow))dlsym(ios, "IOSurfaceGetBytesPerRow");
    _AT_IOSurfaceGetPixelFormat      = (typeof(_AT_IOSurfaceGetPixelFormat))dlsym(ios, "IOSurfaceGetPixelFormat");
    _AT_IOSurfaceGetBaseAddress      = (typeof(_AT_IOSurfaceGetBaseAddress))dlsym(ios, "IOSurfaceGetBaseAddress");
    _AT_IOSurfaceLock                = (typeof(_AT_IOSurfaceLock))dlsym(ios, "IOSurfaceLock");
    _AT_IOSurfaceUnlock              = (typeof(_AT_IOSurfaceUnlock))dlsym(ios, "IOSurfaceUnlock");
    if (!_AT_CARenderServerCaptureDisplay ||
        !_AT_IOSurfaceGetWidth || !_AT_IOSurfaceGetHeight || !_AT_IOSurfaceGetBytesPerRow ||
        !_AT_IOSurfaceGetPixelFormat || !_AT_IOSurfaceGetBaseAddress) {
        ATLog(@"CARenderServer/IOSurface symbols incomplete, capture disabled");
        return;
    }
    gCaptureReady = YES;
    ATLog(@"capture ready: YES (lock: %@)", _AT_IOSurfaceLock ? @"YES" : @"NO");
}

typedef struct { uint8_t *rgba; int w, h; } ATBitmap;

// RESEARCH C3：抓屏位图是物理像素，Lua 坐标是点。
// 自适应换算（位图宽/屏幕点宽），不假设 2x/3x —— 1x 时恒为 1，无损害。
static double ATCaptureScale(const ATBitmap *b);

static void ATFreeBitmap(ATBitmap *b) {
    if (b->rgba) { free(b->rgba); b->rgba = NULL; }
    b->w = b->h = 0;
}

// ---------------------------------------------------------------------------
// E25-A：抓屏看门狗。
// CARenderServerCaptureDisplay 是到 render server 的**同步 IPC**。一旦 render server
// 与 SpringBoard 互相等待，这个调用永不返回 —— 而脚本跑在 SpringBoard 进程里，
// 表现就是"整个系统打不开新程序，只能重启"。
// 对策：把调用挪到专用串行队列，调用方只等有限时间（1.5s）。超时即认定渲染链路
// 已挂，本进程内**永久停用抓屏**并记日志 —— 宁可功能失效，也不拖垮系统。
// 注：AutoTouch（稳定运行多年）实证只导入 _CARenderServerRenderDisplay（调用者自带
// IOSurface），并未使用 CaptureDisplay；本版先加看门狗止血，API 对齐见 ERRORS.md E25。
// ---------------------------------------------------------------------------
#define AT_CAPTURE_TIMEOUT_SEC 1.5
static dispatch_queue_t gCaptureQueue = NULL;
static BOOL gCaptureBroken = NO;

static IOSurfaceRef ATCaptureSurfaceWithTimeout(void) {
    if (gCaptureBroken) return NULL;
    if (!gCaptureQueue) {
        gCaptureQueue = dispatch_queue_create("me.atlite.capture", DISPATCH_QUEUE_SERIAL);
    }
    __block IOSurfaceRef s = NULL;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(gCaptureQueue, ^{
        s = _AT_CARenderServerCaptureDisplay(0, CFSTR("LCD"), NULL);
        if (!s) s = _AT_CARenderServerCaptureDisplay(0, CFSTR("Main"), NULL);
        dispatch_semaphore_signal(sem);
    });
    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                    (int64_t)(AT_CAPTURE_TIMEOUT_SEC * NSEC_PER_SEC)));
    if (r != 0) {
        // 超时：渲染链路已挂。标记后不再重试（重试只会再泄漏一个卡死的线程）
        gCaptureBroken = YES;
        ATLog(@"capture hung >%.1fs — disabled for this session (E25 render-server deadlock guard)",
              AT_CAPTURE_TIMEOUT_SEC);
        return NULL;
    }
    return s;
}

// 抓主屏 → RGBA8（仅 SpringBoard 进程可用）
static BOOL ATCaptureScreen(ATBitmap *out) {
    if (!gCaptureReady) return NO;
    IOSurfaceRef s = ATCaptureSurfaceWithTimeout();
    if (!s) return NO;
    uint32_t seed = 0;
    if (_AT_IOSurfaceLock) _AT_IOSurfaceLock(s, 1 /*kIOSurfaceLockReadOnly*/, &seed);
    int w = (int)_AT_IOSurfaceGetWidth(s);
    int h = (int)_AT_IOSurfaceGetHeight(s);
    size_t pitch = _AT_IOSurfaceGetBytesPerRow(s);
    uint32_t fmt = _AT_IOSurfaceGetPixelFormat(s); // 'BGRA' 或 'ARGB'
    uint8_t *base = (uint8_t *)_AT_IOSurfaceGetBaseAddress(s);
    if (w <= 0 || h <= 0 || !base) {
        if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, seed);
        CFRelease(s); return NO;
    }
    out->w = w; out->h = h;
    out->rgba = (uint8_t *)malloc((size_t)w * h * 4);
    if (!out->rgba) {
        if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, seed);
        CFRelease(s); return NO;
    }
    // 像素格式→RGBA 通道索引（M1：ARGB 的 G 在 2 号位，BGRA 的 G 在 1 号位；
    // 多字符字面量属实现定义行为，用显式数值：'ARGB'=0x41524742，'BGRA'=0x42475241）
    const uint32_t AT_FMT_ARGB = 0x41524742u;
    int rIdx, gIdx, bIdx;
    if (fmt == AT_FMT_ARGB) { rIdx = 1; gIdx = 2; bIdx = 3; }
    else                    { rIdx = 2; gIdx = 1; bIdx = 0; }  // 'BGRA'（iOS 抓屏常态）
    for (int y = 0; y < h; y++) {
        uint8_t *src = base + (size_t)y * pitch;
        uint8_t *dst = out->rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            dst[x*4+0] = src[x*4+rIdx];
            dst[x*4+1] = src[x*4+gIdx];
            dst[x*4+2] = src[x*4+bIdx];
            dst[x*4+3] = src[x*4+3];
        }
    }
    if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, seed);
    CFRelease(s);
    return YES;
}

static inline uint8_t ATLuma(const uint8_t *px) {
    return (uint8_t)((px[0] * 299 + px[1] * 587 + px[2] * 114) / 1000);
}

#pragma mark - Image matching (粗到细 NCC)

typedef struct { uint8_t *g; int w, h; } ATGray;

static void ATFreeGray(ATGray *g) { if (g->g) { free(g->g); g->g = NULL; } g->w = g->h = 0; }

static BOOL ATRGBAToGray(const ATBitmap *src, ATGray *dst) {
    dst->w = src->w; dst->h = src->h;
    dst->g = (uint8_t *)malloc((size_t)src->w * src->h);
    if (!dst->g) return NO;
    for (int y = 0; y < src->h; y++) {
        const uint8_t *s = src->rgba + (size_t)y * src->w * 4;
        uint8_t *d = dst->g + (size_t)y * src->w;
        for (int x = 0; x < src->w; x++) d[x] = ATLuma(s + x * 4);
    }
    return YES;
}

static BOOL ATGrayDownscale(const ATGray *src, ATGray *dst, int scale) {
    dst->w = src->w / scale; dst->h = src->h / scale;
    if (dst->w <= 0 || dst->h <= 0) return NO;
    dst->g = (uint8_t *)malloc((size_t)dst->w * dst->h);
    if (!dst->g) return NO;
    for (int y = 0; y < dst->h; y++)
        for (int x = 0; x < dst->w; x++)
            dst->g[(size_t)y * dst->w + x] = src->g[(size_t)(y * scale) * src->w + x * scale];
    return YES;
}

// 零均值 NCC，返回最佳位置与得分
static BOOL ATNCCBest(const ATGray *hay, const ATGray *needle, double minScore,
                      int *outX, int *outY, double *outScore) {
    if (needle->w < 4 || needle->h < 4 || hay->w < needle->w || hay->h < needle->h) return NO;
    double tMean = 0;
    for (int i = 0; i < needle->w * needle->h; i++) tMean += needle->g[i];
    tMean /= needle->w * needle->h;
    double tVar = 0;
    for (int i = 0; i < needle->w * needle->h; i++) {
        double d = needle->g[i] - tMean;
        tVar += d * d;
    }
    if (tVar < 1e-6) return NO;

    double best = -1;
    int bx = -1, by = -1;
    int maxX = hay->w - needle->w, maxY = hay->h - needle->h;
    for (int y = 0; y <= maxY; y++) {
        for (int x = 0; x <= maxX; x++) {
            double wMean = 0;
            size_t idx = (size_t)y * hay->w + x;
            for (int j = 0; j < needle->h; j++) {
                const uint8_t *row = hay->g + idx + (size_t)j * hay->w;
                for (int i = 0; i < needle->w; i++) wMean += row[i];
            }
            wMean /= needle->w * needle->h;
            double num = 0, wVar = 0;
            for (int j = 0; j < needle->h; j++) {
                const uint8_t *row = hay->g + idx + (size_t)j * hay->w;
                for (int i = 0; i < needle->w; i++) {
                    double d = row[i] - wMean;
                    wVar += d * d;
                    num += d * (needle->g[(size_t)j * needle->w + i] - tMean);
                }
            }
            if (wVar < 1e-6) continue;
            double score = num / sqrt(tVar * wVar);
            if (score > best) { best = score; bx = x; by = y; }
        }
    }
    if (bx < 0 || best < minScore) return NO;
    *outX = bx; *outY = by; *outScore = best;
    return YES;
}

// 完整搜图: 粗搜(1/4) → 粗命中附近 ±pad 原图精搜
static BOOL ATFindImageInScreen(const ATGray *screenFull, const ATBitmap *tmplRGBA,
                                double similarity, int *outX, int *outY, double *outScore) {
    ATGray tmplGray = {0};
    if (!ATRGBAToGray(tmplRGBA, &tmplGray)) return NO;

    ATGray screenQuarter = {0}, tmplQuarter = {0};
    int cx = 0, cy = 0;
    double score = 0;
    BOOL found = NO;
    if (ATGrayDownscale(screenFull, &screenQuarter, 4) && ATGrayDownscale(&tmplGray, &tmplQuarter, 4)) {
        found = ATNCCBest(&screenQuarter, &tmplQuarter, similarity - 0.15, &cx, &cy, &score);
    }
    ATFreeGray(&screenQuarter);
    ATFreeGray(&tmplQuarter);
    if (!found) { ATFreeGray(&tmplGray); return NO; }

    // 精搜窗口：粗命中(原图坐标)扩 pad，保证完整容纳模板
    const int pad = 12;
    int x0 = MAX(0, cx * 4 - pad);
    int y0 = MAX(0, cy * 4 - pad);
    int x1 = MIN(screenFull->w, cx * 4 + tmplGray.w + pad * 2 + 8);
    int y1 = MIN(screenFull->h, cy * 4 + tmplGray.h + pad * 2 + 8);
    if (x1 - x0 < tmplGray.w || y1 - y0 < tmplGray.h) { ATFreeGray(&tmplGray); return NO; }

    ATGray region = {0};
    region.w = x1 - x0; region.h = y1 - y0;
    region.g = (uint8_t *)malloc((size_t)region.w * region.h);
    if (!region.g) { ATFreeGray(&tmplGray); return NO; }
    for (int y = 0; y < region.h; y++)
        memcpy(region.g + (size_t)y * region.w,
               screenFull->g + (size_t)(y0 + y) * screenFull->w + x0, region.w);

    int rx = 0, ry = 0;
    double rs = 0;
    BOOL ok = ATNCCBest(&region, &tmplGray, similarity, &rx, &ry, &rs);
    if (ok) { *outX = x0 + rx; *outY = y0 + ry; *outScore = rs; }
    ATFreeGray(&region);
    ATFreeGray(&tmplGray);
    return ok;
}

// 模板 PNG/JPG → RGBA（路径白名单校验，防目录穿越）
static BOOL ATLoadTemplate(const char *nameUtf8, ATBitmap *out) {
    NSString *name = [NSString stringWithUTF8String:nameUtf8];
    if (name.length == 0 || name.length > 128) return NO;
    if ([name containsString:@"/"] || [name containsString:@"\\"] || [name containsString:@".."]) return NO;
    NSString *ext = name.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"png"] && ![ext isEqualToString:@"jpg"] &&
        ![ext isEqualToString:@"jpeg"]) return NO;
    NSString *path = [ATImagesDir() stringByAppendingPathComponent:name];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return NO;
    UIImage *img = [UIImage imageWithData:data];
    if (!img) return NO;
    CGImageRef cg = img.CGImage;
    int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0 || (long)w * h > 4000000) return NO;
    out->w = w; out->h = h;
    out->rgba = (uint8_t *)malloc((size_t)w * h * 4);
    if (!out->rgba) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(out->rgba, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { CGColorSpaceRelease(cs); free(out->rgba); out->rgba = NULL; return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return YES;
}

// CGImage ← RGBA（Vision OCR 用）
static CGImageRef ATCreateCGImageFromBitmap(const ATBitmap *b) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(b->rgba, b->w, b->h, 8, b->w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { CGColorSpaceRelease(cs); return NULL; }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return img;
}

#pragma mark - Lua engine (API 对齐 AutoTouch)

static CGSize ATScreenSize(void) {
    CGSize s = CGSizeMake(390, 844);
    @try { s = [UIScreen mainScreen].bounds.size; } @catch (__unused id e) {}
    return s;
}

// RESEARCH C3：位图像素宽 / 屏幕点宽 = 缩放（1x 设备为 1，无损害）
static double ATCaptureScale(const ATBitmap *b) {
    CGSize pts = ATScreenSize();
    if (pts.width <= 0 || b->w <= 0) return 1.0;
    double s = (double)b->w / pts.width;
    return s > 0 ? s : 1.0;
}

static int l_touchDown(lua_State *L) {
    ATSimulateTouch(0, (int)luaL_checkinteger(L,1), (float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3));
    return 0;
}
static int l_touchMove(lua_State *L) {
    ATSimulateTouch(1, (int)luaL_checkinteger(L,1), (float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3));
    return 0;
}
static int l_touchUp(lua_State *L) {
    ATSimulateTouch(2, (int)luaL_checkinteger(L,1), (float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3));
    return 0;
}
static int l_keyDown(lua_State *L) {
    ATSimulateKey(YES, (int)luaL_checkinteger(L,1)); return 0;
}
static int l_keyUp(lua_State *L) {
    ATSimulateKey(NO, (int)luaL_checkinteger(L,1)); return 0;
}
// AutoTouch 语义: usleep(微秒)
static int l_usleep(lua_State *L) {
    double us = luaL_checknumber(L,1);
    // E26：分片睡眠（每片 ≤50ms 检查一次停止）。
    // 否则 usleep(5秒) 期间点停止要等满 5 秒才生效，用户会以为停不掉。
    double left = us;
    while (left > 0) {
        double slice = left > 50000.0 ? 50000.0 : left;
        struct timespec req;
        req.tv_sec = 0;
        req.tv_nsec = (long)(slice * 1000.0);
        nanosleep(&req, NULL);
        if (ATShouldStop()) return luaL_error(L, "STOP");
        left -= slice;
    }
    return 0;
}
// ATLite 扩展: msleep(毫秒)
static int l_msleep(lua_State *L) {
    double ms = luaL_checknumber(L,1);
    // E26：同 l_usleep，分片检查停止
    double left = ms;
    while (left > 0) {
        double slice = left > 50.0 ? 50.0 : left;
        struct timespec req;
        req.tv_sec = 0;
        req.tv_nsec = (long)(slice * 1000000.0);
        nanosleep(&req, NULL);
        if (ATShouldStop()) return luaL_error(L, "STOP");
        left -= slice;
    }
    return 0;
}
static int l_log(lua_State *L) {
    int n = lua_gettop(L);
    NSMutableString *s = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        const char *v = lua_tostring(L, i);
        [s appendFormat:@"%s%s", v ? v : lua_typename(L, lua_type(L, i)), i < n ? " " : ""];
    }
    ATLog(@"[lua] %@", s);
    return 0;
}
static int l_screenWidth(lua_State *L)  { lua_pushnumber(L, ATScreenSize().width);  return 1; }
static int l_screenHeight(lua_State *L) { lua_pushnumber(L, ATScreenSize().height); return 1; }
static int l_rootDir(lua_State *L) {
    lua_pushstring(L, ATScriptsDir().fileSystemRepresentation);
    return 1;
}
// stop(): 终止脚本（AutoTouch 同名 API），以特定错误消息实现
static int l_stop(lua_State *L) {
    return luaL_error(L, "STOP");
}

static int l_getColor(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);   // 点坐标（Lua 层契约）
    int y = (int)luaL_checkinteger(L, 2);
    ATBitmap b = {0};
    if (!ATCaptureScreen(&b)) { lua_pushnil(L); return 1; }
    double scale = ATCaptureScale(&b);      // 点 → 像素
    int px = (int)llround(x * scale), py = (int)llround(y * scale);
    if (px < 0 || py < 0 || px >= b.w || py >= b.h) { ATFreeBitmap(&b); lua_pushnil(L); return 1; }
    const uint8_t *pxp = b.rgba + ((size_t)py * b.w + px) * 4;
    lua_pushinteger(L, (pxp[0] << 16) | (pxp[1] << 8) | pxp[2]);
    ATFreeBitmap(&b);
    return 1;
}

// findColor(color[, tolerance]) → { {x,y}, ... }（1/4 缩放扫描，最多 10 个）
static int l_findColor(lua_State *L) {
    unsigned int color = (unsigned int)luaL_checkinteger(L, 1);
    int tol = lua_isnumber(L, 2) ? (int)lua_tointeger(L, 2) : 16;
    uint8_t cr = (color >> 16) & 0xFF, cg = (color >> 8) & 0xFF, cb = color & 0xFF;
    ATBitmap b = {0};
    if (!ATCaptureScreen(&b)) { lua_pushnil(L); return 1; }
    int scanScale = 4, sw = b.w / scanScale, sh = b.h / scanScale;
    double ptScale = ATCaptureScale(&b);    // 像素 → 点（返回给 Lua）
    lua_newtable(L);
    int n = 0;
    for (int y = 0; y < sh && n < 10; y++) {
        for (int x = 0; x < sw && n < 10; x++) {
            const uint8_t *px = b.rgba + ((size_t)(y * scanScale) * b.w + x * scanScale) * 4;
            int dr = px[0] - (int)cr, dg = px[1] - (int)cg, db2 = px[2] - (int)cb;
            if (abs(dr) <= tol && abs(dg) <= tol && abs(db2) <= tol) {
                lua_newtable(L);
                lua_pushinteger(L, (lua_Integer)llround(x * scanScale / ptScale)); lua_rawseti(L, -2, 1);
                lua_pushinteger(L, (lua_Integer)llround(y * scanScale / ptScale)); lua_rawseti(L, -2, 2);
                lua_rawseti(L, -2, ++n);
            }
        }
    }
    ATFreeBitmap(&b);
    return 1;
}

// findImage("button.png"[, similarity]) → { {x, y, score}, ... }（中心点）
static int l_findImage(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    double sim = lua_isnumber(L, 2) ? lua_tonumber(L, 2) : 0.9;
    ATBitmap tmpl = {0};
    if (!ATLoadTemplate(name, &tmpl)) { ATLog(@"findImage: template not found: %s", name); lua_pushnil(L); return 1; }
    ATBitmap screen = {0};
    if (!ATCaptureScreen(&screen)) { ATFreeBitmap(&tmpl); lua_pushnil(L); return 1; }
    double ptScale = ATCaptureScale(&screen); // 释放前取（像素→点）
    ATGray screenGray = {0};
    BOOL haveGray = ATRGBAToGray(&screen, &screenGray);
    ATFreeBitmap(&screen);
    if (!haveGray) { ATFreeBitmap(&tmpl); lua_pushnil(L); return 1; }

    int x = 0, y = 0; double score = 0;
    lua_newtable(L);
    int n = 0;
    if (ATFindImageInScreen(&screenGray, &tmpl, sim, &x, &y, &score)) {
        // 像素 → 点（中心点返回，供 tap 直接用）
        lua_newtable(L);
        lua_pushinteger(L, (lua_Integer)llround((x + tmpl.w / 2.0) / ptScale)); lua_rawseti(L, -2, 1);
        lua_pushinteger(L, (lua_Integer)llround((y + tmpl.h / 2.0) / ptScale)); lua_rawseti(L, -2, 2);
        lua_pushnumber(L, score);           lua_rawseti(L, -2, 3);
        lua_rawseti(L, -2, ++n);
    }
    ATFreeGray(&screenGray);
    ATFreeBitmap(&tmpl);
    return 1;
}

// findText("设置") → { {x, y}, ... }（Vision OCR，中英文）
// 注：performRequests 本身同步，无需额外信号量
static int l_findText(lua_State *L) {
    const char *want = luaL_checkstring(L, 1);
    // M2：want 可能不是合法 UTF-8，@(want) 会得到 nil → containsString:nil 抛异常 → SpringBoard 崩溃
    NSString *wantStr = [NSString stringWithUTF8String:want];
    if (!wantStr || wantStr.length == 0) { lua_pushnil(L); return 1; }
    ATBitmap b = {0};
    if (!ATCaptureScreen(&b)) { lua_pushnil(L); return 1; }
    CGImageRef img = ATCreateCGImageFromBitmap(&b);
    if (!img) { ATFreeBitmap(&b); lua_pushnil(L); return 1; }

    __block NSMutableArray *hits = [NSMutableArray array];
    double ptScale = ATCaptureScale(&b);    // 像素 → 点
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:
        ^(VNRequest *request, NSError *error) {
            if (error) return;
            for (VNRecognizedText *t in request.results) {
                NSString *s = [t topCandidates:1].firstObject.string;
                if ([s containsString:wantStr]) {
                    CGRect bb = t.boundingBox; // 归一化、原点左下 → 像素中心 → 点
                    double cx = (bb.origin.x + bb.size.width / 2) * b.w / ptScale;
                    double cy = (1 - bb.origin.y - bb.size.height / 2) * b.h / ptScale;
                    [hits addObject:@[@(cx), @(cy)]];
                }
            }
        }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
    NSError *err = nil;
    [handler performRequests:@[req] error:&err];
    CGImageRelease(img);

    lua_newtable(L);
    int n = 0;
    for (NSArray *pt in hits) {
        lua_newtable(L);
        NSNumber *x = pt.firstObject;
        NSNumber *y = pt.lastObject;
        // Minor 2 修复：与其余 API 统一 llround 四舍五入（intValue 直接截断会偏左上）
        lua_pushinteger(L, (lua_Integer)llround(x.doubleValue)); lua_rawseti(L, -2, 1);
        lua_pushinteger(L, (lua_Integer)llround(y.doubleValue)); lua_rawseti(L, -2, 2);
        lua_rawseti(L, -2, ++n);
    }
    if (n == 0) ATLog(@"findText: no match for %s", want);
    ATFreeBitmap(&b);
    return 1;
}

// MVP 未实现的 API：保留函数名，给出明确提示而非 nil 报错
static int l_notImplemented(lua_State *L) {
    luaL_traceback(L, L, "not implemented in ATLite v0.3.5 yet", 1);
    ATLog(@"[lua] API not implemented: %s", lua_tostring(L, -1));
    lua_pushnil(L);
    return 1;
}

static const luaL_Reg ATLuaFuncs[] = {
    {"touchDown", l_touchDown},
    {"touchMove", l_touchMove},
    {"touchUp",   l_touchUp},
    {"keyDown",   l_keyDown},
    {"keyUp",     l_keyUp},
    {"usleep",    l_usleep},
    {"msleep",    l_msleep},
    {"log",       l_log},
    {"screenWidth",  l_screenWidth},
    {"screenHeight", l_screenHeight},
    {"rootDir",   l_rootDir},
    {"stop",      l_stop},
    {"getColor",  l_getColor},
    {"findColor", l_findColor},
    {"findImage", l_findImage},
    {"findText",  l_findText},
    {"findColors",     l_notImplemented},
    {"ocrText",        l_notImplemented},
    {"appRun",         l_notImplemented},
    {"appKill",        l_notImplemented},
    {"vibrate",        l_notImplemented},
    {"openURL",        l_notImplemented},
    {"inputText",      l_notImplemented},
    {"toast",          l_notImplemented},
    {NULL, NULL},
};

// ---- Extensions.lua（R17：v2 版本标记 + 版本感知覆写）----
static NSString * const ATExtensionsLua = @R"(-- ATLite Extensions.lua v2 (AutoTouch API parity layer + humanized input)
print = log

-- Lua 5.3 math.random 默认种子固定 —— /dev/urandom 播种
do
    local f = io.open("/dev/urandom", "rb")
    local seeded = false
    if f then
        local s = f:read(8)
        f:close()
        if s and #s == 8 then
            local n = 0
            for i = 1, 8 do n = n * 256 + s:byte(i) end
            math.randomseed(n % 0x7fffffff)
            seeded = true
        end
    end
    if not seeded then math.randomseed(os.time()) end
end

KEY_TYPE = {
    HOME_BUTTON       = 0x40,
    VOLUME_UP_BUTTON  = 0xE9,
    VOLUME_DOWN_BUTTON= 0xEA,
    POWER_BUTTON      = 0x30,
}

ORIENTATION_TYPE = {
    UNKNOWN = 0,
    PORTRAIT = 1,
    PORTRAIT_UPSIDE_DOWN = 2,
    LANDSCAPE_LEFT = 3,
    LANDSCAPE_RIGHT = 4,
}

-- 真人按住 60-120ms（固定 16ms 是最典型的机器特征）
function tap(x, y)
    touchDown(0, x, y)
    usleep(math.random(60000, 120000))
    touchUp(0, x, y)
end

function exit()
    stop()
end

function rootPathOfDocuments()
    return rootDir()
end

-- 搜到就点（中心点），AutoTouch 同名习惯
function findColorTap(color, tolerance)
    local r = findColor(color, tolerance)
    if r and #r > 0 then tap(r[1][1], r[1][2]) end
    return r
end

function findImageTap(path, similarity)
    local r = findImage(path, similarity)
    if r and #r > 0 then tap(r[1][1], r[1][2]) end
    return r
end

function findTextTap(text)
    local r = findText(text)
    if r and #r > 0 then tap(r[1][1], r[1][2]) end
    return r
end

-- 模板图片目录（与电脑上传目录一致）
function imagePath(name)
    return rootDir():gsub("Scripts$", "") .. "Images/" .. name
end
)";

// 版本感知落地：缺失或版本过期时，旧文件备份 .bak 后覆写（R17）
static void ATEnsureLuaLibraries(void) {
    NSString *ext = [ATLibsDir() stringByAppendingPathComponent:@"Extensions.lua"];
    BOOL needsWrite = YES;
    if ([[NSFileManager defaultManager] fileExistsAtPath:ext]) {
        NSString *cur = [NSString stringWithContentsOfFile:ext encoding:NSUTF8StringEncoding error:nil];
        if (cur && [cur containsString:@"ATLite Extensions.lua v2"]) needsWrite = NO;
    }
    if (!needsWrite) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:ext]) {
        NSString *bak = [ext stringByAppendingString:@".bak"];
        [[NSFileManager defaultManager] removeItemAtPath:bak error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:ext toPath:bak error:nil];
        ATLog(@"Extensions.lua old version backed up to %@", bak);
    }
    [ATExtensionsLua writeToFile:ext atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ATLog(@"Extensions.lua v2 written to %@", ext);
}

// 执行：先跑 Extensions.lua（可被用户覆盖），再跑脚本本体
// ---------------------------------------------------------------------------
// E25-B：脚本执行时限。用户脚本跑在 SpringBoard 进程里，一个死循环脚本
// （while true do tap() end）会持续占用进程、不停合成事件，直接把系统拖到
// 打不开任何新程序。这里用 Lua 的 count hook 每 10 万条指令检查一次挂钟时间，
// 超时即中止脚本（不中止 SpringBoard）。
// ---------------------------------------------------------------------------
#define AT_SCRIPT_TIMEOUT_SEC 60
#define AT_SCRIPT_HOOK_COUNT  100000
static CFAbsoluteTime gScriptDeadline = 0.0;

// ---------------------------------------------------------------------------
// E26：强停兜底。
// 脚本跑在 SpringBoard 进程里，**把 App 从后台划掉对它毫无影响**（App 只是遥控器）。
// 所以停止必须是"脚本自己能看见"的信号，不能只依赖 App 存活或通知送达：
//   通道 1（快）：Darwin 通知 → gStopRequested 内存标志
//   通道 2（兜底）：<jbroot>/.../stop.flag 文件 —— 就算通知中心不工作、
//                   SpringBoard 主线程忙到不处理回调，脚本下次检查文件时也能停下
// 两条通道都在 hook（每 10 万指令）与 sleep 分片里被检查。
// ---------------------------------------------------------------------------
static volatile sig_atomic_t gStopRequested = 0;

static NSString *ATStopFlagPath(void) {
    return [ATBaseDir() stringByAppendingPathComponent:@"stop.flag"];
}
static NSString *ATStatusPath(void) {
    return [ATBaseDir() stringByAppendingPathComponent:@"status.json"];
}
static BOOL ATShouldStop(void) {
    if (gStopRequested) return YES;
    return [[NSFileManager defaultManager] fileExistsAtPath:ATStopFlagPath()];
}
static void ATClearStopFlag(void) {
    gStopRequested = 0;
    [[NSFileManager defaultManager] removeItemAtPath:ATStopFlagPath() error:nil];
}
static void ATWriteStatus(BOOL running, NSString *name) {
    NSDictionary *d = @{@"running": @(running),
                        @"script": name ?: @"",
                        @"time": @(CFAbsoluteTimeGetCurrent())};
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (j) [j writeToFile:ATStatusPath() atomically:YES];
}

static void ATLuaTimeoutHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    @autoreleasepool {
        // E26：停止优先于超时判定
        if (ATShouldStop()) luaL_error(L, "STOP");
        if (gScriptDeadline > 0 && CFAbsoluteTimeGetCurrent() > gScriptDeadline) {
            luaL_error(L, "ATLite: script exceeded %d s limit (aborted to protect SpringBoard)",
                       (int)AT_SCRIPT_TIMEOUT_SEC);
        }
    }
}

static void ATPlayLuaFile(NSString *scriptPath) {
    if (!gHIDReady) { ATLog(@"play aborted: HID not ready"); return; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptPath]) {
        ATLog(@"script not found: %@", scriptPath);
        return;
    }
    // E26：新脚本开跑前清掉上一次的停止标志（否则会被上一轮的 flag 立刻停掉）
    ATClearStopFlag();
    ATWriteStatus(YES, scriptPath.lastPathComponent);
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    // E25-B/E26：装上超时+停止钩子（在跑任何用户代码之前）
    gScriptDeadline = CFAbsoluteTimeGetCurrent() + AT_SCRIPT_TIMEOUT_SEC;
    lua_sethook(L, ATLuaTimeoutHook, LUA_MASKCOUNT, AT_SCRIPT_HOOK_COUNT);
    luaL_newlib(L, ATLuaFuncs);
    lua_setglobal(L, "at");
    // 复制到 _G 顶层: touchDown(...) 直接可用（AutoTouch 风格）
    lua_getglobal(L, "at");
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        lua_pushvalue(L, -1);
        lua_setglobal(L, lua_tostring(L, -2));
        lua_pop(L, 1);
    }
    lua_pop(L, 1);

    NSString *ext = [ATLibsDir() stringByAppendingPathComponent:@"Extensions.lua"];
    NSData *extData = [NSData dataWithContentsOfFile:ext];
    if (extData) {
        if (luaL_dostring(L, [[NSString alloc] initWithData:extData encoding:NSUTF8StringEncoding].UTF8String)) {
            ATLog(@"Extensions.lua error: %s", lua_tostring(L, -1));
        }
    }

    NSData *data = [NSData dataWithContentsOfFile:scriptPath];
    NSString *src = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    int err = luaL_dostring(L, src.UTF8String);
    if (err) {
        const char *msg = lua_tostring(L, -1);
        if (msg && strcmp(msg, "STOP") == 0) {
            ATLog(@"script stopped by stop(): %@", scriptPath.lastPathComponent);
        } else {
            ATLog(@"lua error: %s", msg ? msg : "?");
        }
    } else {
        ATLog(@"script finished: %@", scriptPath.lastPathComponent);
    }
    gScriptDeadline = 0; // E25-B：本次执行结束，解除时限
    ATWriteStatus(NO, scriptPath.lastPathComponent); // E26：状态回到空闲
    lua_close(L);
}

#pragma mark - Command handling (SpringBoard)

static BOOL ATIsSpringBoard(void) {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void ATHandleCommand(void) {
    NSString *cmdPath = [ATBaseDir() stringByAppendingPathComponent:@"command.json"];
    NSData *data = [NSData dataWithContentsOfFile:cmdPath];
    if (!data) return;
    NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![cmd isKindOfClass:[NSDictionary class]]) return;
    NSString *action = cmd[@"cmd"];
    NSString *script = cmd[@"script"] ?: @"";
    if (!action.length) return;
    ATLog(@"command: %@ (%@)", action, script);

    // E26：强停。不要求 ATIsSpringBoard —— 任何注入进程收到都先落内存标志，
    // 但要真正中止脚本只有 SpringBoard 里那个 hook 会读到它。
    if ([action isEqualToString:@"stop"]) {
        gStopRequested = 1;
        [[NSFileManager defaultManager] removeItemAtPath:ATStopFlagPath() error:nil];
        ATLog(@"stop requested (forced stop)");
        ATWriteStatus(NO, @"");
        return;
    }

    if ([action isEqualToString:@"run"]) {
        if (!ATIsSpringBoard()) return;
        NSString *n = [script.pathExtension.lowercaseString isEqualToString:@"at"]
            ? script : [script stringByAppendingPathExtension:@"at"];
        NSString *path = [ATScriptsDir() stringByAppendingPathComponent:n];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                // M2：用户脚本是不可信输入，运行链路任何异常都不许击穿到 SpringBoard
                @try { ATPlayLuaFile(path); }
                @catch (NSException *e) { ATLog(@"script exception: %@", e); }
            }
        });
    }
}

#pragma mark - Darwin notification

static void ATDarwinCallback(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    @autoreleasepool { ATHandleCommand(); }
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in @[ATBaseDir(), ATScriptsDir(), ATLibsDir(), ATImagesDir(), ATLogsDir()]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @0755} error:nil];
        }
        ATEnsureLuaLibraries();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        ATDarwinCallback, (__bridge CFStringRef)AT_DARWIN_NOTIFY,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        if (ATIsSpringBoard()) {
            ATLoadHIDSymbols();
            ATLoadCaptureSymbols();
        }
        ATLog(@"v0.3.5 loaded in %@ (sb=%d, jbroot=%@ via %@)",
              NSBundle.mainBundle.bundleIdentifier ?: @"?", ATIsSpringBoard(),
              ATJBRoot(), gJBRootSource ?: @"?");
    }
}
