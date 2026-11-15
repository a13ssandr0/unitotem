#!/usr/bin/env python3
"""Imports the settings of a UniTotem 2.x node into a running UniTotem 3.x manager through its web API.

Reads a directory holding the 2.x `unitotem.conf` (JSON: `urls`, `default_duration`, `users`), its `uploaded/` media,
optionally `hostname` and `timezone` files, and makes the 3.x playlist equal to it: media uploaded, URL assets added,
items in the 2.x order with the same duration and enabled flag. Re-running updates in place.

Inputs: UNITOTEM_URL (https://host), UNITOTEM_USER, and the password from the file named by UNITOTEM_PASSWORD_FILE or,
when unset, from the first line of stdin. The password is never an argument and never logged.
The device certificate is pinned by --fingerprint (SHA-256 of the DER certificate); without it the fingerprint seen is
logged and trusted for this run (trust on first use).

Exit status: 0 done and verified, 1 mismatch or failure, 2 bad input.
"""
import argparse
import base64
import hashlib
import http.client
import json
import logging
import os
import re
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.parse
import uuid as uuidlib

log = logging.getLogger('import-unitotem2')

KNOWN_TOP = {'urls', 'default_duration', 'users'}
KNOWN_ITEM = {'url', 'duration', 'enabled'}
FILE_NAME = re.compile(r'[A-Za-z0-9._-]{1,200}')   # what the manager's secure_filename keeps unchanged
HOST_NAME = re.compile(r'[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?')
ZONE_NAME = re.compile(r'[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}')
CALL_TIMEOUT = 60
CRON_MARK = 'unitotem:-)'
CRON_COMMANDS = {'/usr/sbin/poweroff': 'pwr', '/usr/sbin/reboot': 'reb'}   # the same table as the manager's own crontab import
CRON_FIELD = re.compile(r'[0-9*/,-]{1,40}')
DAYS = re.compile(r'[0-7*/,-]{1,40}')
SCHEDULE = re.compile(r'([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])')
MECHANISMS = ('auto', 'ddc', 'cec', 'output', 'wol', 'serial', 'gpio')


class Failure(Exception):
    pass


# ---------------------------------------------------------------- source

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def load_source(src, hostname_opt, timezone_opt):
    """The desired state: {'items': [...], 'default_duration': int, 'files': {name: sha}, 'hostname', 'timezone'}."""
    with open(os.path.join(src, 'unitotem.conf'), encoding='utf-8') as f:
        conf = json.load(f)
    if not isinstance(conf, dict):
        raise Failure('unitotem.conf is not a JSON object')
    for key in sorted(set(conf) - KNOWN_TOP):
        log.warning('unknown key in unitotem.conf ignored: %s', key)
    if conf.get('users'):
        log.info('2.x web accounts (%d) are not imported: administrators are system accounts of the new device',
                 len(conf['users']))
    default_duration = conf.get('default_duration', 30)
    if not isinstance(default_duration, int) or isinstance(default_duration, bool) or not 0 <= default_duration <= 86400:
        raise Failure('default_duration out of range')
    items, files = [], {}
    for n, raw in enumerate(conf.get('urls', []), 1):
        if not isinstance(raw, dict) or not isinstance(raw.get('url'), str) or not raw['url']:
            raise Failure('item %d has no url' % n)
        for key in sorted(set(raw) - KNOWN_ITEM):
            log.warning('unknown key in item %d ignored: %s', n, key)
        url = raw['url']
        duration = raw.get('duration', default_duration)
        if not isinstance(duration, (int, float)) or isinstance(duration, bool) or not 0 <= duration <= 86400:
            raise Failure('item %d: duration out of range' % n)
        enabled = raw.get('enabled', False)
        if not isinstance(enabled, bool):
            raise Failure('item %d: enabled is not a boolean' % n)
        if url.startswith('file:'):
            name = url[5:]
            if not FILE_NAME.fullmatch(name) or name in ('.', '..'):
                raise Failure('item %d: unsupported file name %r' % (n, name))
            path = os.path.join(src, 'uploaded', name)
            if not os.path.isfile(path):
                raise Failure('item %d: missing media file %s' % (n, name))
            files.setdefault(name, sha256_file(path))
            items.append({'url': url, 'name': name, 'duration': int(duration), 'enabled': enabled, 'file': name})
        else:
            if not re.fullmatch(r'https?://[^\s]+', url):
                raise Failure('item %d: unsupported url %r' % (n, url))
            items.append({'url': url, 'name': '', 'duration': int(duration), 'enabled': enabled, 'file': None})
    updir = os.path.join(src, 'uploaded')
    for name in sorted(os.listdir(updir)) if os.path.isdir(updir) else []:
        path = os.path.join(updir, name)
        if name in files or not os.path.isfile(path):
            continue
        if FILE_NAME.fullmatch(name) and name not in ('.', '..'):
            files[name] = sha256_file(path)      # media in the library that no item uses
        else:
            log.warning('media file with an unsupported name ignored: %s', name)
    sums = os.path.join(src, 'SHA256SUMS')
    if os.path.isfile(sums):
        with open(sums, encoding='utf-8') as f:
            for line in f:
                m = re.fullmatch(r'([0-9a-f]{64})  uploaded/(.+)', line.rstrip('\n'))
                if m and m.group(2) in files and files[m.group(2)] != m.group(1):
                    raise Failure('SHA256SUMS mismatch for %s' % m.group(2))
    hostname = hostname_opt or _first_line(os.path.join(src, 'hostname'))
    timezone = timezone_opt or _first_line(os.path.join(src, 'timezone'))
    if hostname and not (HOST_NAME.fullmatch(hostname)):
        raise Failure('invalid hostname %r' % hostname)
    if timezone and not ZONE_NAME.fullmatch(timezone):
        raise Failure('invalid timezone %r' % timezone)
    return {'items': items, 'default_duration': default_duration, 'files': files,
            'hostname': hostname, 'timezone': timezone}


