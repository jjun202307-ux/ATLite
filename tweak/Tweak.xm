#import "../shared/ATLStopFile.h"
#import "../shared/ATLJBRootPath.h"
#import "../shared/ATLChildProcess.h"
#import "../shared/ATLOCRReply.h"
// ATLiteTweak v0.3.24 — AutoTouch-style script runner (Dopamine roothide only)
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
#import <mach/boolean.h>
#import <sys/stat.h>
#import <time.h>
#import <spawn.h>
#include <fcntl.h>
// R33-C：waitpid 的声明所在；缺失 = 隐式函数声明 = clang 14+ 硬错误（E27/R27 同类）
#include <sys/wait.h>
#import <math.h>
#import <stdlib.h>
#import <signal.h>
#import <string.h>
#import "ATCore.h"
#import "ATCaptureValidation.h"
#import "../shared/ATLEmailJob.h"
#import "../shared/ATLRegistrationJob.h"

#include <stdarg.h>
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
@property (nonatomic, readonly) NSString *string;
@property (nonatomic, readonly) float confidence;
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
            size_t prefixLength = ATLRootPrefixLengthForTweakPath(info.dli_fname);
            if (prefixLength) {
                root = [[NSString alloc] initWithBytes:info.dli_fname length:prefixLength encoding:NSUTF8StringEncoding];
                gJBRootSource = @"dladdr";
            }
        }
        NSString *ownRoot = root;
        root = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        typedef const char *(*ATGetJBRootPrefix)(void);
        ATGetJBRootPrefix getPrefix = (ATGetJBRootPrefix)dlsym(RTLD_DEFAULT, "libroot_get_jbroot_prefix");
        void *libroot = NULL;
        if (!getPrefix) {
            libroot = dlopen("@rpath/libroot.dylib", RTLD_NOW);
            if (!libroot && ownRoot.length)
                libroot = dlopen([[ownRoot stringByAppendingPathComponent:@"usr/lib/libroot.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
            if (libroot) getPrefix = (ATGetJBRootPrefix)dlsym(libroot, "libroot_get_jbroot_prefix");
        }
        if (getPrefix) {
            const char *prefix = getPrefix();
            NSString *candidate = prefix ? [NSString stringWithUTF8String:prefix] : nil;
            BOOL directory = NO;
            if (candidate.isAbsolutePath && [fm fileExistsAtPath:candidate isDirectory:&directory] && directory) {
                root = candidate; gJBRootSource = @"libroot";
            }
        }
        if (libroot) dlclose(libroot);
        if (root) return;
        BOOL ownDirectory = NO;
        if (ownRoot && [fm fileExistsAtPath:ownRoot isDirectory:&ownDirectory] && ownDirectory) {
            root = ownRoot; gJBRootSource = @"dladdr"; return;
        }
        // Dopamine-roothide 实证（DOBootstrapper.m）：/var/jb 是指向 jbroot 的 symlink；
        // jbroot 真实位置 /var/containers/Bundle/Application/.jbroot-<16hex>
        BOOL jbDirectory = NO;
        if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&jbDirectory] && jbDirectory) { root = @"/var/jb"; gJBRootSource = @"probe:/var/jb"; return; }
        gJBRootSource = @"unavailable";
    });
    return root;
}

static NSString *ATBaseDir(void)    { return [ATJBRoot() stringByAppendingString:@"/var/mobile/Library/ATLite"]; }
static NSString *ATScriptsDir(void) { return [ATBaseDir() stringByAppendingPathComponent:@"Scripts"]; }
static NSString *ATLibsDir(void)    { return [ATBaseDir() stringByAppendingPathComponent:@"LuaLibraries"]; }
static NSString *ATLogsDir(void)    { return [ATBaseDir() stringByAppendingPathComponent:@"logs"]; }
static NSString *ATImagesDir(void)  { return [ATBaseDir() stringByAppendingPathComponent:@"Images"]; }

// ---------------------------------------------------------------------------
// E26 强停（定义必须早于所有使用者：l_usleep/l_msleep 在下方、hook 在更下方。
// ⚠ E27 教训：C 是"先声明后使用"，把定义放在使用点之后 = 编译期 undeclared identifier。
//    静态断言必须检查**顺序**，不能只检查字符串是否存在。）
// ---------------------------------------------------------------------------
static NSString *ATStopFlagPath(void) {
    return [ATBaseDir() stringByAppendingPathComponent:@"stop.flag"];
}
static NSString *ATStatusPath(void) {
    return [ATBaseDir() stringByAppendingPathComponent:@"status.json"];
}
// Never clear the shared file: a stop may arrive after the run was submitted.
// The submitted snapshot identifies the last stop which predates that run.
static volatile uint32_t gStopGeneration = 0;
static uint32_t gRunStopGeneration = 0;
static id gRunStopSnapshot = nil; // base64 string or NSNull; nil means legacy
static BOOL ATMemoryStopRequested(void) {
    return __sync_fetch_and_add(&gStopGeneration, 0) != gRunStopGeneration;
}
static BOOL ATShouldStop(void) {
    if (ATMemoryStopRequested()) return YES;
    NSString *path = ATStopFlagPath();
    unsigned char bytes[256]; size_t length = 0;
    int result = ATLReadStopFile(path.fileSystemRepresentation, bytes, sizeof(bytes), &length);
    if (result < 0) return YES;
    if (!result) return NO;
    NSData *current = [NSData dataWithBytes:bytes length:length];
    if (!gRunStopSnapshot) return YES; // old clients: conservatively honor any flag
    if (gRunStopSnapshot == [NSNull null]) return YES;
    return ![[current base64EncodedStringWithOptions:0] isEqualToString:gRunStopSnapshot];
}
static void ATWriteStatus(BOOL running, NSString *name) {
    NSDictionary *d = @{@"running": @(running),
                        @"script": name ?: @"",
                        @"time": @(CFAbsoluteTimeGetCurrent())};
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (j) [j writeToFile:ATStatusPath() atomically:YES];
}

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

// ---------------------------------------------------------------------------
// 正在跑的脚本数 + 等待旧脚本退出（必须放在 ATLog 之后 —— C 先声明后使用，见 E27）
// 用于"停止后立刻跑新脚本"的场景：若不等旧脚本退干净就重置停止信号，
// 旧脚本会因为信号被清而**复活**（v0.3.6 debug 复查发现）。
// ---------------------------------------------------------------------------
static volatile int32_t gRunningScripts = 0;

