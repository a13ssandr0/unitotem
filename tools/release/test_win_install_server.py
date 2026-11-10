#!/usr/bin/env python3
# Tests for tools/win-install-server.py. Local only: 127.0.0.1 on an ephemeral port,
# temp dirs for state and payload. No real key file, state dir or template is touched.

import copy
import hashlib
import http.client
import importlib.util
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_PATH = os.path.join(TOOLS, 'win-install-server.py')
REAL_TEMPLATE = os.path.join(TOOLS, 'windows-installer', 'bootstrap.ps1.tmpl')

_spec = importlib.util.spec_from_file_location('win_install_server', SERVER_PATH)
srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(srv)

ZIP_DIR = 'unitotem-windows-installer/'
ENGINE = "# fake engine\nWrite-Output 'Install-UniTotem fake'\n"
TEST_TEMPLATE = (
    'server=@SERVER@ sha=@SHA256@ bytes=@BYTES@ timeout=@TIMEOUT@ poll=@POLL@\n'
    '@ENGINE@'
)
KEY_LINE = 'ssh-ed25519 ' + 'A' * 68 + ' test@example'
WORD_A = 'WIPE-DESKTOP-ABC-DISK0-S4EVNX0N'


def make_zip(path, engine=ENGINE, drop=(), blob=None):
    if blob is None:
        blob = random.Random(1).randbytes(300000)
    entries = {
        ZIP_DIR + 'Install-UniTotem.ps1': engine.encode('ascii'),
        ZIP_DIR + 'payload/SHA256SUMS': b'0000  file\n',
        ZIP_DIR + 'payload/blob.bin': blob,
    }
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in entries.items():
            if name in drop:
                continue
            z.writestr(name, data)
    return path


def inventory(machine='MACHINE-AAAA', hostname='DESKTOP-ABC', serial='S4EVNX0N123456A ',
              number=0, model='Disk model', os_name='Windows 11 Pro'):
    return {
        'machine': machine,
        'hostname': hostname,
        'ips': ['192.168.1.20'],
        'firmware': 'uefi',
        'secureboot': 'off',
        'bitlocker': [{'drive': 'C', 'status': 'off'}],
        'boot_free_mb': 512,
        'system_disk': number,
        'os': os_name,
        'disks': [{
            'number': number, 'model': model, 'size_gb': 500.0, 'style': 'GPT',
            'serial': serial, 'unique_id': 'uid-1', 'bus': 'NVMe', 'system': True,
            'partitions': [{'number': 1, 'letter': 'C', 'size_mb': 100.0, 'type': 'EFI'}],
        }],
    }


