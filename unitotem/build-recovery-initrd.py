#!/usr/bin/env python3
"""Builds the resident OTA fallback kernel and initrd natively (no chroot, no emulation).

Reads a stage-1 rootfs (a directory, or the stage1.tar.gz tarball) and writes recovery-initrd-<arch>.img,
recovery-vmlinuz-<arch> and recovery.manifest into --out. Only host tools that read foreign-arch files run;
no binary of the target rootfs is executed. Behaviour: the mkinitramfs body, see ninitrd/assemble.py.
"""
import argparse
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "ninitrd"))

DEFAULT_LIST = os.path.join(HERE, "files", "ota-initrd.list")
DEFAULT_HOOK = os.path.join(HERE, "ninitrd", "otahook.py")
LOGO_SCRIPT = os.path.join(HERE, "logo", "gen-logo.py")


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--arch", required=True, choices=("arm64", "amd64"))
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--rootfs", metavar="DIR", help="extracted stage-1 rootfs (read only)")
    src.add_argument("--stage1", metavar="TARBALL", help="stage1.tar.gz, extracted under --work")
    p.add_argument("--out", required=True, metavar="DIR", help="output directory (scratch with --slot-out)")
    p.add_argument("--work", metavar="DIR", help="scratch directory (default: a temporary folder in --out)")
    p.add_argument("--engine", required=True, metavar="PATH", help="ota-engine.sh to ship as /usr/lib/unitotem")
    p.add_argument("--logo-dir", metavar="DIR", help="output of unitotem/logo/gen-logo.py (default: rendered now)")
    p.add_argument("--list", "--hook-list", dest="list_path", default=DEFAULT_LIST, metavar="PATH",
                   help="ota-initrd.list (default: unitotem/files/ota-initrd.list)")
    p.add_argument("--slot-out", metavar="FILE",
                   help="build the initramfs of the installed system (update-initramfs equivalent) into FILE; no vmlinuz, no manifest")
    p.add_argument("--hook-script", default=DEFAULT_HOOK, metavar="PATH",
                   help="project hook port (default: unitotem/ninitrd/otahook.py)")
    return p.parse_args(argv)


def load_hook(path):
    spec = importlib.util.spec_from_file_location("otahook", path)
    if spec is None or spec.loader is None:
        die(f"cannot load hook {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def kernel_version(root):
    mdir = os.path.join(root, "lib", "modules")
    if not os.path.isdir(mdir):
        die(f"no lib/modules under {root}")
    kdirs = sorted(d for d in os.listdir(mdir) if os.path.isdir(os.path.join(mdir, d)))
    if len(kdirs) != 1:
        die(f"expected exactly one kernel under {mdir}, found {len(kdirs)}: {', '.join(kdirs) or 'none'}")
    return kdirs[0]


def partclone_version(root):
    # Version field of the partclone package in the rootfs dpkg database (no binary is run)
    status = os.path.join(root, "var", "lib", "dpkg", "status")
    if not os.path.isfile(status):
        die(f"no dpkg database in {root}")
    with open(status, encoding="utf-8", errors="replace") as fh:
        for stanza in fh.read().split("\n\n"):
            fields = dict(line.split(": ", 1) for line in stanza.splitlines() if ": " in line)
            if fields.get("Package") == "partclone":
                return fields.get("Version", "")
    die("partclone is not installed in the rootfs")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def render_logo(work):
    logo_dir = os.path.join(work, "logo")
    if os.path.exists(logo_dir):
        shutil.rmtree(logo_dir)
    os.makedirs(logo_dir)
    res = subprocess.run([sys.executable, LOGO_SCRIPT, logo_dir], capture_output=True, text=True)
    if res.returncode != 0:
        die(f"logo rendering failed: {res.stderr.strip()}")
    return logo_dir


def main(argv=None):
    args = parse_args(argv)
    for path in (args.engine, args.list_path, args.hook_script):
        if not os.path.isfile(path):
            die(f"missing file: {path}")
    if args.logo_dir and not os.path.isdir(args.logo_dir):
        die(f"missing logo directory: {args.logo_dir}")
    os.makedirs(args.out, exist_ok=True)
    work = args.work or tempfile.mkdtemp(prefix="ninitrd-work-", dir=args.out)
    os.makedirs(work, exist_ok=True)
    try:
        if args.rootfs:
            root = os.path.abspath(args.rootfs)
        else:
            root = os.path.join(work, "rootfs")
            if os.path.exists(root):  # leftover of an earlier run in a kept --work folder
                shutil.rmtree(root)
            os.makedirs(root)
            # device nodes are not used by the initrd and cannot be created without root
            subprocess.run(["tar", "-p", "--exclude=./dev/*", "-xf", os.path.abspath(args.stage1), "-C", root], check=True)
        kver = kernel_version(root)
        print(f"Kernel version: {kver}")
        logo_dir = args.logo_dir or render_logo(work)

        import assemble
        dest = os.path.join(work, "dest")
        if os.path.exists(dest):
            shutil.rmtree(dest)
        level = assemble.build(root, dest, args.arch, kver, os.path.abspath(args.engine),
                               logo_dir, args.list_path, load_hook(args.hook_script), slot=bool(args.slot_out))
        if args.slot_out:
            assemble.pack(dest, os.path.abspath(args.slot_out), work, level)
            print(f"Wrote {args.slot_out} ({os.path.getsize(args.slot_out)} bytes)")
            return

        out = os.path.abspath(args.out)
        initrd = os.path.join(out, f"recovery-initrd-{args.arch}.img")
        vmlinuz = os.path.join(out, f"recovery-vmlinuz-{args.arch}")
        assemble.pack(dest, initrd, work, level)
        shutil.copyfile(os.path.join(root, "boot", f"vmlinuz-{kver}"), vmlinuz)
        manifest = os.path.join(out, "recovery.manifest")
        with open(manifest, "w", encoding="utf-8") as fh:
            fh.write(f"UNITOTEM_RECOVERY_ARCH={args.arch}\n"
                     f"UNITOTEM_RECOVERY_KERNEL_VERSION={kver}\n"
                     f"UNITOTEM_RECOVERY_VMLINUZ_SHA256={sha256(vmlinuz)}\n"
                     f"UNITOTEM_RECOVERY_INITRD_SHA256={sha256(initrd)}\n"
                     f"UNITOTEM_RECOVERY_PARTCLONE_VERSION={partclone_version(root)}\n"
                     f"UNITOTEM_RECOVERY_BUILD_DATE={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        print(f"Wrote {initrd} ({os.path.getsize(initrd)} bytes)")
    finally:
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
