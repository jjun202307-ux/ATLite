#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""roothide deb 规范化打包器（2026-11-07）。

背景：0.3.45 曾靠一串临时命令 `dpkg-deb -R / -b -Zxz` 手工重打包，
产出的包装到真机 dyld 不加载。与官方 Xcode 构建逐字节对比后，把能修的
部分固化成本脚本，避免下次再手搓。

能修（本地工具链范围内）：
  D1 代码签名：ldid -Hsha1 -Hsha256 重签，补 SHA1 主 + SHA256 备用 CodeDirectory
  D4 包元数据：去 data.tar 的 ./ 前缀、属主统一 501:20、保留 postinst 可执行位
  D4 压缩格式：对齐官方 0.3.44 的 control.tar.gz(GZIP) + data.tar.lzma(LZMA_ALONE)，
               ar 成员名后缀与内容 magic 一致（dpkg 按后缀选解压器）
  D5 封号标签：由源码编译决定，脚本只做检查不改二进制内容

**打包层不修、但构建层能修**：D2（LC_DYLD_CHAINED_FIXUPS）是链接参数产物。
2026-11-07 二次取证确认：本地 WSL 的 ld64-609 自带 `fixup_chains`，本地构建加
`export ADDITIONAL_LDFLAGS = -Wl,-fixup_chains` 重编即可让全部分片变成 0x34，
**不需要 macOS / Xcode / CI**。旧版注释写「只有官方 Xcode 能修」是错误结论，已更正。
D3（SDK 16.5 vs 官方 18.5）仍为工具链代际差异，只记录、不阻断。

**明确不做**：替换「官方 OCR worker」。2026-11-07 逐字节取证显示，官方 0.3.44
与本地 0.3.45 的 ATLOCRWorker 的 ANE entitlements 完全一致（都含
H11ANEInDirectPathClient）。把 0.3.44 的二进制塞进 0.3.45 包只会造成版本混装，
没有收益且有风险；改为核对 entitlements，缺失时报「需重新编译」。

用法：
    python3 tools/package_roothide.py <input.deb> <output.deb> [--no-resign]
    python3 tools/package_roothide.py --check <input.deb>      # 只跑门禁，不产出包

重签依赖 ldid（Linux/WSL 可用）。--no-resign 用于纯 Python 环境下验证打包结构。
"""
import argparse
import gzip
import io
import lzma
import os
import plistlib
import struct
import sys
import tarfile
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_artifact import (  # noqa: E402
    loadability_gate, compression_problems, compression_kind, sdk_report, macho_slices,
)
from verify_roothide_layout import parse_ar, unpack_member  # noqa: E402

OFFICIAL_UID, OFFICIAL_GID = 501, 20
MACHO_MAGICS = (b'\xca\xfe\xba\xbe', b'\xcf\xfa\xed\xfe')
CONTROL_MEMBER, DATA_MEMBER = 'control.tar.gz', 'data.tar.lzma'


@dataclass
class RepackReport:
    # fixed / remaining 只放「真实发生的变化」和「真实门禁结果」；
    # 旧版把能力边界硬编码进 remaining，制造了恒绿假测试（复查打回项）。
    fixed: list = field(default_factory=list)
    remaining: list = field(default_factory=list)
    limitations: list = field(default_factory=list)

    def summary(self):
        lines = ['已修复：'] + ['  - ' + x for x in (self.fixed or ['无'])]
        lines += ['门禁仍未通过的问题：'] + ['  - ' + x for x in (self.remaining or ['无'])]
        lines += ['能力边界（打包层不改二进制，需构建参数 / 真机验收）：']
        lines += ['  - ' + x for x in (self.limitations or ['无'])]
        return '\n'.join(lines)


def normalize_member(name, uid, gid):
    """去 ./ 前缀（保留 control.tar 里根目录的 '.' 语义），属主对齐官方包。"""
    clean = name
    while clean.startswith('./'):
        clean = clean[2:]
    if clean == '':
        clean = '.'
    return clean, OFFICIAL_UID, OFFICIAL_GID


def build_ar(control_tar, data_tar):
    """按官方 0.3.44 实证结构组装 ar：control.tar.gz(GZIP) + data.tar.lzma(LZMA_ALONE)。

    dpkg 按 ar 成员名后缀选解压器，成员名必须与内容 magic 一致。
    旧版写 control.tar/ + XZ 内容 —— 自研解析器能读、dpkg 不能读，
    正是「包装出来了但装不上」的 Critical（2026-11-07 技能复查打回项）。
    """
    members = [
        ('debian-binary', b'2.0\n'),
        (CONTROL_MEMBER, gzip.compress(control_tar)),
        (DATA_MEMBER, lzma.compress(data_tar, format=lzma.FORMAT_ALONE)),
    ]
    out = bytearray(b'!<arch>\n')
    for name, blob in members:
        header = ('%-16s%-12s%-6s%-6s%-8s%-10d`\n'
                  % (name, '0', '0', '0', '100644', len(blob))).encode('ascii')
        out += header + blob + (b'\n' if len(blob) & 1 else b'')
    return bytes(out)


def _tar_bytes(entries):
    """entries = [(TarInfo, bytes)]，按官方顺序写 tar，保持权限位。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as out:
        for info, blob in entries:
            out.addfile(info, io.BytesIO(blob) if info.isfile() else None)
    return buf.getvalue()