class ServerCase(unittest.TestCase):
    key_path_name = 'missing.pub'

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='win-srv-test-')
        self.payload = make_zip(os.path.join(self.tmp, 'payload.zip'))
        self.template = os.path.join(self.tmp, 'bootstrap.tmpl')
        with open(self.template, 'w', encoding='utf-8') as f:
            f.write(TEST_TEMPLATE)
        self.state = os.path.join(self.tmp, 'state')
        self.key = os.path.join(self.tmp, self.key_path_name)
        self.lines = []
        self.clock_value = 1000.0
        self.ctx = srv.Context(self.payload, self.state, self.key, 60, template=self.template,
                               out=self.lines.append, clock=lambda: self.clock_value,
                               poll_interval=0.05)
        self.ctx.start_background()
        self.server = srv.make_server('127.0.0.1', 0, self.ctx)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.ctx.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def req(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            return resp.status, dict(resp.getheaders()), resp.read()
        finally:
            conn.close()

    def post_json(self, path, obj):
        return self.req('POST', path, json.dumps(obj).encode('utf-8'),
                        {'Content-Type': 'application/json'})

    def output(self):
        return '\n'.join(self.lines)

    def approval(self, machine):
        status, _, body = self.req('GET', '/approval?machine=' + machine)
        self.assertEqual(status, 200)
        return json.loads(body)

    def wait_for(self, cond, timeout=6.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if cond():
                return True
            time.sleep(0.05)
        return False


class BootstrapTests(ServerCase):
    def test_placeholders_replaced(self):
        status, _, body = self.req('GET', '/')
        self.assertEqual(status, 200)
        text = body.decode('utf-8')
        for name in ('SERVER', 'SHA256', 'BYTES', 'TIMEOUT', 'POLL', 'ENGINE'):
            self.assertNotIn('@' + name + '@', text)
        self.assertIn('server=http://127.0.0.1:%d ' % self.port, text)
        self.assertIn('timeout=60 poll=5', text)
        self.assertIn('Install-UniTotem fake', text)
        size = os.path.getsize(self.payload)
        self.assertIn('bytes=%d ' % size, text)

    def test_payload_matches_bootstrap_sha(self):
        _, _, boot = self.req('GET', '/')
        sha = re.search(r'sha=([0-9a-f]{64})', boot.decode('utf-8')).group(1)
        status, headers, data = self.req('GET', '/payload.zip')
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'application/zip')
        self.assertEqual(int(headers['Content-Length']), len(data))
        self.assertEqual(hashlib.sha256(data).hexdigest(), sha)
        with open(self.payload, 'rb') as f:
            self.assertEqual(data, f.read())

    def test_range_resume(self):
        _, _, full = self.req('GET', '/payload.zip')
        n = len(full)
        status, headers, part = self.req('GET', '/payload.zip', headers={'Range': 'bytes=1000-'})
        self.assertEqual(status, 206)
        self.assertEqual(part, full[1000:])
        self.assertEqual(headers['Content-Range'], 'bytes 1000-%d/%d' % (n - 1, n))
        status, _, _ = self.req('GET', '/payload.zip', headers={'Range': 'bytes=%d-' % n})
        self.assertEqual(status, 416)
        status, _, body = self.req('GET', '/payload.zip', headers={'Range': 'bytes=5-10'})
        self.assertEqual(status, 200)
        self.assertEqual(body, full)

    def test_first_fetch_message_once(self):
        self.req('GET', '/')
        self.req('GET', '/')
        msg = 'client 127.0.0.1 fetched the bootstrap'
        self.assertEqual(self.lines.count(msg), 1)

    def test_other_paths_404(self):
        self.assertEqual(self.req('GET', '/nope')[0], 404)
        self.assertEqual(self.req('POST', '/approval', b'{}', {'Content-Type': 'application/json'})[0], 404)
        self.assertEqual(self.req('GET', '/inventory')[0], 404)

    def test_real_template_has_placeholders(self):
        self.assertTrue(os.path.isfile(REAL_TEMPLATE), 'bootstrap.ps1.tmpl is missing')
        srv.load_template(REAL_TEMPLATE)


class InventoryTests(ServerCase):
    def test_valid_inventory_prints_word(self):
        status, _, body = self.post_json('/inventory', inventory())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {'ok': True})
        out = self.output()
        self.assertIn('Confirmation word for system disk 0: ' + WORD_A, out)
        self.assertIn('type that word here', out.lower())
        self.assertIn('--approve WORD', out)

    def test_schema_rejections(self):
        def drop_os(d): del d['os']
        def extra(d): d['extra'] = 1
        def firmware(d): d['firmware'] = 'efi'
        def secureboot(d): d['secureboot'] = 'maybe'
        def bool_as_int(d): d['system_disk'] = True
        def neg_free(d): d['boot_free_mb'] = -1
        def short_machine(d): d['machine'] = 'short'
        def bad_host(d): d['hostname'] = 'bad host'
        def long_host(d): d['hostname'] = 'A' * 16
        def bad_ip(d): d['ips'] = ['999.1.1.1']
        def many_ips(d): d['ips'] = ['10.0.0.1'] * 65
        def many_disks(d):
            base = d['disks'][0]
            d['disks'] = [dict(copy.deepcopy(base), number=i) for i in range(65)]
        def many_parts(d):
            d['disks'][0]['partitions'] = [{'number': i, 'letter': '', 'size_mb': 1.0, 'type': 'x'}
                                           for i in range(65)]
        def bad_disk_number(d): d['disks'][0]['number'] = 'x'
        def missing_system(d): d['system_disk'] = 7
        def nan_size(d): d['disks'][0]['size_gb'] = float('nan')
        def bad_drive(d): d['bitlocker'] = [{'drive': 'CC', 'status': 'on'}]
        def dup_disk(d): d['disks'].append(copy.deepcopy(d['disks'][0]))
        def bad_letter(d): d['disks'][0]['partitions'][0]['letter'] = '12'

        cases = [drop_os, extra, firmware, secureboot, bool_as_int, neg_free, short_machine,
                 bad_host, long_host, bad_ip, many_ips, many_disks, many_parts, bad_disk_number,
                 missing_system, nan_size, bad_drive, dup_disk, bad_letter]
        for fn in cases:
            with self.subTest(case=fn.__name__):
                d = inventory()
                fn(d)
                status, _, _ = self.post_json('/inventory', d)
                self.assertEqual(status, 400)
        self.assertEqual(self.ctx.inventories, {})

    def test_raw_body_rejections(self):
        h = {'Content-Type': 'application/json'}
        self.assertEqual(self.req('POST', '/inventory', b'{', h)[0], 400)
        self.assertEqual(self.req('POST', '/inventory', b'{"a":1,"a":2}', h)[0], 400)
        self.assertEqual(self.req('POST', '/inventory', b'{"a":NaN}', h)[0], 400)
        self.assertEqual(self.req('POST', '/inventory', b'{}', {'Content-Type': 'text/plain'})[0], 415)

    def test_missing_content_length_411(self):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        conn.putrequest('POST', '/inventory')
        conn.putheader('Content-Type', 'application/json')
        conn.putheader('Transfer-Encoding', 'chunked')
        conn.endheaders()
        resp = conn.getresponse()
        self.assertEqual(resp.status, 411)
        resp.read()
        conn.close()

    def test_oversized_413(self):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        conn.putrequest('POST', '/inventory')
        conn.putheader('Content-Type', 'application/json')
        conn.putheader('Content-Length', str(262145))
        conn.endheaders()
        resp = conn.getresponse()
        self.assertEqual(resp.status, 413)
        resp.read()
        conn.close()

    def test_escape_sequences_stripped(self):
        d = inventory(model='A\x1b[2J\x07B', os_name='Win\nFAKE LINE')
        self.assertEqual(self.post_json('/inventory', d)[0], 200)
        out = self.output()
        self.assertNotIn('\x1b', out)
        self.assertNotIn('\x07', out)
        self.assertIn('A[2JB', out)
        self.assertIn('WinFAKE LINE', out)
        for ch in out:
            self.assertTrue(ch == '\n' or ' ' <= ch <= '~', repr(ch))

    def test_printed_strings_capped_at_80(self):
        self.assertEqual(self.post_json('/inventory', inventory(os_name='X' * 200))[0], 200)
        self.assertIn('X' * 80, self.output())
        self.assertNotIn('X' * 81, self.output())


class ApprovalTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.assertEqual(self.post_json('/inventory', inventory())[0], 200)

    def test_wait_wrong_then_right_via_file(self):
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        self.assertEqual(self.approval('MACHINE-NOPE'), {'state': 'wait'})
        srv.write_approval(self.ctx.approvals_dir, 'WIPE-DESKTOP-ABC-DISK0-WRONGSER')
        self.assertTrue(self.wait_for(lambda: 'no pending PC has that confirmation word' in self.output()))
        self.assertEqual(os.listdir(self.ctx.approvals_dir), [])
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        srv.write_approval(self.ctx.approvals_dir, WORD_A)
        self.assertTrue(self.wait_for(lambda: 'approved: DESKTOP-ABC disk 0' in self.output()))
        self.assertEqual(self.approval('MACHINE-AAAA'),
                         {'state': 'approved', 'disk': 0, 'word': WORD_A})

    def test_approval_bound_to_machine(self):
        self.assertEqual(self.post_json('/inventory',
                                        inventory(machine='MACHINE-BBBB', hostname='LAPTOP-XYZ',
                                                  serial='OTHER123'))[0], 200)
        self.ctx.apply_word(WORD_A, 'stdin')
        self.assertEqual(self.approval('MACHINE-AAAA')['state'], 'approved')
        self.assertEqual(self.approval('MACHINE-BBBB'), {'state': 'wait'})

    def test_bad_machine_id_400(self):
        self.assertEqual(self.req('GET', '/approval?machine=bad')[0], 400)
        self.assertEqual(self.req('GET', '/approval')[0], 400)
        self.assertEqual(self.req('GET', '/approval?machine=MACHINE-AAAA&machine=MACHINE-BBBB')[0], 400)

    def test_not_approvable_over_http(self):
        status, _, _ = self.post_json('/approval', {'machine': 'MACHINE-AAAA', 'word': WORD_A})
        self.assertIn(status, (404, 405))
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        status, _, body = self.req('GET', '/approval?machine=MACHINE-AAAA&word=' + WORD_A)
        self.assertEqual(json.loads(body), {'state': 'wait'})

    def test_word_change_revokes_approval(self):
        self.ctx.apply_word(WORD_A, 'stdin')
        self.assertEqual(self.approval('MACHINE-AAAA')['state'], 'approved')
        self.assertEqual(self.post_json('/inventory', inventory(serial='ZZZZ9999'))[0], 200)
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})

    def test_ambiguous_word_approves_nothing(self):
        self.assertEqual(self.post_json('/inventory', inventory(machine='MACHINE-CCCC'))[0], 200)
        self.ctx.apply_word(WORD_A, 'stdin')
        self.assertIn('more than one PC has that confirmation word', self.output())
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        self.assertEqual(self.approval('MACHINE-CCCC'), {'state': 'wait'})


