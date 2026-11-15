#!/bin/bash
# Tests of unitotem/ninitrd/stockhooks.py (native port of the stock initramfs-tools hooks).
# Part 1: fixture checks (tmp dirs only, fake Stage for the error paths).
# Part 2: run_stock_hooks against the stage-1 rootfs into a tmp DEST (arm64, kver 6.18.60+rpt-rpi-v8),
#         in the mkinitramfs order around the hooks (body skeleton, module apply, hooks, apply, kmod rerun);
#         the produced tree is compared with the reference initrd (work/native-initrd/ninitrd-ref).
#         No target binary is run. Only host readelf, cpio-free comparison, and host fc-cache on DEST.
#   bash tools/release/test_native_initrd_hooks.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ROOTFS="$REPO/work/native-initrd/ninitrd-rootfs"
REF="$REPO/work/native-initrd/ninitrd-ref"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-native-hooks.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

exec python3 -I - "$REPO/unitotem/ninitrd" "$ROOTFS" "$REF" "$TMP" <<'PY'
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

NINITRD, ROOTFS, REF, TMP = sys.argv[1:5]
sys.dont_write_bytecode = True  # no __pycache__ in the repository
sys.path.insert(0, NINITRD)
import stockhooks as sh  # noqa: E402
from stage import Stage  # noqa: E402
from modules import Modules  # noqa: E402

KVER = "6.18.60+rpt-rpi-v8"
ARCH = "arm64"
FAILS = []
PASSES = []


def check(name, cond, detail=""):
    if cond:
        PASSES.append(name)
        print(f"PASS: {name}")
    else:
        FAILS.append(name)
        print(f"FAIL: {name} {detail}")


def fresh_dest(base, name):
    """Body skeleton of mkinitramfs: usr-merged dirs and symlinks, conf, etc, run, scripts, module dir."""
    dest = os.path.join(base, name)
    os.makedirs(dest)
    for d in ("bin", "lib", "sbin"):
        os.makedirs(os.path.join(dest, "usr", d))
        os.symlink("usr/" + d, os.path.join(dest, d))
    for d in ("conf/conf.d", "etc", "run", "scripts", "lib/modules/" + KVER):
        os.makedirs(os.path.join(dest, d))
    return dest


# ---- part 1: fixtures -------------------------------------------------------------------------

class FakeStage:
    """Minimal Stage for error paths: copy_exec always fails, no file access."""

    def __init__(self, root, dest, arch=ARCH, kver=KVER):
        self.root, self.dest, self.arch, self.kver = root, dest, arch, kver
        self.triplet = "aarch64-linux-gnu"
        self.warnings = []
        self.calls = []

    def warn(self, msg):
        self.warnings.append(msg)

    def readlink_f(self, path):
        return path

    def copy_exec(self, src, target=None):
        self.calls.append(src)
        return 1

    def copy_file(self, kind, src, target=None):
        self.calls.append(src)
        return 2

    def command_v(self, name):
        return None


class Recorder:
    def __init__(self):
        self.names, self.dirs = [], []

    def add(self, names):
        self.names.extend(names)

    def add_dir(self, dirname, excludes=()):
        self.dirs.append((dirname, tuple(excludes)))


tmp_fix = tempfile.mkdtemp(dir=TMP, prefix="fix-")
fake_root = os.path.join(tmp_fix, "root")
os.makedirs(os.path.join(fake_root, "etc/initramfs-tools/conf.d"))
os.makedirs(os.path.join(fake_root, "etc/plymouth"))
os.makedirs(os.path.join(fake_root, "usr/share/plymouth"))

# plymouth theme name: plymouthd.conf absent, default theme not installed -> text
st = FakeStage(fake_root, os.path.join(tmp_fix, "dest"))
check("theme falls back to text when no theme is readable",
      sh._plymouth_theme(st) == "text")
with open(os.path.join(fake_root, "usr/share/plymouth/plymouthd.defaults"), "w") as f:
    f.write("[Daemon]\nTheme=ceratopsian\n")
check("theme falls back to plymouthd.defaults value when that theme is installed",
      sh._plymouth_theme(st) == "text")  # ceratopsian not installed in the fixture
os.makedirs(os.path.join(fake_root, "usr/share/plymouth/themes/ceratopsian"))
open(os.path.join(fake_root, "usr/share/plymouth/themes/ceratopsian/ceratopsian.plymouth"), "w").close()
check("theme read from plymouthd.defaults when installed",
      sh._plymouth_theme(st) == "ceratopsian")
with open(os.path.join(fake_root, "etc/plymouth/plymouthd.conf"), "w") as f:
    f.write("# comment\n[Daemon]\nTheme=unknown\n")
check("unreadable Theme= in plymouthd.conf falls through to the defaults",
      sh._plymouth_theme(st) == "ceratopsian")

