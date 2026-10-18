#!/usr/bin/env python3
"""Pre-render the UniTotem wordmark (the same artwork as the manager's Plymouth theme) into raw 32-bit BGRX blobs that the
OTA fallback can write straight to /dev/fb0 with dd - the initramfs has no image decoder. Composited on black (the theme's
background). Two sizes, picked by framebuffer width at runtime.   python3 tools/gen-logo.py"""
from PIL import Image
import os
here = os.path.dirname(os.path.abspath(__file__))
src = Image.open(os.path.join(here, "assets", "unitotem-wordmark.png")).convert("RGBA")
# The wordmark has a gap where the "o" is: in the boot splash a ring (the same artwork that spins there) sits in it. Place it
# the way plymouth/unitotem/unitotem.script does - centre at 0.5179 x width / 0.5734 x height of the wordmark, drawn at half
# the size of the 2x-oversampled spinner image - and keep it still.
ring = Image.open(os.path.join(here, "assets", "unitotem-ring.png")).convert("RGBA")
# The orange arc is the SPINNER: on a still logo it would read as a stuck loading indicator, so the still logo gets a plain white
# ring. Orange pixels (strong red, little green/blue) become white; their alpha and the anti-aliased edges are kept.
px = ring.load()
for yy in range(ring.height):
    for xx in range(ring.width):
        r_, g_, b_, a_ = px[xx, yy]
        if r_ > 150 and r_ - g_ > 60 and r_ - b_ > 60:
            px[xx, yy] = (255, 255, 255, a_)
ring = ring.resize((ring.width // 2, ring.height // 2), Image.LANCZOS)
cx, cy = round(src.width * 0.5179), round(src.height * 0.5734)
src.alpha_composite(ring, (cx - ring.width // 2, cy - ring.height // 2))
for width in (256, 640, 1280):
    h = round(src.height * width / src.width)
    im = src.resize((width, h), Image.LANCZOS)
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255)); bg.alpha_composite(im)
    r, g, b, _ = bg.split()
    raw = Image.merge("RGBA", (b, g, r, Image.new("L", im.size, 0))).tobytes()   # B,G,R,X per pixel (XRGB8888, little endian)
    # guard: no orange (spinner) pixel may reach a still logo
    rgb = bg.convert("RGB").tobytes()
    assert not any(rgb[i] > 150 and rgb[i] - rgb[i + 1] > 60 and rgb[i] - rgb[i + 2] > 60 for i in range(0, len(rgb), 3)), "orange pixel in the still logo"
    out = os.path.join(here, "..", "unitotem", "files", f"unitotem-logo-{width}x{h}.bgrx")
    open(out, "wb").write(raw)
    print(out, width, h, len(raw), "bytes")
    # RGB565, little endian: the firmware framebuffer of the resident Pi fallback (no KMS driver) is 16 bpp
    px = bg.convert("RGB").tobytes()
    out16 = bytearray()
    for i in range(0, len(px), 3):
        v = ((px[i] >> 3) << 11) | ((px[i + 1] >> 2) << 5) | (px[i + 2] >> 3)
        out16 += bytes((v & 255, v >> 8))
    out = os.path.join(here, "..", "unitotem", "files", f"unitotem-logo-{width}x{h}.rgb565")
    open(out, "wb").write(bytes(out16))
    print(out, width, h, len(out16), "bytes")
