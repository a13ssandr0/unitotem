"""Tests of tools/import-unitotem2.py against a fake manager (HTTPS + websocket) that follows the 3.x API semantics.

Run: python3 -m unittest -v tools/release/test_import_unitotem2.py   (needs the openssl command for the certificate)
"""
import base64
import hashlib
import importlib.util
import json
import logging
import os
import shutil
import ssl
import struct
import subprocess
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('imp2', HERE.parent / 'import-unitotem2.py')
imp2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(imp2)

PASSWORD = 'S3cret-pw-value'
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class State:
    def __init__(self):
        self.playlists = {'p1': {'name': 'Default', 'assets': [], 'dd': 30}}
        self.default = 'p1'
        self.files = {}
        self.hostname = 'unitotem'
        self.tz = 'UTC'
        self.log = []
        self.corrupt = set()       # media names served with wrong content
        self.admin = True
        self.setup_calls = []
        self.windows = [{'window_id': 0, 'screen_name': 'HDMI-A-1', 'assigned_playlist': None}]
        self.jobs = []

    def pl(self, pid):
        return self.playlists[pid or self.default]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    @property
    def st(self):
        return self.server.state

    def _send(self, code, body=b'', headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        return 'session=ok' in self.headers.get('Cookie', '')

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n)
        if self.path == '/setup':
            if self.st.admin:
                return self._send(404)
            data = json.loads(body)
            self.st.setup_calls.append(data['username'])
            self.st.admin = True
            return self._send(200, b'{"ok": true}', [('Content-Type', 'application/json')])
        if self.path == '/auth/token':
            form = dict(p.split('=', 1) for p in body.decode().split('&'))
            if form.get('username') == 'admin' and form.get('password') == PASSWORD:
                return self._send(303, headers=[('Set-Cookie', 'session=ok; HttpOnly; Secure'), ('Location', '/')])
            return self._send(401)
        if self.path == '/api/scheduler/upload' and self._authed():
            head, _, rest = body.partition(b'\r\n\r\n')
            name = head.split(b'filename="')[1].split(b'"')[0].decode()
            data = rest.rsplit(b'\r\n--', 1)[0]
            final = name
            i = 1
            while final in self.st.files:
                i += 1
                stem, dot, ext = name.rpartition('.')
                final = '%s_%d.%s' % (stem, i, ext)
            self.st.files[final] = data
            self.st.pl(None)['assets'].append(
                {'uuid': uuid.uuid4().hex, 'name': final, 'url': 'file:' + final, 'duration': 0, 'enabled': False})
            self.st.log.append(('upload', final))
            return self._send(201)
        self._send(403)

    def do_GET(self):
        if self.path == '/login':
            return self._send(200) if self.st.admin else self._send(303, headers=[('Location', '/setup')])
        if self.path.startswith('/uploaded/') and self._authed():
            name = self.path[len('/uploaded/'):]
            if name in self.st.files:
                data = self.st.files[name]
                if name in self.st.corrupt:
                    data = data + b'x'
                return self._send(200, data)
            return self._send(404)
        if self.path == '/ws' and self._authed():
            key = self.headers['Sec-WebSocket-Key']
            acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', acc)
            self.end_headers()
            self.close_connection = True
            return self.ws()
        self._send(403)

    # websocket
    def _recv(self):
        def take(n):
            b = b''
            while len(b) < n:
                c = self.rfile.read(n - len(b))
                if not c:
                    raise EOFError
                b += c
            return b
        b0, b1 = take(2)
        n = b1 & 0x7f
        if n == 126:
            n = struct.unpack('>H', take(2))[0]
        elif n == 127:
            n = struct.unpack('>Q', take(8))[0]
        mask = take(4)
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(take(n)))
        if b0 & 0x0f == 8:
            raise EOFError
        return json.loads(data)

    def _out(self, obj):
        data = json.dumps(obj).encode()
        n = len(data)
        head = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n))
        self.wfile.write(head + data)
        self.wfile.flush()

    def ws(self):
        self._out({'target': 'connected', 'boot': 'x'})
        while True:
            try:
                msg = self._recv()
            except (EOFError, OSError):
                return
            t = msg.pop('target')
            try:
                for out in self.api(t, msg):
                    self._out(out)
            except KeyError as e:
                self._out({'target': t, 'error': 'Invalid command', 'extra': str(e)})

    def _plist(self):
        return [{'playlist_id': k, 'name': v['name'], 'asset_count': len(v['assets']),
                 'enabled_count': sum(a['enabled'] for a in v['assets']), 'is_default': k == self.st.default}
                for k, v in self.st.playlists.items()]

    def api(self, t, a):
        st = self.st
        st.log.append((t, {k: v for k, v in a.items()}))
        if t == 'Settings/Network/hostname':
            return [{'target': t, 'hostname': st.hostname}]
        if t == 'Settings/DateTime/status':
            return [{'target': t, 'timezone': st.tz}]
        if t == 'Settings/Network/set_hostname':
            st.hostname = a['hostname']
            return [{'target': 'Settings/Network/hostname', 'hostname': st.hostname}]
        if t == 'Settings/DateTime/set_timezone':
            st.tz = a['timezone']
            return [{'target': 'Settings/DateTime/status', 'timezone': st.tz}]
        if t == 'Scheduler/playlists':
            return [{'target': t, 'playlists': self._plist()}]
        if t == 'Scheduler/create_playlist':
            st.playlists[uuid.uuid4().hex[:8]] = {'name': a['name'], 'assets': [], 'dd': 30}
            return [{'target': 'Scheduler/playlists', 'playlists': self._plist()}]
        if t == 'Scheduler/rename_playlist':
            st.playlists[a['playlist_id']]['name'] = a['name']
            return []
        if t == 'Scheduler/set_default_playlist':
            st.default = a['playlist_id'] if a['playlist_id'] in st.playlists else (_ for _ in ()).throw(KeyError('pl'))
            return []
        if t == 'Scheduler/files':
            return [{'target': t, 'files': {n: {'filename': n} for n in st.files}}]
        if t == 'Scheduler/delete_files':
            for n in a['files']:
                st.files.pop(n, None)
                for p in st.playlists.values():
                    p['assets'] = [x for x in p['assets'] if x['url'] != 'file:' + n]
            return []
        if t == 'Scheduler/assets':
            p = st.pl(a.get('playlist_id'))
            return [{'target': t, 'playlist_id': a.get('playlist_id'), 'items': [dict(x) for x in p['assets']]}]
        if t == 'Scheduler/delete_asset':
            p = st.pl(a.get('playlist_id'))
            p['assets'] = [x for x in p['assets'] if x['uuid'] != a['uuid']]
            return []
        if t == 'Scheduler/add_url_assets':
            for e in a['items']:
                st.pl(a.get('playlist_id'))['assets'].append(
                    {'uuid': uuid.uuid4().hex, 'name': '', 'url': e['url'], 'duration': e.get('duration', 30),
                     'enabled': e.get('enabled', False)})
            return []
        if t == 'Scheduler/add_file_assets':
            bad = []
            for e in a['items']:
                if e['url'] in st.files:
                    st.pl(a.get('playlist_id'))['assets'].append(
                        {'uuid': uuid.uuid4().hex, 'name': e['url'], 'url': 'file:' + e['url'],
                         'duration': e.get('duration', 0), 'enabled': e.get('enabled', False)})
                else:
                    bad.append(e)
            return [{'target': t, 'error': 'Invalid elements', 'extra': bad}] if bad else []
        if t == 'Scheduler/edit_asset':
            p = st.pl(a.get('playlist_id'))
            asset = next(x for x in p['assets'] if x['uuid'] == a['uuid'])
            for k in ('name', 'duration', 'enabled'):
                if k in a:
                    asset[k] = a[k]
            return []
        if t == 'Scheduler/reorder_assets':
            p = st.pl(a.get('playlist_id'))
            p['assets'].insert(a['to_i'], p['assets'].pop(a['from_i']))
            return []
        if t == 'Scheduler/default_duration':
            return [{'target': t, 'duration': st.pl(a.get('playlist_id'))['dd']}]
        if t == 'Scheduler/set_default_duration':
            st.pl(a.get('playlist_id'))['dd'] = a['duration']
            return [{'target': 'Scheduler/default_duration', 'duration': a['duration']}]
        if t == 'Viewers/list':
            return [{'target': t, 'viewers': {'local-webview': {'windows': [dict(w) for w in st.windows]}}, 'playlists': self._plist()}]
        if t == 'Viewers/assign_playlist':
            if a['playlist_id'] not in st.playlists:
                raise KeyError('playlist')
            next(w for w in st.windows if w['window_id'] == a['window_id'])['assigned_playlist'] = a['playlist_id']
            return []
        if t == 'Settings/Timers/jobs':
            return [{'target': t, 'jobs': [dict(j) for j in st.jobs], 'actions': ['pwr', 'reb']}]
        if t == 'Settings/Timers/add_job':
            st.jobs.append({'uuid': uuid.uuid4().hex, 'command': a['command'], 'minute': a['minute'], 'hour': a['hour'],
                            'day_of_month': a['day_of_month'], 'month': a['month'], 'day_of_week': a['day_of_week'],
                            'enabled': True, 'output': a.get('output'), 'mechanism': a.get('mechanism', 'auto')})
            return [{'target': 'Settings/Timers/jobs', 'jobs': [dict(j) for j in st.jobs]}]
        if t == 'Settings/Timers/set_job_enabled':
            next(j for j in st.jobs if j['uuid'] == a['uuid'])['enabled'] = a['state']
            return []
        raise KeyError(t)


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass        # a client closing its connection is not a test failure


