#!/bin/bash
# Tests of unitotem/ninitrd/otahook.py (native port of unitotem/files/ota-hook) with the real Stage
# (stage.py) and a recording stub for Modules. ROOT is a tiny fixture tree: every target binary is a
# plain file (no ELF, nothing is executed). Checks: the symlinks (/usr/sbin/unitotem-ota-engine, nc
# alternatives, reboot -> systemctl), /root/.ssh mode 700, module and module-opt selection, the x86
# section on and off by arch and efibootmgr, unknown directives raising, package-version, plymouth-plugin
# (copied per arch, absent plugin silent) and replace (a stock symlink becomes the file, mode 644).
# Fixtures live in a mktemp directory removed by the script. Nothing outside it is written.
#   bash tools/release/test_native_initrd_otahook.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-native-otahook.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

exec python3 -I - "$REPO/unitotem/ninitrd" "$TMP" <<'PY'
import os
import stat
import sys

NINITRD, TMP = sys.argv[1:3]
sys.dont_write_bytecode = True  # no __pycache__ in the repository
sys.path.insert(0, NINITRD)
import otahook  # noqa: E402
from stage import Stage  # noqa: E402

KVER = "6.18.60+rpt-rpi-v8"
PASSES = []
FAILS = []

LIST_TEXT = """\
# fixture of unitotem/files/ota-initrd.list: every directive kind
bin bash mountpoint nosuchtool
real realtool
file /etc/group
file /usr/lib/unitotem/ota-engine.sh
terminfo l/linux
module mod_forced
module-opt present-mod absent_mod builtin-mod
x86-bin x86tool
x86-module x86mod
x86-dir /usr/lib/x86dir
package-version unitotem /usr/share/unitotem/boot-version
package-version absentpkg /usr/share/unitotem/absent-version
package-version rcpkg /usr/share/unitotem/rc-version
package-version badver /usr/share/unitotem/bad-version
plymouth-plugin label-freetype.so
plymouth-plugin absent-plugin.so
replace /usr/share/plymouth/themes/unitotem/NotoSans-subset.ttf /usr/share/fonts/Plymouth.ttf
"""

# fixture dpkg status: installed, absent, removed-with-config-files, and an installed package whose
# version has a character outside the allowed set
STATUS_TEXT = """\
Package: unitotem
Status: install ok installed
Version: 2026.12~dev2
Architecture: arm64

Package: rcpkg
Status: deinstall ok config-files
Version: 1.0

Package: badver
Status: install ok installed
Version: 1.0;rm

"""


def check(name, cond, detail=""):
    if cond:
        PASSES.append(name)
        print(f"PASS: {name}")
    else:
        FAILS.append(name)
        print(f"FAIL: {name} {detail}")


def write(path, text="", mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, mode)


