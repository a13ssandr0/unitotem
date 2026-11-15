"""Native port of unitotem/files/ota-hook (initramfs-tools hook of the OTA engine).

Name lists come from unitotem/files/ota-initrd.list (lists.read_list); this module keeps the
code-only special cases. Directive groups run in the order of the POSIX hook, whatever the
line order of the list file.
"""

import os

# Target paths of the usr-merged top-level directories (hook-functions canonicalisation).
_USR_MERGED = ("/bin", "/sbin")
_TERMINFO_DIRS = ("/usr/share/terminfo", "/lib/terminfo", "/usr/lib/terminfo")
_LOGO_EXTS = ("bgrx", "rgb565", "spans")
_ENGINE = "/usr/lib/unitotem/ota-engine.sh"
_KNOWN = {"bin", "real", "file", "logo", "terminfo", "module", "module-opt",
          "x86-bin", "x86-module", "x86-dir"}


def _canon(path):
    """/bin/x -> /usr/bin/x, as copy_file does for usr-merged paths."""
    if path in _USR_MERGED or path.startswith(("/bin/", "/sbin/", "/lib")):
        return "/usr" + path
    return path


def _root(stage, path):
    return os.path.join(str(stage.root), path.lstrip("/"))


def _dst(stage, path):
    return os.path.join(str(stage.dest), _canon(path).lstrip("/"))


def _link(stage, target, link):
    """ln -sf target DEST/link (creates parents, replaces a file or symlink)."""
    p = _dst(stage, link)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if os.path.lexists(p):
        os.unlink(p)
    os.symlink(target, p)


def _module_exists(stage, name):
    """modinfo -k test: the module is in modules.dep or modules.builtin of ROOT's kernel."""
    want = name.replace("-", "_")
    base = _root(stage, "/usr/lib/modules/" + stage.kver)
    for fname in ("modules.dep", "modules.builtin"):
        try:
            with open(os.path.join(base, fname), encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            path = line.split(":", 1)[0].strip()
            mod = os.path.basename(path)
            for ext in (".ko.zst", ".ko.xz", ".ko.gz", ".ko"):
                if mod.endswith(ext):
                    mod = mod[: -len(ext)]
                    break
            if mod.replace("-", "_") == want:
                return True
    return False


def _real(stage, name):
    """Copy the real binary over the existing (BusyBox-linked) entry, with its libraries."""
    src = stage.command_v(name)
    if not src:
        return
    target = _canon(src)
    dest = _dst(stage, target)
    if os.path.lexists(dest):
        os.unlink(dest)
    stage.copy_exec(src, target)


def _bin(stage, name):
    src = stage.command_v(name)
    if not src or stage.copy_exec(src) != 0:
        stage.warn("unitotem-ota hook: '%s' not found, skipping" % name)


def run(stage, modules, list_path):
    """Fill stage.dest like unitotem/files/ota-hook. modules is a Modules bound to stage."""
    import lists  # lazy: lists.py is a sibling module of this package

    groups = {}
    for directive, args in lists.read_list(list_path):
        if directive not in _KNOWN:
            raise ValueError("ota-initrd.list: unknown directive %r" % directive)
        groups.setdefault(directive, []).append(args)

    # bash is a shell dependency of ota-engine.sh (pipefail, process substitution).
    stage.copy_exec("/bin/bash", "/bin")

    # /etc/passwd and /etc/shadow are generated at run time; no hash is baked in.
    os.makedirs(_dst(stage, "/etc"), exist_ok=True)
    os.makedirs(_dst(stage, "/root/.ssh"), exist_ok=True)
    os.chmod(_dst(stage, "/root/.ssh"), 0o700)
    stage.copy_file("file", "/etc/group", "/etc/group")

    for args in groups.get("file", []):
        src = args[0]
        stage.copy_file("file", src, args[1] if len(args) > 1 else src)

    for args in groups.get("logo", []):
        for base in args:
            for ext in _LOGO_EXTS:
                p = "/usr/lib/unitotem/%s.%s" % (base, ext)
                stage.copy_file("file", p, p)

    _link(stage, _ENGINE, "/usr/sbin/unitotem-ota-engine")

    for args in groups.get("bin", []):
        for name in args:
            _bin(stage, name)

    # nc is a Debian alternatives chain: copy the real file and link /bin/nc to it.
    nc = stage.command_v("nc")
    nc_real = stage.readlink_f(nc) if nc else ""
    if nc_real:
        stage.copy_exec(nc_real)
        _link(stage, nc_real, "/bin/nc")

    # reboot must be systemd's binary: BusyBox cannot pass the tryboot argument to reboot(2).
    rb = stage.command_v("reboot")
    rb_real = stage.readlink_f(rb) if rb else ""
    if rb_real:
        stage.copy_exec(rb_real)
        _link(stage, rb_real, "/usr/sbin/reboot")

    for args in groups.get("real", []):
        for name in args:
            _real(stage, name)

    # Framebuffer and serial terminal types (whiptail/slang draws ASCII without them).
    for args in groups.get("terminfo", []):
        for tif in args:
            for d in _TERMINFO_DIRS:
                if os.path.isfile(_root(stage, d + "/" + tif)):
                    stage.copy_file("file", d + "/" + tif, "/usr/share/terminfo/" + tif)
                    break

    for args in groups.get("module", []):
        modules.add(list(args))

    for args in groups.get("module-opt", []):
        present = [n for n in args if _module_exists(stage, n)]
        if present:
            modules.add(present)

    # x86-only section: ARCH is not arm64, or the rootfs ships efibootmgr (Pi images have none).
    if stage.arch != "arm64" or os.path.isfile(_root(stage, "/usr/sbin/efibootmgr")):
        for args in groups.get("x86-bin", []):
            for name in args:
                p = stage.command_v(name)
                if p:
                    stage.copy_exec(p)
        for args in groups.get("x86-module", []):
            modules.add(list(args))
        for args in groups.get("x86-dir", []):
            for d in args:
                if os.path.isdir(_root(stage, d)):
                    stage.copy_file("directory", d, d)
