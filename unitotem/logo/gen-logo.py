#!/usr/bin/env python3
"""Renders the UniTotem wordmark (the artwork of the manager's Plymouth theme, transparent PNG) for the OTA fallback screen, at image build time.

The initramfs has no image decoder, so the fallback writes raw pixels to /dev/fb0 with dd. Per size (256, 640, 1280 px wide) this writes
  unitotem-logo-<W>x<H>.bgrx    32 bpp (XRGB8888, little endian)
  unitotem-logo-<W>x<H>.rgb565  16 bpp (the firmware framebuffer of the resident Pi fallback)
  unitotem-logo-<W>x<H>.spans   one "row x length" line (pixels) per run of non-transparent pixels
The fallback copies only those runs, so the background of the screen stays untouched (the logo is transparent). Edge pixels are blended on
the blue of the screen (whiptail's root window on the Linux console palette, 0,0,170).

    gen-logo.py OUTDIR"""
import os
import sys
from PIL import Image

BLUE = (0, 0, 170, 255)
here = os.path.dirname(os.path.abspath(__file__))
out_dir = sys.argv[1] if len(sys.argv) == 2 else sys.exit(__doc__)
src = Image.open(os.path.join(here, "unitotem-wordmark.png")).convert("RGBA")
# The wordmark has a gap where the "o" is: in the boot splash a ring (the artwork that spins there) sits in it. Placed as
# plymouth/unitotem/unitotem.script does: centre at 0.5179 x width / 0.5734 x height of the wordmark, half the size of the
# 2x-oversampled spinner image, kept still.
ring = Image.open(os.path.join(here, "unitotem-ring.png")).convert("RGBA")
# The orange arc is the SPINNER: on a still logo it would read as a stuck loading indicator, so it becomes white (alpha kept).
px = ring.load()
for yy in range(ring.height):
    for xx in range(ring.width):
        r_, g_, b_, a_ = px[xx, yy]
        if r_ > 150 and r_ - g_ > 60 and r_ - b_ > 60:
            px[xx, yy] = (255, 255, 255, a_)
ring = ring.resize((ring.width // 2, ring.height // 2), Image.LANCZOS)
cx, cy = round(src.width * 0.5179), round(src.height * 0.5734)
src.alpha_composite(ring, (cx - ring.width // 2, cy - ring.height // 2))
os.makedirs(out_dir, exist_ok=True)
for width in (256, 640, 1280):
    h = round(src.height * width / src.width)
    im = src.resize((width, h), Image.LANCZOS)
    alpha = im.split()[3].load()
    bg = Image.new("RGBA", im.size, BLUE)
    bg.alpha_composite(im)
    rgb = bg.convert("RGB").tobytes()
    # no orange (spinner) pixel may reach a still logo
    assert not any(rgb[i] > 150 and rgb[i] - rgb[i + 1] > 60 and rgb[i] - rgb[i + 2] > 60 for i in range(0, len(rgb), 3)), "orange pixel in the still logo"
    name = os.path.join(out_dir, f"unitotem-logo-{width}x{h}")
    raw32 = bytearray()
    raw16 = bytearray()
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
        raw32 += bytes((b, g, r, 0))
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        raw16 += bytes((v & 255, v >> 8))
    open(name + ".bgrx", "wb").write(bytes(raw32))
    open(name + ".rgb565", "wb").write(bytes(raw16))
    runs = []
    for y in range(h):
        x = 0
        while x < width:
            if alpha[x, y] > 0:
                x0 = x
                while x < width and alpha[x, y] > 0:
                    x += 1
                runs.append(f"{y} {x0} {x - x0}")
            else:
                x += 1
    open(name + ".spans", "w").write("\n".join(runs) + "\n")
    print(name, width, h, len(runs), "runs")
