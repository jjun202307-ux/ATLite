import gzip, lzma, struct, sys

DEB = 'me.atlite.ios_0.1.0_iphoneos-arm64e.deb'
data = open(DEB, 'rb').read()

assert data[:8] == b'!<arch>\n'
pos = 8
members = {}
while pos < len(data):
    hdr = data[pos:pos + 60]
    if len(hdr) < 60:
        break
    name = hdr[0:16].decode().strip().rstrip('/')
    size = int(hdr[48:58].decode().strip())
    members[name] = data[pos + 60:pos + 60 + size]
    pos += 60 + size + (size % 2)

print("ar members:", list(members.keys()))
print("debian-binary:", members['debian-binary'].decode())

def list_tar(tar_bytes):
    pos = 0
    out = []
    while pos + 512 <= len(tar_bytes):
        blk = tar_bytes[pos:pos + 512]
        if blk == b'\0' * 512:
            break
        name = blk[0:100].decode().rstrip('\0')
        size = int(blk[124:136].decode().rstrip('\0 ') or '0', 8)
        out.append((name, size, blk[156:157].decode()))
        pos += 512 + ((size + 511) // 512) * 512
    return out

ctrl_key = 'control.tar.gz' if 'control.tar.gz' in members else 'control.tar.xz'
ctrl_tar = gzip.decompress(members['control.tar.gz']) if ctrl_key == 'control.tar.gz' else lzma.decompress(members['control.tar.xz'])
data_tar = lzma.decompress(members['data.tar.lzma']) if 'data.tar.lzma' in members else gzip.decompress(members['data.tar.gz'])

print("\n== control.tar 内容 ==")
for n, s, t in list_tar(ctrl_tar):
    print("  ", n, s)

# control 文件内容
for n, s, t in list_tar(ctrl_tar):
    if n.lstrip('./') == 'control':
        idx = ctrl_tar.find(n.encode())
        # 找内容: tar 头后跟内容
        hdr_pos = 0
        while hdr_pos + 512 <= len(ctrl_tar):
            blk = ctrl_tar[hdr_pos:hdr_pos + 512]
            if blk == b'\0' * 512:
                break
            nm = blk[0:100].decode().rstrip('\0')
            sz = int(blk[124:136].decode().rstrip('\0 ') or '0', 8)
            if nm.lstrip('./') == 'control':
                print("\n== control 文件 ==")
                print(ctrl_tar[hdr_pos + 512:hdr_pos + 512 + sz].decode('utf8', 'replace'))
                break
            hdr_pos += 512 + ((sz + 511) // 512) * 512

print("== data.tar 内容（安装路径） ==")
dy = None
for n, s, t in list_tar(data_tar):
    print("  ", n, s)
    if n.endswith('ATLiteTweak.dylib'):
        # 提取 dylib 内容
        hdr_pos = 0
        while hdr_pos + 512 <= len(data_tar):
            blk = data_tar[hdr_pos:hdr_pos + 512]
            if blk == b'\0' * 512:
                break
            nm = blk[0:100].decode().rstrip('\0')
            sz = int(blk[124:136].decode().rstrip('\0 ') or '0', 8)
            if nm == n:
                dy = data_tar[hdr_pos + 512:hdr_pos + 512 + sz]
                break
            hdr_pos += 512 + ((sz + 511) // 512) * 512

if dy:
    magic, narch = struct.unpack('>II', dy[:8])
    print(f"\n== dylib fat header: magic={hex(magic)} archs={narch} ==")
    for i in range(narch):
        cputype, cpusub, off, sz, align = struct.unpack('>IIIII', dy[8 + i * 20:28 + i * 20])
        print(f"  arch{i}: cputype={hex(cputype)} subtype={hex(cpusub)} size={sz}")