class Fake:
    def __init__(self, tmp):
        self.state = State()
        self.cert = Path(tmp, 'c.pem')
        key = Path(tmp, 'k.pem')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out',
                        str(self.cert), '-days', '2', '-subj', '/CN=fake'], check=True, capture_output=True)
        der = ssl.PEM_cert_to_DER_cert(self.cert.read_text())
        self.fingerprint = hashlib.sha256(der).hexdigest()
        self.httpd = Server(('127.0.0.1', 0), Handler)
        self.httpd.state = self.state
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(self.cert), str(key))
        self.httpd.socket = ctx.wrap_socket(self.httpd.socket, server_side=True)
        self.url = 'https://127.0.0.1:%d' % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


CONF = {
    'urls': [
        {'url': 'file:b.jpg', 'duration': 10, 'enabled': False},
        {'url': 'http://example.invalid/a', 'duration': 10, 'enabled': False},
        {'url': 'file:a.png', 'duration': 15, 'enabled': True},
        {'url': 'https://example.invalid/c', 'duration': 30, 'enabled': True},
    ],
    'default_duration': 15,
    'users': {'admin': {'pass': 'pbkdf2:x'}},
}


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='imp2-')
        self.src = Path(self.tmp, 'src')
        (self.src / 'uploaded').mkdir(parents=True)
        (self.src / 'uploaded' / 'a.png').write_bytes(b'AAAA')
        (self.src / 'uploaded' / 'b.jpg').write_bytes(b'BBBB')
        (self.src / 'uploaded' / 'unused.jpg').write_bytes(b'UUUU')
        (self.src / 'unitotem.conf').write_text(json.dumps(CONF))
        (self.src / 'hostname').write_text('PianoTerra\n')
        (self.src / 'timezone').write_text('Europe/Rome\n')
        self.pwfile = Path(self.tmp, 'pw')
        self.pwfile.write_text(PASSWORD + '\n')
        self.fake = Fake(self.tmp)
        os.environ.update(UNITOTEM_URL=self.fake.url, UNITOTEM_USER='admin', UNITOTEM_PASSWORD_FILE=str(self.pwfile))
        self.logfile = Path(self.tmp, 'log')
        self.handler = logging.FileHandler(self.logfile)
        self.handler.setFormatter(logging.Formatter('%(levelname)s %(message)s'))
        logging.getLogger().setLevel(logging.INFO)
        logging.getLogger().addHandler(self.handler)

    def tearDown(self):
        logging.getLogger().removeHandler(self.handler)
        self.handler.close()
        self.fake.close()
        shutil.rmtree(self.tmp)

    def run_main(self, *extra):
        return imp2.main(['--source', str(self.src), '--fingerprint', self.fake.fingerprint, *extra])

    def items(self):
        return self.fake.state.playlists[self.fake.state.default]['assets']

    def mutations(self):
        return [e for e in self.fake.state.log if e[0] not in (
            'Scheduler/playlists', 'Scheduler/files', 'Scheduler/assets', 'Scheduler/default_duration',
            'Settings/Network/hostname', 'Settings/DateTime/status', 'Viewers/list', 'Settings/Timers/jobs')]

    def test_import_order_flags_media_settings(self):
        self.assertEqual(self.run_main(), 0)
        items = self.items()
        self.assertEqual([i['url'] for i in items], [c['url'] for c in CONF['urls']])
        self.assertEqual([i['enabled'] for i in items], [False, False, True, True])
        self.assertEqual([i['duration'] for i in items], [10, 10, 15, 30])
        st = self.fake.state
        self.assertEqual(st.playlists[st.default]['name'], 'PianoTerra')
        self.assertEqual(len(st.playlists), 1)       # the empty default playlist was renamed
        self.assertEqual(st.playlists[st.default]['dd'], 15)
        self.assertEqual(sorted(st.files), ['a.png', 'b.jpg', 'unused.jpg'])
        self.assertEqual((st.hostname, st.tz), ('PianoTerra', 'Europe/Rome'))

    def test_rerun_changes_nothing(self):
        self.assertEqual(self.run_main(), 0)
        before = [dict(i) for i in self.items()]
        self.fake.state.log.clear()
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.items(), before)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(len(self.fake.state.files), 3)

    def test_rerun_repairs_drift_without_duplicates(self):
        self.assertEqual(self.run_main(), 0)
        items = self.items()
        items[0]['enabled'] = True
        items[2]['duration'] = 99
        items.reverse()
        items.append({'uuid': 'zz', 'name': '', 'url': 'http://extra.invalid/', 'duration': 1, 'enabled': True})
        items.pop(1)                                  # a wanted item is missing
        self.assertEqual(self.run_main(), 0)
        self.assertEqual([i['url'] for i in self.items()], [c['url'] for c in CONF['urls']])
        self.assertEqual([i['enabled'] for i in self.items()], [False, False, True, True])
        self.assertEqual(len(self.fake.state.files), 3)

    def test_existing_media_with_other_content_is_replaced(self):
        self.fake.state.files['a.png'] = b'old'
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.fake.state.files['a.png'], b'AAAA')
        self.assertEqual(len(self.fake.state.files), 3)

    def test_checksum_mismatch_after_upload_fails(self):
        self.fake.state.corrupt.add('b.jpg')
        self.assertEqual(self.run_main(), 1)
        self.assertIn('checksum differs', self.logfile.read_text())

    def test_dry_run_changes_nothing(self):
        self.assertEqual(self.run_main('--dry-run'), 0)
        st = self.fake.state
        self.assertEqual(self.mutations(), [])
        self.assertEqual(st.files, {})
        self.assertEqual(st.playlists['p1']['name'], 'Default')
        text = self.logfile.read_text()
        self.assertIn('PLAN upload media a.png', text)
        self.assertIn('PLAN add url http://example.invalid/a', text)

    def test_password_never_logged_and_unknown_keys_warned(self):
        conf = dict(CONF, extra_key=1)
        conf['urls'] = [dict(CONF['urls'][0], weird=True)] + CONF['urls'][1:]
        (self.src / 'unitotem.conf').write_text(json.dumps(conf))
        self.assertEqual(self.run_main(), 0)
        text = self.logfile.read_text()
        self.assertNotIn(PASSWORD, text)
        self.assertNotIn('pbkdf2', text)
        self.assertIn('WARNING unknown key in unitotem.conf ignored: extra_key', text)
        self.assertIn('WARNING unknown key in item 1 ignored: weird', text)

    def test_wrong_fingerprint_is_refused(self):
        self.assertEqual(imp2.main(['--source', str(self.src), '--fingerprint', '00' * 32]), 1)
        self.assertIn('does not match', self.logfile.read_text())
        self.assertEqual(self.fake.state.files, {})

    def test_wrong_password_is_refused(self):
        self.pwfile.write_text('nope\n')
        self.assertEqual(self.run_main(), 1)
        self.assertNotIn('nope', self.logfile.read_text())

    def test_missing_media_is_an_input_error(self):
        (self.src / 'uploaded' / 'a.png').unlink()
        self.assertEqual(self.run_main(), 2)

    def test_second_playlist_is_created_when_default_has_items(self):
        self.fake.state.playlists['p1']['assets'].append(
            {'uuid': 'u1', 'name': '', 'url': 'http://other.invalid/', 'duration': 5, 'enabled': True})
        self.assertEqual(self.run_main(), 0)
        st = self.fake.state
        self.assertEqual(len(st.playlists), 2)
        self.assertEqual(len(st.playlists['p1']['assets']), 1)     # untouched
        self.assertEqual(st.playlists[st.default]['name'], 'PianoTerra')

    def test_playlist_is_assigned_to_every_window(self):
        self.assertEqual(self.run_main(), 0)
        st = self.fake.state
        self.assertEqual([w['assigned_playlist'] for w in st.windows], [st.default])

    def test_crontab_lines_become_timers(self):
        cron = Path(self.tmp, 'crontab')
        cron.write_text('# comment\n0 19 * * * /usr/sbin/poweroff # unitotem:-)7c016f92-f7cf-4f81-9f25-e913008beac8\n'
                        '#30 0 * * 1 /usr/sbin/reboot # unitotem:-)93dce1fb-2863-4abb-8786-17727a6fecea\n'
                        '5 5 * * * /usr/bin/other # unitotem:-)00000000-0000-0000-0000-000000000000\n'
                        '1 1 * * * /usr/sbin/reboot\n')
        self.assertEqual(self.run_main('--crontab', str(cron)), 0)
        jobs = self.fake.state.jobs
        self.assertEqual([(j['command'], j['hour'], j['minute'], j['day_of_week'], j['enabled']) for j in jobs],
                         [('pwr', '19', '0', '*', True), ('reb', '0', '30', '1', False)])
        self.fake.state.log.clear()
        self.assertEqual(self.run_main('--crontab', str(cron)), 0)
        self.assertEqual(self.mutations(), [])

    def test_screen_schedule_on_every_output(self):
        self.assertEqual(self.run_main('--screen-schedule', '07:30-19:30'), 0)
        jobs = self.fake.state.jobs
        self.assertEqual([(j['command'], j['hour'], j['minute'], j['day_of_week'], j['output'], j['mechanism']) for j in jobs],
                         [('scr_on', '7', '30', '1-5', 'HDMI-A-1', 'output'), ('scr_off', '19', '30', '1-5', 'HDMI-A-1', 'output')])
        self.fake.state.log.clear()
        self.assertEqual(self.run_main('--screen-schedule', '07:30-19:30'), 0)
        self.assertEqual(self.mutations(), [])

    def test_bad_schedule_is_refused_before_any_change(self):
        for spec in ('7:30-19:30', '25:00-19:30', '07:30'):
            self.assertEqual(self.run_main('--screen-schedule', spec), 2)
        self.assertEqual(self.fake.state.jobs, [])
        self.assertEqual(self.mutations(), [])


if __name__ == '__main__':
    unittest.main()
