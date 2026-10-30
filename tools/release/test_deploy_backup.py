#!/usr/bin/env python3
"""Test of the backup the deploy takes of a target that already runs UniTotem: backup_stream (deploy/lib.sh) and backup_running_system
(deploy/remote-deploy.sh) with ssh_t replaced by a local command on a temporary directory standing for /mnt/data.

  python3 tools/release/test_deploy_backup.py
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def sh(script, **kw):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, **kw)


def func(path, name):
    """Source text of the shell function NAME from PATH."""
    out = subprocess.run(["awk", "-v", "n=" + name, '$0 ~ "^" n "\\\\(\\\\) \\\\{" {p=1} p {print} p && /^}/ {exit}', path], capture_output=True, text=True).stdout
    assert out.strip(), name
    return out


LIB = os.path.join(ROOT, "deploy/lib.sh")
RD = os.path.join(ROOT, "deploy/remote-deploy.sh")

with tempfile.TemporaryDirectory() as td:
    data = os.path.join(td, "data"); os.makedirs(data + "/upper/etc.a"); os.makedirs(data + "/unitotem")
    open(data + "/unitotem/users.json", "w").write('{"admin": "x"}')
    open(data + "/upper/etc.a/hostname", "w").write("kiosk-1\n")
    bk = os.path.join(td, "backups")
    lib = func(LIB, "backup_stream")

    r = sh(lib + f'\nbackup_stream "{bk}" demo tar -C "{data}" --numeric-owner -cf - .')
    out = r.stdout.strip()
    check("backup_stream prints the archive path and creates it", r.returncode == 0 and os.path.isfile(out), r.stderr)
    check("the archive reads back and holds the files", "unitotem/users.json" in sh(f'{"zstd" if out.endswith("zst") else "xz"} -dc "{out}" | tar -tf -').stdout)
    check("a checksum file is written next to it", os.path.isfile(os.path.join(bk, "demo.sha256")) and sh(f'cd "{bk}" && sha256sum -c demo.sha256').returncode == 0)
    check("no .part file is left", not [f for f in os.listdir(bk) if f.endswith(".part")])

    r = sh(lib + f'\nbackup_stream "{bk}" broken sh -c "tar -C {data} -cf - . ; exit 3"')
    check("a failing source command fails the backup and leaves nothing", r.returncode != 0 and not [f for f in os.listdir(bk) if f.startswith("broken")], os.listdir(bk))
    r = sh(lib + f'\nbackup_stream "{bk}" garbage echo not-a-tar-stream')
    check("a stream that is not a tar archive is refused", r.returncode != 0 and not [f for f in os.listdir(bk) if f.startswith("garbage")])

    # backup_running_system with ssh_t -> local command, /mnt/data -> the temporary directory
    pre = f'''set -u
declare -A P; P[HAVE_UNITOTEM]=1; OPT_NO_BACKUP=0; OPT_FALLBACK_ONLY=0; OPT_BACKUP_DIR="{td}/b2"; TARGET_USERHOST=root@10.0.0.9
log() {{ echo "LOG: $*"; }}; warn() {{ echo "WARN: $*"; }}; die() {{ echo "DIE: $*"; exit 1; }}
ssh_t() {{ bash -c "${{1//\\/mnt\\/data/{data}}}"; }}
'''
    body = lib + "\n" + func(RD, "backup_running_system")
    r = sh(pre + body + "\nbackup_running_system; echo done")
    got = [f for f in os.listdir(td + "/b2")] if os.path.isdir(td + "/b2") else []
    check("deploy backup: archive named after the host and the version, verified", r.returncode == 0 and any(f.startswith("unitotem-data-10.0.0.9-") and f.endswith((".tar.zst", ".tar.xz")) for f in got) and "Backup written and verified" in r.stdout, (r.stdout, r.stderr))
    check("deploy backup: not an existing UniTotem -> nothing is done", "done" in sh(pre.replace("P[HAVE_UNITOTEM]=1", "P[HAVE_UNITOTEM]=0").replace("b2", "b3") + body + "\nbackup_running_system; echo done").stdout and not os.path.isdir(td + "/b3"))
    check("deploy backup: --no-backup skips it", not os.path.isdir(td + "/b4") and "done" in sh(pre.replace("OPT_NO_BACKUP=0", "OPT_NO_BACKUP=1").replace("b2", "b4") + body + "\nbackup_running_system; echo done").stdout)
    check("deploy backup: --fallback-only writes nothing so it skips it", not os.path.isdir(td + "/b5") and "done" in sh(pre.replace("OPT_FALLBACK_ONLY=0", "OPT_FALLBACK_ONLY=1").replace("b2", "b5") + body + "\nbackup_running_system; echo done").stdout)
    r = sh(pre.replace(f'ssh_t() {{ bash -c "${{1//\\/mnt\\/data/{data}}}"; }}', 'ssh_t() { case "$1" in "[ -d /mnt/data ]"|"cat "*|"du "*) return 0;; *) return 7;; esac; }').replace("b2", "b6") + body + "\nbackup_running_system; echo done")
    check("deploy backup: a failed transfer stops the deploy (exit 1, 'DIE')", "DIE:" in r.stdout and "done" not in r.stdout, r.stdout)

    # ---- UniTotem 1.x/2.x on a single-root system: the data is spread over the ordinary root filesystem
    root = os.path.join(td, "oldroot")
    for d in ("etc/unitotem", "usr/share/unitotem-manager/static/uploaded", "var/spool/cron/crontabs", "etc/netplan", "usr/bin"):
        os.makedirs(os.path.join(root, d))
    open(root + "/etc/unitotem/playlist.json", "w").write("[]")
    open(root + "/usr/share/unitotem-manager/static/uploaded/clip.mp4", "w").write("x" * 1000)
    open(root + "/var/spool/cron/crontabs/root", "w").write("0 3 * * * /usr/sbin/reboot # unitotem:-)abc\n")
    open(root + "/etc/hostname", "w").write("old-kiosk\n")
    open(root + "/usr/bin/other", "w").write("not unitotem data")
    leg = lib + "\n" + func(RD, "backup_legacy_system")
    lpre = f'''set -u
declare -A P; P[HAVE_UNITOTEM]=0; P[LEGACY_UNITOTEM]=2.3.0; OPT_NO_BACKUP=0; OPT_FALLBACK_ONLY=0; OPT_BACKUP_DIR="{td}/l1"; TARGET_USERHOST=root@10.0.0.7
LEGACY_DATA_PATHS="etc/unitotem usr/share/unitotem-manager/static/uploaded var/spool/cron/crontabs/root etc/netplan etc/hostname etc/hosts etc/ssl/unitotem.pem etc/asound.conf etc/X11/xinit/xinitrc"
log() {{ echo "LOG: $*"; }}; warn() {{ echo "WARN: $*"; }}; die() {{ echo "DIE: $*"; exit 1; }}
ssh_t() {{ bash -c "${{1//cd \\/;/cd {root};}}"; }}
'''
    r = sh(lpre + leg + "\nbackup_legacy_system; echo done")
    arc = [f for f in os.listdir(td + "/l1")] if os.path.isdir(td + "/l1") else []
    listing = sh(f'zstd -dc "{td}/l1/{[f for f in arc if f.endswith(".tar.zst")][0]}" | tar -tf -').stdout if any(f.endswith(".tar.zst") for f in arc) else ""
    check("legacy backup: archive named unitotem-legacy-<host>-<version>", r.returncode == 0 and any(f.startswith("unitotem-legacy-10.0.0.7-2.3.0-") for f in arc), (r.stdout, r.stderr))
    check("legacy backup: settings, uploaded media, crontab, hostname are in it", all(x in listing for x in ("etc/unitotem/playlist.json", "uploaded/clip.mp4", "var/spool/cron/crontabs/root", "etc/hostname")), listing)
    check("legacy backup: files that do not exist are skipped, other files are not included", "usr/bin/other" not in listing and "etc/asound.conf" not in listing)
    check("legacy backup: not done for an A/B UniTotem or a non-UniTotem target", not os.path.isdir(td + "/l2") and not os.path.isdir(td + "/l3")
          and "done" in sh(lpre.replace("P[HAVE_UNITOTEM]=0", "P[HAVE_UNITOTEM]=1").replace("l1", "l2") + leg + "\nbackup_legacy_system; echo done").stdout
          and "done" in sh(lpre.replace("P[LEGACY_UNITOTEM]=2.3.0", "P[LEGACY_UNITOTEM]=none").replace("l1", "l3") + leg + "\nbackup_legacy_system; echo done").stdout)

print("\n%d passed, %d failed" % (ok, fail)); sys.exit(1 if fail else 0)