def _unpack(raw):
    """统一走 verify_roothide_layout.unpack_member。

    旧版这里另写一套 magic 判断，和 verify_artifact.py 的 decompress() 行为不一致，
    是复查打回的「两套解压逻辑」问题；现在全项目只有一个解压入口。
    """
    return unpack_member(raw)


def ane_problems(entries):
    """核对 ATLOCRWorker 的 ANE entitlements，不替换任何二进制。

    取证：官方 0.3.44 与本地 0.3.45 的 OCR worker 均含 H11ANEInDirectPathClient，
    「替换官方 worker」没有依据，且会造成 0.3.44/0.3.45 版本混装。
    """
    problems = []
    for info, blob in entries:
        if not (info.isfile() and info.name.endswith('ATLOCRWorker')):
            continue
        try:
            slices = macho_slices(blob)
        except (ValueError, struct.error, plistlib.InvalidFileException) as exc:
            problems.append('D6 ATLOCRWorker 无法解析 entitlements: %s' % exc)
            continue
        for s in slices:
            classes = s['entitlements'].get('com.apple.security.iokit-user-client-class', [])
            if 'H11ANEInDirectPathClient' not in classes:
                problems.append('D6 ATLOCRWorker 缺 H11ANEInDirectPathClient（ANE 访问），'
                                '需重新编译；打包层不替换官方二进制')
                break
    return problems


def _read_tar(raw):
    with tarfile.open(fileobj=io.BytesIO(_unpack(raw)), mode='r:*') as src:
        return [(m, src.extractfile(m).read() if m.isfile() else b'') for m in src.getmembers()]


def _is_macho(blob):
    return blob[:4] in MACHO_MAGICS


def ldid_resign(name, blob):
    """双哈希重签一个 Mach-O，保留原有 entitlements。

    ldid -e 对无 entitlements 的二进制输出空文件，此时必须用裸 -S，
    否则 -S<空文件> 会报 `mmap: Invalid argument`（2026-11-07 实测）。
    """
    import subprocess
    import tempfile

    try:
        with tempfile.TemporaryDirectory(prefix='atl_resign_') as tmp:
            path = os.path.join(tmp, os.path.basename(name) or 'binary')
            with open(path, 'wb') as fh:
                fh.write(blob)
            ent = subprocess.run(['ldid', '-e', path], capture_output=True, check=False)
            ent_path = os.path.join(tmp, 'ent.xml')
            args = ['ldid', '-Hsha1', '-Hsha256']
            if ent.returncode == 0 and ent.stdout.strip():
                with open(ent_path, 'wb') as fh:
                    fh.write(ent.stdout)
                args.append('-S' + ent_path)
            else:
                args.append('-S')
            args.append(path)
            proc = subprocess.run(args, capture_output=True, check=False)
            if proc.returncode != 0:
                raise RuntimeError('ldid 重签 %s 失败: %s'
                                   % (name, proc.stderr.decode('utf-8', 'replace').strip()))
            with open(path, 'rb') as fh:
                return fh.read()
    except FileNotFoundError as exc:
        raise RuntimeError('未找到 ldid（%s）；请在 WSL/Linux 运行，'
                           '或使用 --no-resign 仅验证打包结构' % exc)


