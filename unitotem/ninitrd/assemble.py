"""Recovery initrd staging tree and cpio packing: port of the mkinitramfs 0.151 body.

Order follows mkinitramfs: skeleton, builtin module files, MODULES=most, builtin firmware, init, scripts,
conf, modprobe, module apply, stock hooks, project hook, scripts cache, module apply, hidden deps,
kmod hook, depmod, ld.so.conf copy, cpio. The per-hook work lives in stockhooks.py, otahook.py and modules.py;
the Stage, Modules and hook APIs are imported lazily (see unitotem/ninitrd/ninitrd-SPEC.md).

Not ported: ldconfig -r (no dynamic linker cache is written: glibc falls back to its built-in default
directories, and every library copied here comes from those directories, see stage.py), DSDT.aml (not used).
"""
import collections
import fnmatch
import os
import re
import shutil
import subprocess
import sys

REPO_UNITOTEM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREMOUNT_SRC = os.path.join(REPO_UNITOTEM, "files", "ota-recovery-init-premount")
BUILTIN_FILES = ("modules.builtin", "modules.builtin.bin", "modules.builtin.modinfo", "modules.order")
SHARE = "usr/share/initramfs-tools"
CONFDIR = "etc/initramfs-tools"
# [[:alnum:]\._-] of the mkinitramfs find regex (the backslash is part of the POSIX class)
NAME_RE = re.compile(r"[A-Za-z0-9\\._-]+")
CONF_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9\\._-]*")
COMPRESSED_SUFFIXES = (".zst", ".xz")
LOGO_EXTS = ("bgrx", "rgb565", "spans")


def _warn(msg):
    print(msg, file=sys.stderr)


def _copy_p(src, dst):
    # cp -p for a regular file
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)


def _read_conf(root):
    """Effective COMPRESS, COMPRESSLEVEL: initramfs.conf first, then conf.d files in mkinitramfs order."""
    values = {}
    for path in [os.path.join(root, CONFDIR, "initramfs.conf")] + [p for _, p in _conf_d_files(root)]:
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^(COMPRESS|COMPRESSLEVEL)=['\"]?([^'\"\s]*)['\"]?\s*$", line)
                if m:
                    values[m.group(1)] = m.group(2)
    return values


def _conf_d_files(root):
    """Port of the maybe_add_conf loop: (name, path) in source order, /etc masks /usr/share by name."""
    usr = os.path.join(root, SHARE, "conf.d")
    cfg = os.path.join(root, CONFDIR, "conf.d")
    out = []

    def accept(name, path):
        if not os.path.exists(path):
            return
        if not CONF_NAME_RE.fullmatch(name) or ".dpkg-" in name:
            return
        if os.path.isdir(path):
            _warn(f"W: {path} is a directory instead of file")
            return
        out.append((name, path))

    if os.path.isdir(usr):
        for name in sorted(os.listdir(usr)):
            if not os.path.exists(os.path.join(cfg, name)):
                accept(name, os.path.join(usr, name))
    if os.path.isdir(cfg):
        for name in sorted(os.listdir(cfg)):
            accept(name, os.path.join(cfg, name))
    return out


def _skeleton(root, dest, kver):
    # usr-merged layout: bin, sbin and every lib* top-level name of the target point into usr/
    tops = ["bin", "sbin"] + sorted(n for n in os.listdir(root) if n.startswith("lib"))
    for d in tops:
        os.makedirs(os.path.join(dest, "usr", d), exist_ok=True)
        os.symlink(os.path.join("usr", d), os.path.join(dest, d))
    for d in ("conf/conf.d", "etc", "run", "scripts", os.path.join("lib/modules", kver)):
        os.makedirs(os.path.join(dest, d), exist_ok=True)


def _initlist(initdir):
    """set_initlist: executable, valid-name, syntax-clean scripts, sorted (glob order of the C locale)."""
    names = []
    for name in sorted(os.listdir(initdir)):
        path = os.path.join(initdir, name)
        if name.startswith(".") or not NAME_RE.fullmatch(name) or os.path.isdir(path):
            continue
        if not os.stat(path).st_mode & 0o111:
            continue
        if subprocess.run(["sh", "-n", path], capture_output=True).returncode != 0:
            continue
        names.append(name)
    return names


