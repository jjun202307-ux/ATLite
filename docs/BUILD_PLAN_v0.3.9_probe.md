> 历史资料：保留原始研究与决策记录，不代表 v0.3.11 当前实现。以 TECHNICAL.md 与 LIGHTWEIGHT_PLAN.md 为准。

# 构建计划 v0.3.9 —— 阶段 0 探针包（ATLiteProbe）

> **方法**：superpowers（规格 → 计划 → RED-GREEN TDD → 评审 → 收尾）
> **执行结果（已完成）**：T1–T15 全部执行，**CI run#40192241385 一次通过**，产物验收 17 项 + 补验全过，已部署局域网为 `ATLite_0.3.9_iphoneos-arm64e.deb`。归档见 `docs/ERRORS.md` E31。
>
> **规格来源**：`docs/PLAN_P0_DAEMON.md` §7（探针 P1–P5）与 §4.1（A/B 双模式保活）> **目标**：一次构建拿到五个真机结论，决定 A/B 双模式的默认值与阶段 2 起点
> **性质**：**纯新增**。不改现有抓屏 / 脚本 / 停止链路的任何行为。
> **交付**：`ATLite_0.3.9_iphoneos-arm64e.deb`，用户装一次即可同时验证基线与探针

---

## 0. 这份计划要回答的五个问题

| 编号 | 问题 | 决定什么 |
|---|---|---|
| P1 | App（mobile，no-sandbox）能否 `posix_spawn` 出 app bundle 内的二进制？errno 是多少？ | A 模式可行性 |
| P2 | SpringBoard 内能否 `posix_spawn` 同一个二进制？errno 是多少？ | B 模式可行性（**最大未知**） |
| P3 | spawn 出来的进程 `geteuid()` 是不是 0？ | setuid 在 roothide 下是否生效；不生效则改用 `persona-mgmt` |
| P4 | euid=0 下能否创建 HID client 并 dispatch 一次触摸？ | 阶段 2 能否把触摸搬进 daemon |
| P5 | euid=0 下能否 `IOMobileFramebufferOpen` 拿到主屏 surface？失败时 RenderDisplay 回退可用吗？ | 阶段 2 抓屏方案 |

---

## 1. 零构建验证清单（推送前逐项打勾）

已完成的取证（本轮与上一轮，均有源码/二进制出处）：

- [x] theos `makefiles/instance/tool.mk`：`LOCAL_INSTALL_PATH` ← `_INSTALL_PATH` ← `_PACKAGE_TARGET_DIR` ← `/usr/bin`；stage 行为 = `mkdir -p` + `cp` → `ATLiteProbe_INSTALL_PATH = /Applications/ATLite.app` 成立
- [x] theos `makefiles/package.mk`：`package:: ... stage → before-package → internal-package ...`
- [x] `app/entitlements.plist` 已有 `platform-application` + `no-sandbox`（exec 免 `Killed: 9`）
- [x] jbroot 位于 `/var/containers/Bundle/Application/` 内（可 exec 区域，rootlessJB writeup + find_jbroot L817 双证据）
- [x] 现有 HID 事件装配参数（`Tweak.xm` L289–306）与抓屏符号加载（`Tweak.xm` L343–371）已读过，探针复用同一套签名
- [x] `tools/verify_static.py` 的 `read()` 是**双参数** `read(root, rel)`；`check()`、`tweak` 变量已存在 → 断言代码按此写（T1）
- [x] **`tweak/Tweak.xm` 当前没有 `#import <spawn.h>` 也没有 `<fcntl.h>`** → T11 必须先补（否则编译失败）
- [x] `app/Source/ATLPaths.h` 已导出 `ATLBaseDir()` / `ATLLogsDir()` / `ATLJBRoot()` → T8 可直接用

**待验（写代码前必须自行确认，不得猜）**：

- [ ] `kIOHIDDigitizerEvent*` 与 `kIOHIDDigitizerTransducerTypeHand` 在 theos SDK 是否可见 →
      **规避方案（已采用）**：探针内一律自定义常量名 `AT_EV_*` / `AT_TRANSDUCER_HAND`，绝不依赖 SDK 私有头
