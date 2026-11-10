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


def free_port():
    import socket
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


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
        'ui_culture': 'it-IT',
        'model': 'LENOVO 20XW',
        'cpu': 'Intel(R) Core(TM) i5, 4 cores, 8 threads',
        'ram': '16.0 GB, 2 modules',
        'plan': {'where': 'boot', 'reason': 'the active partition has room'},
        'notes': [],
        'services': [{'name': 'vds', 'status': 'Stopped'}],
        'disks': [{
            'number': number, 'model': model, 'size_gb': 500.0, 'style': 'GPT',
            'serial': serial, 'unique_id': 'uid-1', 'bus': 'NVMe', 'system': True,
            'partitions': [{'number': 1, 'letter': 'C', 'size_mb': 100.0, 'type': 'EFI', 'free_mb': 60}],
        }],
    }


FAKE_PERSONAL = 'ssh-ed25519 ' + 'B' * 68 + ' personal@example'


def fake_home(case, tmp):
    # HOME and XDG_STATE_HOME point into tmp; a decoy personal key sits in ~/.ssh and must never be used.
    home = os.path.join(tmp, 'home')
    os.makedirs(os.path.join(home, '.ssh'))
    with open(os.path.join(home, '.ssh', 'id_ed25519.pub'), 'w') as f:
        f.write(FAKE_PERSONAL + '\n')
    saved = {k: os.environ.get(k) for k in ('HOME', 'XDG_STATE_HOME')}
    os.environ['HOME'] = home
    os.environ.pop('XDG_STATE_HOME', None)

    def restore():
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    case.addCleanup(restore)
    return home


class ServerCase(unittest.TestCase):
    key_file = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='win-srv-test-')
        self.home = fake_home(self, self.tmp)
        self.payload = make_zip(os.path.join(self.tmp, 'payload.zip'))
        self.template = os.path.join(self.tmp, 'bootstrap.tmpl')
        with open(self.template, 'w', encoding='utf-8') as f:
            f.write(TEST_TEMPLATE)
        self.state = os.path.join(self.tmp, 'state')
        self.key = self.key_file
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
    def test_valid_inventory_asks_yes(self):
        status, _, body = self.post_json('/inventory', inventory())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {'ok': True})
        out = self.output()
        self.assertIn('Erase this disk and install UniTotem? Type yes', out)
        self.assertIn('disk 0, Disk model', out)
        self.assertNotIn('WIPE-', out)
        self.assertNotIn('OTA key for this PC', out)

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

    def yes_twice(self):
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('yes', 'stdin')

    def test_two_yes_approve_and_bind_machine_disk_serial(self):
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        self.ctx.apply_answer('yes', 'stdin')
        self.assertIn('Last chance: erase this disk? Type yes', self.output())
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        self.ctx.apply_answer('yes', 'stdin')
        self.assertEqual(self.approval('MACHINE-AAAA'),
                         {'state': 'approved', 'machine': 'MACHINE-AAAA', 'disk': 0, 'serial': 'S4EVNX0N123456A'})
        self.assertIn('approved: (DESKTOP-ABC) disk 0', self.output())

    def test_anything_else_cancels(self):
        for answer in ('Yes', 'YES', 'y', 'no', 'yes please', ''):
            with self.subTest(answer=answer):
                self.ctx.apply_answer('yes', 'stdin')
                self.ctx.apply_answer(answer, 'stdin')
                self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
                self.ctx.apply_answer('yes', 'stdin')  # restarts at the first question
                self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
                self.ctx.apply_answer('no', 'stdin')

    def test_first_yes_then_other_cancels_and_needs_two_again(self):
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('nope', 'stdin')
        self.assertIn('cancelled: nothing was changed', self.output())
        self.ctx.apply_answer('yes', 'stdin')
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})

    def test_via_approvals_dir(self):
        srv.write_approval(self.ctx.approvals_dir, 'yes')
        srv.write_approval(self.ctx.approvals_dir, 'yes')
        self.assertTrue(self.wait_for(lambda: 'approved: (DESKTOP-ABC) disk 0' in self.output()))
        self.assertEqual(os.listdir(self.ctx.approvals_dir), [])
        self.assertEqual(self.approval('MACHINE-AAAA')['state'], 'approved')

    def test_answers_go_to_the_pc_that_reported_last(self):
        self.assertEqual(self.post_json('/inventory',
                                        inventory(machine='MACHINE-BBBB', hostname='LAPTOP-XYZ',
                                                  serial='OTHER123'))[0], 200)
        self.yes_twice()
        self.assertEqual(self.approval('MACHINE-BBBB')['state'], 'approved')
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})

    def test_new_inventory_revokes_approval(self):
        self.yes_twice()
        self.assertEqual(self.approval('MACHINE-AAAA')['state'], 'approved')
        self.assertEqual(self.post_json('/inventory', inventory(serial='ZZZZ9999'))[0], 200)
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})

    def test_bad_machine_id_400(self):
        self.assertEqual(self.req('GET', '/approval?machine=bad')[0], 400)
        self.assertEqual(self.req('GET', '/approval')[0], 400)
        self.assertEqual(self.req('GET', '/approval?machine=MACHINE-AAAA&machine=MACHINE-BBBB')[0], 400)

    def test_not_approvable_over_http(self):
        status, _, _ = self.post_json('/approval', {'machine': 'MACHINE-AAAA', 'answer': 'yes'})
        self.assertIn(status, (404, 405))
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})
        status, _, body = self.req('GET', '/approval?machine=MACHINE-AAAA&answer=yes')
        self.assertEqual(json.loads(body), {'state': 'wait'})

    def test_no_pc_waiting(self):
        ctx = srv.Context(self.payload, os.path.join(self.tmp, 'state2'), None, 60, template=self.template,
                          out=[].append)
        lines = []
        ctx.out_fn = lines.append
        ctx.apply_answer('yes', 'stdin')
        self.assertEqual(lines, ['no PC is waiting'])


