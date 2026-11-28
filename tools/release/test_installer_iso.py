#!/usr/bin/env python3
"""Installer ISO test in user-mode QEMU (no root, no real disk, no libvirt).

Usage: test_installer_iso.py ISO FLASH_IMG.xz [--scenarios bios,uefi,multi,sb,screen,small] [--work DIR] [--boot-timeout S]
Scenarios (default: bios,uefi,multi,sb,screen,small):
  bios    serial-console entry, one disk: address on the screen, ssh without password, motd. Serial whiptail: Enter on
          the menu shows the confirmation (default No) and closes ssh (open sessions too); Enter (No) and Esc (No)
          cancel, the log has changes=none and ssh reopens; a remote install shows the progress screen and a second
          one is refused (exit 7); Tab, Enter (Yes) installs; the result box and the restart / power-off menu follow
  uefi    OVMF, ISO on a USB stick, default entry: ssh only (TERM not linux); boot media refused, no terminal refused,
          install --plain with TERM=linux (text prompt, n cancels), ssh -t install: x (invalid), n (cancel, nothing
          written), YES accepted
  multi   OVMF, three disks: 24 GiB virtio (/dev/vda), 24 GiB NVMe, 8 GiB virtio (/dev/vdb, below the minimum): picker
          lists (too small) for vdb and refuses it, install --disk /dev/vdb -y refused (exit 4, changes=none), picker
          over ssh, install --disk /dev/vda -y, the other two disks untouched
  sb      OVMF with Secure Boot enforcing: console install, the written image boots through its own signed chain
  screen  BIOS, default entry (tty1), disks 24 GiB (/dev/vda) and 8 GiB (/dev/vdb): the whiptail screens driven
          through the QEMU monitor (sendkey), a screenshot of each step to DIR/screen-N-*.png (blue root and grey
          dialog checked, text read with tesseract), the written disk compared, the 8 GiB disk untouched
  small   OVMF, one 8 GiB virtio disk (below the minimum), nothing else: install --disk /dev/vda -y refused (exit 4,
          too small, changes=none), picker refuses the only disk without a question, first MiB and sample unchanged
Checks: written bytes equal the decompressed flash image (chunk by chunk), the 16 MiB after the image and the last MiB are
zero, hashes of untouched disks unchanged, the disk boots alone and the web interface answers, first boot created ROOT_B
and DATA. Sessions are logged to DIR/serial-<scenario>-<phase>.log.
UEFI (uefi, sb, multi, small): the NVRAM variables are kept in DIR/vars-<scenario>.fd, created by the first start of the
scenario (fresh_vars) and reused by the later starts, so the installed disk boots with the NVRAM the install wrote.
sb: the live system reports SecureBoot=1 over ssh and the kernel log names Secure boot enabled or locked down; the
installed disk (uefi, sb) gets a first administrator over the first-access shell, then sudo reads the SecureBoot
variable, the lockdown mode, efibootmgr -v and BootCurrent (must be the UniTotem entry, \\EFI\\BOOT\\BOOTX64.EFI).
The console install closes ssh after the write, so the installer log is read by a second install over ssh from the ISO
on the same disk (sb, bios): "boot entry created label=UniTotem" (sb), "boot entry skipped reason=bios" (bios).
uefi reads the log after its ssh install.
Disk images: DIR, or with the env var ISOWIN_TMP set work/iso-win/isowin-iso-tmp (sparse, named isowin-*); all removed at exit.
Needs qemu-system-x86_64, OVMF (/usr/share/OVMF), sgdisk, mke2fs, ssh, socat, python3-pexpect, python3-pil, tesseract (screen scenario). KVM when writable.
"""
import argparse, atexit, hashlib, os, re, shutil, ssl, subprocess, sys, time, urllib.request
import pexpect

OVMF = '/usr/share/OVMF'
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
ISOWIN_TMP_DIR = os.path.join(REPO, 'work', 'iso-win', 'isowin-iso-tmp')
DISK_FILES = []
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
QMP_ENV['TERM'] = 'xterm-256color'      # ssh sessions take the plain path; a session sets TERM=linux only on purpose
MOTD = ['UniTotem installer', 'To install UniTotem run: install']


