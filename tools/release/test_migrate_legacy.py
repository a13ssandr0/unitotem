#!/usr/bin/env python3
"""tools/migrate-legacy.py against the fake device of test_import_unitotem2.py: archive in, first administrator, settings out."""
import importlib.util
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_import_unitotem2 as base          # noqa: E402

spec = importlib.util.spec_from_file_location('migrate_legacy', HERE.parent / 'migrate-legacy.py')
mig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mig)

CRON = '0 19 * * * /usr/sbin/poweroff # unitotem:-)7c016f92-f7cf-4f81-9f25-e913008beac8\n'


def make_archive(path, conf=None, with_conf=True):
    with tarfile.open(path, 'w:gz') as tar:
        def add(name, data):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        if with_conf:
            add('etc/unitotem/unitotem.conf', json.dumps(conf or base.CONF).encode())
        add('etc/hostname', b'aula-test\n')
        add('etc/timezone', b'Europe/London\n')
        add('usr/share/unitotem-manager/static/uploaded/a.png', b'AAAA')
        add('usr/share/unitotem-manager/static/uploaded/b.jpg', b'BBBB')
        add('var/spool/cron/crontabs/root', CRON.encode())
        add('etc/shadow', b'root:*:1::::::\n')           # never extracted


class MigrateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='mig-')
        self.fake = base.Fake(self.tmp)
        self.fake.state.admin = False
        self.pw = Path(self.tmp, 'pw')
        self.pw.write_text(base.PASSWORD + '\n')
        self.archive = Path(self.tmp, 'legacy.tar.gz')
        make_archive(self.archive)
        self.port = int(self.fake.url.rsplit(':', 1)[1])

    def tearDown(self):
        self.fake.close()
        shutil.rmtree(self.tmp)

    def run_main(self, *extra, archive=None):
        # the fake presents a self-signed certificate: the tool pins whatever the device presents, as for a fresh system
        return mig.main(['--archive', str(archive or self.archive), '--host', '127.0.0.1', '--port', str(self.port),
                         '--admin-user', 'admin', '--admin-password-file', str(self.pw), *extra])

    def test_admin_created_and_settings_migrated_as_they_were(self):
        self.assertEqual(self.run_main(), 0)
        st = self.fake.state
        self.assertEqual(st.setup_calls, ['admin'])
        self.assertEqual(st.playlists[st.default]['name'], 'aula-test')
        self.assertEqual((st.hostname, st.tz), ('aula-test', 'Europe/London'))
        self.assertEqual(sorted(st.files), ['a.png', 'b.jpg'])
        self.assertEqual([(j['command'], j['hour']) for j in st.jobs], [('pwr', '19')])
        self.assertEqual([w['assigned_playlist'] for w in st.windows], [st.default])
        self.assertNotIn('scr_on', [j['command'] for j in st.jobs])      # no schedule is added by the migration

    def test_timezone_option_replaces_the_archive_value(self):
        self.assertEqual(self.run_main('--timezone', 'Europe/Rome'), 0)
        self.assertEqual(self.fake.state.tz, 'Europe/Rome')

    def test_existing_administrator_is_not_created_again(self):
        self.fake.state.admin = True
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.fake.state.setup_calls, [])

    def test_archive_without_settings_is_refused(self):
        bad = Path(self.tmp, 'bad.tar.gz')
        make_archive(bad, with_conf=False)
        self.assertEqual(self.run_main(archive=bad), 1)
        self.assertEqual(self.fake.state.setup_calls, [])


if __name__ == '__main__':
    unittest.main()
