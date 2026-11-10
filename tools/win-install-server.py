#!/usr/bin/env python3
# Serves the UniTotem Windows installer: bootstrap text, payload zip, inventory
# intake, operator approval. A PC runs: irm http://HOST:PORT|iex

import argparse
import hashlib
import ipaddress
import json
import math
import os
import random
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_PAYLOAD = os.path.join(REPO, 'work', 'windows-installer', 'unitotem-windows-installer.zip')
TEMPLATE = os.path.join(HERE, 'windows-installer', 'bootstrap.ps1.tmpl')

ZIP_DIR = 'unitotem-windows-installer/'
ENGINE_ENTRY = ZIP_DIR + 'Install-UniTotem.ps1'
SUMS_ENTRY = ZIP_DIR + 'payload/SHA256SUMS'

PLACEHOLDERS = ('SERVER', 'SHA256', 'BYTES', 'TIMEOUT', 'POLL', 'ENGINE')
PLACEHOLDER_RE = re.compile(r'@(SERVER|SHA256|BYTES|TIMEOUT|POLL|ENGINE)@')
MACHINE_RE = re.compile(r'[A-Za-z0-9-]{8,64}')
HOST_RE = re.compile(r'[A-Za-z0-9-]{1,15}')
# Characters of a log line printed whole (steps, error ids, statements, messages).
LOG_LIMIT = 4000

# Operator answer that approves: exactly this word, asked twice.
YES = 'yes'

# Partition types as reported by Get-Partition (.Type) and Win32_DiskPartition (.Type), shown with a clearer label.
TYPE_LABELS = {
    'IFS': 'NTFS/exFAT (IFS)',
    'Installable File System': 'NTFS/exFAT (IFS)',
    'Basic': 'Basic data',
    'System': 'EFI System',
    'Reserved': 'Microsoft reserved',
    'Recovery': 'Recovery',
    'Unknown': 'Unknown',
}

# Host-name colours (256-colour codes): readable on dark and light terminals; no black, white, green or yellow.
PALETTE = (33, 69, 99, 135, 141, 167, 171, 177, 203, 208)
GREEN = '\x1b[32m'
YELLOW = '\x1b[1;33m'  # the questions
RESET = '\x1b[0m'
KEY_RE = re.compile(r'ssh-ed25519 [A-Za-z0-9+/]{68}( [ -~]{0,128})?')
DRIVE_RE = re.compile(r'[A-Za-z]')
LETTER_RE = re.compile(r'[A-Za-z]?')
RANGE_RE = re.compile(r'bytes=([0-9]{1,15})-')
CONTENT_LENGTH_RE = re.compile(r'[0-9]{1,9}')

MAX_BODY = 262144
MAX_DISKS = 64
MAX_PARTS = 64
CHUNK = 1 << 20
SOCKET_TIMEOUT = 30
POLL_SECONDS = 5
RATE_LIMIT = 50
INV_KEYS = ('machine', 'hostname', 'ips', 'firmware', 'secureboot', 'bitlocker',
            'boot_free_mb', 'system_disk', 'os', 'disks', 'ui_culture', 'services',
            'model', 'cpu', 'ram', 'plan', 'notes')
DISK_KEYS = ('number', 'model', 'size_gb', 'style', 'serial', 'unique_id', 'bus',
             'system', 'partitions')
PART_KEYS = ('number', 'letter', 'size_mb', 'type', 'free_mb')
STATUS_KEYS = ('machine', 'level', 'text')


class Invalid(ValueError):
    pass


# Control characters (C0, DEL, C1: includes ESC) and bidirectional overrides: never reach the terminal.
_UNSAFE = re.compile('[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]')


def clean(value, limit=80):
    # Unicode text is kept; control characters are removed; a cut is never silent.
    text = _UNSAFE.sub('', str(value))
    if len(text) > limit:
        return '%s\u2026[truncated %d]' % (text[:limit], len(text) - limit)
    return text


MBR_TYPES = {
    0x05: 'Extended', 0x07: 'NTFS/exFAT (IFS)', 0x0B: 'FAT32', 0x0C: 'FAT32 LBA', 0x0E: 'FAT16 LBA',
    0x0F: 'Extended LBA', 0x27: 'Recovery', 0x82: 'Linux swap', 0x83: 'Linux', 0xEE: 'GPT protective',
    0xEF: 'EFI System',
}
MBR_RE = re.compile(r'MBR 0x([0-9A-F]{2})( active)?')


