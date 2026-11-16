#!/bin/bash
# Test of unitotem/ninitrd/assemble.py and unitotem/build-recovery-initrd.py on a fixture rootfs under a mktemp folder
# (removed at the end). The stage, modules, stockhooks and hook APIs are stubs (other modules, see ninitrd-SPEC.md);
# tar, cpio, zstd, tsort, sh -n and depmod -b are the real host tools.
#   tools/release/test_native_initrd_assemble.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -I - "${DIR}" <<'PY'
import contextlib
import subprocess
import io
import os
import shutil
import sys
import tarfile
import tempfile
import types
import importlib.util

subprocess_run = subprocess.run
REPO = sys.argv[1]
KVER = "6.18.0-test"
failures = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, mode)


def make_root(base, kvers=(KVER,)):
    root = os.path.join(base, "rootfs")
    os.makedirs(root)
    os.symlink("usr/bin", os.path.join(root, "bin"))
    os.symlink("usr/sbin", os.path.join(root, "sbin"))
    os.symlink("usr/lib", os.path.join(root, "lib"))
    write(os.path.join(root, "etc/initramfs-tools/initramfs.conf"),
          "MODULES=dep\nBUSYBOX=auto\nCOMPRESS=zstd\nCOMPRESSLEVEL=19\n")
    write(os.path.join(root, "etc/initramfs-tools/conf.d/unitotem-compress"), "COMPRESS=zstd\nCOMPRESSLEVEL=19\n")
    write(os.path.join(root, "usr/share/initramfs-tools/init"), "#!/bin/sh\necho init\n", 0o755)
    write(os.path.join(root, "usr/share/initramfs-tools/scripts/init-top/udev"),
          'PREREQ=""\nprereqs() { echo "$PREREQ"; }\ncase "$1" in prereqs) prereqs; exit 0;; esac\n', 0o755)
    write(os.path.join(root, "usr/share/initramfs-tools/scripts/init-top/keymap"),
          'PREREQ="udev"\nprereqs() { echo "$PREREQ"; }\ncase "$1" in prereqs) prereqs; exit 0;; esac\n', 0o755)
    write(os.path.join(root, "usr/share/initramfs-tools/scripts/init-top/notexec"),
          'PREREQ=""\n', 0o644)
    write(os.path.join(root, "usr/share/initramfs-tools/scripts/init-top/.hidden"), "x\n", 0o755)
    write(os.path.join(root, "etc/initramfs-tools/scripts/local-top/mine"), "PREREQ=\"\"\n", 0o755)
    write(os.path.join(root, "etc/modprobe.d/fixture.conf"), "blacklist fixture\n")
    write(os.path.join(root, "etc/ld.so.conf"), "include /etc/ld.so.conf.d/*.conf\n")
    write(os.path.join(root, "etc/ld.so.conf.d/libc.conf"), "# libc\n")
    write(os.path.join(root, "var/lib/dpkg/status"),
          "Package: bash\nVersion: 5.2\n\nPackage: partclone\nVersion: 0.3.31-1\n\n")
    write(os.path.join(root, "usr/lib/firmware/fake.bin.xz"), "not really xz\n")
    for kver in kvers:
        write(os.path.join(root, "usr/lib/modules", kver, "modules.dep"), "")
        write(os.path.join(root, "usr/lib/modules", kver, "modules.builtin"), "kernel/x.ko\n")
        write(os.path.join(root, "usr/lib/modules", kver, "modules.order"), "kernel/x.ko\n")
        write(os.path.join(root, "usr/lib/modules", kver, "modules.builtin.modinfo"), "")
        write(os.path.join(root, "boot", f"vmlinuz-{kver}"), "KERNEL\n")
    return root


def stub_modules(base):
    # stage / modules / stockhooks / hook stubs: they replace the modules written by other tasks
    stage = types.ModuleType("stage")

    class Stage:
        def __init__(self, root, dest, arch, kver, warn=print):
            self.root, self.dest, self.arch, self.kver = root, dest, arch, kver

        def copy_file(self, kind, src, target=None):
            target = target or src
            if os.path.isdir(os.path.join(self.dest, target.lstrip("/"))) or target.endswith("/"):
                target = os.path.join(target, os.path.basename(src))
            dst = os.path.join(self.dest, target.lstrip("/"))
            if os.path.exists(dst):
                return 1
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(self.root, src.lstrip("/")), dst)
            return 0

        def copy_exec(self, src, target=None):
            return 2

    stage.Stage = Stage
    modules = types.ModuleType("modules")

    class Modules:
        def __init__(self, st):
            self.st = st

        def builtin_firmware(self):
            # firmware ends up in the first (uncompressed) segment
            os.makedirs(os.path.join(self.st.dest, "usr/lib/firmware"), exist_ok=True)
            self.st.copy_file("binary", "/usr/lib/firmware/fake.bin.xz")

        def __getattr__(self, name):
            return lambda *a, **k: None

    modules.Modules = Modules
    stockhooks = types.ModuleType("stockhooks")
    stockhooks.run_stock_hooks = lambda st, mods, skip=(): None
    stockhooks.hook_kmod = lambda st, mods, conf=None: None
    sys.modules.update(stage=stage, modules=modules, stockhooks=stockhooks)
    hook_path = os.path.join(base, "hook_stub.py")
    write(hook_path, "def run(stage, modules, list_path):\n"
                     "    open(stage.dest + '/etc/hook-ran', 'w').write(list_path)\n")
    spec = importlib.util.spec_from_file_location("hook_stub", hook_path)
    hook = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hook)
    return hook_path, hook