class StatusTests(ServerCase):
    def test_status_printed_sanitised(self):
        self.assertEqual(self.post_json('/inventory', inventory())[0], 200)
        status, _, _ = self.post_json('/status', {'machine': 'MACHINE-AAAA', 'level': 'ok',
                                                  'text': 'Partitioning\x1b[0m done'})
        self.assertEqual(status, 200)
        self.assertIn('[DESKTOP-ABC] Partitioning[0m done', self.output())

    def test_status_unknown_machine_uses_id(self):
        status, _, _ = self.post_json('/status', {'machine': 'UNKNOWN-0001', 'level': 'info',
                                                  'text': 'hi'})
        self.assertEqual(status, 200)
        self.assertIn('[UNKNOWN-0001] hi', self.output())

    def test_status_bad_level(self):
        status, _, _ = self.post_json('/status', {'machine': 'UNKNOWN-0001', 'level': 'warn',
                                                  'text': 'hi'})
        self.assertEqual(status, 400)

    def test_status_rate_limit(self):
        body = {'machine': 'UNKNOWN-0001', 'level': 'info', 'text': 'x'}
        for _ in range(50):
            self.assertEqual(self.post_json('/status', body)[0], 200)
        self.assertEqual(self.post_json('/status', body)[0], 429)
        self.clock_value += 1.0
        self.assertEqual(self.post_json('/status', body)[0], 200)


