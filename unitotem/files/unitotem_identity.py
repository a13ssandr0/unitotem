"""Identity merge for A/B updates: keep the local accounts across an OTA without freezing the image's system accounts.

The web UI logs in through PAM, so its accounts are system accounts, and root's password is the one the web terminal's `login` checks.
/etc/{passwd,shadow,group,gshadow} are NOT in ota-preserve.list on purpose (whitelisting whole files would pin the image's system
accounts forever). Instead the new slot gets
    image files (base)  +  the LOCAL part of the running system's files (current)
computed here, as pure functions, and installed into the new slot's /etc overlay upper.

What is carried over (everything else comes from the image):
  - root's shadow entry (hash and aging fields);
  - root's login shell and its membership of the group unitotem-first-admin (the sshd first-access marker): from the current slot
    when it has a root passwd line and that group; the old layout keeps the image's values;
  - every account with 1000 <= uid < 65534 and its shadow entry, unless its name or uid clashes with the image (the image wins);
  - the memberships of those accounts and of root in the image's groups, and local groups with gid >= 1000 (name/gid clash: image wins).
System accounts and groups (< 1000) always come from the image.

Safety rules (a device must never end up locked out):
  - the old slot's files are never touched;
  - output is built in memory, validated, written next to its destination and renamed into place; the previous upper file is kept as
    *.pre-update;
  - ANY failure falls back to the plain image files (what happens without this module), is logged and reported, and never fails the update.
"""
import os
import re
import shutil
import subprocess
import tempfile

MAX_BYTES = 4 * 1024 * 1024            # a bigger file is not a passwd file: refuse and fall back
UID_MIN, UID_MAX = 1000, 65534
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*\$?$")
FILES = ("passwd", "shadow", "group", "gshadow")
FIRST_ADMIN_GROUP = "unitotem-first-admin"  # sshd marker group of the first-access root account (created by the image)
SHELL_RE = re.compile(r"/[^:\x00-\x20\x7f]+")  # absolute path, no ':', no whitespace or control characters


