// ATLiteTweak - AutoTouch-style script runner (rootless, roothide/Dopamine)
//
// 架构对齐 AutoTouch 8.6.3（见逆向分析报告）:
//  - Lua 5.3 引擎住在 tweak 内（SpringBoard 进程），App 只是管理器
//  - 脚本为 .at 文件（Lua 语法），存放在 <jbroot>/var/mobile/Library/ATLite/Scripts/
//  - LuaLibraries/Extensions.lua 预加载（AutoTouch 同机制），提供 API 糖
//  - App 通过 command.json + Darwin 通知指挥 tweak（AutoTouch 同构的进程通信）
//  - 触摸模拟走 IOHIDEventSystemClient（SimulateTouch/zxtouch/AutoTouch 同原理）

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

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

// theos SDK 的 Vision 头不含 VNRecognizedText.h(仅 @class 前置声明)。
// 以下 API 运行时 iOS 13+ 存在(部署目标 14.0),仅补编译期声明。
@interface VNRecognizedText (ATLiteSDKCompat)
- (NSArray<VNRecognizedText *> *)topCandidates:(NSUInteger)maxCandidateCount;
@property (nonatomic, readonly) CGRect boundingBox;
@end

#define AT_DARWIN_NOTIFY @"me.atlite.command"

#pragma mark - Paths

// rootless 根路径: Dopamine=/var/jb, roothide=/var/mobile/.jbroot-XXXXXXXX
static NSString *ATJBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:@"/var/jb"]) { root = @"/var/jb"; return; }
        NSArray *cands = [fm contentsOfDirectoryAtPath:@"/var/mobile" error:nil];
        for (NSString *n in cands) {
            if ([n hasPrefix:@".jbroot-"]) {
                root = [@"/var/mobile/" stringByAppendingString:n];
                return;
            }
        }
        root = @"/var/jb"; // fallback
    });
    return root;
}

static NSString *ATBaseDir(void)    { return [ATJBRoot() stringByAppendingString:@"/var/mobile/Library/ATLite"]; }
static NSString *ATScriptsDir(void) { return [ATBaseDir() stringByAppendingPathComponent:@"Scripts"]; }
static NSString *ATLibsDir(void)    { return [ATBaseDir() stringByAppendingPathComponent:@"LuaLibraries"]; }
static NSString *ATLogsDir(void)    { return [ATBaseDir() stringByAppendingPathComponent:@"logs"]; }
static NSString *ATImagesDir(void)  { return [ATBaseDir() stringByAppendingPathComponent:@"Images"]; }

// 与 AutoTouch 一致: print = log
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

#pragma mark - Touch/key simulation (IOHIDEvent, private)

// 枚举值取自 IOKit 私有头 IOHIDEventTypes.h（SimulateTouch/zxtouch 等开源实现通用定义）
enum {
    kIOHIDDigitizerEventRange    = 0x00000001,
    kIOHIDDigitizerEventTouch    = 0x00000002,
    kIOHIDDigitizerEventPosition = 0x00000004,
};
enum { kIOHIDDigitizerTransducerTypeHand = 3 };
// 字段值经 WebKit IOKitSPIIOS.h / KIF / rpc-project consts.py / IDAObjcTypes 四方一致推导：
// base = kIOHIDEventTypeDigitizer(11) << 16 = 0x000B0000
// MajorRadius = base+20，IsDisplayIntegrated = MajorRadius+5 = base+25
// 注意：0x000B000B 是 BarrelPressure(base+11)，不是 IsDisplayIntegrated
#define kIOHIDEventFieldDigitizerMajorRadius        0x000B0014
#define kIOHIDEventFieldDigitizerMinorRadius        0x000B0015
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0x000B0019

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