class VM:
    def __init__(self, work, name, mode, disks, iso=None, usb=False, fwd=()):
        self.work, self.name, self.mode, self.disks, self.iso, self.usb, self.fwd = work, name, mode, disks, iso, usb, fwd
        self.child = None
        self.log = None
        self.mon = os.path.join(work, f'{name}.mon')

    def args(self, fresh_vars=False):
        a = ['qemu-system-x86_64', '-machine', 'q35', '-smp', '4', '-m', '4096', '-display', 'none',
             '-serial', 'stdio', '-monitor', f'unix:{self.mon},server,nowait', '-name', self.name]
        a += ['-enable-kvm', '-cpu', 'host'] if os.access('/dev/kvm', os.W_OK) else ['-cpu', 'max']
        if self.mode in ('uefi', 'sb'):
            sb = self.mode == 'sb'
            ms = sb
            vars_ = os.path.join(self.work, f'vars-{self.name}.fd')
            # NVRAM of the scenario: created by the first start (fresh_vars), reused by later starts
            if fresh_vars or not os.path.exists(vars_):
                shutil.copy(f'{OVMF}/OVMF_VARS_4M.ms.fd' if ms else f'{OVMF}/OVMF_VARS_4M.fd', vars_)
            code = f'{OVMF}/OVMF_CODE_4M.secboot.fd' if ms else f'{OVMF}/OVMF_CODE_4M.fd'
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

    def start(self, phase, fresh_vars=False):
        for h, _ in self.fwd:
            if not port_free(h):
                raise RuntimeError(f'host port {h} in use')
        a = self.args(fresh_vars)
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


def ssh(port, cmd=None, tty=False, timeout=60, term=None, user='root', password=''):
    """ssh USER@127.0.0.1 (root without password by default: open mode, empty password answered). Returns the pexpect
    child at the remote shell. term: TERM of this session (default xterm-256color, the plain installer path)."""
    a = ['-p', str(port), '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
         '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1', '-o', 'ConnectTimeout=5',
         '-tt' if tty else '-T', f'{user}@127.0.0.1'] + ([cmd] if cmd else [])
    c = pexpect.spawn('ssh', a, env=dict(QMP_ENV, TERM=term) if term else QMP_ENV, encoding='latin-1', timeout=timeout)
    # dropbear in open mode accepts auth "none"; a password prompt is answered with the given password
    c.early = ''
    i = c.expect([r'[Pp]assword: ?', pexpect.EOF, pexpect.TIMEOUT], timeout=3)
    if i == 0:
        c.sendline(password)
    elif i == 1:
        c.early = c.before
    return c


def ssh_run(port, cmd, tty=False, timeout=600, user='root', password=''):
    """Runs cmd over ssh, returns (exit status, output). Output of a refused connection is returned with status 255."""
    c = ssh(port, cmd, tty, timeout, user=user, password=password)
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


def answers_cancel(c, name, tag):
    """At Q1: invalid answer x asks again, n cancels (nothing written). Child c is at Q1."""
    c.send('x\r')
    c.expect('Invalid answer, type y or n', timeout=30)
    c.expect(Q1, timeout=30)
    ok(f'{name}: {tag}: invalid answer (x) asks again')
    c.send('n\r'); c.expect('changes=none', timeout=30)


def full_answers(c, name, answer='y', timeout=1800):
    """At Q1: one confirmation (answer), then waits for the end of the write; returns timings."""
    t0 = time.time(); tm = {}
    c.send(answer + '\r')
    c.expect('Checking', timeout=60)
    check(f'{name}: {answer} is the only question, no Last chance question', 'Last chance' not in c.before)
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


def nvram_state(work, name, tag):
    """One line on the NVRAM file of the scenario: size, mtime, hash, and how often the label UniTotem occurs (UCS-2)."""
    p = os.path.join(work, f'vars-{name}.fd')
    if not os.path.exists(p):
        return f'nvram {tag}: no vars file'
    with open(p, 'rb') as f:
        data = f.read()
    st = os.stat(p)
    return (f'nvram {tag}: size={st.st_size} mtime={time.strftime("%H:%M:%S", time.localtime(st.st_mtime))} '
            f'sha256={hashlib.sha256(data).hexdigest()[:16]} UniTotem_ucs2={data.count("UniTotem".encode("utf-16-le"))}')


def boot_installed(work, name, mode, disk, port, timeout=None, ssh_port=None, probe=None):
    """Boots the disk alone with the scenario's NVRAM (never recreated here). probe() runs while the web interface is up."""
    timeout = timeout or BOOT_TIMEOUT
    fwd = [(port, 443)] + ([(ssh_port, 22)] if ssh_port else [])
    vm = VM(work, name, mode, [disk], fwd=fwd)
    print(nvram_state(work, name, 'before boot start'), flush=True)
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
        if up is not None and probe is not None:
            probe()
        return up
    finally:
        vm.stop()
        print(nvram_state(work, name, 'after boot stop'), flush=True)


def finish(work, name, mode, chosen, port, tm, ssh_port=None, probe=None):
    up = boot_installed(work, name, mode, (chosen, 'virtio'), port, ssh_port=ssh_port, probe=probe)
    check(f'{name}: installed disk boots alone, web interface answers' + (f' after {up:.0f}s' if up else ''), up is not None)
    out = subprocess.run(['sgdisk', '-p', chosen], capture_output=True, text=True).stdout
    check(f'{name}: first boot created ROOT_B and DATA', all(n in out for n in ('EFI', 'ROOT_A', 'ROOT_B', 'DATA', 'BIOS')))
    print(f'timing {name}: ' + ', '.join(f'{k}={v:.0f}' for k, v in tm.items()), flush=True)


