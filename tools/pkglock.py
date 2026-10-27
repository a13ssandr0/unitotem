#!/usr/bin/env python3
"""pkglock - make the image's package set repeatable (like a Python requirements.txt with exact versions) and tell when something newer exists.

  pkglock.py freeze  ROOTFS|stageN.tar.gz --arch ARCH [--out FILE] [--snapshot ISO8601Z]
        write the lock from a built root filesystem: every installed package at its exact version, plus the moment of the apt index it was
        installed from (the Debian snapshot to reproduce it)
  pkglock.py prefs   LOCK                      apt preferences that pin every locked package to its version (stage 1 installs with them)
  pkglock.py snapshot LOCK                     the snapshot timestamp (YYYYMMDDTHHMMSSZ) recorded in the lock
  pkglock.py verify  LOCK ROOTFS|tarball       the installed set must be exactly the lock (exit 1 and a list of differences otherwise)
  pkglock.py snapcheck LOCK                    can the locked set be rebuilt from the recorded Debian snapshot? (lists what is gone)
  pkglock.py index   DIR [--arch A]            index a directory of .debs as a flat apt repository (the build cache, as a fallback source)
  pkglock.py upgrade ARCH                      retire the lock: the next stage-1 build resolves fresh and freezes a new one
  pkglock.py check   LOCK [--json]             ask the archives NOW what is newer than the lock; report, with urgency
        exit 0: nothing newer   10: updates, none security-related   20: security updates (the build must stop, see tools/build)

Lock line:   name==version        (an archive package, pinned)
             local name==version  (built by us - unitotem-*, the CEF wheel, the repackaged python libs - recorded, never pinned)

Urgency. apt itself carries no urgency; two real sources are used and shown separately:
  * the archive pocket: an update that comes from `<release>-security` is a SECURITY update;
  * the Debian changelog of the new version (metadata.ftp-master.debian.org): its `urgency=` field and any CVE-nnnn-nnnn it names, for every
    entry between the locked version and the new one. CVEs in the changelog make an update security-related whatever pocket it came from.
Both mark an update as SECURITY. The changelog urgency alone (low/medium/high/...) is shown but does not block. Packages whose archive publishes
no changelog (Raspberry Pi's) show urgency "n/a": only their pocket is known.
"""
import argparse, collections, concurrent.futures, datetime, json, os, re, shutil, subprocess, sys, tarfile, tempfile, urllib.request

os.environ["LC_ALL"] = "C"          # apt prints "Candidato:" in Italian: every parser below reads the English words
LOCAL_RE = re.compile(r"~dev\d+|unitotem|\+rpt\d*-local")
SECURITY_RE = re.compile(r"-security")
URGENCY_ORDER = ["low", "medium", "high", "critical", "emergency"]
WATCH_BACKPORTS = re.compile(r"^(linux-image-(amd64|rpi.*)|linux-headers-amd64|mesa-.*|libgl1-mesa-dri|nvidia-driver|nvidia-kernel-dkms|firmware-.*|labwc|"
                             r"libwlroots.*|wayvnc|pipewire|wireplumber|ffmpeg|libavcodec.*|systemd|network-manager)$")
LOCK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "unitotem", "locks")


# ------------------------------------------------------------------------------------------------------------------------------------
def vcmp(a, b):
    if a == b: return 0
    if subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0: return -1
    return 1


def read_status(src):
    """-> {name: {"version","arch","source","maintainer"}} of the installed packages in a rootfs directory, a tar(.gz) of one, or a status file."""
    if os.path.isdir(src):
        text = open(os.path.join(src, "var/lib/dpkg/status"), errors="replace").read()
    elif tarfile.is_tarfile(src):
        with tarfile.open(src) as t:
            for name in ("./var/lib/dpkg/status", "var/lib/dpkg/status"):
                try: text = t.extractfile(name).read().decode(errors="replace"); break
                except KeyError: continue
            else: raise SystemExit("no var/lib/dpkg/status in " + src)
    else:
        text = open(src, errors="replace").read()
    pk = {}
    for stanza in text.split("\n\n"):
        f = dict(re.findall(r"(?m)^([A-Za-z-]+): (.*)$", stanza))
        if not f.get("Package") or "installed" not in f.get("Status", "").split()[-1:] or f["Status"].split()[0] not in ("install", "hold"):
            continue
        pk[f["Package"]] = {"version": f.get("Version", ""), "arch": f.get("Architecture", ""), "source": f.get("Source", f["Package"]).split()[0],
                            "maintainer": f.get("Maintainer", "")}
    return pk