def type_label(raw):
    raw = clean(raw, 64)
    m = MBR_RE.fullmatch(raw)
    if m is not None:
        code = int(m.group(1), 16)
        label = MBR_TYPES.get(code, 'MBR type')
        return '%s (0x%02X)%s' % (label, code, ', active' if m.group(2) else '')
    label = TYPE_LABELS.get(raw)
    return raw if label is None else '%s (%s)' % (label, raw)


def use_color():
    return sys.stdout.isatty() and not os.environ.get('NO_COLOR')


def _req(cond, what):
    if not cond:
        raise Invalid(what)


def _obj(value, keys, what):
    _req(isinstance(value, dict) and set(value) == set(keys), what)
    return value


def _str(value, maxlen, pattern=None, what='string'):
    # Room for the truncation marker the client appends when it cuts a field.
    _req(isinstance(value, str) and len(value) <= maxlen + (32 if pattern is None else 0), what)
    if pattern is not None:
        _req(pattern.fullmatch(value) is not None, what)
    return value


def _int(value, lo, hi, what):
    _req(type(value) is int and lo <= value <= hi, what)
    return value


def _num(value, lo, hi, what):
    _req(type(value) in (int, float) and math.isfinite(value) and lo <= value <= hi, what)
    return float(value)


def _bool(value, what):
    _req(type(value) is bool, what)
    return value


def _list(value, maxlen, what):
    _req(isinstance(value, list) and len(value) <= maxlen, what)
    return value


def _enum(value, options, what):
    _req(isinstance(value, str) and value in options, what)
    return value


def _ip(value):
    _str(value, 45, None, 'ip')
    try:
        ipaddress.ip_address(value)
    except ValueError:
        raise Invalid('ip')
    return value


def parse_inventory(data):
    _obj(data, INV_KEYS, 'inventory keys')
    machine = _str(data['machine'], 64, MACHINE_RE, 'machine')
    hostname = _str(data['hostname'], 15, HOST_RE, 'hostname')
    ips = [_ip(x) for x in _list(data['ips'], 64, 'ips')]
    firmware = _enum(data['firmware'], ('uefi', 'bios'), 'firmware')
    secureboot = _enum(data['secureboot'], ('on', 'off', 'unknown', 'na'), 'secureboot')
    bitlocker = []
    for item in _list(data['bitlocker'], 26, 'bitlocker'):
        _obj(item, ('drive', 'status'), 'bitlocker entry')
        bitlocker.append({
            'drive': _str(item['drive'], 1, DRIVE_RE, 'drive'),
            'status': _str(item['status'], 64, None, 'status'),
        })
    boot_free = data['boot_free_mb']
    if boot_free is not None:
        boot_free = _int(boot_free, 0, 10 ** 9, 'boot_free_mb')
    system_disk = _int(data['system_disk'], 0, 9999, 'system_disk')
    os_name = _str(data['os'], 200, None, 'os')
    ui_culture = _str(data['ui_culture'], 20, None, 'ui_culture')
    model = _str(data['model'], 120, None, 'model')
    cpu = _str(data['cpu'], 120, None, 'cpu')
    ram = _str(data['ram'], 120, None, 'ram')
    _obj(data['plan'], ('where', 'reason'), 'plan')
    plan = {'where': _enum(data['plan']['where'], ('boot', 'cdrive', 'new', 'none'), 'plan where'),
            'reason': _str(data['plan']['reason'], 400, None, 'plan reason')}
    notes = [_str(x, 400, None, 'note') for x in _list(data['notes'], 8, 'notes')]
    services = []
    for item in _list(data['services'], 16, 'services'):
        _obj(item, ('name', 'status'), 'service entry')
        services.append({'name': _str(item['name'], 32, None, 'service name'),
                         'status': _str(item['status'], 20, None, 'service status')})
    disks = []
    numbers = set()
    for d in _list(data['disks'], MAX_DISKS, 'disks'):
        _obj(d, DISK_KEYS, 'disk entry')
        number = _int(d['number'], 0, 9999, 'disk number')
        _req(number not in numbers, 'duplicate disk number')
        numbers.add(number)
        parts = []
        for p in _list(d['partitions'], MAX_PARTS, 'partitions'):
            _obj(p, PART_KEYS, 'partition entry')
            parts.append({
                'number': _int(p['number'], 0, 9999, 'partition number'),
                'letter': _str(p['letter'], 1, LETTER_RE, 'letter'),
                'size_mb': _num(p['size_mb'], 0, 1e9, 'size_mb'),
                'type': _str(p['type'], 64, None, 'partition type'),
                'free_mb': None if p['free_mb'] is None else _int(p['free_mb'], 0, 10 ** 9, 'free_mb'),
            })
        disks.append({
            'number': number,
            'model': _str(d['model'], 200, None, 'model'),
            'size_gb': _num(d['size_gb'], 0, 1e7, 'size_gb'),
            'style': _str(d['style'], 32, None, 'style'),
            'serial': _str(d['serial'], 128, None, 'serial').strip(),
            'unique_id': _str(d['unique_id'], 256, None, 'unique_id'),
            'bus': _str(d['bus'], 32, None, 'bus'),
            'system': _bool(d['system'], 'system'),
            'partitions': parts,
        })
    matches = [d for d in disks if d['number'] == system_disk]
    _req(len(matches) == 1 and matches[0]['system'], 'system_disk does not name a system disk')
    sysd = matches[0]
    return {
        'machine': machine,
        'hostname': hostname,
        'ips': ips,
        'firmware': firmware,
        'secureboot': secureboot,
        'bitlocker': bitlocker,
        'boot_free_mb': boot_free,
        'system_disk': system_disk,
        'os': os_name,
        'ui_culture': ui_culture,
        'model': model,
        'cpu': cpu,
        'ram': ram,
        'plan': plan,
        'notes': notes,
        'services': services,
        'disks': disks,
    }


