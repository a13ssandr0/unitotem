"""Native port of unitotem/files/ota-hook (initramfs-tools hook of the OTA engine).

Name lists come from unitotem/files/ota-initrd.list (lists.read_list); this module keeps the
code-only special cases. Directive groups run in the order of the POSIX hook, whatever the
line order of the list file.
"""

import os
import re
import shutil

# Target paths of the usr-merged top-level directories (hook-functions canonicalisation).
_USR_MERGED = ("/bin", "/sbin")
_TERMINFO_DIRS = ("/usr/share/terminfo", "/lib/terminfo", "/usr/lib/terminfo")
_ENGINE = "/usr/lib/unitotem/ota-engine.sh"
_KNOWN = {"bin", "real", "file", "terminfo", "module", "module-opt",
          "x86-bin", "x86-module", "x86-dir", "package-version", "plymouth-plugin", "replace"}
_VERSION_RE = re.compile(r"[0-9A-Za-z.+~:-]+")


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


def _installed_version(stage, package):
    """Version of PACKAGE from ROOT's dpkg status file, or "" unless the package is fully installed."""
    try:
        with open(_root(stage, "/var/lib/dpkg/status"), encoding="utf-8") as fh:
            stanzas = fh.read().split("\n\n")
    except FileNotFoundError:
        return ""
    for stanza in stanzas:
        fields = {}
        for line in stanza.splitlines():
            key, sep, value = line.partition(":")
            if sep and not line.startswith((" ", "\t")):
                fields.setdefault(key.strip(), value.strip())
        if fields.get("Package") != package:
            continue
        # "install ok installed" is the state of a package in use (dpkg-query's "ii")
        if fields.get("Status", "").split()[-2:] != ["ok", "installed"]:
            return ""
        return fields.get("Version", "")
    return ""


def _package_version(stage, package, dest):
    """Writes the installed version of PACKAGE to DEST (one line); nothing when it is not installed."""
    version = _installed_version(stage, package)
    if not _VERSION_RE.fullmatch(version):
        return
    target = _dst(stage, dest)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(version + "\n")


def _plymouth_plugin(stage, name):
    """copy_exec of NAME from the target's plymouth plugin directory; nothing when the plugin is absent."""
    src = f"/usr/lib/{stage.triplet}/plymouth/{name}"
    if os.path.isfile(_root(stage, src)):
        if stage.copy_exec(src) != 0:
            stage.warn("unitotem-ota hook: plymouth plugin %s not copied" % name)


def _replace(stage, src, dest):
    """DEST (a file or a symlink) becomes a copy of the root file SRC, mode 644."""
    if not os.path.isfile(_root(stage, src)):
        stage.warn("unitotem-ota hook: '%s' not found, skipping" % src)
        return
    target = _dst(stage, dest)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.lexists(target):
        os.unlink(target)
    shutil.copyfile(_root(stage, src), target)
    os.chmod(target, 0o644)


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

    for args in groups.get("plymouth-plugin", []):
        for name in args:
            _plymouth_plugin(stage, name)

    # After the stock plymouth hook, which links Plymouth.ttf to DejaVu Sans.
    for args in groups.get("replace", []):
        _replace(stage, args[0], args[1])

    for args in groups.get("package-version", []):
        _package_version(stage, args[0], args[1])

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
