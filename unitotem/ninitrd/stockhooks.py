"""Native port of the initramfs-tools hooks that mkinitramfs runs (initramfs-tools 0.151).

Source: /usr/share/initramfs-tools/hooks/{udev,dmsetup,fsck,keymap,klibc-utils,kmod,plymouth,
raspi-firmware-fsck,resume,thermal} and the run order of run_scripts/get_prereq_pairs.
Reads come from ROOT (the target tree), writes go to DEST. No target file is executed.
Stage (copy_file, copy_exec, command_v, readlink_f, root, dest, arch, warn) and Modules (add,
add_dir) are the only helpers used. The host fc-cache is the only host tool run, on DEST.

A hook that fails in the stock script raises HookError (the stock mkinitramfs aborts too).
Configuration: ROOT/etc/initramfs-tools/initramfs.conf and conf.d/*, simple NAME=value lines only.
"""

import fnmatch
import glob
import os
import re
import shutil
import subprocess

DRM_DIR = "kernel/drivers/gpu/drm"
# Stock exclude list of the plymouth hook. copy_modules_dir passes these to find -name, so
# without a .ko suffix they only prune directories of that name; the list is kept as stock.
DRM_EXCLUDES = ["mga", "r128", "savage", "sis", "tdfx", "via", "panfrost"]
THEMES = "/usr/share/plymouth/themes"
PLYMOUTH_TEXT_THEMES = ("text", "details", "tribar")
DEJAVU_SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
DEJAVU_MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
DM_RULES = ("55-dm.rules", "60-persistent-storage-dm.rules", "95-dm-notify.rules")
UDEV_RULES = (
    "50-firmware.rules", "50-udev-default.rules", "60-block.rules", "60-persistent-storage.rules",
    "61-persistent-storage-android.rules", "71-seat.rules", "73-special-net-names.rules",
    "75-net-description.rules", "80-net-setup-link.rules", "80-drivers.rules",
)
KLIBC_SKIP = ("gzip", "kinit", "zcat")
CONF_DEFAULTS = {"MODULES": "most", "KEYMAP": "n", "FSTYPE": "auto", "RESUME": ""}
RE_ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)")
RE_THEME_NAME = re.compile(r"[A-Za-z0-9_.+-]+")

# prereqs() of each hook. busybox is absent from the targets, so klibc-utils has no prerequisite
# (zz-busybox applies only when BUSYBOX is not n and BUSYBOXDIR is set).
HOOK_PREREQS = {
    "udev": (),
    "dmsetup": ("udev",),
    "fsck": (),
    "keymap": (),
    "klibc-utils": (),
    "kmod": (),
    "plymouth": (),
    "raspi-firmware-fsck": (),
    "resume": (),
    "thermal": (),
}


class HookError(RuntimeError):
    """A hook failed; the stock hook aborts mkinitramfs."""


# ---- paths ---------------------------------------------------------------------------------------

def _root_path(stage, path):
    """Host path of a target path in ROOT, every symlink (including the last part) resolved in ROOT."""
    return os.path.join(str(stage.root), stage.readlink_f(path).lstrip("/"))


def _root_keep_last(stage, path):
    """Host path of a target path in ROOT: ancestors resolved in ROOT, the last component kept."""
    parent, base = os.path.split(path.rstrip("/"))
    return os.path.join(_root_path(stage, parent or "/"), base)


def _dest(stage, path):
    return os.path.join(str(stage.dest), path.lstrip("/"))


def _exists(stage, path):
    try:
        return os.path.exists(_root_path(stage, path))
    except OSError:
        return False


def _isfile(stage, path):
    try:
        return os.path.isfile(_root_path(stage, path))
    except OSError:
        return False


def _isexec(stage, path):
    try:
        host = _root_path(stage, path)
        return os.path.isfile(host) and os.access(host, os.X_OK)
    except OSError:
        return False


def _mkdir(stage, path):
    os.makedirs(_dest(stage, path), exist_ok=True)


def _read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()
    except OSError:
        return []


# ---- copies --------------------------------------------------------------------------------------

def _exec(stage, src, target=None):
    rc = stage.copy_exec(src, target)
    if rc:
        raise HookError(f"copy_exec {src} failed with {rc}")


