"""Kernel module and firmware selection for the native recovery initrd.

Inspired by initramfs-tools (hook-functions, mkinitramfs, hooks/kmod, hooks/plymouth), whose
module lists and filters are ported verbatim, and by dracut-install (module mode), which does
the selection: hard and soft dependencies, firmware search, symbol and path filters.
Reads the target tree only (ROOT); writes DEST. Module files are copied unmodified
(a .ko.xz stays .ko.xz). Symlinks are recreated as dracut-install does: the link target is
copied first and the link points at its copy.
"""

import fnmatch
import gzip
import lzma
import os
import posixpath
import re
import shutil
import struct
from pathlib import Path

# Firmware search order of mkinitramfs (no firmware_class path parameter).
def _fw_dirs(kver):
    return [
        f"/lib/firmware/updates/{kver}",
        "/lib/firmware/updates",
        f"/lib/firmware/{kver}",
        "/lib/firmware",
    ]


# Symbols of the block-device drivers (hook-functions auto_add_modules, blockfuncs).
BLOCKFUNCS = (
    "ahci_platform_get_resources|ata_scsi_ioctl|scsi_add_host|blk_cleanup_queue"
    "|register_mtd_blktrans|scsi_esp_register|register_virtio_device"
    "|usb_stor_disconnect|mmc_add_host|sdhci_add_host|scsi_add_host_with_dma"
    "|blk_mq_alloc_disk|blk_mq_alloc_request|blk_mq_destroy_queue|blk_cleanup_disk"
    "|dw_mc_probe|dw_mci_pltfm_register|nvme_init_ctrl"
)

# Default arguments of MODULES=most.
MOST_DEFAULT = ("base", "net", "ide", "scsi", "block", "ata", "dasd", "firewire", "mmc", "usb_storage", "fb")

USB_HOST_EXCLUDES = ["hwa-hc.ko", "sl811_cs.ko", "sl811-hcd.ko", "u132-hcd.ko", "whci-hcd.ko"]

HID_EXCLUDES = [
    "hid-*ff.ko", "hid-a4tech.ko", "hid-cypress.ko",
    "hid-dr.ko", "hid-elecom.ko", "hid-gyration.ko",
    "hid-icade.ko", "hid-kensington.ko", "hid-kye.ko",
    "hid-lcpower.ko", "hid-magicmouse.ko", "hid-ntrig.ko",
    "hid-petalynx.ko", "hid-picolcd.ko", "hid-pl.ko",
    "hid-ps3remote.ko", "hid-quanta.ko",
    "hid-roccat-ko*.ko", "hid-roccat-pyra.ko",
    "hid-saitek.ko", "hid-sensor-hub.ko", "hid-sony.ko",
    "hid-speedlink.ko", "hid-tivo.ko", "hid-twinhan.ko",
    "hid-uclogic.ko", "hid-wacom.ko", "hid-waltop.ko",
    "hid-wiimote.ko", "hid-zydacron.ko",
]

# Dependencies that depmod cannot see (hook-functions hidden_dep_add_modules).
HIDDEN_DEPS = {
    "libcrc32c": ["crc32c"],
    "ubifs": ["deflate", "zlib", "lzo"],
    "btrfs": ["crc32c"],
    "f2fs": ["crc32"],
    "mlx4_core": ["mlx4_ib"],
    "mlx5_core": ["mlx5_ib"],
    "i8042": ["psmouse"],
    "nvme": ["vmd"],
    "spi-rockchip": ["pl330"],
    "dw_mmc-rockchip": ["rockchip-io-domain", "io-domain"],
    "mediatek-drm": ["mediatek-drm-hdmi", "mtk_iommu", "mtk-smi"],
    "mtk_iommu": ["mtk-smi"],
    "phy-mtk-mipi-dsi-drv": ["nvmem_mtk-efuse"],
    "mt6397": ["mtk-pmic-wrap"],
    "qmi_helpers": ["qrtr"],
    "panel-edp": ["pwm_bl"],
    "msm": ["pmic_glink_altmode", "gpio_sbu_mux", "qrtr"],
}