- [ ] `IOMobileFramebufferConnection` 类型是否可见 → **规避**：探针内自定义 `typedef struct __IOMFBConn *ATFBConn;`
- [ ] `IOSurfaceRef` 是否可见 → **规避**：自定义 `typedef struct __ATIOSurface *ATSurfaceRef;`
- [ ] probe target 的 `_CODESIGN_FLAGS` 在 theos `tool.mk` 里是否被应用（与 application.mk 同机制）→ 若 CI 报签名相关错误，**第一嫌疑是这个**，回退方案：去掉 codesign flag，改由 postinst `ldid -S`（dpkg 内已有 ldid？未证实，不优先）

---

## 2. TDD 总顺序（不可跳过、不可颠倒）

```
T1  先写断言（R32 组 12 条）→ 跑，必须 FAIL（RED）
T2..T12  写实现
T13 再跑断言 → 必须 0 FAIL（GREEN）
T14 CI 强化
T15 提交推送 → 产物验收 → 部署
```

**没有 RED 就不算实现。** T1 的断言对未实现的旧代码必须全红；若某条对旧代码就绿了，说明该断言无效，必须改到它变红为止。

---

## 3. 任务清单

### T1（RED）：先写断言，确认它们会失败
- 文件路径：`tools/verify_static.py`
- 在 `V 版本三处同步` 断言**之前**插入 R32 组；同时把版本断言里的 `0.3.8` 全改为 `0.3.9`
- 要做的（完整代码，直接粘贴）：

```python
    # ---- R32: 阶段 0 探针包（A/B 双模式可行性验证） ----
    # 注意：本文件的 read() 是双参数 read(root, rel)；tweak 变量已在 main() 中定义
    probe_mk   = read(root, "probe/Makefile")
    probe_main = read(root, "probe/main.m")
    postinst   = read(root, "layout/DEBIAN/postinst")
    app_probe  = read(root, "app/Source/ATLProbe.m")
    logvc      = read(root, "app/Source/ATLLogViewController.m")
    app_mk     = read(root, "app/Makefile")
    root_mk    = read(root, "Makefile")

    check("R32 probe/Makefile 存在且为 tool.mk",
          "TOOL_NAME = ATLiteProbe" in probe_mk and "tool.mk" in probe_mk)
    check("R32 probe 安装路径为 app bundle",
          "ATLiteProbe_INSTALL_PATH = /Applications/ATLite.app" in probe_mk)
    check("R32 根 Makefile 含 probe 子工程", "SUBPROJECTS" in root_mk and "probe" in root_mk)
    check("R32 postinst 对探针 setuid",
          "chmod u+s" in postinst and "ATLiteProbe" in postinst)
    check("R32 probe 覆盖 P3 身份标记", "PROBE_P3" in probe_main and "geteuid()" in probe_main)
    check("R32 probe 覆盖 P4 HID", "PROBE_P4" in probe_main and "IOHIDEventSystemClientDispatchEvent" in probe_main)
    check("R32 probe 覆盖 P5 framebuffer", "PROBE_P5" in probe_main and "IOMobileFramebufferGetLayerDefaultSurface" in probe_main)
    check("R32 probe 不依赖 SDK 私有类型",
          "ATSurfaceRef" in probe_main and "ATFBConn" in probe_main and "AT_TRANSDUCER_HAND" in probe_main)
    check("R32 probe 结果落盘且权限对 App 可读", "probe.log" in probe_main and "0666" in probe_main)
    check("R32 App 侧用 posix_spawn（非私有 NSTask）",
          "posix_spawn" in app_probe and "NSTask" not in app_probe)
    check("R32 App 侧 P1 标记", "PROBE_P1" in app_probe)
    check("R32 tweak 侧 P2 标记", "PROBE_P2" in tweak)
    check("R32 日志页有探针入口", "ATLRunProbe" in logvc or "探针" in logvc)
    check("R32 app Makefile FILES 含 ATLProbe.m", "Source/ATLProbe.m" in app_mk)
```

