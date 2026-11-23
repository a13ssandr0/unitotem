#!/usr/bin/env python3
"""Tests of the version comparison of unitotem-update (vercmp, vkey) against dpkg, and of the error paths for an
invalid manifest or local version. No device and no network: fetch_trusted runs on a temporary directory with
get and verify replaced by stubs. Nothing outside the temporary directory is read or written.

  python3 tools/release/test_version_compare.py
"""
import functools, importlib.machinery, importlib.util, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu_vercmp", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu_vercmp", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)


def dpkg_cmp(a, b):
    """-1, 0, 1 from dpkg --compare-versions (argument lists, no shell). dpkg exits 2 on a syntax error."""
    lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b], capture_output=True)
    eq = subprocess.run(["dpkg", "--compare-versions", a, "eq", b], capture_output=True)
    if lt.returncode not in (0, 1) or eq.returncode not in (0, 1):
        raise RuntimeError(f"dpkg rejects {a!r} or {b!r}: {lt.stderr!r}")
    if lt.returncode == 0: return -1
    if eq.returncode == 0: return 0
    return 1


# Ordering required by the version grammar: (older, newer)
ORDERED = [
    ("2026.12", "2026.12.1"),
    ("2026.12~rc1", "2026.12"),
    ("2026.12~dev1", "2026.12~rc1"),
    ("2026.11.66", "2026.12"),
    ("2026.12.9", "2026.12.10"),
    ("2026.12~dev2", "2026.12~dev10"),
    ("2026.11.54", "2026.12"),
    ("2026.12.1", "2026.12.10"),
    ("3.0.0~dev33", "2026.12"),
    ("2.3.0", "2026.12"),
    ("2026.12~dev1", "2026.12"),
    ("2026.12~rc1", "2026.12.1"),
    ("0", "2026.11.54"),
    ("2026.12.1~dev1", "2026.12.1"),
    ("1.0", "1.0a"),
    ("1.0~", "1.0"),
    ("1.0~~", "1.0~"),
    ("1.0+x", "1.0.1"),
]

for a, b in ORDERED:
    check(f"order {a} < {b}", uu.vercmp(a, b) == -1 and uu.vercmp(b, a) == 1 and uu.vkey(a) < uu.vkey(b))

EQUAL = ["2026.12", "2026.12.1", "2026.12~rc1", "0", "3.0.0~dev33", "2026.012", "2026.12.001"]
for v in EQUAL:
    check(f"equal {v}", uu.vercmp(v, v) == 0 and not (uu.vkey(v) < uu.vkey(v)) and not (uu.vkey(v) > uu.vkey(v)))
check("leading zeros equal: 2026.012 == 2026.12", uu.vercmp("2026.012", "2026.12") == 0)
check("numeric not lexical: 2026.9 < 2026.10", uu.vercmp("2026.9", "2026.10") == -1)

# Transitivity: sorted order from vkey is consistent for every triple of a sample.
SAMPLE = ["2.3.0", "3.0.0~dev33", "2026.11.54", "2026.12~dev1", "2026.12~dev2", "2026.12~dev10", "2026.12~rc1",
          "2026.12", "2026.12.1", "2026.12.9", "2026.12.10", "2026.12.1~dev1", "2026.13"]
srt = sorted(SAMPLE, key=uu.vkey)
check("transitivity: sorted sample matches the expected order",
      srt == ["2.3.0", "3.0.0~dev33", "2026.11.54", "2026.12~dev1", "2026.12~dev2", "2026.12~dev10", "2026.12~rc1",
              "2026.12", "2026.12.1~dev1", "2026.12.1", "2026.12.9", "2026.12.10", "2026.13"], str(srt))
trans_bad = [(x, y, z) for x in SAMPLE for y in SAMPLE for z in SAMPLE
             if uu.vkey(x) < uu.vkey(y) and uu.vkey(y) < uu.vkey(z) and not uu.vkey(x) < uu.vkey(z)]
check("transitivity: every triple a<b<c gives a<c", not trans_bad, str(trans_bad[:3]))
check("vkey sorts the same as cmp_to_key(vercmp)",
      sorted(SAMPLE, key=uu.vkey) == sorted(SAMPLE, key=functools.cmp_to_key(uu.vercmp)))

