#!/usr/bin/env python3
"""Installer ISO test in user-mode QEMU (no root, no real disk, no libvirt).

Usage: test_installer_iso.py ISO FLASH_IMG.xz [--scenarios bios,uefi,multi,sb,screen] [--work DIR] [--boot-timeout S]
Scenarios (default: bios,uefi,multi,sb,screen):
  bios    serial-console entry, one disk: address on the screen, ssh without password, motd, manual start from the menu
          closes ssh (open sessions too), n reopens it, start from ssh blocks the menu, concurrent start refused,
          y y installs, disk-only boot
  uefi    OVMF, ISO on a USB stick, default entry: ssh only; boot media refused, no terminal refused, ssh -t install y y
  multi   OVMF, two disks (virtio, NVMe): picker over ssh, install --disk DEV -y, the other disk untouched
  sb      OVMF with Secure Boot enforcing: console install, the written image boots through its own signed chain
  screen  BIOS, default entry (tty1): screenshots of the screen to DIR/screen-*.png
Checks: written bytes equal the decompressed flash image (chunk by chunk), the 16 MiB after the image and the last MiB are
zero, hashes of untouched disks unchanged, the disk boots alone and the web interface answers, first boot created ROOT_B
and DATA. Sessions are logged to DIR/serial-<scenario>-<phase>.log.
Needs qemu-system-x86_64, OVMF (/usr/share/OVMF), sgdisk, mke2fs, ssh, socat, python3-pexpect, python3-pil. KVM when writable.
"""
import argparse, hashlib, os, re, shutil, ssl, subprocess, sys, time, urllib.request
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


BOOT_TIMEOUT = 900
QMP_ENV = {k: v for k, v in os.environ.items() if k not in ('DISPLAY', 'SSH_ASKPASS')}
QMP_ENV['SSH_ASKPASS_REQUIRE'] = 'never'
MOTD = ['UniTotem installer', 'To install UniTotem run: install']


class VM:
    def __init__(self, work, name, mode, disks, iso=None, usb=False, fwd=()):
        self.work, self.name, self.mode, self.disks, self.iso, self.usb, self.fwd = work, name, mode, disks, iso, usb, fwd
        self.child = None
        self.log = None
        self.mon = os.path.join(work, f'{name}.mon')

    def args(self):
        a = ['qemu-system-x86_64', '-machine', 'q35', '-smp', '4', '-m', '4096', '-display', 'none',
             '-serial', 'stdio', '-monitor', f'unix:{self.mon},server,nowait', '-name', self.name]
        a += ['-enable-kvm', '-cpu', 'host'] if os.access('/dev/kvm', os.W_OK) else ['-cpu', 'max']
        if self.mode in ('uefi', 'sb'):
            sb = self.mode == 'sb'
            vars_ = os.path.join(self.work, f'vars-{self.name}.fd')
            shutil.copy(f'{OVMF}/OVMF_VARS_4M.ms.fd' if sb else f'{OVMF}/OVMF_VARS_4M.fd', vars_)
            code = f'{OVMF}/OVMF_CODE_4M.secboot.fd' if sb else f'{OVMF}/OVMF_CODE_4M.fd'
            a += ['-drive', f'if=pflash,format=raw,readonly=on,file={code}', '-drive', f'if=pflash,format=raw,file={vars_}']
            if sb:
                a += ['-global', 'driver=cfi.pflash01,property=secure,value=on']
        if self.iso and self.usb:
            a += ['-device', 'qemu-xhci,id=xhci', '-drive', f'file={self.iso},if=none,id=cd,format=raw,readonly=on',
                  '-device', 'usb-storage,bus=xhci.0,drive=cd,bootindex=0']
        elif self.iso:
            a += ['-drive', f'file={self.iso},media=cdrom,if=none,id=cd,readonly=on', '-device', 'ide-cd,drive=cd,bootindex=0']
        for i, (path, kind) in enumerate(self.disks):
            a += ['-drive', f'file={path},if=none,id=d{i},format=raw']
            a += ['-device', f'nvme,serial=nvme{i},drive=d{i}'] if kind == 'nvme' else ['-device', f'virtio-blk-pci,drive=d{i}']
        net = 'user,id=n0' + ''.join(f',hostfwd=tcp:127.0.0.1:{h}-:{g}' for h, g in self.fwd)
        a += ['-netdev', net, '-device', 'virtio-net-pci,netdev=n0']
        return a

    def start(self, phase):
        for h, _ in self.fwd:
            if not port_free(h):
                raise RuntimeError(f'host port {h} in use')
        a = self.args()
        self.log = open(os.path.join(self.work, f'serial-{self.name}-{phase}.log'), 'w')
        self.child = pexpect.spawn(a[0], a[1:], encoding='latin-1', timeout=60)
        self.child.logfile_read = self.log
        self.t0 = time.time()

    def stop(self):
        if self.child is not None and self.child.isalive():
            self.child.terminate(force=True)
        if self.log:
            self.log.close()
        self.child = None

    def screendump(self, path_ppm):
        m = pexpect.spawn('socat', ['-', f'UNIX-CONNECT:{self.mon}'], encoding='latin-1', timeout=10)
        m.sendline(f'screendump {path_ppm}'); time.sleep(1.5); m.close()


