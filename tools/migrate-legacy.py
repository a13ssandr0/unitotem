#!/usr/bin/env python3
"""Migrates the settings of an earlier single-root UniTotem (2.x) onto the system just deployed.

The input is the archive that `deploy/remote-deploy.sh` wrote before it replaced the disk (`unitotem-legacy-*.tar.zst`). From it the settings
file, the uploaded media, the hostname, the time zone and the marked lines of root's crontab are put in the layout of `import-unitotem2.py`,
which does the import. When the new system has no administrator yet, the one named here is created through the setup page first.

    migrate-legacy.py --archive FILE --host IP [--port N] --admin-user NAME --admin-password-file FILE [--timezone ZONE] [--playlist NAME]

The password is read from the file, never from the command line. The configuration is migrated as it was: nothing is added to it.
"""
import argparse
import hashlib
import http.client
import importlib.util
import json
import logging
import os
import re
import ssl
import subprocess
import sys
import tempfile
from pathlib import Path

log = logging.getLogger('migrate-legacy')

MEMBERS = ('etc/unitotem/unitotem.conf', 'etc/hostname', 'etc/timezone', 'usr/share/unitotem-manager/static/uploaded',
           'var/spool/cron/crontabs/root')
HOST_NAME = re.compile(r'[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?')


class Failure(Exception):
    pass


def _importer():
    path = Path(__file__).with_name('import-unitotem2.py')
    spec = importlib.util.spec_from_file_location('import_unitotem2', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def extract(archive, into):
    """Only the members the migration reads are taken out of the archive; tar refuses absolute and `..` names."""
    present = subprocess.run(['tar', '-tf', str(archive)], capture_output=True, text=True, timeout=300)
    if present.returncode != 0:
        raise Failure('cannot read the archive %s: %s' % (archive, present.stderr.strip()))
    names = [n.rstrip('/') for n in present.stdout.splitlines()]
    wanted = [m for m in MEMBERS if any(n == m or n.startswith(m + '/') for n in names)]
    if 'etc/unitotem/unitotem.conf' not in wanted:
        raise Failure('the archive holds no etc/unitotem/unitotem.conf: nothing to migrate')
    done = subprocess.run(['tar', '-xf', str(archive), '-C', str(into), '--no-same-owner', '--no-same-permissions', '--', *wanted],
                          capture_output=True, text=True, timeout=600)
    if done.returncode != 0:
        raise Failure('cannot extract the archive: %s' % done.stderr.strip())


def build_source(root, source, timezone=None):
    """Lays the extracted files out as `import-unitotem2.py --source` expects. Returns the playlist name (the hostname)."""
    source.mkdir(parents=True, exist_ok=True)
    (source / 'unitotem.conf').write_bytes((root / 'etc/unitotem/unitotem.conf').read_bytes())
    uploaded = root / 'usr/share/unitotem-manager/static/uploaded'
    (source / 'uploaded').mkdir(exist_ok=True)
    if uploaded.is_dir():
        for f in sorted(uploaded.iterdir()):
            if f.is_file() and not f.is_symlink():
                (source / 'uploaded' / f.name).write_bytes(f.read_bytes())
    host = ''
    if (root / 'etc/hostname').is_file():
        host = (root / 'etc/hostname').read_text().strip()
        (source / 'hostname').write_text(host + '\n')
    zone = timezone or ((root / 'etc/timezone').read_text().strip() if (root / 'etc/timezone').is_file() else '')
    if zone:
        (source / 'timezone').write_text(zone + '\n')
    if (root / 'var/spool/cron/crontabs/root').is_file():
        (source / 'crontab').write_bytes((root / 'var/spool/cron/crontabs/root').read_bytes())
    return host if HOST_NAME.fullmatch(host) else 'Default'


def fingerprint(host, port=443):
    """SHA-256 of the certificate the new system presents: the importer pins it for the whole run."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    import socket
    with socket.create_connection((host, port), timeout=15) as raw, ctx.wrap_socket(raw) as tls:
        return hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()


def ensure_admin(host, port, user, password, fp):
    """Creates the first administrator through /setup when the new system has none; a system that has one is left alone."""
    imp = _importer()
    conn = imp.Conn(host, port, imp.Pin(fp))
    try:
        conn.request('GET', '/login')
        status = conn.getresponse()
        location = status.getheader('Location') or ''
        status.read()
        code = status.status
    finally:
        conn.close()
    if code == 200 or not location.endswith('/setup'):
        log.info('%s already has an administrator', host)
        return
    body = json.dumps({'username': user, 'password': password})
    conn = imp.Conn(host, port, imp.Pin(fp))
    try:
        conn.request('POST', '/setup', body=body, headers={'Content-Type': 'application/json'})
        r = conn.getresponse()
        data = r.read().decode('utf-8', 'replace')
    finally:
        conn.close()
    if r.status != 200:
        raise Failure('creating the administrator failed (HTTP %d): %s' % (r.status, data[:300]))
    log.info('administrator %s created on %s', user, host)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--archive', required=True)
    p.add_argument('--host', required=True)
    p.add_argument('--port', type=int, default=443)
    p.add_argument('--admin-user', required=True)
    p.add_argument('--admin-password-file', required=True)
    p.add_argument('--timezone', help='replaces the time zone of the archive')
    p.add_argument('--playlist', help='name of the playlist (default: the hostname of the archive)')
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s', stream=sys.stderr)
    try:
        password = Path(args.admin_password_file).read_text(encoding='utf-8').splitlines()[0]
        if not password:
            raise Failure('empty password')
        with tempfile.TemporaryDirectory(prefix='unitotem-migrate-') as tmp:
            root, source = Path(tmp, 'root'), Path(tmp, 'source')
            root.mkdir()
            extract(args.archive, root)
            name = build_source(root, source, args.timezone)
            fp = fingerprint(args.host, args.port)
            ensure_admin(args.host, args.port, args.admin_user, password, fp)
            os.environ.update(UNITOTEM_URL='https://%s:%d' % (args.host, args.port), UNITOTEM_USER=args.admin_user,
                              UNITOTEM_PASSWORD_FILE=args.admin_password_file)
            cmd = ['--source', str(source), '--fingerprint', fp, '--playlist', args.playlist or name]
            if (source / 'crontab').is_file():
                cmd += ['--crontab', str(source / 'crontab')]
            return _importer().main(cmd)
    except (Failure, OSError, ssl.SSLError, http.client.HTTPException, IndexError) as e:
        log.error('%s', e)
        return 1


if __name__ == '__main__':
    sys.exit(main())