SB_EFIVAR = '/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c'
ADMIN, ADMIN_PW = 'isowin', 'Tester.7Disk'      # throwaway administrator of the test disk, removed with it


def secure_boot_value(out):
    """Value byte of the SecureBoot variable from `od -An -tu1` output (4 attribute bytes, then the value), or None."""
    for line in reversed(out.splitlines()):
        if re.fullmatch(r'\s*\d+(\s+\d+)*\s*', line):
            nums = [int(x) for x in line.split()]
            return nums[-1] if len(nums) == 5 else None
    return None


def live_secure_boot(name, port):
    """Live ISO (ssh open, before the install): SecureBoot variable, kernel log line, lockdown mode."""
    st, out = ssh_run(port, f'mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars; '
                            f'od -An -tu1 {SB_EFIVAR}; dmesg | grep -E "Secure boot enabled|locked down"; cat /sys/kernel/security/lockdown 2>/dev/null; true',
                      timeout=60)
    print('live SecureBoot od: ' + ' '.join(l.strip() for l in out.splitlines() if re.fullmatch(r'\s*\d+(\s+\d+)*\s*', l)), flush=True)
    check(f'{name}: live SecureBoot variable ends with 1', st == 0 and secure_boot_value(out) == 1)
    kmsg = [l.strip() for l in out.splitlines() if 'Secure boot enabled' in l or 'locked down' in l]
    print(f'live kernel log: {kmsg}', flush=True)
    check(f'{name}: live kernel log says Secure boot enabled or locked down', bool(kmsg))
    lock = [l.strip() for l in out.splitlines() if re.search(r'\[(none|integrity|confidentiality)\]', l)]
    print(f'live lockdown: {lock}', flush=True)


def efi_entry_checks(name, out, booted=True):
    """efibootmgr -v output of the installed system: UniTotem entry with the removable loader path, first in BootOrder,
    and (booted) BootCurrent is that entry. Plain OVMF rebuilds its boot options at the first start of the
    installed machine and drops entries it did not create, so the `uefi` scenario checks the entry in the live system after the
    install; the NVRAM boot is proven in `sb`."""
    cur = re.search(r'^BootCurrent: ([0-9A-Fa-f]{4})\s*$', out, re.M)
    order = re.search(r'^BootOrder: ([0-9A-Fa-f,]+)', out, re.M)
    ent = re.search(r'^Boot([0-9A-Fa-f]{4})\*? UniTotem\t(.*)$', out, re.M)
    if ent is None:
        bad(f'{name}: efibootmgr lists UniTotem')
        return
    num = ent.group(1).upper(); path = ent.group(2).lower()
    check(f'{name}: efibootmgr lists UniTotem (Boot{num}) on HD(1,GPT) with \\EFI\\BOOT\\BOOTX64.EFI',
          '\\efi\\boot\\bootx64.efi' in path and 'hd(1,gpt' in path)
    check(f'{name}: BootOrder starts with Boot{num}', order is not None and order.group(1).split(',')[0].upper() == num)
    if booted:
        check(f'{name}: BootCurrent is Boot{num} (booted through the NVRAM entry)', cur is not None and cur.group(1).upper() == num)


def installed_probe(name, mode, port):
    """Installed disk, web up: first administrator over the first-access shell, then sudo reads the firmware state.
    uefi: efibootmgr; sb: also the SecureBoot variable and the lockdown mode."""
    def probe():
        s = None
        for _ in range(12):
            c = ssh(port, tty=True, timeout=60)
            try:
                c.expect('User name: ', timeout=30); s = c; break
            except (pexpect.EOF, pexpect.TIMEOUT):
                c.close(force=True); time.sleep(5)
        if s is None:
            bad(f'{name}: first-access shell not reachable over ssh')
            return
        s.sendline(ADMIN); s.expect('Password: ', timeout=30); s.sendline(ADMIN_PW)
        s.expect('Password again: ', timeout=30); s.sendline(ADMIN_PW)
        i = s.expect([f'Administrator {ADMIN} created', pexpect.EOF, pexpect.TIMEOUT], timeout=60)
        s.close(force=True)
        if i != 0:
            bad(f'{name}: first administrator not created')
            return
        cmd = ''
        if mode == 'sb':
            cmd += f'od -An -tu1 {SB_EFIVAR}; cat /sys/kernel/security/lockdown; dmesg | grep -E "Secure boot enabled|locked down"; '
        cmd += 'efibootmgr -v; efibootmgr | grep BootCurrent'
        st, out = ssh_run(port, f"echo {ADMIN_PW} | sudo -S -p '' sh -c '{cmd}'", timeout=120, user=ADMIN, password=ADMIN_PW)
        check(f'{name}: administrator reads the firmware state over ssh (sudo)', st == 0)
        if mode == 'sb':
            v = secure_boot_value(out)
            print('installed SecureBoot od: ' + ' '.join(l.strip() for l in out.splitlines() if re.fullmatch(r'\s*\d+(\s+\d+)*\s*', l)), flush=True)
            check(f'{name}: installed SecureBoot variable ends with 1', v == 1)
            lock = [l.strip() for l in out.splitlines() if re.search(r'\[(none|integrity|confidentiality)\]', l)]
            print(f'installed lockdown: {lock}', flush=True)
            check(f'{name}: installed lockdown is active', any(re.search(r'\[(integrity|confidentiality)\]', l) for l in lock))
        print('installed efibootmgr:\n' + '\n'.join(l for l in out.splitlines() if l.startswith(('Boot', 'HD(', '+HD('))), flush=True)
        if mode == 'sb':
            efi_entry_checks(name, out)
    return probe