def port_free(port):
    import socket
    with socket.socket() as s:
        return s.connect_ex(('127.0.0.1', port)) != 0


def serial_entry(vm, timeout=180):
    """GRUB menu on the serial port: the serial-console entry; returns the seconds from power on."""
    vm.child.expect('serial console', timeout=timeout)
    t = time.time() - vm.t0
    time.sleep(1.5)
    vm.child.send('\x1b[B'); time.sleep(0.5); vm.child.send('\r')
    return t


def ssh(port, cmd=None, tty=False, timeout=60):
    """ssh root@127.0.0.1 without password (empty password answered). Returns the pexpect child at the remote shell."""
    a = ['-p', str(port), '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
         '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1', '-o', 'ConnectTimeout=5',
         '-tt' if tty else '-T', 'root@127.0.0.1'] + ([cmd] if cmd else [])
    c = pexpect.spawn('ssh', a, env=QMP_ENV, encoding='latin-1', timeout=timeout)
    # dropbear in open mode accepts auth "none"; a password prompt is answered with an empty password
    c.early = ''
    i = c.expect([r'[Pp]assword: ?', pexpect.EOF, pexpect.TIMEOUT], timeout=3)
    if i == 0:
        c.sendline('')
    elif i == 1:
        c.early = c.before
    return c


def ssh_run(port, cmd, tty=False, timeout=600):
    """Runs cmd over ssh, returns (exit status, output). Output of a refused connection is returned with status 255."""
    c = ssh(port, cmd, tty, timeout)
    if c.isalive():
        c.expect(pexpect.EOF, timeout=timeout)
        out = c.early + c.before
    else:
        out = c.early
    c.close()
    return c.exitstatus, out


def wait_ssh(port, timeout=180):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            st, _ = ssh_run(port, 'true', timeout=20)
            if st == 0:
                return time.time() - t0
        except Exception:
            pass
        time.sleep(3)
    return None


def hashes(disks):
    return [(sha_head(p, 1 << 20), sha_range(p, 1 << 30, 1 << 20)) for p, _ in disks]


def clean(text):
    return re.sub(r'\x1b\[[0-9;?=]*[A-Za-z]', '', text).replace('\r', '')


Q1 = r'Erase /dev/\w+ and install UniTotem\? \(y/n\)'
Q2 = r'Last chance: erase this disk\? \(y/n\)'


def answers_cancel(c, name, tag):
    """At Q1: invalid answers ask again, n cancels; again to Q2: invalid, n cancels. Child c is at Q1."""
    for bad_answer in ('x', 'Y', 'yes'):
        c.send(bad_answer + '\r')
        c.expect('Invalid answer, type y or n', timeout=30)
        c.expect(Q1, timeout=30)
    ok(f'{name}: {tag}: invalid answers (x, Y, yes) ask again')
    c.send('n\r'); c.expect('changes=none', timeout=30)


def full_answers(c, timeout=1800):
    """At Q1: y, y, then waits for the end of the write; returns timings."""
    t0 = time.time(); tm = {}
    c.send('y\r'); c.expect(Q2, timeout=30); c.send('y\r')
    c.expect('Checking', timeout=60)
    c.expect('Writing', timeout=600); tm['check_s'] = time.time() - t0; t1 = time.time()
    c.expect('Verifying', timeout=timeout); tm['write_s'] = time.time() - t1; t2 = time.time()
    c.expect('install ok', timeout=timeout); tm['verify_s'] = time.time() - t2
    c.expect('Remove the installation media', timeout=60)
    return tm