def _file(stage, kind, src):
    rc = stage.copy_file(kind, src)
    if rc not in (0, 1):
        raise HookError(f"copy_file {src} failed with {rc}")


def _cp_p(src_host, dst_host):
    """cp -p: content of the file, symlinks followed."""
    os.makedirs(os.path.dirname(dst_host), exist_ok=True)
    shutil.copy2(src_host, dst_host)


def _cp_a(src_host, dst_host):
    """cp -a / cp -dRp for one entry: symlinks stay symlinks, directories copied recursively."""
    os.makedirs(os.path.dirname(dst_host), exist_ok=True)
    if os.path.islink(src_host):
        target = os.readlink(src_host)
        if os.path.lexists(dst_host):
            if os.path.islink(dst_host) and os.readlink(dst_host) == target:
                return
            os.remove(dst_host)
        os.symlink(target, dst_host)
    elif os.path.isdir(src_host):
        shutil.copytree(src_host, dst_host, symlinks=True, dirs_exist_ok=True)
    else:
        shutil.copy2(src_host, dst_host)


def _cp_follow_target(stage, src, dst):
    """cp SRC DST (target paths): ROOT content copied to the DEST path dst, symlinks followed."""
    _cp_p(_root_path(stage, src), _dest(stage, dst))


# ---- configuration -------------------------------------------------------------------------------

def read_conf(stage):
    """Effective settings: initramfs.conf, then conf.d/* (simple NAME=value lines only)."""
    conf = dict(CONF_DEFAULTS)
    files = [os.path.join(str(stage.root), "etc/initramfs-tools/initramfs.conf")]
    files += sorted(glob.glob(os.path.join(str(stage.root), "etc/initramfs-tools/conf.d/*")))
    for path in files:
        for line in _read_lines(path):
            match = RE_ASSIGN.fullmatch(line.strip())
            if not match:
                continue
            value = match.group(2).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            conf[match.group(1)] = value
    return conf


# ---- run order -----------------------------------------------------------------------------------

def hook_order():
    """Run order of run_scripts: first hook in sorted name order whose prerequisites ran.

    Gives the same order as GNU tsort on the stock pairs (checked by the test script).
    """
    pending = sorted(HOOK_PREREQS)
    done = []
    while pending:
        for name in pending:
            if all(prereq in done for prereq in HOOK_PREREQS[name]):
                done.append(name)
                pending.remove(name)
                break
        else:
            raise HookError("cycle in hook prerequisites")
    return done


# ---- hooks ---------------------------------------------------------------------------------------

def hook_udev(stage, modules, conf=None):
    _mkdir(stage, "/usr/lib/systemd")
    _exec(stage, "/usr/lib/systemd/systemd-udevd")
    _exec(stage, "/usr/bin/udevadm")

    # libkmod is loaded with dlopen() since systemd v256
    for lib in sorted(glob.glob(os.path.join(str(stage.root), "usr/lib/*/libkmod.so.*"))):
        if os.path.isfile(lib):
            _exec(stage, "/" + os.path.relpath(lib, str(stage.root)))

    if _exists(stage, "/etc/udev/udev.conf"):
        _cp_follow_target(stage, "/etc/udev/udev.conf", "/etc/udev/udev.conf")
    if _exists(stage, "/usr/lib/udev/hwdb.bin"):
        _cp_follow_target(stage, "/usr/lib/udev/hwdb.bin", "/usr/lib/udev/hwdb.bin")

    # .link files: /usr/lib first, then /etc/systemd/network overwrites same names
    _mkdir(stage, "/usr/lib/systemd/network")
    for network in ("/usr/lib/systemd/network", "/etc/systemd/network"):
        _copy_link_files(stage, network)

    _mkdir(stage, "/usr/lib/udev/rules.d")
    for rule in UDEV_RULES:
        _copy_udev_rule(stage, rule)

    # chzdev filtering applies to s390 targets only
    if _exists(stage, "/usr/sbin/chzdev"):
        raise NotImplementedError("chzdev rule filtering (s390) is not ported")

    # local rules without a /usr/lib counterpart
    for rules in sorted(glob.glob(os.path.join(str(stage.root), "etc/udev/rules.d/*.rules"))):
        name = os.path.basename(rules)
        if os.path.exists(rules) and not _exists(stage, "/usr/lib/udev/rules.d/" + name):
            _cp_p(rules, _dest(stage, "/usr/lib/udev/rules.d/" + name))

    for program in ("ata_id", "scsi_id"):
        _exec(stage, "/usr/lib/udev/" + program)
    _exec(stage, "/sbin/blkid")


