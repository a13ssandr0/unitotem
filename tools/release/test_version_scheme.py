#!/usr/bin/env python3
"""Host-side test of the product version scheme (version.py): grammar, git tag mapping, dpkg order, and the
"newest stable tag" of fake-github.py. The dpkg cross-check runs only where dpkg is installed. fake-github is
started on 127.0.0.1 with a temporary release tree; nothing else is contacted.

  python3 tools/release/test_version_scheme.py
"""
import http.client, os, shutil, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import version as V

ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def raises(fn, *args):
    try: fn(*args)
    except V.VersionError: return True
    return False


GOOD_VERSIONS = ["2026.12", "2026.12.1", "2026.12.0", "2026.01", "2026.12.123", "2026.12~dev1", "2026.12~rc1",
                 "2026.12~rc10", "2026.12.1~rc2"]
BAD_VERSIONS = ["", "2026", "2026.1", "2026.123", "2026.12.", "2026.12.1.2", "2026.12-rc1", "2026.12~", "2026.12~rc",
                "2026.12~1", "2026.12~RC1", "2026.12~rc1.1", "2026.12~rc1~dev1", "v2026.12", "2026.12 ", " 2026.12",
                "2026.12\n", "２０２６.12", "2.3.0", "3.0.0~dev5", "9.9.9", "2026-12", "2026.12+rc1",
                "2026.12~rc1-2", None]
GOOD_TAGS = ["v2026.12", "v2026.12.1", "v2026.12-rc1", "v2026.12.1-dev2", "v2026.12-rc10"]
BAD_TAGS = ["2026.12", "v2026.12~rc1", "v2026.12-", "v2026.12-RC1", "v2026.12-rc1-2", "v2026.1", "v2026.12-rc1.1",
            "vx", "v2.3.0", "v3.0.0-dev5", "v2026.12.", "v2026.12 ", "", None]

print("== grammar")
for v in GOOD_VERSIONS:
    check(f"accept version {v!r}", V.VERSION_RE.fullmatch(v) is not None and V.validate(v) == v)
for v in BAD_VERSIONS:
    check(f"reject version {v!r}", raises(V.validate, v))
try: V.validate("2.3.0")
except V.VersionError as e: check("validate: message gives the expected forms", "YYYY.MM" in str(e) and "2.3.0" in str(e), str(e))

print("== git tags")
for v in GOOD_VERSIONS:
    t = V.tag_from_version(v)
    check(f"tag of {v!r} round trips", V.version_from_tag(t) == v, t)
    check(f"tag of {v!r} has no '~'", "~" not in t, t)
for t in GOOD_TAGS:
    check(f"accept tag {t!r}", V.version_from_tag(V.tag_from_version(V.version_from_tag(t))) == V.version_from_tag(t))
for t in BAD_TAGS:
    check(f"reject tag {t!r}", raises(V.version_from_tag, t))
check("tag_from_version: 2026.12~rc1 -> v2026.12-rc1", V.tag_from_version("2026.12~rc1") == "v2026.12-rc1")
check("tag_from_version: 2026.12.1 -> v2026.12.1 (no mapping)", V.tag_from_version("2026.12.1") == "v2026.12.1")
check("version_from_tag: v2026.12-dev1 -> 2026.12~dev1", V.version_from_tag("v2026.12-dev1") == "2026.12~dev1")
check("tag_from_version refuses an invalid version", raises(V.tag_from_version, "2026.12-rc1"))
check("version_from_tag refuses a tilde tag", raises(V.version_from_tag, "v2026.12~rc1"))
if shutil.which("git"):
    for t in ["v2026.12", "v2026.12.1", "v2026.12-rc1"]:
        r = subprocess.run(["git", "check-ref-format", "refs/tags/" + t], capture_output=True)
        check(f"git accepts the tag {t}", r.returncode == 0, r.stderr.decode())
    check("git rejects the dpkg form as a tag", subprocess.run(["git", "check-ref-format", "refs/tags/v2026.12~rc1"],
                                                              capture_output=True).returncode != 0)

print("== dpkg order")
LT = [("2026.12", "2026.12.1"), ("2026.12~rc1", "2026.12"), ("2026.12~dev1", "2026.12~rc1"), ("2026.11.66", "2026.12"),
      ("2026.12.9", "2026.12.10"), ("2026.12~rc1", "2026.12.1"), ("2026.12.1", "2026.12.2"), ("2026.12~rc2", "2026.12~rc10"),
      ("2026.12.99", "2027.01~rc1"), ("2026.12~rc1", "2026.12.0"), ("2026.11.99", "2026.12~dev1")]
