#!/usr/bin/python3 -I
"""Compare two rootfs tarballs (reference build vs native build): paths, type, mode, owner, link target, content hash.

usage: nb-compare-rootfs.py REF.tar.gz NEW.tar.gz [--out DIR]
Writes DIR/{only-ref,only-new,meta,content}.txt (one path per line with the difference) and prints counts per category.
"""
import hashlib
import os
import sys
import tarfile
from collections import Counter


def index(path):
    out = {}
    with tarfile.open(path, "r|gz") as t:
        for m in t:
            n = m.name[1:] if m.name.startswith("./") else m.name
            n = "/" + n.rstrip("/") if n not in ("", ".") else "/"
            h = ""
            if m.isreg():
                f = t.extractfile(m)
                d = hashlib.sha256()
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    d.update(b)
                h = d.hexdigest()
            out[n] = (m.type.decode() if isinstance(m.type, bytes) else m.type, m.mode & 0o7777, m.uid, m.gid, m.linkname, h, m.size)
    return out


def main():
    a, b = sys.argv[1], sys.argv[2]
    outd = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "."
    os.makedirs(outd, exist_ok=True)
    ra, rb = index(a), index(b)
    only_a = sorted(set(ra) - set(rb))
    only_b = sorted(set(rb) - set(ra))
    meta, content = [], []
    for p in sorted(set(ra) & set(rb)):
        x, y = ra[p], rb[p]
        if x[:5] != y[:5]:
            meta.append("%s ref=%s new=%s" % (p, x[:5], y[:5]))
        elif x[5] != y[5]:
            content.append("%s size ref=%d new=%d" % (p, x[6], y[6]))
    for name, lst in (("only-ref", only_a), ("only-new", only_b), ("meta", meta), ("content", content)):
        with open(os.path.join(outd, name + ".txt"), "w") as f:
            f.write("\n".join(lst) + "\n")
    print("entries ref=%d new=%d" % (len(ra), len(rb)))
    for name, lst in (("only in ref", only_a), ("only in new", only_b), ("meta differs", meta), ("content differs", content)):
        top = Counter("/".join(l.split(" ")[0].split("/")[:4]) for l in lst)
        print("%s: %d" % (name, len(lst)))
        for k, v in top.most_common(12):
            print("    %6d %s" % (v, k))


main()