def apt_history_start(src):
    """The first `Start-Date` of the build's apt history (UTC): the apt index that fed the installs is from just before it."""
    try:
        if os.path.isdir(src):
            text = open(os.path.join(src, "var/log/apt/history.log")).read()
        else:
            with tarfile.open(src) as t:
                text = t.extractfile("./var/log/apt/history.log").read().decode()
        m = re.search(r"Start-Date: (\d{4}-\d\d-\d\d)\s+(\d\d:\d\d:\d\d)", text)
        return "%sT%sZ" % (m.group(1), m.group(2)) if m else None
    except (OSError, KeyError, TypeError):
        return None


def is_local(name, info):
    return bool(LOCAL_RE.search(info["version"]) or "unitotem" in info["maintainer"].lower())


def read_lock(path):
    meta, pinned, local = {}, {}, {}
    for line in open(path):
        line = line.rstrip("\n")
        if not line: continue
        if line.startswith("#"):
            m = re.match(r"# ([a-z-]+): (.*)", line)
            if m: meta[m.group(1)] = m.group(2).strip()
            continue
        loc = line.startswith("local ")
        name, _, ver = line[6:].partition("==") if loc else line.partition("==")
        (local if loc else pinned)[name.strip()] = ver.strip()
    return meta, pinned, local


# ------------------------------------------------------------------------------------------------------------------------------------
def cmd_freeze(a):
    pk = read_status(a.src)
    snap = a.snapshot or apt_history_start(a.src)
    lines = ["# unitotem package lock v1 - generated by tools/pkglock.py freeze, edit only through it",
             "# arch: %s" % a.arch, "# release: %s" % a.release,
             "# apt-snapshot: %s" % (snap or "unknown"),
             "# generated: %s" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")]
    loc = {n: i for n, i in pk.items() if is_local(n, i)}
    arc = {n: i for n, i in pk.items() if n not in loc}
    lines.append("# packages: %d pinned, %d local" % (len(arc), len(loc)))
    lines += ["%s==%s" % (n, arc[n]["version"]) for n in sorted(arc)]
    lines += ["local %s==%s" % (n, loc[n]["version"]) for n in sorted(loc)]
    out = a.out or os.path.join(LOCK_DIR, "%s.lock" % a.arch)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, "w").write("\n".join(lines) + "\n")
    print("%s: %d pinned, %d local, snapshot %s" % (out, len(arc), len(loc), snap))
    return 0


def cmd_prefs(a):
    _, pinned, _ = read_lock(a.lock)
    out = ["# generated from the package lock: pins every locked package to its exact version (see tools/pkglock.py)"]
    for n in sorted(pinned):
        out.append("Package: %s\nPin: version %s\nPin-Priority: 1001\n" % (n, pinned[n]))
    sys.stdout.write("\n".join(out) + "\n")
    return 0