- 验证：
  ```
  python tools/verify_static.py 2>&1 | grep -E "R32|FAIL" 
  ```
  **预期：R32 全部 FAIL（14 条），且版本断言也 FAIL。** 任何一条 PASS 都说明断言写错了，改到红为止。

---

### T2：probe 子工程骨架（Makefile + entitlements）
- 文件路径：`probe/Makefile`（新建）
- 要做的（完整内容）：

```make
THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ATLiteProbe

ATLiteProbe_FILES = main.m
ATLiteProbe_FRAMEWORKS = Foundation CoreFoundation
ATLiteProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# 实证：tool.mk 的 LOCAL_INSTALL_PATH 直接取 <INSTANCE>_INSTALL_PATH，
# 装进 app bundle 内才能 exec（jbroot 在 /var/containers/Bundle 内，出界 EPERM）。
ATLiteProbe_INSTALL_PATH = /Applications/ATLite.app
ATLiteProbe_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
```

- 文件路径：`probe/entitlements.plist`（新建）
- 要做的（完整内容）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>platform-application</key>
	<true/>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
</dict>
</plist>
```

- 验证：本地 `ls probe/` 两个文件都在；`python tools/verify_static.py` 中 R32 前两条应转 PASS

---

### T3：probe/main.m —— 骨架 + P3 身份
- 文件路径：`probe/main.m`（新建）
- 要做的（完整骨架，先只含 P3；T4/T5 再追加）：

```objc
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <unistd.h>

// 探针：只回答 PLAN_P0_DAEMON.md §7 的 P3/P4/P5（P1/P2 由调用方 App/tweak 回答）。
// 路径零推导：由调用方通过 --base 传入，避免 mainBundle 在命令行工具下的不确定行为。

static FILE *gOut = NULL;

static void P(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    printf("%s\n", s.UTF8String);
    if (gOut) { fprintf(gOut, "%s\n", s.UTF8String); fflush(gOut); }
}

typedef struct __ATIOSurface *ATSurfaceRef;   // 自定义名：绝不依赖 SDK 私有头
typedef struct __ATFBConn *ATFBConn;

// P3：我到底是谁（setuid 是否生效的唯一判据）
static void probe_identity(void) {
    P(@"PROBE_P3 uid=%d euid=%d gid=%d egid=%d pid=%d ppid=%d",
      getuid(), geteuid(), getgid(), getegid(), getpid(), getppid());
    P(@"PROBE_P3 verdict=%@", geteuid() == 0 ? @"ROOT" : @"NOT-ROOT");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *base = nil, *from = @"?";
        for (int i = 1; i < argc - 1; i++) {
            if (!strcmp(argv[i], "--base")) base = @(argv[i + 1]);
            if (!strcmp(argv[i], "--from")) from = @(argv[i + 1]);
        }
        if (!base) { printf("usage: ATLiteProbe --base <dir> --from <app|springboard>\n"); return 2; }

        NSString *logs = [base stringByAppendingPathComponent:@"logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logs
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *logPath = [logs stringByAppendingPathComponent:@"probe.log"];
        gOut = fopen(logPath.fileSystemRepresentation, "a");
        if (gOut) chmod(logPath.fileSystemRepresentation, 0666); // root 写 → mobile 读

        P(@"=== ATLiteProbe begin (from=%@) ===", from);
        probe_identity();
        // probe_hid();      // T4
        // probe_framebuffer(); // T5
        P(@"=== ATLiteProbe end ===");
        if (gOut) fclose(gOut);
    }
    return 0;
}
```

- 验证：本任务结束时**先不跑断言**（P4/P5 还没写，R32 仍会 FAIL，这是预期的）
- 注意：`@(argv[i+1])` 要求 argv 为合法 UTF-8；路径来自我们自己的代码，安全

---

### T4：probe/main.m —— P4 HID 注入
- 文件路径：`probe/main.m`（在 `probe_identity` 之后插入）
- 要做的（完整代码；参数与 `Tweak.xm` L289–306 逐参数一致，常量自定义名）：

```objc
// ---- P4：root 下能否注入一次触摸 ----
typedef struct __ATIOHIDEvent *ATEventRef;
typedef struct __ATIOHIDClient *ATClientRef;
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