def entry_log_check(name, mode, log):
    """Installer log line for the UEFI boot entry (uefi, sb) or the BIOS skip (bios)."""
    if mode == 'bios':
        check(f'{name}: log says boot entry skipped reason=bios', 'INFO boot entry skipped reason=bios' in log)
    else:
        check(f'{name}: log says boot entry created label=UniTotem', 'INFO boot entry created label=UniTotem' in log)


def reinstall_check(work, flash, name, mode, disk, ssh_port):
    """Second install over ssh from the ISO on the installed disk: the console install closes ssh after the write, so
    this is the only way to read the installer log. sb: fresh NVRAM, the installed entry would boot before the ISO."""
    vm = VM(work, name, mode, [disk], iso=work_iso, fwd=[(ssh_port, 22)])
    vm.start('reinstall', fresh_vars=True)
    try:
        t = wait_ssh(ssh_port, 300)
        check(f'{name}: ISO up on the installed disk, ssh without password' + (f' after {t:.0f}s' if t else ''), t is not None)
        if t is None:
            return
        st, out = ssh_run(ssh_port, 'install --disk /dev/vda -y', timeout=1800)
        check(f'{name}: install --disk /dev/vda -y over ssh ends 0', st == 0 and 'install ok disk=/dev/vda' in out)
        st, log = ssh_run(ssh_port, 'cat /run/unitotem-installer.log')
        entry_log_check(name, mode, log)
    finally:
        vm.stop()
    verify_written(name + ' reinstall', mode, flash, [disk], disk[0], [])


def new_disk(work, name, i, gib, kind):
    """Disk file isowin-<name>-disk<i>.img in ISOWIN_TMP (when set) or in work; removed by cleanup_disks."""
    base = ISOWIN_TMP_DIR if os.environ.get('ISOWIN_TMP') else work
    os.makedirs(base, exist_ok=True)
    p = os.path.join(base, f'isowin-{name}-disk{i}.img'); DISK_FILES.append(p)
    make_disk(p, gib)
    return (p, kind)


def new_disks(work, name, n):
    return [new_disk(work, name, i, 24, 'virtio' if i == 0 else 'nvme') for i in range(n)]


def cleanup_disks():
    """Removes the throwaway disks, and the ISOWIN_TMP folder when it is empty."""
    for p in DISK_FILES:
        if os.path.exists(p):
            os.remove(p)
    if os.environ.get('ISOWIN_TMP') and os.path.isdir(ISOWIN_TMP_DIR) and not os.listdir(ISOWIN_TMP_DIR):
        os.rmdir(ISOWIN_TMP_DIR)


YESNO = r'Erase /dev/\w+ and install UniTotem\?'


def ui_install(c, name, timeout=1800):
    """Console install after the confirmation's Yes: gauge, result box, restart / power-off menu. c is at the yesno."""
    tm = {}
    c.send('\t'); c.expect([pexpect.TIMEOUT], timeout=1)      # Tab selects Yes; its repaint is drained
    c.send('\r')
    c.expect('Checking the media', timeout=120)
    check(f'{name}: one confirmation, no second question', 'Erase /dev/' not in c.before)
    t1 = time.time()
    c.expect('Writing', timeout=600); tm['check_s'] = time.time() - t1; t1 = time.time()
    c.expect('Verifying', timeout=timeout); tm['write_s'] = time.time() - t1; t1 = time.time()
    c.expect('UniTotem is installed on', timeout=timeout); tm['verify_s'] = time.time() - t1
    c.expect('Remove the installation media', timeout=60)
    ok(f'{name}: gauge (checking, writing, verifying) and result box')
    c.send('\r')                                              # closes the result box
    c.expect('Installation finished', timeout=60)
    ok(f'{name}: restart / power-off menu after the result')
    return tm