static IOHIDEventSystemClientRef (*_AT_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static void (*_AT_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventRef (*_AT_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, Float32, Float32, Float32, Float32, Float32, Boolean, Boolean, uint32_t);
// 真实签名（nanotech/iphoneheaders IOHIDEvent.h）：allocator, timeStamp, index, identity,
// eventMask, x, y, z, tipPressure, twist, range, touch, options = 13 参（勿多加 uint32）
static IOHIDEventRef (*_AT_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, Float32, Float32, Float32, Float32, Float32, Boolean, Boolean, uint32_t);
static void (*_AT_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
// 注意：真实符号名是 ...Value 结尾（IOHIDEventSetInteger 这个符号不存在，dlsym 会返回 NULL）
static void (*_AT_IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int32_t);
static void (*_AT_IOHIDEventSetFloatValue)(IOHIDEventRef, uint32_t, Float32);
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

// —— 拟人化三件套：坐标抖动 / 随机时间戳 / 随机接触面积 ——
// 依据 BUILD_PLAN F40-F43：真人手指落点有 ±2pt 噪声、事件时间戳有 ±1ms 自然抖动、
// 指尖接触椭圆 3.5~6mm（Apple 默认 5mm，单位 mm）

// 返回 [-amount, +amount) 的均匀抖动
static float ATJitter(float amount) {
    return ((float)arc4random_uniform(2000) / 1999.0f * 2.0f - 1.0f) * amount;
}

// mach_absolute_time() ± 1ms（按 mach_timebase 正确换算为 ticks）
static uint64_t ATTimestampNow(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    if (tb.numer == 0 || tb.denom == 0) return mach_absolute_time();
    uint64_t half = (1000000ULL * (uint64_t)tb.numer) / (uint64_t)tb.denom; // 1ms → ticks
    if (half == 0 || half > 0x7fffffffULL) return mach_absolute_time();
    return mach_absolute_time() + (int64_t)arc4random_uniform((uint32_t)(half * 2)) - (int64_t)half;
}

// action: 0=down 1=move 2=up （与 AutoTouch touchDown/touchMove/touchUp 对应）
static void ATSimulateTouch(int action, int finger, float x, float y) {
    if (!gHIDReady) return;
    uint64_t ts = ATTimestampNow();
    BOOL isUp = (action == 2);
    uint32_t mask = (action == 1)
        ? (kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventTouch)
        : (kIOHIDDigitizerEventRange   | kIOHIDDigitizerEventTouch);
    Boolean touching = isUp ? 0 : 1;

    // 1) 坐标抖动：down/up ±2pt、move ±1pt（真人无法精准复点同一像素；
    //    down 与 up 各自独立抖动，天然形成按住期间的微漂移）
    float j = (action == 1) ? 1.0f : 2.0f;
    x += ATJitter(j);
    y += ATJitter(j);

    // 3) 随机接触面积：major 3.5~6.0mm、minor 2.5~4.5mm（minor ≤ major）
    float major = 3.5f + (float)arc4random_uniform(251) / 100.0f;
    float minor = 2.5f + (float)arc4random_uniform(201) / 100.0f;
    if (minor > major) minor = major;

    // hand（父事件）：与 SimulateTouch/KIF 参考实现一致——位置/压力为 0，
    // 由 finger 子事件携带坐标与触摸状态（F42）
    IOHIDEventRef hand = _AT_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand,
        0, 0, kIOHIDDigitizerEventTouch, 0,
        0, 0, 0, 0, 0, 0, true, 0);
    // finger（子事件）：index 从 1 起、identity=2（IOHIDFamily：multitouch 视 2 为 finger）（F43）
    IOHIDEventRef fg = _AT_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        (uint32_t)(finger + 1), 2, mask,
        x, y, 0, 0, 0, touching, touching, 0);
    if (!hand || !fg) { if (hand) CFRelease(hand); if (fg) CFRelease(fg); return; }
    _AT_IOHIDEventAppendEvent(hand, fg, 0);
    _AT_IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    _AT_IOHIDEventSetIntegerValue(fg,   kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    _AT_IOHIDEventSetFloatValue(fg, kIOHIDEventFieldDigitizerMajorRadius, major);
    _AT_IOHIDEventSetFloatValue(fg, kIOHIDEventFieldDigitizerMinorRadius, minor);
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, hand);
    CFRelease(hand);
    CFRelease(fg);
}

// keyDown/keyUp: usage 为 consumer page (0x0C) 的用法码，与 AutoTouch KEY_TYPE 值一致
#define AT_HID_USAGE_PAGE_CONSUMER 0x0C
static void ATSimulateKey(BOOL down, int usage) {
    if (!gHIDReady || !_AT_IOHIDEventCreateKeyboardEvent) return;
    IOHIDEventRef ev = _AT_IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, ATTimestampNow(),
        AT_HID_USAGE_PAGE_CONSUMER, (uint32_t)usage, down ? TRUE : FALSE, 0);
    if (!ev) return;
    _AT_IOHIDEventSystemClientDispatchEvent(gHIDClient, ev);
    CFRelease(ev);
}

