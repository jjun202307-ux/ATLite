#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
产物级验收器：直接拆解构建出来的 .deb，验证"真机上会发生什么"。

与 tools/verify_static.py 的分工：
  - verify_static.py  → 源码/配置层（构建前，零成本）
  - verify_artifact.py → 产物层（构建后，证明代码真的进了包）

用法：
    python tools/verify_artifact.py <path-to.deb>

注意（踩过的坑）：
  clang 对含非 ASCII 的 NSString 字面量会以 **UTF-16LE** 存进 __TEXT,__ustring 段，
  不是 UTF-8。检查中文文案时必须两种编码都试，否则会误判"功能没进包"。
"""
import io
import os
import sys
import tarfile
import struct
import plistlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_roothide_layout import parse_ar, decompress  # noqa: E402

FAILS = []
PASSES = []


def check(name, ok, detail=""):
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))
    (PASSES if ok else FAILS).append(name)


def in_blob(blob, s):
    """字符串是否出现在二进制中（UTF-8 或 UTF-16LE 任一命中）"""
    return s.encode("utf-8") in blob or s.encode("utf-16-le") in blob


def macho_slices(blob):
    """Read architectures and XML entitlements from load-command-referenced signatures."""
    def require(ok):
        if not ok:
            raise ValueError("invalid/truncated Mach-O")
    require(len(blob) >= 8)
    if blob[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", blob, 4)[0]
        require(0 < count <= 16 and len(blob) >= 8 + count * 20)
        result = []
        for i in range(count):
            cpu, subtype, offset, length, _ = struct.unpack_from(">5I", blob, 8 + i * 20)
            require(offset >= 8 + count * 20 and length > 0 and offset + length <= len(blob))
            slices = macho_slices(blob[offset:offset + length])
            require(len(slices) == 1 and slices[0]['cpu'] == cpu and slices[0]['subtype'] == subtype)
            result.extend(slices)
        return result
    require(len(blob) >= 32 and blob[:4] == b"\xcf\xfa\xed\xfe")
    _, cpu, subtype, filetype, count, size, _, _ = struct.unpack_from("<8I", blob)
    end = 32 + size
    require(end <= len(blob) and count <= size // 8)
    result = {'cpu': cpu, 'subtype': subtype, 'filetype': filetype, 'entitlements': {}}
    offset = 32
    for _ in range(count):
        require(offset + 8 <= end)
        cmd, length = struct.unpack_from("<2I", blob, offset)
        require(length >= 8 and offset + length <= end)
        if cmd == 0x1d:
            require(length >= 16)
            start, total = struct.unpack_from("<2I", blob, offset + 8)
            require(start >= end and start + total <= len(blob) and total >= 12)
            sig = blob[start:start + total]
            magic, slen, n = struct.unpack_from(">3I", sig)
            require(magic == 0xfade0cc0 and 12 <= slen <= total and n <= (slen - 12) // 8)
            for i in range(n):
                kind, pos = struct.unpack_from(">2I", sig, 12 + i * 8)
                require(pos >= 12 + n * 8 and pos + 8 <= slen)
                if kind == 5:
                    emagic, elen = struct.unpack_from(">2I", sig, pos)
                    require(emagic == 0xfade7171 and elen >= 8 and pos + elen <= slen)
                    result['entitlements'] = plistlib.loads(sig[pos + 8:pos + elen])
        offset += length
    require(offset == end)
    return [result]


def modern_arm64e(slice_info):
    """User-space, versioned ptrauth ABI required for iOS 14+ system injection.

    LLVM MachO.h: 0x80000000 versioned, 0x40000000 kernel, bits 27..24 version.
    Apple user-space ABI currently uses version 0 (full subtype 0x80000002).
    """
    subtype = slice_info['subtype']
    return (slice_info['cpu'] == 0x100000c and subtype & 0xffffff == 2
            and bool(subtype & 0x80000000) and not subtype & 0x40000000
            and (subtype >> 24) & 0xf == 0)


def main(deb_path):
    m = parse_ar(deb_path)
    ctl = tarfile.open(fileobj=io.BytesIO(
        decompress([v for k, v in m.items() if k.startswith("control.tar")][0])), mode="r:*")
    control = ctl.extractfile("./control").read().decode("utf-8", "replace")

    # 从文件名推断期望版本（me.atlite.ios_<ver>_iphoneos-arm64e.deb）
    base = os.path.basename(deb_path)
    ver = base.split("_")[1] if "_" in base else "?"

    check("Version=%s" % ver, ("Version: %s" % ver) in control)
    check("Architecture=iphoneos-arm64e", "Architecture: iphoneos-arm64e" in control)

    dt = tarfile.open(fileobj=io.BytesIO(
        decompress([v for k, v in m.items() if k.startswith("data.tar")][0])))
    names = dt.getnames()
    files = {x.name.lstrip("./"): x for x in dt.getmembers() if x.isfile()}
    for executable, kind in [('Applications/ATLite.app/ATLite', 2),
                             ('Applications/ATLite.app/ATLiteProbe', 2),
                             ('Applications/ATLite.app/ATLOCRWorker', 2),
                             ('Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib', 6)]:
        member = files.get(executable)
        check('executable present: ' + executable, member is not None and bool(member.mode & 0o111))
        if member and executable.endswith(('/ATLiteProbe','/ATLOCRWorker')):
            check('tool archive mode has no setuid/setgid: ' + executable, not member.mode & 0o6000)
        if member:
            try:
                slices = macho_slices(dt.extractfile(member).read())
                check('arm64 + arm64e: ' + executable,
                      len(slices) == 2 and {s['cpu'] for s in slices} == {0x100000c}
                      and {s['subtype'] & 0xffffff for s in slices} == {0, 2}
                      and all(s['filetype'] == kind for s in slices))
                if kind == 6:
                    check('SpringBoard tweak uses iOS14+ arm64e ABI',
                          any(modern_arm64e(s) for s in slices))
                if executable.endswith('/ATLOCRWorker'):
                    check('OCR worker contains device-verified ANE access', all('H11ANEInDirectPathClient' in s['entitlements'].get('com.apple.security.iokit-user-client-class',[]) for s in slices))
                if kind == 2:
                    need = ['platform-application', 'com.apple.private.security.no-sandbox']
                    if executable.endswith('/ATLite'):
                        need += ['com.apple.private.security.storage.AppBundles',
                                 'com.apple.private.security.storage.AppDataContainers']
                    check('signed entitlements true: ' + executable,
                          all(s['entitlements'].get(k) is True for s in slices for k in need))
            except (ValueError, struct.error, plistlib.InvalidFileException) as error:
                check('parse Mach-O: ' + executable, False, str(error))
    post = next((x for x in ctl if x.name.lstrip('./') == 'postinst'), None)
    check('postinst executable', post is not None and bool(post.mode & 0o111))
    if post:
        script = ctl.extractfile(post).read().decode('utf-8')
        check('probe not setuid by default', 'chmod 0755' in script and 'chmod u+s' not in script)

    # ---- roothide 布局（E22/R22）：无前缀 rootful 式 ----
    check("无前缀布局（无 rootfs/var/jb）", not any("rootfs" in n for n in names))
    check("App 在 ./Applications 下",
          any(n.lstrip("./").startswith("Applications/ATLite.app") for n in names))
    check("tweak 在 ./Library/MobileSubstrate/DynamicLibraries 下",
          any("Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib" in n for n in names))

    # ---- App 元数据 ----
    plist_members = [n for n in names if n.endswith("ATLite.app/Info.plist")]
    check("Info.plist 在位", bool(plist_members))
    if plist_members:
        pl = plistlib.loads(dt.extractfile(plist_members[0]).read())
        check("CFBundleExecutable==ATLite", pl.get("CFBundleExecutable") == "ATLite")
        check("版本 %s 与 Info.plist 一致" % ver, pl.get("CFBundleShortVersionString") == ver)

    check("test.at 随包", any(n.endswith("ATLite.app/test.at") for n in names))

    # ---- 图标 ----
    import struct as _st
    for fname, size in [("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180)]:
        mem = [n for n in names if n.endswith("ATLite.app/" + fname)]
        ok = False
        if mem:
            png = dt.extractfile(mem[0]).read()
            if png[:8] == b"\x89PNG\r\n\x1a\n":
                w, h = _st.unpack(">II", png[16:24])
                ok = (w, h) == (size, size)
        check("图标 %s %dx%d" % (fname, size, size), ok)

    # ---- entitlements（AutoTouch 实证四键）----
    appbin_members = [n for n in names if n.endswith("ATLite.app/ATLite")]
    check("App 二进制在位", bool(appbin_members))
    if appbin_members:
        blob = dt.extractfile(appbin_members[0]).read()
        need = ["platform-application", "com.apple.private.security.no-sandbox",
                "com.apple.private.security.storage.AppBundles",
                "com.apple.private.security.storage.AppDataContainers"]
        missing = [k for k in need if k.encode() not in blob]
        check("entitlements 四键嵌入", not missing, "缺%s" % missing)

        # ---- 新功能是否真的进了包（中文按 UTF-8/UTF-16 双查）----
        check("日志页进入二进制", in_blob(blob, "ATLLogViewController"))
        check("日志文件名进入二进制", in_blob(blob, "tweak.log"))
        check("日志诊断文案进入二进制", in_blob(blob, "诊断"))
        check("日志页标题进入二进制", in_blob(blob, "运行日志"))

    print()
    print("==== 产物验收: %s ====" % ("全过（%d 项）" % len(PASSES) if not FAILS
                                     else "FAIL: %s" % FAILS))
    return 1 if FAILS else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python tools/verify_artifact.py <deb 路径>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