// Monotonic wall budget shared only with the one admitted worker.
static double gScriptDeadline = 0;
static double ATMonotonicNow(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
static BOOL ATScriptExpired(void) {
    return gScriptDeadline > 0 && ATMonotonicNow() >= gScriptDeadline;
}
static void ATCheckScript(lua_State *L) {
    BOOL cancelled;
    @autoreleasepool { cancelled = ATShouldStop(); }
    if (cancelled) luaL_error(L, "STOP");
    if (ATScriptExpired()) luaL_error(L, "ATLite: execution deadline exceeded");
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
// WebKit PAL IOKitSPIIOS.h: the seventh argument is buttonMask, not options.
static IOHIDEventRef (*_AT_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, boolean_t, boolean_t, uint32_t);
// FingerEvent（13 参，E5 的教训——多一个 uint32 都会错位寄存器）:
//   allocator, ts, index, identity, eventMask, x, y, z, tipPressure, twist, range, touch, options
static IOHIDEventRef (*_AT_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, boolean_t, boolean_t, uint32_t);
static void (*_AT_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
// ⚠ E1：真实符号名以 ...Value 结尾；"IOHIDEventSetInteger" 不存在
static void (*_AT_IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex);
static void (*_AT_IOHIDEventSetFloatValue)(IOHIDEventRef, uint32_t, double);
// WebKit PAL IOKitSPIIOS.h: uint32_t usages and Darwin boolean_t.
static IOHIDEventRef (*_AT_IOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, uint32_t);

static IOHIDEventSystemClientRef gHIDClient = nil;
static BOOL gHIDReady = NO;
static uint64_t gTouchSenderID=0;
static void (*_AT_IOHIDEventSetSenderID)(IOHIDEventRef,uint64_t);
static CGSize ATScreenSize(void);

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
    ATSYM(_AT_IOHIDEventSetSenderID, "IOHIDEventSetSenderID");
    ATSYM(_AT_IOHIDEventCreateKeyboardEvent,        "IOHIDEventCreateKeyboardEvent");
#undef ATSYM
    if (!_AT_IOHIDEventSystemClientCreate || !_AT_IOHIDEventSystemClientDispatchEvent ||
        !_AT_IOHIDEventCreateDigitizerEvent || !_AT_IOHIDEventCreateDigitizerFingerEvent ||
        !_AT_IOHIDEventAppendEvent || !_AT_IOHIDEventSetIntegerValue ||
        !_AT_IOHIDEventSetFloatValue) {
        ATLog(@"IOHIDEvent symbols incomplete, touch sim disabled");
        return;
    }
    // Resolve the current device's digitizer identity; never reuse another phone's ID.
    CFMutableDictionaryRef (*matching)(const char *)=(CFMutableDictionaryRef (*)(const char *))dlsym(iokit,"IOServiceMatching");
    uint32_t (*getService)(uint32_t,CFDictionaryRef)=(uint32_t (*)(uint32_t,CFDictionaryRef))dlsym(iokit,"IOServiceGetMatchingService");
    int (*registryID)(uint32_t,uint64_t *)=(int (*)(uint32_t,uint64_t *))dlsym(iokit,"IORegistryEntryGetRegistryEntryID");
    int (*releaseService)(uint32_t)=(int (*)(uint32_t))dlsym(iokit,"IOObjectRelease");
    if(matching && getService && registryID && releaseService && _AT_IOHIDEventSetSenderID) {
        CFMutableDictionaryRef query=matching("AppleMultitouchDevice");
        uint32_t service=query?getService(0,query):0;
        if(service) { if(registryID(service,&gTouchSenderID))gTouchSenderID=0;releaseService(service); }
    }
    ATLog(@"digitizer sender=%llu",(unsigned long long)gTouchSenderID);
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
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    static uint64_t previous = 0; // serialized by the sole script worker
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    uint64_t half = ATNanosecondsToTicks(1000000, tb.numer, tb.denom);
    uint64_t now = mach_absolute_time();
    int64_t jitter = (half && half < INT32_MAX) ?
        (int64_t)arc4random_uniform((uint32_t)(half * 2)) - (int64_t)half : 0;
    uint64_t stamp = jitter < 0 && (uint64_t)(-jitter) > now ? now : now + jitter;
    if (stamp <= previous) stamp = previous + 1;
    previous = stamp;
    return stamp;
}

typedef struct { BOOL down; float x, y; } ATTouchState;
static ATTouchState gTouches[10];
static BOOL gKeys[65536];
static BOOL gASCIIKeys[256];

// action: 0=down 1=move 2=up
// 事件装配（R4）：与 SimulateTouch/KIF 逐参数一致（F42/F43）——
//   hand（父）：index=0 identity=0 x/y/z=0 压力=0 mask=Touch range=0 touch=true
//   finger（子）：index 从 1 起（finger+1）、identity=2、mask 动态、tipPressure=0
static void ATSimulateTouch(int action, int finger, float x, float y) {
    if (!gHIDReady || !gTouchSenderID || !_AT_IOHIDEventSetSenderID) return;
    if (finger < 0 || finger >= 10 || !isfinite(x) || !isfinite(y)) return;
    CGSize screen=ATScreenSize();
    if(screen.width<=0 || screen.height<=0) { ATLog(@"touch failed: screen size unavailable");return; }
    float originalX=x,originalY=y;
    ATThrottleEvents();
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

    double digitizerX=0,digitizerY=0;
    if(!ATPointToDigitizer(x,y,screen.width,screen.height,&digitizerX,&digitizerY))return;
    IOHIDEventRef hand = _AT_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand,
        0, 0, kIOHIDDigitizerEventTouch, 0,
        0, 0, 0, 0, 0, touching, touching, 0);
    IOHIDEventRef fg = _AT_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        (uint32_t)(finger + 1), 2, mask,
        digitizerX, digitizerY, 0, 0, 0, touching, touching, 0);
    if (!hand || !fg) { if (hand) CFRelease(hand); if (fg) CFRelease(fg); return; }
    _AT_IOHIDEventAppendEvent(hand, fg, 0);
    _AT_IOHIDEventSetIntegerValue(hand, AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _AT_IOHIDEventSetIntegerValue(fg,   AT_FIELD_IS_DISPLAY_INTEGRATED, 1);
    _AT_IOHIDEventSetFloatValue(fg, AT_FIELD_MAJOR_RADIUS, major);
    _AT_IOHIDEventSetFloatValue(fg, AT_FIELD_MINOR_RADIUS, minor);
    _AT_IOHIDEventSetSenderID(hand,gTouchSenderID);
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, hand);
    gTouches[finger] = (ATTouchState){ !isUp, originalX, originalY };
    CFRelease(hand);
    CFRelease(fg);
}

// keyDown/keyUp: consumer page (0x0C) 用法码，与 AutoTouch KEY_TYPE 一致
#define AT_HID_USAGE_PAGE_CONSUMER 0x0C
static void ATSimulateKey(BOOL down, int usage) {
    if (!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent) return;
    if (usage < 0 || usage > 65535) return;
    ATThrottleEvents();
    IOHIDEventRef ev = _AT_IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, ATTimestampNow(),
        AT_HID_USAGE_PAGE_CONSUMER, (uint16_t)usage, down ? TRUE : FALSE, 0);
    if (!ev) return;
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, ev);
    gKeys[usage] = down;
    CFRelease(ev);
}

static BOOL ATASCIIKeyEvent(BOOL down, uint16_t usage) {
    if (!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent || usage > 255) return NO;
    ATThrottleEvents();
    IOHIDEventRef event = _AT_IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
        ATTimestampNow(), 0x07, usage, down, 0);
    if (!event) return NO;
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, event);
    gASCIIKeys[usage] = down;
    CFRelease(event); return YES;
}

static void ATReleaseAllInputs(void) {
    for (int i=0; i<10; i++) if (gTouches[i].down)
        ATSimulateTouch(2, i, gTouches[i].x, gTouches[i].y);
    for (int i=0; i<65536; i++) if (gKeys[i]) ATSimulateKey(NO, i);
    for (int i=0; i<256; i++) if (gASCIIKeys[i]) ATASCIIKeyEvent(NO, (uint16_t)i);
}

#pragma mark - Screen capture (CARenderServer + IOSurface)

typedef struct CF_BRIDGED_TYPE(id) __IOSurface *IOSurfaceRef;
// E29（AutoTouch 实证对齐）：libATGraphic.iOS15.0.dylib 导入表只含
// _CARenderServerRenderDisplay —— 由调用方自建 IOSurface 传给 render server 写入，
// 而非让 render server 分配后返回（v0.3.6 及以前用的旧版抓取 API 无任何实证依据，
// 且是零文档内部接口，系统级 hang 最大嫌疑）。SO 实证用法：
//   surface = IOSurfaceCreate(props);            // 调用方自建、自控生命周期
//   CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
// Signature independently checked against ioscpy Capture.mm and RecordMyScreen.
// It returns void: reading the return register as kern_return_t produced false kr=1 failures.
static void (*_AT_CARenderServerRenderDisplay)(uint32_t, CFStringRef, IOSurfaceRef, uint32_t, uint32_t);
static IOSurfaceRef (*_AT_IOSurfaceCreate)(CFDictionaryRef);
static size_t (*_AT_IOSurfaceGetWidth)(IOSurfaceRef);
static size_t (*_AT_IOSurfaceGetHeight)(IOSurfaceRef);
static size_t (*_AT_IOSurfaceGetBytesPerRow)(IOSurfaceRef);
static uint32_t (*_AT_IOSurfaceGetPixelFormat)(IOSurfaceRef);
static void * (*_AT_IOSurfaceGetBaseAddress)(IOSurfaceRef);
// 渲染前后 Lock/Unlock（AutoTouch/SO 同模式；IOSurfaceCreate 必需，Lock/Unlock 可选）
static int32_t (*_AT_IOSurfaceLock)(IOSurfaceRef, uint32_t, uint32_t *);
static int32_t (*_AT_IOSurfaceUnlock)(IOSurfaceRef, uint32_t, uint32_t *);
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
    _AT_CARenderServerRenderDisplay = (typeof(_AT_CARenderServerRenderDisplay))dlsym(qc, "CARenderServerRenderDisplay");
    _AT_IOSurfaceCreate              = (typeof(_AT_IOSurfaceCreate))dlsym(ios, "IOSurfaceCreate");
    _AT_IOSurfaceGetWidth            = (typeof(_AT_IOSurfaceGetWidth))dlsym(ios, "IOSurfaceGetWidth");
    _AT_IOSurfaceGetHeight           = (typeof(_AT_IOSurfaceGetHeight))dlsym(ios, "IOSurfaceGetHeight");
    _AT_IOSurfaceGetBytesPerRow      = (typeof(_AT_IOSurfaceGetBytesPerRow))dlsym(ios, "IOSurfaceGetBytesPerRow");
    _AT_IOSurfaceGetPixelFormat      = (typeof(_AT_IOSurfaceGetPixelFormat))dlsym(ios, "IOSurfaceGetPixelFormat");
    _AT_IOSurfaceGetBaseAddress      = (typeof(_AT_IOSurfaceGetBaseAddress))dlsym(ios, "IOSurfaceGetBaseAddress");
    _AT_IOSurfaceLock                = (typeof(_AT_IOSurfaceLock))dlsym(ios, "IOSurfaceLock");
    _AT_IOSurfaceUnlock              = (typeof(_AT_IOSurfaceUnlock))dlsym(ios, "IOSurfaceUnlock");
    if (!_AT_CARenderServerRenderDisplay || !_AT_IOSurfaceCreate ||
        !_AT_IOSurfaceGetWidth || !_AT_IOSurfaceGetHeight || !_AT_IOSurfaceGetBytesPerRow ||
        !_AT_IOSurfaceGetPixelFormat || !_AT_IOSurfaceGetBaseAddress ||
        !_AT_IOSurfaceLock || !_AT_IOSurfaceUnlock) {
        ATLog(@"CARenderServer/IOSurface symbols incomplete, capture disabled");
        return;
    }
    gCaptureReady = YES;
    ATLog(@"capture symbols ready (frame capture not yet verified)");
}