def parse_status(data):
    _obj(data, STATUS_KEYS, 'status keys')
    return {
        'machine': _str(data['machine'], 64, MACHINE_RE, 'machine'),
        'level': _enum(data['level'], ('info', 'ok', 'error'), 'level'),
        'text': _str(data['text'], 20000, None, 'text'),
    }


def render_block(rec):
    sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
    lines = [
        '',
        '=== PC waiting for approval ===',
        'Hostname:    ' + clean(rec['hostname'], 15),
        'Machine:     ' + clean(rec['machine'], 64),
        'Client IP:   ' + clean(rec['client_ip'], 45),
        'Addresses:   ' + (clean(', '.join(rec['ips'])) or 'none'),
        'OS:          ' + clean(rec['os']),
        'Model:       ' + clean(rec['model'], 120),
        'CPU:         ' + clean(rec['cpu'], 120),
        'RAM:         ' + clean(rec['ram'], 120),
        'UI language: ' + clean(rec['ui_culture'], 20),
        'Storage svc: ' + (', '.join(clean(x['name'], 32) + '=' + clean(x['status'], 20) for x in rec['services']) or 'none'),
        'Firmware:    ' + clean(rec['firmware'], 10),
        'Secure Boot: ' + ('n/a (legacy BIOS)' if rec['secureboot'] == 'na' else clean(rec['secureboot'], 10)),
        'BitLocker:   ' + (', '.join(clean(b['drive'], 1) + ': ' + clean(b['status'])
                                     for b in rec['bitlocker']) or 'none'),
        'Boot free:   ' + (str(rec['boot_free_mb']) + ' MB' if rec['boot_free_mb'] is not None
                           else 'unknown'),
        'Disks:',
    ]
    for d in rec['disks']:
        mark = ' [SYSTEM]' if d is sysd else ''
        lines.append('  Disk %d%s: %s, %.1f GB, %s, serial %s, bus %s' % (
            d['number'], mark, clean(d['model']), d['size_gb'], clean(d['style'], 32),
            clean(d['serial']), clean(d['bus'], 32)))
        for p in d['partitions']:
            free = '' if p['free_mb'] is None else ', %d MB free' % p['free_mb']
            lines.append('    part %d  letter %s  %.0f MB%s  %s' % (
                p['number'], clean(p['letter'] or '-', 1), p['size_mb'], free, type_label(p['type'])))
    lines.append('Plan:        ' + clean(rec['plan']['where']) + ' - ' + clean(rec['plan']['reason'], 400))
    for note in rec['notes']:
        lines.append('Note:        ' + clean(note, 400))
    return '\n'.join(lines)


def disk_question(rec, text):
    sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
    return '%s: disk %d, %s, %.1f GB, serial %s. %s' % (
        clean(rec['hostname'], 15), sysd['number'], clean(sysd['model']), sysd['size_gb'], clean(sysd['serial']), text)


def check_payload(path):
    # Returns the engine text (Install-UniTotem.ps1) after validating the zip.
    if not zipfile.is_zipfile(path):
        raise ValueError('payload is not a zip file: ' + path)
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        for need in (ENGINE_ENTRY, SUMS_ENTRY):
            if need not in names:
                raise ValueError('payload lacks ' + need)
        raw = z.read(ENGINE_ENTRY)
    try:
        engine = raw.decode('ascii')
    except UnicodeDecodeError:
        raise ValueError('Install-UniTotem.ps1 is not ASCII')
    for line in engine.splitlines():
        if line.startswith("'@"):
            raise ValueError("Install-UniTotem.ps1 has a line starting with '@")
    return engine


