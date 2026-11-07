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
import lzma
import os
import re
import sys
import tarfile
import struct
import plistlib
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_roothide_layout import (  # noqa: E402
    parse_ar, unpack_member, is_tar,
    XZ_MAGIC, GZIP_MAGIC, BZIP2_MAGIC, ZSTD_MAGIC,
)

MACHO_MAGICS = (b'\xca\xfe\xba\xbe', b'\xcf\xfa\xed\xfe')

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
        if cmd & 0x7fffffff == LC_CODE_SIGNATURE:
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


# ---------------------------------------------------------------------------
# 真机可加载性门禁（2026-11-07）
#
# 事故背景：本地 WSL 构建的 0.3.45 deb 通过旧版 38 项静态验收，装到真机后
# tweak 不注入（无 "v0.3.45 loaded in"、8080 不通），A-B-A 对照确认是包本身。
# 与官方 Xcode 构建（真机可加载）逐字节对比，旧验收器漏掉以下硬差异：
#   D1 签名：官方每个分片 slot0=SHA1 主 + slot4096=SHA256 备用；本地只有单 SHA256
#   D2 链接：官方两分片都是 LC_DYLD_CHAINED_FIXUPS；本地 arm64 是老 DYLD_INFO_ONLY
#   D4 包元数据：官方 data.tar 无 ./ 前缀、属主 501:20；本地全带 ./、1000:1000
#   D5 封号标签：0.3.45 起必须以 UTF-16LE 编进 dylib（UTF-8 搜会误判）
# 这些断言不替代真机验证，但能在构建后立刻拦住「装不上」的包，避免白跑一次构建/装机。
# ---------------------------------------------------------------------------
LC_CHAINED_FIXUPS = 0x34          # LC_DYLD_CHAINED_FIXUPS (去掉 LC_REQ_DYLD 高位)
LC_CODE_SIGNATURE = 0x1d
LC_BUILD_VERSION = 0x32
CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0
CSMAGIC_CODEDIRECTORY = 0xfade0c02
HASH_SHA1, HASH_SHA256 = 1, 2
# 取证（2026-11-07）：官方 0.3.44 的 data.tar 63 个文件属主全是 501:20，
# 没有 0:0。旧版放宽到 (0,0) 无依据，收紧。
OFFICIAL_OWNERS = {(501, 20)}
DYLIB_NAME = 'Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib'
SUFFIX_TO_KIND = {'.xz': 'xz', '.gz': 'gz', '.bz2': 'bz2',
                  '.lzma': 'lzma', '.zst': 'zst', '': ''}


def strip_dot_prefix(name):
    """只剥路径前缀 ./；lstrip('./') 是字符集合剥离，会误伤以 . 或 / 开头的名字。"""
    while name.startswith('./'):
        name = name[2:]
    return name


def code_directory_slots(signature):
    """解析嵌入式签名 SuperBlob，返回 {slot 编号: hashType}。

    CodeDirectory 的 hashType 位于偏移 37（1=SHA1, 2=SHA256）。
    """
    try:
        if len(signature) < 12 or struct.unpack_from('>I', signature, 0)[0] != CSMAGIC_EMBEDDED_SIGNATURE:
            return {}
        count = struct.unpack_from('>I', signature, 8)[0]
        out = {}
        for i in range(min(count, 64)):
            if 12 + i * 8 + 8 > len(signature):
                break
            kind, pos = struct.unpack_from('>II', signature, 12 + i * 8)
            if pos + 40 > len(signature):
                continue
            if struct.unpack_from('>I', signature, pos)[0] != CSMAGIC_CODEDIRECTORY:
                continue
            out[kind] = signature[pos + 37]
        return out
    except (struct.error, IndexError):
        return {}


