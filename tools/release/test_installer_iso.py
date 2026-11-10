#!/usr/bin/env python3
"""Installer ISO test in user-mode QEMU (no root, no real disk, no libvirt).

Usage: test_installer_iso.py ISO FLASH_IMG.xz [--scenarios bios,uefi,multi,sb,screen] [--work DIR] [--keep]
Scenarios (default: bios,uefi,multi,sb):
  bios    legacy BIOS, one blank disk: wrong word leaves the disk untouched, right word installs, disk-only boot
  uefi    the same with OVMF
  multi   UEFI, two disks (virtio + NVMe): the picker, only the chosen disk is written
  sb      OVMF with Secure Boot enforcing (Microsoft keys): ISO boots through shim, installer activates the shim chain
  screen  BIOS, default menu entry (tty1): screenshot of the installer to DIR/screen-*.ppm
Checks: written bytes equal the decompressed flash image (compared chunk by chunk), the 16 MiB after the image
and the last MiB are zero, the disk boots alone and the web interface answers, first boot created ROOT_B and DATA.
The serial console is driven with pexpect; every session is logged to DIR/serial-<scenario>-<phase>.log.
Needs qemu-system-x86_64, OVMF (/usr/share/OVMF), sgdisk, mtools, python3-pexpect. KVM is used when writable.
"""
import argparse, hashlib, os, shutil, ssl, subprocess, sys, time, urllib.request
import pexpect

OVMF = '/usr/share/OVMF'
RESULTS = []


def ok(desc):
    RESULTS.append((True, desc)); print('PASS:', desc, flush=True)


def bad(desc):
    RESULTS.append((False, desc)); print('FAIL:', desc, flush=True)


def check(desc, cond):
    (ok if cond else bad)(desc)


def make_disk(path, gib):
    """Sparse disk with an old GPT, one ext4 partition (OLDDATA) and random bytes at 1 GiB: 'old data' to protect."""
    with open(path, 'wb') as f:
        f.truncate(gib << 30)
    subprocess.run(['sgdisk', '-n', '1:2048:+512M', '-t', '1:8300', '-c', '1:olddata', path], check=True, capture_output=True)
    subprocess.run(['mke2fs', '-q', '-F', '-t', 'ext4', '-L', 'OLDDATA', '-E', 'offset=1048576', path, '524288k'], check=True)
    with open(path, 'r+b') as f:
        f.seek(1 << 30); f.write(os.urandom(1 << 20))


def sha_head(path, n):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        left = n
        while left:
            b = f.read(min(left, 1 << 22))
            if not b:
                break
            h.update(b); left -= len(b)
    return h.hexdigest()


def sha_range(path, start, n):
    with open(path, 'rb') as f:
        f.seek(start); return hashlib.sha256(f.read(n)).hexdigest()


def compare_image(img_xz, disk, skip=None):
    """Chunk-wise compare of `xz -dc img_xz` with the start of disk; skip = (start, end) byte range ignored.
    Returns (length, first mismatch offset or None)."""
    p = subprocess.Popen(['xz', '-dc', '--', img_xz], stdout=subprocess.PIPE)
    off = 0; bad_off = None
    with open(disk, 'rb') as d:
        while True:
            a = p.stdout.read(1 << 22)
            if not a:
                break
            b = d.read(len(a))
            if a != b and bad_off is None:
                for i in range(0, len(a), 512):
                    if a[i:i + 512] != b[i:i + 512] and not (skip and skip[0] <= off + i < skip[1]):
                        bad_off = off + i; break
            off += len(a)
    p.wait()
    return off, bad_off


