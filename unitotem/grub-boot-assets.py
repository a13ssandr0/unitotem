#!/usr/bin/env python3
"""Build-time generator of the GRUB boot pictures: the Plymouth splash layout (wordmark and static ring, centred) at each display size, optionally with a "Booting slot" line.

  grub-boot-assets.py logo --theme DIR --out DIR [--modes WxH,...]
  grub-boot-assets.py slot --theme DIR --font TTF --version VERSION --out DIR [--modes WxH,...] [--slots a b]

GRUB stretches each picture to the whole screen (background_image -m stretch), so every picture is exactly WxH.
Output: OUT/WxH.png (logo) or OUT/boot-SLOT-WxH.png (slot), plain RGB 8-bit PNG.
"""
import argparse, functools, os, re, sys, tempfile

from PIL import Image, ImageDraw, ImageFont

# Same values as the Plymouth theme (unitotem.script) and the Qt splash (bootsplash.py).
WORDMARK_FRAC = 0.601    # wordmark width / screen width
TEXT_SIZE_FRAC = 0.0225  # text font size / screen width (minimum 12 px)
TEXT_GAP_FRAC = 0.04     # gap from wordmark bottom to text top / screen width
RING_X = 0.5179          # ring centre, fraction of the wordmark width
RING_Y = 0.5734          # ring centre, fraction of the wordmark height

TIERS = (1280, 1920, 2560, 3840)  # wordmark-N.png and spinner-N.png in the theme
SPINNER_OVERSAMPLE = 2            # spinner PNGs are drawn at 2x the shown size
MODES = [
    "1024x768", "1280x720", "1280x800", "1280x1024", "1360x768", "1366x768", "1440x900", "1600x900", "1680x1050",
    "1920x1080", "1920x1200", "2560x1080", "2560x1440", "2560x1600", "3440x1440", "3840x2160", "4096x2160",
]
MODE_RE = re.compile(r"[1-9][0-9]{2,4}x[1-9][0-9]{2,4}")
VERSION_RE = re.compile(r"[0-9A-Za-z.+~:-]{1,64}")
SLOT_RE = re.compile(r"[A-Za-z]")
MIN_DIM, MAX_DIM = 320, 7680


class UsageError(Exception):
    pass


def check_modes(text):
    modes = []
    for item in text.split(","):
        if not MODE_RE.fullmatch(item):
            raise UsageError("bad mode %r, expected WxH" % item)
        w, h = (int(v) for v in item.split("x"))
        if not (MIN_DIM <= w <= MAX_DIM and MIN_DIM <= h <= MAX_DIM):
            raise UsageError("mode %r outside %d..%d" % (item, MIN_DIM, MAX_DIM))
        modes.append((w, h))
    return modes


def check_theme(theme):
    if not os.path.isdir(theme):
        raise UsageError("theme directory not found: %s" % theme)
    for tier in TIERS:
        for kind in ("wordmark", "spinner"):
            path = os.path.join(theme, "%s-%d.png" % (kind, tier))
            if not os.path.isfile(path):
                raise UsageError("theme file missing: %s" % path)


@functools.lru_cache(maxsize=None)
def _load(path):
    return Image.open(path).convert("RGBA")


def geometry(theme, w, h):
    """Return (wordmark, ring, wordmark x, wordmark y) for a WxH screen, as in unitotem.script layout()."""
    target_w = int(w * WORDMARK_FRAC)
    # Smallest tier whose wordmark is at least target_w wide.
    tier = next((t for t in TIERS if _load(os.path.join(theme, "wordmark-%d.png" % t)).width >= target_w), TIERS[-1])
    wm_raw = _load(os.path.join(theme, "wordmark-%d.png" % tier))
    rg_raw = _load(os.path.join(theme, "spinner-%d.png" % tier))
    scale = target_w / wm_raw.width
    wm = wm_raw.resize((target_w, int(wm_raw.height * scale)), Image.LANCZOS)
    # Halved for the oversampling; forced odd so the ring centre is exact.
    ring_size = int(rg_raw.width * scale / SPINNER_OVERSAMPLE)
    if ring_size % 2 == 0:
        ring_size += 1
    ring = rg_raw.resize((ring_size, ring_size), Image.LANCZOS)
    x = w // 2 - wm.width // 2
    y = h // 2 - wm.height // 2
    return wm, ring, x, y