_SUFFIXES = (".ko.xz", ".ko.zst", ".ko.gz", ".ko")


def _kmod_name(filename):
    """Module name as libkmod derives it: file name without .ko suffix, '-' as '_'."""
    base = filename
    for suffix in _SUFFIXES:
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    return base.replace("-", "_")


def _strip_suffix(name):
    """Name without a module file suffix, '-' kept (alias patterns use the raw spelling)."""
    for suffix in _SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def _canon(path):
    """Usr-merge canonical target path: /lib/x -> /usr/lib/x (also bin, sbin, lib64)."""
    path = posixpath.normpath(path)
    for top in ("bin", "sbin", "lib", "lib64"):
        if path == "/" + top or path.startswith("/" + top + "/"):
            return "/usr" + path
    return path


class _Filter:
    """-P (path exclusion) and -s (undefined symbol inclusion) of dracut-install."""

    def __init__(self, path_nopath=None, symbol=None):
        self.nopath = re.compile(path_nopath) if path_nopath else None
        self.symbol = re.compile(symbol) if symbol else None

    def allow_path(self, path):
        return self.nopath is None or self.nopath.search(path) is None

    def allow_symbols(self, symbols):
        if self.symbol is None:
            return True
        return any(self.symbol.search(s) for s in symbols)