#pragma mark - Screen capture (CARenderServer + IOSurface, 全部 dlsym 绕开 SDK 头文件)

typedef struct CF_BRIDGED_TYPE(id) __IOSurface *IOSurfaceRef;
// 真实签名（AutoTouch libATGraphic 反汇编 + ios-mcp 实证，BUILD_PLAN F46/F47）：
// IOSurfaceRef CARenderServerCaptureDisplay(uint32_t serverPort=0, CFStringRef displayName, CFDictionaryRef options)
// —— 首参 0 = 默认 server（不是 server 指针！），第二参显示屏名（iOS: "LCD"，备选 "Main"）
static IOSurfaceRef (*_AT_CARenderServerCaptureDisplay)(uint32_t, CFStringRef, CFDictionaryRef);
static size_t (*_AT_IOSurfaceGetWidth)(IOSurfaceRef);
static size_t (*_AT_IOSurfaceGetHeight)(IOSurfaceRef);
static size_t (*_AT_IOSurfaceGetBytesPerRow)(IOSurfaceRef);
static uint32_t (*_AT_IOSurfaceGetPixelFormat)(IOSurfaceRef);
static void * (*_AT_IOSurfaceGetBaseAddress)(IOSurfaceRef);
// 可选：读前加锁（经典截图模式，AutoTouch 同样 Lock/Unlock）；缺失时不阻塞
static int32_t (*_AT_IOSurfaceLock)(IOSurfaceRef, uint32_t, uint32_t *);
static void (*_AT_IOSurfaceUnlock)(IOSurfaceRef, uint32_t, uint32_t);
static BOOL gCaptureReady = NO;

static void ATLoadCaptureSymbols(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!qc || !ios) { ATLog(@"QuartzCore/IOSurface dlopen failed: %s / %s",
                             qc ? "ok" : dlerror(), ios ? "ok" : dlerror()); return; }
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

static void ATFreeBitmap(ATBitmap *b) {
    if (b->rgba) { free(b->rgba); b->rgba = NULL; }
    b->w = b->h = 0;
}

// 抓当前主屏，输出 RGBA8（仅 SpringBoard 进程可用）
static BOOL ATCaptureScreen(ATBitmap *out) {
    if (!gCaptureReady) return NO;
    // port=0（默认 server）+ 显示屏名：iOS 上 "LCD" 优先，"Main" 回退（ios-mcp 同款策略）
    IOSurfaceRef s = _AT_CARenderServerCaptureDisplay(0, CFSTR("LCD"), NULL);
    if (!s) s = _AT_CARenderServerCaptureDisplay(0, CFSTR("Main"), NULL);
    if (!s) return NO;
    uint32_t seed = 0;
    if (_AT_IOSurfaceLock) _AT_IOSurfaceLock(s, 1 /*kIOSurfaceLockReadOnly*/, &seed);  // 读前加锁
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
    int rIdx = (fmt == 'ARGB') ? 1 : 2;  // 输出统一 RGBA
    int bIdx = (fmt == 'ARGB') ? 3 : 0;
    for (int y = 0; y < h; y++) {
        uint8_t *src = base + (size_t)y * pitch;
        uint8_t *dst = out->rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            dst[x*4+0] = src[x*4+rIdx];
            dst[x*4+1] = src[x*4+1];
            dst[x*4+2] = src[x*4+bIdx];
            dst[x*4+3] = src[x*4+3];
        }
    }
    if (_AT_IOSurfaceUnlock) _AT_IOSurfaceUnlock(s, 1, seed);  // 读毕解锁
    CFRelease(s);
    return YES;
}

static inline uint8_t ATLuma(const uint8_t *px) {
    return (uint8_t)((px[0] * 299 + px[1] * 587 + px[2] * 114) / 1000);
}

