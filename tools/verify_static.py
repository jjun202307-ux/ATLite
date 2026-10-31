# -*- coding: utf-8 -*-
"""
ATLite 静态验证套件（superpowers TDD 的测试层）
================================================
本环境无法本地运行 iOS 代码，因此"测试" = 对源码与配置的可执行断言。
每条断言对应 docs/ERRORS.md 中一起【真实发生过的事故】，不是覆盖率装饰。

用法:
  python tools/verify_static.py [仓库根目录]
  退出码 0 = 全绿; 1 = 有失败（打印每条 FAIL 及对应错误编号）
"""
import os
import re
import sys
import plistlib

FAILS = []
PASSES = []


def check(rule, ok, detail=""):
    tag = "PASS" if ok else "FAIL"
    print("[%s] %s %s" % (tag, rule, detail))
    (PASSES if ok else FAILS).append(rule)


def read(root, rel):
    # 文件缺失返回空串而非抛异常：本工具要能跑在"旧版快照"上做 RED 实测
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        return ""
    with open(p, "rb") as f:
        return f.read().decode("utf8", "replace").replace("\r\n", "\n").replace("\r", "\n")


def strip_comments(src):
    """剥离 C 系注释（文档注释合法提及历史错误名，守卫只针对真实代码）"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def main(root):
    tweak_code = strip_comments(read(root, "tweak/Tweak.xm"))
    tweak = read(root, "tweak/Tweak.xm")

    # ---- R1/E1: dlsym 符号名必须带 Value 后缀；禁止裸 IOHIDEventSetInteger（代码层）----
    set_syms = re.findall(r'"(IOHIDEventSet[A-Za-z]+)"', tweak_code)
    check("R1-E1 setter符号名", set_syms and all(s.endswith("Value") for s in set_syms),
          str(set_syms))
    check("R1-E1 无裸SetInteger引用",
          not re.search(r'IOHIDEventSetInteger(?!Value)', tweak_code))

    # ---- R2/E2: 字段常量必须为四方验证值，禁 0x000B000B（代码层）----
    check("R2-E2 MajorRadius=0x000B0014", "0x000B0014" in tweak_code)
    check("R2-E2 MinorRadius=0x000B0015", "0x000B0015" in tweak_code)
    check("R2-E2 IsDisplayIntegrated=0x000B0019", "0x000B0019" in tweak_code)
    check("R2-E2 无BarrelPressure误用0x000B000B", "0x000B000B" not in tweak_code)

    # ---- R5/E5: finger 事件 typedef 必须是 13 参（12 个逗号）----
    m = re.search(r'_AT_IOHIDEventCreateDigitizerFingerEvent\)\(([^;]+);', tweak)
    finger_params = m.group(1).count(",") + 1 if m else -1
    check("R5-E5 finger typedef 13参", finger_params == 13, "实际=%d" % finger_params)

    # ---- R4/E4: finger 事件 index=finger+1、identity=2；hand 全 0 ----
    check("R4-E4 finger index+1 identity=2",
          bool(re.search(r'\(uint32_t\)\(finger \+ 1\),\s*2,\s*mask', tweak)))
    check("R4-E4 hand事件全0参考模式",
          "kIOHIDDigitizerTransducerTypeHand,\n        0, 0, kIOHIDDigitizerEventTouch, 0," in tweak)

    # ---- R29/E29: 抓屏 API 对齐 AutoTouch 实证（RenderDisplay + 自建 IOSurface）----
    # 实证：libATGraphic.iOS15.0.dylib 导入表只含 _CARenderServerRenderDisplay；
    # 旧版内部抓取 API（render server 分配 surface 返回）无任何实证且零文档。
    check("R29-E29 RenderDisplay 符号声明+dlsym",
          "_AT_CARenderServerRenderDisplay" in tweak and '"CARenderServerRenderDisplay"' in tweak)
    check("R29-E29 IOSurfaceCreate 自建表面",
          "_AT_IOSurfaceCreate" in tweak and '"IOSurfaceCreate"' in tweak)
    check("R29-E29 RenderDisplay 调用 (0,LCD,surface,0,0)",
          '_AT_CARenderServerRenderDisplay(0, CFSTR("LCD"), s, 0, 0)' in tweak)
    check("R29-E29 旧版抓取 API 字样完全消失", "CaptureDisplay" not in tweak)
    check("R29-E29 自建surface必需属性键",
          '"IOSurfaceIsGlobal"' in tweak and '"IOSurfaceAllocSize"' in tweak
          and '"IOSurfacePixelFormat"' in tweak and '"IOSurfaceBytesPerRow"' in tweak)
    check("R29-E29 渲染前写锁/解锁及后置只读锁",
          "_AT_IOSurfaceLock(s, 0, NULL)" in tweak and "_AT_IOSurfaceUnlock(s, 0, NULL)" in tweak
          and "_AT_IOSurfaceLock(s, 1" in tweak)
    check("R29-E29 屏幕像素尺寸惰性缓存(主线程取值)",
          "ATScreenPixelSize" in tweak and "dispatch_get_main_queue" in tweak)
    check("R29-E29 RenderDisplay void ABI", "static void (*_AT_CARenderServerRenderDisplay)" in tweak
          and "int kr = _AT_CARenderServerRenderDisplay" not in tweak)
    capture = tweak_code[tweak_code.find("static IOSurfaceRef ATRenderIntoNewSurface("):tweak_code.find("static IOSurfaceRef ATCaptureSurfaceWithTimeout(")]
    check("R29-E29 渲染后核验sentinel变化而非空分配",
          0 <= capture.find("memset(initial, 0xa5") < capture.find("_AT_CARenderServerRenderDisplay(0")
          < capture.find("BOOL written = ATCaptureWasWritten(")
          and "if (!written || unlockRC != 0)" in capture)

    check("R3-E3 无CreateServer残留", "CreateServer" not in tweak)

    # ---- R30/E30: 屏幕尺寸获取不得绕过看门狗原则（v0.3.7 复查 H1/H2）----
    # H1: dispatch_sync 主线程无超时 → 主线程卡死时脚本线程在渲染前就永久卡死，
    #     Lua 指令计数钩子/强停全部失效（线程堵在 C 层，钩子不触发）。
    # H2: 一次性 static 缓存 → 旋转后尺寸过期，搜图坐标全错。
    m30 = re.search(r'static CGSize ATScreenPixelSize\(void\) \{(.*?)\n\}', tweak_code, re.S)
    body30 = m30.group(1) if m30 else ""
    check("R30-E30 尺寸函数存在", bool(m30))
    check("R30-E30 尺寸获取带超时等待(与看门狗同构)",
          "dispatch_semaphore_wait" in body30 and "dispatch_time" in body30)
    check("R30-E30 尺寸无一次性缓存(旋转安全)", "static CGSize" not in body30)
    check("R30-E30 超时失败返回零尺寸(抓屏失败但不卡死)",
          "CGSizeZero" in body30 or "{0, 0}" in body30)

    # ---- R12/E12 + R13/E13: loslib 桩在 CI；精确警告豁免在 Makefile ----
    wf = read(root, ".github/workflows/build.yml")
    check("R12-E12 loslib system() 桩补丁在CI",
          "loslib" in wf.lower() and "system(cmd)" in wf)
    check("R13-E13 string-plus-int 精确豁免", "-Wno-error=string-plus-int" in read(root, "tweak/Makefile"))

    # ---- R14/E14: Vision SDK 兼容类别 ----
    check("R14-E14 VNRecognizedText类别", "VNRecognizedText (ATLiteSDKCompat)" in tweak)

    # ---- R17/E17: Extensions.lua v3 版本感知 ----
    check("R17-E17 v3标记", "ATLite Extensions.lua v3" in tweak)
    check("R17-E17 版本感知覆写+.bak", "needsWrite" in tweak and '".bak"' in tweak)

    # ---- R15/E15: 每个 app .m 导入其使用的自定义类头文件 ----
    for src, need in [
        ("app/Source/main.m", ['#import "ATLAppDelegate.h"']),
        ("app/Source/ATLRootViewController.m", ['#import "ATLRootViewController.h"']),
        ("app/Source/ATLAppDelegate.m", ['#import "ATLAppDelegate.h"']),
        ("app/Source/ATLWebServer.m", ['#import "ATLWebServer.h"']),
    ]:
        content = read(root, src)
        missing = [n for n in need if n not in content]
        check("R15-E15 %s 导入" % src, not missing, "缺%s" % missing)

    # ---- R16/E16: ifaddrs 必须带 struct 关键字 ----
    vc = read(root, "app/Source/ATLRootViewController.m")
    check("R16-E16 struct ifaddrs", "struct ifaddrs" in vc and "for (struct ifaddrs *" in vc)

    # ---- R6/E6: Info.plist 全硬编码、无 $( 占位符、可执行名==二进制名 ----
    plist_raw = read(root, "app/Resources/Info.plist")
    check("R6-E6 Info.plist 无占位符", "$(" not in plist_raw)
    try:
        pl = plistlib.loads(plist_raw.encode())
        check("R6-E6 CFBundleExecutable==ATLite", pl.get("CFBundleExecutable") == "ATLite",
              str(pl.get("CFBundleExecutable")))
    except Exception as e:
        check("R6-E6 Info.plist 可解析", False, str(e))
    app_mk = read(root, "app/Makefile")
    check("R6-E6 二进制名一致", "APPLICATION_NAME = ATLite" in app_mk)

    # ---- R7/E7: roothide 三要素 ----
    ctrl = read(root, "control")
    check("R7-E7 Architecture=iphoneos-arm64e", "iphoneos-arm64e" in ctrl)
    check("R7-E7 根级layout postinst", os.path.isfile(os.path.join(root, "layout/DEBIAN/postinst")))
    if os.path.isfile(os.path.join(root, "layout/DEBIAN/postinst")):
        pi = read(root, "layout/DEBIAN/postinst")
        check("R7-E7 postinst uicache+容错", "uicache" in pi and "|| true" in pi)
    check("R7-E7 CI 自制 roothide scheme 模块", "vendor/mod/roothide" in wf)
    check("R7-E7 CI vendor/lib 复制(R20/E20)", "vendor/lib/iphone/rootless" in wf)
    check("R19-E19 CI set -x 诊断", "set -ux" in wf or "set -x" in wf)
    check("R19-E19 CI 存在性断言", "test -f" in wf)
    check("R20-E20 CI 断言现代 libroot", 'test -f "$THEOS/lib/iphone/roothide/libroot.a"' in wf)
    check("ABI 使用 macOS Xcode 工具链", "runs-on: macos-15" in wf and "xcrun --sdk iphoneos clang --version" in wf
          and "iOSToolchain-x86_64.tar.xz" not in wf)
    check("ABI 链接不放过未定义符号", "undefined,dynamic_lookup" not in read(root, "tweak/Makefile"))

    # ---- R22/E22: roothide 包无前缀（官方实证布局），postinst 用 vroot 路径 ----
    check("R22-E22 CI 无 /rootfs/var/jb 前缀", "/rootfs/var/jb" not in wf)
    check("R22-E22 roothide package.mk 置空", ': > "$THEOS/vendor/mod/roothide/package.mk"' in wf)
    if os.path.isfile(os.path.join(root, "layout/DEBIAN/postinst")):
        pi = read(root, "layout/DEBIAN/postinst")
        check("R22-E22 postinst 用 vroot 路径",
              "/Applications/ATLite.app" in pi and "/rootfs/" not in pi)
    # Active-root resolution must not guess the first leftover .jbroot directory.
    app_paths = strip_comments(read(root, "app/Source/ATLPaths.m"))
    for side, code in [("tweak", tweak_code), ("app", app_paths)]:
        check("R22-E22 %s 当前libroot且不枚举猜根" % side,
              'libroot_get_jbroot_prefix' in code
              and 'hasPrefix:@".jbroot-"' not in code
              and 'isDirectory:' in code)

    # ---- R8/E8: filter plist 命名 == TWEAK_NAME ----
    check("R8-E8 ATLiteTweak.plist 在位",
          os.path.isfile(os.path.join(root, "tweak/ATLiteTweak.plist")))

    # ---- R9/E9: 自检脚本随包发布 + 首启复制逻辑 ----
    check("R9-E9 test.at 在 app Resources",
          os.path.isfile(os.path.join(root, "app/Resources/test.at")))
    check("R9-E9 App 首启复制 test.at 逻辑",
          "test.at" in vc and "copy" in vc.lower())

    # ---- 评审修复守卫（两段式评审 M1/M2）----
    check("M1 ARGB绿通道修正(gIdx)", "gIdx" in tweak_code and "AT_FMT_ARGB" in tweak_code)
    check("M2 findText nil防御", "stringWithUTF8String:want" in tweak_code)
    check("M2 脚本运行try/finally防御", bool(re.search(r"static void ATPlayLuaFile\([^)]*\)\s*\{.*?@try\s*\{.*?@finally\s*\{", tweak_code, re.S)))
    check("M3 seed前建目录", "seedBundledScripts" in vc and
          vc.find("createDirectoryAtPath:ATLScriptsDir") < vc.find("copyItemAtPath:bundled"))

    # ---- v0.3.0 新规格（RESEARCH.md 取证驱动）----
    # I1: 图标声明（AutoTouch 实证键结构）
    pl_keys = plistlib.loads(plist_raw.encode())
    icons = pl_keys.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    check("I1 图标声明 CFBundleIconFiles", "AppIcon60x60" in icons.get("CFBundleIconFiles", []))
    check("I1 CFBundleIconName", icons.get("CFBundleIconName") == "AppIcon")

    # I2: 图标 PNG 真实存在且尺寸正确
    import struct as _st
    for fname, size in [("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180)]:
        p = os.path.join(root, "app/Resources", fname)
        ok = False
        if os.path.isfile(p):
            with open(p, "rb") as f:
                head = f.read(24)
            if head[:8] == b"\x89PNG\r\n\x1a\n":
                w, h = _st.unpack(">II", head[16:24])
                ok = (w, h) == (size, size)
        check("I2 %s %dx%d" % (fname, size, size), ok)

    # I3: entitlements 四个键（AutoTouch 二进制实证清单）
    ent_path = os.path.join(root, "app/entitlements.plist")
    if os.path.isfile(ent_path):
        ent = plistlib.load(open(ent_path, "rb"))
        need = ["platform-application", "com.apple.private.security.no-sandbox",
                "com.apple.private.security.storage.AppBundles",
                "com.apple.private.security.storage.AppDataContainers"]
        missing = [k for k in need if ent.get(k) is not True]
        check("I3 entitlements 四键全真", not missing, "缺%s" % missing)
    else:
        check("I3 entitlements.plist 存在", False)

    # I4: app/Makefile 带 entitlements 签名参数（rules.mk 实例级覆写机制）
    check("I4 CODESIGN_FLAGS 带 entitlements",
          "CODESIGN_FLAGS" in app_mk and "entitlements.plist" in app_mk)

    # I5: 点/像素归一化（AutoTouch getScreenScale 实证区分）
    check("I5 抓屏缩放归一化", "ATCaptureScale" in tweak_code)

    # I6: jbroot 以自身路径推导，探测为回退（tweak 侧 dladdr / app 侧 bundlePath）
    check("I6 tweak 侧 dladdr 推导 jbroot", "dladdr" in tweak_code)
    vc_code = strip_comments(vc)
    check("I6 app 侧 bundlePath 推导 jbroot",
          "mainBundle].bundlePath" in app_paths and "/Applications/ATLite.app" in app_paths)

    # C1/E21: dispatch_once block 内禁止 ATLog（ATLog→ATLogsDir→ATBaseDir→ATJBRoot 重入死锁）
    m_once = re.search(r"ATJBRoot\(void\)\s*\{(.*?)\n\}\n", tweak, flags=re.S)
    if m_once:
        once_body = m_once.group(1)
        blk = once_body[once_body.find("dispatch_once"):] if "dispatch_once" in once_body else once_body
        check("C1 once block 内无 ATLog", "ATLog" not in strip_comments(blk))
    else:
        check("C1 ATJBRoot 函数可定位", False)

    # Minor2: findText 输出与其余 API 统一 llround（禁 intValue 截断）
    check("Minor2 findText llround 统一",
          "llround(hits.lines[i].x+hits.lines[i].width/2)" in tweak_code and "x.intValue" not in tweak_code)

    # Minor1: 仅支持 iPhone，无 CFBundleIcons~ipad 段
    check("Minor1 无 CFBundleIcons~ipad", "CFBundleIcons~ipad" not in plist_raw)

    # ---- R23/E23: IP 状态行与导航栏不可见（真机截图实证）----
    appd = read(root, "app/Source/ATLAppDelegate.m")
    check("R23-E23 AppDelegate 包 UINavigationController",
          "UINavigationController" in appd and "initWithRootViewController" in appd)
    check("R23-E23 IP状态行作tableHeaderView（不被遮挡）", "tableHeaderView" in vc_code)
    check("R23-E23 不再自建table盖状态行", "[[UITableView alloc]" not in vc_code)

    # V: 版本三处同步
    check("V 版本0.3.17三处同步",
          "Version: 0.3.17" in ctrl and "<string>0.3.17</string>" in plist_raw and "v0.3.17" in tweak)

    # ---- R32: 阶段 0 探针包 v0.3.10（A/B 双模式可行性验证 P1-P5）----
    # 注意：本文件的 read() 是双参数 read(root, rel)；tweak 变量已在 main() 中定义
    probe_mk   = read(root, "probe/Makefile")
    root_mk    = read(root, "Makefile")
    probe_main = read(root, "probe/main.m")
    postinst   = read(root, "layout/DEBIAN/postinst")
    app_probe  = read(root, "app/Source/ATLProbe.m")
    logvc_raw  = read(root, "app/Source/ATLLogViewController.m")
    app_mk     = read(root, "app/Makefile")
    probe_ent  = read(root, "probe/entitlements.plist")

    check("R32 probe/Makefile 存在且用 tool.mk",
          "TOOL_NAME = ATLiteProbe" in probe_mk and "tool.mk" in probe_mk)
    check("R32 probe 安装路径为 app bundle（出界 exec 会 EPERM）",
          "ATLiteProbe_INSTALL_PATH = /Applications/ATLite.app" in probe_mk)
    check("R32 probe 自带 entitlements 且免 Killed:9",
          "platform-application" in probe_ent and "no-sandbox" in probe_ent)
    check("R32 根 Makefile 含 probe 子工程", "probe" in root_mk)
    check("R32 postinst 清除探针setuid默认部署",
          "chmod 0755 /Applications/ATLite.app/ATLiteProbe" in postinst and "chmod u+s" not in strip_comments(postinst))
    check("R32 P3 身份标记（euid 判据）", "PROBE_P3" in probe_main and "geteuid()" in probe_main)
    check("R32 P4 HID 注入探针",
          "PROBE_P4" in probe_main and "IOHIDEventSystemClientDispatchEvent" in probe_main)
    check("R32 P5 framebuffer入口未验证时明确unsupported",
          "PROBE_P5" in probe_main and "framebuffer entry=UNSUPPORTED" in probe_main
          and not re.search(r"_ATFBOpen\(0\s*,", strip_comments(probe_main)))
    check("R32 P5 RenderDisplay 回退路径", "CARenderServerRenderDisplay" in probe_main)
    check("R32 探针不依赖 SDK 私有类型",
          "ATSurfaceRef" in probe_main and "ATFBConn" in probe_main and "AT_TRANSDUCER_HAND" in probe_main)
    check("R32 探针stdout由App有界落盘",
          "fflush(stdout)" in probe_main and "probe-app.log" in app_probe
          and "AT_PROBE_MAX_OUTPUT" in app_probe and "ATLWriteDiagnosticResult(result, path" in app_probe
          and "createDirectoryAtPath:" in read(root, "app/Source/ATLFileIO.h"))
    check("R32 App 侧用 posix_spawn（禁私有 NSTask）",
          "posix_spawn" in app_probe and "NSTask" not in app_probe)
    check("R32 App 侧 P1 标记", "PROBE_P1" in app_probe)
    check("R32 tweak 侧 P2 标记", "PROBE_P2" in tweak)
    check("R32 tweak 已补 spawn.h/fcntl.h",
          "#import <spawn.h>" in tweak and "fcntl.h" in tweak)
    check("R32 日志页有探针入口", "ATLRunProbe" in logvc_raw)
    check("R32 app Makefile FILES 含 ATLProbe.m", "Source/ATLProbe.m" in app_mk)

    # ---- R33: Preserve prior failure coverage using the current stdout contract. ----
    # A: App terminal recognition is run/caller-specific. P2 remains explicitly
    # asynchronous and is inspected in tweak.log, never inferred from begin.
    check("R33-A P2不以begin或历史日志冒充完成",
          'containsString:@"from=springboard"' not in logvc_raw
          and 'P2' in logvc_raw and 'tweak.log' in logvc_raw
          and '未确认完成' in logvc_raw
          and 'run_id=%@ from=%@ PROBE_END' in app_probe)
    # B SpringBoard 侧 spawn 不传 --w/--h，回退 RenderDisplay 用硬编码 1170x2532，
    #   非该分辨率机型必失败 → 误判"P5 双失败"，污染阶段 2 决策。需自动重试多个尺寸。
    check("R33-B probe 回退多分辨率重试（不依赖调用方传尺寸）",
          "kATFallbackSizes" in probe_main
          and "AT_TRY_SIZES" in probe_main)
    # C SpringBoard 内 spawn 从不 waitpid → 每点一次留一个僵尸进程挂在 SpringBoard 名下
    #   非阻塞轮询使用同一所有者处理回收和超时；行为由原生测试验证。
    check("R33-C SpringBoard 侧回收子进程（禁 spawn 后不 reap）",
          "ATProbeReapPoll" in tweak and "waitpid(state->pid, &status, WNOHANG)" in tweak)
    # D: All surface readers must be guarded together before use.
    check("R33-D probe 抓屏读数三个符号全部判空",
          bool(re.search(r"if\s*\([^)]*!_ATSurfaceGetBase[^)]*!_ATSurfaceGetWidth[^)]*!_ATSurfaceGetHeight", strip_comments(probe_main))))
    # E: P2 diagnostics retain the existing shared log candidate mechanism.
    check("R33-E P2明确转到共享tweak日志候选路径",
          "ATLExistingLogPath" in logvc_raw and "ATLLogCandidatePaths" in logvc_raw
          and "P2" in logvc_raw and "tweak.log" in logvc_raw)
    # F App 侧阻塞 read(fds[0]) 无超时：若 probe 卡在 RenderDisplay 同步 IPC
    #   （正是 E25/E30 担心的死锁场景），后台线程永久阻塞且无法取消。违反 R30。
    check("R33-F App侧超时输出和有界回收并检查kill失败",
          "select(" in app_probe and "ATProbeNow() + 8.0" in app_probe
          and "killRC = kill(pid, SIGKILL)" in app_probe and "killError = killRC ? errno" in app_probe
          and "WNOHANG" in app_probe and "reapDeadline" in app_probe
          and not re.search(r"waitpid\([^;]+,\s*0\)", app_probe))
    check("R33-G 探针禁止任意特权路径写入",
          not re.search(r"\b(?:fopen|chmod|writeToFile)\s*[:(]", strip_comments(probe_main))
          and '"--base"' not in strip_comments(probe_main)
          and "NOT-ROOT diagnostic-limit" in probe_main)

    # ---- R24/E24: App 内可查看 tweak 日志（脚本"没反应"时的调试手段）----
    logvc_path = os.path.join(root, "app/Source/ATLLogViewController.m")
    check("R24-E24 日志页存在", os.path.isfile(logvc_path))
    if os.path.isfile(logvc_path):
        logvc = strip_comments(read(root, "app/Source/ATLLogViewController.m"))
        check("R24-E24 日志多路径探测(容忍jbroot差异)", "ATLExistingLogPath" in logvc)
        check("R24-E24 找不到日志时输出诊断", "诊断" in read(root, "app/Source/ATLLogViewController.m"))
        check("R24-E24 自动刷新便于看实时输出", "scheduledTimerWithTimeInterval" in logvc)
    check("R24-E24 导航栏有日志入口", "openLog" in vc_code and "ATLLogViewController alloc" in vc_code)
    check("R24-E24 路径模块已抽出共享", os.path.isfile(os.path.join(root, "app/Source/ATLPaths.m")))
    # 通用守卫：app/Source 下新增 .m 必须登记进 ATLite_FILES，否则链接期符号缺失
    import glob as _glob
    srcs = [os.path.basename(p) for p in _glob.glob(os.path.join(root, "app/Source", "*.m"))]
    missing_src = [s for s in srcs if ("Source/" + s) not in app_mk]
    check("R24 Makefile FILES 覆盖全部 Source/*.m", not missing_src, "漏登记%s" % missing_src)

    # ---- R25/E25: 系统级 hang 防护（脚本跑在 SpringBoard 进程内）----
    check("R25-A 抓屏带超时看门狗",
          "ATCaptureSurfaceWithTimeout" in tweak_code and "gCaptureBroken" in tweak_code)
    check("R25-A 抓屏超时后永久停用", "gCaptureBroken = YES" in tweak_code)
    check("R25-B 脚本执行时限钩子", "lua_sethook" in tweak_code and "ATLuaTimeoutHook" in tweak_code)
    play = tweak_code[tweak_code.find("static void ATPlayLuaFile("):]
    check("R25-B hook在bootstrap和用户chunk执行前装配",
          0 <= play.find("lua_sethook(") < play.find("lua_pcall(")
          < play.find("ATExecuteLoadedChunk(L, extensions)") < play.find("ATExecuteLoadedChunk(L, scriptPath)"))
    check("R25-B 用户chunk只文本加载并受pcall保护",
          bool(re.search(r'luaL_loadbufferx\([^;]+,\s*"t"\);\s*if\s*\(!status\)\s*status = lua_pcall', tweak_code, re.S))
          and "luaL_dostring" not in tweak_code and "luaL_dofile" not in tweak_code)
    check("R25-C HID 事件节流", "ATThrottleEvents" in tweak_code)

    # ---- R26/E26: 强停兜底（脚本跑在 SpringBoard，杀 App 无效）----
    check("R26-E26 tweak 侧停止代次", "gStopGeneration" in tweak_code and "gRunStopGeneration" in tweak_code)
    check("R26-E26 停止双通道(通知+flag文件)",
          "ATStopFlagPath" in tweak_code and "ATLReadStopFile" in tweak_code and "stopSnapshot" in tweak_code)
    check("R26-E26 hook 检查停止", "ATShouldStop" in tweak_code)
    check("R26-E26 sleep 分片可中断",
          tweak_code.count("ATShouldStop") >= 3)  # hook + usleep + msleep
    check("R26-E26 新脚本继承提交时停止快照", "gRunStopSnapshot" in tweak_code and "ATClearStopFlag" not in tweak_code)
    check("R26-E26 tweak 处理 stop 命令",
          'isEqualToString:@"stop"' in tweak_code)
    check("R26-E26 App 侧停止命令模块", os.path.isfile(os.path.join(root, "app/Source/ATLCommand.m")))
    check("R26-E26 App 主界面有停止入口", "stopScript" in vc_code)
    check("R26-E26 日志页有停止入口",
          "stopScript" in strip_comments(read(root, "app/Source/ATLLogViewController.m")))

    # ---- R27/E27: C 先声明后使用 —— 全量定义顺序守卫（v0.3.5/0.3.6 两次构建失败实证）----
    # 只检查"字符串存在"抓不到 undeclared identifier；必须对**所有** static 函数查顺序
    def _static_order_violations(src):
        lines = strip_comments(src).split("\n")
        defs = {}
        for i, l in enumerate(lines):
            m = re.match(r"\s*static\s+[A-Za-z_][\w\s\*<>]*?\b([A-Za-z_]\w*)\s*\(", l)
            if m:
                defs.setdefault(m.group(1), i)
        bad = []
        for name, d in defs.items():
            for i, l in enumerate(lines):
                if i == d:
                    continue
                if (name + "(") in l and not l.lstrip().startswith("static"):
                    if i < d:
                        bad.append("%s(定义L%d<使用L%d)" % (name, d + 1, i + 1))
                    break
        return bad

    for rel in ["tweak/Tweak.xm", "app/Source/ATLWebServer.m", "app/Source/ATLPaths.m",
                "app/Source/ATLCommand.m"]:
        v = _static_order_violations(read(root, rel))
        check("R27-E27 %s 无定义晚于使用" % rel, not v, str(v))

    # ---- 复查修复守卫（v0.3.5 debug 复查发现）----
    # 1) luaL_error 是 longjmp，必须发生在 @autoreleasepool 之外，否则破坏 autorelease 栈
    guard = re.search(r"static void ATCheckScript\([^)]*\)\s*\{(.*?)\n\}", tweak_code, re.S)
    hook = re.search(r"static void ATLuaTimeoutHook\([^)]*\)\s*\{(.*?)\n\}", tweak_code, re.S)
    check("复查-1 hook经ATCheckScript在pool外报错",
          bool(guard and hook and "ATCheckScript(L)" in hook.group(1)
               and re.search(r"@autoreleasepool\s*\{[^}]+\}\s*if\s*\(cancelled\)\s*luaL_error", guard.group(1), re.S)
               and "ATScriptExpired()" in guard.group(1)))
    admission = tweak_code.find("__sync_bool_compare_and_swap(&gRunningScripts, 0, 1)")
    check("复查-2 CAS拒绝并发脚本而非覆盖旧run",
          admission >= 0 and "previous script is still active" in tweak_code
          and "ATWaitForPreviousScripts" not in tweak_code)
    check("复查-2 finally原子释放运行槽",
          bool(re.search(r"@finally\s*\{.*?ATReleaseAllInputs\(\).*?lua_close\(L\).*?__sync_lock_test_and_set\(&gRunningScripts, 0\)", play, re.S)))
    check("复查-2 原子准入和停止快照发布发生在调度之前",
          admission >= 0 and admission < tweak_code.find("gRunStopSnapshot =", admission)
          < tweak_code.find("dispatch_async", admission) < tweak_code.find("ATPlayLuaFile(path)", admission))

    # ---- Lua 接线（编译正确性守卫）----
    check("Lua extern C 包裹", 'extern "C" {' in tweak and "<lua.h>" in tweak)
    check("Lua vendor 路径", "-Ilib/lua53" in read(root, "tweak/Makefile"))
    check("Lua 文件清单 wildcard", "ATLiteTweak_FILES" in read(root, "tweak/Makefile"))

    # ---- 汇总 ----
    print("\n==== %d PASS / %d FAIL ====" % (len(PASSES), len(FAILS)))
    if FAILS:
        print("失败规则: " + ", ".join(FAILS))
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