// E30（v0.3.7 复查 H1/H2）：自建 IOSurface 需要物理像素尺寸，但取法有两条铁律——
// ① 不得一次性缓存：设备旋转后 bounds 宽高互换，缓存过期会让搜图坐标全错（H2）。
//    故每次抓屏都重新取。
// ② 跨线程等待必须带超时（E25 同原则）：UIScreen 只能主线程碰，若主线程卡死，
//    无超时的 dispatch_sync 会让脚本线程在渲染之前就永久卡死——Lua 指令计数钩子
//    和强停在线程堵于 C 层时都不触发（H1）。故用 semaphore 限时等待，超时返回
//    零尺寸：抓屏失败、脚本拿到 nil，但线程绝不滞留。
#define AT_SCREEN_SIZE_TIMEOUT_SEC 1.5
static CGSize ATScreenPixelSize(void) {
    CGSize (^measure)(void) = ^{
        UIScreen *s = UIScreen.mainScreen;
        return CGSizeMake(s.bounds.size.width * s.nativeScale,
                          s.bounds.size.height * s.nativeScale);
    };
    if ([NSThread isMainThread]) return measure();
    __block CGSize px = {0, 0};
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        px = measure();
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(AT_SCREEN_SIZE_TIMEOUT_SEC * NSEC_PER_SEC))) != 0) {
        ATLog(@"main thread unresponsive >%.1fs — screen size unavailable this frame",
              AT_SCREEN_SIZE_TIMEOUT_SEC);
        return CGSizeMake(0, 0);
    }
    return px;
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
// E25-A：抓屏看门狗（E29 后保留作纵深防御）。
// RenderDisplay 仍是到 render server 的**同步 IPC**。一旦 render server
// 与 SpringBoard 互相等待，这个调用永不返回 —— 而脚本跑在 SpringBoard 进程里，
// 表现就是"整个系统打不开新程序，只能重启"。
// 对策：把渲染挪到专用串行队列，调用方只等有限时间（1.5s）。超时即认定渲染链路
// 已挂，本进程内**永久停用抓屏**并记日志 —— 宁可功能失效，也不拖垮系统。
// E29：API 已对齐 AutoTouch 实证（_CARenderServerRenderDisplay，调用方自建
// IOSurface），看门狗从"止血"降级为"保险丝"，正常路径不应再触发。
// ---------------------------------------------------------------------------
#define AT_CAPTURE_TIMEOUT_SEC 1.5
static dispatch_queue_t gCaptureQueue = NULL;
static BOOL gCaptureBroken = NO;

// 在抓屏队列上执行：自建 IOSurface → RenderDisplay 写入。返回 NULL = 失败。
// 属性键为 IOSurface 公开文档字符串值；像素格式固定 'ARGB'（SO 实证配方）。
static IOSurfaceRef ATRenderIntoNewSurface(CGSize px) {
    int w = (int)px.width, h = (int)px.height;
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192 || (size_t)w * h > 16777216) {
        ATLog(@"screen pixel size invalid or too large: %dx%d", w, h); return NULL;
    }
    int bpe = 4, pitch = w * 4, alloc = pitch * h;
    int argb = 0x42475241; // 'BGRA': byte order B,G,R,A, as used by current capture implementations.
    CFTypeRef keys[7] = {
        CFSTR("IOSurfaceIsGlobal"), CFSTR("IOSurfaceBytesPerElement"),
        CFSTR("IOSurfaceBytesPerRow"), CFSTR("IOSurfaceWidth"),
        CFSTR("IOSurfaceHeight"), CFSTR("IOSurfacePixelFormat"),
        CFSTR("IOSurfaceAllocSize"),
    };
    CFNumberRef nBpe   = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpe);
    CFNumberRef nPitch = CFNumberCreate(NULL, kCFNumberSInt32Type, &pitch);
    CFNumberRef nW     = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
    CFNumberRef nH     = CFNumberCreate(NULL, kCFNumberSInt32Type, &h);
    CFNumberRef nFmt   = CFNumberCreate(NULL, kCFNumberSInt32Type, &argb);
    CFNumberRef nAlloc = CFNumberCreate(NULL, kCFNumberSInt32Type, &alloc);
    if (!nBpe || !nPitch || !nW || !nH || !nFmt || !nAlloc) {
        CFNumberRef values[] = {nBpe, nPitch, nW, nH, nFmt, nAlloc};
        for (CFNumberRef value : values) if (value) CFRelease(value);
        ATLog(@"capture: surface property allocation failed"); return NULL;
    }
    CFTypeRef vals[7] = { kCFBooleanTrue, nBpe, nPitch, nW, nH, nFmt, nAlloc };
    CFDictionaryRef props = CFDictionaryCreate(NULL, keys, vals, 7,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (nBpe)   CFRelease(nBpe);   if (nPitch) CFRelease(nPitch);
    if (nW)     CFRelease(nW);     if (nH)     CFRelease(nH);
    if (nFmt)   CFRelease(nFmt);   if (nAlloc) CFRelease(nAlloc);
    if (!props) return NULL;
    IOSurfaceRef s = _AT_IOSurfaceCreate(props);
    CFRelease(props);
    if (!s) { ATLog(@"IOSurfaceCreate failed"); return NULL; }
    if (!_AT_IOSurfaceLock || !_AT_IOSurfaceUnlock || _AT_IOSurfaceLock(s, 0, NULL) != 0) {
        CFRelease(s); ATLog(@"capture: surface write lock failed"); return NULL;
    }
    uint8_t *initial = (uint8_t *)_AT_IOSurfaceGetBaseAddress(s);
    size_t surfacePitch = _AT_IOSurfaceGetBytesPerRow(s);
    if (!initial || surfacePitch < (size_t)w * 4 || surfacePitch > (size_t)w * 4 + 65536) {
        _AT_IOSurfaceUnlock(s, 0, NULL); CFRelease(s); return NULL;
    }
    memset(initial, 0xa5, surfacePitch * (size_t)h);
    int32_t unlockRC = _AT_IOSurfaceUnlock(s, 0, NULL);
    if (unlockRC != 0) { ATLog(@"capture: surface write unlock=%d", unlockRC); CFRelease(s); return NULL; }
    _AT_CARenderServerRenderDisplay(0, CFSTR("LCD"), s, 0, 0);
    uint32_t seed = 0;
    int32_t lockRC = _AT_IOSurfaceLock(s, 1 /* ReadOnly, synchronize renderer writes */, &seed);
    if (lockRC != 0) { ATLog(@"capture: surface read lock=%d", lockRC); CFRelease(s); return NULL; }
    BOOL written = ATCaptureWasWritten((const uint8_t *)_AT_IOSurfaceGetBaseAddress(s),
                                      (size_t)w, (size_t)h, surfacePitch);
    unlockRC = _AT_IOSurfaceUnlock(s, 1, &seed);
    if (!written || unlockRC != 0) {
        ATLog(@"capture: renderer left destination untouched or unlock failed (%d); no frame", unlockRC);
        CFRelease(s); return NULL;
    }
    static BOOL loggedFrame = NO; // confined to gCaptureQueue
    if (!loggedFrame) { ATLog(@"capture: first written frame %dx%d BGRA (visual correctness requires device check)", w, h); loggedFrame = YES; }
    return s;
}

static IOSurfaceRef ATCaptureSurfaceWithTimeout(void) {
    static dispatch_once_t once;
    static NSObject *captureGate;
    dispatch_once(&once, ^{ gCaptureQueue = dispatch_queue_create("me.atlite.capture", DISPATCH_QUEUE_SERIAL); captureGate = [NSObject new]; });
    @synchronized (captureGate) { if (gCaptureBroken) return NULL; }
    // A main-thread sizing timeout is a missed frame, not a renderer hang.
    CGSize px = ATScreenPixelSize();
    if (px.width <= 0 || px.height <= 0) return NULL;
    __block IOSurfaceRef result = NULL;
    __block BOOL abandoned = NO;
    NSObject *gate = [NSObject new];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(gCaptureQueue, ^{
        @autoreleasepool {
            IOSurfaceRef surface = ATRenderIntoNewSurface(px);
            @synchronized (gate) {
                if (abandoned) { if (surface) CFRelease(surface); }
                else result = surface;
            }
            dispatch_semaphore_signal(sem);
        }
    });
    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                    (int64_t)(AT_CAPTURE_TIMEOUT_SEC * NSEC_PER_SEC)));
    @synchronized (gate) {
        if (r != 0) {
            abandoned = YES;
            if (result) { CFRelease(result); result = NULL; }
            @synchronized (captureGate) { gCaptureBroken = YES; }
            ATLog(@"capture hung >1.5s — disabled for this session; engine isolation still required");
            return NULL;
        }
        return result;
    }
}

// 抓主屏 → RGBA8（仅 SpringBoard 进程可用）
static BOOL ATCaptureScreen(ATBitmap *out) {
    if (!gCaptureReady) return NO;
    IOSurfaceRef s = ATCaptureSurfaceWithTimeout();
    if (!s) return NO;
    uint32_t seed = 0;
    if (!_AT_IOSurfaceLock || !_AT_IOSurfaceUnlock ||
        _AT_IOSurfaceLock(s, 1 /* ReadOnly */, &seed) != 0) { CFRelease(s); return NO; }
    int w = (int)_AT_IOSurfaceGetWidth(s);
    int h = (int)_AT_IOSurfaceGetHeight(s);
    size_t pitch = _AT_IOSurfaceGetBytesPerRow(s);
    uint32_t fmt = _AT_IOSurfaceGetPixelFormat(s); // 'BGRA' 或 'ARGB'
    uint8_t *base = (uint8_t *)_AT_IOSurfaceGetBaseAddress(s);
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192 ||
        (size_t)w * h > 16777216 || !base || pitch < (size_t)w * 4 ||
        (fmt != 0x41524742u && fmt != 0x42475241u)) {
        if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, &seed);
        CFRelease(s); return NO;
    }
    out->w = w; out->h = h;
    out->rgba = (uint8_t *)malloc((size_t)w * h * 4);
    if (!out->rgba) {
        if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, &seed);
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
            dst[x*4+3] = 255;
        }
    }
    if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, &seed);
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

static BOOL ATRGBAToGrayRegion(const ATBitmap *src, ATGray *dst, int x0, int y0, int w, int h) {
    if (!src || !src->rgba || x0<0 || y0<0 || w<=0 || h<=0 || x0>src->w-w || y0>src->h-h) return NO;
    dst->w=w; dst->h=h; dst->g=(uint8_t *)malloc((size_t)w*h);
    if (!dst->g) return NO;
    for (int y=0; y<h; y++) {
        const uint8_t *row=src->rgba + ((size_t)(y0+y)*src->w+x0)*4;
        uint8_t *out=dst->g+(size_t)y*w;
        for (int x=0; x<w; x++) out[x]=ATLuma(row+x*4);
    }
    return YES;
}