def _copy_udev_rule(stage, rule):
    """First of /etc/udev/rules.d and /usr/lib/udev/rules.d; missing rules are skipped (udev hook)."""
    for base in ("/etc/udev/rules.d/", "/usr/lib/udev/rules.d/"):
        if _exists(stage, base + rule):
            _cp_p(_root_path(stage, base + rule), _dest(stage, "/usr/lib/udev/rules.d/" + rule))
            return True
    return False


def _copy_link_files(stage, network):
    base = os.path.join(str(stage.root), network.lstrip("/"))
    if not os.path.isdir(base):
        return
    # find -L: symlinked directories are followed; cp -r copies the matches (links stay links)
    for top, dirnames, filenames in os.walk(base, followlinks=True):
        for name in sorted(dirnames) + sorted(filenames):
            if fnmatch.fnmatchcase(name, "*.link*"):
                _cp_a(os.path.join(top, name), _dest(stage, "/usr/lib/systemd/network/" + name))


def hook_dmsetup(stage, modules, conf=None):
    _mkdir(stage, "/usr/lib/udev/rules.d")
    for rule in DM_RULES:
        if not _copy_udev_rule(stage, rule):
            raise HookError(f"dmsetup: udev rule {rule} missing")
    _exec(stage, "/usr/sbin/dmsetup")
    modules.add(["dm_mod"])


def hook_fsck(stage, modules, conf=None):
    conf = conf or read_conf(stage)
    if not _isexec(stage, "/sbin/fsck"):
        return
    types = _fsck_types(stage, conf)
    if not types:
        return
    _exec(stage, "/sbin/fsck")
    _exec(stage, "/sbin/logsave")
    for ftype in types:
        prog = stage.command_v("fsck." + ftype)
        if prog:
            _exec(stage, prog)
        else:
            stage.warn(f"W: /sbin/fsck.{ftype} doesn't exist, can't install to initramfs")


def _fsck_types(stage, conf):
    if conf.get("FSTYPE", "auto") != "auto":
        return sorted({ftype for ftype in conf["FSTYPE"].split(",") if ftype})
    types = set()
    for mountpoint in ("/", "/usr"):
        ftype = _fstab_type(stage, mountpoint)
        if ftype:
            types.add(ftype)
    return sorted(types)


def _fstab_rows(stage):
    files = [os.path.join(str(stage.root), "etc/fstab")]
    files += sorted(glob.glob(os.path.join(str(stage.root), "etc/fstab.d/*.fstab")))
    for path in files:
        if not os.path.isfile(path):
            continue
        for line in _read_lines(path):
            fields = line.split()
            if len(fields) < 2 or fields[0].startswith("#"):
                continue
            yield (fields + [""] * 6)[:6]


def _fstab_type(stage, mountpoint):
    """get_fsck_type_fstab: type of the first fstab row for the mountpoint.

    For / and for type auto the stock hook probes the device on the build host, which a foreign
    rootfs cannot do. No type is returned then, as the stock hook does without the device.
    """
    for fsname, mnt_dir, mnt_type, _opts, _freq, _pass in _fstab_rows(stage):
        if mnt_dir != mountpoint:
            continue
        if mnt_dir == "/" or mnt_type == "auto":
            stage.warn(f"W: fsck: cannot identify the type of file system '{fsname}' for fsck hook")
            return ""
        return mnt_type
    return ""


def hook_keymap(stage, modules, conf=None):
    conf = conf or read_conf(stage)
    if conf.get("KEYMAP", "n") not in ("y", "Y"):
        return
    raise NotImplementedError("KEYMAP=y runs setupcon from the target; not ported")