def verify_written(name, mode, flash, disks, chosen, before, others=()):
    skip = None
    length, mism = compare_image(flash, chosen, skip)
    check(f'{name}: {length} written bytes equal the flash image', mism is None)
    size = os.path.getsize(chosen)
    z = (sha_range(chosen, length, 16 << 20) == hashlib.sha256(bytes(16 << 20)).hexdigest()
         and sha_range(chosen, size - (1 << 20), 1 << 20) == hashlib.sha256(bytes(1 << 20)).hexdigest())
    check(f'{name}: 16 MiB after the image and the last MiB are zero', z)
    for o in others:
        i = [p for p, _ in disks].index(o)
        check(f'{name}: the other disk is untouched', hashes([(o, '')])[0] == before[i])


def boot_installed(work, name, mode, disk, port, timeout=None):
    timeout = timeout or BOOT_TIMEOUT
    vm = VM(work, name, mode, [disk], fwd=[(port, 443)])
    vm.start('boot')
    ctx = ssl._create_unverified_context()
    up = None
    try:
        while time.time() - vm.t0 < timeout:
            time.sleep(5)
            try:
                if urllib.request.urlopen(f'https://127.0.0.1:{port}/login', timeout=5, context=ctx).status == 200:
                    up = time.time() - vm.t0; break
            except Exception:
                pass
            if not vm.child.isalive():
                break
        return up
    finally:
        vm.stop()


def finish(work, name, mode, chosen, port, tm):
    up = boot_installed(work, name, mode, (chosen, 'virtio'), port)
    check(f'{name}: installed disk boots alone, web interface answers' + (f' after {up:.0f}s' if up else ''), up is not None)
    out = subprocess.run(['sgdisk', '-p', chosen], capture_output=True, text=True).stdout
    check(f'{name}: first boot created ROOT_B and DATA', all(n in out for n in ('EFI', 'ROOT_A', 'ROOT_B', 'DATA', 'BIOS')))
    print(f'timing {name}: ' + ', '.join(f'{k}={v:.0f}' for k, v in tm.items()), flush=True)


def new_disks(work, name, n):
    disks = []
    for i in range(n):
        p = os.path.join(work, f'{name}-disk{i}.img'); make_disk(p, 24)
        disks.append((p, 'virtio' if i == 0 else 'nvme'))
    return disks