typedef struct { double deadline; BOOL interrupted; unsigned checks; } ATSearchContext;
static int ATSearchCancelled(void *opaque) {
    ATSearchContext *context = (ATSearchContext *)opaque;
    BOOL cancelled = ATMemoryStopRequested();
    if ((context->checks++ & 63u) == 0) {
        @autoreleasepool { cancelled = ATShouldStop(); }
    }
    if (cancelled || ATScriptExpired() || ATMonotonicNow() >= context->deadline) {
        context->interrupted = YES;
        return 1;
    }
    return 0;
}
static BOOL ATNCCBest(const ATGray *hay, const ATGray *needle, double minScore,
                      int *outX, int *outY, double *outScore, ATSearchContext *context) {
    return ATCoreNCCBest(hay->g, hay->w, hay->h, needle->g, needle->w, needle->h,
                        minScore, outX, outY, outScore, ATSearchCancelled, context) == 1;
}
static BOOL ATFindImageInScreen(const ATGray *screenFull, const ATBitmap *tmplRGBA,
                                double similarity, int *outX, int *outY, double *outScore,
                                BOOL *interrupted) {
    ATGray templateGray = {0};
    if (!ATRGBAToGray(tmplRGBA, &templateGray)) return NO;
    ATSearchContext context = { ATMonotonicNow() + 2.0, NO, 0 };
    BOOL found = ATNCCBest(screenFull, &templateGray, similarity, outX, outY, outScore, &context);
    *interrupted = context.interrupted;
    ATFreeGray(&templateGray);
    return found;
}

// 模板 PNG/JPG → RGBA（路径白名单校验，防目录穿越）
static BOOL ATLoadTemplate(const char *nameUtf8, ATBitmap *out) {
    NSString *name = [NSString stringWithUTF8String:nameUtf8];
    if (!name.length || name.length > 1024 || [name containsString:@"\\"] ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    NSString *ext = name.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"png"] && ![ext isEqualToString:@"jpg"] &&
        ![ext isEqualToString:@"jpeg"]) return NO;
    NSString *root = ATImagesDir().stringByResolvingSymlinksInPath;
    NSString *path = ([name isAbsolutePath] ? name : [root stringByAppendingPathComponent:name]);
    path = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (![path hasPrefix:[root stringByAppendingString:@"/"]]) return NO;
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
    if ([NSThread isMainThread]) return UIScreen.mainScreen.bounds.size;
    __block CGSize size = CGSizeZero;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        size = UIScreen.mainScreen.bounds.size;
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC))) return CGSizeZero;
    return size;
}

// RESEARCH C3：位图像素宽 / 屏幕点宽 = 缩放（1x 设备为 1，无损害）
static double ATCaptureScale(const ATBitmap *b) {
    CGSize pts = ATScreenSize();
    if (pts.width <= 0 || b->w <= 0) return 1.0;
    double s = (double)b->w / pts.width;
    return s > 0 ? s : 1.0;
}

static int l_touchDown(lua_State *L) {
    ATCheckScript(L);
    ATSimulateTouch(0, (int)luaL_checkinteger(L,1), (float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3));
    return 0;
}
static int l_touchMove(lua_State *L) {
    ATCheckScript(L);
    ATSimulateTouch(1, (int)luaL_checkinteger(L,1), (float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3));
    return 0;
}
static int l_touchUp(lua_State *L) {
    ATCheckScript(L);
    ATSimulateTouch(2, (int)luaL_checkinteger(L,1), (float)luaL_checknumber(L,2), (float)luaL_checknumber(L,3));
    return 0;
}
static int l_keyDown(lua_State *L) {
    ATCheckScript(L);
    ATSimulateKey(YES, (int)luaL_checkinteger(L,1)); return 0;
}
static int l_keyUp(lua_State *L) {
    ATCheckScript(L);
    ATSimulateKey(NO, (int)luaL_checkinteger(L,1)); return 0;
}
// AutoTouch 语义: usleep(微秒)
static int l_usleep(lua_State *L) {
    double us = luaL_checknumber(L,1);
    if (!isfinite(us) || us < 0) return luaL_error(L, "usleep: expected finite nonnegative duration");
    // E26：分片睡眠（每片 ≤50ms 检查一次停止）。
    // 否则 usleep(5秒) 期间点停止要等满 5 秒才生效，用户会以为停不掉。
    double left = us;
    while (left > 0) {
        double slice = left > 50000.0 ? 50000.0 : left;
        struct timespec req;
        req.tv_sec = 0;
        req.tv_nsec = (long)(slice * 1000.0);
        nanosleep(&req, NULL);
        ATCheckScript(L);
        if (ATScriptExpired()) return luaL_error(L, "ATLite: execution deadline exceeded");
        left -= slice;
    }
    return 0;
}
// ATLite 扩展: msleep(毫秒)
static int l_msleep(lua_State *L) {
    double ms = luaL_checknumber(L,1);
    if (!isfinite(ms) || ms < 0) return luaL_error(L, "msleep: expected finite nonnegative duration");
    // E26：同 l_usleep，分片检查停止
    double left = ms;
    while (left > 0) {
        double slice = left > 50.0 ? 50.0 : left;
        struct timespec req;
        req.tv_sec = 0;
        req.tv_nsec = (long)(slice * 1000000.0);
        nanosleep(&req, NULL);
        ATCheckScript(L);
        if (ATScriptExpired()) return luaL_error(L, "ATLite: execution deadline exceeded");
        left -= slice;
    }
    return 0;
}
static int l_log(lua_State *L) {
    int n = lua_gettop(L);
    NSMutableString *s = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        size_t length = 0;
        const char *v = lua_tolstring(L, i, &length);
        NSString *piece = v ? [[NSString alloc] initWithBytes:v length:length encoding:NSUTF8StringEncoding]
                            : [NSString stringWithUTF8String:lua_typename(L, lua_type(L, i))];
        [s appendString:piece ?: @"[invalid UTF-8]"];
        if (i < n) [s appendString:@" "];
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
    // Persist cancellation so the enclosing guarded pcall/xpcall cannot swallow it.
    __sync_fetch_and_add(&gStopGeneration, 1);
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
    double points[10][2];
    int n = 0;
    for (int y=0; y<sh && n<10; y++) {
        if (ATShouldStop() || ATScriptExpired()) { ATFreeBitmap(&b); ATCheckScript(L); }
        for (int x=0; x<sw && n<10; x++) {
            const uint8_t *px = b.rgba + ((size_t)(y*scanScale)*b.w+x*scanScale)*4;
            if (abs(px[0]-(int)cr)<=tol && abs(px[1]-(int)cg)<=tol && abs(px[2]-(int)cb)<=tol) {
                points[n][0] = llround(x*scanScale/ptScale);
                points[n][1] = llround(y*scanScale/ptScale); n++;
            }
        }
    }
    ATFreeBitmap(&b);
    lua_newtable(L);
    for (int i=0; i<n; i++) {
        lua_createtable(L,2,0);
        lua_pushinteger(L,(lua_Integer)points[i][0]); lua_rawseti(L,-2,1);
        lua_pushinteger(L,(lua_Integer)points[i][1]); lua_rawseti(L,-2,2);
        lua_rawseti(L,-2,i+1);
    }
    return 1;
}

// findImage("button.png"[, similarity[, {x,y,width,height}]]) → { {x, y, score}, ... }（点坐标）
static int l_findImage(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    double sim = lua_isnumber(L, 2) ? lua_tonumber(L, 2) : 0.9;
    if (!isfinite(sim) || sim < 0 || sim > 1) return luaL_error(L, "findImage: similarity must be finite in [0,1]");
    BOOL hasRegion = !lua_isnoneornil(L,3);
    double region[4] = {0};
    if (hasRegion) {
        luaL_checktype(L,3,LUA_TTABLE);
        const char *names[4]={"x","y","width","height"};
        for (int i=0;i<4;i++) { lua_getfield(L,3,names[i]);region[i]=luaL_checknumber(L,-1);lua_pop(L,1); }
    }
    ATBitmap tmpl = {0};
    if (!ATLoadTemplate(name, &tmpl)) { ATLog(@"findImage: template not found: %s", name); lua_pushnil(L); return 1; }
    ATBitmap screen = {0};
    if (!ATCaptureScreen(&screen)) { ATFreeBitmap(&tmpl); lua_pushnil(L); return 1; }
    double ptScale = ATCaptureScale(&screen); // 释放前取（像素→点）
    int originX=0,originY=0,regionW=screen.w,regionH=screen.h;
    if (hasRegion && !ATCorePointRegion(region[0],region[1],region[2],region[3],ptScale,
                                        screen.w,screen.h,&originX,&originY,&regionW,&regionH)) {
        ATFreeBitmap(&screen); ATFreeBitmap(&tmpl);
        return luaL_error(L,"findImage: region must fit the screen and have positive size");
    }
    ATGray screenGray = {0};
    BOOL haveGray = hasRegion ? ATRGBAToGrayRegion(&screen,&screenGray,originX,originY,regionW,regionH)
                              : ATRGBAToGray(&screen, &screenGray);
    ATFreeBitmap(&screen);
    if (!haveGray) { ATFreeBitmap(&tmpl); lua_pushnil(L); return 1; }

    int x = 0, y = 0; double score = 0;
    BOOL interrupted = NO;
    BOOL found = ATFindImageInScreen(&screenGray, &tmpl, sim, &x, &y, &score, &interrupted);
    double centerX = (originX + x + tmpl.w / 2.0) / ptScale;
    double centerY = (originY + y + tmpl.h / 2.0) / ptScale;
    ATFreeGray(&screenGray);
    ATFreeBitmap(&tmpl);
    ATCheckScript(L);
    if (interrupted) return luaL_error(L, "findImage: search exceeded 2s computation budget");
    lua_newtable(L);
    if (found) {
        lua_createtable(L,3,0);
        lua_pushinteger(L,(lua_Integer)llround(centerX)); lua_rawseti(L,-2,1);
        lua_pushinteger(L,(lua_Integer)llround(centerY)); lua_rawseti(L,-2,2);
        lua_pushnumber(L,score); lua_rawseti(L,-2,3);
        lua_rawseti(L,-2,1);
    }
    return 1;
}