def load_command_kinds(slice_blob):
    """返回 thin Mach-O 分片的 load command 编号集合（去掉 LC_REQ_DYLD 高位）。"""
    try:
        if len(slice_blob) < 32 or slice_blob[:4] != b'\xcf\xfa\xed\xfe':
            return set()
        ncmds, sizeofcmds = struct.unpack_from('<2I', slice_blob, 16)
        out, off, end = set(), 32, min(32 + sizeofcmds, len(slice_blob))
        for _ in range(min(ncmds, 512)):
            if off + 8 > end:
                break
            cmd, cmdsize = struct.unpack_from('<2I', slice_blob, off)
            out.add(cmd & 0x7fffffff)
            if cmdsize < 8 or off + cmdsize > end:
                break
            off += cmdsize
        return out
    except struct.error:
        return set()


def fat_slice_blobs(blob):
    """把 fat / thin Mach-O 拆成 [(cpusubtype, slice_bytes), ...]。

    第二轮复查 C2：与 38 项验收器的 macho_slices() 同口径——分片必须是
    thin Mach-O，且 cpu/subtype 必须与 fat 表项一致；否则返回 [] 让门禁报 D0。
    """
    try:
        if len(blob) < 8:
            return []
        if blob[:4] == b'\xca\xfe\xba\xbe':
            count = struct.unpack_from('>I', blob, 4)[0]
            if not 0 < count <= 16 or len(blob) < 8 + count * 20:
                return []
            out = []
            for i in range(count):
                cpu, subtype, off, size, _ = struct.unpack_from('>5I', blob, 8 + i * 20)
                if size == 0 or off < 8 + count * 20 or off + size > len(blob):
                    return []
                sl = blob[off:off + size]
                if len(sl) < 32 or sl[:4] != b'\xcf\xfa\xed\xfe':
                    return []
                thin_cpu, thin_sub = struct.unpack_from('<2I', sl, 4)
                if thin_cpu != cpu or thin_sub != subtype:
                    return []
                out.append((subtype, sl))
            return out
        if blob[:4] == b'\xcf\xfa\xed\xfe':
            return [(None, blob)]
        return []
    except struct.error:
        return []


def signature_blob(slice_blob):
    """取分片的 LC_CODE_SIGNATURE 数据区（SuperBlob bytes）。"""
    try:
        if len(slice_blob) < 32 or slice_blob[:4] != b'\xcf\xfa\xed\xfe':
            return b''
        ncmds, sizeofcmds = struct.unpack_from('<2I', slice_blob, 16)
        off, end = 32, min(32 + sizeofcmds, len(slice_blob))
        for _ in range(min(ncmds, 512)):
            if off + 8 > end:
                break
            cmd, cmdsize = struct.unpack_from('<2I', slice_blob, off)
            if cmd & 0x7fffffff == LC_CODE_SIGNATURE and off + 16 <= len(slice_blob):
                start, total = struct.unpack_from('<2I', slice_blob, off + 8)
                if start >= end and start + total <= len(slice_blob):
                    return slice_blob[start:start + total]
                return b''
            if cmdsize < 8 or off + cmdsize > end:
                break
            off += cmdsize
        return b''
    except struct.error:
        return b''


def inspect_binary_loadability(blob, label='binary'):
    """检查单个 Mach-O 的签名与链接结构，返回问题列表。

    第二轮复查 C2：结构校验复用 38 项验收器的 macho_slices()，两套解析器
    不许互相矛盾——38 项判不合格的结构，本门禁也必须判不合格。
    """
    try:
        structural = macho_slices(blob)
    except (ValueError, struct.error, plistlib.InvalidFileException, IndexError) as exc:
        return ['D0 %s 结构校验失败（%s: %s），分片与 fat 表项不一致或截断'
                % (label, type(exc).__name__, exc)]
    if not structural:
        return ['D0 %s 解析不出任何分片' % label]
    slices = fat_slice_blobs(blob)
    if not slices or len(slices) != len(structural):
        return ['D0 %s 有 Mach-O magic 但解析不出合法分片（截断/畸形 fat 头）' % label]
    problems = []
    for subtype, sl in slices:
        tag = '%s[sub=0x%08x]' % (label, subtype) if subtype is not None else label
        kinds = load_command_kinds(sl)
        if LC_CHAINED_FIXUPS not in kinds:
            problems.append('D2 %s 缺 LC_DYLD_CHAINED_FIXUPS（本地老链接器 DYLD_INFO_ONLY），'
                            '两个分片加载路径与官方不一致' % tag)
        slots = code_directory_slots(signature_blob(sl))
        if slots.get(0) != HASH_SHA1 or slots.get(4096) != HASH_SHA256:
            problems.append('D1 %s 签名缺 SHA1 主 / SHA256 备用 CodeDirectory（实得 %s），'
                            'iOS 校验 ad-hoc 签名时会被拒' % (tag, slots or '无签名'))
    return problems