class UnicodeLogTests(ServerCase):
    MSG = ('Nessun oggetto MSFT_Partition trovato con la propriet\u00e0 "DriveLetter" uguale a "C". '
           '\u00c8 gi\u00e0 cos\u00ec: \u00e0\u00e8\u00ec\u00f2\u00f9 \u20ac')

    def send(self, text):
        body = json.dumps({'machine': 'MACHINE-AAAA', 'level': 'error', 'text': text}, ensure_ascii=False)
        return self.req('POST', '/status', body.encode('utf-8'), {'Content-Type': 'application/json; charset=utf-8'})

    def test_round_trip_exact(self):
        self.post_json('/inventory', inventory())
        self.assertEqual(self.send(self.MSG)[0], 200)
        self.assertIn(self.MSG, self.output())

    def test_3000_chars_not_cut(self):
        self.post_json('/inventory', inventory())
        text = ('\u00e0bc' * 1000)
        self.assertEqual(len(text), 3000)
        self.assertEqual(self.send(text)[0], 200)
        self.assertIn(text, self.output())
        self.assertNotIn('truncated', self.output())

    def test_cut_is_marked(self):
        self.post_json('/inventory', inventory())
        self.assertEqual(self.send('x' * 5000)[0], 200)
        self.assertIn('x' * 4000 + '\u2026[truncated 1000]', self.output())

    def test_control_characters_removed(self):
        self.post_json('/inventory', inventory())
        self.assertEqual(self.send('a\x1b[31mb\x9bc\x07d\u202ee').count('x'), 0)
        out = self.output()
        self.assertIn('a[31mbcde', out)
        for ch in ('\x1b', '\x9b', '\x07', '\u202e'):
            self.assertNotIn(ch, out)

    def test_invalid_utf8_does_not_break_the_server(self):
        status, _, _ = self.req('POST', '/status', b'{"machine":"MACHINE-AAAA","level":"info","text":"a\xff\xfeb"}',
                                {'Content-Type': 'application/json'})
        self.assertEqual(status, 200)
        self.assertEqual(self.req('GET', '/approval?machine=MACHINE-AAAA')[0], 200)


