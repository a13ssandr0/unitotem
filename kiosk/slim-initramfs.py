#!/usr/bin/env python3
"""Shrink an initramfs: the Raspberry Pi firmware reads kernel+initramfs from the SD at only ~5 MB/s (measured on a Pi 4 with
uart_2ndstage=1: 40 MB of initramfs = 7.8 s of black screen before the kernel even starts), so every MB of initramfs is ~0.2 s
of boot. Run in the image build after update-initramfs; also usable on any initrd file.

  slim-initramfs.py IN OUT [--arch arm64|amd64]

What it does: keeps the early (uncompressed) cpio segments untouched, unpacks the compressed main segment, drops
 - usr/lib/udev/hwdb.bin (13 MB, only used to name USB/PCI devices; nothing in the initramfs needs it),
 - on arm64: every Wi-Fi firmware that is not for a chip found on a Raspberry Pi (43430 Zero 2/Pi 3, 43436 Zero 2 W,
   43455 Pi 3B+/4, 43456 Pi 400/CM4); the OTA fallback only needs Wi-Fi on those boards,
and recompresses the main segment with zstd -19 (the kernel has CONFIG_RD_ZSTD; falls back to gzip -9 if zstd is missing).
"""
import os, re, shutil, subprocess, sys, tempfile

MAGICS = [(b"\x28\xb5\x2f\xfd", ["zstd", "-dc"]), (b"\x1f\x8b", ["gzip", "-dc"]), (b"\xfd7zXZ", ["xz", "-dc"]),
          (b"\x04\x22\x4d\x18", ["lz4", "-dc"])]
PI_WIFI = re.compile(r"43430|43436|43455|43456")


def split_segments(data):
    """-> ([raw early segments (bytes, incl. their padding)], compressed main bytes or None, codec cmd)"""
    off, early = 0, []
    while off < len(data):
        if data[off:off + 6] == b"070701":
            i = data.find(b"TRAILER!!!", off)
            if i < 0:
                raise SystemExit("cpio segment without TRAILER")
            end = (i - 110) + ((110 + 11 + 3) & ~3)
            nxt = end
            while nxt < len(data) and data[nxt] == 0:
                nxt += 1
            early.append(data[off:nxt])
            off = nxt
            continue
        for magic, cmd in MAGICS:
            if data[off:off + len(magic)] == magic:
                return early, data[off:], cmd
        raise SystemExit("unknown initramfs segment at offset %d" % off)
    return early, None, None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    arch = "arm64" if "--arch" not in sys.argv else sys.argv[sys.argv.index("--arch") + 1]
    args = [a for a in args if a != arch]
    src, dst = args[0], args[1]
    data = open(src, "rb").read()
    early, comp, cmd = split_segments(data)
    if comp is None:
        raise SystemExit("no compressed main segment found (already uncompressed?): nothing to do")
    tmp = tempfile.mkdtemp(prefix="slim-initramfs-")
    try:
        tree = os.path.join(tmp, "tree"); os.mkdir(tree)
        raw = subprocess.run(cmd, input=comp, stdout=subprocess.PIPE, check=True).stdout
        subprocess.run(["cpio", "-id", "--quiet", "--no-absolute-filenames"], input=raw, cwd=tree, check=True)
        removed = 0

        def rm(p):
            nonlocal removed
            try:
                removed += os.lstat(p).st_size
                os.unlink(p)
            except FileNotFoundError:
                pass
        rm(os.path.join(tree, "usr/lib/udev/hwdb.bin"))
        if arch == "arm64":
            for sub in ("brcm", "cypress"):
                d = os.path.join(tree, "usr/lib/firmware", sub)
                if not os.path.isdir(d):
                    continue
                for dp, dn, fn in os.walk(d):
                    for f in fn:
                        if not PI_WIFI.search(f):
                            rm(os.path.join(dp, f))
                for dp, dn, fn in os.walk(d):          # symlinks left pointing at removed files
                    for f in fn:
                        p = os.path.join(dp, f)
                        if os.path.islink(p) and not os.path.exists(p):
                            rm(p)
        names = subprocess.run(["find", ".", "-print0"], cwd=tree, stdout=subprocess.PIPE, check=True).stdout
        cpio = subprocess.run(["cpio", "-0", "-o", "-H", "newc", "--owner=0:0", "--quiet"], input=names, cwd=tree,
                              stdout=subprocess.PIPE, check=True).stdout
        if shutil.which("zstd"):
            out = subprocess.run(["zstd", "-19", "-T0", "-q", "-c"], input=cpio, stdout=subprocess.PIPE, check=True).stdout
            codec = "zstd -19"
        else:
            out = subprocess.run(["gzip", "-9n", "-c"], input=cpio, stdout=subprocess.PIPE, check=True).stdout
            codec = "gzip -9 (zstd not installed)"
        with open(dst, "wb") as f:
            for seg in early:
                f.write(seg)
            f.write(out)
        print("slim-initramfs: %s -> %s: %.1f MB -> %.1f MB (%s; removed %.1f MB uncompressed)"
              % (os.path.basename(src), os.path.basename(dst), len(data) / 1e6, os.path.getsize(dst) / 1e6, codec, removed / 1e6))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
