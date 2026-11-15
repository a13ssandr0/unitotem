#!/usr/bin/env python3
# Entries of an initramfs file: any sequence of cpio archives, each uncompressed (newc) or compressed (zstd, gzip, xz).
# lsinitramfs and unmkinitramfs fail on an uncompressed archive appended to a zstd one; this reader does not.
#   initrd-scan.py list INITRD       entry names in archive order (exit 2: not an initramfs)
#   initrd-scan.py get INITRD NAME   content of the last entry NAME, a later entry replaces an earlier one (exit 1: absent, 2: unreadable)
# zstd frames are decompressed by the zstd tool (python3 has no zstd module before 3.14); their frame layout is read here (RFC 8878).
import lzma, subprocess, sys, zlib

ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'


class Bad(Exception):
    pass


def norm(name):
    while name.startswith('./'):
        name = name[2:]
    return name.lstrip('/')


def align4(n):
    return (n + 3) & ~3


def skippable(d, pos):
    return len(d) >= pos + 8 and 0x50 <= d[pos] <= 0x5f and d[pos + 1:pos + 4] == b'\x2a\x4d\x18'


def zstd_frame_end(d, pos):
    if len(d) < pos + 6:
        raise Bad('truncated zstd frame header')
    fhd = d[pos + 4]
    single, checksum, did, fcs = (fhd >> 5) & 1, (fhd >> 2) & 1, fhd & 3, fhd >> 6
    p = pos + 5 + (0 if single else 1)
    p += {0: 0, 1: 1, 2: 2, 3: 4}[did]
    p += {0: (1 if single else 0), 1: 2, 2: 4, 3: 8}[fcs]
    while True:
        if p + 3 > len(d):
            raise Bad('truncated zstd block header')
        bh = int.from_bytes(d[p:p + 3], 'little')
        last, btype, size = bh & 1, (bh >> 1) & 3, bh >> 3
        p += 3
        if btype == 3:
            raise Bad('reserved zstd block type')
        p += 1 if btype == 1 else size          # RLE block: one byte; raw and compressed: Block_Size bytes
        if last:
            break
    if checksum:
        p += 4
    if p > len(d):
        raise Bad('truncated zstd block')
    return p


def newc(d, base):
    # padding counts from the start of its own archive: an archive appended at an odd offset is still aligned
    out, pos = [], base
    while True:
        if d[pos:pos + 6] not in (b'070701', b'070702') or len(d) < pos + 110:
            raise Bad('bad cpio header at %d' % pos)
        try:
            filesize = int(d[pos + 54:pos + 62], 16)
            namesize = int(d[pos + 94:pos + 102], 16)
        except ValueError:
            raise Bad('bad cpio header at %d' % pos)
        name_at = pos + 110
        raw = d[name_at:name_at + namesize]
        if namesize == 0 or len(raw) != namesize or raw[-1:] != b'\0':
            raise Bad('bad cpio name at %d' % pos)
        name = raw[:-1].decode('utf-8', 'surrogateescape')
        data = base + align4(name_at + namesize - base)
        end = data + filesize
        if end > len(d):
            raise Bad('truncated cpio entry %s' % name)
        if name == 'TRAILER!!!':
            return out, base + align4(end - base)
        out.append((norm(name), d[data:end]))
        pos = base + align4(end - base)


def entries(d):
    out, pos, n = [], 0, len(d)
    while True:
        while pos < n and d[pos] == 0:           # padding between archives
            pos += 1
        if pos >= n:
            return out
        if d[pos:pos + 6] in (b'070701', b'070702'):
            ents, pos = newc(d, pos)
            out.extend(ents)
        elif d[pos:pos + 4] == ZSTD_MAGIC or skippable(d, pos):
            start = pos
            while pos < n and (d[pos:pos + 4] == ZSTD_MAGIC or skippable(d, pos)):
                if skippable(d, pos):
                    pos += 8 + int.from_bytes(d[pos + 4:pos + 8], 'little')
                else:
                    pos = zstd_frame_end(d, pos)
            r = subprocess.run(['zstd', '-dcq'], input=d[start:pos], capture_output=True)
            if r.returncode != 0:
                raise Bad('zstd: ' + r.stderr.decode('utf-8', 'replace').strip())
            out.extend(entries(r.stdout))
        elif d[pos:pos + 2] == b'\x1f\x8b':
            z = zlib.decompressobj(31)
            body = z.decompress(d[pos:])
            if not z.eof:
                raise Bad('truncated gzip stream')
            out.extend(entries(body))
            pos = n - len(z.unused_data)
        elif d[pos:pos + 6] == b'\xfd7zXZ\x00':
            x = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
            body = x.decompress(d[pos:])
            if not x.eof:
                raise Bad('truncated xz stream')
            out.extend(entries(body))
            pos = n - len(x.unused_data)
        else:
            raise Bad('unknown data at %d' % pos)


def main(argv):
    if len(argv) not in (3, 4) or argv[1] not in ('list', 'get') or (argv[1] == 'get') != (len(argv) == 4):
        print('usage: initrd-scan.py list INITRD | get INITRD NAME', file=sys.stderr)
        return 2
    try:
        with open(argv[2], 'rb') as f:
            d = f.read()
        if not d:
            raise Bad('empty file')
        ents = entries(d)
    except (OSError, Bad) as e:
        print('initrd-scan.py: %s: %s' % (argv[2], e), file=sys.stderr)
        return 2
    if argv[1] == 'list':
        for name, _ in ents:
            print(name)
        return 0
    hits = [data for name, data in ents if name == norm(argv[3])]
    if not hits:
        return 1
    sys.stdout.buffer.write(hits[-1])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