class PlanTests(ServerCase):
    def test_model_cpu_ram_and_plan_shown(self):
        inv = inventory()
        inv['firmware'] = 'bios'
        inv['secureboot'] = 'na'
        inv['plan'] = {'where': 'cdrive', 'reason': 'C: is NTFS'}
        inv['notes'] = ['Safe Mode: the Storage services are stopped.']
        self.post_json('/inventory', inv)
        out = self.output()
        for text in ('Model:       LENOVO 20XW', 'CPU:         Intel', 'RAM:         16.0 GB, 2 modules',
                     'Secure Boot: n/a (legacy BIOS)', 'Plan:        cdrive - C: is NTFS',
                     'Note:        Safe Mode: the Storage services are stopped.', '60 MB free'):
            self.assertIn(text, out)

    def test_plan_none_asks_nothing(self):
        inv = inventory()
        inv['plan'] = {'where': 'none', 'reason': 'restart in normal mode'}
        self.post_json('/inventory', inv)
        self.assertIn('Cannot install on this PC: restart in normal mode', self.output())
        self.assertNotIn('Type yes', self.output())
        self.ctx.apply_answer('yes', 'stdin')
        self.assertIn('no PC is waiting', self.output())

    def test_bad_plan_rejected(self):
        inv = inventory()
        inv['plan'] = {'where': 'elsewhere', 'reason': 'x'}
        self.assertEqual(self.post_json('/inventory', inv)[0], 400)

    def test_mbr_type_labels(self):
        self.assertEqual(srv.type_label('MBR 0x07 active'), 'NTFS/exFAT (IFS) (0x07), active')
        self.assertEqual(srv.type_label('MBR 0x27'), 'Recovery (0x27)')
        self.assertEqual(srv.type_label('MBR 0x99'), 'MBR type (0x99)')


class RestartTests(ServerCase):
    def new_ctx(self, keep=False):
        lines = []
        ctx = srv.Context(self.payload, self.state, None, 60, template=self.template, out=lines.append,
                          keep_approvals=keep)
        return ctx, lines

    def test_unknown_machine_then_known(self):
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'unknown'})
        self.post_json('/inventory', inventory())
        self.assertEqual(self.approval('MACHINE-AAAA'), {'state': 'wait'})

    def test_state_persisted_atomically_without_secrets(self):
        self.post_json('/inventory', inventory())
        d = os.path.join(self.state, 'machines')
        self.assertEqual(os.stat(d).st_mode & 0o777, 0o700)
        names = os.listdir(d)
        self.assertEqual(names, ['MACHINE-AAAA.json'])
        path = os.path.join(d, names[0])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(path, encoding='utf-8') as f:
            text = f.read()
        for secret in ('PRIVATE', 'BEGIN OPENSSH', 'ssh-ed25519'):
            self.assertNotIn(secret, text)

    def test_restart_restores_inventory_not_approvals(self):
        self.post_json('/inventory', inventory())
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('yes', 'stdin')
        self.assertEqual(self.approval('MACHINE-AAAA')['state'], 'approved')
        ctx, lines = self.new_ctx()
        self.assertIn('MACHINE-AAAA', ctx.inventories)
        self.assertEqual(ctx.get_approval('MACHINE-AAAA'), {'state': 'wait'})
        text = '\n'.join(lines)
        self.assertIn('approvals must be given again', text)
        self.assertIn('Erase this disk and install UniTotem? Type yes', text)
        ctx.apply_answer('yes', 'stdin')
        ctx.apply_answer('yes', 'stdin')
        self.assertEqual(ctx.get_approval('MACHINE-AAAA')['state'], 'approved')
        ctx.close()

    def test_keep_approvals_restores_them(self):
        ctx, _ = self.new_ctx(keep=True)
        ctx.add_inventory(inventory(), '127.0.0.1')
        ctx.apply_answer('yes', 'stdin')
        ctx.apply_answer('yes', 'stdin')
        ctx.close()
        ctx2, lines = self.new_ctx(keep=True)
        self.assertEqual(ctx2.get_approval('MACHINE-AAAA')['state'], 'approved')
        self.assertNotIn('Type yes', '\n'.join(lines))
        ctx2.close()

    def test_changed_disk_invalidates_a_kept_approval(self):
        ctx, _ = self.new_ctx(keep=True)
        ctx.add_inventory(inventory(), '127.0.0.1')
        ctx.apply_answer('yes', 'stdin')
        ctx.apply_answer('yes', 'stdin')
        path = os.path.join(self.state, 'machines', 'MACHINE-AAAA.json')
        with open(path, encoding='utf-8') as f:
            doc = json.load(f)
        doc['approved']['serial'] = 'OTHER'
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(doc, f)
        ctx.close()
        ctx2, _ = self.new_ctx(keep=True)
        self.assertEqual(ctx2.get_approval('MACHINE-AAAA'), {'state': 'wait'})
        ctx2.close()

    def test_unreadable_state_file_ignored(self):
        with open(os.path.join(self.state, 'machines', 'BAD-MACHINE-1.json'), 'w') as f:
            f.write('{not json')
        ctx, lines = self.new_ctx()
        self.assertIn('ignored an unreadable state file', '\n'.join(lines))
        ctx.close()

    def test_same_inventory_again_is_idempotent(self):
        self.post_json('/inventory', inventory())
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('yes', 'stdin')
        before = len(self.lines)
        self.assertEqual(self.post_json('/inventory', inventory())[0], 200)
        self.assertEqual(self.approval('MACHINE-AAAA')['state'], 'approved')
        self.assertEqual(len(self.lines), before)

    def test_http_server_restart_keeps_the_machine(self):
        self.post_json('/inventory', inventory())
        self.server.shutdown()
        self.server.server_close()
        ctx, _ = self.new_ctx()
        server = srv.make_server('127.0.0.1', 0, ctx)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            import http.client as hc
            c = hc.HTTPConnection('127.0.0.1', server.server_port, timeout=10)
            c.request('GET', '/approval?machine=MACHINE-AAAA')
            self.assertEqual(json.loads(c.getresponse().read()), {'state': 'wait'})
            c.close()
        finally:
            server.shutdown()
            server.server_close()
            ctx.close()
            # tearDown shuts the first server down once more
            self.server = srv.make_server('127.0.0.1', 0, self.ctx)
            threading.Thread(target=self.server.serve_forever, daemon=True).start()