enum { AT_TRANSDUCER_HAND = 3 };
enum { AT_EV_RANGE = 0x00000001, AT_EV_TOUCH = 0x00000002, AT_EV_POSITION = 0x00000004 };
#define AT_FIELD_IS_DISPLAY_INTEGRATED 0x000B0019
#define AT_FIELD_MAJOR_RADIUS          0x000B0014
#define AT_FIELD_MINOR_RADIUS          0x000B0015

static void probe_hid(void) {
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!io) { P(@"PROBE_P4 FAIL dlopen IOKit: %s", dlerror()); return; }
    _ATClientCreate   = dlsym(io, "IOHIDEventSystemClientCreate");
    _ATClientDispatch = dlsym(io, "IOHIDEventSystemClientDispatchEvent");
    _ATCreateDigitizer= dlsym(io, "IOHIDEventCreateDigitizerEvent");
    _ATCreateFinger   = dlsym(io, "IOHIDEventCreateDigitizerFingerEvent");
    _ATAppendEvent    = dlsym(io, "IOHIDEventAppendEvent");
    _ATSetInt         = dlsym(io, "IOHIDEventSetIntegerValue");
    _ATSetFloat       = dlsym(io, "IOHIDEventSetFloatValue");
    if (!_ATClientCreate || !_ATClientDispatch || !_ATCreateDigitizer || !_ATCreateFinger) {
        P(@"PROBE_P4 FAIL symbols missing"); return;
    }
    ATClientRef client = _ATClientCreate(kCFAllocatorDefault);
    if (!client) { P(@"PROBE_P4 FAIL client create returned NULL (euid=%d)", geteuid()); return; }

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
    _ATClientDispatch(client, hand);                       // down
    P(@"PROBE_P4 dispatched touchDown(160,300) euid=%d", geteuid());
    usleep(60000);
    ATEventRef hand2 = _ATCreateDigitizer(kCFAllocatorDefault, mach_absolute_time(),
        AT_TRANSDUCER_HAND, 0, 0, AT_EV_TOUCH, 0, 0, 0, 0, 0, 0, 0, true, 0);
    ATEventRef fg2 = _ATCreateFinger(kCFAllocatorDefault, mach_absolute_time(), 1, 2,
        (uint32_t)AT_EV_TOUCH, 160, 300, 0, 0, 0, 0, 0, 0);
    if (hand2 && fg2) {
        _ATAppendEvent(hand2, fg2, 0);
        _ATClientDispatch(client, hand2);                  // up
        P(@"PROBE_P4 dispatched touchUp");
    }
    P(@"PROBE_P4 verdict=DISPATCHED (以屏幕是否出现点击反馈为准)");
}
```

- 同时把 `main()` 里 `// probe_hid();` 的注释取消
- 验证：本任务结束时 R32 的 P4 那条应转 PASS

---

### T5：probe/main.m —— P5 抓屏（Framebuffer 主 + RenderDisplay 回退）
- 文件路径：`probe/main.m`（在 `probe_hid` 之后插入）
- 要做的（完整代码）：

