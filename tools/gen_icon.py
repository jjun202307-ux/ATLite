# -*- coding: utf-8 -*-
"""纯标准库生成 App 图标 PNG（无 PIL 依赖）。
设计：深蓝渐变圆角方形 + 白色同心圆"触点涟漪"（自动化点按的隐喻）。
iOS 会自行裁圆角，图要填满整个方形。
"""
import os
import struct
import zlib


def write_png(path, size):
    w = h = size
    cx, cy = w / 2.0, h / 2.0
    # 涟漪参数（随尺寸缩放）
    r_outer = size * 0.30
    r_mid = size * 0.20
    r_dot = size * 0.10

    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        for x in range(w):
            # 背景：顶部 #0A84FF → 底部 #0055D4 的纵向渐变
            t = y / (h - 1)
            r = int(0x0A * (1 - t) + 0x00 * t)
            g = int(0x84 * (1 - t) + 0x55 * t)
            b = int(0xFF * (1 - t) + 0xD4 * t)
            # 中心同心圆（白）：外圈半透明 → 中圈 60% → 圆心实心
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d < r_dot:
                r, g, b = 255, 255, 255
            elif d < r_mid:
                f = 0.72
                r = int(r * (1 - f) + 255 * f); g = int(g * (1 - f) + 255 * f); b = int(b * (1 - f) + 255 * f)
            elif d < r_outer:
                f = 0.40
                r = int(r * (1 - f) + 255 * f); g = int(g * (1 - f) + 255 * f); b = int(b * (1 - f) + 255 * f)
            raw += bytes((r, g, b))

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8bit RGB
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + \
          chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("%s %dx%d %d bytes" % (path, size, size, len(png)))


base = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "Resources")
write_png(os.path.join(base, "AppIcon60x60@2x.png"), 120)
write_png(os.path.join(base, "AppIcon60x60@3x.png"), 180)