// OCR results are staged in fixed native storage. No native bitmap survives Lua allocation.
static BOOL gOCRWorkerBroken=NO;
static int ATLOCRCancelled(void *context) {
    (void)context;
    return ATShouldStop() || ATScriptExpired();
}
static BOOL ATRecognizeScreen(ATTextResult *out) {
    if (gOCRWorkerBroken) { ATLog(@"OCR disabled after unconfirmed child reap; respring required");return NO; }
    ATBitmap bitmap={0};CGImageRef image=NULL;CGImageDestinationRef destination=NULL;
    int inputFD=-1;BOOL ok=NO;
    @try {
        @autoreleasepool {
            if (!ATCaptureScreen(&bitmap)) return NO;
            image=ATCreateCGImageFromBitmap(&bitmap);
            if (!image) return NO;
            double scale=ATCaptureScale(&bitmap);
            NSMutableData *png=[NSMutableData data];
            destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
            if (!destination) return NO;
            CGImageDestinationAddImage(destination,image,NULL);
            if (!CGImageDestinationFinalize(destination) || !png.length || png.length>ATL_OCR_INPUT_LIMIT) {
                ATLog(@"OCR input PNG serialization failed or exceeded limit");return NO;
            }
            NSString *pattern=[ATBaseDir() stringByAppendingPathComponent:@"ocr-input-XXXXXX"];
            char *temporary=strdup(pattern.fileSystemRepresentation);
            if (!temporary) return NO;
            inputFD=mkstemp(temporary);
            if (inputFD>=0 && unlink(temporary)) { close(inputFD);inputFD=-1; }
            free(temporary);
            if (inputFD<0) { ATLog(@"OCR temporary input failed errno=%d",errno);return NO; }
            if (fcntl(inputFD,F_SETFD,FD_CLOEXEC)<0) return NO;
            NSUInteger written=0;
            while (written<png.length) {
                if (ATLOCRCancelled(NULL)) return NO;
                ssize_t n=write(inputFD,(const char *)png.bytes+written,png.length-written);
                if (n<0 && errno==EINTR) continue;
                if (n<=0) return NO;
                written+=(NSUInteger)n;
            }
            if (lseek(inputFD,0,SEEK_SET)<0) return NO;
            NSString *requestID=NSUUID.UUID.UUIDString;
            NSString *exe=[ATJBRoot() stringByAppendingPathComponent:@"Applications/ATLite.app/ATLOCRWorker"];
            NSMutableData *output=[NSMutableData dataWithLength:ATL_OCR_OUTPUT_LIMIT];
            ATLChildResult child=ATLRunChild(exe.fileSystemRepresentation,requestID.UTF8String,inputFD,
                (char *)output.mutableBytes,output.length,ATL_OCR_TIMEOUT,ATLOCRCancelled,NULL);
            if (child.status!=ATL_CHILD_OK) {
                if (child.status==ATL_CHILD_REAP_FAILED) gOCRWorkerBroken=YES;
                ATLog(@"OCR request=%@ process failed status=%d errno=%d reaped=%d exit=%d signal=%d",requestID,child.status,child.systemError,child.reaped,child.exitCode,child.signal);
                return NO;
            }
            output.length=child.length;
            NSString *error=nil;
            ok=ATLDecodeOCRReply(output,requestID,bitmap.w,bitmap.h,scale,out,&error);
            if (!ok) ATLog(@"OCR request=%@ failed: %@",requestID,error);
        }
    } @finally {
        if (inputFD>=0) close(inputFD);
        if (destination) CFRelease(destination);
        if (image) CGImageRelease(image);
        ATFreeBitmap(&bitmap);
    }
    return ok;
}
static int l_findText(lua_State *L) {
    const char *want = luaL_checkstring(L,1);
    BOOL valid = NO;
    @autoreleasepool { valid = [NSString stringWithUTF8String:want].length > 0; }
    if (!valid) return luaL_error(L,"findText: expected nonempty UTF-8 text");
    ATTextResult hits = {0};
    if (!ATRecognizeScreen(&hits)) return luaL_error(L,"findText: screen capture or OCR unavailable");
    ATCheckScript(L);
    lua_newtable(L); int count=0;
    for (int i=0; i<hits.count; i++) if (strstr(hits.lines[i].text,want)) {
        lua_createtable(L,2,0);
        lua_pushinteger(L,(lua_Integer)llround(hits.lines[i].x+hits.lines[i].width/2)); lua_rawseti(L,-2,1);
        lua_pushinteger(L,(lua_Integer)llround(hits.lines[i].y+hits.lines[i].height/2)); lua_rawseti(L,-2,2);
        lua_rawseti(L,-2,++count);
    }
    return 1;
}
static int l_ocrText(lua_State *L) {
    ATTextResult hits = {0};
    if (!ATRecognizeScreen(&hits)) return luaL_error(L,"ocrText: screen capture or OCR unavailable");
    ATCheckScript(L);
    lua_createtable(L,hits.count,0);
    for (int i=0; i<hits.count; i++) {
        ATTextLine *line=&hits.lines[i];
        lua_createtable(L,0,6);
        lua_pushstring(L,line->text); lua_setfield(L,-2,"text");
        lua_pushnumber(L,line->x); lua_setfield(L,-2,"x");
        lua_pushnumber(L,line->y); lua_setfield(L,-2,"y");
        lua_pushnumber(L,line->width); lua_setfield(L,-2,"width");
        lua_pushnumber(L,line->height); lua_setfield(L,-2,"height");
        lua_pushnumber(L,line->confidence); lua_setfield(L,-2,"confidence");
        lua_rawseti(L,-2,i+1);
    }
    return 1;
}
static int l_inputText(lua_State *L) {
    size_t length=0; const unsigned char *text=(const unsigned char *)luaL_checklstring(L,1,&length);
    if (!length || length>254) return luaL_error(L,"inputText: expected 1..254 printable ASCII bytes");
    uint16_t usages[254]; int shifts[254];
    for (size_t i=0; i<length; i++) if (!ATASCIIKey(text[i],&usages[i],&shifts[i]))
        return luaL_error(L,"inputText: this lightweight build supports printable ASCII email text only");
    if (!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent) return luaL_error(L,"inputText: HID keyboard unavailable");
    for (size_t i=0; i<length; i++) {
        ATCheckScript(L);
        BOOL ok=(!shifts[i] || ATASCIIKeyEvent(YES,0xe1));
        if (ok) ok=ATASCIIKeyEvent(YES,usages[i]);
        if (ok) ok=ATASCIIKeyEvent(NO,usages[i]);
        if (shifts[i]) ok=ATASCIIKeyEvent(NO,0xe1) && ok;
        if (!ok) return luaL_error(L,"inputText: event creation failed");
    }
    lua_pushboolean(L,1); return 1; // dispatched, not a guarantee that a field had focus
}
static char gRegistrationID[81], gRegistrationPassword[255], gRegistrationCode[7];
static void ATClearRegistrationSecret(void) {
    volatile unsigned char *p=(volatile unsigned char *)gRegistrationPassword;
    for(size_t i=0;i<sizeof(gRegistrationPassword);i++) p[i]=0;
}
static void ATClearRegistrationCode(void) {
    volatile unsigned char *p=(volatile unsigned char *)gRegistrationCode;
    for(size_t i=0;i<sizeof(gRegistrationCode);i++) p[i]=0;
}
static NSString *ATRegistrationDir(void) {
    NSString *base=ATBaseDir();return base.length ? [base stringByAppendingPathComponent:@"Registration"] : nil;
}
static int l_getRegistrationJob(lua_State *L) {
    if(gRegistrationID[0]) return luaL_error(L,"registration job already claimed");
    char identifier[81]={0},email[255]={0},username[65]={0},fullName[101]={0},zip[6]={0};
    BOOL found=NO;ATClearRegistrationSecret();
    @autoreleasepool {
        NSError *error=nil;NSDictionary *job=ATLRegistrationClaimPending(ATRegistrationDir(),&error);
        if(job) {
            BOOL idOK=[job[@"id"] getCString:identifier maxLength:sizeof(identifier) encoding:NSUTF8StringEncoding];
            if(idOK) strlcpy(gRegistrationID,identifier,sizeof(gRegistrationID));
            found=idOK && [job[@"email"] getCString:email maxLength:sizeof(email) encoding:NSUTF8StringEncoding] &&
                  [job[@"username"] getCString:username maxLength:sizeof(username) encoding:NSUTF8StringEncoding] &&
                  [job[@"fullName"] getCString:fullName maxLength:sizeof(fullName) encoding:NSUTF8StringEncoding] &&
                  [job[@"zip"] getCString:zip maxLength:sizeof(zip) encoding:NSUTF8StringEncoding] &&
                  [job[@"password"] getCString:gRegistrationPassword maxLength:sizeof(gRegistrationPassword) encoding:NSUTF8StringEncoding];
        }
    }
    if(!found) { ATClearRegistrationSecret();if(gRegistrationID[0])return luaL_error(L,"registration job could not be loaded safely");lua_pushnil(L);return 1; }
    lua_createtable(L,0,5);
    lua_pushstring(L,identifier);lua_setfield(L,-2,"jobId");
    lua_pushstring(L,email);lua_setfield(L,-2,"email");
    lua_pushstring(L,username);lua_setfield(L,-2,"username");
    lua_pushstring(L,fullName);lua_setfield(L,-2,"fullName");
    lua_pushstring(L,zip);lua_setfield(L,-2,"zip");
    return 1;
}
static int l_inputRegistrationPassword(lua_State *L) {
    if(!gRegistrationID[0] || !gRegistrationPassword[0]) return luaL_error(L,"registration password unavailable or already used");
    if(!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent) {ATClearRegistrationSecret();return luaL_error(L,"keyboard unavailable");}
    size_t length=strlen(gRegistrationPassword);
    for(size_t i=0;i<length;i++) {
        uint16_t usage=0;int shift=0;ATCheckScript(L);
        if(!ATASCIIKey((unsigned char)gRegistrationPassword[i],&usage,&shift)) {ATClearRegistrationSecret();return luaL_error(L,"registration password unsupported");}
        BOOL ok=(!shift || ATASCIIKeyEvent(YES,0xe1));
        if(ok)ok=ATASCIIKeyEvent(YES,usage);if(ok)ok=ATASCIIKeyEvent(NO,usage);
        if(shift)ok=ATASCIIKeyEvent(NO,0xe1) && ok;
        if(!ok){ATClearRegistrationSecret();return luaL_error(L,"keyboard event failed");}
    }
    ATClearRegistrationSecret();lua_pushboolean(L,1);return 1;
}
static int l_inputRegistrationCode(lua_State *L) {
    if(gRegistrationID[0])return luaL_error(L,"registration job already active");
    ATClearRegistrationCode();BOOL found=NO;
    @autoreleasepool {
        NSError *error=nil;NSDictionary *job=ATLRegistrationClaimCode(ATRegistrationDir(),&error);
        if(job){BOOL idOK=[job[@"id"] getCString:gRegistrationID maxLength:sizeof(gRegistrationID) encoding:NSUTF8StringEncoding];
            found=idOK && [job[@"code"] getCString:gRegistrationCode maxLength:sizeof(gRegistrationCode) encoding:NSUTF8StringEncoding];}
    }
    if(!found){ATClearRegistrationCode();return luaL_error(L,"registration code unavailable");}
    if(!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent){ATClearRegistrationCode();return luaL_error(L,"keyboard unavailable");}
    size_t length=strlen(gRegistrationCode);
    for(size_t i=0;i<length;i++){
        uint16_t usage=0;int shift=0;ATCheckScript(L);
        if(!ATASCIIKey((unsigned char)gRegistrationCode[i],&usage,&shift) || shift){ATClearRegistrationCode();return luaL_error(L,"registration code invalid");}
        BOOL ok=ATASCIIKeyEvent(YES,usage);if(ok)ok=ATASCIIKeyEvent(NO,usage);
        if(!ok){ATClearRegistrationCode();return luaL_error(L,"keyboard event failed");}
    }
    ATClearRegistrationCode();lua_pushboolean(L,1);return 1;
}
static int l_registrationStage(lua_State *L) {
    const char *stage=luaL_checkstring(L,1);ATLRegEvent event;
    if(!strcmp(stage,"fields_ready"))event=ATL_REG_FIELDS_READY;
    else if(!strcmp(stage,"begin_submit"))event=ATL_REG_BEGIN_SUBMIT;
    else if(!strcmp(stage,"verification_seen"))event=ATL_REG_VERIFICATION_SEEN;
    else if(!strcmp(stage,"failed"))event=ATL_REG_FAILED;
    else if(!strcmp(stage,"success"))event=ATL_REG_SUCCESS_CONFIRMED;
    else return luaL_error(L,"invalid registration stage");
    if(!gRegistrationID[0])return luaL_error(L,"no claimed registration job");
    if(event==ATL_REG_FIELDS_READY && gRegistrationPassword[0])return luaL_error(L,"registration password has not been used");
    BOOL ok=NO;
    @autoreleasepool { NSError *error=nil;ok=ATLRegistrationAdvance(ATRegistrationDir(),[NSString stringWithUTF8String:gRegistrationID],event,&error); }
    if(!ok)return luaL_error(L,"registration stage not confirmed");
    if(event==ATL_REG_VERIFICATION_SEEN || event==ATL_REG_FAILED || event==ATL_REG_SUCCESS_CONFIRMED){ATClearRegistrationSecret();ATClearRegistrationCode();gRegistrationID[0]=0;}
    lua_pushboolean(L,1);return 1;
}
static char gClaimedJobID[81], gClaimedEmail[255];
static int l_getEmailJob(lua_State *L) {
    char jobID[81]={0},email[255]={0}; BOOL found=NO;
    @autoreleasepool {
        NSError *error=nil;
        NSDictionary *job=ATLEmailClaimJob(ATBaseDir(),&error);
        if (job) {
            found=[job[@"jobId"] getCString:jobID maxLength:sizeof(jobID) encoding:NSUTF8StringEncoding] &&
                  [job[@"email"] getCString:email maxLength:sizeof(email) encoding:NSUTF8StringEncoding];
            if (found) { strcpy(gClaimedJobID,jobID); strcpy(gClaimedEmail,email); }
        } else ATLog(@"getEmailJob: %@",error.localizedDescription);
    }
    if (!found) { lua_pushnil(L); return 1; }
    lua_createtable(L,0,2);
    lua_pushstring(L,jobID); lua_setfield(L,-2,"jobId");
    lua_pushstring(L,email); lua_setfield(L,-2,"email");
    return 1;
}
static const char *ATLuaCheckText(lua_State *L, int index, size_t max, BOOL empty, size_t *length) {
    if (lua_type(L,index)!=LUA_TSTRING) luaL_error(L,"email result: expected string");
    const char *text=lua_tolstring(L,index,length);
    if ((!empty && !*length) || *length>max || !ATValidUTF8Text((const unsigned char *)text,*length))
        luaL_error(L,"email result: invalid UTF-8, control characters or length");
    return text;
}
static int l_sendEmailResult(lua_State *L) {
    size_t jobLength=0,emailLength=0,nameLength=0;
    const char *jobID=ATLuaCheckText(L,1,80,NO,&jobLength);
    const char *email=ATLuaCheckText(L,2,254,NO,&emailLength);
    const char *username=ATLuaCheckText(L,3,1024,NO,&nameLength);
    luaL_checktype(L,4,LUA_TTABLE);
    size_t count=lua_rawlen(L,4);
    if (count>100) return luaL_error(L,"sendEmailResult: max 100 OCR lines");
    // Validate all Lua values before entering an ObjC pool (Lua errors longjmp).
    for(size_t i=1;i<=count;i++) {
        lua_rawgeti(L,4,(lua_Integer)i);
        size_t n=0; ATLuaCheckText(L,-1,2048,YES,&n); lua_pop(L,1);
    }
    BOOL ok=NO;
    @autoreleasepool {
        NSMutableArray *lines=[NSMutableArray array];
        for(size_t i=1;i<=count;i++) {
            lua_rawgeti(L,4,(lua_Integer)i); size_t n=0; const char *text=lua_tolstring(L,-1,&n);
            NSString *line=[[NSString alloc] initWithBytes:text length:n encoding:NSUTF8StringEncoding];
            [lines addObject:line]; lua_pop(L,1);
        }
        NSError *error=nil;
        ok=ATLEmailFinishJob(ATBaseDir(),[[NSString alloc] initWithBytes:jobID length:jobLength encoding:NSUTF8StringEncoding],
             [[NSString alloc] initWithBytes:email length:emailLength encoding:NSUTF8StringEncoding],
             [[NSString alloc] initWithBytes:username length:nameLength encoding:NSUTF8StringEncoding],lines,nil,&error);
        if(!ok) ATLog(@"sendEmailResult: %@",error.localizedDescription);
    }
    if(!ok) return luaL_error(L,"sendEmailResult: invalid, cancelled or stale job (see log)");
    gClaimedJobID[0]=gClaimedEmail[0]=0;
    lua_pushboolean(L,1); return 1;
}
static int l_failEmailJob(lua_State *L) {
    size_t jobLength=0,emailLength=0,failureLength=0;
    const char *jobID=ATLuaCheckText(L,1,80,NO,&jobLength);
    const char *email=ATLuaCheckText(L,2,254,NO,&emailLength);
    const char *failure=ATLuaCheckText(L,3,2048,NO,&failureLength);
    BOOL ok=NO;
    @autoreleasepool {
        NSError *error=nil;
        ok=ATLEmailFinishJob(ATBaseDir(),[[NSString alloc] initWithBytes:jobID length:jobLength encoding:NSUTF8StringEncoding],
              [[NSString alloc] initWithBytes:email length:emailLength encoding:NSUTF8StringEncoding],nil,nil,
              [[NSString alloc] initWithBytes:failure length:failureLength encoding:NSUTF8StringEncoding],&error);
        if(!ok) ATLog(@"failEmailJob: %@",error.localizedDescription);
    }
    if(ok) gClaimedJobID[0]=gClaimedEmail[0]=0;
    lua_pushboolean(L,ok); return 1;
}