def hook_klibc_utils(stage, modules, conf=None):
    """klibc utilities as /bin (busybox absent); libraries as /lib."""
    klibc_dir = _root_path(stage, "/usr/lib/klibc/bin")
    if os.path.isdir(klibc_dir):
        for name in sorted(os.listdir(klibc_dir)):
            if name in KLIBC_SKIP:
                continue
            if os.path.exists(_dest(stage, "/sbin/" + name)) or os.path.exists(_dest(stage, "/bin/" + name)):
                continue
            src = os.path.join(klibc_dir, name)
            if os.path.isfile(src):
                _mkdir(stage, "/bin")
                shutil.copy2(src, _dest(stage, "/bin/" + name))
    for lib in sorted(glob.glob(os.path.join(str(stage.root), "usr/lib/klibc-*.so"))):
        if os.path.isfile(lib):
            _mkdir(stage, "/lib")
            shutil.copy2(lib, _dest(stage, "/lib/" + os.path.basename(lib)))


def hook_kmod(stage, modules, conf=None):
    """Also run by mkinitramfs after the full module set exists; a rerun is idempotent."""
    _exec(stage, "/usr/bin/kmod")
    _mkdir(stage, "/usr/sbin")
    for name in ("modprobe", "rmmod"):
        _cp_a(_root_keep_last(stage, "/usr/sbin/" + name), _dest(stage, "/usr/sbin/" + name))

    _mkdir(stage, "/usr/lib/modprobe.d")
    for path in sorted(glob.glob(os.path.join(str(stage.root), "usr/lib/modprobe.d/*"))):
        _cp_a(path, _dest(stage, "/usr/lib/modprobe.d/" + os.path.basename(path)))

    # kmod dlopen()s its decompressor when the kernel cannot decompress modules itself
    if _kconfig_yes(stage, "CONFIG_MODULE_DECOMPRESS"):
        return
    modroot = _dest(stage, "/usr/lib/modules")
    for suffix, lib in ((".xz", "liblzma.so.5"), (".zst", "libzstd.so.1")):
        if not _has_suffix(modroot, suffix):
            continue
        libs = sorted(glob.glob(os.path.join(str(stage.root), "usr/lib/*-linux-gnu", lib)))
        if not libs:
            raise HookError(f"kmod: {lib} missing in the target")
        for path in libs:
            _exec(stage, "/" + os.path.relpath(path, str(stage.root)))


def _kconfig_yes(stage, option):
    """kconfig_yes: /boot/config-<kver> of the target sets option to y."""
    return f"{option}=y" in _read_lines(os.path.join(str(stage.root), "boot", "config-" + stage.kver))


def _has_suffix(root, suffix):
    for _top, _dirs, files in os.walk(root):
        if any(name.endswith(suffix) for name in files):
            return True
    return False