# Cross-check with dpkg over a table of pairs (both directions are checked by the list).
PAIRS = [(a, b) for a, b in ORDERED] + [
    ("2026.12", "2026.12"), ("2026.12.1", "2026.12"), ("2026.12.0", "2026.12"), ("2026.12.00", "2026.12.0"),
    ("2026.12~dev2", "2026.12~dev2"), ("2026.12~dev10", "2026.12~dev2"), ("2026.12~rc1", "2026.12~dev1"),
    ("2026.12~rc1", "2026.12~rc1"), ("2026.12~", "2026.12~a"), ("2026.12~a", "2026.12~0"),
    ("2026.12~1", "2026.12~a"), ("2026.12a", "2026.12"), ("2026.12", "2026.12a"), ("2026.12.a", "2026.12.1"),
    ("2026.12.1a", "2026.12.1.a"), ("2026.12.1+x", "2026.12.1"), ("2026.12.1-x", "2026.12.1"),
    ("1.0", "1.0.0"), ("1.0.0", "1.0"), ("1.10", "1.9"), ("1.9", "1.10"), ("1.01", "1.1"),
    ("1a", "1+"), ("1+", "1a"), ("1~", "1"), ("1~", "1~~"),
    ("1.0~beta1", "1.0~beta2"), ("1.0~beta10", "1.0~beta9"), ("1.0~alpha", "1.0~beta"), ("1.0~", "1.0~~"),
    ("2.3.0", "2.3.0.1"), ("2.3.0", "2.10.0"), ("2.3.0", "2026.12"), ("3.0.0~dev33", "2.3.0"),
    ("3.0.0~dev33", "3.0.0"), ("3.0.0~dev33", "3.0.0~dev34"), ("0", "0.0"), ("00", "0"), ("2026.11.54", "2026.11.5"),
    ("2026.12.1", "2026.12.1~rc1"), ("2026.12.1~rc1", "2026.12.1~rc2"), ("2026.12.2", "2026.12.10"),
    ("2026.12.10", "2026.12.2"), ("2026.1.10", "2026.10.1"), ("9", "10"),
]
check("dpkg table has at least 40 pairs", len(PAIRS) >= 40, str(len(PAIRS)))
mismatch = []
for a, b in PAIRS:
    d = dpkg_cmp(a, b)
    m = uu.vercmp(a, b)
    if d != m: mismatch.append((a, b, "dpkg", d, "vercmp", m))
check(f"dpkg cross-check over {len(PAIRS)} pairs", not mismatch, str(mismatch[:5]))

# Invalid input raises ValueError (never another exception type).
BAD = ["", " 2026.12", "2026.12 ", "2026/12", "2026,12", "é", "2026.12\n", "a" * 256, None, 12, ["2026.12"], b"2026.12"]
for bad in BAD:
    try:
        uu.vercmp(bad, "2026.12")
        raised = None
    except ValueError as e:
        raised = e
    except Exception as e:
        raised = e
    check(f"invalid input {bad!r} raises ValueError", isinstance(raised, ValueError), repr(raised))
try:
    uu.vercmp("2026.12", "")
    check("invalid second argument raises ValueError", False)
except ValueError:
    check("invalid second argument raises ValueError", True)
check("255-character version accepted", uu.vercmp("1" * 255, "1" * 255) == 0)

# Manifest and local version errors reach the updater as Fail (normal error), not a traceback.
with tempfile.TemporaryDirectory() as td:
    keys_dir = os.path.join(td, "keys"); os.makedirs(keys_dir)
    open(os.path.join(keys_dir, "root.pub"), "w").write("ROOT\n")
    state = os.path.join(td, "state"); os.makedirs(state)
    verfile = os.path.join(td, "release-version"); open(verfile, "w").write("2026.11.54\n")
    conf = dict(uu.CONF_DEFAULTS, UPDATE_KEYS_DIR=keys_dir, UPDATE_STATE_DIR=state, UPDATE_VERSION_FILE=verfile)

    real_get, real_verify = uu.get, uu.verify

    def serve(manifest_obj):
        keys_raw = json.dumps({"seq": 1, "keys": [{"pub": "K"}]}).encode()
        man_raw = json.dumps(manifest_obj).encode()
        table = {"keys.json": keys_raw, "keys.json.sig": b"s", "manifest.json": man_raw, "manifest.json.sig": b"s"}
        uu.get = lambda url: table[url.rsplit("/", 1)[1]]
        uu.verify = lambda pub, data, sig: True

    def fetch_fail(manifest_obj):
        serve(manifest_obj)
        try:
            uu.fetch_trusted(conf)
            return None
        except uu.Fail as e:
            return e.code
        except Exception as e:
            return f"traceback: {type(e).__name__}: {e}"
        finally:
            uu.get, uu.verify = real_get, real_verify

    base = {"version": "2026.12", "channel": "stable", "layout": 2, "parts": []}
    for name, bad_ver in (("missing", None), ("slash", "2026/12"), ("empty", ""), ("number", 2026), ("list", ["x"])):
        m = dict(base)
        if bad_ver is None: m.pop("version")
        else: m["version"] = bad_ver
        code = fetch_fail(m)
        check(f"manifest version {name} gives Fail bad-manifest-version", code == "bad-manifest-version", str(code))
    code = fetch_fail(["not", "a", "dict"])
    check("manifest that is not an object gives Fail bad-manifest-version", code == "bad-manifest-version", str(code))

    # A valid manifest passes the version check (fails later only if a later check is reached).
    code = fetch_fail(dict(base, min_updater=1))
    check("valid manifest version is accepted", code is None or code not in ("bad-manifest-version",), str(code))

    # Local version file: valid, empty (= 0), missing (= 0), invalid (Fail).
    open(verfile, "w").write("2026.11.54\n")
    check("current_version reads a valid file", uu.current_version(conf) == "2026.11.54")
    open(verfile, "w").write("\n")
    check("empty version file is 0", uu.current_version(conf) == "0")
    os.unlink(verfile)
    check("missing version file is 0", uu.current_version(conf) == "0")
    open(verfile, "w").write("2026/11\n")
    try:
        uu.current_version(conf)
        check("invalid version file raises Fail", False)
    except uu.Fail as e:
        check("invalid version file raises Fail bad-version-file", e.code == "bad-version-file", e.code)

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
