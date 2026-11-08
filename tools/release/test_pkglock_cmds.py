#!/usr/bin/env python3
"""Offline tests of the network commands of tools/pkglock.py: check, snapcheck, upgrade, and the local/archive split of is_local.

apt-get and apt-cache are replaced by a fake archive: the sources file apt is given selects the repository (Debian main,
the snapshot, or the live repository). The changelog fetch is replaced too. No network, no real apt, no real lock directory:
every path is in a temporary directory.

  python3 -m unittest tools/release/test_pkglock_cmds.py
  PKGLOCK_PATH=/path/to/pkglock.py python3 -m unittest tools/release/test_pkglock_cmds.py   (another copy of the module)
"""
import argparse, contextlib, io, json, os, pathlib, shutil, subprocess, tempfile, unittest, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PKGLOCK = os.environ.get("PKGLOCK_PATH") or os.path.join(ROOT, "tools", "pkglock.py")
spec = importlib.util.spec_from_file_location("pkglock_under_test", PKGLOCK)
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
REAL_RUN = subprocess.run          # kept for non-apt calls (dpkg --compare-versions in vcmp)

SNAP_TS = "2026-10-27T19:50:56Z"
LOCK_TEXT = """# unitotem package lock v1 - test fixture
# arch: amd64
# release: trixie
# apt-snapshot: %s
# packages: 2 pinned, 1 local
curl==8.14.1-2+deb13u7
libc6==2.41-12
local unitotem==3.0.0~dev25
""" % SNAP_TS

LIVE_HOST = "https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/"
ARCHIVE_ORIGIN = "http://deb.debian.org/debian trixie/main amd64"
UPDATES_ORIGIN = "http://deb.debian.org/debian trixie-updates/main amd64"
SECURITY_ORIGIN = "http://security.debian.org/debian-security trixie-security/main amd64"
BACKPORTS_ORIGIN = "http://deb.debian.org/debian trixie-backports/main amd64"


class FakeArchive:
    """Repositories by name: repo -> {pkg: (candidate, [(version, origin line)])}. A repository can be unreachable."""

    def __init__(self):
        self.repos, self.unreachable, self.queries = {}, set(), []

    def add(self, repo, pkg, candidate, versions):
        self.repos.setdefault(repo, {})[pkg] = (candidate, versions)

    def repo_of(self, args):
        """The repository apt is pointed at: the snapshot, the live line alone, or Debian's main."""
        path = [a.split("=", 1)[1] for a in args if a.startswith("Dir::Etc::sourcelist=")][0]
        text = pathlib.Path(path).read_text()
        if "snapshot.debian.org" in text: return "snapshot"
        if "deb.debian.org" not in text and ("nvidia" in text or "raspberrypi" in text): return "live"
        return "main"

    def run(self, args, **kw):
        if not args or args[0] not in ("apt-get", "apt-cache"):
            return REAL_RUN(args, **kw)
        repo = self.repo_of(args)
        if "update" in args:
            self.queries.append(("update", repo))
            rc = 1 if repo in self.unreachable else 0
            return subprocess.CompletedProcess(args, rc, "", "" if rc == 0 else "unreachable")
        if "policy" in args:
            names = args[args.index("policy") + 1:]
            self.queries.append(("policy", names))
            return subprocess.CompletedProcess(args, 0, self._policy(repo, names), "")
        if "show" in args:
            name, _, ver = args[-1].partition("=")
            self.queries.append(("show", name))
            fn = "pool/main/%s/%s/%s_%s_amd64.deb" % (name[0], name, name, ver)
            return subprocess.CompletedProcess(args, 0, "Package: %s\nSource: %s\nVersion: %s\nFilename: %s\n" % (name, name, ver, fn), "")
        return subprocess.CompletedProcess(args, 1, "", "unsupported fake call")

    def _policy(self, repo, names):
        out = []
        table = self.repos.get(repo, {})
        for n in names:
            if n not in table: continue
            cand, versions = table[n]
            out.append("%s:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n" % (n, cand))
            for v, origin in versions:
                out.append("     %s 500\n        500 %s Packages\n" % (v, origin))
        return "".join(out)


