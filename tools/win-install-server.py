#!/usr/bin/env python3
# Serves the UniTotem Windows installer: bootstrap text, payload zip, inventory
# intake, operator approval. A PC runs: irm http://HOST:PORT|iex

import argparse
import hashlib
import ipaddress
import json
import math
import os
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
DEFAULT_KEY = os.path.expanduser('~/.ssh/id_ed25519.pub')

ZIP_DIR = 'unitotem-windows-installer/'
ENGINE_ENTRY = ZIP_DIR + 'Install-UniTotem.ps1'
SUMS_ENTRY = ZIP_DIR + 'payload/SHA256SUMS'
KEY_ENTRY = ZIP_DIR + 'payload/authorized_key.pub'

PLACEHOLDERS = ('SERVER', 'SHA256', 'BYTES', 'TIMEOUT', 'POLL', 'ENGINE')
PLACEHOLDER_RE = re.compile(r'@(SERVER|SHA256|BYTES|TIMEOUT|POLL|ENGINE)@')
MACHINE_RE = re.compile(r'[A-Za-z0-9-]{8,64}')
HOST_RE = re.compile(r'[A-Za-z0-9-]{1,15}')
WORD_RE = re.compile(r'WIPE-[A-Z0-9-]{1,40}-DISK[0-9]{1,4}-[A-Z0-9]{1,8}')
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
            'boot_free_mb', 'system_disk', 'os', 'disks')
DISK_KEYS = ('number', 'model', 'size_gb', 'style', 'serial', 'unique_id', 'bus',
             'system', 'partitions')
PART_KEYS = ('number', 'letter', 'size_mb', 'type')
STATUS_KEYS = ('machine', 'level', 'text')


class Invalid(ValueError):
    pass


def clean(value, limit=80):
    # Keep printable ASCII only: no terminal escape sequences from the network.
    text = str(value)
    return ''.join(ch for ch in text if ' ' <= ch <= '~')[:limit]


def confirm_word(hostname, number, serial):
    # Must match Get-ConfirmWord in Install-UniTotem.ps1 (same steps, same order).
    host = re.sub(r'[^A-Z0-9-]', '', str(hostname).upper())[:15]
    tag = re.sub(r'[^A-Za-z0-9]', '', str(serial)).upper()[:8]
    if not tag:
        tag = 'NOSERIAL'
    return 'WIPE-' + host + '-DISK' + str(int(number)) + '-' + tag


def _req(cond, what):
    if not cond:
        raise Invalid(what)


def _obj(value, keys, what):
    _req(isinstance(value, dict) and set(value) == set(keys), what)
    return value