def scenario_console(work, flash, name, mode, port):
    """Serial-console entry: the whole manual / ssh interplay, then a console install."""
    print(f'=== {name}', flush=True)
    SSH = port; WEB = port + 1
    disks = new_disks(work, name, 1); before = hashes(disks)
    vm = VM(work, name, mode, disks, iso=work_iso, fwd=[(SSH, 22)])
    vm.start('install'); c = vm.child; tm = {}
    try:
        tm['grub_menu_s'] = serial_entry(vm)
        c.expect('Remote install: waiting for network', timeout=240); tm['screen_s'] = time.time() - vm.t0
        c.expect(r'Remote install: ssh root@10\.0\.2\.15', timeout=120)
        ok(f'{name}: screen shows the address (waiting, then ssh root@10.0.2.15)')
        t = wait_ssh(SSH)
        check(f'{name}: ssh without password while the screen is up', t is not None)
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30)
        lines = [l.strip() for l in clean(s.before).splitlines() if l.strip()]
        check(f'{name}: welcome message is exactly {MOTD}', lines[-2:] == MOTD)
        # manual start from the menu: ssh closes, the open session ends
        c.send('\r')
        c.expect('ssh closed reason=local install', timeout=60)
        ok(f'{name}: manual start prints the ssh closed line')
        check(f'{name}: open ssh session was terminated', s.expect([pexpect.EOF, pexpect.TIMEOUT], timeout=15) == 0)
        time.sleep(1)
        st, _ = ssh_run(SSH, 'true', timeout=20)
        check(f'{name}: ssh refused while the local install is asked', st == 255)
        c.expect(Q1, timeout=60)
        answers_cancel(c, name, 'console')
        c.expect(r'Remote install: ssh root@10\.0\.2\.15', timeout=60)
        ok(f'{name}: n returns to the screen')
        t = wait_ssh(SSH, 30)
        check(f'{name}: ssh reopened after n', t is not None)
        st, out = ssh_run(SSH, 'cat /run/unitotem-installer.log')
        check(f'{name}: log has the closed and reopened lines', 'INFO ssh closed reason=local install' in out and 'INFO ssh reopened' in out)
        # y then n at the second question
        c.send('\r'); c.expect(Q1, timeout=60); c.send('y\r'); c.expect(Q2, timeout=30)
        c.send('q\r'); c.expect('Invalid answer, type y or n', timeout=30); c.expect(Q2, timeout=30)
        c.send('n\r'); c.expect('changes=none', timeout=30)
        c.expect(r'Remote install: ssh root@10\.0\.2\.15', timeout=60)
        check(f'{name}: disks untouched after n and after y, n', hashes(disks) == before)
        # start from ssh: the console menu is replaced by the progress notice
        wait_ssh(SSH, 30)
        r1 = ssh(SSH, tty=True); r1.expect('# ', timeout=30); r1.sendline('install'); r1.expect(Q1, timeout=60)
        c.expect('Installation in progress \\(remote\\)', timeout=30)
        ok(f'{name}: console shows Installation in progress (remote)')
        st, out = ssh_run(SSH, 'install --disk /dev/vda -y', timeout=60)
        check(f'{name}: second install refused while one runs (exit 7)', st == 7 and 'installation in progress' in out)
        r1.send('n\r'); r1.expect('changes=none', timeout=30)
        r1.sendline('exit'); r1.expect(pexpect.EOF, timeout=15)
        c.expect(r'Remote install: ssh root@10\.0\.2\.15', timeout=60)
        ok(f'{name}: menu back after the remote run ended')
        check(f'{name}: disks untouched after the remote n', hashes(disks) == before)
        # the real install from the console
        c.send('\r'); c.expect(Q1, timeout=60)
        tm.update(full_answers(c))
        ok(f'{name}: console install finished')
        time.sleep(1)
    finally:
        vm.stop()
    verify_written(name, mode, flash, disks, disks[0][0], before)
    finish(work, name, mode, disks[0][0], WEB, tm)
    os.remove(disks[0][0])


def scenario_uefi_usb(work, flash, name, port):
    print(f'=== {name}', flush=True)
    SSH = port; WEB = port + 1
    disks = new_disks(work, name, 1); before = hashes(disks)
    vm = VM(work, name, 'uefi', disks, iso=work_iso, usb=True, fwd=[(SSH, 22)])
    vm.start('install'); tm = {}
    try:
        t = wait_ssh(SSH, 300)
        check(f'{name}: default entry up, ssh without password' + (f' after {t:.0f}s' if t else ''), t is not None)
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30)
        lines = [l.strip() for l in clean(s.before).splitlines() if l.strip()]
        check(f'{name}: welcome message is exactly {MOTD}', lines[-2:] == MOTD)
        s.sendline('exit'); s.expect(pexpect.EOF, timeout=15)
        st, out = ssh_run(SSH, 'install --disk /dev/sda -y')
        check(f'{name}: boot media refused (exit 4)', st == 4 and 'boot media' in out and 'changes=none' in out)
        st, out = ssh_run(SSH, 'install')
        check(f'{name}: no terminal refused (exit 3)', st == 3 and 'a terminal is required' in out)
        st, out = ssh_run(SSH, 'install --disk /dev/zzz -y')
        check(f'{name}: bad disk refused (exit 2 or 4)', st in (2, 4))
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30); s.sendline('install'); s.expect(Q1, timeout=60)
        answers_cancel(s, name, 'ssh')
        check(f'{name}: disks untouched after n', hashes(disks) == before)
        s.sendline('install'); s.expect(Q1, timeout=60)
        tm.update(full_answers(s))
        ok(f'{name}: ssh install finished')
        s.send('\r')
        time.sleep(3)
    finally:
        vm.stop()
    verify_written(name, 'uefi', flash, disks, disks[0][0], before)
    finish(work, name, 'uefi', disks[0][0], WEB, tm)
    os.remove(disks[0][0])