class MergeError(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------------------------------------------------------
def parse(text, nfields, what="file"):
    """-> (list of field lists, number of skipped lines). A blank/malformed/duplicate-name line is skipped, never fatal."""
    rows, seen, skipped = [], set(), 0
    if isinstance(text, bytes):
        if b"\0" in text:
            raise MergeError(f"{what}: binary data")
        text = text.decode("utf-8", "replace")
    if len(text) > MAX_BYTES:
        raise MergeError(f"{what}: too big")
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if not line.strip():
            continue
        f = line.split(":")
        if len(f) != nfields or not NAME_RE.match(f[0]) or f[0] in seen:
            skipped += 1
            continue
        seen.add(f[0])
        rows.append(f)
    return rows, skipped


def _int(s):
    return int(s) if re.fullmatch(r"\d+", s or "") else None


def _split(s):
    return [x for x in s.split(",") if x]


def _join(names):
    return ",".join(names)


def _set_member(csv, name, want):
    """Add (want=True) or remove (want=False) one name in a comma list; keeps the order of the others."""
    names = [n for n in _split(csv) if n != name]
    if want:
        names.append(name)
    return _join(names)


# ---------------------------------------------------------------------------------------------------------------------------
# the pure merge
# ---------------------------------------------------------------------------------------------------------------------------
def merge_identity(base, cur, log=None):
    """base, cur: dicts {'passwd','shadow','group','gshadow'} -> text (str or bytes; missing/None = empty).
    Returns {'passwd','shadow','group','gshadow'} merged texts. Raises MergeError if the result cannot be trusted."""
    log = log if log is not None else []

    def L(msg):
        log.append(msg)

    bp, _ = parse(base.get("passwd") or "", 7, "base passwd")
    bs, _ = parse(base.get("shadow") or "", 9, "base shadow")
    bg, _ = parse(base.get("group") or "", 4, "base group")
    bgs, _ = parse(base.get("gshadow") or "", 4, "base gshadow")
    try:
        cp, sk1 = parse(cur.get("passwd") or "", 7, "current passwd")
        cs, sk2 = parse(cur.get("shadow") or "", 9, "current shadow")
        cg, sk3 = parse(cur.get("group") or "", 4, "current group")
        cgs, sk4 = parse(cur.get("gshadow") or "", 4, "current gshadow")
    except MergeError as e:
        raise MergeError(f"current files unusable: {e}")
    if sk1 + sk2 + sk3 + sk4:
        L(f"skipped {sk1 + sk2 + sk3 + sk4} malformed/duplicate lines in the current files")

    if not any(r[0] == "root" and r[2] == "0" for r in bp):
        raise MergeError("the image's passwd has no root with uid 0")

    base_names = {r[0] for r in bp}
    base_uids = {r[2] for r in bp}
    base_gnames = {r[0] for r in bg}
    base_gids = {r[2] for r in bg}
    sh_base = {r[0]: r for r in bs}
    sh_cur = {r[0]: r for r in cs}

    # ---- passwd / shadow
    out_p = [list(r) for r in bp]
    out_s = [list(r) for r in bs]
    sh_out = {r[0]: r for r in out_s}
    carried = set()                                  # local account names kept from current
    for r in cp:
        name, uid = r[0], _int(r[2])
        if name == "root":
            continue
        if uid is None or not (UID_MIN <= uid < UID_MAX):
            continue                                 # system accounts always come from the image
        if name in base_names or r[2] in base_uids:
            L(f"account {name} (uid {r[2]}) clashes with the image: the image wins")
            continue
        out_p.append(list(r))
        carried.add(name)
        e = sh_cur.get(name)
        if e is None:
            e = [name, "!", "", "0", "99999", "7", "", "", ""]      # no shadow entry in current: locked
            L(f"account {name} had no shadow entry: carried locked")
        ent = list(e)
        out_s.append(ent)
        sh_out[name] = ent
    # root: hash and aging from current (the web terminal's login uses it)
    if "root" in sh_cur:
        e = list(sh_cur["root"])
        if "root" in sh_out:
            sh_out["root"][:] = e
        else:
            ent = e; out_s.append(ent); sh_out["root"] = ent
    elif "root" not in sh_out:
        raise MergeError("neither the image nor the current shadow has a root entry")

    # root's login shell: from current when current has root and the marker group (closed: /bin/bash, open: the first-admin shell)
    cur_root = next((r for r in cp if r[0] == "root"), None)
    marker_cur = next((r for r in cg if r[0] == FIRST_ADMIN_GROUP), None)
    use_cur_root = cur_root is not None and marker_cur is not None
    if use_cur_root and SHELL_RE.fullmatch(cur_root[6]):
        for r in out_p:
            if r[0] == "root":
                r[6] = cur_root[6]
        L(f"root login shell from the current slot: {cur_root[6]}")
    elif use_cur_root:
        L(f"root login shell in the current slot is invalid ({cur_root[6]!r}): the image's shell is kept")
    else:
        L(f"root login shell and {FIRST_ADMIN_GROUP} membership from the image (current has no root or no {FIRST_ADMIN_GROUP} group)")

    # ---- group / gshadow
    names_ok = {r[0] for r in out_p}
    keep_members = carried | {"root"}
    out_g = [list(r) for r in bg]
    cur_g = {r[0]: r for r in cg}
    cur_gs = {r[0]: r for r in cgs}
    base_gs = {r[0]: r for r in bgs}
    gs_out = {}
    for r in out_g:
        b = base_gs.get(r[0])
        gs_out[r[0]] = list(b) if b else [r[0], "!", "", r[3]]
    # memberships of local accounts (and root) in the image's groups
    for g in out_g:
        c = cur_g.get(g[0])
        if not c or g[0] not in base_gnames:
            continue
        add = [m for m in _split(c[3]) if m in keep_members and m in names_ok]
        if add:
            g[3] = _join(list(dict.fromkeys(_split(g[3]) + add)))
        gs = gs_out[g[0]]
        cgs_e = cur_gs.get(g[0])
        if cgs_e:
            gs[3] = _join(list(dict.fromkeys(_split(gs[3]) + [m for m in _split(cgs_e[3]) if m in keep_members and m in names_ok])))
            gs[2] = _join(list(dict.fromkeys(_split(gs[2]) + [m for m in _split(cgs_e[2]) if m in keep_members and m in names_ok])))
        else:
            gs[3] = g[3]
    # root's membership of the marker group is exactly the current one: added or removed (the image's open state lists root)
    if use_cur_root and FIRST_ADMIN_GROUP in base_gnames:
        for g in out_g:
            if g[0] != FIRST_ADMIN_GROUP:
                continue
            gs = gs_out[g[0]]
            cgs_e = cur_gs.get(g[0])
            in_members = "root" in _split(marker_cur[3])
            in_admins = False
            if cgs_e:
                in_members = "root" in _split(cgs_e[3])
                in_admins = "root" in _split(cgs_e[2])
            g[3] = _set_member(g[3], "root", in_members)
            gs[3] = _set_member(gs[3], "root", in_members)
            gs[2] = _set_member(gs[2], "root", in_admins)
            L(f"root {'in' if in_members else 'not in'} {FIRST_ADMIN_GROUP} (from the current slot)")
    # local groups
    for c in cg:
        gid = _int(c[2])
        if gid is None or not (UID_MIN <= gid < UID_MAX):
            continue
        if c[0] in base_gnames or c[2] in base_gids:
            if c[0] not in base_gnames:
                L(f"group {c[0]} (gid {c[2]}) clashes with the image: the image wins")
            continue
        members = [m for m in _split(c[3]) if m in names_ok]
        row = [c[0], c[1], c[2], _join(members)]
        out_g.append(row)
        e = cur_gs.get(c[0])
        gs_out[c[0]] = [c[0], e[1] if e else "!", _join([m for m in _split(e[2]) if m in names_ok]) if e else "", _join(members)]
    out_gs = [gs_out[r[0]] for r in out_g]

    result = {
        "passwd": "".join(":".join(r) + "\n" for r in out_p),
        "shadow": "".join(":".join(r) + "\n" for r in out_s),
        "group": "".join(":".join(r) + "\n" for r in out_g),
        "gshadow": "".join(":".join(r) + "\n" for r in out_gs),
    }
    validate(result)
    return result


def validate(res):
    """Strict check of the merged set. Raises MergeError."""
    p, _ = parse(res["passwd"], 7, "passwd")
    s, _ = parse(res["shadow"], 9, "shadow")
    g, _ = parse(res["group"], 4, "group")
    gs, _ = parse(res["gshadow"], 4, "gshadow")
    for what, rows in (("passwd", p), ("shadow", s), ("group", g), ("gshadow", gs)):
        n = res[what].count("\n")
        if n != len(rows):
            raise MergeError(f"{what}: {n - len(rows)} unparsable/duplicate line(s) in the result")
    names = [r[0] for r in p]
    if len(set(r[2] for r in p)) != len(p):
        # duplicate uids are legal on Linux but never produced here: treat as a bug in the inputs, do not trust
        raise MergeError("duplicate uid in the merged passwd")
    if len(set(r[2] for r in g)) != len(g):
        raise MergeError("duplicate gid in the merged group")
    if not any(r[0] == "root" and r[2] == "0" for r in p):
        raise MergeError("root (uid 0) missing in passwd")
    if not any(r[0] == "root" for r in s):
        raise MergeError("root missing in shadow")
    pn = set(names)
    for r in s:
        if r[0] not in pn:
            raise MergeError(f"shadow entry {r[0]} has no passwd entry")
    for r in p:
        if _int(r[2]) is None or _int(r[3]) is None:
            raise MergeError(f"passwd {r[0]}: non numeric uid/gid")
    gn = {r[0] for r in g}
    for r in g:
        for m in _split(r[3]):
            if m not in pn:
                raise MergeError(f"group {r[0]}: member {m} does not exist")
    for r in gs:
        if r[0] not in gn:
            raise MergeError(f"gshadow entry {r[0]} has no group")
        for m in _split(r[2]) + _split(r[3]):
            if m not in pn:
                raise MergeError(f"gshadow {r[0]}: member {m} does not exist")


# ---------------------------------------------------------------------------------------------------------------------------
# reading / checking / installing
# ---------------------------------------------------------------------------------------------------------------------------
def read_set(directory):
    out = {}
    for n in FILES:
        try:
            with open(os.path.join(directory, n), "rb") as f:
                data = f.read(MAX_BYTES + 1)
            out[n] = data
        except OSError:
            out[n] = b""
    return out


def _tool_issues(tool, a, b, extra_dir):
    """Run pwck/grpck -r on a pair of files in a scratch dir; -> set of normalised problem lines."""
    exe = shutil.which(tool) or shutil.which(tool, path="/usr/sbin:/sbin")
    if not exe:
        return None
    try:
        r = subprocess.run([exe, "-r", a, b], capture_output=True, text=True, timeout=30, env=dict(os.environ, LC_ALL="C", LANG="C"))   # messages are matched in English
    except (OSError, subprocess.TimeoutExpired):
        return None
    return {re.sub(r"\s+", " ", l.strip()) for l in (r.stdout + r.stderr).splitlines() if l.strip()}


SERIOUS = re.compile(r"invalid|duplicate|no matching|illegal|bad |missing|not found in|unknown", re.I)


def tool_check(base, merged):
    """pwck -r / grpck -r must not report anything serious on the merged files that it does not already report on the image's own."""
    with tempfile.TemporaryDirectory(prefix="ut-idcheck-") as d:
        for tag, src in (("b", base), ("m", merged)):
            for n in FILES:
                data = src[n]
                with open(os.path.join(d, f"{tag}.{n}"), "wb" if isinstance(data, bytes) else "w") as f:
                    f.write(data)
        problems = []
        for tool, (x, y) in (("pwck", ("passwd", "shadow")), ("grpck", ("group", "gshadow"))):
            mb = _tool_issues(tool, os.path.join(d, f"b.{x}"), os.path.join(d, f"b.{y}"), d)
            mm = _tool_issues(tool, os.path.join(d, f"m.{x}"), os.path.join(d, f"m.{y}"), d)
            if mb is None or mm is None:
                continue                                    # tool absent: our own validate() already ran
            # file names differ between the two runs: normalise them away
            norm = lambda s: {re.sub(r"[bm]\.(passwd|shadow|group|gshadow)", r"\1", l) for l in s}
            for l in sorted(norm(mm) - norm(mb)):
                if SERIOUS.search(l):
                    problems.append(f"{tool}: {l}")
        if problems:
            raise MergeError("; ".join(problems[:5]))


def install_set(dest_dir, merged, shadow_gid=None):
    """Write the four files into dest_dir (a new slot's /etc overlay upper) atomically, keeping a previous version as *.pre-update."""
    os.makedirs(dest_dir, exist_ok=True)
    modes = {"passwd": 0o644, "group": 0o644, "shadow": 0o640, "gshadow": 0o640}
    tmps = {}
    try:
        for n in FILES:                                          # all temp files first: nothing is installed if one write fails
            fd, tmp = tempfile.mkstemp(prefix=f".{n}.", suffix=".unitotem-new", dir=dest_dir)
            tmps[n] = tmp
            with os.fdopen(fd, "wb") as f:
                data = merged[n]
                f.write(data if isinstance(data, bytes) else data.encode())
                f.flush(); os.fsync(f.fileno())
            os.chmod(tmp, modes[n])
            try:
                os.chown(tmp, 0, shadow_gid if (n in ("shadow", "gshadow") and shadow_gid is not None) else 0)
            except (PermissionError, OSError):
                pass                                             # not root (tests): ownership is irrelevant there
        for n in FILES:
            dst = os.path.join(dest_dir, n)
            if os.path.exists(dst):
                shutil.copy2(dst, dst + ".pre-update")
            os.replace(tmps[n], dst)
            tmps.pop(n)
    finally:
        for t in tmps.values():
            try: os.unlink(t)
            except OSError: pass
    fd = os.open(dest_dir, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def remove_set(dest_dir):
    """Fallback: the plain image files are the ones visible in the new slot (nothing in its overlay upper)."""
    for n in FILES:
        for suffix in ("", ".unitotem-new"):
            try: os.unlink(os.path.join(dest_dir, n + suffix))
            except OSError: pass


def apply_merge(base_dir, current_dir, dest_dir):
    """Whole operation. NEVER raises: returns {'ok': bool, 'detail': str, 'log': [..]} for the update status."""
    log = []
    try:
        base, cur = read_set(base_dir), read_set(current_dir)
        merged = merge_identity(base, cur, log)
        tool_check({k: v.decode("utf-8", "replace") for k, v in base.items()}, merged)
        gid = None
        try:
            for r in parse(merged["group"], 4)[0]:
                if r[0] == "shadow":
                    gid = int(r[2])
        except Exception:
            gid = None
        install_set(dest_dir, merged, gid)
        return {"ok": True, "detail": "local accounts merged into the new slot", "log": log}
    except Exception as e:                                       # includes MergeError, I/O errors, anything unforeseen
        try:
            remove_set(dest_dir)
        except Exception:
            pass
        return {"ok": False, "detail": f"identity merge FAILED, the new slot uses the image's own account files "
                                       f"(root password = image default): {e}", "log": log}