def scenario_console(work, flash, name, mode, port):
    """Serial-console entry: the whiptail menu and install dialogs over serial, the ssh interplay, then a console install."""
    print(f'=== {name}', flush=True)
    SSH = port; WEB = port + 1
    disks = new_disks(work, name, 1); before = hashes(disks)
    vm = VM(work, name, mode, disks, iso=work_iso, fwd=[(SSH, 22)])
    vm.start('install', fresh_vars=True); c = vm.child; tm = {}
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
        if mode == 'sb':
            live_secure_boot(name, SSH)
        # Enter on the menu: the confirmation (default No) shows and ssh closes, the open session ends
        c.send('\r')
        c.expect(YESNO, timeout=60); c.expect(r'Disk: /dev/vda', timeout=15)
        ok(f'{name}: menu Enter shows the confirmation with the target disk')
        check(f'{name}: open ssh session was terminated', s.expect([pexpect.EOF, pexpect.TIMEOUT], timeout=15) == 0)
        time.sleep(1)
        st, _ = ssh_run(SSH, 'true', timeout=20)
        check(f'{name}: ssh refused while the confirmation is up', st == 255)
        # Enter = No: cancelled, nothing written, the menu returns, ssh reopens
        c.send('\r')
        c.expect(r'Remote install: ssh root@10\.0\.2\.15', timeout=60)
        ok(f'{name}: Enter (No) returns to the menu')
        t = wait_ssh(SSH, 30)
        check(f'{name}: ssh reopened after No', t is not None)
        st, out = ssh_run(SSH, 'cat /run/unitotem-installer.log')
        check(f'{name}: log has ssh closed, cancelled changes=none, ssh reopened',
              all(x in out for x in ('INFO ssh closed reason=local install', 'INFO cancelled disk=/dev/vda changes=none',
                                     'INFO ssh reopened reason=install ended')))
        check(f'{name}: disks untouched after No', hashes(disks) == before)
        # Esc = No
        c.send('\r'); c.expect(YESNO, timeout=60)
        c.send('\x1b')
        c.expect(r'Remote install: ssh root@10\.0\.2\.15', timeout=60)
        ok(f'{name}: Esc (No) returns to the menu')
        wait_ssh(SSH, 30)
        st, out = ssh_run(SSH, 'grep -c "INFO cancelled disk=/dev/vda changes=none" /run/unitotem-installer.log')
        check(f'{name}: Esc cancel logged (two cancels in the log)', st == 0 and re.search(r'^2\s*$', out, re.M) is not None)
        check(f'{name}: disks untouched after Esc', hashes(disks) == before)
        # a remote install over ssh takes the console: the menu shows the progress screen
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
        wait_ssh(SSH, 30)
        c.send('\r'); c.expect(YESNO, timeout=60)
        tm.update(ui_install(c, name))
        ok(f'{name}: console install finished')
        time.sleep(1)
    finally:
        vm.stop()
    verify_written(name, mode, flash, disks, disks[0][0], before)
    with_efi = mode == 'sb'
    finish(work, name, mode, disks[0][0], WEB, tm, ssh_port=SSH if with_efi else None,
           probe=installed_probe(name, mode, SSH) if with_efi else None)
    if mode in ('sb', 'bios'):
        # the installer log of the console install is not reachable: a second install over ssh from the ISO
        reinstall_check(work, flash, name, mode, disks[0], SSH)
        finish(work, name, mode, disks[0][0], WEB, {}, ssh_port=SSH if with_efi else None,
               probe=installed_probe(name, mode, SSH) if with_efi else None)
        drop_vars(work, name)
    os.remove(disks[0][0])


def drop_vars(work, name):
    """Removes the NVRAM file of a scenario once its last boot is checked."""
    p = os.path.join(work, f'vars-{name}.fd')
    if os.path.exists(p):
        os.remove(p)