```objc
// ---- P5：root 下能否直读主屏 layer surface；失败则回退 RenderDisplay ----
static int (*_ATFBOpen)(mach_port_t, task_t, unsigned int, ATFBConn *);
static int (*_ATFBGetLayerDefaultSurface)(ATFBConn, int, ATSurfaceRef *);
static ATSurfaceRef (*_ATSurfaceCreate)(CFDictionaryRef);
static size_t (*_ATSurfaceGetWidth)(ATSurfaceRef);
static size_t (*_ATSurfaceGetHeight)(ATSurfaceRef);
static void *(*_ATSurfaceGetBase)(ATSurfaceRef);
static int32_t (*_ATSurfaceLock)(ATSurfaceRef, uint32_t, uint32_t *);
static void (*_ATSurfaceUnlock)(ATSurfaceRef, uint32_t, uint32_t);
static int (*_ATRenderDisplay)(uint32_t, CFStringRef, ATSurfaceRef, uint32_t, uint32_t);

static void probe_framebuffer(void) {
    void *fb  = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
    void *ios = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    _ATSurfaceGetWidth  = ios ? dlsym(ios, "IOSurfaceGetWidth") : NULL;
    _ATSurfaceGetHeight = ios ? dlsym(ios, "IOSurfaceGetHeight") : NULL;
    _ATSurfaceGetBase   = ios ? dlsym(ios, "IOSurfaceGetBaseAddress") : NULL;
    _ATSurfaceLock      = ios ? dlsym(ios, "IOSurfaceLock") : NULL;
    _ATSurfaceUnlock    = ios ? dlsym(ios, "IOSurfaceUnlock") : NULL;

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
        if (kr2 == 0 && s && _ATSurfaceGetBase && _ATSurfaceGetWidth) {
            size_t w = _ATSurfaceGetWidth(s), h = _ATSurfaceGetHeight(s);
            uint32_t seed = 0;
            if (_ATSurfaceLock) _ATSurfaceLock(s, 0, &seed);
            uint8_t *p = (uint8_t *)_ATSurfaceGetBase(s);
            P(@"PROBE_P5 framebuffer %zux%zu first_pixel=%02x%02x%02x%02x",
              w, h, p ? p[0] : 0, p ? p[1] : 0, p ? p[2] : 0, p ? p[3] : 0);
            if (_ATSurfaceUnlock) _ATSurfaceUnlock(s, 0, seed);
            P(@"PROBE_P5 verdict=FRAMEBUFFER-OK");
            return;
        }
    }

    // 回退：AutoTouch 实证路径（调用方自建 IOSurface → RenderDisplay）
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    _ATSurfaceCreate = ios ? dlsym(ios, "IOSurfaceCreate") : NULL;
    _ATRenderDisplay = qc  ? dlsym(qc,  "CARenderServerRenderDisplay") : NULL;
    if (!_ATSurfaceCreate || !_ATRenderDisplay) {
        P(@"PROBE_P5 FAIL no fallback symbols"); return;
    }
    int w = 1170, h = 2532; // 仅探针用固定尺寸；真机以日志宽高为准判断合理性
    uint32_t argb = 0x41524742u;
    CFDictionaryRef props = (__bridge CFDictionaryRef)@{
        @"IOSurfaceIsGlobal":      @YES,
        @"IOSurfaceBytesPerElement": @4,
        @"IOSurfaceBytesPerRow":   @(w * 4),
        @"IOSurfaceWidth":         @(w),
        @"IOSurfaceHeight":        @(h),
        @"IOSurfacePixelFormat":   @(argb),
        @"IOSurfaceAllocSize":     @(w * h * 4),
    };
    ATSurfaceRef s = _ATSurfaceCreate(props);
    if (!s) { P(@"PROBE_P5 FAIL surface create NULL"); return; }
    int krr = _ATRenderDisplay(0, CFSTR("LCD"), s, 0, 0);
    P(@"PROBE_P5 fallback RenderDisplay kr=%d %zux%zu", krr,
      _ATSurfaceGetWidth ? _ATSurfaceGetWidth(s) : 0,
      _ATSurfaceGetHeight ? _ATSurfaceGetHeight(s) : 0);
    P(@"PROBE_P5 verdict=%@", krr == 0 ? @"FALLBACK-RENDERDISPLAY-OK" : @"BOTH-FAILED");
}
```

- 同时把 `main()` 里 `// probe_framebuffer();` 的注释取消
- 验证：R32 的 P5 那条应转 PASS；另外 `grep -c PROBE_P probe/main.m` 应为 3

---

### T6：根 Makefile 挂上子工程
- 文件路径：`Makefile`
- 把第 5 行 `SUBPROJECTS += tweak app` 改为 `SUBPROJECTS += tweak app probe`
- 验证：`grep SUBPROJECTS Makefile` 输出含 probe

---

### T7：postinst 给探针 setuid
- 文件路径：`layout/DEBIAN/postinst`
- 在 `uicache` 行**之前**插入（保持 vroot 路径写法，无 `/var/jb`、无 `/rootfs` 前缀）：