// MVP 未实现的 API：保留函数名，给出明确提示而非 nil 报错
static int l_notImplemented(lua_State *L) {
    luaL_traceback(L, L, "not implemented in ATLite v0.3.24 yet", 1);
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
    {"getRegistrationJob", l_getRegistrationJob},
    {"inputRegistrationPassword", l_inputRegistrationPassword},
    {"inputRegistrationCode", l_inputRegistrationCode},
    {"registrationStage", l_registrationStage},
    {"getEmailJob", l_getEmailJob},
    {"sendEmailResult", l_sendEmailResult},
    {"failEmailJob", l_failEmailJob},
    {"findColors",     l_notImplemented},
    {"ocrText",        l_ocrText},
    {"appRun",         l_notImplemented},
    {"appKill",        l_notImplemented},
    {"vibrate",        l_notImplemented},
    {"openURL",        l_notImplemented},
    {"inputText",      l_inputText},
    {"toast",          l_notImplemented},
    {NULL, NULL},
};

// ---- Extensions.lua（R17：v2 版本标记 + 版本感知覆写）----
static NSString * const ATExtensionsLua = @R"(-- ATLite Extensions.lua v3 (AutoTouch API parity layer + humanized input)
print = log

-- Lua 5.3 math.random 默认种子固定 —— /dev/urandom 播种
math.randomseed(_atlSeed)
_atlSeed = nil


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
    local ok, err = pcall(usleep, math.random(60000, 120000))
    touchUp(0, x, y)
    if not ok then error(err, 0) end