def scenario_uefi_usb(work, flash, name, port):
    print(f'=== {name}', flush=True)
    SSH = port; WEB = port + 1
    disks = new_disks(work, name, 1); before = hashes(disks)
    vm = VM(work, name, 'uefi', disks, iso=work_iso, usb=True, fwd=[(SSH, 22)])
    vm.start('install', fresh_vars=True); tm = {}
    try:
        t = wait_ssh(SSH, 300)
        check(f'{name}: default entry up, ssh without password' + (f' after {t:.0f}s' if t else ''), t is not None)
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30)
        lines = [l.strip() for l in clean(s.before).splitlines() if l.strip()]
        check(f'{name}: welcome message is exactly {MOTD}', lines[-2:] == MOTD)
        s.sendline('exit'); s.expect(pexpect.EOF, timeout=15)
        # TERM=linux over ssh would take the whiptail path; --plain keeps the text prompt
        s = ssh(SSH, tty=True, term='linux'); s.expect('# ', timeout=30)
        s.sendline('install --plain'); s.expect(Q1, timeout=60)
        s.send('n\r'); s.expect('INFO cancelled disk=/dev/vda changes=none', timeout=30)
        ok(f'{name}: install --plain with TERM=linux gives the text prompt, n cancels')
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
        tm.update(full_answers(s, name, 'YES'))
        ok(f'{name}: ssh install finished')
        st, log = ssh_run(SSH, 'cat /run/unitotem-installer.log')
        entry_log_check(name, 'uefi', log)
        st, live = ssh_run(SSH, 'sync; efibootmgr -v; efibootmgr | grep BootCurrent', timeout=60)
        print(f'live efibootmgr after install (status {st}):\n' + '\n'.join(
            l for l in live.splitlines() if l.startswith(('Boot', 'HD(', '+HD('))), flush=True)
        print(nvram_state(work, name, 'live after install'), flush=True)
        efi_entry_checks(name, live, booted=False)
        s.send('\r')
        time.sleep(3)
    finally:
        vm.stop()
        print(nvram_state(work, name, 'after install stop'), flush=True)
    verify_written(name, 'uefi', flash, disks, disks[0][0], before)
    finish(work, name, 'uefi', disks[0][0], WEB, tm, ssh_port=SSH, probe=installed_probe(name, 'uefi', SSH))
    drop_vars(work, name)
    os.remove(disks[0][0])


def scenario_multi(work, flash, name, port):
    print(f'=== {name}', flush=True)
    SSH = port; WEB = port + 1
    disks = new_disks(work, name, 2)
    disks.append(new_disk(work, name, 2, 8, 'virtio'))  # 8 GiB: below the A/B minimum, listed as (too small)
    before = hashes(disks)
    vm = VM(work, name, 'uefi', disks, iso=work_iso, fwd=[(SSH, 22)])
    vm.start('install'); tm = {}
    try:
        t = wait_ssh(SSH, 300)
        check(f'{name}: default entry up, ssh without password', t is not None)
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30); s.sendline('install')
        s.expect(r'1\) /dev/nvme0n1', timeout=60); s.expect(r'2\) /dev/vda'); s.expect(r'3\) /dev/vdb .*\(too small\)')
        s.expect('Select the disk')
        ok(f'{name}: picker lists three disks, 8 GiB one as (too small)')
        s.send('9\r'); s.expect('Invalid answer, type a number from 1 to 3 or q', timeout=15)
        s.send('3\r'); s.expect(r'WARNING disk=/dev/vdb too small min=\d+', timeout=15); s.expect('Select the disk \\(1-3', timeout=15)
        ok(f'{name}: picker refuses the (too small) disk and asks again')
        s.send('2\r'); s.expect(Q1, timeout=30)
        answers_cancel(s, name, 'picker')
        s.sendline('install'); s.expect('Select the disk \\(1-3', timeout=60); s.send('q\r'); s.expect('cancelled changes=none', timeout=15)
        check(f'{name}: disks untouched after n and q', hashes(disks) == before)
        st, out = ssh_run(SSH, 'install --disk /dev/vdb -y', timeout=60)
        check(f'{name}: install --disk /dev/vdb -y refused (exit 4, too small min=, changes=none)',
              st == 4 and re.search(r'too small min=\d+ changes=none', out) is not None)
        s.sendline('exit'); s.expect(pexpect.EOF, timeout=15)
        t0 = time.time()
        st, out = ssh_run(SSH, 'install --disk /dev/vda -y', timeout=1800)
        tm['unattended_s'] = time.time() - t0
        check(f'{name}: install --disk /dev/vda -y over ssh ends 0 and names disk and size',
              st == 0 and 'target=/dev/vda' in out and 'GiB' in out and 'install ok disk=/dev/vda' in out)
    finally:
        vm.stop()
    verify_written(name, 'uefi', flash, disks, disks[0][0], before, others=[disks[1][0], disks[2][0]])
    finish(work, name, 'uefi', disks[0][0], WEB, tm)
    for p, _ in disks:
        os.remove(p)