def scenario_multi(work, flash, name, port):
    print(f'=== {name}', flush=True)
    SSH = port; WEB = port + 1
    disks = new_disks(work, name, 2); before = hashes(disks)
    vm = VM(work, name, 'uefi', disks, iso=work_iso, fwd=[(SSH, 22)])
    vm.start('install'); tm = {}
    try:
        t = wait_ssh(SSH, 300)
        check(f'{name}: default entry up, ssh without password', t is not None)
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30); s.sendline('install')
        s.expect(r'1\) /dev/nvme0n1', timeout=60); s.expect(r'2\) /dev/vda'); s.expect('Select the disk')
        ok(f'{name}: picker lists both disks')
        s.send('9\r'); s.expect('Invalid answer, type a number from 1 to 2 or q', timeout=15)
        s.send('2\r'); s.expect(Q1, timeout=30)
        answers_cancel(s, name, 'picker')
        s.sendline('install'); s.expect('Select the disk \\(1-2', timeout=60); s.send('q\r'); s.expect('cancelled changes=none', timeout=15)
        check(f'{name}: disks untouched after n and q', hashes(disks) == before)
        s.sendline('exit'); s.expect(pexpect.EOF, timeout=15)
        t0 = time.time()
        st, out = ssh_run(SSH, 'install --disk /dev/vda -y', timeout=1800)
        tm['unattended_s'] = time.time() - t0
        check(f'{name}: install --disk /dev/vda -y over ssh ends 0 and names disk and size',
              st == 0 and 'target=/dev/vda' in out and 'GiB' in out and 'install ok disk=/dev/vda' in out)
    finally:
        vm.stop()
    verify_written(name, 'uefi', flash, disks, disks[0][0], before, others=[disks[1][0]])
    finish(work, name, 'uefi', disks[0][0], WEB, tm)
    for p, _ in disks:
        os.remove(p)


def scenario_screen(work):
    """Default (tty1) entry on the VGA: screenshots of the screen, with and without an address."""
    print('=== screen', flush=True)
    disks = new_disks(work, 'screen', 1)
    vm = VM(work, 'screen', 'bios', disks, iso=work_iso, fwd=[(2280, 22)])
    vm.start('install')
    try:
        for tag, wait in (('menu', 40), ('late', 40)):
            time.sleep(wait)
            ppm = os.path.join(work, f'screen-{tag}.ppm')
            vm.screendump(ppm)
            ok_ = os.path.exists(ppm) and os.path.getsize(ppm) > 1000
            check(f'screen: {tag} screenshot written', ok_)
            if ok_:
                from PIL import Image
                Image.open(ppm).save(os.path.join(work, f'screen-{tag}.png')); os.remove(ppm)
    finally:
        vm.stop()
        os.remove(disks[0][0])


def main():
    global work_iso, BOOT_TIMEOUT
    ap = argparse.ArgumentParser()
    ap.add_argument('iso'); ap.add_argument('flash')
    ap.add_argument('--scenarios', default='bios,uefi,multi,sb,screen')
    ap.add_argument('--work', default='work/installer-iso-test')
    ap.add_argument('--boot-timeout', type=int, default=900, help='seconds to wait for the web interface of the installed disk')
    a = ap.parse_args()
    BOOT_TIMEOUT = a.boot_timeout
    work_iso = os.path.abspath(a.iso); flash = os.path.abspath(a.flash)
    os.makedirs(a.work, exist_ok=True); work = os.path.abspath(a.work)
    for s in a.scenarios.split(','):
        if s == 'bios': scenario_console(work, flash, 'bios', 'bios', 2200)
        elif s == 'uefi': scenario_uefi_usb(work, flash, 'uefi', 2210)
        elif s == 'multi': scenario_multi(work, flash, 'multi', 2220)
        elif s == 'sb': scenario_console(work, flash, 'sb', 'sb', 2230)
        elif s == 'screen': scenario_screen(work)
        else: sys.exit(f'unknown scenario {s}')
    print(f'{sum(1 for r in RESULTS if r[0])} passed, {sum(1 for r in RESULTS if not r[0])} failed')
    sys.exit(1 if any(not r[0] for r in RESULTS) else 0)


if __name__ == '__main__':
    main()