end

function swipe(x1, y1, x2, y2, durationMs)
    durationMs = durationMs or 400
    assert(type(durationMs) == "number" and durationMs >= 16 and durationMs <= 10000,
        "swipe duration must be 16..10000ms")
    local steps = math.min(120, math.max(2, math.floor(durationMs / 16)))
    touchDown(0, x1, y1)
    local x, y = x1, y1
    local ok, err = pcall(function()
        for i = 1, steps do
            local t = i / steps
            x, y = x1 + (x2-x1)*t, y1 + (y2-y1)*t
            touchMove(0, x, y)
            msleep(durationMs / steps)
        end
    end)
    touchUp(0, x, y)
    if not ok then error(err, 0) end
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
        if (cur && [cur containsString:@"ATLite Extensions.lua v3"]) needsWrite = NO;
    }
    if (!needsWrite) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:ext]) {
        NSString *bak = [ext stringByAppendingString:@".bak"];
        [[NSFileManager defaultManager] removeItemAtPath:bak error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:ext toPath:bak error:nil];
        ATLog(@"Extensions.lua old version backed up to %@", bak);
    }
    [ATExtensionsLua writeToFile:ext atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ATLog(@"Extensions.lua v3 written to %@", ext);
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
// gScriptDeadline is defined beside ATMonotonicNow, before all C operations.

// ---------------------------------------------------------------------------
// E26：强停兜底。
// 脚本跑在 SpringBoard 进程里，**把 App 从后台划掉对它毫无影响**（App 只是遥控器）。
// 所以停止必须是"脚本自己能看见"的信号，不能只依赖 App 存活或通知送达：
//   通道 1（快）：Darwin 通知 → gStopGeneration 内存代次
//   通道 2（兜底）：<jbroot>/.../stop.flag 文件 —— 就算通知中心不工作、
//                   SpringBoard 主线程忙到不处理回调，脚本下次检查文件时也能停下
// 两条通道都在 hook（每 10 万指令）与 sleep 分片里被检查。
// （具体实现定义在文件前部 Paths 段之后 —— C 要求先声明后使用）
// ---------------------------------------------------------------------------

static void ATLuaTimeoutHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    ATCheckScript(L);
}

static void *ATLuaAllocator(void *ud, void *ptr, size_t oldSize, size_t newSize) {
    return ATBudgetRealloc((ATMemoryBudget *)ud, ptr, oldSize, newSize);
}

// Preserve ordinary protected-call results, but never let a script swallow the
// persistent stop/deadline signal and continue its outer loop indefinitely.
static int ATGuardedProtectedCall(lua_State *L) {
    int arguments = lua_gettop(L);
    ATCheckScript(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 1);
    lua_call(L, arguments, LUA_MULTRET);
    ATCheckScript(L);
    return lua_gettop(L);
}
static void ATGuardProtectedCall(lua_State *L, const char *name) {
    lua_getglobal(L, name);
    lua_pushcclosure(L, ATGuardedProtectedCall, 1);
    lua_setglobal(L, name);
}

static int ATInitializeLua(lua_State *L) {
    luaL_requiref(L, "_G", luaopen_base, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1); lua_pop(L, 1);
    ATGuardProtectedCall(L, "pcall");
    ATGuardProtectedCall(L, "xpcall");
    // No debug/os/io/package/coroutine. This is defense in depth, not a sandbox.
    // Lua 5.3 disables instruction hooks during __gc. A script-installed
    // finalizer could therefore loop forever even during lua_close().
    const char *removed[] = { "dofile", "loadfile", "load", "collectgarbage",
                             "setmetatable", "getmetatable", NULL };
    for (int i=0; removed[i]; i++) { lua_pushnil(L); lua_setglobal(L, removed[i]); }
    lua_pushinteger(L, arc4random_uniform(0x7fffffff)); lua_setglobal(L, "_atlSeed");
    luaL_newlib(L, ATLuaFuncs); lua_setglobal(L, "at");
    lua_getglobal(L, "at"); lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        const char *key = lua_tostring(L, -2);
        lua_pushvalue(L, -1); lua_setglobal(L, key); lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return 0;
}

static BOOL ATExecuteLoadedChunk(lua_State *L, NSString *path) {
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&error];
    if (!attributes || [attributes fileSize] > 1024 * 1024) {
        ATLog(@"script read rejected (missing or >1MiB): %@ (%@)", path, error); return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!text || data.length > 1024 * 1024) {
        ATLog(@"script read/UTF-8 validation failed: %@ (%@)", path, error); return NO;
    }
    int status = luaL_loadbufferx(L, data.length ? (const char *)data.bytes : "", data.length,
                                 path.lastPathComponent.UTF8String, "t");
    if (!status) status = lua_pcall(L, 0, 0, 0);
    if (status) {
        ATLog(@"lua error (%@): %s", path.lastPathComponent, lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "non-string Lua error");
        lua_pop(L, 1); return NO;
    }
    return YES;
}

static void ATPlayLuaFile(NSString *scriptPath) {
    ATMemoryBudget budget = {0, 32 * 1024 * 1024};
    lua_State *L = NULL;
    @try {
        gClaimedJobID[0]=gClaimedEmail[0]=0;gRegistrationID[0]=0;ATClearRegistrationSecret();ATClearRegistrationCode();
        ATWriteStatus(YES, scriptPath.lastPathComponent);
        gScriptDeadline = ATMonotonicNow() + AT_SCRIPT_TIMEOUT_SEC;
        L = lua_newstate(ATLuaAllocator, &budget);
        if (!L) { ATLog(@"Lua VM allocation failed"); return; }
        lua_sethook(L, ATLuaTimeoutHook, LUA_MASKCOUNT, 10000);
        lua_pushcfunction(L, ATInitializeLua);
        if (lua_pcall(L, 0, 0, 0)) { ATLog(@"Lua bootstrap failed: %s", lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "non-string Lua error"); return; }
        NSString *extensions = [ATLibsDir() stringByAppendingPathComponent:@"Extensions.lua"];
        if (!ATExecuteLoadedChunk(L, extensions)) return;
        if (ATExecuteLoadedChunk(L, scriptPath)) ATLog(@"script finished: %@", scriptPath.lastPathComponent);
    } @catch (NSException *exception) {
        ATLog(@"script exception: %@", exception);
    } @finally {
        // Release injected inputs even when Lua stops during tap()'s sleep.
        @try { ATReleaseAllInputs(); }
        @catch (NSException *exception) { ATLog(@"input cleanup exception: %@", exception); }
        if (L) lua_close(L);
        ATClearRegistrationSecret();ATClearRegistrationCode();
        if(gRegistrationID[0]) {
            NSError *error=nil;
            ATLRegistrationAdvance(ATRegistrationDir(),[NSString stringWithUTF8String:gRegistrationID],ATL_REG_INTERRUPTED,&error);
            gRegistrationID[0]=0;
        }
        if(gClaimedJobID[0]) {
            NSError *error=nil;
            ATLEmailFinishJob(ATBaseDir(),[NSString stringWithUTF8String:gClaimedJobID],
                [NSString stringWithUTF8String:gClaimedEmail],nil,nil,@"script ended or stopped before reporting a username",&error);
            gClaimedJobID[0]=gClaimedEmail[0]=0;
        }
        gScriptDeadline = 0;
        ATWriteStatus(NO, scriptPath.lastPathComponent);
        __sync_lock_test_and_set(&gRunningScripts, 0);
    }
}

#pragma mark - Command handling (SpringBoard)

static BOOL ATIsSpringBoard(void) {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

// R33-C：spawn 出去的子进程退出后必须回收，否则变僵尸挂在常驻的 SpringBoard 名下，
// 而 SpringBoard 不会替我们 reap —— 每点一次探针就多一个僵尸，累积泄漏 pid 表。
// 串行队列上的非阻塞轮询统一负责回收与超时，无 dispatch source 失败路径。
#include <errno.h>
#include <stdio.h>
static dispatch_queue_t ATReapQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("me.atlite.reap", DISPATCH_QUEUE_SERIAL); });
    return q;
}
typedef struct ATProbeReaper {
    pid_t pid;
    char runId[37];
    unsigned polls;
    unsigned postKillPolls;
    unsigned interruptPolls;
    int killSent;
} ATProbeReaper;