def _first_line(path):
    try:
        with open(path, encoding='utf-8') as f:
            return f.readline().strip()
    except OSError:
        return ''


# ---------------------------------------------------------------- transport

class Pin:
    """Checks the peer certificate against the pinned fingerprint (or records it: trust on first use)."""

    def __init__(self, fingerprint):
        self.fingerprint = fingerprint.lower().replace(':', '') if fingerprint else None
        self.seen = None
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.context.check_hostname = False
        self.context.verify_mode = ssl.CERT_NONE      # replaced by the fingerprint check in check()

    def check(self, sock):
        fp = hashlib.sha256(sock.getpeercert(binary_form=True)).hexdigest()
        if self.fingerprint is not None and fp != self.fingerprint:
            sock.close()
            raise Failure('certificate fingerprint %s does not match the pinned one' % fp)
        if self.seen is None:
            self.seen = fp
            if self.fingerprint is None:
                log.info('certificate fingerprint (trusted on first use): %s', fp)
        elif fp != self.seen:
            sock.close()
            raise Failure('certificate changed during the run')


class Conn(http.client.HTTPSConnection):
    def __init__(self, host, port, pin):
        super().__init__(host, port, context=pin.context, timeout=CALL_TIMEOUT)
        self.pin = pin

    def connect(self):
        super().connect()
        self.pin.check(self.sock)


class Session:
    def __init__(self, base, user, password, pin):
        u = urllib.parse.urlsplit(base)
        if u.scheme != 'https' or not u.hostname:
            raise Failure('UNITOTEM_URL must be https://host[:port]')
        self.host, self.port, self.pin = u.hostname, u.port or 443, pin
        self.cookie = None
        self.login(user, password)

    def request(self, method, path, body=None, headers=None):
        conn = Conn(self.host, self.port, self.pin)
        try:
            h = dict(headers or {})
            if self.cookie:
                h['Cookie'] = self.cookie
            conn.request(method, path, body=body, headers=h)
            r = conn.getresponse()
            return r.status, r.getheaders(), r.read()
        finally:
            conn.close()

    def login(self, user, password):
        body = urllib.parse.urlencode({'username': user, 'password': password, 'src': '/'})
        status, headers, _ = self.request('POST', '/auth/token', body,
                                          {'Content-Type': 'application/x-www-form-urlencoded'})
        cookie = None
        for k, v in headers:
            if k.lower() == 'set-cookie' and '=' in v:
                pair = v.split(';', 1)[0]
                if pair.split('=', 1)[1]:
                    cookie = pair
        if status >= 400 or not cookie:
            raise Failure('login refused (HTTP %d)' % status)
        self.cookie = cookie
        log.info('logged in as %s', user)

    def upload(self, name, data):
        boundary = secrets.token_hex(16)
        head = ('--%s\r\nContent-Disposition: form-data; name="files"; filename="%s"\r\n'
                'Content-Type: application/octet-stream\r\n\r\n' % (boundary, name)).encode()
        body = head + data + ('\r\n--%s--\r\n' % boundary).encode()
        status, _, _ = self.request('POST', '/api/scheduler/upload', body,
                                    {'Content-Type': 'multipart/form-data; boundary=' + boundary})
        if status != 201:
            raise Failure('upload of %s refused (HTTP %d)' % (name, status))

    def download(self, name):
        status, _, data = self.request('GET', '/uploaded/' + urllib.parse.quote(name))
        if status != 200:
            raise Failure('download of %s failed (HTTP %d)' % (name, status))
        return data