def scenario_small(work, flash, name, port):
    """One 8 GiB disk, below the minimum, nothing else: refused by --disk and by the picker, nothing written."""
    print(f'=== {name}', flush=True)
    SSH = port
    disks = [new_disk(work, name, 0, 8, 'virtio')]; before = hashes(disks)
    vm = VM(work, name, 'uefi', disks, iso=work_iso, usb=True, fwd=[(SSH, 22)])
    vm.start('install')
    try:
        t = wait_ssh(SSH, 300)
        check(f'{name}: default entry up, ssh without password' + (f' after {t:.0f}s' if t else ''), t is not None)
        st, out = ssh_run(SSH, 'install --disk /dev/vda -y')
        check(f'{name}: install --disk /dev/vda -y refused (exit 4, too small min=, changes=none)',
              st == 4 and re.search(r'ERROR disk=/dev/vda too small min=\d+ changes=none', out) is not None)
        s = ssh(SSH, tty=True); s.expect('# ', timeout=30); s.sendline('install')
        i = s.expect([Q1, r'WARNING disk=/dev/vda too small min=\d+ changes=none'], timeout=60)
        check(f'{name}: picker refuses the only disk, no question asked', i == 1)
        s.expect('cancelled changes=none', timeout=15)
        ok(f'{name}: picker prints cancelled changes=none')
        s.sendline('exit'); s.expect(pexpect.EOF, timeout=15)
        check(f'{name}: 8 GiB disk untouched (first MiB and sample)', hashes(disks) == before)
    finally:
        vm.stop()
    for p, _ in disks:
        os.remove(p)


def pump(vm, secs):
    """Keeps the serial output read while the screen changes (the serial buffer must not fill up)."""
    vm.child.expect([pexpect.TIMEOUT, pexpect.EOF], timeout=secs)


def vga_key(vm, key):
    """One key into the VGA console through the QEMU monitor (sendkey)."""
    m = pexpect.spawn('socat', ['-', f'UNIX-CONNECT:{vm.mon}'], encoding='latin-1', timeout=10)
    m.sendline(f'sendkey {key}'); time.sleep(0.5); m.close()


def vga_dump(vm, path):
    """QEMU screendump to path; returns once the file has its final size (fast enough to catch a 4 s gauge phase)."""
    m = pexpect.spawn('socat', ['-', f'UNIX-CONNECT:{vm.mon}'], encoding='latin-1', timeout=10)
    m.sendline(f'screendump {path}')
    end = time.time() + 5; last = -1
    while time.time() < end:
        time.sleep(0.1)
        if os.path.exists(path):
            size = os.path.getsize(path)
            if size > 1000 and size == last:
                break
            last = size
    m.close()


def colour_fraction(cnt, n, targets, tol=12):
    """Share of the n pixels whose every channel is within tol of one target colour (cnt: colour -> pixel count).
    The GRUB gfxterm framebuffer of the ISO is 8-bit VGA: the blue measured as (0,0,170), grey (170,170,170)."""
    return sum(k for col, k in cnt.items()
               if any(all(abs(c - t) <= tol for c, t in zip(col, tg)) for tg in targets)) / n


def screen_shot(vm, work):
    """Screendump of the VGA screen: (PIL image, blue root fraction, grey dialog fraction, OCR text), or None."""
    from PIL import Image
    ppm = os.path.join(work, 'screen-poll.ppm')
    if os.path.exists(ppm):
        os.remove(ppm)
    vga_dump(vm, ppm)
    if not os.path.exists(ppm) or os.path.getsize(ppm) < 1000:
        return None
    img = Image.open(ppm).convert('RGB'); os.remove(ppm)
    n = img.width * img.height
    cnt = {col: k for k, col in img.getcolors(maxcolors=n)}
    blue = colour_fraction(cnt, n, [(0, 0, 170), (0, 0, 168)])          # the whiptail root (VGA blue)
    grey = colour_fraction(cnt, n, [(170, 170, 170), (168, 168, 168)])  # the dialog (VGA light grey)
    ocr_png = os.path.join(work, 'screen-ocr.png')
    crop = img.crop((0, 60, img.width, 340))      # the dialog rows; OCR of the full frame misses the gauge text
    crop.resize((crop.width * 3, crop.height * 3), Image.LANCZOS).save(ocr_png)
    text = subprocess.run(['tesseract', ocr_png, 'stdout', '--psm', '6'], capture_output=True, text=True, timeout=120).stdout
    os.remove(ocr_png)
    return img, blue, grey, text


def screen_wait(vm, work, pattern, timeout, step):
    """Polls the screen every `step` seconds until the OCR text matches pattern; returns the shot or None.
    The last frame seen is kept in screen_wait.last (for the failure report)."""
    t0 = time.time(); screen_wait.last = None
    while time.time() - t0 < timeout:
        pump(vm, step)
        r = screen_shot(vm, work)
        if r:
            screen_wait.last = r
        if r and re.search(pattern, r[3]):
            return r
    return None