for a, b in LT:
    check(f"order {a} < {b}", V.compare(a, b) < 0 and V.compare(b, a) > 0)
check("order: 2026.12 == 2026.12", V.compare("2026.12", "2026.12") == 0)
check("order: 2026.12.1 == 2026.12.1", V.compare("2026.12.1", "2026.12.1") == 0)
check("sort key: releases, fixes and pre-releases in order",
      sorted(["2026.12.10", "2026.12", "2026.12.9", "2026.12~rc1", "2026.11.66", "2026.12.1", "2026.12~dev1"], key=V.key)
      == ["2026.11.66", "2026.12~dev1", "2026.12~rc1", "2026.12", "2026.12.1", "2026.12.9", "2026.12.10"])

if shutil.which("dpkg"):
    pairs = [(a, b) for a in GOOD_VERSIONS + ["2026.12.9", "2026.12.10", "2026.11.66", "2027.01"] for b in GOOD_VERSIONS + ["2026.12.9", "2026.12.10", "2026.11.66", "2027.01"]]
    mism = []
    for a, b in pairs:
        lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
        eq = subprocess.run(["dpkg", "--compare-versions", a, "eq", b]).returncode == 0
        c = V.compare(a, b)
        if lt != (c < 0) or eq != (c == 0): mism.append((a, b))
    check(f"dpkg cross-check: {len(pairs)} pairs agree with dpkg --compare-versions", not mism, str(mism[:5]))
else:
    print("SKIP: dpkg not installed: no cross-check")

print("== fake-github: newest stable tag")
FG = os.path.join(HERE, "fake-github.py")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def latest(port):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("GET", "/o/r/releases/latest/download/manifest.json")
    r = c.getresponse(); loc = r.getheader("Location"); r.read(); c.close()
    return r.status, loc


with tempfile.TemporaryDirectory() as td:
    root = os.path.join(td, "rel")
    os.makedirs(root)
    for t in ["v2026.11.66", "v2026.12", "v2026.12.1", "v2026.12.9", "v2026.12.10", "vfoo", "v3.0.0-dev5"]:
        os.makedirs(os.path.join(root, t))
        with open(os.path.join(root, t, "manifest.json"), "w") as f: f.write("{}")
    port = free_port()
    srv = subprocess.Popen([sys.executable, FG, "--root", root, "--bind", "127.0.0.1", "--port", str(port)], stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 10
        while True:
            try: latest(port); break
            except OSError:
                if time.time() > deadline: raise
                time.sleep(0.1)
        st, loc = latest(port)
        check("latest: 2026.12.10 is the newest stable (not lexical)", st == 302 and loc.endswith("/releases/download/v2026.12.10/manifest.json"), f"{st} {loc}")
        os.makedirs(os.path.join(root, "v2026.12.11-rc1"))
        open(os.path.join(root, "v2026.12.11-rc1", "PRERELEASE"), "w").close()
        open(os.path.join(root, "v2026.12.11-rc1", "manifest.json"), "w").write("{}")
        st, loc = latest(port)
        check("latest: a PRERELEASE tag is skipped", loc.endswith("/v2026.12.10/manifest.json"), f"{st} {loc}")
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/objects/v2026.12.10/manifest.json"); r = c.getresponse(); body = r.read(); c.close()
        check("objects: a release file is served", r.status == 200 and body == b"{}", str(r.status))
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/objects/vfoo/manifest.json"); r = c.getresponse(); r.read(); c.close()
        check("objects: a non-version directory is refused", r.status == 404, str(r.status))
    finally:
        srv.terminate(); srv.wait()
    root2 = os.path.join(td, "rel2")
    os.makedirs(os.path.join(root2, "v2026.12-rc1"))
    open(os.path.join(root2, "v2026.12-rc1", "manifest.json"), "w").write("{}")
    port2 = free_port()
    srv2 = subprocess.Popen([sys.executable, FG, "--root", root2, "--bind", "127.0.0.1", "--port", str(port2)], stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 10
        while True:
            try: st, loc = latest(port2); break
            except OSError:
                if time.time() > deadline: raise
                time.sleep(0.1)
        check("latest: a tag without PRERELEASE is the newest stable, even when it is -rc1",
              st == 302 and loc.endswith("/v2026.12-rc1/manifest.json"), f"{st} {loc}")
    finally:
        srv2.terminate(); srv2.wait()

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