#pragma mark - Image matching (粗到细 NCC 模板匹配)

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

// scale: 缩小倍数（nearest 采样）
static BOOL ATGrayDownscale(const ATGray *src, ATGray *dst, int scale) {
    dst->w = src->w / scale; dst->h = src->h / scale;
    if (dst->w <= 0 || dst->h <= 0) return NO;
    dst->g = (uint8_t *)malloc((size_t)dst->w * dst->h);
    if (!dst->g) return NO;
    for (int y = 0; y < dst->h; y++) {
        for (int x = 0; x < dst->w; x++) {
            dst->g[(size_t)y * dst->w + x] = src->g[(size_t)(y * scale) * src->w + x * scale];
        }
    }
    return YES;
}

// 在 gray 里做零均值 NCC，返回最佳位置与得分；scale 用于映射回原图坐标
static BOOL ATNCCBest(const ATGray *hay, const ATGray *needle, double minScore,
                      int *outX, int *outY, double *outScore) {
    if (needle->w < 4 || needle->h < 4 || hay->w < needle->w || hay->h < needle->h) return NO;
    // 模板均值与方差
    double tMean = 0;
    for (int i = 0; i < needle->w * needle->h; i++) tMean += needle->g[i];
    tMean /= needle->w * needle->h;
    double tVar = 0;
    for (int i = 0; i < needle->w * needle->h; i++) {
        double d = needle->g[i] - tMean;
        tVar += d * d;
    }
    if (tVar < 1e-6) return NO; // 纯色模板无意义

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

// 完整搜图: 抓屏 → 粗搜(1/4) → 原图精搜
static BOOL ATFindImageInScreen(const ATGray *screenFull, const ATBitmap *tmplRGBA,
                                double similarity, int *outX, int *outY, double *outScore) {
    ATGray tmplGray = {0};
    if (!ATRGBAToGray(tmplRGBA, &tmplGray)) return NO;

    ATGray screenQuarter = {0}, tmplQuarter = {0};
    BOOL found = NO;
    int cx = 0, cy = 0;
    double score = 0;
    if (ATGrayDownscale(screenFull, &screenQuarter, 4) && ATGrayDownscale(&tmplGray, &tmplQuarter, 4)) {
        if (ATNCCBest(&screenQuarter, &tmplQuarter, similarity - 0.15, &cx, &cy, &score)) {
            found = YES;
        }
    }
    ATFreeGray(&screenQuarter);
    ATFreeGray(&tmplQuarter);
    if (!found) { ATFreeGray(&tmplGray); return NO; }

    // 精搜：在粗命中附近 ±12px（原图坐标）全分辨率搜索
    int pad = 12;
    int x0 = MAX(0, cx * 4 - pad), y0 = MAX(0, cy * 4 - pad);
    int x1 = MIN(screenFull->w, x0 + tmplQuarter.w * 4 + tmplGray.w - tmplGray.w + pad * 2 + tmplGray.w);
    int y1 = MIN(screenFull->h, y0 + tmplQuarter.h * 4 + tmplGray.h + pad * 2);
    x1 = MIN(screenFull->w, cx * 4 + tmplGray.w + pad * 2 + 8);
    y1 = MIN(screenFull->h, cy * 4 + tmplGray.h + pad * 2 + 8);
    if (x1 - x0 < tmplGray.w || y1 - y0 < tmplGray.h) { ATFreeGray(&tmplGray); return NO; }

    ATGray region = {0};
    region.w = x1 - x0; region.h = y1 - y0;
    region.g = (uint8_t *)malloc((size_t)region.w * region.h);
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

// 加载模板 PNG/JPG → RGBA
static BOOL ATLoadTemplate(const char *nameUtf8, ATBitmap *out) {
    NSString *name = [NSString stringWithUTF8String:nameUtf8];
    if (name.length > 128 || [name containsString:@"/"] || [name containsString:@".."]) return NO;
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
    if (w <= 0 || h <= 0 || (long)w * h > 4e6) return NO; // 模板限制在 4MP 内
    out->w = w; out->h = h;
    out->rgba = (uint8_t *)malloc((size_t)w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(out->rgba, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return YES;
}

// CGImage ← RGBA（供 Vision OCR 用）
static CGImageRef ATCreateCGImageFromBitmap(const ATBitmap *b) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(b->rgba, b->w, b->h, 8, b->w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
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
    struct timespec req;
    req.tv_sec = (time_t)(us / 1e6);
    req.tv_nsec = (long)((us - req.tv_sec * 1e6) * 1e3);
    nanosleep(&req, NULL);
    return 0;
}
// ATLite 扩展: msleep(毫秒) —— AutoTouch 没有但写脚本更顺手
static int l_msleep(lua_State *L) {
    lua_pushcfunction(L, NULL); // placeholder to keep stack balanced if misused
    lua_pop(L, 1);
    double ms = luaL_checknumber(L,1);
    struct timespec req;
    req.tv_sec = (time_t)(ms / 1000);
    req.tv_nsec = (long)((ms - req.tv_sec * 1000) * 1e6);
    nanosleep(&req, NULL);
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
// stop(): 终止脚本（AutoTouch 同名 API）
static int l_stop(lua_State *L) {
    return luaL_error(L, "STOP");
}

// ---- 屏幕取色/搜图/搜字 ----

static int l_getColor(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    ATBitmap b = {0};
    if (!ATCaptureScreen(&b)) { lua_pushnil(L); return 1; }
    if (x < 0 || y < 0 || x >= b.w || y >= b.h) { ATFreeBitmap(&b); lua_pushnil(L); return 1; }
    const uint8_t *px = b.rgba + ((size_t)y * b.w + x) * 4;
    lua_pushinteger(L, (px[0] << 16) | (px[1] << 8) | px[2]);
    ATFreeBitmap(&b);
    return 1;
}

// findColor(color) / findColor(color, tolerance) → { {x,y}, ... }
static int l_findColor(lua_State *L) {
    unsigned int color = (unsigned int)luaL_checkinteger(L, 1);
    int tol = lua_isnumber(L, 2) ? (int)lua_tointeger(L, 2) : 16;
    uint8_t cr = (color >> 16) & 0xFF, cg = (color >> 8) & 0xFF, cb = color & 0xFF;
    ATBitmap b = {0};
    if (!ATCaptureScreen(&b)) { lua_pushnil(L); return 1; }

    // 1/4 缩放扫描
    int scale = 4, sw = b.w / scale, sh = b.h / scale;
    lua_newtable(L);
    int n = 0;
    for (int y = 0; y < sh && n < 10; y++) {
        for (int x = 0; x < sw && n < 10; x++) {
            const uint8_t *px = b.rgba + ((size_t)(y * scale) * b.w + x * scale) * 4;
            int dr = px[0] - (int)cr, dg = px[1] - (int)cg, db2 = px[2] - (int)cb;
            if (abs(dr) <= tol && abs(dg) <= tol && abs(db2) <= tol) {
                lua_newtable(L);
                lua_pushinteger(L, x * scale); lua_rawseti(L, -2, 1);
                lua_pushinteger(L, y * scale); lua_rawseti(L, -2, 2);
                lua_rawseti(L, -2, ++n);
            }
        }
    }
    ATFreeBitmap(&b);
    return 1;
}

// findImage("button.png", 0.9) → { {x, y, score}, ... }（中心点坐标）
static int l_findImage(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    double sim = lua_isnumber(L, 2) ? lua_tonumber(L, 2) : 0.9;
    ATBitmap tmpl = {0};
    if (!ATLoadTemplate(name, &tmpl)) { ATLog(@"findImage: template not found: %s", name); lua_pushnil(L); return 1; }
    ATBitmap screen = {0};
    if (!ATCaptureScreen(&screen)) { ATFreeBitmap(&tmpl); lua_pushnil(L); return 1; }
    ATGray screenGray = {0};
    BOOL haveGray = ATRGBAToGray(&screen, &screenGray);
    ATFreeBitmap(&screen);
    if (!haveGray) { ATFreeBitmap(&tmpl); lua_pushnil(L); return 1; }

    int x = 0, y = 0; double score = 0;
    lua_newtable(L);
    int n = 0;
    if (ATFindImageInScreen(&screenGray, &tmpl, sim, &x, &y, &score)) {
        lua_newtable(L);
        lua_pushinteger(L, x + tmpl.w / 2); lua_rawseti(L, -2, 1);
        lua_pushinteger(L, y + tmpl.h / 2); lua_rawseti(L, -2, 2);
        lua_pushnumber(L, score);           lua_rawseti(L, -2, 3);
        lua_rawseti(L, -2, ++n);
    }
    ATFreeGray(&screenGray);
    ATFreeBitmap(&tmpl);
    return 1;
}

// findText("设置") → { {x, y}, ... }（Vision OCR，中文/英文）
static int l_findText(lua_State *L) {
    const char *want = luaL_checkstring(L, 1);
    ATBitmap b = {0};
    if (!ATCaptureScreen(&b)) { lua_pushnil(L); return 1; }
    CGImageRef img = ATCreateCGImageFromBitmap(&b);
    if (!img) { ATFreeBitmap(&b); lua_pushnil(L); return 1; }

    __block NSMutableArray *hits = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:
        ^(VNRequest *request, NSError *error) {
            if (error) return;
            for (VNRecognizedText *t in request.results) {
                NSString *s = [t topCandidates:1].firstObject.string;
                if ([s containsString:@(want)]) {
                    CGRect bb = t.boundingBox; // 归一化、原点左下
                    double cx = (bb.origin.x + bb.size.width / 2) * b.w;
                    double cy = (1 - bb.origin.y - bb.size.height / 2) * b.h;
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
    dispatch_semaphore_signal(sem);
    CGImageRelease(img);

    lua_newtable(L);
    int n = 0;
    for (NSArray *pt in hits) {
        lua_newtable(L);
        NSNumber *x = pt.firstObject;
        NSNumber *y = pt.lastObject;
        lua_pushinteger(L, x.intValue); lua_rawseti(L, -2, 1);
        lua_pushinteger(L, y.intValue); lua_rawseti(L, -2, 2);
        lua_rawseti(L, -2, ++n);
    }
    if (n == 0) ATLog(@"findText: no match for %s", want);
    ATFreeBitmap(&b);
    return 1;
}
// MVP 暂未实现的 API：保留函数名，避免老脚本直接报 nil 错误
static int l_notImplemented(lua_State *L) {
    luaL_traceback(L, L, "not implemented in ATLite MVP yet", 1);
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

// AutoTouch 的 LuaLibraries/Extensions.lua 预加载机制：首次运行时落地为真实文件
static NSString * const ATExtensionsLua = @R"(-- ATLite Extensions.lua v2 (AutoTouch API parity layer + humanized input)
print = log

-- Lua 5.3 的 math.random 默认种子固定，不播种则每次运行序列相同 —— 用 /dev/urandom 播种
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

function tap(x, y)
    touchDown(0, x, y)
    usleep(math.random(60000, 120000))  -- 真人按住 60-120ms（原固定 16ms 是最典型的机器特征）
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

-- TODO(MVP+): getColors/findColors/ocrText/dialog 在后续版本以原生实现补齐
)";

// Extensions.lua 版本感知落地：文件缺失或版本标记过期时，旧文件备份为 .bak 后覆写。
// （否则已安装设备上的旧版 Extensions.lua 永远不会更新，拟人化改动不生效）
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

// 执行: 先跑 LuaLibraries/Extensions.lua（可被用户覆盖），再跑脚本本体
static void ATPlayLuaFile(NSString *scriptPath) {
    if (!gHIDReady) { ATLog(@"play aborted: HID not ready"); return; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptPath]) {
        ATLog(@"script not found: %@", scriptPath);
        return;
    }
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
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

    if ([action isEqualToString:@"run"]) {
        if (!ATIsSpringBoard()) return;
        // 支持带或不带 .at 后缀
        NSString *n = [script.pathExtension.lowercaseString isEqualToString:@"at"]
            ? script : [script stringByAppendingPathExtension:@"at"];
        NSString *path = [ATScriptsDir() stringByAppendingPathComponent:n];
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
        ATLog(@"loaded in %@ (sb=%d)", NSBundle.mainBundle.bundleIdentifier ?: @"?", ATIsSpringBoard());
    }
}