def hook_plymouth(stage, modules, conf=None):
    conf = conf or read_conf(stage)
    theme = _plymouth_theme(stage)
    theme_file = f"{THEMES}/{theme}/{theme}.plymouth"
    image_dir = _plymouth_image_dir(stage, theme_file)
    module_name = _plymouth_module_name(stage, theme_file)
    plugin_path = f"/usr/lib/{stage.triplet}/plymouth"
    if theme in PLYMOUTH_TEXT_THEMES:
        plugins = ("text.so", "details.so")
    else:
        plugins = ("text.so", "details.so", "label-pango.so")

    module = f"{plugin_path}/{module_name}.so"
    if not _exists(stage, module):
        stage.warn(f"W: plymouth module ({module}) missing, skipping plymouth.")
        return

    _exec(stage, module)
    _mkdir(stage, THEMES)
    _cp_r_dir(stage, f"{THEMES}/{theme}")
    if image_dir and image_dir != f"{THEMES}/{theme}":
        _cp_r_dir(stage, image_dir, THEMES)

    for binary in ("/usr/bin/plymouth", "/usr/sbin/plymouthd", "/usr/libexec/plymouth/plymouthd-fd-escrow"):
        _exec(stage, binary)

    for plugin in plugins:
        if _isfile(stage, f"{plugin_path}/{plugin}"):
            _exec(stage, f"{plugin_path}/{plugin}")
        else:
            stage.warn(f"W: plymouth: The plugin {plugin} is missing, "
                       "the selected theme might not work as expected.")
            stage.warn("W: plymouth: You might want to install the plymouth-themes package to fix this.")

    _cp_r_dir(stage, f"{THEMES}/details")
    _cp_r_dir(stage, f"{THEMES}/text")

    if _exists(stage, "/etc/os-release"):
        _cp_follow_target(stage, "/etc/os-release", "/etc/os-release")

    if theme not in ("text", "details"):
        _cp_follow_target(stage, "/usr/share/plymouth/debian-logo.png", "/usr/share/plymouth/debian-logo.png")
        _plymouth_fonts(stage, theme)

    if _exists(stage, "/etc/default/keyboard"):
        _cp_follow_target(stage, "/etc/default/keyboard", "/etc/default/keyboard")

    if module_name == "two-step":
        logo = "/usr/share/desktop-base/debian-logos/logo-text-version-64.png"
        if _exists(stage, logo) and image_dir:
            _cp_follow_target(stage, logo, image_dir + "/watermark.png")

    mods = conf.get("MODULES", "most")
    if mods == "dep":
        raise NotImplementedError("MODULES=dep (sysfs walk for drm) is not ported")
    if mods == "list":
        stage.warn("W: plymouth: not including drm modules since MODULES=list")
    elif os.path.isdir(os.path.join(str(stage.root), "usr/lib/modules", stage.kver, DRM_DIR)):
        modules.add_dir(DRM_DIR, DRM_EXCLUDES)

    _exec(stage, f"/usr/lib/{stage.triplet}/plymouth/renderers/frame-buffer.so")
    _exec(stage, f"/usr/lib/{stage.triplet}/plymouth/renderers/drm.so")

    _mkdir(stage, "/etc/plymouth")
    if _isfile(stage, "/etc/plymouth/plymouthd.conf"):
        _cp_a(_root_keep_last(stage, "/etc/plymouth/plymouthd.conf"),
              _dest(stage, "/etc/plymouth/plymouthd.conf"))
    _cp_a(_root_keep_last(stage, "/usr/share/plymouth/plymouthd.defaults"),
          _dest(stage, "/usr/share/plymouth/plymouthd.defaults"))

    # dummy root account lookup (Debian #691598)
    _append_line_if_missing(_dest(stage, "/etc/passwd"), r"^root:", "root:x:0:0:root:/root:/bin/sh")
    _append_line_if_missing(_dest(stage, "/etc/nsswitch.conf"), r"^passwd: files", "passwd: files")

    for lib in sorted(glob.glob(os.path.join(str(stage.root), "usr/lib", stage.triplet, "libnss_files*"))):
        if os.path.exists(lib):
            _exec(stage, "/" + os.path.relpath(lib, str(stage.root)))


def _cp_r_dir(stage, src, dest_dir=None):
    """cp -r SRC DEST_DIR/ for a ROOT directory: symlinks are copied as symlinks.

    dest_dir is a target path (default: the same path); the copy lands in dest_dir/basename(src).
    """
    dest_dir = dest_dir or os.path.dirname(src.rstrip("/"))
    name = os.path.basename(src.rstrip("/"))
    shutil.copytree(_root_path(stage, src), os.path.join(_dest(stage, dest_dir), name),
                    symlinks=True, dirs_exist_ok=True)


def _ini_value(path, key):
    for line in _read_lines(path):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "[")):
            continue
        name, sep, value = stripped.partition("=")
        if sep and name.strip() == key:
            return value.strip()
    return ""


def _plymouth_theme(stage):
    """plymouth-set-default-theme: Theme= of plymouthd.conf, then plymouthd.defaults, then default.plymouth."""
    def usable(name):
        if not name or RE_THEME_NAME.fullmatch(name) is None:
            return False
        return _isfile(stage, f"{THEMES}/{name}/{name}.plymouth")

    name = _ini_value(os.path.join(str(stage.root), "etc/plymouth/plymouthd.conf"), "Theme")
    if not usable(name):
        name = _ini_value(os.path.join(str(stage.root), "usr/share/plymouth/plymouthd.defaults"), "Theme")
    link = os.path.join(str(stage.root), THEMES.lstrip("/"), "default.plymouth")
    if not usable(name) and os.path.islink(link):
        name = os.path.basename(os.readlink(link)).removesuffix(".plymouth")
    if not usable(name):
        name = "text"
    return name


def _theme_lines(stage, theme_file):
    return _read_lines(_root_path(stage, theme_file)) if _isfile(stage, theme_file) else []


def _plymouth_image_dir(stage, theme_file):
    """ImageDir= of the theme file (grep ImageDir *= *, then sed removes the match)."""
    for line in _theme_lines(stage, theme_file):
        match = re.search(r"ImageDir *= *", line)
        if match:
            return line[:match.start()] + line[match.end():]
    return ""