class DisplayTests(ServerCase):
    def test_type_labels(self):
        self.assertEqual(srv.type_label('IFS'), 'NTFS/exFAT (IFS) (IFS)')
        self.assertEqual(srv.type_label('Installable File System'), 'NTFS/exFAT (IFS) (Installable File System)')
        self.assertEqual(srv.type_label('Weird'), 'Weird')
        self.assertEqual(srv.type_label('System'), 'EFI System (System)')

    def test_partition_type_shown_with_label(self):
        inv = inventory()
        inv['disks'][0]['partitions'][0]['type'] = 'IFS'
        self.post_json('/inventory', inv)
        self.assertIn('NTFS/exFAT (IFS) (IFS)', self.output())

    def test_host_colour_stable_and_in_memory(self):
        self.ctx.color = True
        a = self.ctx.host_tag('laptop-ale')
        self.assertEqual(a, self.ctx.host_tag('laptop-ale'))
        self.assertRegex(a, r'^\x1b\[38;5;\d+m\(laptop-ale\)\x1b\[0m$')
        code = int(re.search(r'38;5;(\d+)m', a).group(1))
        self.assertIn(code, srv.PALETTE)
        self.assertNotIn(code, (0, 15, 2, 10, 82, 46, 255, 16))
        other = self.ctx.host_tag('pc-two')
        self.assertNotEqual(a, other.replace('pc-two', 'laptop-ale'))
        self.ctx.color = False
        self.assertEqual(self.ctx.host_tag('laptop-ale'), '(laptop-ale)')

    def test_questions_yellow_and_not_in_palette(self):
        self.ctx.color = True
        q = self.ctx.ask('Type yes')
        self.assertEqual(q, '\x1b[1;33mType yes\x1b[0m')
        self.ctx.color = False
        self.assertEqual(self.ctx.ask('Type yes'), 'Type yes')
        for code in (3, 11, 178, 220, 221, 226, 227, 214, 172):
            self.assertNotIn(code, srv.PALETTE)

    def test_no_colour_without_tty_or_with_no_color(self):
        self.assertFalse(srv.use_color())  # tests run without a terminal
        os.environ['NO_COLOR'] = '1'
        self.addCleanup(os.environ.pop, 'NO_COLOR', None)
        self.assertFalse(srv.use_color())