def _prereqs(path):
    """PREREQ list of a boot script, read statically: the variable echoed by its prereqs() function,
    assigned as a double-quoted literal. Nothing of the script is executed."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    fn = re.search(r"^prereqs\(\)\s*\{", text, re.M)
    if fn is None:
        # no prereqs() function: the script prints nothing for `prereqs`
        if re.search(r"\bprereqs\b", text):
            raise RuntimeError(f"{path}: prereqs is used in a form that is not read statically")
        return []
    echo = re.compile(r'echo\s+"\$\{?(\w+)\}?"').search(text, fn.end(), fn.end() + 200)
    if not echo:
        raise RuntimeError(f"{path}: prereqs() does not echo a variable")
    var = echo.group(1)
    values = re.findall(rf'^{var}="([^"$`\\]*)"[ \t]*$', text, re.M)
    return values[-1].split() if values else []


def _gnu_tsort(pairs):
    """GNU coreutils tsort order: a FIFO of zero-count nodes.

    Zero-count nodes are queued in sorted name order at start; a successor joins the tail when its last
    predecessor is emitted. Self pairs only declare a node. Cycles are reported and skipped.
    Checked against the Debian reference ORDER files (init-top, init-premount, init-bottom, panic).
    """
    succ, count = {}, {}
    for a, b in pairs:
        succ.setdefault(a, [])
        count.setdefault(a, 0)
        count.setdefault(b, 0)
        succ.setdefault(b, [])
        if a != b:
            succ[a].append(b)
            count[b] += 1
    queue = collections.deque(n for n in sorted(count) if count[n] == 0)
    out = []
    while True:
        while queue:
            node = queue.popleft()
            out.append(node)
            for nxt in succ[node]:
                count[nxt] -= 1
                if count[nxt] == 0:
                    queue.append(nxt)
        left = [n for n in sorted(count) if count[n] > 0]
        if not left:
            break
        _warn(f"W: tsort: input contains a loop: {' '.join(left)}")
        queue.append(left[0])
        count[left[0]] = 0
    return out


def _cache_run_scripts(dest, scriptdir):
    """Port of cache_run_scripts: writes scriptdir/ORDER in tsort order of the prereq pairs."""
    initdir = os.path.join(dest, scriptdir.lstrip("/"))
    if not os.path.isdir(initdir):
        return
    order = os.path.join(initdir, "ORDER")
    open(order, "w").close()
    pairs = []
    for name in _initlist(initdir):
        pairs.append((name, name))
        pairs.extend((pre, name) for pre in _prereqs(os.path.join(initdir, name)))
    lines = []
    for x in _gnu_tsort(pairs):
        if os.path.isfile(os.path.join(initdir, x)):
            lines.append(f'{scriptdir}/{x} "$@"\n')
            lines.append("[ -e /conf/param.conf ] && . /conf/param.conf\n")
    with open(order, "w", encoding="utf-8") as fh:
        fh.write("".join(lines))


def _copy_scripts(root, dest):
    # Stock scripts (find -type f, name regex), then CONFDIR scripts to depth 2 (dot names pruned), overriding.
    usr = os.path.join(root, SHARE, "scripts")
    for dirpath, dirnames, filenames in os.walk(usr):
        for name in filenames:
            src = os.path.join(dirpath, name)
            if os.path.islink(src) or not NAME_RE.fullmatch(name):
                continue
            rel = os.path.relpath(src, usr)
            _copy_p(src, os.path.join(dest, "scripts", rel))
    cfg = os.path.join(root, CONFDIR, "scripts")
    if not os.path.isdir(cfg):
        return
    # find -maxdepth 2: files of the top directory and of its direct subdirectories only
    for dirpath, dirnames, filenames in os.walk(cfg):
        rel_dir = os.path.relpath(dirpath, cfg)
        depth = 0 if rel_dir == "." else rel_dir.count(os.sep) + 1
        dirnames[:] = [d for d in dirnames if not (d.startswith(".") and len(d) > 1) and depth < 1]
        if depth > 1:
            continue
        for name in filenames:
            src = os.path.join(dirpath, name)
            if name.startswith(".") and len(name) > 1 or os.path.islink(src) or not NAME_RE.fullmatch(name):
                continue
            _copy_p(src, os.path.join(dest, "scripts", os.path.relpath(src, cfg)))


def _install_premount(dest):
    # The fallback entry point: the project init-premount script, installed as zz-unitotem-ota.
    dst = os.path.join(dest, "scripts", "init-premount", "zz-unitotem-ota")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(PREMOUNT_SRC, dst)
    os.chmod(dst, 0o755)


def _builtin_module_files(root, dest, kver):
    src_dir = os.path.join(root, "lib/modules", kver)
    for name in BUILTIN_FILES:
        src = os.path.join(src_dir, name)
        if os.path.isfile(src):
            _copy_p(src, os.path.join(dest, "lib/modules", kver, name))


def _module_names_from_file(path, mods, forced=None):
    # add_modules_from_file: first word of each non-comment line; force_load also records "module args" in /conf/modules
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            words = line.split()
            if len(words) > 1:
                raise RuntimeError(f"{path}: module options are not ported: {line.strip()}")
            mods.add([words[0]])
            if forced is not None:
                forced.append(words[0] + " ")


def _ld_so_conf(root, dest):
    # cp -pPr /etc/ld.so.conf*: symlinks kept, directories copied
    etc = os.path.join(root, "etc")
    for name in sorted(os.listdir(etc)):
        if not name.startswith("ld.so.conf"):
            continue
        src = os.path.join(etc, name)
        dst = os.path.join(dest, "etc", name)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
        elif os.path.isdir(src):
            shutil.copytree(src, dst, symlinks=True)
        else:
            shutil.copy2(src, dst)


def build(root, dest, arch, kver, engine, logo_dir, list_path, hook, warn=_warn, slot=False):
    """Fills dest (empty, created here if missing) from the target tree root. Returns the zstd level.

    slot=True builds the initramfs of the installed system (what update-initramfs makes): the rootfs's own init-premount
    scripts are used and initramfs.conf is kept as is; slot=False builds the resident fallback."""
    os.umask(0o022)  # entry modes as mkinitramfs makes them (its umask is 022)
    import modules as modules_mod
    import stage as stage_mod
    import stockhooks

    if os.path.exists(dest) and os.listdir(dest):
        raise RuntimeError(f"staging directory is not empty: {dest}")
    os.makedirs(dest, exist_ok=True)
    os.chmod(dest, 0o755)
    conf_dir = os.path.join(root, CONFDIR)
    if os.path.exists(os.path.join(conf_dir, "DSDT.aml")):
        raise RuntimeError("DSDT.aml override is not ported")
    moddir = os.path.join(root, "lib/modules", kver)
    if not os.path.isfile(os.path.join(moddir, "modules.dep")):
        raise RuntimeError(f"{moddir}/modules.dep missing: the rootfs needs depmod run on it first")

    _skeleton(root, dest, kver)
    # engine and logo are placed before the hooks so the project hook's copy_file keeps them
    # (copy_file returns "already present"); this is the staging-area form of the stage-1 refresh
    _copy_p_mode(engine, os.path.join(dest, "usr/lib/unitotem/ota-engine.sh"), 0o755)
    for base in _logo_names(list_path):
        for ext in LOGO_EXTS:
            src = os.path.join(logo_dir, f"{base}.{ext}")
            if os.path.isfile(src):
                _copy_p_mode(src, os.path.join(dest, "usr/lib/unitotem", f"{base}.{ext}"), 0o644)
            else:
                warn(f"W: logo {base}.{ext} not rendered, not shipped")

    _builtin_module_files(root, dest, kver)
    st = stage_mod.Stage(root, dest, arch, kver, warn=warn)
    mods = modules_mod.Modules(st)

    forced = []
    _module_names_from_file(os.path.join(conf_dir, "modules"), mods, forced)
    mods_d = os.path.join(root, SHARE, "modules.d")
    if os.path.isdir(mods_d):
        for name in sorted(os.listdir(mods_d)):
            _module_names_from_file(os.path.join(mods_d, name), mods, forced)

    conf = _read_conf(root)
    compress = conf.get("COMPRESS", "")
    if compress != "zstd":
        raise RuntimeError(f"COMPRESS={compress!r}: only zstd is ported")
    level = conf.get("COMPRESSLEVEL") or "9"
    if not re.fullmatch(r"[0-9]{1,2}", level):
        raise RuntimeError(f"invalid COMPRESSLEVEL={level!r}")

    # MODULES=most is forced (stage-1 policy: MODULES=dep probes the build host root)
    mods.most()
    mods.builtin_firmware()

    _copy_p(os.path.join(root, SHARE, "init"), os.path.join(dest, "init"))
    _copy_scripts(root, dest)
    if not slot:
        _install_premount(dest)

    os.makedirs(os.path.join(dest, "conf"), exist_ok=True)
    with open(os.path.join(conf_dir, "initramfs.conf"), encoding="utf-8") as fh:
        text = fh.read()
    if not slot:
        text = re.sub(r"^MODULES=.*$", "MODULES=most", text, flags=re.M)
    with open(os.path.join(dest, "conf", "initramfs.conf"), "w", encoding="utf-8") as fh:
        fh.write(text)
    with open(os.path.join(dest, "conf", "arch.conf"), "w", encoding="utf-8") as fh:
        fh.write(f"DPKG_ARCH={arch}\n")
    if forced:
        with open(os.path.join(dest, "conf", "modules"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(forced) + "\n")
    os.makedirs(os.path.join(dest, "conf", "conf.d"), exist_ok=True)
    for _, path in _conf_d_files(root):
        st.copy_file("config", "/" + os.path.relpath(path, root), "/conf/conf.d")

    # fstab and mtab
    open(os.path.join(dest, "etc", "fstab"), "w").close()
    os.symlink("/proc/mounts", os.path.join(dest, "etc", "mtab"))

    # module-init-tools
    st.copy_exec("/sbin/modprobe", "/sbin")
    st.copy_exec("/sbin/rmmod", "/sbin")
    os.makedirs(os.path.join(dest, "etc", "modprobe.d"), exist_ok=True)
    os.makedirs(os.path.join(dest, "lib", "modprobe.d"), exist_ok=True)
    for sub in ("etc", "lib"):
        d = os.path.join(root, sub, "modprobe.d")
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".conf"):
                st.copy_file("config", f"/{sub}/modprobe.d/{name}")

    mods.apply()
    stockhooks.run_stock_hooks(st, mods)
    hook.run(st, mods, list_path)

    scripts = os.path.join(dest, "scripts")
    for dirpath, dirnames, _ in os.walk(scripts):
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if not os.path.islink(full):
                _cache_run_scripts(dest, "/" + os.path.relpath(full, dest))

    mods.apply()
    mods.hidden_deps()
    stockhooks.hook_kmod(st, mods)

    subprocess.run(["depmod", "-a", "-b", dest, kver], check=True)
    modsdir = os.path.join(dest, "lib", "modules", kver)
    for name in os.listdir(modsdir):
        if name.startswith("modules.") and fnmatch.fnmatchcase(name, "modules.*map"):
            os.remove(os.path.join(modsdir, name))
    _ld_so_conf(root, dest)
    return level


def _logo_names(list_path):
    # the `logo` directives of the data file, as the project hook reads them
    from lists import read_list
    return [name for directive, args in read_list(list_path) if directive == "logo" for name in args]


def _copy_p_mode(src, dst, mode):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, mode)


def _tree_lists(dest):
    """find/add_directories/sort/uniq of mkinitramfs: (main, uncompressed) lists of ./-relative names."""
    main, uncomp = set(), set()
    for dirpath, dirnames, filenames in os.walk(dest):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = "./" + os.path.relpath(full, dest)
            real_dir = os.path.isdir(full) and not os.path.islink(full)
            named = name.endswith(COMPRESSED_SUFFIXES)
            if named:
                uncomp.add(rel)
            if not real_dir and not named:
                main.add(rel)
            if real_dir and not os.listdir(full):
                main.add(rel)
    return _with_parents(main), _with_parents(uncomp)


def _with_parents(paths):
    out = set()
    for p in paths:
        parts = p[2:].split("/")
        for i in range(1, len(parts)):
            out.add("./" + "/".join(parts[:i]))
        out.add(p)
    if out:
        out.add(".")
    return "".join(line + "\n" for line in sorted(out))


def pack(dest, out_path, work, level):
    """Writes out_path: uncompressed cpio of *.zst/*.xz, then zstd cpio of the rest (mkinitramfs layout)."""
    main_text, uncomp_text = _tree_lists(dest)
    segments = []
    if uncomp_text:
        segments.append(_cpio(dest, uncomp_text, os.path.join(work, "uncompressed.cpio")))
    main_cpio = _cpio(dest, main_text, os.path.join(work, "main.cpio"))
    zst = os.path.join(work, "main.cpio.zst")
    with open(zst, "wb") as fh:
        subprocess.run(["zstd", "-q", f"-{level}", "-T0", "-c", main_cpio], stdout=fh, check=True)
    segments.append(zst)
    with open(out_path, "wb") as out:
        for seg in segments:
            with open(seg, "rb") as fh:
                shutil.copyfileobj(fh, out)


def _cpio(dest, list_text, out_file):
    with open(out_file, "wb") as fh:
        subprocess.run(["cpio", "--quiet", "-R", "0:0", "-o", "-H", "newc", "-D", dest],
                       input=list_text.encode("utf-8"), stdout=fh, check=True)
    return out_file
