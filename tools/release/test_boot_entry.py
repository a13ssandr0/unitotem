#!/usr/bin/env python3
"""Test of unitotem-boot-entry on a temporary efivars directory (no real variable is read or written).

  python3 tools/release/test_boot_entry.py
"""
import importlib.machinery, importlib.util, os, struct, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
loader = importlib.machinery.SourceFileLoader("be", os.path.join(ROOT, "unitotem/files/unitotem-boot-entry"))
spec = importlib.util.spec_from_loader("be", loader); be = importlib.util.module_from_spec(spec); loader.exec_module(be)
ok = fail = 0


def check(name, cond):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name)


def entry(desc, loader_path, extra=b""):
    fp = loader_path.encode("utf-16-le") + b"\0\0"
    paths = struct.pack("<BBH", 4, 4, 4 + len(fp)) + fp + struct.pack("<BBH", 0x7f, 0xff, 4)
    return be.build(7, 1, desc, paths, extra)


def make(d, num, blob):
    open(os.path.join(d, "Boot%04X-%s" % (num, be.GLOBAL)), "wb").write(blob)
    open(os.path.join(d, "BootCurrent-%s" % be.GLOBAL), "wb").write(struct.pack("<IH", 6, num))


def read(d, num):
    return be.parse(open(os.path.join(d, "Boot%04X-%s" % (num, be.GLOBAL)), "rb").read())


with tempfile.TemporaryDirectory() as d:
    make(d, 3, entry("debian", "\\EFI\\debian\\shimx64.efi", b"opt"))
    check("renames the UniTotem loader entry", be.rename(d, immutable=False) == "renamed")
    var, attr, desc, paths, data = read(d, 3)
    check("description is UniTotem, attributes, path list and data kept",
          desc == "UniTotem" and var == 7 and attr == 1 and data == b"opt" and be.file_paths(paths) == ["\\EFI\\debian\\shimx64.efi"])
    check("second run changes nothing", be.rename(d, immutable=False) == "named")
    make(d, 4, entry("Windows Boot Manager", "\\EFI\\Microsoft\\Boot\\bootmgfw.efi"))
    check("a foreign entry is left alone", be.rename(d, immutable=False) == "foreign" and read(d, 4)[2] == "Windows Boot Manager")
    make(d, 5, entry("UEFI OS", "\\EFI\\BOOT\\BOOTX64.EFI"))
    check("the removable path is ours too", be.rename(d, immutable=False) == "renamed")
    check("main with a missing efivars directory succeeds", be.main(["--efivars", d + "/none"]) == 0)
    check("main rejects a bad name", be.main(["--efivars", d, "--name", "a;b"]) == 2)
print("%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)