class StatusTests(ServerCase):
    def test_status_printed_sanitised(self):
        self.assertEqual(self.post_json('/inventory', inventory())[0], 200)
        status, _, _ = self.post_json('/status', {'machine': 'MACHINE-AAAA', 'level': 'ok',
                                                  'text': 'Partitioning\x1b[0m done'})
        self.assertEqual(status, 200)
        self.assertIn('(DESKTOP-ABC) Partitioning[0m done', self.output())

    def test_status_unknown_machine_uses_id(self):
        status, _, _ = self.post_json('/status', {'machine': 'UNKNOWN-0001', 'level': 'info',
                                                  'text': 'hi'})
        self.assertEqual(status, 200)
        self.assertIn('(UNKNOWN-0001) hi', self.output())

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


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='win-srv-payload-')
        self.home = fake_home(self, self.tmp)
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
            self.ctx(p, None)

    def test_not_a_zip_rejected(self):
        p = os.path.join(self.tmp, 'bad.zip')
        with open(p, 'wb') as f:
            f.write(b'not a zip')
        with self.assertRaises(ValueError):
            self.ctx(p, None)

    def test_engine_with_quote_at_line_start_refused(self):
        p = make_zip(os.path.join(self.tmp, 'bad.zip'), engine="x\n'@\n")
        with self.assertRaises(ValueError):
            self.ctx(p, None)

    def test_payload_served_unchanged_without_any_key(self):
        p = make_zip(os.path.join(self.tmp, 'ok.zip'))
        ctx = self.ctx(p, None)
        try:
            self.assertIsNone(ctx.explicit_key)
            self.assertEqual(ctx.served_path, p)
            with open(p, 'rb') as f:
                self.assertEqual(ctx.sha, hashlib.sha256(f.read()).hexdigest())
            with zipfile.ZipFile(p) as z:
                for n in z.namelist():
                    self.assertNotIn(b'ssh-ed25519', z.read(n))
        finally:
            ctx.close()

    def test_explicit_key_does_not_change_the_payload(self):
        p = make_zip(os.path.join(self.tmp, 'ok.zip'))
        key = os.path.join(self.tmp, 'key.pub')
        with open(key, 'w', encoding='ascii') as f:
            f.write(KEY_LINE + '\n')
        ctx = self.ctx(p, key)
        try:
            self.assertEqual(ctx.explicit_key, KEY_LINE)
            self.assertEqual(ctx.served_path, p)
        finally:
            ctx.close()

    def test_bad_key_refused(self):
        p = make_zip(os.path.join(self.tmp, 'ok.zip'))
        key = os.path.join(self.tmp, 'key.pub')
        for content in (KEY_LINE + '\n' + KEY_LINE + '\n', 'ssh-rsa AAAA user\n', ''):
            with self.subTest(content=content[:20]):
                with open(key, 'w', encoding='ascii') as f:
                    f.write(content)
                with self.assertRaises(ValueError):
                    self.ctx(p, key)


