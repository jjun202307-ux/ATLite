# -*- coding: utf-8 -*-
"""产物「真机可加载性」门禁的红测（T1，先红后绿）。

背景（2026-11-07）：本地 WSL 构建的 0.3.45 deb 通过旧版 38 项静态验收，
真机却 dyld 不加载。逐字节与官方 0.3.44（Xcode 构建、真机可加载）对比，
查出旧验收器完全没检查的 5 类差异：
  D1 签名：官方每个分片 slot0=SHA1 主 + slot4096=SHA256 备用；本地只有单 SHA256
  D2 链接：官方两分片都是 LC_DYLD_CHAINED_FIXUPS；本地 arm64 是老 DYLD_INFO_ONLY
  D3 SDK：官方 18.5 / 本地 16.5（记录差异，供构建溯源）
  D4 包元数据：官方无 ./ 前缀、属主 501:20；本地全带 ./、属主 1000:1000
  D5 封号标签：0.3.45 起必须是 UTF-16LE 编进 dylib
"""
import gzip
import importlib.util
import io
import lzma
import pathlib
import struct
import sys
import tarfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('artifact', ROOT / 'tools' / 'verify_artifact.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

OFFICIAL = ROOT.parent / 'atlite-0.3.44' / 'me.atlite.ios_0.3.44_iphoneos-arm64e.deb'
LOCAL_BAD = ROOT.parent / 'US-port' / 'ATLite_0.3.45_fixed_iphoneos-arm64e.deb'
DYLIB = 'Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib'


def _superblob(slots):
    """构造嵌入式签名 SuperBlob；slots = [(kind, hashType)]。"""
    blobs, index = [], b''
    for kind, ht in slots:
        # CodeDirectory: 9 个 uint32 + hashSize/hashType/platform/pageSize + spare2
        cd = struct.pack('>9I', 0xfade0c02, 48, 0x20400, 0, 0, 0, 0, 0, 0)
        cd += bytes([32 if ht == 2 else 20, ht, 0, 12]) + struct.pack('>2I', 0, 0)
        blobs.append((kind, cd))
    off = 12 + 8 * len(blobs)
    body = b''
    for kind, cd in blobs:
        index += struct.pack('>2I', kind, off + len(body))
        body += cd
    return struct.pack('>3I', 0xfade0cc0, off + len(body), len(blobs)) + index + body


def _thin(subtype=0x80000002, fixups=0x34, sig_slots=((0, 1), (4096, 2)),
          sdk=0x00120500):
    """构造一个最小 thin Mach-O：可指定重定位命令、签名槽位、LC_BUILD_VERSION.sdk。"""
    sig = _superblob(sig_slots)
    cmds = [
        struct.pack('<2I', 0x19, 72) + b'\0' * 64,          # LC_SEGMENT_64
        struct.pack('<4I', fixups, 16, 0, 0),               # fixups / dyld info
        struct.pack('<4I', 0x1d, 16, 4096, len(sig)),       # LC_CODE_SIGNATURE
        struct.pack('<6I', 0x32, 24, 2, 0x000e0000, sdk, 0),  # LC_BUILD_VERSION
    ]
    body = b''.join(cmds)
    hdr = struct.pack('<8I', 0xfeedfacf, 0x100000c, subtype, 6,
                      len(cmds), len(body), 0x100085, 0)
    return hdr + body + b'\0' * (4096 - 32 - len(body)) + sig


def _fat(slices):
    """slices = [(cpu, subtype, thin_bytes)]，分片按 4096 对齐，构造合法 fat 头。"""
    n = len(slices)
    out = bytearray(struct.pack('>2I', 0xcafebabe, n))
    # 每个分片留 8192 字节槽位（分片本体约 4096+签名），避免后一分片
    # 被前一分片覆盖导致 fat 表项偏移与实际不符。
    offsets = [4096 + i * 8192 for i in range(n)]
    for i, (cpu, sub, sl) in enumerate(slices):
        out += struct.pack('>5I', cpu, sub, offsets[i], len(sl), 12)
    for i, (_, _, sl) in enumerate(slices):
        out += b'\0' * (offsets[i] - len(out))
        out += sl
    return bytes(out)


def _good_fat():
    """官方结构：arm64(subtype=0) + arm64e(subtype=0x80000002) 两分片。"""
    return _fat([(0x100000c, 0, _thin(subtype=0)),
                 (0x100000c, 0x80000002,
                  _thin(subtype=0x80000002) + '封号'.encode('utf-16-le'))])


def _bad_fat():
    """畸形：第二表项 subtype=0，但分片头写的是 arm64e —— 38 项判不合格。"""
    sl = _thin(subtype=0x80000002)
    return _fat([(0x100000c, 0x80000002, sl),
                 (0x100000c, 0, sl)])


def _archive(files):
    s = io.BytesIO()
    with tarfile.open(fileobj=s, mode='w') as t:
        for name, data, uid, gid in files:
            m = tarfile.TarInfo(name)
            m.size, m.mode, m.uid, m.gid = len(data), 0o755, uid, gid
            t.addfile(m, io.BytesIO(data))
    return s.getvalue()


def _ar_bytes(members):
    """members = [(ar 成员名, bytes)]；严格按官方 ar header（%-16s 空格填充、无尾 /）。"""
    out = bytearray(b'!<arch>\n')
    for name, blob in members:
        out += ('%-16s%-12s%-6s%-6s%-8s%-10d`\n'
                % (name, '0', '0', '0', '100644', len(blob))).encode('ascii')
        out += blob + (b'\n' if len(blob) & 1 else b'')
    return bytes(out)


def _control_tar(control='Version: 0.3.45\nArchitecture: iphoneos-arm64e\n'):
    return _archive([('./control', control.encode(), 501, 20),
                     ('./postinst',
                      b'#!/bin/sh\nchmod 0755 /Applications/ATLite.app/ATLiteProbe\nexit 0\n',
                      501, 20)])


def _deb(entries, control='Version: 0.3.45\nArchitecture: iphoneos-arm64e\n',
         ctl_name='control.tar', data_name='data.tar', ctl_xform=None, data_xform=None):
    ctl, data = _control_tar(control), _archive(entries)
    if ctl_xform:
        ctl = ctl_xform(ctl)
    if data_xform:
        data = data_xform(data)
    return _ar_bytes([('debian-binary', b'2.0\n'), (ctl_name, ctl), (data_name, data)])


class SignatureGate(unittest.TestCase):
    def test_dual_hash_signature_is_required(self):
        """D1: 必须有 SHA1 主 + SHA256 备用两个 CodeDirectory。"""
        self.assertTrue(hasattr(mod, 'code_directory_slots'), '缺签名槽位解析器')
        self.assertEqual({0: 1, 4096: 2}, mod.code_directory_slots(_superblob([(0, 1), (4096, 2)])))
        self.assertEqual({0: 2}, mod.code_directory_slots(_superblob([(0, 2)])))

    def test_chained_fixups_required_on_every_slice(self):
        """D2: 两个分片都要 LC_DYLD_CHAINED_FIXUPS，老 DYLD_INFO_ONLY 判不合格。"""
        self.assertTrue(hasattr(mod, 'load_command_kinds'), '缺 load command 解析器')
        self.assertIn(0x34, mod.load_command_kinds(_thin(fixups=0x34)))
        self.assertNotIn(0x34, mod.load_command_kinds(_thin(fixups=0x22)))

    def test_gate_rejects_single_sha256_signature(self):
        """D1 硬门禁：单 SHA256 的包必须报出问题。"""
        self.assertTrue(hasattr(mod, 'loadability_gate'), '缺可加载性门禁')
        problems = mod.loadability_gate(io.BytesIO(_deb([])), _thin(sig_slots=((0, 2),)))
        self.assertTrue(any('SHA1' in p or 'sha1' in p for p in problems), problems)

    def test_gate_rejects_old_dyld_info_only(self):
        """D2 硬门禁：老式重定位必须报出问题。"""
        problems = mod.loadability_gate(io.BytesIO(_deb([])), _thin(fixups=0x22))
        self.assertTrue(any('chained' in p.lower() or 'FIXUPS' in p for p in problems), problems)


class PackageMetadataGate(unittest.TestCase):
    def test_gate_rejects_dot_prefix_and_wrong_owner(self):
        """D4: ./ 前缀与 1000:1000 属主必须被拦下。"""
        blob = _deb([('./' + DYLIB, _thin(), 1000, 1000)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        text = ' '.join(problems)
        self.assertIn('./', text, problems)
        self.assertTrue(any('1000' in p or '属主' in p for p in problems), problems)

    def test_gate_accepts_official_style_metadata(self):
        """D4 正样本：无 ./ 前缀 + 501:20 不应因元数据报错。"""
        blob = _deb([(DYLIB, _thin(), 501, 20)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertFalse([p for p in problems if '前缀' in p or '属主' in p], problems)


class BlockedLabelGate(unittest.TestCase):
    def test_blocked_label_must_be_in_dylib_as_utf16le(self):
        """D5: 0.3.45 起「封号」必须以 UTF-16LE 编进 dylib（UTF-8 会误判）。"""
        self.assertTrue(hasattr(mod, 'in_blob'), '缺双编码字符串检查')
        self.assertTrue(mod.in_blob('封号'.encode('utf-16-le'), '封号'))
        self.assertTrue(mod.in_blob('封号'.encode('utf-8'), '封号'))
        self.assertTrue(hasattr(mod, 'blocked_label_present'), '缺封号标签门禁')
        self.assertFalse(mod.blocked_label_present(_thin()))
        self.assertTrue(mod.blocked_label_present(_thin() + '封号'.encode('utf-16-le')))


class GateHardening(unittest.TestCase):
    """技能复查打回项（2026-11-07）：门禁不许再出现「自洽式假绿灯」。"""

    def test_ar_member_suffix_must_match_compression(self):
        """D4：无后缀成员塞 XZ 数据必须被拦（dpkg 按成员名后缀选解压器）。"""
        blob = _deb([(DYLIB, _thin(), 501, 20)],
                    ctl_xform=lambda b: lzma.compress(b),
                    data_xform=lambda b: lzma.compress(b))
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(any('后缀' in p or '压缩' in p for p in problems), problems)

    def test_official_style_gz_lzma_members_pass(self):
        """正样本：官方 control.tar.gz + data.tar.lzma 不能被压缩检查误伤。"""
        # 用真·fat 双分片（arm64 + arm64e），别再用单 thin 自证
        blob = _deb([(DYLIB, _good_fat(), 501, 20)],
                    ctl_name='control.tar.gz', data_name='data.tar.lzma',
                    ctl_xform=lambda b: gzip.compress(b),
                    data_xform=lambda b: lzma.compress(b, format=lzma.FORMAT_ALONE))
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertEqual([], problems, problems)

    def test_package_without_any_macho_is_rejected(self):
        """D0：包里一个 Mach-O 都没有，绝不允许全绿（上次事故的根因形态）。"""
        blob = _deb([('Applications/ATLite.app/test.at', b'log("hi")\n', 501, 20)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(any('Mach-O' in p or 'D0' in p for p in problems), problems)

    def test_malformed_inputs_return_problems_not_exceptions(self):
        """畸形/截断输入要报问题，不许把 struct.error / LZMAError 抛给调用方。"""
        cases = [
            b'not an ar archive',
            b'!<arch>\n' + b'X' * 40,
            _ar_bytes([('debian-binary', b'2.0\n'),
                       ('control.tar', b'\xfd7zXZ\x00garbage'),
                       ('data.tar', b'\xfd7zXZ\x00garbage')]),
            _ar_bytes([('debian-binary', b'2.0\n'),
                       ('control.tar', _control_tar()),
                       ('data.tar', _archive([(DYLIB, b'\xca\xfe\xba\xbe' + b'\0' * 8, 501, 20)]))]),
        ]
        for i, blob in enumerate(cases):
            with self.subTest(case=i):
                problems = mod.loadability_gate(io.BytesIO(blob), None)
                self.assertIsInstance(problems, list)
                self.assertTrue(problems, 'case %d 不应全绿' % i)

    def test_d5_enforced_from_control_version(self):
        """D5 必须从 control 的 Version 判定；0.3.45 缺封号标签要被拦。"""
        blob = _deb([(DYLIB, _thin(), 501, 20)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(any('封号' in p or 'D5' in p for p in problems), problems)

    def test_d5_not_applied_to_older_version(self):
        """0.3.44 不该被 0.3.45 的新标签要求误伤。"""
        blob = _deb([(DYLIB, _thin(), 501, 20)],
                    control='Version: 0.3.44\nArchitecture: iphoneos-arm64e\n')
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertFalse([p for p in problems if 'D5' in p or '封号' in p], problems)

    def test_invalid_control_version_is_reported(self):
        """control 缺合法 Version 不能静默跳过版本相关门禁。"""
        blob = _deb([(DYLIB, _thin(), 501, 20)],
                    control='Package: me.atlite.ios\nArchitecture: iphoneos-arm64e\n')
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(any('Version' in p for p in problems), problems)

    def test_owner_0_0_is_rejected(self):
        """官方包 63 个文件全是 501:20；放宽到 0:0 属于无依据放松。"""
        blob = _deb([(DYLIB, _thin() + '封号'.encode('utf-16-le'), 0, 0)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(any('属主' in p for p in problems), problems)


class GateBypassHardening(unittest.TestCase):
    """第二轮复查 Critical：门禁 API 不许被绕过，解析器不许自相矛盾。"""

    def test_sample_blob_cannot_bypass_with_garbage_deb(self):
        """C1：sample_blob 分支也必须校验 deb 本体，不能「垃圾 deb + 合法分片 = 全绿」。"""
        problems = mod.loadability_gate(b'not an ar at all', _thin())
        self.assertTrue(problems, '垃圾 deb 不该被 sample_blob 分支放行')

    def test_injected_members_cannot_mask_a_bad_deb(self):
        """C1：外部传入 members 不得覆盖待检 deb 的真实内容。"""
        bad = _deb([('./' + DYLIB, _thin(sig_slots=((0, 2),)), 1000, 1000)])
        good_members = {'debian-binary': b'2.0\n',
                        'control.tar': _control_tar(),
                        'data.tar': _archive([])}
        problems = mod.loadability_gate(io.BytesIO(bad), members=good_members)
        self.assertTrue(any('1000' in p or 'SHA1' in p or './' in p for p in problems),
                        '注入官方 members 不该把坏包洗成全绿：%s' % problems)

    def test_malformed_fat_header_is_rejected(self):
        """C2：fat 表项 cpu/subtype 与分片头不符，38 项判不合格，门禁也必须判不合格。"""
        blob = _deb([(DYLIB, _bad_fat(), 501, 20)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(any(p.startswith('D0') and ('结构' in p or '分片' in p)
                            for p in problems), problems)

    def test_valid_two_slice_fat_passes(self):
        """正样本：官方结构 arm64+arm64e 双分片 fat 必须能过门禁。"""
        blob = _deb([(DYLIB, _good_fat(), 501, 20)])
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertEqual([], problems, problems)

    def test_internal_bug_is_not_disguised_as_gate_problem(self):
        """M1：编程错误（NameError/TypeError）必须冒出来，不能被 except Exception
        伪装成 D0 让畸形输入红测恒绿。"""
        with mock.patch.object(mod, 'parse_ar', side_effect=NameError('TYPO_in_code')):
            with self.assertRaises(NameError):
                mod.loadability_gate(io.BytesIO(_deb([])), None)

    def test_unsupported_zstd_member_is_rejected(self):
        """M2：后缀/magic 一致但解包器不支持，不能算「格式合法」。"""
        problems = mod.compression_problems(
            {'data.tar.zst': b'\x28\xb5\x2f\xfd' + b'\0' * 100})
        self.assertTrue(problems, 'zstd 无依赖时必须报问题，不能假绿')

    def test_corrupt_gzip_payload_returns_problems_not_crash(self):
        """第三轮复查 Minor：gzip deflate 载荷损坏要报问题，不许 zlib.error 崩溃。"""
        good = bytearray(gzip.compress(_control_tar()))
        for i in range(12, min(len(good) - 8, 40)):
            good[i] ^= 0xff
        blob = _deb([(DYLIB, _good_fat(), 501, 20)],
                    ctl_name='control.tar.gz', ctl_xform=lambda b: bytes(good))
        problems = mod.loadability_gate(io.BytesIO(blob), None)
        self.assertTrue(problems, '损坏 gzip 必须报问题而不是抛异常')


class SdkReporting(unittest.TestCase):
    """D3：SDK 代际差异必须被记录，供构建溯源，不靠口头描述。"""

    def test_build_version_sdk_parsed(self):
        self.assertTrue(hasattr(mod, 'build_version_sdk'), '缺 LC_BUILD_VERSION.sdk 解析')
        self.assertEqual((18, 5), mod.build_version_sdk(_thin(sdk=0x00120500)))
        self.assertEqual((16, 5), mod.build_version_sdk(_thin(sdk=0x00100500)))

    def test_sdk_report_records_synthetic_deb(self):
        self.assertTrue(hasattr(mod, 'sdk_report'), '缺 D3 SDK 汇总报告')
        blob = _deb([(DYLIB, _thin(sdk=0x00100500), 501, 20)])
        info = mod.sdk_report(io.BytesIO(blob))
        self.assertTrue(any('16.5' in x for x in info), info)


@unittest.skipUnless(OFFICIAL.exists(), '官方 0.3.44 样本不在本机')
class RealSamples(unittest.TestCase):
    def test_official_xcode_deb_passes_loadability_gate(self):
        """正样本：真机验证可加载的官方包不能被误伤。"""
        problems = mod.loadability_gate(str(OFFICIAL), None)
        self.assertEqual([], problems, problems)

    @unittest.skipUnless(LOCAL_BAD.exists(), '本地坏包样本不在本机')
    def test_local_wsl_deb_is_rejected_by_loadability_gate(self):
        """负样本：上次装机失败的包必须被门禁拦下。"""
        problems = mod.loadability_gate(str(LOCAL_BAD), None)
        self.assertTrue(problems, '门禁没能拦住上次装不上的坏包')

    def test_d3_official_sdk_is_recorded(self):
        """D3 正样本：官方 Xcode 包的 SDK 18.5 要被如实记录下来。"""
        info = mod.sdk_report(str(OFFICIAL))
        self.assertTrue(any('18.5' in x for x in info), info)


if __name__ == '__main__':
    unittest.main()