def blocked_label_present(blob):
    """0.3.45 起「封号」必须以 UTF-16LE 常量编进二进制。"""
    return '封号'.encode('utf-16-le') in blob


def compression_kind(raw):
    """ar 成员实际压缩格式：''=纯tar，xz/gz/bz2/lzma/zst，?=无法识别。"""
    if raw[:6] == XZ_MAGIC:
        return 'xz'
    if raw[:2] == GZIP_MAGIC:
        return 'gz'
    if raw[:4] == ZSTD_MAGIC:
        return 'zst'
    # 与 unpack_member() 保持同一判定顺序：纯 tar 先于 BZIP2（复查 N1/N7）
    if is_tar(raw):
        return ''
    if raw[:3] == BZIP2_MAGIC:
        return 'bz2'
    if len(raw) >= 13:
        try:
            if is_tar(lzma.decompress(raw, format=lzma.FORMAT_ALONE)):
                return 'lzma'
        except (lzma.LZMAError, ValueError):
            pass
    return '?'


def compression_problems(members):
    """D4：dpkg 按 ar 成员名后缀选解压器，后缀必须与内容 magic 一致。

    官方 0.3.44 实证：control.tar.gz(GZIP) + data.tar.lzma(LZMA_ALONE)。
    旧 build_ar() 写 control.tar/ + XZ 内容 —— 自研解析器能读、dpkg 不能读。
    """
    problems = []
    for name, raw in members.items():
        base = ('control.tar' if name.startswith('control.tar')
                else 'data.tar' if name.startswith('data.tar') else None)
        if base is None:
            continue
        suffix = name[len(base):].rstrip('/')
        if suffix not in SUFFIX_TO_KIND:
            problems.append('D4 ar 成员 %s 的后缀 %r 无法识别' % (name, suffix))
            continue
        expected, actual = SUFFIX_TO_KIND[suffix], compression_kind(raw)
        if actual == '?':
            problems.append('D4 ar 成员 %s 内容压缩格式无法识别' % name)
        elif actual != expected:
            problems.append('D4 ar 成员 %s 后缀(%s) 与内容(%s) 不一致，'
                            'dpkg 按后缀选解压器会失败'
                            % (name, expected or '无后缀/纯tar', actual))
        # M2：后缀/magic 一致还不够，内容必须真的能被统一解压入口解包。
        # 否则 zstd（缺依赖）这类「格式认得、解不开」会被判成合法假绿。
        try:
            unpack_member(raw)
        except (ValueError, OSError, EOFError, lzma.LZMAError, zlib.error) as exc:
            problems.append('D4 ar 成员 %s 内容无法解包（%s: %s）'
                            % (name, type(exc).__name__, exc))
    return problems


def control_version(ctl):
    """从 control.tar 读 Version，返回 ((major,minor,patch), 问题)。

    版本只认 control，不从 deb 文件名推断（改文件名就能绕过版本门禁）。
    """
    member = next((m for m in ctl.getmembers()
                   if m.isfile() and strip_dot_prefix(m.name) == 'control'), None)
    if member is None:
        return (), 'D4 control.tar 内缺 control 文件，无法判定版本相关门禁'
    try:
        text = ctl.extractfile(member).read().decode('utf-8', 'replace')
    except (OSError, tarfile.TarError) as exc:
        return (), 'D4 control 文件无法读取: %s' % exc
    mo = re.search(r'^Version:\s*(\d+)\.(\d+)\.(\d+)\s*$', text, re.M)
    if not mo:
        return (), 'D4 control 缺合法 Version（版本相关门禁不可静默跳过）'
    return tuple(int(x) for x in mo.groups()), ''