def read_key(path):
    # Returns the key line, or None when the key file is absent (open mode).
    if not os.path.lexists(path):
        return None
    with open(path, 'rb') as f:
        data = f.read(4097)
    if len(data) > 4096:
        raise ValueError('authorized key file is too large')
    try:
        text = data.decode('ascii')
    except UnicodeDecodeError:
        raise ValueError('authorized key file is not ASCII')
    lines = text.splitlines()
    if len(lines) != 1 or not KEY_RE.fullmatch(lines[0]):
        raise ValueError('authorized key file must hold exactly one ssh-ed25519 line')
    return lines[0]


HOST_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:-]*')


def deploy_key_path(host):
    # Same per-target key location as ota_key_path in deploy/lib.sh.
    if HOST_RE.fullmatch(host) is None:
        raise ValueError('invalid host for the OTA key')
    base = os.environ.get('XDG_STATE_HOME') or os.path.join(os.path.expanduser('~'), '.local', 'state')
    return os.path.join(base, 'unitotem-deploy', host.replace(':', '_'), 'id_ed25519')


def ensure_machine_key(host):
    # Creates the per-target key when missing (like ota_key_ensure); returns (private path, public line).
    key = deploy_key_path(host)
    d = os.path.dirname(key)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    if not os.path.isfile(key):
        env = {k: v for k, v in os.environ.items() if k not in ('DISPLAY', 'SSH_ASKPASS')}
        env['SSH_ASKPASS_REQUIRE'] = 'never'
        old = os.umask(0o077)
        try:
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'unitotem-deploy', '-f', key],
                           stdin=subprocess.DEVNULL, check=True, env=env, timeout=30)
        finally:
            os.umask(old)
    if not os.path.isfile(key + '.pub'):
        old = os.umask(0o077)
        try:
            out = subprocess.run(['ssh-keygen', '-y', '-f', key], stdin=subprocess.DEVNULL, check=True,
                                 capture_output=True, timeout=30).stdout
        finally:
            os.umask(old)
        with open(key + '.pub', 'wb') as f:
            f.write(out)
    os.chmod(key, 0o600)
    line = read_key(key + '.pub')
    return key, line


def file_digest(path):
    h = hashlib.sha256()
    size = 0
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(CHUNK), b''):
            h.update(chunk)
            size += len(chunk)
    return size, h.hexdigest()


def load_template(path):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    for name in PLACEHOLDERS:
        if '@' + name + '@' not in text:
            raise ValueError('bootstrap template lacks @' + name + '@')
    return text


def prepare_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def clean_approvals(path):
    # Words left over from an earlier run are not approvals for this run.
    for name in os.listdir(path):
        if name.startswith('.') or name.endswith('.word'):
            try:
                os.unlink(os.path.join(path, name))
            except OSError:
                pass


def read_word_file(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    except OSError:
        return None
    with os.fdopen(fd, 'rb') as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            return None
        data = f.read(256)
    return data.decode('ascii', 'replace').strip()


def _no_dupes(pairs):
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys):
        raise ValueError('duplicate key')
    return dict(pairs)


def _reject_const(name):
    raise ValueError('constant ' + name)