class WebSocket:
    """Minimal RFC 6455 client: text frames, masked, fragmentation, ping/pong, close."""

    def __init__(self, session):
        raw = socket.create_connection((session.host, session.port), timeout=CALL_TIMEOUT)
        self.sock = session.pin.context.wrap_socket(raw, server_hostname=None)
        session.pin.check(self.sock)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ('GET /ws HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
               'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: https://%s:%d\r\nCookie: %s\r\n\r\n'
               % (session.host, session.port, key, session.host, session.port, session.cookie))
        self.sock.sendall(req.encode())
        self.buf = b''
        head = self._until(b'\r\n\r\n')
        if b' 101 ' not in head.split(b'\r\n', 1)[0]:
            raise Failure('websocket refused: %s' % head.split(b'\r\n', 1)[0].decode('latin-1'))
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        if accept not in head:
            raise Failure('websocket handshake answer invalid')

    def _until(self, marker):
        while marker not in self.buf:
            self._fill()
        head, _, self.buf = self.buf.partition(marker)
        return head

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise Failure('connection closed by the device')
        self.buf += chunk

    def _take(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack('>H', n)
        else:
            head += bytes([0x80 | 127]) + struct.pack('>Q', n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def send(self, obj):
        self._send_frame(1, json.dumps(obj).encode())

    def recv(self, timeout):
        """Next JSON text message, or None on timeout."""
        self.sock.settimeout(timeout)
        try:
            message = b''
            while True:
                b0, b1 = self._take(2)
                n = b1 & 0x7f
                if n == 126:
                    n = struct.unpack('>H', self._take(2))[0]
                elif n == 127:
                    n = struct.unpack('>Q', self._take(8))[0]
                mask = self._take(4) if b1 & 0x80 else None
                payload = self._take(n)
                if mask:
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                op = b0 & 0x0f
                if op == 9:
                    self._send_frame(10, payload)
                elif op == 8:
                    raise Failure('websocket closed by the device')
                elif op in (1, 0):
                    message += payload
                    if b0 & 0x80:
                        return json.loads(message.decode())
        except (socket.timeout, TimeoutError):
            return None
        finally:
            self.sock.settimeout(CALL_TIMEOUT)

    def close(self):
        try:
            self._send_frame(8, b'')
            self.sock.close()
        except OSError:
            pass


class Api:
    """Calls the websocket API. A call is followed by a read of an unrelated state whose answer closes it (one
    connection handles its messages in order, so that answer arrives after the call has finished); late broadcasts
    are drained so the newest message of a target wins."""
    MARKERS = ('Settings/Network/hostname', 'Settings/DateTime/status')

    def __init__(self, ws):
        self.ws = ws
        self.latest = {}
        self.errors = []
        deadline = time.monotonic() + CALL_TIMEOUT
        while time.monotonic() < deadline:       # the 'connected' greeting
            m = self.ws.recv(5)
            if m and m.get('target') == 'connected':
                return
        raise Failure('no greeting from the websocket')

    def _take(self, m):
        if 'error' in m:
            self.errors.append(m)
        self.latest[m.get('target')] = m

    def call(self, target, **args):
        """Sends the call, waits until it is done; returns the newest message with the same target (or None)."""
        self.errors.clear()
        self.latest.pop(target, None)
        marker = self.MARKERS[1] if target.startswith('Settings/Network/') else self.MARKERS[0]
        self.ws.send({'target': target, **args})
        self.ws.send({'target': marker})
        deadline = time.monotonic() + CALL_TIMEOUT
        while True:
            m = self.ws.recv(5)
            if m is not None:
                self._take(m)
                if m.get('target') == marker:
                    break
            if time.monotonic() > deadline:
                raise Failure('timeout waiting for %s' % target)
        while True:                               # late broadcasts of this call
            m = self.ws.recv(0.2)
            if m is None:
                break
            self._take(m)
        if self.errors:
            raise Failure('%s failed: %s' % (target, '; '.join(
                str(e.get('error')) + (' ' + str(e['extra']) if e.get('extra') else '') for e in self.errors)))
        return self.latest.get(target)

    def read(self, target, **args):
        m = self.call(target, **args)
        if m is None:
            raise Failure('no answer to %s' % target)
        return m


def load_crontab(path):
    """Timers of a 2.x root crontab: the lines that carry the product mark and run poweroff or reboot. A commented line stays a disabled timer."""
    timers = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            enabled = not line.startswith('#')
            line = line.lstrip('# ')
            if CRON_MARK not in line:
                continue
            body, _, _ = line.partition('#')
            fields = body.split(None, 5)
            if len(fields) != 6:
                continue
            command = fields[5].strip()
            if command not in CRON_COMMANDS:
                log.warning('crontab line not migrated (unknown command): %s', command)
                continue
            if not all(CRON_FIELD.fullmatch(x) for x in fields[:5]):
                log.warning('crontab line not migrated (invalid schedule): %s', ' '.join(fields[:5]))
                continue
            timers.append({'command': CRON_COMMANDS[command], 'minute': fields[0], 'hour': fields[1], 'day_of_month': fields[2],
                           'month': fields[3], 'day_of_week': fields[4], 'enabled': enabled})
    return timers


def timer_key(job):
    return tuple(job.get(k) or None for k in ('command', 'minute', 'hour', 'day_of_month', 'month', 'day_of_week', 'output'))


def screen_schedule(spec, days, mechanism, outputs):
    """Timers that switch every output on at the first time of `spec` (HH:MM-HH:MM) and off at the second, on `days` (cron day-of-week field)."""
    m = SCHEDULE.fullmatch(spec)
    if not m:
        raise Failure('screen schedule must be HH:MM-HH:MM')
    if not DAYS.fullmatch(days):
        raise Failure('invalid days %r' % days)
    if mechanism not in MECHANISMS:
        raise Failure('unknown mechanism %r' % mechanism)
    on_h, on_m, off_h, off_m = (str(int(x)) for x in m.groups())
    out = []
    for name in outputs:
        for command, hour, minute in (('scr_on', on_h, on_m), ('scr_off', off_h, off_m)):
            out.append({'command': command, 'minute': minute, 'hour': hour, 'day_of_month': '*', 'month': '*', 'day_of_week': days,
                        'enabled': True, 'output': name, 'mechanism': mechanism})
    return out


# ---------------------------------------------------------------- import

class Importer:
    def __init__(self, session, api, want, playlist_name, dry):
        self.session, self.api, self.want, self.name, self.dry = session, api, want, playlist_name, dry
        self.pid = None
        self.timers_wanted = []

    def act(self, text, target=None, **args):
        if self.dry:
            log.info('PLAN %s', text)
            return None
        log.info('%s', text)
        return self.api.call(target, **args) if target else None

    def playlists(self):
        return self.api.read('Scheduler/playlists')['playlists']

    def choose_playlist(self):
        pls = self.playlists()
        same = [p for p in pls if p['name'] == self.name]
        if same:
            self.pid = same[0]['playlist_id']
            log.info('playlist "%s" exists (%s)', self.name, self.pid)
        else:
            empty = [p for p in pls if p['asset_count'] == 0]
            if len(pls) == 1 and empty:
                self.pid = empty[0]['playlist_id']
                self.act('rename the empty playlist "%s" to "%s"' % (empty[0]['name'], self.name),
                         'Scheduler/rename_playlist', playlist_id=self.pid, name=self.name)
            else:
                known = {p['playlist_id'] for p in pls}
                self.act('create playlist "%s"' % self.name, 'Scheduler/create_playlist', name=self.name)
                if not self.dry:
                    new = [p for p in self.playlists() if p['playlist_id'] not in known]
                    if len(new) != 1:
                        raise Failure('cannot find the created playlist')
                    self.pid = new[0]['playlist_id']
        pls = [p for p in self.playlists()] if not self.dry else pls
        if self.pid and not any(p['playlist_id'] == self.pid and p['is_default'] for p in pls):
            self.act('make playlist "%s" the default' % self.name, 'Scheduler/set_default_playlist', playlist_id=self.pid)

    def media(self):
        files = self.api.read('Scheduler/files')['files']
        for name, digest in self.want['files'].items():
            if name in files:
                have = hashlib.sha256(self.session.download(name)).hexdigest()
                if have == digest:
                    log.info('media %s present, checksum equal', name)
                    continue
                log.warning('media %s differs on the device, replaced', name)
                self.act('delete media %s' % name, 'Scheduler/delete_files', files=[name])
            if self.dry:
                log.info('PLAN upload media %s (%s)', name, digest[:12])
                continue
            with open(os.path.join(self.srcdir, 'uploaded', name), 'rb') as f:
                data = f.read()
            log.info('upload media %s (%d bytes)', name, len(data))
            self.session.upload(name, data)
            deadline = time.monotonic() + CALL_TIMEOUT
            while time.monotonic() < deadline:
                if name in self.api.read('Scheduler/files')['files']:
                    break
                time.sleep(0.5)
            else:
                raise Failure('media %s did not appear on the device under that name' % name)

    def assets(self):
        return self.api.read('Scheduler/assets', playlist_id=self.pid)['items']

    def playlist(self):
        existing = self.assets() if self.pid else []
        used, match = set(), []
        for item in self.want['items']:
            hit = next((a for a in existing if a['url'] == item['url'] and a['uuid'] not in used), None)
            if hit:
                used.add(hit['uuid'])
            match.append(hit)
        for a in existing:
            if a['uuid'] not in used:
                self.act('remove asset not in the 2.x list: %s' % a['url'], 'Scheduler/delete_asset',
                         uuid=a['uuid'], playlist_id=self.pid)
        for item, hit in zip(self.want['items'], match):
            if hit is None:
                if item['file']:
                    self.act('add file %s' % item['url'], 'Scheduler/add_file_assets',
                             items=[{'url': item['file'], 'duration': item['duration'], 'enabled': item['enabled']}],
                             playlist_id=self.pid)
                else:
                    self.act('add url %s' % item['url'], 'Scheduler/add_url_assets',
                             items=[{'url': item['url'], 'duration': item['duration'], 'enabled': item['enabled'],
                                     'media_type': 0}], playlist_id=self.pid)
        if self.dry:
            for item, hit in zip(self.want['items'], match):
                if hit and (hit['duration'], hit['enabled'], hit['name']) != (item['duration'], item['enabled'], item['name']):
                    log.info('PLAN edit %s: duration %s enabled %s', item['url'], item['duration'], item['enabled'])
            log.info('PLAN order: %d items in the 2.x order', len(self.want['items']))
            return
        now = self.assets()
        byurl = {}
        for a in now:
            byurl.setdefault(a['url'], []).append(a)
        order = []
        for item in self.want['items']:
            order.append(byurl[item['url']].pop(0))
        for item, a in zip(self.want['items'], order):
            args = {}
            if a['name'] != item['name']:
                args['name'] = item['name']
            if a['duration'] != item['duration']:
                args['duration'] = item['duration']
            if a['enabled'] != item['enabled']:
                args['enabled'] = item['enabled']
            if args:
                self.act('edit %s: %s' % (item['url'], ', '.join('%s=%s' % kv for kv in args.items())),
                         'Scheduler/edit_asset', uuid=a['uuid'], playlist_id=self.pid, **args)
        cur = [a['uuid'] for a in now]
        for i, a in enumerate(order):
            if cur[i] != a['uuid']:
                j = cur.index(a['uuid'])
                self.act('move item %d to position %d: %s' % (j, i, a['url']), 'Scheduler/reorder_assets',
                         from_i=j, to_i=i, playlist_id=self.pid)
                cur.insert(i, cur.pop(j))

    def default_duration(self):
        d = self.want['default_duration']
        if self.pid and self.api.read('Scheduler/default_duration', playlist_id=self.pid)['duration'] == d:
            log.info('default duration %d s already set', d)
            return
        self.act('set default duration %d s' % d, 'Scheduler/set_default_duration', duration=d, playlist_id=self.pid)

    def system(self):
        host = self.want['hostname']
        if host:
            if self.api.read('Settings/Network/hostname')['hostname'] == host:
                log.info('hostname %s already set', host)
            else:
                self.act('set hostname %s (takes effect at once; no reboot needed, the address "%s.local" changes)'
                         % (host, host), 'Settings/Network/set_hostname', hostname=host)
        tz = self.want['timezone']
        if tz:
            if self.api.read('Settings/DateTime/status').get('timezone') == tz:
                log.info('timezone %s already set', tz)
            else:
                self.act('set timezone %s' % tz, 'Settings/DateTime/set_timezone', timezone=tz)

    def windows(self):
        """(viewer id, window id, assigned playlist) of every window of every viewer."""
        viewers = self.api.read('Viewers/list')['viewers']
        return [(vid, w['window_id'], w.get('assigned_playlist')) for vid, v in viewers.items() for w in v.get('windows', [])]

    def outputs(self):
        viewers = self.api.read('Viewers/list')['viewers']
        return sorted({w['screen_name'] for v in viewers.values() for w in v.get('windows', []) if w.get('screen_name')})

    def assign(self):
        """The imported playlist plays on every window: a window without a playlist shows the idle page."""
        for vid, wid, current in self.windows():
            if current == self.pid:
                log.info('window %s of %s already plays the playlist', wid, vid)
            else:
                self.act('assign the playlist to window %s of %s' % (wid, vid), 'Viewers/assign_playlist',
                         viewer_id=vid, window_id=wid, playlist_id=self.pid)

    def timers(self, wanted):
        """Adds the wanted timers that the device does not have yet (same action, schedule and output) and sets their enabled state."""
        self.timers_wanted = wanted
        have = self.api.read('Settings/Timers/jobs')['jobs']
        key = timer_key
        for w in wanted:
            same = [j for j in have if key(j) == key(w)]
            if not same:
                args = {k: v for k, v in w.items() if k != 'enabled' and v is not None}
                self.act('add timer %s %s:%s days %s%s' % (w['command'], w['hour'], w['minute'], w['day_of_week'],
                                                         ' on %s' % w['output'] if w.get('output') else ''),
                         'Settings/Timers/add_job', **args)
                if self.dry:
                    continue
                have = self.api.read('Settings/Timers/jobs')['jobs']
                same = [j for j in have if key(j) == key(w)]
            for j in same[:1]:
                if bool(j['enabled']) != w['enabled']:
                    self.act('set timer %s enabled=%s' % (j['uuid'], w['enabled']), 'Settings/Timers/set_job_enabled',
                             uuid=j['uuid'], state=w['enabled'])
                else:
                    log.info('timer %s %s:%s already present', w['command'], w['hour'], w['minute'])

    def verify(self):
        problems = []
        pls = self.playlists()
        mine = [p for p in pls if p['playlist_id'] == self.pid]
        if not mine:
            return ['playlist missing']
        if not mine[0]['is_default']:
            problems.append('playlist is not the default')
        items = self.assets()
        want = self.want['items']
        if len(items) != len(want):
            problems.append('item count %d, expected %d' % (len(items), len(want)))
        for i, (a, w) in enumerate(zip(items, want), 1):
            for key in ('url', 'name', 'duration', 'enabled'):
                if a[key] != w[key]:
                    problems.append('item %d %s: %r, expected %r' % (i, key, a[key], w[key]))
        if self.api.read('Scheduler/default_duration', playlist_id=self.pid)['duration'] != self.want['default_duration']:
            problems.append('default duration differs')
        files = self.api.read('Scheduler/files')['files']
        for name, digest in self.want['files'].items():
            if name not in files:
                problems.append('media %s missing' % name)
            elif hashlib.sha256(self.session.download(name)).hexdigest() != digest:
                problems.append('media %s checksum differs' % name)
        if self.want['hostname'] and self.api.read('Settings/Network/hostname')['hostname'] != self.want['hostname']:
            problems.append('hostname differs')
        if self.want['timezone'] and self.api.read('Settings/DateTime/status').get('timezone') != self.want['timezone']:
            problems.append('timezone differs')
        for vid, wid, current in self.windows():
            if current != self.pid:
                problems.append('window %s of %s does not play the playlist' % (wid, vid))
        have = self.api.read('Settings/Timers/jobs')['jobs']
        for w in self.timers_wanted:
            if not any(timer_key(j) == timer_key(w) and bool(j['enabled']) == w['enabled'] for j in have):
                problems.append('timer %s %s:%s missing' % (w['command'], w['hour'], w['minute']))
        return problems


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--source', required=True, help='directory with unitotem.conf, uploaded/, hostname, timezone')
    p.add_argument('--playlist', default='PianoTerra', help='name of the playlist to fill')
    p.add_argument('--fingerprint', help='SHA-256 of the DER certificate (hex, colons allowed)')
    p.add_argument('--hostname', help='override the hostname file')
    p.add_argument('--timezone', help='override the timezone file')
    p.add_argument('--crontab', help='root crontab of the 2.x system: its marked poweroff and reboot lines become timers')
    p.add_argument('--screen-schedule', help='HH:MM-HH:MM: every output is switched on at the first time and off at the second')
    p.add_argument('--screen-days', default='1-5', help='cron day-of-week field of --screen-schedule (default 1-5)')
    p.add_argument('--screen-mechanism', default='output', choices=MECHANISMS, help='how --screen-schedule switches the screen (default output)')
    p.add_argument('--dry-run', action='store_true', help='read the device, print the plan, change nothing')
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s', stream=sys.stderr)

    url, user = os.environ.get('UNITOTEM_URL'), os.environ.get('UNITOTEM_USER')
    pwfile = os.environ.get('UNITOTEM_PASSWORD_FILE')
    if not url or not user:
        log.error('UNITOTEM_URL and UNITOTEM_USER are required')
        return 2
    try:
        if pwfile:
            with open(pwfile, encoding='utf-8') as f:
                password = f.readline().rstrip('\r\n')
        else:
            password = sys.stdin.readline().rstrip('\r\n')
        if not password:
            log.error('empty password')
            return 2
        want = load_source(args.source, args.hostname, args.timezone)
        if args.screen_schedule:
            screen_schedule(args.screen_schedule, args.screen_days, args.screen_mechanism, [])   # refuses a bad schedule before the device is touched
        if args.crontab:
            load_crontab(args.crontab)
    except (OSError, ValueError, Failure) as e:
        log.error('input: %s', e)
        return 2
    if not args.playlist.strip():
        log.error('empty playlist name')
        return 2

    log.info('source: %d items, %d media files, default duration %d s, hostname %s, timezone %s',
             len(want['items']), len(want['files']), want['default_duration'],
             want['hostname'] or '-', want['timezone'] or '-')
    ws = None
    try:
        session = Session(url, user, password, Pin(args.fingerprint))
        ws = WebSocket(session)
        api = Api(ws)
        imp = Importer(session, api, want, args.playlist.strip(), args.dry_run)
        imp.srcdir = args.source
        imp.choose_playlist()
        imp.media()
        imp.playlist()
        imp.default_duration()
        imp.system()
        imp.assign()
        wanted = load_crontab(args.crontab) if args.crontab else []
        if args.screen_schedule:
            wanted += screen_schedule(args.screen_schedule, args.screen_days, args.screen_mechanism, imp.outputs())
        imp.timers(wanted)
        if args.dry_run:
            log.info('dry run: nothing changed')
            return 0
        problems = imp.verify()
        for pr in problems:
            log.error('verify: %s', pr)
        if problems:
            return 1
        log.info('verified: %d items, %d media files, settings equal to the 2.x source', len(want['items']), len(want['files']))
        return 0
    except (Failure, OSError, ssl.SSLError, http.client.HTTPException, ValueError, KeyError) as e:
        log.error('%s', e)
        return 1
    finally:
        if ws:
            ws.close()


if __name__ == '__main__':
    sys.exit(main())