def _str(value, maxlen, pattern=None, what='string'):
    _req(isinstance(value, str) and len(value) <= maxlen, what)
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
    secureboot = _enum(data['secureboot'], ('on', 'off', 'unknown'), 'secureboot')
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
            })
        disks.append({
            'number': number,
            'model': _str(d['model'], 200, None, 'model'),
            'size_gb': _num(d['size_gb'], 0, 1e7, 'size_gb'),
            'style': _str(d['style'], 32, None, 'style'),
            'serial': _str(d['serial'], 128, None, 'serial'),
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
        'disks': disks,
        'word': confirm_word(hostname, sysd['number'], sysd['serial']),
    }


def parse_status(data):
    _obj(data, STATUS_KEYS, 'status keys')
    return {
        'machine': _str(data['machine'], 64, MACHINE_RE, 'machine'),
        'level': _enum(data['level'], ('info', 'ok', 'error'), 'level'),
        'text': _str(data['text'], 512, None, 'text'),
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
        'Firmware:    ' + clean(rec['firmware'], 10),
        'Secure Boot: ' + clean(rec['secureboot'], 10),
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
            lines.append('    part %d  letter %s  %.0f MB  %s' % (
                p['number'], clean(p['letter'] or '-', 1), p['size_mb'], clean(p['type'], 64)))
    lines.append('Confirmation word for system disk %d: %s' % (sysd['number'], clean(rec['word'], 60)))
    lines.append('Type that word here, or run: win-install-server.py --approve WORD')
    return '\n'.join(lines)


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


def make_served_zip(src, key_line, state_dir):
    # Copies the payload entry by entry (streamed) and adds the key entry.
    fd, tmp = tempfile.mkstemp(prefix='payload-', suffix='.zip', dir=state_dir)
    os.close(fd)
    try:
        with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, 'w') as zout:
            for info in zin.infolist():
                if info.filename == KEY_ENTRY:
                    raise ValueError('payload already holds authorized_key.pub')
                zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                zi.compress_type = info.compress_type
                zi.external_attr = info.external_attr
                if info.filename.endswith('/'):
                    zout.writestr(zi, b'')
                    continue
                with zin.open(info) as fin, zout.open(zi, 'w') as fout:
                    shutil.copyfileobj(fin, fout, CHUNK)
            kz = zipfile.ZipInfo(KEY_ENTRY, date_time=(1980, 1, 1, 0, 0, 0))
            kz.compress_type = zipfile.ZIP_STORED
            kz.external_attr = 0o644 << 16
            zout.writestr(kz, (key_line + '\n').encode('ascii'))
    except BaseException:
        os.unlink(tmp)
        raise
    return tmp


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
                 out=None, clock=time.monotonic, poll_interval=1.0):
        self.state_dir = prepare_dir(os.path.abspath(state_dir))
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
        self.temp_zip = None
        payload = os.path.abspath(payload)
        self.engine_text = check_payload(payload)
        key_line = read_key(key_path)
        self.key_path = key_path
        self.key_line = key_line
        try:
            if key_line is None:
                self.served_path = payload
            else:
                self.temp_zip = make_served_zip(payload, key_line, self.state_dir)
                self.served_path = self.temp_zip
            self.size, self.sha = file_digest(self.served_path)
        except BaseException:
            self.close()
            raise
        clean_approvals(self.approvals_dir)

    def emit(self, text):
        with self.out_lock:
            if self.out_fn is not None:
                self.out_fn(text)
            else:
                print(text, flush=True)

    def close(self):
        self.stop.set()
        if self.temp_zip is not None:
            try:
                os.unlink(self.temp_zip)
            except OSError:
                pass
            self.temp_zip = None

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

    def add_inventory(self, data, client_ip):
        rec = parse_inventory(data)
        rec['client_ip'] = client_ip
        with self.lock:
            self.inventories[rec['machine']] = rec
        self.emit(render_block(rec))
        return rec

    def add_status(self, data):
        st = parse_status(data)
        with self.lock:
            rec = self.inventories.get(st['machine'])
        name = rec['hostname'] if rec else st['machine']
        self.emit('[' + clean(name, 15) + '] ' + clean(st['text'], 80))

    def get_approval(self, machine):
        with self.lock:
            rec = self.inventories.get(machine)
            ap = self.approved.get(machine)
            if rec and ap and ap['word'] == rec['word']:
                sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
                return {'state': 'approved', 'disk': sysd['number'], 'word': rec['word']}
        return {'state': 'wait'}

    def apply_word(self, word, source):
        word = word.strip()
        with self.lock:
            matches = [(m, rec) for m, rec in self.inventories.items()
                       if WORD_RE.fullmatch(word) and rec['word'] == word]
            if not matches:
                msg = 'no pending PC has that confirmation word'
            elif len(matches) > 1:
                msg = 'more than one PC has that confirmation word: nothing approved'
            else:
                machine, rec = matches[0]
                sysd = [d for d in rec['disks'] if d['number'] == rec['system_disk']][0]
                prev = self.approved.get(machine)
                already = prev is not None and prev['word'] == rec['word']
                self.approved[machine] = {'disk': sysd['number'], 'word': rec['word']}
                msg = ('already approved: ' if already else 'approved: ') + \
                      clean(rec['hostname'], 15) + ' disk ' + str(sysd['number'])
        self.emit(msg)

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
                self.apply_word(word, 'file')

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
                self.apply_word(line, 'stdin')

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
            return json.loads(body.decode('utf-8'), object_pairs_hook=_no_dupes,
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
    p.add_argument('--authorized-key', default=DEFAULT_KEY)
    p.add_argument('--timeout-minutes', type=int_arg(1, 1440), default=60)
    p.add_argument('--state-dir', default=default_state_dir())
    p.add_argument('--approve', metavar='WORD', default=None)
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.approve is not None:
        if WORD_RE.fullmatch(args.approve) is None:
            print('invalid confirmation word', file=sys.stderr)
            return 2
        approvals = prepare_dir(os.path.join(prepare_dir(os.path.abspath(args.state_dir)), 'approvals'))
        write_approval(approvals, args.approve)
        print('approval queued: the running server takes it within one second')
        return 0

    try:
        ctx = Context(args.payload, args.state_dir, args.authorized_key, args.timeout_minutes)
    except (OSError, ValueError) as e:
        print('error: ' + str(e), file=sys.stderr)
        return 2

    addrs = [args.advertise] if args.advertise else local_ipv4s()
    print('Paste one of these on the Windows PC (PowerShell):')
    for a in addrs:
        print('  irm http://%s:%d|iex' % (a, args.port))
    print('Or in Win+R, confirmed with Ctrl+Shift+Enter (administrator):')
    for a in addrs:
        run = 'powershell -NoProfile -Command "irm http://%s:%d|iex"' % (a, args.port)
        if len(run) <= 250:  # the Run field takes 259 characters
            print('  ' + run)
    if not addrs:
        print('  no IPv4 address found: use --advertise IP')
    print('payload: sha256 %s, %d bytes' % (ctx.sha, ctx.size))
    if ctx.key_line is None:
        print('WARNING: OPEN MODE: no key file at %s; the payload is not restricted to a key'
              % args.authorized_key)
    else:
        print('authorized key: ' + args.authorized_key)

    try:
        server = make_server(args.bind, args.port, ctx)
    except OSError as e:
        ctx.close()
        print('error: cannot listen: ' + str(e), file=sys.stderr)
        return 2
    stdin_stream = sys.stdin if (sys.stdin is not None and sys.stdin.isatty()) else None
    ctx.start_background(stdin_stream)
    print('listening on %s:%d' % (args.bind, server.server_port), flush=True)
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