# fsck: root entry is not identified without the device; /usr with a type is used; FSTYPE overrides
with open(os.path.join(fake_root, "etc/fstab"), "w") as f:
    f.write("# comment\n/dev/mmcblk0p2 / ext4 defaults 0 1\n/dev/mmcblk0p5 /usr ext4 ro 0 2\n")
warned = len(st.warnings)
check("fsck: root type is not probed in a foreign rootfs",
      sh._fsck_types(st, {"FSTYPE": "auto"}) == ["ext4"] and len(st.warnings) == warned + 1,
      f"types={sh._fsck_types(st, {'FSTYPE': 'auto'})}")
check("fsck: FSTYPE list overrides fstab",
      sh._fsck_types(st, {"FSTYPE": "vfat,ext4"}) == ["ext4", "vfat"])
with open(os.path.join(fake_root, "etc/fstab"), "w") as f:
    f.write("/dev/x /usr vfat ro 0 2\n")
check("fsck: /usr fstab type taken as is",
      sh._fsck_types(st, {"FSTYPE": "auto"}) == ["vfat"])

# keymap: KEYMAP=y is refused, not silently skipped
try:
    sh.hook_keymap(st, Recorder(), {"KEYMAP": "y"})
    check("keymap: KEYMAP=y refused", False, "no error")
except NotImplementedError:
    check("keymap: KEYMAP=y refused", True)

# dmsetup: a missing rule aborts like the stock exit 1
fdest = os.path.join(tmp_fix, "dm")
os.makedirs(os.path.join(fdest, "usr/lib/udev/rules.d"))
try:
    sh.hook_dmsetup(FakeStage(fake_root, fdest), Recorder(), {})
    check("dmsetup: missing udev rule aborts", False, "no error")
except sh.HookError:
    check("dmsetup: missing udev rule aborts", True)

# copy_exec failures abort the hook (set -e in the stock hooks)
try:
    sh.hook_raspi_firmware_fsck(FakeStage(fake_root, fdest), Recorder(), {})
    check("raspi-firmware-fsck: failed copy aborts", False, "no error")
except sh.HookError:
    check("raspi-firmware-fsck: failed copy aborts", True)

# kconfig: CONFIG_MODULE_DECOMPRESS=y in the target config
os.makedirs(os.path.join(fake_root, "boot"))
with open(os.path.join(fake_root, "boot/config-" + KVER), "w") as f:
    f.write("CONFIG_MODULE_DECOMPRESS=y\n")
check("kconfig: CONFIG_MODULE_DECOMPRESS=y read from the target config",
      sh._kconfig_yes(st, "CONFIG_MODULE_DECOMPRESS"))
with open(os.path.join(fake_root, "boot/config-" + KVER), "w") as f:
    f.write("# CONFIG_MODULE_DECOMPRESS is not set\n")
check("kconfig: unset option is not yes",
      not sh._kconfig_yes(st, "CONFIG_MODULE_DECOMPRESS"))

# conf: initramfs.conf then conf.d, quotes stripped
with open(os.path.join(fake_root, "etc/initramfs-tools/initramfs.conf"), "w") as f:
    f.write("MODULES=most\nKEYMAP=n\n# FSTYPE=x\nFSTYPE=auto\n")
with open(os.path.join(fake_root, "etc/initramfs-tools/conf.d/x"), "w") as f:
    f.write('KEYMAP="y"\n')
conf = sh.read_conf(st)
check("conf: conf.d overrides initramfs.conf and quotes are stripped",
      conf["KEYMAP"] == "y" and conf["MODULES"] == "most" and conf["FSTYPE"] == "auto", str(conf))

# run order: udev before dmsetup, all hooks present once
order = sh.hook_order()
check("hook order: udev before dmsetup", order.index("udev") < order.index("dmsetup"))
check("hook order: every hook exactly once", sorted(order) == sorted(sh.HOOKS) and len(order) == len(sh.HOOKS))

# tsort cross-check: host tsort on the same pairs as get_prereq_pairs
pairs = []
for name in sorted(sh.HOOK_PREREQS):
    pairs.append(f"{name} {name}")
    for prereq in sh.HOOK_PREREQS[name]:
        pairs.append(f"{prereq} {name}")