def link(target, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(target, path)


def build_root(base, efi):
    """Fixture rootfs: usr-merged top level, Debian alternatives chain for nc, reboot -> systemctl."""
    root = os.path.join(base, "root")
    os.makedirs(root)
    for d in ("bin", "sbin", "lib"):
        link("usr/" + d, os.path.join(root, d))
    write(os.path.join(root, "usr/bin/bash"), "#!/bin/sh\n", 0o755)
    write(os.path.join(root, "usr/bin/mountpoint"), "mountpoint\n", 0o755)
    write(os.path.join(root, "usr/bin/nc.traditional"), "nc fixture\n", 0o755)
    link("/usr/bin/nc.traditional", os.path.join(root, "etc/alternatives/nc"))
    link("/etc/alternatives/nc", os.path.join(root, "usr/bin/nc"))
    write(os.path.join(root, "usr/bin/systemctl"), "systemctl fixture\n", 0o755)
    link("systemctl", os.path.join(root, "usr/bin/reboot"))
    write(os.path.join(root, "usr/bin/realtool"), "realtool fixture\n", 0o755)
    write(os.path.join(root, "usr/bin/x86tool"), "x86tool fixture\n", 0o755)
    write(os.path.join(root, "etc/group"), "root:x:0:\n")
    write(os.path.join(root, "var/lib/dpkg/status"), STATUS_TEXT)
    write(os.path.join(root, "usr/lib/unitotem/ota-engine.sh"), "#!/bin/bash\n", 0o755)
    write(os.path.join(root, "usr/share/terminfo/l/linux"), "linux terminfo fixture\n")
    write(os.path.join(root, "usr/lib/x86dir/marker"), "x\n")
    for triplet in ("aarch64-linux-gnu", "x86_64-linux-gnu"):
        write(os.path.join(root, f"usr/lib/{triplet}/plymouth/label-freetype.so"), "freetype plugin fixture\n", 0o755)
        write(os.path.join(root, f"usr/lib/{triplet}/plymouth/label-pango.so"), "pango plugin fixture\n", 0o755)
    write(os.path.join(root, "usr/share/plymouth/themes/unitotem/NotoSans-subset.ttf"), "NotoSans fixture\n", 0o644)
    kdir = os.path.join(root, "usr/lib/modules", KVER)
    write(os.path.join(kdir, "modules.dep"),
          "kernel/drivers/x/present_mod.ko.xz:\nkernel/drivers/x/other.ko:\n")
    write(os.path.join(kdir, "modules.builtin"), "kernel/drivers/y/builtin_mod.ko\n")
    if efi:
        write(os.path.join(root, "usr/sbin/efibootmgr"), "efibootmgr fixture\n", 0o755)
    return root


class RecordingModules:
    def __init__(self):
        self.added = []

    def add(self, names):
        self.added.append(list(names))

    def add_dir(self, dirname, excludes=()):
        self.added.append(["dir:" + dirname])


def run_case(tag, arch, efi, list_path):
    """otahook.run against a fresh ROOT and DEST for one arch and efibootmgr setting."""
    base = os.path.join(TMP, tag)
    root = build_root(base, efi)
    dest = os.path.join(base, "dest")
    for d in ("usr/bin", "usr/sbin", "usr/lib", "usr/share/fonts", "etc", "root"):
        os.makedirs(os.path.join(dest, d))
    for d in ("bin", "sbin", "lib"):
        link("usr/" + d, os.path.join(dest, d))
    # BusyBox placeholder that the real directive must overwrite
    write(os.path.join(dest, "usr/bin/realtool"), "busybox placeholder\n", 0o755)
    # the link the stock plymouth hook makes (DejaVu Sans); the replace directive must turn it into a file
    link("/usr/share/fonts/DejaVuSans.ttf", os.path.join(dest, "usr/share/fonts/Plymouth.ttf"))

    warnings = []
    stage = Stage(root, dest, arch, KVER, warn=warnings.append)
    copies = []
    orig_copy_file = stage.copy_file

    def recording_copy_file(kind, src, target=None):
        copies.append((kind, src))
        return orig_copy_file(kind, src, target)

    stage.copy_file = recording_copy_file
    modules = RecordingModules()
    otahook.run(stage, modules, list_path)
    return dest, warnings, modules.added, copies


def p(dest, rel):
    return os.path.join(dest, rel)


def is_file_with(path, text):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read() == text
    except OSError:
        return False


LIST = os.path.join(TMP, "fixture-ota-initrd.list")
write(LIST, LIST_TEXT)

CASES = [
    ("arm64-noefi", "arm64", False, False),
    ("amd64", "amd64", False, True),
    ("arm64-efi", "arm64", True, True),
]

for tag, arch, efi, x86_on in CASES:
    dest, warnings, added, copies = run_case(tag, arch, efi, LIST)
    t = f"[{tag}] "

    # common output of every target
    check(t + "bash and etc/group copied", os.path.isfile(p(dest, "usr/bin/bash"))
          and os.path.isfile(p(dest, "etc/group")))
    check(t + "/usr/sbin/unitotem-ota-engine links to the engine",
          os.path.islink(p(dest, "usr/sbin/unitotem-ota-engine"))
          and os.readlink(p(dest, "usr/sbin/unitotem-ota-engine")) == "/usr/lib/unitotem/ota-engine.sh")
    check(t + "/bin/nc links to the real nc (alternatives followed)",
          os.path.islink(p(dest, "usr/bin/nc"))
          and os.readlink(p(dest, "usr/bin/nc")) == "/usr/bin/nc.traditional"
          and os.path.isfile(p(dest, "usr/bin/nc.traditional")))
    check(t + "/usr/sbin/reboot links to systemctl, which is copied",
          os.path.islink(p(dest, "usr/sbin/reboot"))
          and os.readlink(p(dest, "usr/sbin/reboot")) == "/usr/bin/systemctl"
          and is_file_with(p(dest, "usr/bin/systemctl"), "systemctl fixture\n"))
    mode = stat.S_IMODE(os.stat(p(dest, "root/.ssh")).st_mode) if os.path.isdir(p(dest, "root/.ssh")) else None
    check(t + "/root/.ssh is a directory with mode 700", mode == 0o700, f"mode={mode}")
    check(t + "real directive overwrites the BusyBox placeholder",
          is_file_with(p(dest, "usr/bin/realtool"), "realtool fixture\n"))
    check(t + "bin directive copies found commands", os.path.isfile(p(dest, "usr/bin/mountpoint")))
    check(t + "terminfo directive copies the entry",
          os.path.isfile(p(dest, "usr/share/terminfo/l/linux")))
    boot_version = p(dest, "usr/share/unitotem/boot-version")
    check(t + "package-version writes the installed version, one line",
          is_file_with(boot_version, "2026.12~dev2\n"), f"exists={os.path.exists(boot_version)}")
    check(t + "package-version writes nothing for an absent package",
          not os.path.lexists(p(dest, "usr/share/unitotem/absent-version")))
    check(t + "package-version writes nothing for a removed (config-files) package",
          not os.path.lexists(p(dest, "usr/share/unitotem/rc-version")))
    check(t + "package-version writes nothing for a version outside [0-9A-Za-z.+~:-]",
          not os.path.lexists(p(dest, "usr/share/unitotem/bad-version")))
    triplet = "aarch64-linux-gnu" if arch == "arm64" else "x86_64-linux-gnu"
    other = "x86_64-linux-gnu" if arch == "arm64" else "aarch64-linux-gnu"
    check(t + "plymouth-plugin copies label-freetype.so from the arch's plugin directory",
          is_file_with(p(dest, f"usr/lib/{triplet}/plymouth/label-freetype.so"), "freetype plugin fixture\n"))
    check(t + "plymouth-plugin does not copy the other arch's plugin",
          not os.path.lexists(p(dest, f"usr/lib/{other}/plymouth/label-freetype.so")))
    check(t + "absent plymouth plugin is silent (no file, no warning)",
          not os.path.lexists(p(dest, f"usr/lib/{triplet}/plymouth/absent-plugin.so"))
          and not any("absent-plugin" in w for w in warnings), f"warnings={warnings}")
    font = p(dest, "usr/share/fonts/Plymouth.ttf")
    check(t + "replace turns the stock Plymouth.ttf symlink into a copy of the theme font",
          not os.path.islink(font) and is_file_with(font, "NotoSans fixture\n"))
    check(t + "replace leaves the copied font at mode 644",
          os.path.isfile(font) and stat.S_IMODE(os.stat(font).st_mode) == 0o644)
    check(t + "missing bin is reported and skipped",
          any("nosuchtool" in w and "skipping" in w for w in warnings), f"warnings={warnings}")

    # module and module-opt: module-opt keeps only names the kernel has (modules.dep or builtin)
    expected = [["mod_forced"], ["present-mod", "builtin-mod"]]
    if x86_on:
        expected.append(["x86mod"])
    check(t + "module and module-opt selection (absent_mod dropped)",
          added == expected, f"added={added} expected={expected}")

    # x86 section: on when arch is not arm64, or efibootmgr exists in ROOT
    x86_bin = os.path.isfile(p(dest, "usr/bin/x86tool"))
    x86_dir = ("directory", "/usr/lib/x86dir") in copies
    check(t + f"x86 section {'on' if x86_on else 'off'}: x86-bin copied" if x86_on
          else t + "x86 section off: x86-bin not copied", x86_bin == x86_on)
    check(t + f"x86 section {'on' if x86_on else 'off'}: x86-dir staged", x86_dir == x86_on)

# unknown directives raise
BAD = os.path.join(TMP, "bad-ota-initrd.list")
write(BAD, "bin bash\nbogus-directive x\n")
raised = None
try:
    otahook.run(Stage(os.path.join(TMP, "bad-root"), os.path.join(TMP, "bad-dest"), "arm64", KVER,
                      warn=lambda m: None), RecordingModules(), BAD)
except ValueError as exc:
    raised = str(exc)
check("unknown directive raises ValueError", raised is not None and "unknown directive" in raised,
      f"raised={raised!r}")

# package-version validation in lists.py: PACKAGE DEST with an absolute, dot-free DEST
import lists  # noqa: E402
for bad in ("package-version unitotem\n", "package-version unitotem relative/path\n",
            "package-version unitotem /usr/../etc/x\n", "package-version UniTotem /usr/share/x\n",
            "plymouth-plugin\n", "plymouth-plugin label-freetype\n", "plymouth-plugin Label.so\n",
            "plymouth-plugin ../label.so\n", "plymouth-plugin label-freetype.so extra.so\n",
            "replace /usr/share/a\n", "replace relative/src /usr/share/fonts/Plymouth.ttf\n",
            "replace /usr/../etc/x /usr/share/fonts/Plymouth.ttf\n", "replace /a/b /c/../d\n"):
    bad_list = os.path.join(TMP, "pv-bad.list")
    write(bad_list, bad)
    rejected = False
    try:
        lists.read_list(bad_list)
    except lists.ListError:
        rejected = True
    check("lists.py rejects " + bad.strip(), rejected)
pv_ok = os.path.join(TMP, "pv-ok.list")
write(pv_ok, "package-version unitotem /usr/share/unitotem/boot-version\n")
check("lists.py accepts package-version PACKAGE DEST",
      lists.read_list(pv_ok) == [("package-version", ["unitotem", "/usr/share/unitotem/boot-version"])])

pr_ok = os.path.join(TMP, "pr-ok.list")
write(pr_ok, "plymouth-plugin label-freetype.so\nreplace /usr/share/plymouth/themes/unitotem/NotoSans-subset.ttf"
      " /usr/share/fonts/Plymouth.ttf\n")
check("lists.py accepts plymouth-plugin NAME.so and replace SRC DEST",
      lists.read_list(pr_ok) == [("plymouth-plugin", ["label-freetype.so"]),
                                 ("replace", ["/usr/share/plymouth/themes/unitotem/NotoSans-subset.ttf",
                                              "/usr/share/fonts/Plymouth.ttf"])])

print(f"SUMMARY: {len(PASSES)} passed, {len(FAILS)} failed")
sys.exit(1 if FAILS else 0)
PY