def text_ink(text, font):
    """Return (left, right) of the drawn glyphs relative to the text origin, from a rendered mask."""
    pad = font.size
    layer = Image.new("L", (int(font.getlength(text)) + 2 * pad, 3 * pad), 0)
    ImageDraw.Draw(layer).text((pad, pad), text, font=font, fill=255)
    left, _top, right, _bottom = layer.getbbox()
    return left - pad, right - pad


def compose(theme, w, h, text=None, font_path=None):
    """Return the WxH RGB picture: black, wordmark, ring, and the optional text line below the wordmark."""
    wm, ring, x, y = geometry(theme, w, h)
    im = Image.new("RGB", (w, h), (0, 0, 0))
    im.paste(wm, (x, y), wm)
    im.paste(ring, (round(x + wm.width * RING_X - ring.width / 2), round(y + wm.height * RING_Y - ring.height / 2)), ring)
    if text:
        font = ImageFont.truetype(font_path, max(12, round(TEXT_SIZE_FRAC * w)))
        # Centre the glyph ink, not the advance width (the side bearings differ per glyph).
        ink_left, ink_right = text_ink(text, font)
        origin_x = round((w - (ink_right - ink_left)) / 2) - ink_left
        ImageDraw.Draw(im).text((origin_x, y + wm.height + round(TEXT_GAP_FRAC * w)), text, font=font,
                                fill=(255, 255, 255))
    return im


def write_png(im, out_dir, name):
    """Write through a temporary file in out_dir, then rename it over the final name."""
    fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".tmp-", suffix=".png")
    try:
        with os.fdopen(fd, "wb") as fh:
            im.save(fh, format="PNG", optimize=True)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(out_dir, name))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class OneLineParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "%s: error: %s\n" % (self.prog, message))


def build_parser():
    p = OneLineParser(description="Generate the GRUB boot pictures.")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("logo", "slot"):
        sp = sub.add_parser(name)
        sp.add_argument("--theme", required=True)
        sp.add_argument("--out", required=True)
        sp.add_argument("--modes", default=None, help="comma-separated WxH list (default: built-in list)")
        if name == "slot":
            sp.add_argument("--font", required=True)
            sp.add_argument("--version", required=True)
            sp.add_argument("--slots", nargs="+", default=["a", "b"])
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        modes = check_modes(args.modes if args.modes is not None else ",".join(MODES))
        check_theme(args.theme)
        if os.path.exists(args.out) and not os.path.isdir(args.out):
            raise UsageError("output is not a directory: %s" % args.out)
        if args.cmd == "slot":
            if not VERSION_RE.fullmatch(args.version):
                raise UsageError("bad version %r" % args.version)
            for slot in args.slots:
                if not SLOT_RE.fullmatch(slot):
                    raise UsageError("bad slot %r, expected a letter" % slot)
            if not os.path.isfile(args.font):
                raise UsageError("font not found: %s" % args.font)
    except UsageError as exc:
        sys.stderr.write("grub-boot-assets.py: error: %s\n" % exc)
        return 2

    os.makedirs(args.out, exist_ok=True)
    count = 0
    for w, h in modes:
        if args.cmd == "logo":
            write_png(compose(args.theme, w, h), args.out, "%dx%d.png" % (w, h))
            count += 1
            continue
        for slot in args.slots:
            text = "Booting slot %s: UniTotem %s" % (slot.upper(), args.version)
            im = compose(args.theme, w, h, text, args.font)
            write_png(im, args.out, "boot-%s-%dx%d.png" % (slot.lower(), w, h))
            count += 1
    print("%d pictures in %s" % (count, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
