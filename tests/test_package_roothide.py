# -*- coding: utf-8 -*-
"""tools/package_roothide.py 的红测（T3，先红后绿）。

目标：把「上次靠临时命令手搓 deb」固化成可重复、可验证的脚本，
并如实报告哪些问题本地工具链修不了（D2 chained fixups）。
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
spec = importlib.util.spec_from_file_location('packer', ROOT / 'tools' / 'package_roothide.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def _ar(ctl, data, ctl_name='control.tar', data_name='data.tar'):
    out = b'!<arch>\n'
    for name, blob in [('debian-binary', b'2.0\n'), (ctl_name, ctl), (data_name, data)]:
        out += ('%-16s%-12s%-6s%-6s%-8s%-10d`\n' % (name, '0', '0', '0', '100644', len(blob))).encode()
        out += blob + (b'\n' if len(blob) & 1 else b'')
    return out


def _tar(files):
    s = io.BytesIO()
    with tarfile.open(fileobj=s, mode='w') as t:
        for name, data, uid, gid, mode, isdir in files:
            m = tarfile.TarInfo(name)
            m.size = 0 if isdir else len(data)
            m.mode, m.uid, m.gid = mode, uid, gid
            if isdir:
                m.type = tarfile.DIRTYPE
                t.addfile(m)
            else:
                t.addfile(m, io.BytesIO(data))
    return s.getvalue()


def _sample_deb():
    ctl = _tar([('./', b'', 501, 20, 0o755, True),
                ('./control', b'Package: me.atlite.ios\nVersion: 0.3.45\nArchitecture: iphoneos-arm64e\n', 501, 20, 0o644, False),
                ('./postinst', b'#!/bin/sh\nchmod 0755 /Applications/ATLite.app/ATLiteProbe\nexit 0\n', 501, 20, 0o755, False)])
    data = _tar([('./', b'', 1000, 1000, 0o755, True),
                 ('./Applications/', b'', 1000, 1000, 0o755, True),
                 ('./Applications/ATLite.app/ATLite', b'MACHOMAGIC' + b'\0' * 40, 1000, 1000, 0o755, False),
                 ('./Applications/ATLite.app/test.at', b'log("hi")\n', 1000, 1000, 0o644, False)])
    return _ar(ctl, data)


def _data_tar(deb_bytes):
    """从 deb 字节里取出 data.tar 的 TarInfo 列表与内容。"""
    from verify_roothide_layout import parse_ar, decompress
    members = parse_ar(deb_bytes)
    raw = decompress([v for k, v in members.items() if k.startswith('data.tar')][0])
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:*') as t:
        return [(m, t.extractfile(m).read() if m.isfile() else b'') for m in t.getmembers()]


def _thin_macho(fixups=0x22):
    """最小 thin Mach-O：老式 DYLD_INFO_ONLY + 无签名，用于让真门禁报 D1/D2。"""
    cmds = [
        struct.pack('<2I', 0x19, 72) + b'\0' * 64,
        struct.pack('<4I', fixups, 16, 0, 0),
        struct.pack('<6I', 0x32, 24, 2, 0x000e0000, 0x00100500, 0),
    ]
    body = b''.join(cmds)
    return (struct.pack('<8I', 0xfeedfacf, 0x100000c, 0x80000002, 6,
                        len(cmds), len(body), 0, 0) + body)


def _thin_macho_d2_only():
    """合法双哈希签名 + 老式 DYLD_INFO_ONLY：门禁只剩 D2 一个问题。"""
    blobs, index, body = [], b'', b''
    for kind, ht in ((0, 1), (4096, 2)):
        cd = struct.pack('>9I', 0xfade0c02, 48, 0x20400, 0, 0, 0, 0, 0, 0)
        cd += bytes([20 if ht == 1 else 32, ht, 0, 12]) + struct.pack('>2I', 0, 0)
        blobs.append((kind, cd))
    off = 12 + 8 * len(blobs)
    for kind, cd in blobs:
        index += struct.pack('>2I', kind, off + len(body))
        body += cd
    sig = struct.pack('>3I', 0xfade0cc0, off + len(body), len(blobs)) + index + body
    cmds = [
        struct.pack('<2I', 0x19, 72) + b'\0' * 64,
        struct.pack('<4I', 0x22, 16, 0, 0),
        struct.pack('<6I', 0x32, 24, 2, 0x000e0000, 0x00100500, 0),
        struct.pack('<4I', 0x1d, 16, 4096, len(sig)),
    ]
    cmds_body = b''.join(cmds)
    hdr = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0x80000002, 6,
                      len(cmds), len(cmds_body), 0, 0)
    return hdr + cmds_body + b'\0' * (4096 - len(hdr) - len(cmds_body)) + sig


def _deb_with_macho(blob, version='0.3.44'):
    ctl = _tar([('./control',
                 ('Version: %s\nArchitecture: iphoneos-arm64e\n' % version).encode(),
                 501, 20, 0o644, False)])
    data = _tar([('Applications/ATLite.app/ATLite', blob, 501, 20, 0o755, False)])
    return _ar(ctl, data)


class PackerContract(unittest.TestCase):
    def test_module_exists_with_repack_entrypoint(self):
        self.assertTrue(hasattr(mod, 'repack'), '缺打包入口')
        self.assertTrue(hasattr(mod, 'normalize_member'), '缺条目规范化')
        self.assertTrue(hasattr(mod, 'build_ar'), '缺 ar 组装')

    def test_dot_prefix_removed_and_owner_normalized(self):
        """D4：去 ./ 前缀、属主改 501:20，但内容与权限不能变。"""
        src = _sample_deb()
        dst = mod.repack(src, resign=False)
        entries = _data_tar(dst)
        names = [m.name for m, _ in entries]
        self.assertFalse(any(n.startswith('./') for n in names), names)
        self.assertEqual(b'', entries[0][1])
        self.assertEqual({(501, 20)}, {(m.uid, m.gid) for m, _ in entries})
        app = next(b for m, b in entries if m.name.endswith('/ATLite'))
        self.assertEqual(b'MACHOMAGIC' + b'\0' * 40, app)
        self.assertEqual(b'log("hi")\n', next(b for m, b in entries if m.name.endswith('test.at')))
        self.assertEqual(0o755, next(m.mode for m, _ in entries if m.name.endswith('/ATLite')))

    def test_control_keeps_version_and_postinst_executable(self):
        src = _sample_deb()
        dst = mod.repack(src, resign=False)
        from verify_roothide_layout import parse_ar, decompress
        members = parse_ar(dst)
        raw = decompress([v for k, v in members.items() if k.startswith('control.tar')][0])
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:*') as t:
            ctrl = t.extractfile('./control').read().decode()
            post = next(x for x in t.getmembers() if x.name.endswith('postinst'))
        self.assertIn('Version: 0.3.45', ctrl)
        self.assertIn('Architecture: iphoneos-arm64e', ctrl)
        self.assertTrue(post.mode & 0o111)

    def test_resign_is_invoked_for_macho_only(self):
        """重签只作用于 Mach-O，普通文件字节必须原样保留。"""
        calls = []

        def fake_resign(name, blob):
            calls.append((name, len(blob)))
            return blob + b'RESIGNED'

        src = _sample_deb()
        # 样本里的 'MACHOMAGIC' 不是真 Mach-O；换成合法 fat 头验证筛选逻辑
        fat = struct.pack('>2I', 0xcafebabe, 1) + struct.pack('>5I', 0x100000c, 0x80000002, 4096, 64, 14)
        fat += b'\0' * (4096 - 8 - 20) + b'\xcf\xfa\xed\xfe' + b'\0' * 60
        ctl = _tar([('./control', b'Package: me.atlite.ios\nVersion: 0.3.45\n', 501, 20, 0o644, False)])
        data = _tar([('./Applications/ATLite.app/ATLite', fat, 1000, 1000, 0o755, False),
                     ('./Applications/ATLite.app/test.at', b'log("hi")\n', 1000, 1000, 0o644, False)])
        dst = mod.repack(_ar(ctl, data), resign=fake_resign)
        self.assertEqual(1, len(calls), calls)
        self.assertIn('ATLite', calls[0][0])
        entries = _data_tar(dst)
        self.assertTrue(next(b for m, b in entries if m.name.endswith('/ATLite')).endswith(b'RESIGNED'))
        self.assertEqual(b'log("hi")\n', next(b for m, b in entries if m.name.endswith('test.at')))

    def test_repack_reports_unfixable_problems_truthfully(self):
        """D2 是链接器产物：必须用真 Mach-O 让门禁真的报出 D1/D2，
        不许靠报告里一句硬编码文本通过断言（旧版是恒绿假测试）。"""
        src = _deb_with_macho(_thin_macho())
        out, report = mod.repack_with_report(src, resign=False)
        self.assertTrue(hasattr(report, 'fixed'), '缺已修复清单')
        self.assertTrue(hasattr(report, 'remaining'), '缺剩余问题清单')
        self.assertTrue(any('D2' in p for p in report.remaining), report.remaining)
        self.assertTrue(any('D1' in p for p in report.remaining), report.remaining)
        # 输入本来就是无前缀 + 501:20，不能谎称修了 D4
        self.assertFalse(any('D4' in p for p in report.fixed), report.fixed)


class PackagingHardening(unittest.TestCase):
    """技能复查打回项（2026-11-07）：产出包必须真能被 dpkg 读，报告不许假绿。"""

    def test_output_ar_members_match_official_compression(self):
        """Critical：成员名带后缀且与内容 magic 一致，对齐官方 gz/lzma。"""
        from verify_roothide_layout import parse_ar
        from verify_artifact import compression_problems
        dst = mod.repack(_sample_deb(), resign=False)
        members = parse_ar(dst)
        self.assertIn('control.tar.gz', members, sorted(members))
        self.assertIn('data.tar.lzma', members, sorted(members))
        self.assertEqual([], compression_problems(members), sorted(members))

    def test_output_data_tar_is_lzma_alone_tar(self):
        """data.tar.lzma 必须是合法 LZMA_ALONE，解开后是合法 tar。"""
        from verify_roothide_layout import parse_ar, is_tar
        dst = mod.repack(_sample_deb(), resign=False)
        raw = parse_ar(dst)['data.tar.lzma']
        self.assertEqual(b'\x5d', raw[:1])
        self.assertTrue(is_tar(lzma.decompress(raw, format=lzma.FORMAT_ALONE)))

    def test_official_style_gz_lzma_input_is_supported(self):
        """输入为官方 .gz/.lzma 格式也能规范化（旧 _unpack 只认 XZ/GZIP/BZIP2/纯tar）。"""
        ctl = _tar([('./control', b'Version: 0.3.44\n', 501, 20, 0o644, False)])
        data = _tar([('Applications/ATLite.app/test.at', b'log("hi")\n', 501, 20, 0o644, False)])
        src = _ar(gzip.compress(ctl), lzma.compress(data, format=lzma.FORMAT_ALONE),
                  'control.tar.gz', 'data.tar.lzma')
        dst = mod.repack(src, resign=False)
        blobs = b''.join(b for _, b in _data_tar(dst))
        self.assertIn(b'log("hi")', blobs)

    def test_report_fixed_is_not_unconditionally_claimed(self):
        """没有实际修复时 fixed 不能声称 D1/D4 已修；恒绿文本必须移出 remaining。"""
        src = _deb_with_macho(_thin_macho())
        out, report = mod.repack_with_report(src, resign=False)
        self.assertFalse(any('D4' in p for p in report.fixed), report.fixed)
        self.assertFalse(any('D1' in p for p in report.fixed), report.fixed)
        self.assertTrue(hasattr(report, 'limitations'), '能力边界声明应独立成字段')
        # limitations 必须由真实门禁结果 + 真实 SDK 读数生成，不能靠硬编码恒绿
        self.assertTrue(any(p.startswith('D2') and '检测到' in p
                            for p in report.limitations), report.limitations)
        self.assertTrue(any(p.startswith('D3') and '16.5' in p
                            for p in report.limitations), report.limitations)

    def test_repack_never_swaps_in_foreign_binaries(self):
        """禁止把官方 0.3.44 的二进制塞进 0.3.45 包（版本混装）。
        取证：两包 OCR worker 的 ANE entitlements 完全一致，替换没有依据。"""
        src, dst = _sample_deb(), mod.repack(_sample_deb(), resign=False)
        src_entries, dst_entries = _data_tar(src), _data_tar(dst)

        def norm(n):
            while n.startswith('./'):
                n = n[2:]
            return n or '.'

        self.assertEqual([norm(m.name) for m, _ in src_entries],
                         [norm(m.name) for m, _ in dst_entries])
        self.assertEqual([b for _, b in src_entries], [b for _, b in dst_entries])

    def test_missing_ldid_raises_clear_runtime_error(self):
        """Windows 无 ldid 时不能把裸 FileNotFoundError 抛给调用方。"""
        with mock.patch('subprocess.run', side_effect=FileNotFoundError('ldid')):
            with self.assertRaises(RuntimeError) as ctx:
                mod.ldid_resign('ATLite', _thin_macho())
        self.assertIn('ldid', str(ctx.exception))

    def test_output_mode_returns_nonzero_when_d2_remains(self):
        """M3：退出码契约统一——门禁仍剩 D2 时，产出模式也必须非零（不把
        不合格包判成成功）。打包动作仍完成并写出文件，但结论是不合格。"""
        import contextlib
        import os
        import tempfile
        src = _deb_with_macho(_thin_macho_d2_only())
        with tempfile.TemporaryDirectory() as tmp:
            ip, op = os.path.join(tmp, 'in.deb'), os.path.join(tmp, 'out.deb')
            with open(ip, 'wb') as fh:
                fh.write(src)
            with contextlib.redirect_stdout(io.StringIO()):
                rc = mod.main(['--no-resign', ip, op])
            self.assertEqual(1, rc)
            self.assertTrue(os.path.exists(op))

    def test_check_mode_does_not_need_ldid(self):
        """--check 只跑门禁，不产出包，纯 Python 环境也应可用。"""
        import tempfile
        with tempfile.NamedTemporaryFile(suffix='.deb', delete=False) as fh:
            fh.write(_sample_deb())
            path = fh.name
        try:
            rc = mod.main(['--check', path])
            self.assertIsInstance(rc, int)
        finally:
            import os
            os.unlink(path)


if __name__ == '__main__':
    unittest.main()