def repack_with_report(deb_bytes, resign=None):
    """规范化 deb，返回 (输出 deb 字节, RepackReport)。

    resign: None=不重签；False=不重签；可调用对象 (name, blob)->bytes；True=用 ldid_resign。
    """
    if resign is True:
        resign = ldid_resign
    elif not callable(resign):
        resign = None

    members = parse_ar(deb_bytes)
    ctl_raw = [v for k, v in members.items() if k.startswith('control.tar')][0]
    data_raw = [v for k, v in members.items() if k.startswith('data.tar')][0]
    ctl_entries, data_entries = _read_tar(ctl_raw), _read_tar(data_raw)
    report = RepackReport()
    resigned = []

    def transform(entries, strip_prefix):
        out = []
        for info, blob in entries:
            new_name, uid, gid = normalize_member(info.name, info.uid, info.gid)
            # 官方包的 control.tar 内部仍是 ./control / ./postinst；
            # 只有 data.tar 是无前缀布局，不能一刀切。
            if not strip_prefix:
                new_name = info.name
            dotted = new_name != info.name
            owned = (uid, gid) != (info.uid, info.gid)
            clone = tarfile.TarInfo(new_name)
            clone.mode = info.mode
            clone.uid, clone.gid = uid, gid
            clone.mtime = info.mtime
            clone.type = info.type
            clone.linkname = info.linkname
            clone.uname, clone.gname = '', ''
            if info.isfile() and _is_macho(blob) and resign is not None:
                blob = resign(new_name, blob)
                resigned.append(new_name)
            # 必须在重签之后按最终字节数写 size，否则变长签名会被 tar 截断
            clone.size = len(blob) if info.isfile() else 0
            out.append((clone, blob, dotted, owned))
        return out

    ctl_done, data_done = transform(ctl_entries, False), transform(data_entries, True)
    # fixed 只记「输入→输出真实发生的变化」，不无条件声称修好
    if any(d for _, _, d, _ in data_done):
        report.fixed.append('D4 去掉 data.tar 的 ./ 前缀（对齐官方无前缀布局）')
    if any(o for _, _, _, o in data_done):
        report.fixed.append('D4 data.tar 属主统一为 501:20（避免装机后变 1000:1000）')
    if resigned:
        report.fixed.append('D1 对 %d 个 Mach-O 执行 ldid -Hsha1 -Hsha256 重签'
                            '（补 SHA1 主 + SHA256 备用 CodeDirectory）' % len(resigned))

    ctl_tar = _tar_bytes([(i, b) for i, b, _, _ in ctl_done])
    data_tar = _tar_bytes([(i, b) for i, b, _, _ in data_done])
    out_deb = build_ar(ctl_tar, data_tar)

    # 产出包自检：ar 后缀↔magic 必须一致（旧版漏掉、dpkg 读不了的根因）
    suffix_issues = compression_problems(parse_ar(out_deb))
    if suffix_issues:
        raise RuntimeError('产出 deb 压缩格式自检失败: %s' % '；'.join(suffix_issues))

    # remaining 只放真实门禁结果，绝不塞硬编码文本制造假绿
    report.remaining = loadability_gate(io.BytesIO(out_deb))
    report.remaining.extend(ane_problems([(i, b) for i, b, _, _ in data_done]))

    # 能力边界单独成字段，且必须来自真实检测结果，不许靠硬编码恒绿（复查 M4）
    d2_hits = [p for p in report.remaining if p.startswith('D2')]
    report.limitations = []
    if d2_hits:
        report.limitations.append(
            'D2 检测到 %d 处（缺 chained fixups）；打包层不改二进制内容，'
            '需在本地 WSL 构建时加 -Wl,-fixup_chains 重编（不需要 macOS/Xcode/CI），'
            '详见 docs/本地构建修复与产物门禁_2026-11-07.md' % len(d2_hits))
    report.limitations.extend(sdk_report(io.BytesIO(out_deb)))
    report.limitations.append(
        '静态/产物门禁不能代替真机加载验证（BUILD_STATUS.md 既有纪律）；'
        '本脚本不做真机验证，过门禁也不等于可装机')
    report.limitations.append(
        'OCR worker 不替换：官方 0.3.44 与本地 0.3.45 的 ANE entitlements 一致，'
        '替换只会造成 0.3.44/0.3.45 版本混装')
    return out_deb, report


def repack(deb_bytes, resign=None):
    """便捷入口：只返回规范化后的 deb 字节。"""
    return repack_with_report(deb_bytes, resign=resign)[0]


def main(argv=None):
    ap = argparse.ArgumentParser(description='roothide deb 规范化打包 + 可加载性门禁')
    ap.add_argument('input', help='输入 deb')
    ap.add_argument('output', nargs='?', help='输出 deb')
    ap.add_argument('--no-resign', action='store_true', help='跳过 ldid 重签（纯结构验证）')
    ap.add_argument('--check', action='store_true', help='只跑门禁，不产出包')
    args = ap.parse_args(argv)

    with open(args.input, 'rb') as fh:
        raw = fh.read()
    if args.check:
        problems = loadability_gate(args.input)
        print('门禁问题（%d 条）：' % len(problems))
        for p in problems:
            print('  - ' + p)
        for line in sdk_report(args.input):
            print('[INFO] ' + line)
        return 1 if problems else 0

    if not args.output:
        ap.error('产出包时必须给 output 路径')
    try:
        out, report = repack_with_report(raw, resign=None if args.no_resign else True)
    except RuntimeError as exc:
        print('打包失败：%s' % exc, file=sys.stderr)
        print('提示：Windows 无 ldid 时请用 --no-resign 仅验证结构，或在 WSL 中运行。',
              file=sys.stderr)
        return 2
    with open(args.output, 'wb') as fh:
        fh.write(out)
    print('已写出 %s（%d 字节）' % (args.output, len(out)))
    print('ar 成员：%s(GZIP) + %s(LZMA_ALONE)，后缀与内容一致'
          % (CONTROL_MEMBER, DATA_MEMBER))
    print(report.summary())
    # 三处退出码契约统一（复查 M3）：验收器 / --check / 产出模式，
    # 只要门禁还有问题（含 D2）一律非零退出。D2 由构建阶段的链接参数修复，
    # 打包层无法在事后补；本地 WSL 产物加对开关后同样可以全绿。
    blocking = [p for p in report.remaining
                if p.startswith(('D0', 'D1', 'D2', 'D4', 'D5', 'D6'))]
    if blocking:
        print('结论：产物仍不合格（%d 条门禁问题），禁止装机；'
              '文件已写出仅供检查。' % len(blocking))
    return 1 if blocking else 0


if __name__ == '__main__':
    sys.exit(main())
