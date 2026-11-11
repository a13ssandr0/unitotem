#!/usr/bin/env python3
"""Reduces an unpacked recovery initramfs to what the installer ISO needs (tools/build-installer-iso.sh).

Usage: slim-installer-initrd.py TREE
TREE is the output of `unmkinitramfs` (main part). Removes: early microcode, GPU/Wi-Fi/Bluetooth/other firmware,
modules outside the boot-media, disk, input and wired-network sets (dependency closure kept, indexes rebuilt with
depmod), partition-cloning, Wi-Fi and boot-splash programs, libraries nothing needs any more.
Prints the size of every step. Run as the owner of TREE (no root needed).
"""
import os, re, shutil, subprocess, sys

tree = os.path.abspath(sys.argv[1])
if not os.path.isdir(os.path.join(tree, 'usr/lib/modules')):
    sys.exit('not an unpacked initramfs: ' + tree)


def size(path):
    total = 0
    for d, _, files in os.walk(path):
        for f in files:
            p = os.path.join(d, f)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    return total


def rm(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.remove(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


def step(name, before):
    now = size(tree)
    print(f'{name}: {before / 1e6:.1f} MB -> {now / 1e6:.1f} MB')
    return now


cur = size(tree)
print(f'unpacked: {cur / 1e6:.1f} MB')

# 1. early microcode
rm(os.path.join(tree, 'kernel'))
cur = step('microcode removed', cur)

# 2. firmware: small wired-network blobs only
KEEP_FW = {'rtl_nic', 'tigon', 'e100', '3com', 'tehuti', 'kaweth', 'regulatory.db', 'regulatory.db.p7s',
           'regulatory.db-debian', 'regulatory.db.p7s-debian'}
fw = os.path.join(tree, 'usr/lib/firmware')
for e in os.listdir(fw):
    if e not in KEEP_FW:
        rm(os.path.join(fw, e))
cur = step('firmware reduced', cur)

# 3. modules: directory seeds + named seeds, dependency closure from the original modules.dep
kver = os.listdir(os.path.join(tree, 'usr/lib/modules'))[0]
mdir = os.path.join(tree, 'usr/lib/modules', kver)
dep = {}
for line in open(os.path.join(mdir, 'modules.dep')):
    m, _, rest = line.partition(':')
    dep[m.strip()] = rest.split()
DIR_SEEDS = ['drivers/ata/', 'drivers/nvme/host/', 'drivers/usb/storage/', 'drivers/usb/host/', 'drivers/usb/common/',
             'drivers/usb/core/', 'drivers/block/', 'drivers/virtio/', 'drivers/mmc/', 'drivers/cdrom/', 'drivers/hv/',
             'drivers/net/ethernet/', 'drivers/net/usb/', 'drivers/net/phy/', 'drivers/net/mdio/', 'drivers/net/hyperv/',
             'drivers/net/vmxnet3/', 'drivers/scsi/', 'drivers/i2c/', 'drivers/input/serio/', 'drivers/input/keyboard/',
             'drivers/firmware/efi/', 'fs/isofs/', 'fs/ext4/', 'fs/jbd2/', 'fs/fat/', 'fs/nls/', 'fs/efivarfs/', 'fs/mbcache',
             'lib/']
NAME_SEEDS = {'virtio_net', 'mii', 'usbhid', 'hid', 'hid-generic', 'i2c-hid', 'i2c-hid-acpi', 'hid-multitouch',
              'vfat', 'fat', 'loop', 'cdrom', 'sr_mod', 'sd_mod', 'sg', 'crc32c_generic', 'libcrc32c', 'crc16'}
GPU_SCSI_SKIP = ('drivers/scsi/qla', 'drivers/scsi/lpfc', 'drivers/scsi/bfa', 'drivers/scsi/csiostor', 'drivers/scsi/qedi',
                 'drivers/scsi/qedf', 'drivers/scsi/bnx2fc', 'drivers/scsi/bnx2i', 'drivers/scsi/be2iscsi')


def short(p):
    return p.split('kernel/', 1)[1] if 'kernel/' in p else p


def modname(p):
    return re.sub(r'\.ko(\.[a-z]+)?$', '', os.path.basename(p)).replace('_', '-')


keep = set()
for m in dep:
    s = short(m)
    if any(s.startswith(d) for d in DIR_SEEDS) and not s.startswith(GPU_SCSI_SKIP):
        keep.add(m)
    if modname(m) in {n.replace('_', '-') for n in NAME_SEEDS}:
        keep.add(m)
todo = list(keep)
while todo:
    for d in dep.get(todo.pop(), []):
        if d not in keep:
            keep.add(d); todo.append(d)
for m in dep:
    if m not in keep:
        p = os.path.join(mdir, m)
        if os.path.exists(p):
            os.remove(p)
# empty directories
for d, dirs, files in os.walk(os.path.join(mdir, 'kernel'), topdown=False):
    if not dirs and not files:
        os.rmdir(d)
r = subprocess.run(['depmod', '-b', tree, kver], capture_output=True, text=True)
if r.returncode:
    sys.exit('depmod failed: ' + r.stderr)
print(f'modules kept: {len(keep)} of {len(dep)}')
cur = step('modules reduced', cur)

# 4. programs not used by the installer
REMOVE_BIN = ['partclone.dd', 'partclone.extfs', 'partclone.fat', 'partclone.info', 'partclone.restore', 'parted',
              'wpa_supplicant', 'wpa_passphrase', 'plymouth', 'plymouthd', 'grub-install', 'mke2fs', 'mkfs.ext4',
              'mkfs.fat', 'fsck.fat', 'fatlabel', 'e2fsck', 'e2label', 'tune2fs', 'dumpe2fs', 'resize2fs', 'dmsetup',
              'efibootmgr', 'nc', 'nc.traditional', 'nfsmount', 'mkfifo', 'chroot', 'cpio', 'base64']
for d in ('usr/bin', 'usr/sbin'):
    for n in REMOVE_BIN:
        rm(os.path.join(tree, d, n))
for d in ('usr/share/plymouth', 'usr/share/fonts', 'etc/plymouth', 'etc/fonts', 'usr/lib/plymouth'):
    rm(os.path.join(tree, d))
# the boot-splash script of the recovery initramfs
pm = os.path.join(tree, 'scripts/init-premount')
rm(os.path.join(pm, 'plymouth'))
open(os.path.join(pm, 'ORDER'), 'w').write('/scripts/init-premount/zz-unitotem-ota "$@"\n[ -e /conf/param.conf ] && . /conf/param.conf\n')
cur = step('programs removed', cur)

# 5. libraries nothing needs: closure of DT_NEEDED over every ELF left, plus the ones loaded by name at run time
libdir = os.path.join(tree, 'usr/lib/x86_64-linux-gnu')
by_name = {}
for f in os.listdir(libdir):
    p = os.path.join(libdir, f)
    if '.so' in f:
        by_name[f] = p


def needed(path):
    out = subprocess.run(['readelf', '-d', path], capture_output=True, text=True).stdout
    return re.findall(r'\(NEEDED\)\s+Shared library: \[([^\]]+)\]', out)


def is_elf(path):
    try:
        with open(path, 'rb') as f:
            return f.read(4) == b'\x7fELF'
    except OSError:
        return False


roots = []
for d, _, files in os.walk(tree):
    if d.startswith(os.path.join(tree, 'usr/lib/modules')) or d == libdir:
        continue
    for f in files:
        p = os.path.join(d, f)
        if not os.path.islink(p) and is_elf(p):
            roots.append(p)
need, queue = set(), []
for p in roots:
    queue += needed(p)
# loaded by name at run time (udevd dlopens libkmod, libblkid and friends; glibc loads the nss and gcc libraries)
for pat in ('libnss_files.so.2', 'libgcc_s.so.1', 'ld-linux-x86-64.so.2', 'libresolv.so.2', 'libc.so.6', 'libkmod.so.2',
            'libblkid.so.1', 'libmount.so.1', 'libacl.so.1', 'libaudit.so.1', 'libcap.so.2', 'libcrypto.so.3',
            'libpam.so.0', 'libpcre2-8.so.0', 'libbpf.so.1', 'libelf.so.1', 'libseccomp.so.2', 'libselinux.so.1',
            'libcryptsetup.so.12', 'libgcrypt.so.20', 'libdevmapper.so.1.02.1'):
    queue.append(pat)
while queue:
    n = queue.pop()
    if n in need:
        continue
    need.add(n)
    p = by_name.get(n)
    if p:
        real = os.path.realpath(p)
        if os.path.exists(real) and is_elf(real):
            queue += needed(real)
            need.add(os.path.basename(real))
for f, p in list(by_name.items()):
    if f in need:
        continue
    if os.path.islink(p) and os.path.basename(os.path.realpath(p)) in need:
        continue
    if os.path.isfile(p) and f in need:
        continue
    if not os.path.isdir(p):
        rm(p)
cur = step('libraries reduced', cur)
print(f'final: {size(tree) / 1e6:.1f} MB')