def snapshot_ts(meta):
    s = meta.get("apt-snapshot", "")
    m = re.fullmatch(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z", s)
    return "".join(m.groups()[:3]) + "T" + "".join(m.groups()[3:]) + "Z" if m else ""


def cmd_snapshot(a):
    meta, _, _ = read_lock(a.lock)
    ts = snapshot_ts(meta)
    if not ts: return 1
    print(ts); return 0


def cmd_verify(a):
    meta, pinned, local = read_lock(a.lock)
    pk = read_status(a.src)
    bad = []
    for n, v in sorted(pinned.items()):
        if n not in pk: bad.append("missing   %s==%s" % (n, v))
        elif pk[n]["version"] != v: bad.append("different %s: lock %s, installed %s" % (n, v, pk[n]["version"]))
    known = set(pinned) | set(local)
    for n, i in sorted(pk.items()):
        if n not in known:
            bad.append("not locked %s==%s%s" % (n, i["version"], "  (local package)" if is_local(n, i) else ""))
    if bad:
        print("PACKAGE LOCK MISMATCH (%d):" % len(bad)); print("\n".join("  " + b for b in bad[:80]))
        if len(bad) > 80: print("  ... and %d more" % (len(bad) - 80))
        return 1
    print("package lock verified: %d pinned + %d local packages, identical" % (len(pinned), len(local)))
    return 0


# ------------------------------------------------------------------------------------------------------------------------------------
def parse_policy(text):
    """apt-cache policy output -> {pkg: {"candidate": v, "versions": {v: [origin lines]}}}"""
    res, cur, ver = {}, None, None
    for line in text.splitlines():
        if line and not line.startswith(" "):
            cur = line.rstrip(":"); res[cur] = {"candidate": None, "versions": collections.OrderedDict()}; ver = None
        elif cur is None: continue
        elif line.strip().startswith("Candidate:"):
            c = line.split(":", 1)[1].strip(); res[cur]["candidate"] = None if c == "(none)" else c
        elif re.match(r"^( \*\*\*| {1,5})\s*\S+ \d+\s*$", line) and not re.match(r"^\s{6,}", line):
            ver = line.replace("***", "").split()[0]; res[cur]["versions"][ver] = []
        elif ver and re.match(r"^\s+\d+ \S+", line):
            res[cur]["versions"][ver].append(line.strip())
    return res


def classify(entry, locked):
    """-> (candidate, origins list, newer_in_backports (version or None)) for one package."""
    cand = entry["candidate"]
    bpo = None
    for v, origs in entry["versions"].items():
        if any("backports" in o for o in origs) and vcmp(v, locked) > 0:
            if bpo is None or vcmp(v, bpo) > 0: bpo = v
    if not cand or vcmp(cand, locked) <= 0:
        return None, [], bpo
    return cand, entry["versions"].get(cand, []), bpo


def changelog_info(source, component_path, new, old):
    """Urgency and CVEs of the changelog entries newer than OLD up to NEW (Debian archive only). -> (urgency or None, [cves])"""
    ver = re.sub(r"^\d+:", "", new)
    url = "https://metadata.ftp-master.debian.org/changelogs/%s/%s_%s_changelog" % (component_path, source, ver)
    try:
        text = urllib.request.urlopen(url, timeout=25).read().decode("utf-8", "replace")
    except Exception:
        return None, []
    urg, cves, ents = None, set(), re.split(r"(?m)^(?=\S+ \([^)]*\) )", text)
    for e in ents:
        m = re.match(r"\S+ \(([^)]*)\) [^;]*; urgency=(\w+)", e)
        if not m: continue
        if vcmp(m.group(1), old) <= 0: break
        u = m.group(2).lower()
        if u in URGENCY_ORDER and (urg is None or URGENCY_ORDER.index(u) > URGENCY_ORDER.index(urg)): urg = u
        cves.update(re.findall(r"CVE-\d{4}-\d{4,7}", e))
    return urg, sorted(cves)


def apt_env(arch, release, workdir):
    for d in ("etc/apt", "state/lists/partial", "cache/archives/partial"):
        os.makedirs(os.path.join(workdir, d), exist_ok=True)
    src = ["deb [arch=%s trusted=yes] http://deb.debian.org/debian %s main contrib non-free non-free-firmware" % (arch, release),
           "deb [arch=%s trusted=yes] http://deb.debian.org/debian %s-updates main contrib non-free non-free-firmware" % (arch, release),
           "deb [arch=%s trusted=yes] http://security.debian.org/debian-security %s-security main contrib non-free non-free-firmware" % (arch, release),
           "deb [arch=%s trusted=yes] http://deb.debian.org/debian %s-backports main contrib non-free non-free-firmware" % (arch, release)]
    if arch == "arm64":
        src.append("deb [arch=arm64 trusted=yes] http://archive.raspberrypi.org/debian/ %s main" % release)
    open(os.path.join(workdir, "etc/apt/sources.list"), "w").write("\n".join(src) + "\n")
    open(os.path.join(workdir, "status"), "w").close()
    opts = ["-o", "Dir::Etc::sourcelist=%s/etc/apt/sources.list" % workdir, "-o", "Dir::Etc::sourceparts=/dev/null",
            "-o", "Dir::Etc::preferences=/dev/null", "-o", "Dir::Etc::preferencesparts=/dev/null",
            "-o", "Dir::State=%s/state" % workdir, "-o", "Dir::State::status=%s/status" % workdir, "-o", "Dir::Cache=%s/cache" % workdir,
            "-o", "APT::Architecture=%s" % arch, "-o", "APT::Architectures=%s" % arch, "-o", "Debug::NoLocking=1",
            "-o", "Acquire::Languages=none", "-o", "Acquire::Check-Valid-Until=false"]
    return opts


def cmd_check(a):
    meta, pinned, local = read_lock(a.lock)
    arch = meta.get("arch", "amd64"); release = meta.get("release", "trixie")
    tmp = tempfile.mkdtemp(prefix="pkglock-")
    try:
        opts = apt_env(arch, release, tmp)
        r = subprocess.run(["apt-get", *opts, "update", "-qq"], capture_output=True, text=True)
        if r.returncode != 0:
            print("apt-get update failed:\n" + r.stderr[-800:], file=sys.stderr); return 2
        names = sorted(pinned)
        pol = {}
        for i in range(0, len(names), 400):
            out = subprocess.run(["apt-cache", *opts, "policy", *names[i:i + 400]], capture_output=True, text=True).stdout
            pol.update(parse_policy(out))
        updates, backports = [], []
        for n in names:
            if n not in pol: continue
            cand, origs, bpo = classify(pol[n], pinned[n])
            if bpo and WATCH_BACKPORTS.match(n): backports.append((n, pinned[n], bpo))
            if cand:
                sec = any(SECURITY_RE.search(o) for o in origs)
                updates.append({"package": n, "locked": pinned[n], "new": cand, "security_pocket": sec, "origins": sorted({o.split()[1] for o in origs if len(o.split()) > 1}),
                                "urgency": None, "cves": []})
        # changelogs (Debian archive only) for the updates that come from a Debian origin
        def enrich(u):
            if not any("deb.debian.org" in o or "security.debian.org" in o for o in u["origins"]):
                return u                                  # Raspberry Pi's archive publishes no changelog: only the pocket is known
            show = subprocess.run(["apt-cache", *opts, "show", "%s=%s" % (u["package"], u["new"])], capture_output=True, text=True).stdout
            src = re.search(r"(?m)^Source: (\S+)", show); fn = re.search(r"(?m)^Filename: (\S+)", show)
            m = re.match(r"pool/(?:updates/)?([^/]+)/([^/]+)/([^/]+)/", fn.group(1)) if fn else None   # security pool: pool/updates/main/e/expat/
            if m:
                srcname = (src.group(1) if src else u["package"])
                u["urgency"], u["cves"] = changelog_info(srcname, "%s/%s/%s" % m.groups(), u["new"], u["locked"])
            return u
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            updates = list(ex.map(enrich, updates))
        for u in updates:
            u["security"] = bool(u["security_pocket"] or u["cves"])
        updates.sort(key=lambda u: (not u["security"], u["package"]))
        sec = [u for u in updates if u["security"]]
        report = {"lock": os.path.basename(a.lock), "arch": arch, "locked_snapshot": meta.get("apt-snapshot"), "packages_locked": len(pinned),
                  "updates": updates, "security": len(sec), "backports_available": backports}
        if a.json:
            print(json.dumps(report, indent=1))
        else:
            print_report(report)
        return 20 if sec else (10 if updates else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_snapcheck(a):
    """Can the locked set be rebuilt from the Debian snapshot recorded in the lock? Lists the locked versions the snapshot does not offer."""
    meta, pinned, _ = read_lock(a.lock)
    arch = meta.get("arch", "amd64"); release = meta.get("release", "trixie"); ts = snapshot_ts(meta)
    if not ts:
        print("the lock records no snapshot"); return 2
    tmp = tempfile.mkdtemp(prefix="pkglock-snap-")
    try:
        opts = apt_env(arch, release, tmp)
        src = ["deb [arch=%s trusted=yes] http://snapshot.debian.org/archive/debian/%s/ %s main contrib non-free non-free-firmware" % (arch, ts, release),
               "deb [arch=%s trusted=yes] http://snapshot.debian.org/archive/debian/%s/ %s-updates main contrib non-free non-free-firmware" % (arch, ts, release),
               "deb [arch=%s trusted=yes] http://snapshot.debian.org/archive/debian-security/%s/ %s-security main contrib non-free non-free-firmware" % (arch, ts, release)]
        if arch == "arm64":
            src.append("deb [arch=arm64 trusted=yes] http://archive.raspberrypi.org/debian/ %s main" % release)
        open(os.path.join(tmp, "etc/apt/sources.list"), "w").write("\n".join(src) + "\n")
        r = subprocess.run(["apt-get", *opts, "update", "-qq"], capture_output=True, text=True)
        if r.returncode != 0:
            print("apt-get update on the snapshot failed:\n" + r.stderr[-800:], file=sys.stderr); return 2
        names = sorted(pinned); pol = {}
        for i in range(0, len(names), 400):
            pol.update(parse_policy(subprocess.run(["apt-cache", *opts, "policy", *names[i:i + 400]], capture_output=True, text=True).stdout))
        gone = [(n, pinned[n]) for n in names if n not in pol or pinned[n] not in pol[n]["versions"]]
        if gone:
            print("%d locked versions are NOT available from snapshot %s (%d of %d ok):" % (len(gone), ts, len(names) - len(gone), len(names)))
            for n, v in gone[:60]: print("   %s==%s" % (n, v))
            return 1
        print("all %d locked packages are available from snapshot %s (+ the Raspberry Pi archive on arm64)" % (len(names), ts))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def print_report(r):
    ups = r["updates"]
    print("== package lock check: %s (locked at apt snapshot %s, %d packages)" % (r["arch"], r["locked_snapshot"], r["packages_locked"]))
    if not ups:
        print("   everything is at the locked versions: nothing newer in the archives.")
    for u in ups:
        tag = "SECURITY " if u["security"] else "update   "
        extra = []
        if u["security_pocket"]: extra.append("pocket " + ",".join(o for o in u["origins"] if SECURITY_RE.search(o)))
        else: extra.append("from " + ",".join(u["origins"][:2]))
        extra.append("urgency %s" % (u["urgency"] or "n/a"))
        if u["cves"]: extra.append("%d CVE: %s%s" % (len(u["cves"]), ", ".join(u["cves"][:4]), " ..." if len(u["cves"]) > 4 else ""))
        print("   %s %-38s %s -> %s   (%s)" % (tag, u["package"], u["locked"], u["new"], "; ".join(extra)))
    nsec = r["security"]
    print("   -- %d newer, %d of them SECURITY" % (len(ups), nsec))
    if r["backports_available"]:
        print("   -- newer major versions in backports (NOT used; a decision, not an update):")
        for n, old, new in r["backports_available"][:40]:
            print("        %-38s %s -> %s" % (n, old, new))
    if nsec:
        print("\n   *** SECURITY UPDATES PENDING: the image build is blocked until the lock is renewed (tools/pkglock.py upgrade %s)" % r["arch"])
        print("   *** or, knowingly, built anyway with PKGLOCK_ACK_SECURITY=1")
    elif ups:
        print("   Not urgent: renew the lock when you decide to (tools/pkglock.py upgrade %s); the build goes on with the locked versions." % r["arch"])


def cmd_index(a):
    """Index the .debs of a directory as a flat apt repository (Packages + Release): the build's download cache then also serves versions the
    archives dropped (the Raspberry Pi archive keeps no snapshot). Used with [trusted=yes]: local files we downloaded ourselves."""
    import hashlib
    d = a.dir; stanzas = []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".deb"): continue
        path = os.path.join(d, fn)
        ctl = subprocess.run(["dpkg-deb", "-f", path], capture_output=True, text=True)
        if ctl.returncode != 0: continue
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
        stanzas.append("%s\nFilename: ./%s\nSize: %d\nSHA256: %s\n" % (ctl.stdout.strip(), fn, os.path.getsize(path), h.hexdigest()))
    pk = "\n".join(stanzas)
    open(os.path.join(d, "Packages"), "w").write(pk)
    ph = hashlib.sha256(pk.encode()).hexdigest()
    open(os.path.join(d, "Release"), "w").write("Origin: unitotem-cache\nLabel: unitotem-cache\nSuite: cache\nCodename: cache\nDate: %s\nArchitectures: %s\nSHA256:\n %s %d Packages\n"
                                                % (datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S UTC"), a.arch, ph, len(pk.encode())))
    print("indexed %d packages in %s" % (len(stanzas), d)); return 0


def cmd_upgrade(a):
    """Retire the lock: the next stage-1 build resolves everything fresh from the live archives and writes a new lock."""
    path = os.path.join(LOCK_DIR, "%s.lock" % a.arch)
    if not os.path.exists(path):
        print("no lock for %s" % a.arch); return 1
    old = path + ".prev"
    shutil.move(path, old)
    print("lock retired (kept as %s). The next stage-1 build of %s installs the CURRENT archive versions and freezes a new lock;\n"
          "commit unitotem/locks/%s.lock afterwards." % (old, a.arch, a.arch))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    f = sp.add_parser("freeze"); f.add_argument("src"); f.add_argument("--arch", required=True); f.add_argument("--release", default="trixie")
    f.add_argument("--out"); f.add_argument("--snapshot")
    for n in ("prefs", "snapshot"):
        x = sp.add_parser(n); x.add_argument("lock")
    v = sp.add_parser("verify"); v.add_argument("lock"); v.add_argument("src")
    c = sp.add_parser("check"); c.add_argument("lock"); c.add_argument("--json", action="store_true")
    u = sp.add_parser("upgrade"); u.add_argument("arch")
    sc = sp.add_parser("snapcheck"); sc.add_argument("lock")
    ix = sp.add_parser("index"); ix.add_argument("dir"); ix.add_argument("--arch", default="amd64")
    a = ap.parse_args()
    return {"freeze": cmd_freeze, "prefs": cmd_prefs, "snapshot": cmd_snapshot, "verify": cmd_verify, "check": cmd_check, "upgrade": cmd_upgrade, "snapcheck": cmd_snapcheck, "index": cmd_index}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