class MachineKeyTests(ServerCase):
    def approve(self, machine='MACHINE-AAAA'):
        self.post_json('/inventory', inventory(machine=machine))
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('yes', 'stdin')

    def key_files(self):
        base = os.path.join(self.home, '.local', 'state', 'unitotem-deploy', '127.0.0.1')
        return base, os.path.join(base, 'id_ed25519')

    def test_key_per_machine_in_deploy_layout_with_modes(self):
        self.post_json('/inventory', inventory())
        base, key = self.key_files()
        self.assertEqual(os.stat(base).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(key).st_mode & 0o777, 0o600)
        with open(key + '.pub') as f:
            self.assertIn('unitotem-deploy', f.read())
        self.assertNotIn('OTA key', self.output())

    def test_key_only_after_approval_and_only_the_public_part(self):
        self.post_json('/inventory', inventory())
        self.assertEqual(self.req('GET', '/key?machine=MACHINE-AAAA')[0], 403)
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('yes', 'stdin')
        status, _, body = self.req('GET', '/key?machine=MACHINE-AAAA')
        self.assertEqual(status, 200)
        with open(self.key_files()[1] + '.pub') as f:
            self.assertEqual(body.decode().strip(), f.read().strip())
        self.assertNotIn(b'PRIVATE', body)
        self.assertEqual(self.req('GET', '/key?machine=bad')[0], 400)
        self.assertEqual(self.req('GET', '/key?machine=MACHINE-BBBB')[0], 403)

    def test_personal_key_never_used(self):
        self.approve()
        _, _, body = self.req('GET', '/key?machine=MACHINE-AAAA')
        self.assertNotIn(FAKE_PERSONAL.split()[1].encode(), body)
        self.assertNotIn(FAKE_PERSONAL.split()[1], self.output())

    def test_next_command_printed_after_approval(self):
        self.approve()
        self.assertIn('OTA_FALLBACK_KEY=' + self.key_files()[1] + ' deploy/remote-deploy.sh recover 127.0.0.1 --parts DIR --yes',
                      self.output())

    def test_second_inventory_reuses_the_key(self):
        self.post_json('/inventory', inventory())
        with open(self.key_files()[1] + '.pub') as f:
            first = f.read()
        self.post_json('/inventory', inventory())
        with open(self.key_files()[1] + '.pub') as f:
            self.assertEqual(first, f.read())

    def test_machine_a_approval_does_not_release_b_key(self):
        self.post_json('/inventory', inventory(machine='MACHINE-BBBB', hostname='OTHERPC'))
        self.post_json('/inventory', inventory(machine='MACHINE-AAAA'))
        self.ctx.apply_answer('yes', 'stdin')
        self.ctx.apply_answer('yes', 'stdin')
        self.assertEqual(self.req('GET', '/key?machine=MACHINE-AAAA')[0], 200)
        self.assertEqual(self.req('GET', '/key?machine=MACHINE-BBBB')[0], 403)


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='win-srv-cli-')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run([sys.executable, '-I', SERVER_PATH, '--state-dir', self.tmp] + list(args),
                              capture_output=True, text=True, timeout=60)

    def test_approve_yes_twice_writes_two_files_0600(self):
        res = self.run_cli('--approve', 'yes', '--approve', 'yes')
        self.assertEqual(res.returncode, 0, res.stderr)
        appr = os.path.join(self.tmp, 'approvals')
        names = sorted(os.listdir(appr))
        self.assertEqual(len(names), 2)
        for n in names:
            path = os.path.join(appr, n)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            with open(path, encoding='ascii') as f:
                self.assertEqual(f.read(), 'yes\n')

    def test_approve_anything_else_rejected(self):
        for args in (('--approve', 'yes'), ('--approve', 'Yes', '--approve', 'Yes'),
                     ('--approve', 'yes', '--approve', 'yes', '--approve', 'yes'), ('--approve', 'WIPE-x-DISK0-A')):
            with self.subTest(args=args):
                res = self.run_cli(*args)
                self.assertEqual(res.returncode, 2)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, 'approvals')) and
                         os.listdir(os.path.join(self.tmp, 'approvals')))

    def test_startup_prints_only_the_irm_commands(self):
        p = subprocess.Popen([sys.executable, '-I', SERVER_PATH, '--state-dir', self.tmp, '--port', str(free_port()),
                              '--advertise', '127.0.0.1', '--payload', self.payload_zip()],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            out = ''
            deadline = time.time() + 15
            while time.time() < deadline and 'listening' not in out:
                out += p.stdout.readline()
        finally:
            p.terminate()
            p.wait(timeout=10)
        self.assertIn('irm http://127.0.0.1:', out)
        self.assertNotIn('-NoProfile', out)
        self.assertIn('Win+R -> powershell -> Ctrl+Shift+Enter\nthen paste the irm line', out)
        self.assertEqual(out.count('irm http://'), 1)
        for text in ('sha256', 'payload', 'OTA key', 'OTA_FALLBACK_KEY', 'key file'):
            self.assertNotIn(text, out)
        self.assertNotIn('\x1b', out)  # no colour without a terminal

    def payload_zip(self):
        return make_zip(os.path.join(self.tmp, 'p.zip'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