```sh
# roothide vroot：探针随 app bundle 安装，chmod u+s 让 App(mobile) spawn 后拿到 root。
# 实证：触动精灵 roothide(355) 版 postinst 同样对 TSDaemon 执行 chmod u+s。
# 失败不得阻塞安装（若 setuid 不生效，探针 P3 会打出 euid=NOT-ROOT，我们据此换方案）。
chmod u+s /Applications/ATLite.app/ATLiteProbe 2>/dev/null || true
```

- 验证：`grep -n "ATLiteProbe" layout/DEBIAN/postinst` 有输出

---

### T8：App 侧 P1 —— posix_spawn 跑探针并捕获输出
- 文件路径：`app/Source/ATLProbe.h`（新建）、`app/Source/ATLProbe.m`（新建）
- 要做的（`ATLProbe.h`）：

```objc
#import <Foundation/Foundation.h>
// 诊断探针：posix_spawn app bundle 内的 ATLiteProbe，捕获 stdout。
// 不用 NSTask（iOS 私有类），纯 POSIX + pipe，构建期即可发现类型问题。
NSString *ATLRunProbe(NSString *from);
```

- 要做的（`ATLProbe.m` 完整内容）：

```objc
#import "ATLProbe.h"
#import "ATLPaths.h"
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

NSString *ATLRunProbe(NSString *from) {
    NSString *exe = [NSBundle.mainBundle.bundlePath
                     stringByAppendingPathComponent:@"ATLiteProbe"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:exe]) {
        return [NSString stringWithFormat:@"PROBE_P1 FAIL 二进制缺失: %@", exe];
    }
    BOOL execOK = [fm isExecutableFileAtPath:exe];
    int fds[2];
    if (pipe(fds) != 0) return @"PROBE_P1 FAIL pipe() 失败";

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);

    char *argv[] = { (char *)"ATLiteProbe",
                     (char *)"--base", (char *)ATLBaseDir().UTF8String,
                     (char *)"--from", (char *)from.UTF8String, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe.fileSystemRepresentation, &fa, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        return [NSString stringWithFormat:
                @"PROBE_P1 FAIL posix_spawn rc=%d errno=%d (%s) exec=%@ path=%@",
                rc, rc, strerror(rc), execOK ? @"YES" : @"NO", exe];
    }

    NSMutableData *buf = [NSMutableData data];
    char tmp[4096]; ssize_t n;
    while ((n = read(fds[0], tmp, sizeof tmp)) > 0) [buf appendBytes:tmp length:(NSUInteger)n];
    close(fds[0]);
    int status = 0; waitpid(pid, &status, 0);

    NSString *out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    return [NSString stringWithFormat:
            @"PROBE_P1 spawn OK (pid=%d, status=%d, exec=%@)\n%@",
            pid, status, execOK ? @"YES" : @"NO", out];
}
```

- 验证：R32 的 "R32 App 侧用 posix_spawn" 与 "PROBE_P1" 两条应转 PASS

---

### T9：日志页加入口
- 文件路径：`app/Source/ATLLogViewController.m`
- 改动 1：第 3 行后加 `#import "ATLProbe.h"`
- 改动 2：在 `setToolbarItems:@[` 数组里，`stopItem` **之后**插入一项：

```objc
        [[UIBarButtonItem alloc] initWithTitle:@"诊断探针" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(runProbe)],
```

- 改动 3：在 `- (void)stopScript` 方法**之后**插入：

```objc
- (void)runProbe {
    self.text.text = @"正在运行诊断探针…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = ATLRunProbe(@"app");
        NSString *log = [ATLLogsDir() stringByAppendingPathComponent:@"probe.log"];
        NSData *d = [NSData dataWithContentsOfFile:log];
        NSString *file = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.text.text = [NSString stringWithFormat:@"%@\n\n---- probe.log ----\n%@",
                              out, file.length ? file : @"（无）"];
            self.text.textColor = [UIColor blackColor];
        });
    });
}
```

- 验证：`grep -n "ATLRunProbe" app/Source/ATLLogViewController.m` 有两处（import 不计则为调用处）

---