class VM:
    def __init__(self, work, name, mode, disks, iso=None, fwd=None):
        self.work, self.name, self.mode, self.disks, self.iso, self.fwd = work, name, mode, disks, iso, fwd
        self.child = None
        self.log = None

    def args(self):
        a = ['qemu-system-x86_64', '-machine', 'q35', '-smp', '4', '-m', '4096', '-display', 'none',
             '-serial', 'stdio', '-monitor', 'none', '-name', self.name]
        a += ['-enable-kvm', '-cpu', 'host'] if os.access('/dev/kvm', os.W_OK) else ['-cpu', 'max']
        if self.mode in ('uefi', 'sb'):
            sb = self.mode == 'sb'
            vars_ = os.path.join(self.work, f'vars-{self.name}.fd')
            shutil.copy(f'{OVMF}/OVMF_VARS_4M.ms.fd' if sb else f'{OVMF}/OVMF_VARS_4M.fd', vars_)
            code = f'{OVMF}/OVMF_CODE_4M.secboot.fd' if sb else f'{OVMF}/OVMF_CODE_4M.fd'
            a += ['-drive', f'if=pflash,format=raw,readonly=on,file={code}', '-drive', f'if=pflash,format=raw,file={vars_}']
            if sb:
                a += ['-global', 'driver=cfi.pflash01,property=secure,value=on']
        if self.iso:
            a += ['-drive', f'file={self.iso},media=cdrom,if=none,id=cd,readonly=on', '-device', 'ide-cd,drive=cd,bootindex=0']
        for i, (path, kind) in enumerate(self.disks):
            a += ['-drive', f'file={path},if=none,id=d{i},format=raw']
            if kind == 'nvme':
                a += ['-device', f'nvme,serial=nvme{i},drive=d{i}']
            else:
                a += ['-device', f'virtio-blk-pci,drive=d{i}']
        net = 'user,id=n0' + (f',hostfwd=tcp:127.0.0.1:{self.fwd}-:443' if self.fwd else '')
        a += ['-netdev', net, '-device', 'virtio-net-pci,netdev=n0']
        return a

    def start(self, phase):
        self.log = open(os.path.join(self.work, f'serial-{self.name}-{phase}.log'), 'w')
        self.child = pexpect.spawn(self.args()[0], self.args()[1:], encoding='latin-1', timeout=60)
        self.child.logfile_read = self.log
        self.t0 = time.time()

    def stop(self):
        if self.child is not None and self.child.isalive():
            self.child.terminate(force=True)
        if self.log:
            self.log.close()
        self.child = None


def menu_serial_entry(vm, timeout=180):
    """GRUB menu on the serial port: choose the serial-console entry, return the seconds from power on."""
    vm.child.expect('serial console', timeout=timeout)
    t = time.time() - vm.t0
    time.sleep(1.5)
    vm.child.send('\x1b[B'); time.sleep(0.5); vm.child.send('\r')
    return t


def run_installer(work, name, mode, disks, pick_index=None, wrong_first=True):
    """Boots the ISO, drives the installer. Returns timing dict. disks: list of (path, kind)."""
    iso = work_iso
    vm = VM(work, name, mode, disks, iso=iso)
    vm.start('install')
    tm = {}
    try:
        tm['grub_menu_s'] = menu_serial_entry(vm)
        c = vm.child
        if len(disks) > 1:
            c.expect('Select the disk', timeout=240)
            tm['installer_ui_s'] = time.time() - vm.t0
            for _ in range(pick_index or 0):
                c.send('\x1b[B'); time.sleep(0.4)
            c.send('\r')
        c.expect('Type ERASE to erase this disk', timeout=240)
        tm.setdefault('installer_ui_s', time.time() - vm.t0)
        if wrong_first:
            c.send('erase\r')
            c.expect('Nothing was written', timeout=30)
            ok(f'{name}: wrong word reported')
            tm['wrong_seen'] = True
            c.send('\r')
            if len(disks) > 1:
                c.expect('Select the disk', timeout=60)
                for _ in range(pick_index or 0):
                    c.send('\x1b[B'); time.sleep(0.4)
                c.send('\r')
            c.expect('Type ERASE to erase this disk', timeout=60)
            tm['hash_checkpoint'] = True
            yield_checkpoint(vm, 'wrong')
        t_write = time.time()
        c.send('ERASE\r')
        c.expect('Checking media', timeout=60)
        c.expect('Writing', timeout=600)
        tm['check_s'] = time.time() - t_write
        t1 = time.time()
        c.expect('Verifying', timeout=1800)
        tm['write_s'] = time.time() - t1
        t2 = time.time()
        c.expect('Installation complete', timeout=1800)
        tm['verify_s'] = time.time() - t2
        tm['total_s'] = time.time() - vm.t0
        ok(f'{name}: installer finished')
        time.sleep(1); c.send('\r')
        time.sleep(3)
    finally:
        vm.stop()
    return tm


