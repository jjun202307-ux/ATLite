#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
roothide deb 布局核验器（E22/R22 防复发的核心取证工具）

用途：从 roothide 官方源取 N 个真实 deb，统计 data.tar 内路径的前缀分布、
      dylib/App 安装目录、postinst 里写的路径形式，形成可复核的统计证据。

用法：
    python tools/verify_roothide_layout.py --samples 6        # 抓官方源样本核验
    python tools/verify_roothide_layout.py --deb path/to.deb  # 核验单个包

设计原则（debug-error-recovery 阶段 1/5）：
  - 结论必须来自"可重复运行的一条命令"，不接受单次人工观察
  - 样本量 >= 3，避免 n=1 的偶然证据
"""
import argparse
import io
import lzma
import os
import re
import struct
import sys
import tarfile
import urllib.request
from collections import Counter

REPO = "https://roothide.github.io"


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ATLite-layout-audit"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


XZ_MAGIC = b"\xfd7zXZ\x00"
GZIP_MAGIC = b"\x1f\x8b"
BZIP2_MAGIC = b"BZh"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"          # zstd 真正的 magic（旧版误写成 LZMA_ALONE 头）


def parse_ar(path_or_bytes):
    """解析 deb 的 ar 归档，返回 {成员名: bytes}。

    2026-11-07：加边界校验并改抛 ValueError。原来用 assert + 无校验切片，
    畸形输入会 AssertionError / 静默截断，让门禁「自洽式假绿灯」。
    """
    if isinstance(path_or_bytes, bytes):
        data = path_or_bytes
    else:
        with open(path_or_bytes, "rb") as fh:
            data = fh.read()
    if data[:8] != b"!<arch>\n":
        raise ValueError("不是 ar 归档")
    out, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        if hdr[58:60] != b"`\n":
            raise ValueError("ar 成员头损坏 @%d" % off)
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("ascii", "replace").strip())
        except ValueError:
            raise ValueError("ar 成员长度非法 @%d (%s)" % (off, name))
        if size < 0 or off + 60 + size > len(data):
            raise ValueError("ar 成员越界 @%d (%s)" % (off, name))
        out[name] = data[off + 60:off + 60 + size]
        off += 60 + size + (size & 1)
    if off < len(data):
        raise ValueError("ar 归档尾部有 %d 字节残缺数据" % (len(data) - off))
    return out


def is_tar(data):
    """未压缩 tar 的 ustar magic 位于偏移 257。"""
    return len(data) >= 512 and data[257:262] == b"ustar"


def unpack_member(raw):
    """按 magic 精确识别 deb 的 control.tar / data.tar 压缩格式。

    这是 verify_artifact.py、verify_roothide_layout.py、package_roothide.py
    的唯一解压入口（2026-11-07 技能复查要求消除三套不一致实现）：
      .xz    -> XZ          .gz  -> gzip
      .bz2   -> bzip2       .lzma / 无后缀但 LZMA_ALONE 头 -> FORMAT_ALONE
      无后缀 -> 必须是未压缩 tar
    zstd 无依赖，明确报错而不是被误判成 LZMA。
    """
    if raw[:6] == XZ_MAGIC:
        try:
            return lzma.decompress(raw, format=lzma.FORMAT_XZ)
        except lzma.LZMAError as exc:
            raise ValueError("XZ 成员损坏: %s" % exc)
    if raw[:2] == GZIP_MAGIC:
        import gzip
        import zlib
        try:
            return gzip.decompress(raw)
        except (OSError, EOFError, zlib.error) as exc:
            raise ValueError("gzip 成员损坏: %s" % exc)
    if raw[:4] == ZSTD_MAGIC:
        raise ValueError("zstd 压缩需要 zstandard 依赖，无法核验")
    # 纯 tar 必须先于 BZIP2 判定：合法 tar 的首文件名可能恰好以 "BZh" 开头，
    # 若按 magic 优先会把纯 tar 误当 bzip2（复查 N1）。
    if is_tar(raw):
        return raw
    if raw[:3] == BZIP2_MAGIC:
        import bz2
        try:
            return bz2.decompress(raw)
        except (OSError, EOFError, ValueError) as exc:
            raise ValueError("bzip2 成员损坏: %s" % exc)
    # 只剩 LZMA_ALONE：1B props + 4B dict + 8B uncompressed size。
    # 必须解出合法 tar 才接受，杜绝旧版「FORMAT_ALONE 盲试解出空流」的假成功。
    if len(raw) >= 13:
        try:
            out = lzma.decompress(raw, format=lzma.FORMAT_ALONE)
        except lzma.LZMAError:
            out = b""
        if is_tar(out):
            return out
    raise ValueError("无法识别的 tar 成员压缩格式（magic=%r）" % raw[:8])


def decompress(raw):
    """向后兼容别名；新代码请直接用 unpack_member()。"""
    return unpack_member(raw)


def get_member(members, prefix):
    for k, v in members.items():
        if k.startswith(prefix):
            return v
    return None


def audit_deb(blob, label):
    """返回单个包的审计结果 dict"""
    m = parse_ar(blob)
    res = {"label": label, "paths": [], "control": "", "scripts": {}, "arch": ""}

    ctl_raw = get_member(m, "control.tar")
    if ctl_raw:
        ctl = tarfile.open(fileobj=io.BytesIO(decompress(ctl_raw)))
        for n in ctl.getnames():
            base = os.path.basename(n)
            if base == "control":
                res["control"] = ctl.extractfile(n).read().decode("utf-8", "replace")
            elif base in ("postinst", "preinst", "postrm", "prerm", "extrainst_"):
                res["scripts"][base] = ctl.extractfile(n).read().decode("utf-8", "replace")
        am = re.search(r"^Architecture: (.+)$", res["control"], re.M)
        res["arch"] = am.group(1).strip() if am else "?"

    data_raw = get_member(m, "data.tar")
    if data_raw:
        dt = tarfile.open(fileobj=io.BytesIO(decompress(data_raw)))
        res["paths"] = dt.getnames()
    return res


def top_level(path):
    p = path.lstrip("./").lstrip("/")
    return p.split("/")[0] if p else ""


def repo_samples(count):
    txt = http_get(REPO + "/Packages").decode("utf-8", "replace")
    blocks = txt.split("\n\n")
    picked, seen_pkg = [], set()
    # 优先挑 arm64e + Tweaks/Applications/System 不同 Section，保证样本多样
    for want in ("Tweaks", "Applications", "System", "Utilities", "Development"):
        for b in blocks:
            if len(picked) >= count:
                break
            pkg = re.search(r"^Package: (.+)$", b, re.M)
            fn = re.search(r"^Filename: (.+)$", b, re.M)
            sec = re.search(r"^Section: (.+)$", b, re.M)
            if not (pkg and fn):
                continue
            if sec and sec.group(1) != want:
                continue
            if not fn.group(1).endswith("arm64e.deb"):
                continue
            if pkg.group(1) in seen_pkg:
                continue
            seen_pkg.add(pkg.group(1))
            picked.append((pkg.group(1), fn.group(1)))
        if len(picked) >= count:
            break
    # 若按 Section 挑不满，退化为顺序补足
    for b in blocks:
        if len(picked) >= count:
            break
        pkg = re.search(r"^Package: (.+)$", b, re.M)
        fn = re.search(r"^Filename: (.+)$", b, re.M)
        if pkg and fn and fn.group(1).endswith("arm64e.deb") and pkg.group(1) not in seen_pkg:
            seen_pkg.add(pkg.group(1))
            picked.append((pkg.group(1), fn.group(1)))
    return picked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=6)
    ap.add_argument("--deb", action="append", default=[])
    args = ap.parse_args()

    targets = []
    for d in args.deb:
        targets.append((os.path.basename(d), None, d))
    for pkg, fn in repo_samples(args.samples):
        targets.append((pkg, REPO + "/" + fn.lstrip("./"), None))

    results = []
    for label, url, local in targets:
        try:
            blob = open(local, "rb").read() if local else http_get(url)
            r = audit_deb(blob, label)
            r["url"] = url or local
            results.append(r)
            print("已抓取 %-42s arch=%-18s 路径数=%d" % (label, r["arch"], len(r["paths"])))
        except Exception as e:
            print("抓取失败 %s: %s" % (label, e), file=sys.stderr)

    if not results:
        raise SystemExit("无有效样本")

    print("\n" + "=" * 78)
    print("一、data.tar 顶层目录分布（判断有无前缀）")
    print("=" * 78)
    tl = Counter()
    for r in results:
        for p in r["paths"]:
            tl[top_level(p)] += 1
    for k, v in tl.most_common():
        flag = "  <== 前缀!" if k in ("rootfs", "var", "jb", "private") else ""
        print("  %-28s %4d%s" % (k, v, flag))

    print("\n" + "=" * 78)
    print("二、tweak dylib 与 .app 的安装目录")
    print("=" * 78)
    dylibs = Counter()
    apps = Counter()
    for r in results:
        for p in r["paths"]:
            lp = p.lower()
            if lp.endswith(".dylib"):
                dylibs[os.path.dirname(p.lstrip("./"))] += 1
            if "/Applications/" in p and p.count(".app") >= 1:
                m2 = re.search(r"(.*?\.app)", p)
                if m2:
                    apps[os.path.dirname(m2.group(1).lstrip("./"))] += 1
    for k, v in dylibs.most_common():
        print("  dylib 目录: %s  (%d)" % (k or ".", v))
    for k, v in apps.most_common():
        print("  .app  目录: %s  (%d)" % (k or ".", v))

    print("\n" + "=" * 78)
    print("三、维护者脚本里的路径写法")
    print("=" * 78)
    for r in results:
        for sname, body in r["scripts"].items():
            hits = sorted(set(re.findall(r"/(?:rootfs/)?var/jb[^\s\"']*|/[A-Za-z0-9_.-]*\.app|/Library/[^\s\"']*", body)))
            if hits:
                print("  [%s] %s" % (r["label"], sname))
                for h in hits[:6]:
                    print("        %s" % h)

    print("\n" + "=" * 78)
    print("四、Architecture 分布")
    print("=" * 78)
    for k, v in Counter(r["arch"] for r in results).most_common():
        print("  %-20s %d" % (k, v))

    prefix_hits = sum(v for k, v in tl.items() if k in ("rootfs", "var", "jb", "private"))
    print("\n>>> 结论：%d 个样本中，带安装前缀的路径条目 = %d" % (len(results), prefix_hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