### T10：app Makefile 登记新文件
- 文件路径：`app/Makefile`
- 在 `ATLite_FILES = ...` 末尾追加 ` Source/ATLProbe.m`
- 验证：R32 最后一条（FILES 含 ATLProbe.m）转 PASS；且既有 R24 的 FILES 覆盖守卫仍绿

---

### T11：tweak 侧 P2 —— SpringBoard 内 spawn
- 文件路径：`tweak/Tweak.xm`
- 改动 1：在 `ATHandleCommand` 的 `stop` 分支之后、`run` 分支之前插入：

```objc
    // 阶段 0 探针 P2：SpringBoard 内能否 spawn（B 模式保活的可行性判据）
    if ([action isEqualToString:@"probe"]) {
        if (!ATIsSpringBoard()) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { ATProbeSpawnFromSpringBoard(); }
        });
        return;
    }
```

- 改动 2：在 `ATHandleCommand` 函数**定义之前**（`ATIsSpringBoard` 之后）插入实现：

```objc
// P2：SpringBoard 内 spawn 探针。只关心 rc/errno —— 这是 B 模式唯一悬空点。
// 与 App 侧共用同一份二进制，stdout 交给探针自己写 probe.log。
static void ATProbeSpawnFromSpringBoard(void) {
    NSString *exe = [[NSBundle mainBundle].bundlePath
                     stringByAppendingPathComponent:@"ATLiteProbe"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:exe]) { ATLog(@"PROBE_P2 FAIL 二进制缺失: %@", exe); return; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    char *argv[] = { (char *)"ATLiteProbe",
                     (char *)"--base", (char *)ATBaseDir().UTF8String,
                     (char *)"--from", (char *)"springboard", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe.fileSystemRepresentation, &fa, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    ATLog(@"PROBE_P2 spawn rc=%d errno=%d exec=%@ pid=%d path=%@",
          rc, rc, [fm isExecutableFileAtPath:exe] ? @"YES" : @"NO", pid, exe);
}
```

- **改动 0（必做，已核验当前缺失）**：`tweak/Tweak.xm` 第 23 行 `#import <sys/stat.h>` 之后追加两行：
  ```objc
  #import <spawn.h>
  #include <fcntl.h>
  ```
  （已核验：当前 import 区块只有 Foundation/UIKit/CoreFoundation/CoreGraphics/ImageIO/Vision/dlfcn/mach_time/sys/stat/time/math/stdlib，**没有 spawn.h 也没有 fcntl.h**，不加必然编译失败）
- 验证：R32 的 PROBE_P2 那条转 PASS

---

### T12：版本号 0.3.9 同步四处
- `control`：`Version: 0.3.8` → `0.3.9`
- `app/Resources/Info.plist`：`0.3.8` → `0.3.9`，`CFBundleVersion` `11` → `12`
- `tweak/Tweak.xm`：`v0.3.8` 三处（头注释 / luaL_traceback 文案 / ctor 日志）→ `v0.3.9`
- `tools/verify_static.py`：版本断言 `0.3.8` → `0.3.9`
- 验证：`grep -c "0\.3\.9" control app/Resources/Info.plist tweak/Tweak.xm tools/verify_static.py` 四个文件均 ≥1

---

### T13（GREEN）：全量静态套件 + RED 复验
- 验证 1：`python tools/verify_static.py` → **必须 0 FAIL**（当前 103 条 + R32 的 14 条）
- 验证 2（RED 复验，证明断言有效）：
  ```
  git stash && python tools/verify_static.py | grep -c FAIL && git stash pop
  ```
  或直接对 HEAD 版本跑断言脚本（沿用 E29/E30 的做法）：R32 组对 `git show HEAD:` 的旧代码必须**全部 FAIL**
- 验证 3：`tools/verify_artifact.py` 扩展两条断言（T15 产物验收用）：
  - deb 内 `./Applications/ATLite.app/ATLiteProbe` 存在
  - postinst 含 `chmod u+s`

---

### T14：CI 强化（构建纪律铁律第 2 条）
- 文件路径：`.github/workflows/build.yml`
- 改动 1：`Build package` 步骤的 `run:` 首行加 `set -x`（当前只有 Setup roothide scheme 步骤有 `set -ux`）
- 改动 2：在 `Build package` **之前**新增一步：

