#!/usr/bin/env python3
# Serves the UniTotem Windows installer: bootstrap text, payload zip, inventory
# intake, operator approval. A PC runs: irm http://HOST:PORT|iex

import argparse
import hashlib
import ipaddress
import json
import logging
import math
import os
import random
import re
import secrets
import signal
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
REASON_RE = re.compile(r'[a-z0-9_=,.:-]{1,80}')
HOST_RE = re.compile(r'[A-Za-z0-9-]{1,15}')
# Characters of a log line printed whole (steps, error ids, statements, messages).
LOG_LIMIT = 4000

# Operator answers: y approves (asked twice), n cancels; nothing else is accepted.
YES = 'y'
APPROVE_FILE_RE = re.compile(r'approve(?: ([A-Za-z0-9-]{8,64}))?')
NO = 'n'
INVALID_ANSWER = 'Invalid answer, type y or n'
Q_FIRST = 'Erase this disk and install UniTotem? (y/n)'
Q_LAST = 'Last chance: erase this disk? (y/n)'

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
            'model', 'cpu', 'ram', 'plan', 'facts')
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
            'reason': _str(data['plan']['reason'], 80, REASON_RE, 'plan reason')}
    facts = [_str(x, 200, None, 'fact') for x in _list(data['facts'], 16, 'facts')]
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
        'facts': facts,
        'services': services,
        'disks': disks,
    }


def parse_status(data):
    _obj(data, STATUS_KEYS, 'status keys')
    return {
        'machine': _str(data['machine'], 64, MACHINE_RE, 'machine'),
        'level': _enum(data['level'], ('info', 'warn', 'error', 'done'), 'level'),
        'text': _str(data['text'], 20000, None, 'text'),
    }


def render_block(rec):
    # Summary of the PC: indented two spaces, no timestamp or level (log lines start in column 0).
    sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
    lines = [
        'hostname:     ' + clean(rec['hostname'], 15),
        'machine:      ' + clean(rec['machine'], 64),
        'client_ip:    ' + clean(rec['client_ip'], 45),
        'addresses:    ' + (clean(', '.join(rec['ips'])) or 'none'),
        'os:           ' + clean(rec['os']),
        'model:        ' + clean(rec['model'], 120),
        'cpu:          ' + clean(rec['cpu'], 120),
        'ram:          ' + clean(rec['ram'], 120),
        'ui_language:  ' + clean(rec['ui_culture'], 20),
        'storage_svc:  ' + (', '.join(clean(x['name'], 32) + '=' + clean(x['status'], 20) for x in rec['services']) or 'none'),
        'firmware:     ' + clean(rec['firmware'], 10),
        'secure_boot:  ' + ('n/a' if rec['secureboot'] == 'na' else clean(rec['secureboot'], 10)),
        'bitlocker:    ' + (', '.join(clean(b['drive'], 1) + ': ' + clean(b['status'])
                                      for b in rec['bitlocker']) or 'none'),
        'boot_free:    ' + (str(rec['boot_free_mb']) + ' MB' if rec['boot_free_mb'] is not None else 'unknown'),
        'disks:',
    ]
    for d in rec['disks']:
        mark = ' (system)' if d is sysd else ''
        lines.append('  disk %d%s: model=%s size=%.1fGB style=%s serial=%s bus=%s' % (
            d['number'], mark, clean(d['model']), d['size_gb'], clean(d['style'], 32),
            clean(d['serial']), clean(d['bus'], 32)))
        for p in d['partitions']:
            free = '' if p['free_mb'] is None else ' free=%dMB' % p['free_mb']
            lines.append('    part %d: letter=%s size=%.0fMB%s type=%s' % (
                p['number'], clean(p['letter'] or '-', 1), p['size_mb'], free, type_label(p['type'])))
    lines.append('plan:         destination=' + clean(rec['plan']['where']) + ' reason=' + clean(rec['plan']['reason'], 80))
    return '\n'.join('  ' + line for line in lines)