class Context:
    def __init__(self, payload, state_dir, key_path, timeout_minutes, template=TEMPLATE,
                 out=None, clock=time.monotonic, poll_interval=1.0, keep_approvals=False):
        self.state_dir = prepare_dir(os.path.abspath(state_dir))
        self.machines_dir = prepare_dir(os.path.join(self.state_dir, 'machines'))
        self.keep_approvals = keep_approvals
        self.raw = {}
        self.approvals_dir = prepare_dir(os.path.join(self.state_dir, 'approvals'))
        self.lock = threading.Lock()
        self.out_lock = threading.Lock()
        self.out_fn = out
        self.clock = clock
        self.poll_interval = poll_interval
        self.timeout_minutes = timeout_minutes
        self.template_text = load_template(template)
        self.inventories = {}
        self.approved = {}
        self.seen = set()
        self.rate = {}
        self.stop = threading.Event()
        payload = os.path.abspath(payload)
        self.engine_text = check_payload(payload)
        # Explicit shared key, or None: then every machine gets its own key (ensure_machine_key).
        self.key_path = key_path
        self.explicit_key = read_key(key_path) if key_path else None
        self.keys = {}
        self.colors = {}
        self.color = use_color()
        self.stage = 0
        self.last_machine = None
        self.served_path = payload
        self.size, self.sha = file_digest(self.served_path)
        clean_approvals(self.approvals_dir)
        self.load_state()

    def emit(self, text):
        with self.out_lock:
            if self.out_fn is not None:
                self.out_fn(text)
            else:
                print(text, flush=True)

    def close(self):
        self.stop.set()

    def render_bootstrap(self, server_url):
        values = {
            'SERVER': server_url,
            'SHA256': self.sha,
            'BYTES': str(self.size),
            'TIMEOUT': str(self.timeout_minutes),
            'POLL': str(POLL_SECONDS),
            'ENGINE': self.engine_text,
        }
        # One pass: substituted text is never scanned again.
        return PLACEHOLDER_RE.sub(lambda m: values[m.group(1)], self.template_text)

    def first_fetch(self, ip):
        with self.lock:
            if ip in self.seen:
                return False
            self.seen.add(ip)
            return True

    def rate_ok(self, ip):
        now = self.clock()
        with self.lock:
            if len(self.rate) > 4096:
                self.rate.clear()
            q = self.rate.setdefault(ip, deque())
            while q and now - q[0] >= 1.0:
                q.popleft()
            if len(q) >= RATE_LIMIT:
                return False
            q.append(now)
            return True

    # State files (no private keys, no payload): one JSON per machine, written atomically, mode 0600. Approvals are
    # not restored after a restart unless --keep-approvals.
    def save_machine(self, machine):
        with self.lock:
            doc = {'inventory': self.raw[machine], 'client_ip': self.inventories[machine]['client_ip'],
                   'approved': self.approved.get(machine) if self.keep_approvals else None}
        path = os.path.join(self.machines_dir, machine + '.json')
        tmp = os.path.join(self.machines_dir, '.tmp-' + secrets.token_hex(6))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(doc, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)

    def load_state(self):
        newest = (0.0, None)
        restored = 0
        for name in sorted(os.listdir(self.machines_dir)):
            if name.startswith('.') or not name.endswith('.json'):
                continue
            path = os.path.join(self.machines_dir, name)
            try:
                with open(path, encoding='utf-8') as f:
                    doc = json.load(f)
                rec = parse_inventory(doc['inventory'])
                ip = str(doc['client_ip'])
                ipaddress.ip_address(ip)
                rec['client_ip'] = ip
                if self.explicit_key is not None:
                    priv = self.key_path[:-4] if self.key_path.endswith('.pub') else None
                    line = self.explicit_key
                else:
                    priv, line = ensure_machine_key(ip)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                self.emit('ignored an unreadable state file: ' + clean(name, 80))
                continue
            m = rec['machine']
            self.inventories[m] = rec
            self.raw[m] = doc['inventory']
            self.keys[m] = {'priv': priv, 'line': line}
            ap = doc.get('approved')
            if self.keep_approvals and isinstance(ap, dict) and ap.get('disk') == rec['system_disk'] \
                    and ap.get('serial') == self.system_serial(rec):
                self.approved[m] = {'disk': ap['disk'], 'serial': ap['serial']}
            mtime = os.stat(path).st_mtime
            if rec['plan']['where'] != 'none' and mtime >= newest[0]:
                newest = (mtime, m)
            restored += 1
        self.last_machine = newest[1]
        if restored:
            self.emit('restored %d PC(s) from %s%s' % (restored, clean(self.machines_dir, 200),
                      '' if self.keep_approvals else '; approvals must be given again'))
            rec = self.inventories.get(newest[1]) if newest[1] else None
            if rec is not None and newest[1] not in self.approved:
                self.emit(self.ask(disk_question(rec, 'Erase this disk and install UniTotem? Type yes')))

    def add_inventory(self, data, client_ip):
        rec = parse_inventory(data)
        rec['client_ip'] = client_ip
        with self.lock:
            same = self.raw.get(rec['machine']) == data and \
                self.inventories[rec['machine']]['client_ip'] == client_ip
        if same:
            return self.inventories[rec['machine']]  # idempotent: nothing changes, no new question
        if self.explicit_key is not None:
            priv = self.key_path[:-4] if self.key_path.endswith('.pub') else None
            line = self.explicit_key
        else:
            priv, line = ensure_machine_key(client_ip)
        with self.lock:
            self.inventories[rec['machine']] = rec
            self.keys[rec['machine']] = {'priv': priv, 'line': line}
            self.raw[rec['machine']] = data
            self.approved.pop(rec['machine'], None)
            self.last_machine = rec['machine'] if rec['plan']['where'] != 'none' else None
            self.stage = 0
        self.save_machine(rec['machine'])
        self.emit(render_block(rec))
        if rec['plan']['where'] == 'none':
            self.emit(self.ask('Cannot install on this PC: ' + clean(rec['plan']['reason'], 400)))
        else:
            self.emit(self.ask(disk_question(rec, 'Erase this disk and install UniTotem? Type yes')))
        return rec

    def get_key(self, machine):
        # Public key line, only for a machine whose approval is valid.
        with self.lock:
            ok = self.get_approval_locked(machine)
            k = self.keys.get(machine)
        return k['line'] if (ok and k) else None

    def next_command(self, machine):
        with self.lock:
            rec = self.inventories.get(machine)
            k = self.keys.get(machine)
        if not rec or not k:
            return ''
        return 'OTA_FALLBACK_KEY=%s deploy/remote-deploy.sh recover %s --parts DIR --yes' % (
            k['priv'] or '<private key>', rec['client_ip'])

    def add_status(self, data):
        st = parse_status(data)
        with self.lock:
            rec = self.inventories.get(st['machine'])
        name = rec['hostname'] if rec else st['machine']
        # Errors are printed whole: the step, the failing statement and the error id are needed remotely.
        limit = LOG_LIMIT
        self.emit(self.host_tag(name) + ' ' + clean(st['text'], limit))

    def get_approval_locked(self, machine):
        rec = self.inventories.get(machine)
        ap = self.approved.get(machine)
        return bool(rec and ap and ap['disk'] == rec['system_disk'] and ap['serial'] == self.system_serial(rec))

    @staticmethod
    def system_serial(rec):
        return [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]['serial']

    def get_approval(self, machine):
        with self.lock:
            if self.get_approval_locked(machine):
                ap = self.approved[machine]
                return {'state': 'approved', 'machine': machine, 'disk': ap['disk'], 'serial': ap['serial']}
            if machine not in self.inventories:
                return {'state': 'unknown'}  # the client sends its inventory again
        return {'state': 'wait'}

    def ask(self, text):
        # Questions to the operator in yellow (same rules as the host colours).
        return YELLOW + text + RESET if self.color else text

    def host_tag(self, name):
        # "(host)" with a stable random colour per host name (in memory only); plain without a terminal.
        name = clean(name, 15)
        tag = '(' + name + ')'
        if not self.color:
            return tag
        with self.lock:
            code = self.colors.get(name)
            if code is None:
                free = [c for c in PALETTE if c not in self.colors.values()] or list(PALETTE)
                code = random.choice(free)
                self.colors[name] = code
        return '\x1b[38;5;%dm%s%s' % (code, tag, RESET)

    def apply_answer(self, text, source):
        # The operator answers `yes` twice for the PC that reported last; anything else cancels.
        text = text.strip()
        approved = None
        with self.lock:
            machine = self.last_machine
            rec = self.inventories.get(machine) if machine else None
            if rec is None:
                msg = 'no PC is waiting'
            elif text != YES:
                self.stage = 0
                msg = 'cancelled: nothing was changed'
            elif self.stage == 0:
                self.stage = 1
                msg = self.ask(disk_question(rec, 'Last chance: erase this disk? Type yes'))
            else:
                self.stage = 0
                sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
                self.approved[machine] = {'disk': sysd['number'], 'serial': sysd['serial']}
                msg = 'approved: ' + self.host_tag(rec['hostname']) + ' disk ' + str(sysd['number'])
                approved = machine
        if approved is not None and self.keep_approvals:
            self.save_machine(approved)
        self.emit(msg)
        if approved is not None:
            self.emit('When the PC shows its address in the OTA environment, run: ' + self.next_command(approved))

    def poll_approvals_once(self):
        for name in sorted(os.listdir(self.approvals_dir)):
            if name.startswith('.') or not name.endswith('.word'):
                continue
            path = os.path.join(self.approvals_dir, name)
            word = read_word_file(path)
            try:
                os.unlink(path)
            except OSError:
                pass
            if word is not None:
                self.apply_answer(word, 'file')

    def _poll_loop(self):
        while not self.stop.wait(self.poll_interval):
            try:
                self.poll_approvals_once()
            except OSError as e:
                self.emit('approvals directory error: ' + clean(e.strerror or 'error'))

    def _stdin_loop(self, stream):
        for line in stream:
            if self.stop.is_set():
                break
            if line.strip():
                self.apply_answer(line, 'stdin')

    def start_background(self, stdin_stream=None):
        threading.Thread(target=self._poll_loop, daemon=True).start()
        if stdin_stream is not None:
            threading.Thread(target=self._stdin_loop, args=(stdin_stream,), daemon=True).start()

    def render_bootstrap_for(self, ip, port):
        host = '[' + ip + ']' if ':' in ip else ip
        return self.render_bootstrap('http://' + host + ':' + str(port))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'unitotem-winserver'
    sys_version = ''
    timeout = SOCKET_TIMEOUT

    def log_message(self, fmt, *args):
        return

    @property
    def ctx(self):
        return self.server.ctx

    def send_body(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if code >= 400:
            self.close_connection = True
            self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, obj):
        self.send_body(code, json.dumps(obj).encode('ascii'), 'application/json')

    def fail(self, code, msg):
        self.send_body(code, (msg + '\n').encode('ascii'), 'text/plain; charset=utf-8')

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/':
            self.send_bootstrap()
        elif url.path == '/payload.zip':
            self.send_payload()
        elif url.path == '/approval':
            self.send_approval(url.query)
        elif url.path == '/key':
            self.send_key(url.query)
        else:
            self.fail(404, 'not found')

    def do_POST(self):
        path = urlsplit(self.path).path
        if path not in ('/inventory', '/status'):
            self.fail(404, 'not found')
            return
        if path == '/status' and not self.ctx.rate_ok(self.client_address[0]):
            self.fail(429, 'too many requests')
            return
        data = self.read_json()
        if data is None:
            return
        try:
            if path == '/inventory':
                self.ctx.add_inventory(data, self.client_address[0])
            else:
                self.ctx.add_status(data)
        except Invalid as e:
            self.fail(400, 'invalid ' + str(e))
            return
        self.send_json(200, {'ok': True})

    def read_json(self):
        ctype = (self.headers.get('Content-Type') or '').split(';')[0].strip().lower()
        if ctype != 'application/json':
            self.fail(415, 'expected application/json')
            return None
        raw = self.headers.get('Content-Length')
        if raw is None or CONTENT_LENGTH_RE.fullmatch(raw.strip()) is None:
            self.fail(411 if raw is None else 400, 'Content-Length required')
            return None
        length = int(raw)
        if length > MAX_BODY:
            self.fail(413, 'body too large')
            return None
        body = self.rfile.read(length)
        if len(body) != length:
            self.fail(400, 'short body')
            return None
        try:
            return json.loads(body.decode('utf-8', 'replace'), object_pairs_hook=_no_dupes,
                              parse_constant=_reject_const)
        except (ValueError, RecursionError):
            self.fail(400, 'invalid json')
            return None

    def send_bootstrap(self):
        ip = self.connection.getsockname()[0]
        body = self.ctx.render_bootstrap_for(ip, self.server.server_port).encode('utf-8')
        client = self.client_address[0]
        if self.ctx.first_fetch(client):
            self.ctx.emit('client ' + clean(client, 45) + ' fetched the bootstrap')
        self.send_body(200, body, 'text/plain; charset=utf-8')

    def send_payload(self):
        size = self.ctx.size
        start = 0
        code = 200
        extra = {'Accept-Ranges': 'bytes'}
        rng = self.headers.get('Range')
        if rng is not None:
            m = RANGE_RE.fullmatch(rng.strip())
            if m is not None:
                start = int(m.group(1))
                if start >= size:
                    self.send_body(416, b'', 'text/plain', {'Content-Range': 'bytes */%d' % size})
                    return
                code = 206
                extra['Content-Range'] = 'bytes %d-%d/%d' % (start, size - 1, size)
        self.send_response(code)
        self.send_header('Content-Type', 'application/zip')
        self.send_header('Content-Length', str(size - start))
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        remaining = size - start
        try:
            with open(self.ctx.served_path, 'rb') as f:
                f.seek(start)
                while remaining > 0:
                    chunk = f.read(min(CHUNK, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def send_key(self, query):
        values = parse_qs(query, keep_blank_values=True).get('machine', [])
        if len(values) != 1 or MACHINE_RE.fullmatch(values[0]) is None:
            self.fail(400, 'bad machine id')
            return
        line = self.ctx.get_key(values[0])
        if line is None:
            self.fail(403, 'not approved')
            return
        self.send_body(200, (line + '\n').encode('ascii'), 'text/plain; charset=us-ascii')

    def send_approval(self, query):
        values = parse_qs(query, keep_blank_values=True).get('machine', [])
        if len(values) != 1 or MACHINE_RE.fullmatch(values[0]) is None:
            self.fail(400, 'bad machine id')
            return
        self.send_json(200, self.ctx.get_approval(values[0]))


class Server(ThreadingHTTPServer):
    daemon_threads = True


def make_server(bind, port, ctx):
    srv = Server((bind, port), Handler)
    srv.ctx = ctx
    return srv


def local_ipv4s():
    found = []
    try:
        out = subprocess.run(['ip', '-4', '-o', 'addr', 'show'], capture_output=True,
                             text=True, timeout=5, check=False).stdout
        found = re.findall(r'\binet (\d{1,3}(?:\.\d{1,3}){3})/', out)
    except (OSError, subprocess.SubprocessError):
        found = []
    if not found:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(('192.0.2.1', 9))  # UDP connect sends no packet
                found = [s.getsockname()[0]]
        except OSError:
            found = []
    addrs = []
    for a in found:
        if not a.startswith('127.') and a not in addrs:
            addrs.append(a)
    return addrs


def default_state_dir():
    base = os.environ.get('XDG_STATE_HOME') or os.path.expanduser('~/.local/state')
    return os.path.join(base, 'unitotem-winserver')


def ip_arg(value):
    try:
        ipaddress.ip_address(value)
    except ValueError:
        raise argparse.ArgumentTypeError('not an IP address: ' + value)
    return value


def int_arg(lo, hi):
    def parse(value):
        try:
            n = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError('not a number')
        if not lo <= n <= hi:
            raise argparse.ArgumentTypeError('must be %d..%d' % (lo, hi))
        return n
    return parse


def write_approval(approvals_dir, word):
    tmp = os.path.join(approvals_dir, '.tmp-' + secrets.token_hex(8))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write((word + '\n').encode('ascii'))
        f.flush()
        os.fsync(f.fileno())
    final = os.path.join(approvals_dir, '%020d-%s.word' % (time.time_ns(), secrets.token_hex(4)))
    os.replace(tmp, final)


def parse_args(argv):
    p = argparse.ArgumentParser(description='Serve the UniTotem Windows installer.')
    p.add_argument('--bind', default='0.0.0.0', type=ip_arg)
    p.add_argument('--port', type=int_arg(1, 65535), default=8000)
    p.add_argument('--advertise', type=ip_arg, default=None)
    p.add_argument('--payload', default=DEFAULT_PAYLOAD)
    p.add_argument('--authorized-key', default=None, metavar='FILE')
    p.add_argument('--keep-approvals', action='store_true',
                   help='restore approvals after a restart (default: they must be given again)')
    p.add_argument('--timeout-minutes', type=int_arg(1, 1440), default=60)
    p.add_argument('--state-dir', default=default_state_dir())
    p.add_argument('--approve', metavar='yes', action='append', default=None,
                   help='answer for the PC that reported last; give it twice: --approve yes --approve yes')
    return p.parse_args(argv)


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    args = parse_args(argv)
    if args.approve is not None:
        if args.approve != [YES, YES]:
            print('use exactly: --approve yes --approve yes', file=sys.stderr)
            return 2
        approvals = prepare_dir(os.path.join(prepare_dir(os.path.abspath(args.state_dir)), 'approvals'))
        for _ in range(2):
            write_approval(approvals, YES)
        print('approval queued: the running server takes it within one second')
        return 0

    try:
        ctx = Context(args.payload, args.state_dir, args.authorized_key, args.timeout_minutes,
                      keep_approvals=args.keep_approvals)
    except (OSError, ValueError) as e:
        print('error: ' + str(e), file=sys.stderr)
        return 2

    addrs = [args.advertise] if args.advertise else local_ipv4s()
    for a in addrs:
        print('irm http://%s:%d|iex' % (a, args.port))
    if not addrs:
        print('no IPv4 address found: use --advertise IP')
    print('Win+R -> powershell -> Ctrl+Shift+Enter')
    print('then paste the irm line')

    try:
        server = make_server(args.bind, args.port, ctx)
    except OSError as e:
        ctx.close()
        print('error: cannot listen: ' + str(e), file=sys.stderr)
        return 2
    stdin_stream = sys.stdin if (sys.stdin is not None and sys.stdin.isatty()) else None
    ctx.start_background(stdin_stream)
    line = 'listening on %s:%d' % (args.bind, server.server_port)
    print(GREEN + line + RESET if use_color() else line, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('stopped')
    finally:
        server.server_close()
        ctx.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