```yaml
      - name: Static assertions
        run: |
          set -x
          python3 tools/verify_static.py
```

- 改动 3：在 `Build package` 步骤 `make package` 之后追加产物就位断言：

```sh
          find .theos -name 'ATLiteProbe' -print
          test -n "$(find .theos -name 'ATLiteProbe' -print -quit)"
```

- 验证：推送后 CI 日志里能看到 `Static assertions` 步骤通过、且 `ATLiteProbe` 路径被打印

---

### T15：提交 → CI → 产物验收 → 部署 → 归档
- 提交信息要点：阶段 0 探针包（P1–P5），纯新增，不改现有行为
- CI 通过后：
  1. 下载产物 → `python tools/verify_artifact.py <deb>` 全过
  2. 补验二进制字符串（**双编码**：UTF-8 + UTF-16LE，clang `__ustring` 坑已踩三次）：
     `PROBE_P3` / `PROBE_P4` / `PROBE_P5` / `IOMobileFramebufferGetLayerDefaultSurface` / `CARenderServerRenderDisplay`
  3. 复制到局域网根 `ATLite_0.3.9_iphoneos-arm64e.deb`，`sed` 更新 `index.html`，`curl` 实测 HTTP 200
  4. `docs/ERRORS.md` 归档 E31（探针包）+ `docs/RESEARCH.md` 记 A/B 取证结论
- 验证：`curl -s -o /dev/null -w "%{http_code}" http://192.168.2.100:8088/ATLite_0.3.9_iphoneos-arm64e.deb` → 200

---

## 4. 真机验收步骤（交付给用户）

1. 装 v0.3.9（覆盖安装即可）
2. 打开 App → 日志页 → 确认 `v0.3.9 loaded` 与 `capture ready: YES (RenderDisplay, lock: YES)`（基线）
3. 点工具栏「诊断探针」→ 页面显示 `PROBE_P1 ...` + `---- probe.log ----` 内容
4. 回主界面点「运行并查看日志」跑一次 test.at，然后**再**从日志页发一次探针（走 SpringBoard 通道），日志里应出现 `PROBE_P2 spawn rc=...`
5. 把 `PROBE_P1` / `PROBE_P2` / `PROBE_P3` / `PROBE_P4` / `PROBE_P5` 五行回报给我

## 5. 结果如何决定下一步

| 结果 | 结论 | 动作 |
|---|---|---|
| P1 rc=0 且 P3 ROOT | A 模式成立，setuid 有效 | 默认模式可用 B，A 兜底 |
| P1 rc≠0 | App 侧 spawn 被拒 | 补 `persona-mgmt` + `posix_spawnattr_set_persona_uid_np` |
| P2 rc≠0 | SpringBoard 侧被拒 | 默认模式改为 `app`（放弃开机即活） |
| P3 NOT-ROOT | roothide 下 setuid 不生效 | 改由 tweak 以 SpringBoard 身份 spawn；或接受 mobile daemon（引擎外移仍根治卡死） |
| P4 dispatch 但屏幕无反应 | 缺 entitlement | 补 HID 相关 entitlement（先怀疑 `platform-application` 收紧了 IOKit） |
| P5 FRAMEBUFFER-OK | 阶段 2 抓屏走 Framebuffer | 无同步 IPC，E29/E30 那类风险彻底消失 |
| P5 两者都失败 | 抓屏留在 SpringBoard 转发 | 阶段 2 只搬 HID |

---

## 6. 本计划明确禁止

- **禁止**把探针装到 `/usr/bin`（tool.mk 默认路径，出 `/var/containers/Bundle` 会 EPERM）
- **禁止**在探针里使用 `NSTask`（iOS 私有）或 `system()`（iOS SDK 标 unavailable）
- **禁止**改现有抓屏 / 脚本 / 强停 / 日志链路的任何行为——探针是纯新增
- **禁止**在探针里做路径推导（一律由 `--base` 传入）
- **禁止**"改一处构建一次"：T1–T13 全部本地验证通过后，才推送触发 CI