def disk_question(rec, text):
    sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
    return '(%s) disk=%d model=%s size=%.1fGB serial=%s: %s' % (
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


class Busy(Exception):
    pass


BUSY_MESSAGE = 'server busy: another PC is being installed'


class Terminal:
    # One print lock for every thread. While a question is pending on a terminal, a log line is printed above the
    # prompt and the prompt with what the operator already typed is drawn again below it.
    ERASE = '\r\x1b[2K'

    def __init__(self, stream=None, interactive=False):
        self.stream = stream or sys.stdout
        self.interactive = interactive
        self.lock = threading.RLock()  # shared with the logging handler
        self.prompt = None
        self.buf = ''

    def _write(self, text):
        self.stream.write(text)
        self.stream.flush()

    def log(self, text):
        with self.lock:
            if self.interactive and self.prompt is not None:
                self._write(self.ERASE + text + '\n' + self.prompt + self.buf)
            else:
                self._write(text + '\n')

    def set_prompt(self, prompt):
        with self.lock:
            if not self.interactive:
                if prompt is not None:
                    self._write(prompt + '\n')
                return
            if prompt is None:
                if self.prompt is not None:
                    self._write(self.ERASE)
                self.buf = ''
            else:
                self._write(self.ERASE + prompt + self.buf)
            self.prompt = prompt

    def key(self, ch):
        # One typed character; returns the finished line on Enter, else None. Without a prompt, input is ignored.
        with self.lock:
            if self.prompt is None:
                return None
            if ch in ('\r', '\n'):
                line = self.buf
                self._write(self.ERASE + self.prompt + line + '\n')
                self.buf = ''
                self.prompt = None
                return line
            if ch in ('\x7f', '\x08'):
                if self.buf:
                    self.buf = self.buf[:-1]
                    self._write(self.ERASE + self.prompt + self.buf)
            elif ch == '\x15':
                self.buf = ''
                self._write(self.ERASE + self.prompt)
            elif ' ' <= ch <= '~' and len(self.buf) < 32:
                self.buf += ch
                self._write(ch)
        return None


LOG_FORMAT = '%(asctime)s %(levelname)s (%(host)s) %(message)s'
LOG_DATEFMT = '%Y-%m-%d %H:%M:%S'
LOGGER = logging.getLogger('winserver')


class PromptHandler(logging.StreamHandler):
    # Prints a record above the pending prompt and draws the prompt (with the typed text) again below it, under the
    # lock the terminal reader uses.
    def __init__(self, term):
        super().__init__(term.stream)
        self.term = term
        self.lock = term.lock

    def emit(self, record):
        try:
            self.term.log(self.format(record))
        except Exception:
            self.handleError(record)


class HostColors:
    # Stable random colour per host name (256-colour code), kept in memory only.
    def __init__(self):
        self.codes = {}
        self.lock = threading.Lock()

    def name(self, name):
        name = clean(name, 15)
        with self.lock:
            code = self.codes.get(name)
            if code is None:
                free = [c for c in PALETTE if c not in self.codes.values()] or list(PALETTE)
                code = random.choice(free)
                self.codes[name] = code
        return '\x1b[38;5;%dm%s%s' % (code, name, RESET)


class HostFilter(logging.Filter):
    # Sets record.host: "server" or the PC name, in a stable random colour when the stream is a terminal.
    def __init__(self, colors, color=False):
        super().__init__()
        self.colors = colors
        self.color = color

    def filter(self, record):
        name = clean(getattr(record, 'host', None) or 'server', 15)
        record.host = self.colors.name(name) if self.color else name
        return True


def make_formatter():
    return logging.Formatter(LOG_FORMAT, datefmt=LOG_DATEFMT)


class Context:
    def __init__(self, payload, state_dir, key_path, timeout_minutes, template=TEMPLATE,
                 out=None, clock=time.monotonic, poll_interval=1.0, keep_approvals=False, term=None, colors=None):
        self.state_dir = prepare_dir(os.path.abspath(state_dir))
        self.machines_dir = prepare_dir(os.path.join(self.state_dir, 'machines'))
        self.keep_approvals = keep_approvals
        self.raw = {}
        self.approvals_dir = prepare_dir(os.path.join(self.state_dir, 'approvals'))
        self.lock = threading.Lock()
        self.term = term or Terminal(sys.stdout, sys.stdout.isatty() and sys.stdin is not None and sys.stdin.isatty())
        self.current_question = None
        self.wall = time.time
        self.active = None
        self.active_since = 0.0
        self.busy_logged = {}
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
        self.colors = colors or HostColors()
        self.color = use_color()
        self.stage = 0
        self.last_machine = None
        self.served_path = payload
        self.size, self.sha = file_digest(self.served_path)
        clean_approvals(self.approvals_dir)
        self.load_state()

    def emit(self, text, level=logging.INFO, host=None, raw=False):
        # Log records go through the logging module; raw lines (the PC summary, questions) are printed as they are.
        if raw:
            if self.out_fn is not None:
                self.out_fn(text)
            else:
                self.term.log(text)
        else:
            LOGGER.log(level, text, extra={'host': host or 'server'})

    def question(self, text):
        # The pending question: the prompt on a terminal, a log line otherwise (and in the tests).
        self.current_question = text
        if self.out_fn is not None:
            if text is not None:
                self.out_fn(self.ask(text))
        else:
            self.term.set_prompt(None if text is None else self.ask(text) + ' ')

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
                self.emit('state file ignored name=%s' % clean(name, 80), logging.WARNING)
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
        if newest[1] is not None and self.wall() - newest[0] <= self.timeout_minutes * 60:
            self.active = newest[1]
            self.active_since = newest[0]
        if restored:
            self.emit('state restored machines=%d approvals=%s' % (restored, 'kept' if self.keep_approvals else 'dropped'))
            rec = self.inventories.get(newest[1]) if newest[1] else None
            if rec is not None and newest[1] not in self.approved:
                self.question(disk_question(rec, Q_FIRST))

    def add_inventory(self, data, client_ip):
        rec = parse_inventory(data)
        rec['client_ip'] = client_ip
        self.check_machine(rec['machine'], client_ip)
        with self.lock:
            same = self.raw.get(rec['machine']) == data and \
                self.inventories[rec['machine']]['client_ip'] == client_ip
        if same:
            with self.lock:
                if self.active is None and rec['plan']['where'] != 'none':
                    self.active = rec['machine']
                    self.active_since = self.wall()
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
            self.active = rec['machine']
            self.active_since = self.wall()
            self.last_machine = rec['machine'] if rec['plan']['where'] != 'none' else None
            self.stage = 0
        self.save_machine(rec['machine'])
        self.emit('inventory received machine=%s client=%s firmware=%s' % (clean(rec['machine'], 64), clean(client_ip, 45), clean(rec['firmware'], 10)), host=rec['hostname'])
        self.emit(render_block(rec), raw=True)
        for fact in rec['facts']:
            self.emit(clean(fact, 200), host=rec['hostname'])
        if rec['plan']['where'] == 'none':
            self.question(None)
            self.release(rec['machine'])
            self.emit('cannot install reason=%s' % clean(rec['plan']['reason'], 80), logging.ERROR, rec['hostname'])
        else:
            self.question(disk_question(rec, Q_FIRST))
        return rec

    # One PC at a time: the machine that sent an inventory is active until it finishes, is cancelled, is reset or
    # its session is older than --timeout-minutes. Requests of another machine id get HTTP 409.
    def expire_locked(self):
        if self.active is not None and self.wall() - self.active_since > self.timeout_minutes * 60:
            gone, self.active = self.active, None
            return gone
        return None

    def check_machine(self, machine, client_ip):
        with self.lock:
            gone = self.expire_locked()
            busy = self.active is not None and self.active != machine
            now = self.wall()
            log = busy and now - self.busy_logged.get(machine, 0) > 60
            if log:
                self.busy_logged[machine] = now
        if gone:
            self.emit('session expired machine=%s' % clean(gone, 64), logging.WARNING)
        if busy:
            if log:
                self.emit('rejected machine=%s client=%s reason=busy' % (clean(machine, 64), clean(client_ip, 45)), logging.WARNING)
            raise Busy(BUSY_MESSAGE)

    def release(self, machine=None):
        with self.lock:
            if machine is None or self.active == machine:
                self.active = None

    def reset(self):
        with self.lock:
            gone, self.active = self.active, None
        self.emit('session reset machine=%s' % clean(gone or 'none', 64))

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

    def add_status(self, data, client_ip=''):
        st = parse_status(data)
        self.check_machine(st['machine'], client_ip)
        with self.lock:
            rec = self.inventories.get(st['machine'])
            if self.active == st['machine']:
                self.active_since = self.wall()
        name = rec['hostname'] if rec else st['machine']
        level = {'info': logging.INFO, 'warn': logging.WARNING, 'error': logging.ERROR, 'done': logging.INFO}[st['level']]
        # Messages are printed whole: step, failing statement and error id are needed remotely.
        self.emit(clean(st['text'], LOG_LIMIT), level, name)
        if st['level'] in ('done', 'error'):
            self.release(st['machine'])

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

    def apply_answer(self, text, source):
        # The operator answers y twice for the PC that reported last; n cancels; anything else is asked again.
        text = text.strip().lower()
        approved = None
        again = None
        host = None
        level = logging.INFO
        with self.lock:
            machine = self.last_machine
            rec = self.inventories.get(machine) if machine else None
            if rec is not None:
                host = rec['hostname']
            if rec is None:
                msg = 'no PC is waiting'
                level = logging.WARNING
            elif text not in (YES, NO):
                msg = INVALID_ANSWER
                level = logging.WARNING
                again = self.current_question
            elif text == NO:
                self.stage = 0
                self.active = None
                msg = 'cancelled changes=none'
                again = False
            elif self.stage == 0:
                self.stage = 1
                msg = None
                again = disk_question(rec, Q_LAST)
            else:
                self.stage = 0
                self.active_since = self.wall()
                sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
                self.approved[machine] = {'disk': sysd['number'], 'serial': sysd['serial']}
                msg = 'approved disk=%d serial=%s' % (sysd['number'], clean(sysd['serial'], 40))
                approved = machine
                again = False
        if approved is not None and self.keep_approvals:
            self.save_machine(approved)
        if again is False:
            self.question(None)
        if msg is not None:
            self.emit(msg, level, host)
        if again:
            self.question(again)
        if approved is not None:
            self.emit('next: ' + self.next_command(approved), logging.INFO, host)

    def approve_direct(self, machine, source):
        # `-y`: approves without the two questions; same binding to machine id + disk number + serial.
        approved = None
        host = None
        level = logging.INFO
        with self.lock:
            machine = machine or self.last_machine
            rec = self.inventories.get(machine) if machine else None
            if rec is not None:
                host = rec['hostname']
            if rec is None:
                msg = 'no such PC' if machine else 'no PC is waiting'
                level = logging.WARNING
            elif rec['plan']['where'] == 'none':
                msg = 'cannot approve reason=%s' % clean(rec['plan']['reason'], 80)
                level = logging.ERROR
            else:
                sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
                self.approved[machine] = {'disk': sysd['number'], 'serial': sysd['serial']}
                self.stage = 0
                self.active = machine
                self.active_since = self.wall()
                msg = 'approved disk=%d serial=%s' % (sysd['number'], clean(sysd['serial'], 40))
                approved = machine
        if approved is not None:
            if self.keep_approvals:
                self.save_machine(approved)
            if machine == self.last_machine:
                self.question(None)
        self.emit(msg, level, host)
        if approved is not None:
            self.emit('next: ' + self.next_command(approved), logging.INFO, host)

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
            if word == 'reset':
                self.reset()
                continue
            m = APPROVE_FILE_RE.fullmatch(word or '')
            if m is not None:
                self.approve_direct(m.group(1), 'file')

    def _poll_loop(self):
        while not self.stop.wait(self.poll_interval):
            try:
                self.poll_approvals_once()
            except OSError as e:
                self.emit('approvals directory error=%s' % clean(e.strerror or 'error'), logging.ERROR)

    def _tty_loop(self, stream):
        # Raw character input (no echo, ISIG kept) so the typed text can be drawn again under the log lines.
        import select
        import termios
        import tty
        fd = stream.fileno()
        old = termios.tcgetattr(fd)
        tty.setcbreak(fd)
        try:
            while not self.stop.is_set():
                if not select.select([fd], [], [], 0.2)[0]:
                    continue
                data = os.read(fd, 64)
                if not data:
                    break
                for ch in data.decode('ascii', 'ignore'):
                    line = self.term.key(ch)
                    if line is not None and line.strip():
                        self.apply_answer(line, 'stdin')
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)

    def _stdin_loop(self, stream):
        for line in stream:
            if self.stop.is_set():
                break
            if line.strip():
                self.apply_answer(line, 'stdin')

    def start_background(self, stdin_stream=None):
        threading.Thread(target=self._poll_loop, daemon=True).start()
        if stdin_stream is not None:
            target = self._tty_loop if self.term.interactive else self._stdin_loop
            threading.Thread(target=target, args=(stdin_stream,), daemon=True).start()

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
                self.ctx.add_status(data, self.client_address[0])
        except Invalid as e:
            self.fail(400, 'invalid ' + str(e))
            return
        except Busy as e:
            self.send_json(409, {'error': 'busy', 'message': str(e)})
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
            self.ctx.emit('bootstrap served client=%s' % clean(client, 45))
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
        try:
            self.ctx.check_machine(values[0], self.client_address[0])
        except Busy as e:
            self.send_json(409, {'error': 'busy', 'message': str(e)})
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
        try:
            self.ctx.check_machine(values[0], self.client_address[0])
        except Busy as e:
            self.send_json(409, {'error': 'busy', 'message': str(e)})
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
    # word: 'approve' or 'approve MACHINE-ID'
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
    p.add_argument('-y', '--yes', action='store_true',
                   help='approve the PC that reported last in the running server (no questions)')
    p.add_argument('--machine', metavar='ID', default=None, help='with -y: approve this machine id')
    p.add_argument('--reset', action='store_true', help='free the session of the running server (SIGHUP does the same)')
    p.add_argument('--log-file', metavar='FILE', default=None, help='also write the log to FILE (UTF-8)')
    return p.parse_args(argv)


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    args = parse_args(argv)
    if args.reset:
        if args.yes or args.machine is not None:
            print('--reset cannot be combined with -y', file=sys.stderr)
            return 2
        approvals = prepare_dir(os.path.join(prepare_dir(os.path.abspath(args.state_dir)), 'approvals'))
        write_approval(approvals, 'reset')
        print('reset queued: the running server takes it within one second')
        return 0
    if args.machine is not None and not args.yes:
        print('--machine needs -y', file=sys.stderr)
        return 2
    if args.yes:
        if args.machine is not None and MACHINE_RE.fullmatch(args.machine) is None:
            print('invalid machine id', file=sys.stderr)
            return 2
        approvals = prepare_dir(os.path.join(prepare_dir(os.path.abspath(args.state_dir)), 'approvals'))
        write_approval(approvals, 'approve' + (' ' + args.machine if args.machine else ''))
        print('approval queued: the running server takes it within one second')
        return 0

    term = Terminal(sys.stdout, sys.stdout.isatty() and sys.stdin is not None and sys.stdin.isatty())
    colors = HostColors()
    handler = PromptHandler(term)
    handler.setFormatter(make_formatter())
    handler.addFilter(HostFilter(colors, use_color()))
    LOGGER.setLevel(logging.INFO)
    LOGGER.addHandler(handler)
    LOGGER.propagate = False
    if args.log_file:
        fh = logging.FileHandler(args.log_file, encoding='utf-8')
        fh.setFormatter(make_formatter())
        fh.addFilter(HostFilter(colors, False))
        LOGGER.addHandler(fh)
    try:
        ctx = Context(args.payload, args.state_dir, args.authorized_key, args.timeout_minutes,
                      keep_approvals=args.keep_approvals, term=term, colors=colors)
    except (OSError, ValueError) as e:
        print('error: ' + str(e), file=sys.stderr)
        return 2

    addrs = [args.advertise] if args.advertise else local_ipv4s()
    print('On the Windows machine press Win+R, type powershell, press Enter, type one of the following commands and press Enter')
    for a in addrs:
        print('irm http://%s:%d|iex' % (a, args.port))
    if not addrs:
        print('no IPv4 address found: use --advertise IP')

    try:
        server = make_server(args.bind, args.port, ctx)
    except OSError as e:
        ctx.close()
        print('error: cannot listen: ' + str(e), file=sys.stderr)
        return 2
    signal.signal(signal.SIGHUP, lambda *_: ctx.reset())
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
