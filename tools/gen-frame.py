#!/usr/bin/env python3
"""Pre-render the rounded frame drawn around the OTA progress dialog (see ota_frame in deploy/ota-engine.sh).
The update screen is always 640x480 (the Pi fallback forces it; text console 80x30 cells of 8x16 px), where whiptail's 72x14
dialog sits at x 32..608, y 128..352. The frame surrounds it with a 6 px margin: outer box x 24..616, y 116..364, radius 16,
line 3 px. Only the frame's pixels are ever written - the dialog interior belongs to whiptail - so the pieces are:
top band (16 rows, both corners and the top line), bottom band (16 rows), and the 3 px vertical stripe (left/right sides).
Raw pixels in both framebuffer formats (BGRX 32 bpp, RGB565 16 bpp little endian), composited on black.
    python3 tools/gen-frame.py"""
from PIL import Image, ImageDraw
import os
W, H, R, T = 592, 248, 16, 3
S = 4                                                    # supersampling for the anti-aliased arcs
LINE = (225, 225, 225)
big = Image.new("RGB", (W * S, H * S), (0, 0, 0))
ImageDraw.Draw(big).rounded_rectangle((0, 0, W * S - 1, H * S - 1), radius=R * S, outline=LINE, width=T * S)
img = big.resize((W, H), Image.LANCZOS)
parts = {
    "top": img.crop((0, 0, W, R)),
    "bottom": img.crop((0, H - R, W, H)),
    "stripe": img.crop((0, H // 2, T, H // 2 + 1)),     # left side; the right side is identical (mirror image, symmetric line)
}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kiosk", "files")
for name, part in parts.items():
    px = part.tobytes()
    bgrx = b"".join(bytes((px[i + 2], px[i + 1], px[i], 0xFF)) for i in range(0, len(px), 3))   # X byte non-zero: shell-safe, unused
    rgb565 = bytearray()
    for i in range(0, len(px), 3):
        v = ((px[i] >> 3) << 11) | ((px[i + 1] >> 2) << 5) | (px[i + 2] >> 3)
        rgb565 += bytes((v & 255, v >> 8))
    open(os.path.join(out, f"unitotem-frame-{name}.bgrx"), "wb").write(bgrx)
    open(os.path.join(out, f"unitotem-frame-{name}.rgb565"), "wb").write(bytes(rgb565))
    print(name, part.size, len(bgrx), len(rgb565))
img.save(os.path.join(out, "..", "..", "tools", "assets", "frame-preview.png"))