class ConfirmWordTests(unittest.TestCase):
    def test_vectors(self):
        self.assertEqual(srv.confirm_word('desktop-ABC', 0, 'S4EVNX0N123456A '),
                         'WIPE-DESKTOP-ABC-DISK0-S4EVNX0N')
        self.assertEqual(srv.confirm_word('pc_1', 2, ''), 'WIPE-PC1-DISK2-NOSERIAL')

    def test_truncation_and_format(self):
        self.assertEqual(srv.confirm_word('ABCDEFGHIJKLMNOP', 1, 'abcdefghijk'),
                         'WIPE-ABCDEFGHIJKLMNO-DISK1-ABCDEFGH')
        self.assertEqual(srv.confirm_word('A', 12, '-_-'), 'WIPE-A-DISK12-NOSERIAL')
        word = srv.confirm_word('desktop-ABC', 0, 'S4EVNX0N')
        self.assertIsNotNone(srv.WORD_RE.fullmatch(word))


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='win-srv-payload-')
        self.state = os.path.join(self.tmp, 'state')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ctx(self, payload, key_path):
        return srv.Context(payload, self.state, key_path, 60, template=self._template(),
                           out=lambda s: None)

    def _template(self):
        path = os.path.join(self.tmp, 'bootstrap.tmpl')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(TEST_TEMPLATE)
        return path

    def test_missing_entry_rejected(self):
        p = make_zip(os.path.join(self.tmp, 'bad.zip'), drop=(ZIP_DIR + 'payload/SHA256SUMS',))
        with self.assertRaises(ValueError):
            self.ctx(p, os.path.join(self.tmp, 'none.pub'))

    def test_not_a_zip_rejected(self):
        p = os.path.join(self.tmp, 'bad.zip')
        with open(p, 'wb') as f:
            f.write(b'not a zip')
        with self.assertRaises(ValueError):
            self.ctx(p, os.path.join(self.tmp, 'none.pub'))

    def test_engine_with_quote_at_line_start_refused(self):
        p = make_zip(os.path.join(self.tmp, 'bad.zip'), engine="x\n'@\n")
        with self.assertRaises(ValueError):
            self.ctx(p, os.path.join(self.tmp, 'none.pub'))

    def test_open_mode_serves_original(self):
        p = make_zip(os.path.join(self.tmp, 'ok.zip'))
        ctx = self.ctx(p, os.path.join(self.tmp, 'none.pub'))
        try:
            self.assertIsNone(ctx.key_line)
            self.assertEqual(ctx.served_path, p)
            with open(p, 'rb') as f:
                self.assertEqual(ctx.sha, hashlib.sha256(f.read()).hexdigest())
        finally:
            ctx.close()

    def test_key_mode_adds_entry_and_cleans_up(self):
        p = make_zip(os.path.join(self.tmp, 'ok.zip'))
        key = os.path.join(self.tmp, 'key.pub')
        with open(key, 'w', encoding='ascii') as f:
            f.write(KEY_LINE + '\n')
        ctx = self.ctx(p, key)
        served = ctx.served_path
        self.assertNotEqual(served, p)
        self.assertEqual(os.stat(self.state).st_mode & 0o777, 0o700)
        with zipfile.ZipFile(served) as z:
            self.assertEqual(z.read(srv.KEY_ENTRY).decode('ascii'), KEY_LINE + '\n')
            with zipfile.ZipFile(p) as orig:
                self.assertEqual(z.read(ZIP_DIR + 'payload/blob.bin'),
                                 orig.read(ZIP_DIR + 'payload/blob.bin'))
        with open(served, 'rb') as f:
            self.assertEqual(ctx.sha, hashlib.sha256(f.read()).hexdigest())
        ctx.close()
        self.assertFalse(os.path.exists(served))

    def test_bad_key_refused(self):
        p = make_zip(os.path.join(self.tmp, 'ok.zip'))
        key = os.path.join(self.tmp, 'key.pub')
        for content in (KEY_LINE + '\n' + KEY_LINE + '\n', 'ssh-rsa AAAA user\n', ''):
            with self.subTest(content=content[:20]):
                with open(key, 'w', encoding='ascii') as f:
                    f.write(content)
                with self.assertRaises(ValueError):
                    self.ctx(p, key)


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='win-srv-cli-')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run([sys.executable, '-I', SERVER_PATH, '--state-dir', self.tmp] + list(args),
                              capture_output=True, text=True, timeout=60)

    def test_approve_writes_file_0600(self):
        res = self.run_cli('--approve', WORD_A)
        self.assertEqual(res.returncode, 0, res.stderr)
        appr = os.path.join(self.tmp, 'approvals')
        names = os.listdir(appr)
        self.assertEqual(len(names), 1)
        path = os.path.join(appr, names[0])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(path, encoding='ascii') as f:
            self.assertEqual(f.read(), WORD_A + '\n')

    def test_approve_bad_word_rejected(self):
        res = self.run_cli('--approve', 'WIPE-x-DISK0-A')
        self.assertEqual(res.returncode, 2)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, 'approvals')) and
                         os.listdir(os.path.join(self.tmp, 'approvals')))


if __name__ == '__main__':
    unittest.main(verbosity=2)