def screen_step(vm, work, tag, pattern, timeout, step, what):
    """Waits for one whiptail screen, saves it as work/screen-TAG.png and checks the blue root with the grey dialog."""
    r = screen_wait(vm, work, pattern, timeout, step)
    if r is None:
        bad(f'screen: {tag}: {what} not on the screen within {timeout}s')
        last = screen_wait.last
        if last is not None:
            last[0].save(os.path.join(work, f'screen-{tag}-timeout.png'))
            print(f'last OCR text of screen: {tag}:\n{last[3]}', flush=True)
        return None
    img, blue, grey, _ = r
    img.save(os.path.join(work, f'screen-{tag}.png'))
    ok(f'screen: {tag}: {what}')
    check(f'screen: {tag}: framebuffer is 640x480 (actual {img.width}x{img.height})', img.size == (640, 480))
    check(f'screen: {tag}: blue root and grey dialog (blue {blue:.0%}, grey {grey:.0%})', blue > 0.2 and grey > 0.03)
    return r


def scenario_screen(work, flash):
    """Default (tty1) entry on the VGA, two disks (24 GiB, 8 GiB below the minimum): the whiptail screens driven
    through the QEMU monitor, a screenshot of each step, then the written disk is checked."""
    print('=== screen', flush=True)
    disks = [new_disk(work, 'screen', 0, 24, 'virtio'), new_disk(work, 'screen', 1, 8, 'virtio')]
    before = hashes(disks)
    vm = VM(work, 'screen', 'bios', disks, iso=work_iso, fwd=[(2280, 22)])
    vm.start('install')
    try:
        screen_step(vm, work, '1-menu', r'Install UniTotem|Remote install', 300, 20, 'console menu')
        vga_key(vm, 'ret')                                              # Install UniTotem
        screen_step(vm, work, '2-disks', r'Select the disk', 180, 5, 'disk menu with the too small disk')
        vga_key(vm, 'down'); vga_key(vm, 'ret')                         # /dev/vdb, 8 GiB
        r = screen_step(vm, work, '3-toosmall', r'too small', 30, 3, 'message naming the minimum')
        if r is not None:
            check('screen: 3-toosmall names the minimum', re.search(r'Minimum', r[3]) is not None)
        vga_key(vm, 'ret'); pump(vm, 2)                                 # closes the message, the picker starts over
        vga_key(vm, 'ret')                                              # /dev/vda, 24 GiB
        # OCR reads the 'v' of /dev/vda as 'u' in some frames: the disk name is checked by the written disk below
        screen_step(vm, work, '4-confirm', r'Erase /dev/\w+ and install', 30, 3, 'confirmation, default No')
        vga_key(vm, 'tab'); pump(vm, 1); vga_key(vm, 'ret')             # Yes
        # the gauge phases last seconds here (check ~4 s, write ~10 s): polled every second, not every 20 s
        screen_step(vm, work, '5-gauge-check', r'Checking', 120, 1, 'gauge: checking the media')
        screen_step(vm, work, '6-gauge-write', r'Writing', 900, 1, 'gauge: writing')
        screen_step(vm, work, '7-result', r'installed on', 1800, 5, 'result message')
        vga_key(vm, 'ret'); pump(vm, 2)                                 # closes the message
        screen_step(vm, work, '8-finish', r'Installation finished', 60, 3, 'restart / power-off menu')
    finally:
        vm.stop()
    verify_written('screen', 'bios', flash, disks, disks[0][0], before, others=[disks[1][0]])
    for p, _ in disks:
        os.remove(p)


def main():
    global work_iso, BOOT_TIMEOUT
    ap = argparse.ArgumentParser()
    ap.add_argument('iso'); ap.add_argument('flash')
    ap.add_argument('--scenarios', default='bios,uefi,multi,sb,screen,small')
    ap.add_argument('--work', default='work/installer-iso-test')
    ap.add_argument('--boot-timeout', type=int, default=900, help='seconds to wait for the web interface of the installed disk')
    a = ap.parse_args()
    BOOT_TIMEOUT = a.boot_timeout
    work_iso = os.path.abspath(a.iso); flash = os.path.abspath(a.flash)
    os.makedirs(a.work, exist_ok=True); work = os.path.abspath(a.work)
    atexit.register(cleanup_disks)
    for s in a.scenarios.split(','):
        if s == 'bios': scenario_console(work, flash, 'bios', 'bios', 2200)
        elif s == 'uefi': scenario_uefi_usb(work, flash, 'uefi', 2210)
        elif s == 'multi': scenario_multi(work, flash, 'multi', 2220)
        elif s == 'sb': scenario_console(work, flash, 'sb', 'sb', 2230)
        elif s == 'screen': scenario_screen(work, flash)
        elif s == 'small': scenario_small(work, flash, 'small', 2240)
        else: sys.exit(f'unknown scenario {s}')
    print(f'{sum(1 for r in RESULTS if r[0])} passed, {sum(1 for r in RESULTS if not r[0])} failed')
    sys.exit(1 if any(not r[0] for r in RESULTS) else 0)


if __name__ == '__main__':
    main()