def build_version_sdk(slice_blob):
    """读 LC_BUILD_VERSION.sdk，返回 (major, minor)；解析不到返回 None。"""
    try:
        if len(slice_blob) < 32 or slice_blob[:4] != b'\xcf\xfa\xed\xfe':
            return None
        ncmds, sizeofcmds = struct.unpack_from('<2I', slice_blob, 16)
        off, end = 32, min(32 + sizeofcmds, len(slice_blob))
        for _ in range(min(ncmds, 512)):
            if off + 8 > end:
                break
            cmd, cmdsize = struct.unpack_from('<2I', slice_blob, off)
            if cmd & 0x7fffffff == LC_BUILD_VERSION and off + 20 <= len(slice_blob):
                sdk = struct.unpack_from('<I', slice_blob, off + 16)[0]
                return (sdk >> 16) & 0xffff, (sdk >> 8) & 0xff
            if cmdsize < 8:
                break
            off += cmdsize
    except struct.error:
        pass
    return None


def _deb_bytes(deb_source):
    if isinstance(deb_source, (bytes, bytearray)):
        return bytes(deb_source)
    if hasattr(deb_source, 'read'):
        return deb_source.read()
    with open(deb_source, 'rb') as fh:
        return fh.read()


# 只捕获「输入/解析」类异常。编程错误（NameError/TypeError/AttributeError）
# 必须冒出来，否则 except Exception 会把内部 bug 伪装成 D0，让畸形输入红测恒绿。
GATE_PARSE_ERRORS = (ValueError, tarfile.TarError, OSError, EOFError,
                     lzma.LZMAError, struct.error, IndexError, zlib.error,
                     plistlib.InvalidFileException, UnicodeError)


def sdk_report(deb_source):
    """D3：汇总包内 Mach-O 的 SDK 代际，返回信息串列表（只记录，不阻断）。

    官方 Xcode 18.5 / 本地 WSL 16.5 属链接器代际差异，打包层修不了，
    但必须如实记录，不能只在文档里口头描述。
    """
    try:
        ms = parse_ar(_deb_bytes(deb_source))
        parts = [v for k, v in ms.items() if k.startswith('data.tar')]
        if not parts:
            return ['D3 无 data.tar，无法读取 SDK']
        with tarfile.open(fileobj=io.BytesIO(unpack_member(parts[0])), mode='r:*') as dt:
            versions = set()
            for m in dt.getmembers():
                if not m.isfile():
                    continue
                try:
                    blob = dt.extractfile(m).read()
                except (OSError, tarfile.TarError):
                    continue
                if blob[:4] not in MACHO_MAGICS:
                    continue
                for _, sl in fat_slice_blobs(blob):
                    sdk = build_version_sdk(sl)
                    if sdk:
                        versions.add('%d.%d' % sdk)
        if not versions:
            return ['D3 未读到 LC_BUILD_VERSION.sdk，无法判断 SDK 代际']
        return ['D3 SDK=%s（官方 Xcode 基准 18.5；本地老 SDK 属链接器代际差异，'
                '打包层无法修复）' % '/'.join(sorted(versions))]
    except GATE_PARSE_ERRORS as exc:
        return ['D3 SDK 读取失败: %s: %s' % (type(exc).__name__, exc)]