CHECKPOINTS = {}


def yield_checkpoint(vm, tag):
    """Hashes of the first MiB and of the 1 GiB spot of every disk while the VM runs (nothing may be written yet)."""
    CHECKPOINTS[(vm.name, tag)] = [(sha_head(p, 1 << 20), sha_range(p, 1 << 30, 1 << 20)) for p, _ in vm.disks]


def port_free(port):
    import socket
    with socket.socket() as s:
        return s.connect_ex(('127.0.0.1', port)) != 0


def boot_installed(work, name, mode, disk, port, timeout=900):
    if not port_free(port):
        bad(f'{name}: host port {port} is already in use')
        return None
    vm = VM(work, name, mode, [disk], fwd=port)
    vm.start('boot')
    ctx = ssl._create_unverified_context()
    up = None
    try:
        t = 0
        while t < timeout:
            time.sleep(5); t = time.time() - vm.t0
            try:
                r = urllib.request.urlopen(f'https://127.0.0.1:{port}/login', timeout=5, context=ctx)
                if r.status == 200:
                    up = t; break
            except Exception:
                pass
            if not vm.child.isalive():
                break
        return up
    finally:
        vm.stop()


def layout_ok(disk):
    out = subprocess.run(['sgdisk', '-p', disk], capture_output=True, text=True).stdout
    return all(n in out for n in ('EFI', 'ROOT_A', 'ROOT_B', 'DATA', 'BIOS')), out


def scenario(work, flash, name, mode, ndisks=1, pick_index=0, port=8443):
    print(f'=== {name}', flush=True)
    disks = []
    d0 = os.path.join(work, f'{name}-disk0.img'); make_disk(d0, 24); disks.append((d0, 'virtio'))
    if ndisks > 1:
        d1 = os.path.join(work, f'{name}-disk1.img'); make_disk(d1, 24); disks.append((d1, 'nvme'))
    before = [(sha_head(p, 1 << 20), sha_range(p, 1 << 30, 1 << 20)) for p, _ in disks]
    tm = run_installer(work, name, mode, disks, pick_index=pick_index if ndisks > 1 else None)
    # the VM order of disks in the picker is /sys/block name order: nvme0n1 before vda
    target = 0 if ndisks == 1 else (1 if pick_index == 1 else 0)
    # wrong answer left every disk untouched
    cp = CHECKPOINTS.get((name, 'wrong'))
    check(f'{name}: disks untouched after the wrong word', cp == before)
    # which disk got the image: virtio (disks[0]) is /dev/vda, the NVMe is /dev/nvme0n1 (listed first)
    chosen = disks[0][0] if (ndisks == 1 or pick_index == 1) else disks[1][0]
    other = None if ndisks == 1 else (disks[1][0] if chosen == disks[0][0] else disks[0][0])
    skip = (1 << 20, 513 << 20) if mode == 'sb' else None
    length, mism = compare_image(flash, chosen, skip)
    check(f'{name}: {length} written bytes equal the flash image' + (f' (ESP skipped)' if skip else ''), mism is None)
    z1 = sha_range(chosen, length, 16 << 20) == hashlib.sha256(bytes(16 << 20)).hexdigest()
    size = os.path.getsize(chosen)
    z2 = sha_range(chosen, size - (1 << 20), 1 << 20) == hashlib.sha256(bytes(1 << 20)).hexdigest()
    check(f'{name}: 16 MiB after the image and the last MiB are zero', z1 and z2)
    if other:
        i = [p for p, _ in disks].index(other)
        check(f'{name}: the other disk is untouched', (sha_head(other, 1 << 20), sha_range(other, 1 << 30, 1 << 20)) == before[i])
    if mode == 'sb':
        r = subprocess.run(f'MTOOLS_SKIP_CHECK=1 mtype -i {chosen}@@1048576 ::EFI/unitotem-sb/active', shell=True, capture_output=True, text=True)
        check(f'{name}: shim chain activated', r.stdout.strip() == 'shim')
    up = boot_installed(work, name, mode, (chosen, 'virtio'), port)
    check(f'{name}: installed disk boots alone, web interface answers' + (f' after {up:.0f}s' if up else ''), up is not None)
    good, out = layout_ok(chosen)
    check(f'{name}: first boot created ROOT_B and DATA', good)
    print(f'timing {name}: ' + ', '.join(f'{k}={v:.0f}' if isinstance(v, float) else f'{k}={v}' for k, v in tm.items()) + (f', web_after_boot={up:.0f}' if up else ''), flush=True)
    for p, _ in disks:
        os.remove(p)