class PkglockCommands(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="pkglock-cmds-test-")
        self.lockdir = os.path.join(self.td, "locks")
        os.makedirs(self.lockdir)
        self._saved = (P.LOCK_DIR, tempfile.tempdir, P.changelog_info, subprocess.run)
        P.LOCK_DIR = self.lockdir
        tempfile.tempdir = self.td                  # apt scratch directories of check and snapcheck stay in the test directory
        self.archive = FakeArchive()
        self.changelog = {}                         # source -> (urgency, [cves]) of the fake changelog fetch
        self.changelog_calls = []
        P.changelog_info = self._fake_changelog
        subprocess.run = self.archive.run

    def tearDown(self):
        P.LOCK_DIR, tempfile.tempdir, P.changelog_info, subprocess.run = self._saved
        shutil.rmtree(self.td, ignore_errors=True)

    def _fake_changelog(self, source, path, new, old):
        self.changelog_calls.append(source)
        return self.changelog.get(source, (None, []))

    def write_lock(self, text=LOCK_TEXT, name="amd64.lock"):
        path = os.path.join(self.td, name)
        pathlib.Path(path).write_text(text)
        return path

    def run_check(self, path, as_json=False):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = P.cmd_check(argparse.Namespace(lock=path, json=as_json))
        return rc, buf.getvalue()

    def run_snapcheck(self, path):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = P.cmd_snapcheck(argparse.Namespace(lock=path))
        return rc, buf.getvalue()

    def same_versions(self, repo="main"):
        self.archive.add(repo, "curl", "8.14.1-2+deb13u7", [("8.14.1-2+deb13u7", ARCHIVE_ORIGIN)])
        self.archive.add(repo, "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])

    # ---- check ---------------------------------------------------------------------------------------------------------------------

    def test_check_nothing_newer_exits_0(self):
        self.same_versions()
        rc, out = self.run_check(self.write_lock())
        self.assertEqual(rc, 0)
        self.assertIn("nothing newer in the archives", out)

    def test_check_security_pocket_exits_20(self):
        self.archive.add("main", "curl", "8.14.1-2+deb13u8", [("8.14.1-2+deb13u8", SECURITY_ORIGIN), ("8.14.1-2+deb13u7", ARCHIVE_ORIGIN)])
        self.archive.add("main", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        rc, out = self.run_check(self.write_lock())
        self.assertEqual(rc, 20)
        self.assertIn("SECURITY", out)
        self.assertIn("1 of them SECURITY", out)
        self.assertIn("pocket", out)

    def test_check_plain_update_exits_10(self):
        self.archive.add("main", "curl", "8.14.1-2+deb13u8", [("8.14.1-2+deb13u8", UPDATES_ORIGIN), ("8.14.1-2+deb13u7", ARCHIVE_ORIGIN)])
        self.archive.add("main", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        rc, out = self.run_check(self.write_lock())
        self.assertEqual(rc, 10)
        self.assertRegex(out, r"update\s+curl")
        self.assertIn("0 of them SECURITY", out)
        self.assertIn("Not urgent", out)

    def test_check_changelog_cve_makes_a_plain_update_security(self):
        self.archive.add("main", "curl", "8.14.1-2+deb13u8", [("8.14.1-2+deb13u8", UPDATES_ORIGIN), ("8.14.1-2+deb13u7", ARCHIVE_ORIGIN)])
        self.archive.add("main", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        self.changelog["curl"] = ("high", ["CVE-2026-1234"])
        rc, out = self.run_check(self.write_lock(), as_json=True)
        self.assertEqual(rc, 20)
        report = json.loads(out)
        self.assertEqual(report["security"], 1)
        self.assertEqual(report["updates"][0]["cves"], ["CVE-2026-1234"])
        self.assertEqual(report["updates"][0]["urgency"], "high")
        self.assertTrue(report["updates"][0]["security"])
        self.assertEqual(self.changelog_calls, ["curl"], "the changelog is read for the Debian update only")

    def test_check_backports_for_stable_lock_is_reported_not_an_update(self):
        lock = LOCK_TEXT.replace("libc6==2.41-12", "linux-image-amd64==6.12.113-1")
        self.archive.add("main", "curl", "8.14.1-2+deb13u7", [("8.14.1-2+deb13u7", ARCHIVE_ORIGIN)])
        self.archive.add("main", "linux-image-amd64", "6.12.113-1",
                         [("6.12.113-1", ARCHIVE_ORIGIN), ("7.2.11-1~bpo13+1", BACKPORTS_ORIGIN)])
        rc, out = self.run_check(self.write_lock(lock))
        self.assertEqual(rc, 0, "a backports version of a stable lock is no update")
        self.assertIn("NOT used", out)
        self.assertIn("linux-image-amd64", out)

    def test_check_apt_update_failure_exits_2(self):
        self.archive.unreachable.add("main")
        self.same_versions()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc, out = self.run_check(self.write_lock())
        self.assertEqual(rc, 2)
        self.assertIn("apt-get update failed", err.getvalue())
        self.assertEqual(out, "")

    def test_check_queries_only_the_locked_archive_packages(self):
        self.same_versions()
        self.run_check(self.write_lock())
        queried = [n for kind, arg in self.archive.queries if kind == "policy" for n in arg]
        self.assertEqual(sorted(queried), ["curl", "libc6"], "local packages never reach apt")

    def test_check_writes_nothing_into_the_lock_directory(self):
        self.same_versions()
        path = self.write_lock()
        before = pathlib.Path(path).read_text()
        self.run_check(path)
        self.assertEqual(pathlib.Path(path).read_text(), before)
        self.assertEqual(os.listdir(self.lockdir), [])

    # ---- snapcheck -----------------------------------------------------------------------------------------------------------------

    def test_snapcheck_all_in_snapshot_is_repeatable(self):
        self.same_versions("snapshot")
        rc, out = self.run_snapcheck(self.write_lock())
        self.assertEqual(rc, 0)
        self.assertIn("repeatable: all 2 locked packages are in Debian snapshot", out)

    def test_snapcheck_gone_from_snapshot_but_online_is_repeatable(self):
        self.archive.add("snapshot", "curl", "8.14.1-2+deb13u6", [("8.14.1-2+deb13u6", ARCHIVE_ORIGIN)])
        self.archive.add("snapshot", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        self.archive.add("live", "curl", "8.14.1-2+deb13u7", [("8.14.1-2+deb13u7", LIVE_HOST + " ./")])
        rc, out = self.run_snapcheck(self.write_lock())
        self.assertEqual(rc, 0, out)
        self.assertIn("1 from", out)
        self.assertIn("still online", out)

    def test_snapcheck_gone_everywhere_exits_1_and_says_upgrade(self):
        self.archive.add("snapshot", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        self.archive.add("live", "curl", "9.9.9", [("9.9.9", LIVE_HOST + " ./")])
        rc, out = self.run_snapcheck(self.write_lock())
        self.assertEqual(rc, 1)
        self.assertIn("no longer offered by any online repository", out)
        self.assertIn("curl==8.14.1-2+deb13u7", out)
        self.assertIn("pkglock.py upgrade amd64", out)

    def test_snapcheck_gone_without_live_source_exits_1(self):
        # bookworm has no live repository in pkglock: a version missing from the snapshot cannot be recovered
        lock = LOCK_TEXT.replace("release: trixie", "release: bookworm")
        self.archive.add("snapshot", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        rc, out = self.run_snapcheck(self.write_lock(lock))
        self.assertEqual(rc, 1)
        self.assertIn("NOT in snapshot", out)
        self.assertIn("curl==8.14.1-2+deb13u7", out)

    def test_snapcheck_lock_without_snapshot_exits_2(self):
        rc, out = self.run_snapcheck(self.write_lock(LOCK_TEXT.replace(SNAP_TS, "unknown")))
        self.assertEqual(rc, 2)
        self.assertIn("records no snapshot", out)

    def test_snapcheck_live_repository_unreachable_exits_2(self):
        self.archive.add("snapshot", "libc6", "2.41-12", [("2.41-12", ARCHIVE_ORIGIN)])
        self.archive.add("live", "curl", "9.9.9", [("9.9.9", LIVE_HOST + " ./")])
        self.archive.unreachable.add("live")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc, _ = self.run_snapcheck(self.write_lock())
        self.assertEqual(rc, 2)
        self.assertIn("cannot reach", err.getvalue())

    # ---- upgrade -------------------------------------------------------------------------------------------------------------------

    def test_upgrade_retires_the_lock_to_prev(self):
        path = os.path.join(self.lockdir, "amd64.lock")
        pathlib.Path(path).write_text(LOCK_TEXT)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = P.cmd_upgrade(argparse.Namespace(arch="amd64"))
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(path))
        self.assertEqual(pathlib.Path(path + ".prev").read_text(), LOCK_TEXT, "the retired lock is kept unchanged")
        self.assertIn("unitotem/locks/amd64.lock", buf.getvalue())

    def test_upgrade_without_lock_exits_1_and_changes_nothing(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = P.cmd_upgrade(argparse.Namespace(arch="arm64"))
        self.assertEqual(rc, 1)
        self.assertIn("no lock for arm64", buf.getvalue())
        self.assertEqual(os.listdir(self.lockdir), [])

    def test_upgrade_leaves_the_other_arch_alone(self):
        other = os.path.join(self.lockdir, "arm64.lock")
        pathlib.Path(other).write_text("# arch: arm64\n")
        with contextlib.redirect_stdout(io.StringIO()):
            P.cmd_upgrade(argparse.Namespace(arch="amd64"))
        self.assertTrue(os.path.exists(other))

    # ---- is_local: which versions are ours -----------------------------------------------------------------------------------------

    def test_our_packages_are_local(self):
        maint = "Alessandro Campolo <x@example.org>"
        for name, ver in [("unitotem", "3.0.0~dev25"), ("plymouth-theme-unitotem", "3.0.0~dev25"), ("python3-cefpython3", "3.0.0~dev11"),
                          ("python3-fastapi-login", "1.10.3-0unitotem1"), ("libfoo-rpt", "1.0+rpt1-local")]:
            self.assertTrue(P.is_local(name, {"version": ver, "maintainer": maint}), name)

    def test_archive_dev_version_is_not_local(self):
        # a Debian package whose version carries ~devN is an archive package: pinned, not recorded as local
        info = {"version": "2.0~dev3-1", "maintainer": "Debian Python Team <x@debian.org>"}
        self.assertFalse(P.is_local("libexample-python", info))


if __name__ == "__main__":
    unittest.main()
