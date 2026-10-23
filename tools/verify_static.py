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
    with open(os.path.join(root, rel), "rb") as f:
        return f.read().decode("utf8", "replace")


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

    # ---- R3/E3: 抓屏签名 (0, LCD/Main, NULL)；无 CreateServer 残留 ----
    check("R3-E3 CaptureDisplay(LCD) 在位",
          '_AT_CARenderServerCaptureDisplay(0, CFSTR("LCD"), NULL)' in tweak)
    check("R3-E3 CaptureDisplay(Main)回退在位",
          '_AT_CARenderServerCaptureDisplay(0, CFSTR("Main"), NULL)' in tweak)
    check("R3-E3 无CreateServer残留", "CreateServer" not in tweak)

    # ---- R12/E12 + R13/E13: loslib 桩在 CI；精确警告豁免在 Makefile ----
    wf = read(root, ".github/workflows/build.yml")
    check("R12-E12 loslib system() 桩补丁在CI",
          "loslib" in wf.lower() and "system(cmd)" in wf)
    check("R13-E13 string-plus-int 精确豁免", "-Wno-error=string-plus-int" in read(root, "tweak/Makefile"))

    # ---- R14/E14: Vision SDK 兼容类别 ----
    check("R14-E14 VNRecognizedText类别", "VNRecognizedText (ATLiteSDKCompat)" in tweak)

    # ---- R17/E17: Extensions.lua v2 版本感知 ----
    check("R17-E17 v2标记", "ATLite Extensions.lua v2" in tweak)
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
    check("R20-E20 CI 断言 libroot_oldabi", "libroot_oldabi.a" in wf)

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
    check("M2 脚本运行@try防御", "@try { ATPlayLuaFile" in tweak_code)
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
          "mainBundle].bundlePath" in vc_code and "/Applications/ATLite.app" in vc_code)

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
          "llround(x.doubleValue)" in tweak_code and "x.intValue" not in tweak_code)

    # Minor1: 仅支持 iPhone，无 CFBundleIcons~ipad 段
    check("Minor1 无 CFBundleIcons~ipad", "CFBundleIcons~ipad" not in plist_raw)

    # V: 版本三处同步 0.3.0
    check("V 版本0.3.0三处同步",
          "Version: 0.3.0" in ctrl and "<string>0.3.0</string>" in plist_raw and "v0.3.0" in tweak)

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
