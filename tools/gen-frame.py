#!/usr/bin/env python3
"""Pre-render the pieces of the rounded frame drawn around the OTA progress dialog (see ota_frame in deploy/ota-engine.sh).
The frame itself is laid out at runtime for WHATEVER resolution the screen has (the dialog is centered by whiptail, so its pixel
position follows from the console size); only the pieces that are expensive to compute in a shell are pre-rendered:
  unitotem-frame-corners-<R>.<fmt>   the four anti-aliased corners TL, TR, BL, BR, each R x R pixels, back to back
  unitotem-frame-line.<fmt>          4096 pixels of the solid line colour (straight edges are prefixes of it)
for the radii the console cell heights call for, in the three framebuffer formats seen in practice:
  bgrx (32 bpp, X byte non-zero so shell tools are safe), bgr24 (24 bpp), rgb565 (16 bpp, little endian).
Line thickness follows the radius (THICK). Composited on black, the background of the update screen.
    python3 tools/gen-frame.py"""
from PIL import Image, ImageDraw
import os
RADII = {12: 2, 16: 3, 24: 5, 32: 6, 48: 10, 64: 13}          # radius -> line thickness in px
LINE = (225, 225, 225)
S = 4                                                           # supersampling for the anti-aliased arcs
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kiosk", "files")


def encode(img, fmt):
    px = img.tobytes()
    if fmt == "bgrx":
        return b"".join(bytes((px[i + 2], px[i + 1], px[i], 0xFF)) for i in range(0, len(px), 3))
    if fmt == "bgr24":
        return b"".join(bytes((px[i + 2], px[i + 1], px[i])) for i in range(0, len(px), 3))
    b = bytearray()
    for i in range(0, len(px), 3):
        v = ((px[i] >> 3) << 11) | ((px[i + 1] >> 2) << 5) | (px[i + 2] >> 3)
        b += bytes((v & 255, v >> 8))
    return bytes(b)


for fmt in ("bgrx", "bgr24", "rgb565"):
    open(os.path.join(out, f"unitotem-frame-line.{fmt}"), "wb").write(encode(Image.new("RGB", (4096, 1), LINE), fmt))
    for r, t in RADII.items():
        big = Image.new("RGB", (2 * r * S, 2 * r * S), (0, 0, 0))
        ImageDraw.Draw(big).rounded_rectangle((0, 0, 2 * r * S - 1, 2 * r * S - 1), radius=r * S, outline=LINE, width=t * S)
        sq = big.resize((2 * r, 2 * r), Image.LANCZOS)
        corners = [sq.crop((0, 0, r, r)), sq.crop((r, 0, 2 * r, r)), sq.crop((0, r, r, 2 * r)), sq.crop((r, r, 2 * r, 2 * r))]
        open(os.path.join(out, f"unitotem-frame-corners-{r}.{fmt}"), "wb").write(b"".join(encode(c, fmt) for c in corners))
print("radii", sorted(RADII), "formats bgrx bgr24 rgb565")