tsort = subprocess.run(["tsort"], input="\n".join(pairs) + "\n", capture_output=True, text=True,
                       env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
check("hook order equals host tsort on the stock pairs",
      tsort.returncode == 0 and tsort.stdout.split() == order,
      f"tsort={tsort.stdout.split()} order={order}")

# ---- part 2: produced tree against the reference -----------------------------------------------

def listing(base):
    out = {}
    for top, dirs, files in os.walk(base):
        for name in dirs + files:
            full = os.path.join(top, name)
            rel = os.path.relpath(full, base)
            if os.path.islink(full):
                out[rel] = ("l", os.readlink(full), None)
            elif os.path.isdir(full):
                out[rel] = ("d", "", None)
            else:
                with open(full, "rb") as handle:
                    out[rel] = ("f", "", hashlib.sha256(handle.read()).hexdigest())
    return out


# kmod alone: the xz rule (CONFIG_MODULE_DECOMPRESS unset, .ko.xz modules present) copies liblzma;
# no .zst module exists, so the zstd rule copies nothing.
kdest = fresh_dest(TMP, "kmod-only")
kstage = Stage(ROOTFS, kdest, ARCH, KVER, warn=lambda m: None)
kmods = Modules(kstage)
kmods.most()
kmods.apply()
sh.hook_kmod(kstage, kmods)
check("kmod alone copies liblzma for the .ko.xz modules",
      os.path.exists(os.path.join(kdest, "usr/lib/aarch64-linux-gnu/liblzma.so.5")))
# libzstd is in the copy_exec closure of kmod (libcrypto NEEDED); the zstd rule adds nothing here.
kmod_closure = [lib for lib in kstage.libraries("/usr/bin/kmod") if "libzstd" in lib]
check("kmod alone: libzstd comes from the kmod closure, not the zstd rule",
      bool(kmod_closure) and os.path.exists(os.path.join(kdest, "usr/lib/aarch64-linux-gnu/libzstd.so.1")),
      str(kmod_closure))

dest = fresh_dest(TMP, "dest")
stage = Stage(ROOTFS, dest, ARCH, KVER, warn=lambda m: print("  stage-warn: " + m))
mods = Modules(stage)
mods.most()
mods.apply()
sh.run_stock_hooks(stage, mods)
mods.apply()
sh.hook_kmod(stage, mods)
before_rerun = listing(dest)
sh.hook_kmod(stage, mods)
check("hook kmod rerun leaves DEST unchanged", listing(dest) == before_rerun)

# Library closure of the hook binaries (readelf NEEDED, as copy_exec does): each must be in DEST.
HOOK_BINARIES = ["/usr/lib/systemd/systemd-udevd", "/usr/bin/udevadm", "/usr/sbin/dmsetup", "/usr/bin/kmod",
                 "/usr/bin/plymouth", "/usr/sbin/plymouthd", "/sbin/fsck.ext4", "/sbin/fsck.vfat",
                 "/sbin/blkid", "/usr/lib/udev/ata_id", "/usr/lib/udev/scsi_id",
                 "/usr/libexec/plymouth/plymouthd-fd-escrow",
                 f"/usr/lib/{stage.triplet}/plymouth/script.so"]
closure_missing = []
for binary in HOOK_BINARIES:
    for lib in stage.libraries(binary):
        if not os.path.exists(os.path.join(dest, lib.lstrip("/"))):
            closure_missing.append(f"{binary}:{lib}")
check("library closure of the hook binaries is in DEST", not closure_missing,
      " ".join(closure_missing))

IGNORE_TOP = {"bin", "sbin", "lib", "init", "scripts", "conf", "run", "root"}
IGNORE_PREFIX = ("lib/modules", "usr/lib/modules", "lib/firmware", "usr/lib/firmware",
                 "etc/alternatives", "etc/fstab", "etc/mtab", "etc/group", "etc/ld.so",
                 "etc/modprobe.d", "etc/passwd", "etc/nsswitch.conf",
                 "usr/lib/unitotem", "usr/sbin/unitotem", "usr/share/terminfo", "root/",
                 "var/cache/ldconfig")
CACHE_DIR = "var/cache/fontconfig/"
LIB_PREFIX = (f"usr/lib/{stage.triplet}/", "usr/lib/ld-linux-")
# Project list (T3, unitotem/files/ota-initrd.list): names it adds or overrides are not hook output.
LIST = os.path.join(NINITRD, "..", "files", "ota-initrd.list")
sys.path.insert(0, NINITRD)
from lists import read_list  # noqa: E402

project_names, real_names, project_bins = set(), set(), []
for directive, args in read_list(LIST):
    if directive in ("bin", "real", "x86-bin"):
        project_names.update(args)
        if directive == "real":
            real_names.update(args)
        if directive != "x86-bin":
            project_bins.extend(args)
    elif directive == "file":
        project_names.add(os.path.basename(args[-1] if len(args) > 1 else args[0]))
# Special cases of unitotem/files/ota-hook (nc alternatives link, reboot real binary).
project_names.update(("nc", "nc.traditional", "reboot"))


def listing(base):
    out = {}
    for top, dirs, files in os.walk(base):
        for name in dirs + files:
            full = os.path.join(top, name)
            rel = os.path.relpath(full, base)
            if os.path.islink(full):
                out[rel] = ("l", os.readlink(full), None)
            elif os.path.isdir(full):
                out[rel] = ("d", "", None)
            else:
                with open(full, "rb") as handle:
                    out[rel] = ("f", "", hashlib.sha256(handle.read()).hexdigest())
    return out


def keep(rel):
    if rel in IGNORE_TOP or rel.split("/", 1)[0] in IGNORE_TOP:
        return False
    return not rel.startswith(IGNORE_PREFIX)


def cache_offsets(a, b):
    """Byte offsets where two cache files differ."""
    with open(a, "rb") as fa, open(b, "rb") as fb:
        da, db = fa.read(), fb.read()
    if len(da) != len(db):
        return None
    return [i for i in range(len(da)) if da[i] != db[i]]


produced = {k: v for k, v in listing(dest).items() if keep(k)}
reference = {k: v for k, v in listing(REF).items() if keep(k)}

extra = sorted(set(produced) - set(reference))
missing = sorted(set(reference) - set(produced))
common = sorted(set(produced) & set(reference))
kind_diff = [p for p in common if produced[p][:2] != reference[p][:2]]
content_diff = [p for p in common if produced[p][0] == "f" and produced[p][2] != reference[p][2]
                and not p.startswith(CACHE_DIR)]
real_diff = [p for p in content_diff if os.path.basename(p) in real_names]
content_diff = [p for p in content_diff if p not in real_diff]
cache_names = sorted(p for p in reference if p.startswith(CACHE_DIR) and p.endswith(".cache-9"))
cache_bad = []
for name in cache_names:
    if name not in produced:
        cache_bad.append(name + " absent")
        continue
    offsets = cache_offsets(os.path.join(dest, name), os.path.join(REF, name))
    # fontconfig stores the scanned directories' mtimes at header offsets 48-63
    if offsets is None or any(not 48 <= off < 64 for off in offsets):
        cache_bad.append(name + " differs outside the directory mtime")
cache_bad += [p for p in produced if p.startswith(CACHE_DIR) and p not in reference]

# Library closure of the project binaries (resolved in ROOT) explains the reference-only libraries.
project_closure = set()


def usr_rel(path):
    rel = path.lstrip("/")
    return "usr/" + rel if rel.startswith("lib/") else rel


for name in project_bins:
    path = stage.command_v(name)
    if not path:
        continue
    # an alternatives or link name also brings its target (copy_file copies the link target)
    project_names.add(os.path.basename(stage.readlink_f(path)))
    for lib in stage.libraries(path):
        project_closure.add(usr_rel(lib))
        project_closure.add(usr_rel(stage.readlink_f(lib)))
# copy_libgcc: a project binary linked to libpthread also pulls libgcc_s.so.1 (stock copy_exec)
project_closure.add("usr/lib/" + stage.triplet + "/libgcc_s.so.1")
# Project-hook output that no list name explains: reboot resolves to systemd's binary, and
# ota-hook / otahook.py copy readlink -f of reboot (usr/bin/systemctl). This test runs only the
# stock hooks; the project hook is covered by tools/release/test_native_initrd_otahook.sh.
PROJECT_HOOK_PATHS = ("usr/bin/systemctl",)
missing_hook = [p for p in missing if not p.startswith(LIB_PREFIX)
                and os.path.basename(p) not in project_names and p not in PROJECT_HOOK_PATHS]
missing_lib = [p for p in missing if p.startswith(LIB_PREFIX)]
missing_lib_unexplained = [p for p in missing_lib if p not in project_closure]

check("no hook-produced path absent from the reference", not extra, "extra=" + " ".join(extra))
check("link and directory entries match the reference", not kind_diff,
      "kind/target differs: " + " ".join(kind_diff))
check("reference paths owned by the hooks are produced", not missing_hook,
      "missing=" + " ".join(missing_hook))
check("hook-owned file contents match the reference", not content_diff,
      "content differs: " + " ".join(content_diff))
check("fontconfig caches: same names, differences only in directory mtimes", not cache_bad,
      " ".join(cache_bad))
check("reference-only libraries belong to project binaries", not missing_lib_unexplained,
      " ".join(missing_lib_unexplained))
print(f"INFO: produced={len(produced)} reference={len(reference)} common={len(common)}")
print("INFO: contents overridden by project 'real' directives (klibc vs real): " + " ".join(real_diff))
print("INFO: reference-only project names (bin/real/file, not hook output): "
      + " ".join(p for p in missing if os.path.basename(p) in project_names))
shutil.rmtree(tmp_fix)
print(f"SUMMARY: {len(PASSES)} passed, {len(FAILS)} failed")
sys.exit(1 if FAILS else 0)
PY