def scenario_screen(work):
    """Default (tty1) entry on the QEMU VGA: screenshot of the installer after it started."""
    print('=== screen', flush=True)
    d0 = os.path.join(work, 'screen-disk0.img'); make_disk(d0, 24)
    mon = os.path.join(work, 'screen.mon')
    vm = VM(work, 'screen', 'bios', [(d0, 'virtio')], iso=work_iso)
    a = vm.args(); a[a.index('-monitor') + 1] = f'unix:{mon},server,nowait'
    vm.log = open(os.path.join(work, 'serial-screen-install.log'), 'w')
    vm.child = pexpect.spawn(a[0], a[1:], encoding='latin-1', timeout=60)
    try:
        for tag, wait in (('menu', 12), ('installer', 60)):
            time.sleep(wait)
            ppm = os.path.join(work, f'screen-{tag}.ppm')
            m = pexpect.spawn('socat', ['-', f'UNIX-CONNECT:{mon}'], encoding='latin-1', timeout=10)
            m.sendline(f'screendump {ppm}'); time.sleep(1); m.sendline('quit') if False else None; m.close()
            check(f'screen: {tag} screenshot written', os.path.exists(ppm) and os.path.getsize(ppm) > 1000)
    finally:
        vm.stop()
        os.remove(d0)


def main():
    global work_iso
    ap = argparse.ArgumentParser()
    ap.add_argument('iso'); ap.add_argument('flash')
    ap.add_argument('--scenarios', default='bios,uefi,multi,sb')
    ap.add_argument('--work', default='work/installer-iso-test')
    a = ap.parse_args()
    work_iso = os.path.abspath(a.iso); flash = os.path.abspath(a.flash)
    os.makedirs(a.work, exist_ok=True); work = os.path.abspath(a.work)
    for s in a.scenarios.split(','):
        if s == 'bios': scenario(work, flash, 'bios', 'bios', port=8443)
        elif s == 'uefi': scenario(work, flash, 'uefi', 'uefi', port=8444)
        elif s == 'multi': scenario(work, flash, 'multi', 'uefi', ndisks=2, pick_index=1, port=8445)
        elif s == 'sb': scenario(work, flash, 'sb', 'sb', port=8446)
        elif s == 'screen': scenario_screen(work)
        else: sys.exit(f'unknown scenario {s}')
    print(f'{sum(1 for r in RESULTS if r[0])} passed, {sum(1 for r in RESULTS if not r[0])} failed')
    sys.exit(1 if any(not r[0] for r in RESULTS) else 0)


if __name__ == '__main__':
    main()