def loadability_gate(deb_source, sample_blob=None, members=None):
    """返回真机可加载性问题列表；空列表表示通过。

    deb_source : deb 路径或含 deb 字节的 file-like
    sample_blob: 合成单测专用，只检查这一个 Mach-O；deb 本体仍必须是合法 ar
    members    : **已废弃，一律忽略**。第二轮复查 C1：外部注入 members 曾能把
                 坏包「洗」成官方包全绿；现在强制从 deb_source 重读。

    只捕获明确的解析异常并转成「不放行」；编程错误必须冒出来，不许被
    except Exception 伪装成 D0 让畸形输入红测恒绿（复查 M1）。
    """
    try:
        base_members = parse_ar(_deb_bytes(deb_source))
    except (OSError, ValueError) as exc:
        return ['D0 deb 无法读取/不是合法 ar 归档（%s: %s），门禁拒绝放行'
                % (type(exc).__name__, exc)]
    if not any(k.startswith('control.tar') for k in base_members) or \
       not any(k.startswith('data.tar') for k in base_members):
        return ['D4 deb 缺 control.tar / data.tar']
    if sample_blob is not None:
        return inspect_binary_loadability(sample_blob)
    try:
        problems = list(compression_problems(base_members))
        ctl_parts = [v for k, v in base_members.items() if k.startswith('control.tar')]
        data_parts = [v for k, v in base_members.items() if k.startswith('data.tar')]
        ctl = dt = None
        try:
            ctl = tarfile.open(fileobj=io.BytesIO(unpack_member(ctl_parts[0])), mode='r:*')
            dt = tarfile.open(fileobj=io.BytesIO(unpack_member(data_parts[0])), mode='r:*')
        except (tarfile.TarError, OSError, EOFError, ValueError,
                lzma.LZMAError, zlib.error) as exc:
            if ctl is not None:      # 复查 Minor-2：失败路径也要关掉已打开的 control.tar
                ctl.close()
            return problems + ['D4 deb 归档无法解包: %s: %s' % (type(exc).__name__, exc)]

        try:
            version, ver_issue = control_version(ctl)
            if ver_issue:
                problems.append(ver_issue)

            # D4：data.tar 路径前缀与文件属主（官方 Xcode 产物基准）
            file_members = [m for m in dt.getmembers() if m.isfile()]
            prefixed = [m.name for m in file_members if m.name.startswith('./')]
            if prefixed:
                problems.append('D4 data.tar 有 %d 个条目带 ./ 前缀（官方包为无前缀）' % len(prefixed))
            owners = {(m.uid, m.gid) for m in file_members}
            bad_owners = sorted(owners - OFFICIAL_OWNERS)
            if bad_owners:
                problems.append('D4 data.tar 属主 %s 不是 501:20（装机会变成 1000:1000）'
                                % ', '.join('%d:%d' % o for o in bad_owners))

            # D1 / D2：逐个可执行文件检查；统计 Mach-O 数量防「空包全绿」
            macho_count = 0
            for member in file_members:
                try:
                    blob = dt.extractfile(member).read()
                except (OSError, tarfile.TarError):
                    continue
                if blob[:4] in MACHO_MAGICS:
                    macho_count += 1
                    problems.extend(inspect_binary_loadability(blob, strip_dot_prefix(member.name)))
            if macho_count == 0:
                problems.append('D0 data.tar 内没有任何 Mach-O 可执行文件，'
                                '无法证明可加载（拒绝全绿）')

            # D5：0.3.45 起「封号」必须以 UTF-16LE 编进 tweak dylib。
            # 版本解析失败时按最严格处理，绝不静默跳过（复查 N2）。
            need_d5 = bool(ver_issue) or version >= (0, 3, 45)
            if need_d5:
                dylib = next((m for m in file_members
                              if strip_dot_prefix(m.name) == DYLIB_NAME), None)
                if dylib is None:
                    label = '%d.%d.%d' % version if version else '未知版本'
                    problems.append('D5 %s 需封号标签，但包内找不到 %s' % (label, DYLIB_NAME))
                else:
                    try:
                        ok = blocked_label_present(dt.extractfile(dylib).read())
                    except (OSError, tarfile.TarError):
                        ok = False
                    if not ok:
                        problems.append('D5 版本 >=0.3.45 但 dylib 内缺「封号」UTF-16LE 常量'
                                        '（源码有、编译没进包就是编译失败）')
            return problems
        finally:
            ctl.close()
            dt.close()
    except GATE_PARSE_ERRORS as exc:
        return ['D0 deb 解析失败（%s: %s），门禁拒绝放行' % (type(exc).__name__, exc)]