// One serial owner checks and reaps this child, including the timeout path.
// It never blocks a worker and stops immediately if another reaper owns the child.
static void ATProbeReapPoll(void *context) {
    ATProbeReaper *state = (ATProbeReaper *)context;
    int status = 0;
    pid_t result = waitpid(state->pid, &status, WNOHANG);
    if (result == state->pid) {
        if (WIFEXITED(status))
            ATLog(@"PROBE_P2 run_id=%s pid=%d exited exit_status=%d", state->runId, state->pid, WEXITSTATUS(status));
        else if (WIFSIGNALED(status))
            ATLog(@"PROBE_P2 run_id=%s pid=%d signaled signal=%d", state->runId, state->pid, WTERMSIG(status));
        else
            ATLog(@"PROBE_P2 run_id=%s pid=%d unexpected wait status=%d", state->runId, state->pid, status);
        free(state);
        return;
    }
    if (result < 0 && errno == ECHILD) {
        ATLog(@"PROBE_P2 run_id=%s pid=%d waitpid ECHILD; exit status unavailable", state->runId, state->pid);
        free(state);
        return;
    }
    if (result < 0 && errno != EINTR) {
        ATLog(@"PROBE_P2 run_id=%s pid=%d waitpid failed errno=%d; child may remain unreaped", state->runId, state->pid, errno);
        free(state);
        return;
    }
    if (result < 0 && errno == EINTR) {
        if (++state->interruptPolls >= 80) {
            ATLog(@"PROBE_P2 run_id=%s pid=%d waitpid repeatedly interrupted; child may remain unreaped", state->runId, state->pid);
            free(state);
            return;
        }
    } else {
        state->interruptPolls = 0;
    }
    if (result == 0 && !state->killSent && ++state->polls >= 80) {
        state->killSent = 1;
        int rc = kill(state->pid, SIGKILL);
        int killErrno = rc == 0 ? 0 : errno;
        ATLog(@"PROBE_P2 run_id=%s pid=%d timeout kill_rc=%d errno=%d", state->runId, state->pid, rc, killErrno);
    }
    if (state->killSent && ++state->postKillPolls >= 300) {
        ATLog(@"PROBE_P2 run_id=%s pid=%d reaper stopped: child may remain unreaped", state->runId, state->pid);
        free(state);
        return;
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                     ATReapQueue(), state, ATProbeReapPoll);
}

static void ATReapChildAsync(ATProbeReaper *state) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                     ATReapQueue(), state, ATProbeReapPoll);
}

// P2（阶段 0 探针）：SpringBoard 内能否 posix_spawn —— 这是 B 模式保活唯一的悬空点。
// 与 App 侧共用同一份二进制；stdout 交给探针自己写 probe.log，这里只关心 rc/errno。
static void ATProbeSpawnFromSpringBoard(void) {
    NSString *runId = NSUUID.UUID.UUIDString;
    NSString *exe = [ATJBRoot() stringByAppendingPathComponent:@"Applications/ATLite.app/ATLiteProbe"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:exe]) { ATLog(@"PROBE_P2 run_id=%@ pid=0 FAIL 二进制缺失: %@", runId, exe); return; }
    ATProbeReaper *reaper = (ATProbeReaper *)calloc(1, sizeof(*reaper));
    if (!reaper) { ATLog(@"PROBE_P2 run_id=%@ pid=0 FAIL reaper allocation", runId); return; }
    posix_spawn_file_actions_t fa;
    int actionRC = posix_spawn_file_actions_init(&fa);
    if (actionRC != 0) { ATLog(@"PROBE_P2 run_id=%@ pid=0 FAIL file actions init rc=%d", runId, actionRC); free(reaper); return; }
    NSString *probeLog = [ATLogsDir() stringByAppendingPathComponent:@"tweak.log"];
    actionRC = posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, probeLog.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (actionRC != 0) { ATLog(@"PROBE_P2 run_id=%@ pid=0 FAIL file actions addopen rc=%d", runId, actionRC); posix_spawn_file_actions_destroy(&fa); free(reaper); return; }
    snprintf(reaper->runId, sizeof(reaper->runId), "%s", runId.UTF8String);
    char *argv[] = { (char *)"ATLiteProbe",
                     (char *)"--run-id", (char *)runId.UTF8String,
                     (char *)"--from", (char *)"springboard", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe.fileSystemRepresentation, &fa, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    ATLog(@"PROBE_P2 run_id=%@ spawn rc=%d errno=%d exec=%@ pid=%d path=%@",
          runId, rc, rc, [fm isExecutableFileAtPath:exe] ? @"YES" : @"NO", pid, exe);
    if (rc == 0 && pid > 0) { reaper->pid = pid; ATReapChildAsync(reaper); }
    else free(reaper);
}

static BOOL ATValidScriptName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length || name.length > 128 ||
        [name containsString:@"/"] || [name containsString:@"\\"] || [name containsString:@".."] ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    return [@[@"at", @"lua"] containsObject:name.pathExtension.lowercaseString];
}

// Legacy senders without IDs retain their existing at-least-once semantics.
// Keep the latest 4096 IDs in insertion order. After eviction or a SpringBoard
// restart, an older delayed command can no longer be guaranteed deduplicated.
static BOOL ATClaimCommandID(id commandID) {
    if (![commandID isKindOfClass:NSString.class] || ![commandID length]) return YES;
    static const NSUInteger ATCommandIDCapacity = 4096;
    static NSMutableOrderedSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableOrderedSet orderedSet]; });
    @synchronized (seen) {
        if ([seen containsObject:commandID]) return NO;
        if (seen.count == ATCommandIDCapacity) [seen removeObjectAtIndex:0];
        [seen addObject:commandID];
        return YES;
    }
}

static void ATHandleCommand(void) {
    if (!ATIsSpringBoard()) return;
    uint32_t observedStopGeneration = __sync_fetch_and_add(&gStopGeneration, 0);
    NSString *cmdPath = [ATBaseDir() stringByAppendingPathComponent:@"command.json"];
    NSData *data = [NSData dataWithContentsOfFile:cmdPath];
    if (!data) return;
    NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![cmd isKindOfClass:[NSDictionary class]]) return;
    NSString *action = cmd[@"cmd"];
    NSString *script = cmd[@"script"] ?: @"";
    if (![action isKindOfClass:NSString.class] || !action.length) return;
    if (!ATClaimCommandID(cmd[@"commandId"])) return;
    ATLog(@"command: %@ (%@)", action, script);

    // E26：强停。不要求 ATIsSpringBoard —— 任何注入进程收到都先落内存标志，
    // 但要真正中止脚本只有 SpringBoard 里那个 hook 会读到它。
    if ([action isEqualToString:@"stop"]) {
        __sync_fetch_and_add(&gStopGeneration, 1);
        ATLog(@"stop requested (cooperative cancellation; waiting for actual exit)");
        return;
    }

    // 阶段 0 探针 P2：SpringBoard 内 spawn（不跑脚本、不影响任何现有状态）
    if ([action isEqualToString:@"probe"]) {
        if (!ATIsSpringBoard()) return;
        if (!ATJBRoot()) { NSLog(@"[ATLite] current jailbreak root unavailable; tweak disabled"); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { ATProbeSpawnFromSpringBoard(); }
        });
        return;
    }

    if ([action isEqualToString:@"run"]) {
        if (!ATValidScriptName(script)) { ATLog(@"run rejected: invalid script name"); return; }
        NSString *root = ATScriptsDir().stringByResolvingSymlinksInPath;
        NSString *path = [root stringByAppendingPathComponent:script].stringByResolvingSymlinksInPath;
        if (![path hasPrefix:[root stringByAppendingString:@"/"]]) { ATLog(@"run rejected: path escaped Scripts"); return; }
        if (!__sync_bool_compare_and_swap(&gRunningScripts, 0, 1)) {
            ATLog(@"run rejected: previous script is still active; stop and wait for exit"); return;
        }
        // Publish the pre-admission generation: a concurrent notification cannot
        // be erased by resetting a boolean after the running CAS.
        gRunStopGeneration = observedStopGeneration;
        id snapshot = cmd[@"stopSnapshot"];
        gRunStopSnapshot = (snapshot == [NSNull null] || [snapshot isKindOfClass:NSString.class]) ? snapshot : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { ATPlayLuaFile(path); }
        });
    }


}

#pragma mark - Darwin notification

static void ATDarwinCallback(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    @autoreleasepool {
        // Serialize command reads through admission, without holding the gate
        // during script execution. The stop file remains independently visible.
        static NSObject *ATCommandCallbackGate;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ ATCommandCallbackGate = [NSObject new]; });
        @synchronized (ATCommandCallbackGate) { ATHandleCommand(); }
    }
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        if (!ATIsSpringBoard()) return;
        if (!ATJBRoot()) { NSLog(@"[ATLite] current jailbreak root unavailable; tweak disabled"); return; }
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in @[ATBaseDir(), ATScriptsDir(), ATLibsDir(), ATImagesDir(), ATLogsDir()]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @0755} error:nil];
        }
        BOOL registrationDirectory=NO;
        if ([fm fileExistsAtPath:ATRegistrationDir() isDirectory:&registrationDirectory] && registrationDirectory) {
            NSError *recoveryError=nil;
            if(!ATLRegistrationRecover(ATRegistrationDir(),&recoveryError)) ATLog(@"registration recovery unavailable");
        }
        ATEnsureLuaLibraries();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        ATDarwinCallback, (__bridge CFStringRef)AT_DARWIN_NOTIFY,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        if (ATIsSpringBoard()) {
            ATLoadHIDSymbols();
            ATLoadCaptureSymbols();
        }
        ATLog(@"v0.3.24 loaded in %@ (sb=%d, jbroot=%@ via %@)",
              NSBundle.mainBundle.bundleIdentifier ?: @"?", ATIsSpringBoard(),
              ATJBRoot(), gJBRootSource ?: @"?");
    }
}