def _plymouth_module_name(stage, theme_file):
    for line in _theme_lines(stage, theme_file):
        if line.startswith("ModuleName="):
            return line[len("ModuleName="):]
    return ""


def _plymouth_fonts(stage, theme):
    """Fontconfig files, the fixed DejaVu pair in place of fc-match, and the font cache."""
    _mkdir(stage, "/etc/fonts/conf.d")
    _cp_follow_target(stage, "/etc/fonts/fonts.conf", "/etc/fonts/fonts.conf")
    _cp_follow_target(stage, "/etc/fonts/conf.d/60-latin.conf", "/etc/fonts/conf.d/60-latin.conf")
    _mkdir(stage, "/var/cache/fontconfig")
    _mkdir(stage, "/usr/local/share/fonts")
    _mkdir(stage, "/usr/share/fonts")

    for font in (DEJAVU_SANS, DEJAVU_MONO):
        if not _isfile(stage, font):
            raise HookError(f"plymouth: font {font} missing in the target")
        if not os.path.isfile(_dest(stage, font)):
            _file(stage, "font", font)
    _symlink(DEJAVU_SANS, _dest(stage, "/usr/share/fonts/Plymouth.ttf"))
    _symlink(DEJAVU_MONO, _dest(stage, "/usr/share/fonts/Plymouth-monospace.ttf"))

    if theme in ("spinner", "bgrt"):
        for face in ("Cantarell-Regular.otf", "Cantarell-Light.otf", "Cantarell-VF.otf"):
            src = "/usr/share/fonts/opentype/cantarell/" + face
            if _exists(stage, src):
                _mkdir(stage, "/usr/share/fonts/opentype/cantarell")
                _cp_follow_target(stage, src, src)

    try:
        subprocess.run(["fc-cache", "-s", "-y", str(stage.dest)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError as exc:
        raise HookError("plymouth: host fc-cache not found") from exc
    except subprocess.CalledProcessError as exc:
        raise HookError(f"plymouth: fc-cache failed with {exc.returncode}") from exc


def _symlink(target, link):
    if os.path.lexists(link):
        raise HookError(f"plymouth: {link} already exists")
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(target, link)


def _append_line_if_missing(path, pattern, line):
    """grep -qs PATTERN FILE || echo LINE >> FILE; the file is created when missing."""
    if any(re.search(pattern, text) for text in _read_lines(path)):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def hook_resume(stage, modules, conf=None):
    conf = conf or read_conf(stage)
    resume = conf.get("RESUME", "")
    if resume == "none":
        return
    if resume and resume != "auto":
        # A configured device is checked with blkid on the build host: not ported.
        raise NotImplementedError("RESUME=<device> needs a block device on the build host")
    # Swap autodetection is skipped in a chroot (ischroot), so RESUME=auto selects nothing.
    if resume == "auto":
        stage.warn("W: initramfs-tools failed to select a resume device")
        _mkdir(stage, "/conf/conf.d")
        with open(_dest(stage, "/conf/conf.d/zz-resume-auto"), "w", encoding="utf-8") as handle:
            handle.write("RESUME=\n")


def hook_raspi_firmware_fsck(stage, modules, conf=None):
    _exec(stage, "/sbin/fsck.ext4")
    _exec(stage, "/sbin/fsck.vfat")


def hook_thermal(stage, modules, conf=None):
    # Only the amd64 branch applies; the powerpc branch is for G5 Macs.
    if stage.arch == "amd64":
        modules.add(["fan", "thermal"])


HOOKS = {
    "udev": hook_udev,
    "dmsetup": hook_dmsetup,
    "fsck": hook_fsck,
    "keymap": hook_keymap,
    "klibc-utils": hook_klibc_utils,
    "kmod": hook_kmod,
    "plymouth": hook_plymouth,
    "raspi-firmware-fsck": hook_raspi_firmware_fsck,
    "resume": hook_resume,
    "thermal": hook_thermal,
}


def run_stock_hooks(stage, modules):
    """Run the stock hooks in mkinitramfs order. The CONFDIR hooks are not part of this port."""
    conf = read_conf(stage)
    for name in hook_order():
        HOOKS[name](stage, modules, conf)