def main(deb_path):
    # main() 会在同一进程被反复调用（打包链路 / 测试），全局计数必须重入安全
    FAILS.clear()
    PASSES.clear()
    m = parse_ar(deb_path)
    ctl = tarfile.open(fileobj=io.BytesIO(
        unpack_member([v for k, v in m.items() if k.startswith("control.tar")][0])), mode="r:*")
    ctrl_member = next((x for x in ctl.getmembers()
                        if x.isfile() and strip_dot_prefix(x.name) == 'control'), None)
    control = (ctl.extractfile(ctrl_member).read().decode("utf-8", "replace")
               if ctrl_member else "")

    # 文件名版本只用于展示与原 38 项的「文件名 vs control」一致性检查；
    # 门禁判定一律以 control 里的权威版本为准（改文件名不能绕过 D5）。
    base = os.path.basename(deb_path)
    fname_ver = base.split("_")[1] if "_" in base else "?"
    ver = fname_ver
    ctrl_ver, ctrl_ver_issue = control_version(ctl)
    check("control Version 合法", bool(ctrl_ver) and not ctrl_ver_issue, ctrl_ver_issue)

    check("Version=%s" % ver, ("Version: %s" % ver) in control)
    check("Architecture=iphoneos-arm64e", "Architecture: iphoneos-arm64e" in control)

    dt = tarfile.open(fileobj=io.BytesIO(
        unpack_member([v for k, v in m.items() if k.startswith("data.tar")][0])))
    names = dt.getnames()
    files = {strip_dot_prefix(x.name): x for x in dt.getmembers() if x.isfile()}
    for executable, kind in [('Applications/ATLite.app/ATLite', 2),
                             ('Applications/ATLite.app/ATLiteProbe', 2),
                             ('Applications/ATLite.app/ATLOCRWorker', 2),
                             ('Applications/ATLite.app/ATLiteRegistration', 2),
                             ('Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib', 6)]:
        member = files.get(executable)
        check('executable present: ' + executable, member is not None and bool(member.mode & 0o111))
        if member and executable.endswith(('/ATLiteProbe','/ATLOCRWorker','/ATLiteRegistration')):
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
    post = next((x for x in ctl if strip_dot_prefix(x.name) == 'postinst'), None)
    check('postinst executable', post is not None and bool(post.mode & 0o111))
    if post:
        script = ctl.extractfile(post).read().decode('utf-8', 'replace')
        check('probe not setuid by default', 'chmod 0755' in script and 'chmod u+s' not in script)

    # ---- roothide 布局（E22/R22）：无前缀 rootful 式 ----
    check("无前缀布局（无 rootfs/var/jb）", not any("rootfs" in n for n in names))
    check("App 在 ./Applications 下",
          any(strip_dot_prefix(n).startswith("Applications/ATLite.app") for n in names))
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

    # ---- 真机可加载性门禁（2026-11-07，见本文件上方事故说明）----
    # 旧 38 项只查「文件在不在 / CPU 架构 / entitlements」，装不上的包照样全绿。
    # 门禁强制自己重读 deb，不接收外部 members（第二轮复查 C1）。
    gate_problems = loadability_gate(deb_path)
    check("可加载性门禁：签名/链接/包元数据", not gate_problems,
          "；".join(gate_problems[:4]) if gate_problems else "")

    # D5：0.3.45 起「封号」标签必须真的编进 dylib（UTF-16LE，UTF-8 搜会误判）。
    # 版本取自 control；解析失败按最严格处理，不静默跳过。
    dylib = files.get(DYLIB_NAME)
    if ctrl_ver_issue or ctrl_ver >= (0, 3, 45):
        check("封号标签 UTF-16LE 编进 dylib",
              bool(dylib) and blocked_label_present(dt.extractfile(dylib).read()))

    # D3：SDK 代际差异只记录、不阻断（链接器产物，打包层修不了）。
    for line in sdk_report(deb_path):
        print("[INFO] " + line)

    ctl.close()
    dt.close()
    print()
    print("==== 产物验收: %s ====" % ("全过（%d 项）" % len(PASSES) if not FAILS
                                     else "FAIL: %s" % FAILS))
    return 1 if FAILS else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python tools/verify_artifact.py <deb 路径>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