def run_cli(args):
    spec = importlib.util.spec_from_file_location("build_recovery_initrd",
                                                  os.path.join(REPO, "unitotem/build-recovery-initrd.py"))
    cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cli)
    return cli.main(args)


def sh(cmd):
    return subprocess_run(cmd, capture_output=True, check=True).stdout


base = tempfile.mkdtemp(prefix="ninitrd-t4b-")
try:
    os.makedirs(os.path.join(base, "in"))
    root = make_root(os.path.join(base, "in"))
    engine = os.path.join(base, "ota-engine.sh")
    write(engine, "#!/bin/bash\necho engine\n", 0o600)
    listing = os.path.join(base, "ota-initrd.list")
    write(listing, "# fixture\nbin bash\n")
    hook_path, _ = stub_modules(base)
    out = os.path.join(base, "out")
    work = os.path.join(base, "work")
    os.makedirs(work)

    run_cli(["--arch", "arm64", "--rootfs", root, "--out", out, "--work", work, "--engine", engine,
             "--list", listing, "--hook-script", hook_path])
    initrd = os.path.join(out, "recovery-initrd-arm64.img")
    check(os.path.isfile(initrd), "initrd written")
    check(os.path.isfile(os.path.join(out, "recovery-vmlinuz-arm64")), "vmlinuz copied")
    manifest = open(os.path.join(out, "recovery.manifest"), encoding="utf-8").read()
    for key in ("UNITOTEM_RECOVERY_ARCH=arm64", f"UNITOTEM_RECOVERY_KERNEL_VERSION={KVER}",
                "UNITOTEM_RECOVERY_PARTCLONE_VERSION=0.3.31-1", "UNITOTEM_RECOVERY_INITRD_SHA256=",
                "UNITOTEM_RECOVERY_BUILD_DATE="):
        check(key in manifest, f"manifest has {key}")

    img = open(initrd, "rb").read()
    zmagic = b"\x28\xb5\x2f\xfd"
    trailer = img.find(b"TRAILER!!!")
    check(trailer >= 0, "first segment ends with a cpio trailer")
    z = img.find(zmagic, trailer)
    check(z > trailer and set(img[trailer + 21:z]) <= {0},
          "second segment is a zstd frame after the trailer block padding")
    seg1 = os.path.join(work, "seg1.cpio")
    seg2 = os.path.join(work, "seg2.zst")
    open(seg1, "wb").write(img[:z])
    open(seg2, "wb").write(img[z:])
    seg2_plain = os.path.join(work, "seg2.cpio")
    subprocess_run(["zstd", "-q", "-d", "-f", seg2, "-o", seg2_plain], check=True)
    seg2 = seg2_plain
    seg1_list = sh(["cpio", "--quiet", "-tv", "-H", "newc", "-F", seg1]).decode()
    seg2_list = sh(["cpio", "--quiet", "-tv", "-H", "newc", "-F", seg2]).decode()
    check("fake.bin.xz" in seg1_list and "fake.bin.xz" not in seg2_list,
          "*.xz files are in the uncompressed first segment only")
    lines = [l for l in (seg1_list + seg2_list).splitlines() if l.strip()]
    check(all(l.split()[2:4] == ["root", "root"] for l in lines), "every entry owned by root:root")
    check(any(l.startswith("lrwxrwxrwx") and l.endswith(" bin -> usr/bin") for l in seg2_list.splitlines()),
          "usr-merge symlink bin -> usr/bin in the skeleton")
    check(any(l.endswith(" lib -> usr/lib") for l in seg2_list.splitlines()), "lib -> usr/lib symlink present")

    ex = os.path.join(base, "extract")
    os.makedirs(ex)
    subprocess_run = __import__("subprocess").run
    for seg in (seg1, seg2):
        subprocess_run(["cpio", "--quiet", "-idm", "-H", "newc", "-D", ex], input=open(seg, "rb").read(), check=True)
    order_premount = open(os.path.join(ex, "scripts/init-premount/ORDER"), encoding="utf-8").read()
    check('/scripts/init-premount/zz-unitotem-ota "$@"' in order_premount, "premount ORDER lists zz-unitotem-ota")
    order_top = open(os.path.join(ex, "scripts/init-top/ORDER"), encoding="utf-8").read()
    check(order_top.index("/scripts/init-top/udev") < order_top.index("/scripts/init-top/keymap"),
          "tsort puts the PREREQ before its script")
    check("notexec" not in order_top and ".hidden" not in order_top, "non-executable and dot scripts skipped")
    check(os.path.isfile(os.path.join(ex, "scripts/local-top/mine")), "CONFDIR script copied")
    check(os.path.isfile(os.path.join(ex, "usr/lib/firmware/fake.bin.xz")), "firmware .xz file in the tree")
    check(open(os.path.join(ex, "conf/initramfs.conf"), encoding="utf-8").read().count("MODULES=most") == 1,
          "MODULES forced to most in conf/initramfs.conf")
    check(open(os.path.join(ex, "conf/arch.conf"), encoding="utf-8").read() == "DPKG_ARCH=arm64\n", "arch.conf")
    check(os.path.isfile(os.path.join(ex, "conf/conf.d/unitotem-compress")), "conf.d copied")
    check(os.path.isfile(os.path.join(ex, "etc/modprobe.d/fixture.conf")), "modprobe.d copied")
    check(os.path.islink(os.path.join(ex, "etc/mtab")) and os.readlink(os.path.join(ex, "etc/mtab")) == "/proc/mounts",
          "mtab symlink")
    check(open(os.path.join(ex, "usr/lib/unitotem/ota-engine.sh"), encoding="utf-8").read() == "#!/bin/bash\necho engine\n",
          "engine copied from --engine")
    check(os.stat(os.path.join(ex, "usr/lib/unitotem/ota-engine.sh")).st_mode & 0o777 == 0o755, "engine mode 755")
    check(os.listdir(os.path.join(ex, "usr/lib/unitotem")) == ["ota-engine.sh"],
          "no logo blob shipped: the engine is the only file of usr/lib/unitotem")
    check(os.path.isfile(os.path.join(ex, "etc/hook-ran")), "project hook called")
    check(os.path.isfile(os.path.join(ex, "scripts/init-premount/zz-unitotem-ota")), "premount script installed")
    check(os.path.isfile(os.path.join(ex, "lib/modules", KVER, "modules.builtin")), "builtin module files copied")

    # --stage1 tarball path gives the same tree layout
    tarball = os.path.join(base, "stage1.tar.gz")
    with tarfile.open(tarball, "w:gz") as tf:
        tf.add(root, arcname=".")
    out2 = os.path.join(base, "out2")
    run_cli(["--arch", "arm64", "--stage1", tarball, "--out", out2, "--work", os.path.join(base, "work2"),
             "--engine", engine, "--list", listing, "--hook-script", hook_path])
    check(os.path.isfile(os.path.join(out2, "recovery-initrd-arm64.img")), "--stage1 tarball builds")

    # two kernels: fails with a message
    base3 = tempfile.mkdtemp(prefix="ninitrd-t4b-two-", dir=base)
    root3 = make_root(base3, kvers=(KVER, KVER + "-b"))
    err = io.StringIO()
    code = None
    with contextlib.redirect_stderr(err):
        try:
            run_cli(["--arch", "arm64", "--rootfs", root3, "--out", os.path.join(base3, "o"), "--work",
                     os.path.join(base3, "w"), "--engine", engine, "--list", listing,
                     "--hook-script", hook_path])
        except SystemExit as exc:
            code = exc.code
    check(code == 1 and "expected exactly one kernel" in err.getvalue(), "two kernels fail with a clear message")
    # size guard: amd64 over the limit fails, arm64 and a small file pass
    sys.path.insert(0, os.path.join(REPO, "unitotem"))
    spec = importlib.util.spec_from_file_location("brid", os.path.join(REPO, "unitotem", "build-recovery-initrd.py"))
    brid = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(brid)
    big = os.path.join(base, "big.img")
    with open(big, "wb") as fh:
        fh.truncate(brid.INITRD_MAX["amd64"] + 1)
    err = io.StringIO()
    code = None
    with contextlib.redirect_stderr(err):
        try:
            brid.check_size(big, "amd64")
        except SystemExit as exc:
            code = exc.code
    check(code == 1 and "out of memory" in err.getvalue(), "an amd64 recovery initrd over the limit fails the build")
    brid.check_size(big, "arm64")
    with open(big, "r+b") as fh:
        fh.truncate(brid.INITRD_MAX["amd64"])
    brid.check_size(big, "amd64")
    check(True, "an amd64 initrd at the limit and an arm64 one pass")
finally:
    if failures:
        print(f"fixture kept for inspection: {base}")
    else:
        shutil.rmtree(base, ignore_errors=True)

if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks passed")
PY