def _elf_info(data):
    """Return (modinfo dict key -> [values], set of undefined global symbols) of an ELF64 LE module."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not an ELF64 little-endian object")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    sections = []
    for i in range(shnum):
        name, typ, _flags, _addr, offset, size, link, _info, _align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", data, shoff + i * shentsize)
        sections.append((name, typ, offset, size, link, entsize))

    def cstr(offset):
        end = data.index(b"\0", offset)
        return data[offset:end].decode("utf-8", "replace")

    shstr_off = sections[shstrndx][2]
    modinfo_raw = None
    symtab = None
    for name, typ, offset, size, link, entsize in sections:
        section_name = cstr(shstr_off + name)
        if section_name == ".modinfo":
            modinfo_raw = data[offset:offset + size]
        elif typ == 2:  # SHT_SYMTAB
            symtab = (offset, size, link, entsize)

    info = {}
    if modinfo_raw is not None:
        for item in modinfo_raw.split(b"\0"):
            if b"=" in item:
                key, _, value = item.decode("utf-8", "replace").partition("=")
                info.setdefault(key, []).append(value)

    undef = set()
    if symtab is not None:
        sym_off, sym_size, link, entsize = symtab
        str_off = sections[link][2]
        for pos in range(sym_off, sym_off + sym_size, entsize or 24):
            st_name, _info, _other, st_shndx = struct.unpack_from("<IBBH", data, pos)
            if st_shndx == 0 and st_name != 0:
                undef.add(cstr(str_off + st_name))
    return info, frozenset(undef)


class Modules:
    """Collects kernel modules and firmware of the target kernel into DEST.

    Call order follows mkinitramfs: most() (immediate dracut calls, pending names),
    add()/add_dir() (pending names), builtin_firmware(), apply() (dracut -m of the
    pending names), hidden_deps(), apply().
    """

    def __init__(self, stage):
        self.root = Path(stage.root)
        self.dest = Path(stage.dest)
        self.kver = stage.kver
        self.warn = stage.warn
        self.kdir = "/lib/modules/" + self.kver
        self._kroot = self.root / self.kdir[1:]
        self._pending = []
        self._done = set()  # rel paths of modules already in DEST
        self._index = None  # (by_name, deps, aliases), loaded on first use
        self._elf = {}  # rel -> (modinfo, undefined symbols)

    # ---- target tree helpers -------------------------------------------------

    def _resolve(self, path, follow_last=True):
        """Resolve a target path inside ROOT the way a chroot would.

        Symlinks are expanded in the target tree, absolute targets are re-rooted.
        Returns the resolved target path, or None on a symlink loop.
        """
        pending = [c for c in path.split("/") if c]
        out = []
        hops = 0
        while pending:
            comp = pending.pop(0)
            if comp == ".":
                continue
            if comp == "..":
                if out:
                    out.pop()
                continue
            cand = "/" + "/".join(out + [comp])
            if (pending or follow_last) and os.path.islink(self.root / cand[1:]):
                hops += 1
                if hops > 40:
                    return None
                target = os.readlink(self.root / cand[1:])
                if target.startswith("/"):
                    out = []
                pending = [c for c in target.split("/") if c] + pending
                continue
            out.append(comp)
        return "/" + "/".join(out)

    def _exists(self, path):
        """access(F_OK) on a target path (follows symlinks, chroot view)."""
        resolved = self._resolve(path)
        return resolved is not None and os.path.exists(self.root / resolved[1:])

    def _dest_exists(self, path):
        return os.path.exists(self.dest / _canon(path)[1:])

    def _glob(self, pattern):
        """glob of a target path pattern, chroot view, sorted."""
        parts = [p for p in pattern.split("/") if p]
        current = [""]
        for part in parts:
            nxt = []
            for base in current:
                if not any(c in part for c in "*?["):
                    nxt.append(base + "/" + part)
                    continue
                resolved = self._resolve(base or "/")
                if resolved is None:
                    continue
                try:
                    names = os.listdir(self.root / resolved[1:])
                except OSError:
                    continue
                for name in names:
                    if fnmatch.fnmatchcase(name, part) and (not name.startswith(".") or part.startswith(".")):
                        nxt.append(base + "/" + name)
            current = nxt
        return sorted(p for p in current if self._exists(p))

    def _install(self, src, depth=0):
        """Copy one target path to DEST at its canonical path (dracut-install cp / ln_r).

        Returns 0 when copied or already present, 1 when the source is missing.
        """
        if depth > 40:
            return 1
        real_path = self._resolve(src, follow_last=False)
        if real_path is None:
            return 1
        out = self.dest / _canon(real_path)[1:]
        if os.path.lexists(out):
            return 0
        real = self.root / real_path[1:]
        if os.path.islink(real):
            target = os.readlink(real)
            if not target.startswith("/"):
                target = posixpath.join(posixpath.dirname(real_path), target)
            target = posixpath.normpath(target)
            if self._install(target, depth + 1) != 0:
                return 1
            target_dest = self.dest / _canon(self._resolve(target, follow_last=False))[1:]
            out.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(os.path.relpath(target_dest, out.parent), out)
            return 0
        if not os.path.exists(real):
            return 1
        out.parent.mkdir(parents=True, exist_ok=True)
        if real.is_dir():
            out.mkdir(exist_ok=True)
            return 0
        shutil.copyfile(real, out)
        shutil.copymode(real, out)
        return 0

    # ---- module index (modules.dep, modules.alias) ---------------------------

    def _load_index(self):
        if self._index is not None:
            return self._index
        by_name, deps, aliases = {}, {}, []
        with open(self._kroot / "modules.dep", encoding="utf-8") as fh:
            for line in fh:
                rel, sep, rest = line.partition(":")
                if not sep:
                    continue
                rel = rel.strip()
                deps[rel] = rest.split()
                by_name.setdefault(_kmod_name(posixpath.basename(rel)), rel)
        alias_file = self._kroot / "modules.alias"
        if alias_file.exists():
            with open(alias_file, encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) == 3 and parts[0] == "alias":
                        aliases.append((parts[1], _kmod_name(parts[2])))
        self._index = (by_name, deps, aliases)
        return self._index

    def _lookup(self, name):
        """Module rel paths for a name or alias, as kmod_module_new_from_lookup."""
        by_name, _deps, aliases = self._load_index()
        key = _kmod_name(name)
        if key in by_name:
            return [by_name[key]]
        raw = _strip_suffix(name)
        found = []
        for pattern, module in aliases:
            if fnmatch.fnmatchcase(raw, pattern) and module in by_name:
                found.append(by_name[module])
        return found

    def _deps(self, rel):
        return self._load_index()[1].get(rel, [])

    def _parse(self, rel):
        """(modinfo, undefined symbols) of a module, decompressed once."""
        if rel in self._elf:
            return self._elf[rel]
        path = self._kroot / rel
        try:
            raw = path.read_bytes()
            if rel.endswith(".xz"):
                raw = lzma.decompress(raw)
            elif rel.endswith(".gz"):
                raw = gzip.decompress(raw)
            elif rel.endswith(".zst"):
                try:
                    from compression import zstd  # Python 3.14
                except ImportError:
                    raise ValueError("a .zst module needs Python 3.14 (compression.zstd)") from None
                raw = zstd.decompress(raw)
            result = _elf_info(raw)
        except (OSError, ValueError, lzma.LZMAError, EOFError, gzip.BadGzipFile) as exc:
            self.warn(f"W: cannot read module {rel}: {exc}")
            result = ({}, frozenset())
        self._elf[rel] = result
        return result

    def _softdeps(self, rel):
        """(pre, post) module rel paths from the softdep modinfo values."""
        pre, post = [], []
        # Only the first softdep value is honoured (libkmod as used by dracut-install, checked
        # with the host oracle on btrfs, ksmbd and cifs). Tokens without pre:/post: are ignored.
        for value in self._parse(rel)[0].get("softdep", [])[:1]:
            mode = None
            for token in value.split():
                if token == "pre:":
                    mode = pre
                elif token == "post:":
                    mode = post
                elif mode is not None:
                    mode.extend(self._lookup(token))
        return pre, post

    # ---- dracut-install semantics --------------------------------------------

    def _install_firmware(self, rel):
        """install_firmware of dracut-install: every firmware value, every firmware directory."""
        for value in self._parse(rel)[0].get("firmware", []):
            for directory in _fw_dirs(self.kver):
                fwpath = directory + "/" + value
                if any(c in value for c in "*?[") and not self._exists(fwpath):
                    for match in self._glob(fwpath):
                        self._install_firmware_file(match)
                else:
                    self._install_firmware_file(fwpath)

    def _install_firmware_file(self, path):
        if not self._exists(path):
            for suffix in (".zst", ".xz"):
                if self._exists(path + suffix):
                    path += suffix
                    break
            else:
                return 1
        return self._install(path)

    def _install_dependency(self, rel):
        """install_dependent_module: no filters, skipped when already present."""
        if rel is None or rel in self._done:
            return
        if self._install(self.kdir + "/" + rel) != 0:
            return
        self._done.add(rel)
        self._install_tree(rel)

    def _install_tree(self, rel):
        self._install_firmware(rel)
        for dep in self._deps(rel):
            self._install_dependency(dep)
        pre, post = self._softdeps(rel)
        for dep in pre + post:
            self._install_dependency(dep)

    def _install_top(self, rel, flt):
        """install_module: top-level module, subject to the -P and -s filters."""
        if rel is None:
            return
        if flt is not None:
            if not flt.allow_path(self.kdir + "/" + rel):
                return
            if flt.symbol is not None and not flt.allow_symbols(self._parse(rel)[1]):
                return
        if self._install(self.kdir + "/" + rel) == 0:
            self._done.add(rel)
        self._install_tree(rel)

    def _dir_modules(self, dirname, flt):
        """Module rel paths under kernel/, extra/ and updates/ <dirname> (=dirname form)."""
        found = []
        for top in ("kernel", "extra", "updates"):
            base = self._kroot / top / dirname
            if base.is_dir():
                self._walk_dir(base, top + "/" + dirname, flt, found)
        return found

    def _walk_dir(self, path, rel_dir, flt, found):
        if flt is not None and flt.nopath is not None and not flt.allow_path(self.kdir + "/" + rel_dir):
            return
        for entry in sorted(os.scandir(path), key=lambda e: e.name):
            rel = rel_dir + "/" + entry.name
            if entry.is_dir(follow_symlinks=False):
                self._walk_dir(Path(entry.path), rel, flt, found)
            elif ".ko" in entry.name:
                found.append(rel)

    def _dracut(self, names, flt=None):
        """dracut-install -m NAMES [filters]."""
        for name in names:
            if name.startswith("="):
                for rel in self._dir_modules(name[1:], flt):
                    for module in self._lookup(_kmod_name(posixpath.basename(rel))):
                        self._install_top(module, flt)
            elif name.startswith("/"):
                raise ValueError(f"absolute module path not supported: {name}")
            else:
                for module in self._lookup(name):
                    self._install_top(module, flt)

    def _call(self, names, path_nopath=None, symbol=None):
        if not names:
            return
        self._dracut(names, _Filter(path_nopath, symbol))

    # ---- public API -----------------------------------------------------------

    def add(self, names):
        """manual_add_modules: names are applied by apply()."""
        self._pending.extend(names)

    def add_dir(self, dirname, excludes=()):
        """copy_modules_dir: every module under kernel/<dirname> (not extra/updates)."""
        base = self._kroot / dirname
        if not base.is_dir():
            return
        patterns = [e + "*" if e.endswith(".ko") else e for e in excludes]
        if any(fnmatch.fnmatchcase(base.name, p) for p in patterns):
            return
        names = []

        def walk(path):
            for entry in sorted(os.scandir(path), key=lambda e: e.name):
                if any(fnmatch.fnmatchcase(entry.name, p) for p in patterns):
                    continue
                if entry.is_dir(follow_symlinks=False):
                    walk(entry.path)
                if fnmatch.fnmatchcase(entry.name, "*.ko*"):
                    names.append(entry.name.split(".", 1)[0])

        walk(base)
        self._pending.extend(names)

    def apply(self):
        """apply_add_modules: dracut-install -m of the sorted unique pending names."""
        names = sorted(set(self._pending))
        self._pending = []
        self._dracut(names)

    def most(self, args=MOST_DEFAULT):
        """auto_add_modules: the MODULES=most table of hook-functions."""
        modules = []
        block_modules = []
        for arg in args:
            if arg == "base":
                modules += ["btrfs", "ext2", "ext3", "ext4", "f2fs"]
                modules += ["isofs", "jfs", "reiserfs", "squashfs", "udf", "xfs"]
                modules += ["nfs", "nfsv2", "nfsv3", "nfsv4"]
                modules += ["af_packet", "atkbd", "i8042", "psmouse"]
                modules += ["virtio_pci", "virtio_mmio"]
                self.add_dir("kernel/drivers/usb/host", USB_HOST_EXCLUDES)
                modules += ["=drivers/usb/c67x00", "=drivers/usb/cdns3", "=drivers/usb/chipidea"]
                modules += ["=drivers/usb/dwc2", "=drivers/usb/dwc3", "=drivers/usb/isp1760"]
                modules += ["=drivers/usb/mtu3", "=drivers/usb/musb", "=drivers/usb/renesas_usbhs"]
                modules += ["=drivers/usb/typec"]
                modules += ["onboard_usb_hub", "onboard_usb_dev"]
                modules += ["=net/qrtr"]
                modules += ["=drivers/input/keyboard"]
                self.add_dir("kernel/drivers/hid", HID_EXCLUDES)
                modules += ["=drivers/input/serio", "=drivers/tty/serial"]
                modules += [
                    "=drivers/bus", "=drivers/clk", "=drivers/devfreq", "=drivers/dma",
                    "=drivers/extcon", "=drivers/gpio", "=drivers/hwspinlock",
                    "=drivers/interconnect", "=drivers/i2c/busses", "=drivers/i2c/muxes",
                    "=drivers/mailbox", "=drivers/memory", "=drivers/mfd", "=drivers/nvmem",
                    "=drivers/pci/controller", "=drivers/phy", "=drivers/platform/chrome",
                    "=drivers/power", "=drivers/pinctrl", "=drivers/regulator", "=drivers/reset",
                    "=drivers/rpmsg", "=drivers/soc", "=drivers/spi", "=drivers/spmi",
                    "=drivers/usb/phy", "=drivers/watchdog",
                ]
                modules += ["=drivers/rtc"]
            elif arg == "net":
                exclude = "cdc_mbim|ipheth|qmi_wwan|sierra_net|tun|veth|xen-netback"
                exclude_dir = "isdn|net/(802|ethernet|llc|phy|team)|uwb|wan|wireless"
                self._call(
                    ["=drivers/net"],
                    path_nopath=f"/(({exclude})\\.ko|({exclude_dir})/)",
                    symbol="eth_type_trans|register_virtio_device|usbnet_open",
                )
                modules += ["=drivers/net/ethernet", "=drivers/net/mdio"]
                modules += ["=drivers/net/phy", "cdc_eem", "ch9200", "ipvlan"]
                modules += ["netconsole", "r8153_ecm"]
            elif arg == "ide":
                modules += ["=drivers/ide"]
            elif arg == "mmc":
                modules += ["=drivers/mmc"]
            elif arg == "scsi":
                self._call(
                    ["=drivers/message/fusion", "=drivers/s390/scsi", "=drivers/scsi"],
                    symbol=BLOCKFUNCS + "|iscsi_register_transport",
                )
                modules += ["cxgb3i", "cxgb4i", "scsi_dh_alua", "scsi_dh_emc"]
                modules += ["scsi_dh_rdac", "scsi_transport_srp"]
            elif arg == "ata":
                block_modules += ["=drivers/ata"]
            elif arg == "block":
                block_modules += ["=drivers/block", "=drivers/nvme"]
                modules += ["=drivers/ufs", "vmd"]
            elif arg == "ubi":
                modules += ["deflate", "zlib", "lzo", "ubi", "ubifs"]
            elif arg == "firewire":
                modules += ["firewire-ohci", "firewire-sbp2"]
            elif arg == "dasd":
                modules += ["dasd_diag_mod", "dasd_eckd_mod", "dasd_fba_mod"]
            elif arg == "usb_storage":
                modules += ["=drivers/usb/storage"]
            elif arg == "fb":
                modules += [
                    "rockchipdrm", "pwm-cros-ec", "pwm_bl", "pwm-rockchip", "panel-simple",
                    "analogix-anx6345", "pwm-sun4i", "sun4i-drm", "sun8i-mixer", "panel-edp",
                    "mediatek-drm", "pwm-mtk-disp", "anx7625", "parade_ps8640", "msm",
                    "pwm_imx27", "nwl-dsi", "ti-sn65dsi86", "imx-dcss",
                    "mux-mmio", "mxsfb",
                ]
        self._pending.extend(modules)
        if block_modules:
            self._call(block_modules, symbol=BLOCKFUNCS)

    def hidden_deps(self):
        """hidden_dep_add_modules: extra dependencies for the modules present in DEST."""
        names = []
        builtin = self._kroot / "modules.builtin"
        if builtin.exists():
            for line in builtin.read_text(encoding="utf-8").splitlines():
                names.append(posixpath.basename(line).split(".", 1)[0])
        kernel_dest = self.dest / "usr" / self.kdir[1:] / "kernel"
        if kernel_dest.is_dir():
            for path in kernel_dest.rglob("*.ko*"):
                names.append(path.name.split(".", 1)[0])
        wanted = []
        for name in names:
            wanted += HIDDEN_DEPS.get(name, [])
        self._dracut(wanted)

    def builtin_firmware(self):
        """add_builtin_firmware: firmware of drivers built into the kernel."""
        modinfo = self._kroot / "modules.builtin.modinfo"
        if not modinfo.exists():
            return
        text = modinfo.read_bytes().replace(b"\0", b"\n").decode("utf-8", "replace")
        for line in text.splitlines():
            # grep '^[^=]*\.firmware=' : the key before the first '=' ends in .firmware
            head, sep, firmware = line.partition("=")
            if not sep or not head.endswith(".firmware"):
                continue
            modname = head[: -len(".firmware")]
            firmware = firmware.strip()
            if self._add_firmware(firmware) != 0:
                self.warn(f"W: Possible missing firmware /lib/firmware/{firmware} for built-in driver {modname}")

    def _add_firmware(self, firmware):
        """add_firmware of hook-functions: first match in priority order, copied once."""
        found = None
        for suffix in ("", ".zst", ".xz"):
            for directory in _fw_dirs(self.kver):
                location = directory + "/" + firmware + suffix
                if self._dest_exists(location):
                    return 0
                if found is None and self._exists(location):
                    found = location
        if found is None:
            return 1
        return self._install(found)
