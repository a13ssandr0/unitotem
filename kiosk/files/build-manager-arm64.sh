#!/bin/bash
# Make an arm64 unitotem-manager .deb out of the amd64 one. The manager is Python: everything in the package except the
# virtualenv (/var/unitotem-venv, full of binary wheels - PySide6, CEF) is architecture independent, so the arm64 package is
# the same files with the venv rebuilt NATIVELY, exactly as debian/rules does it (pip install of manager/requirements.txt, then
# the cefpython3 aarch64 wheel from the project's GitHub release). Runs inside the stage 1 chroot setup, which on the build Pi is
# native arm64 - no emulation.
#   build-manager-arm64.sh ROOTFS SOURCE_AMD64_DEB OUT_DIR
set -euo pipefail
ROOTFS="$1"; SRC="$2"; OUT="$3"
CEF_RELEASE_REPO="${CEF_RELEASE_REPO:-a13ssandr0/cefpython}"
CEF_RELEASE_TAG="${CEF_RELEASE_TAG:-v147.0.0-arm64-stripped}"   # the wheel built with the strip in cefpython CMake (libcef.so 241 MB instead of 1980 MB); the strip below is then a no-op

# Not in /tmp: on the build Pi that is a 256 MB tmpfs, and the Pi's own disk is small too, so never unpack the amd64 venv at all
# (it is >2 GB and is thrown away) and move, not copy, the native venv into the package.
mkdir -p "$OUT"
W=$(mktemp -d -p "$(dirname "$OUT")" manager-arm64.XXXXXX); trap 'rm -rf -- "$W"' EXIT
mkdir -p "$W/pkg"
dpkg-deb --fsys-tarfile "$SRC" | tar -x -C "$W/pkg" --exclude=./var/unitotem-venv --exclude=./var/unitotem-venv/*
dpkg-deb -e "$SRC" "$W/pkg/DEBIAN"
VER=$(dpkg-deb -f "$SRC" Version)
echo ">>> manager arm64: repackaging $(basename "$SRC") ($VER); dropping its amd64 venv, building a native one"
mkdir -p "$W/pkg/var"
sed -i 's/^Architecture: .*/Architecture: arm64/' "$W/pkg/DEBIAN/control"
grep -q '^Architecture: arm64$' "$W/pkg/DEBIAN/control"

# the venv has absolute paths in its scripts: it must be built where it will live, so build it in the chroot at /var/unitotem-venv
chroot "$ROOTFS" rm -rf /var/unitotem-venv
cp "$W/pkg/usr/share/unitotem-manager/requirements.txt" "$ROOTFS/tmp/manager-requirements.txt"
chroot "$ROOTFS" python3 -m venv --system-site-packages --copies /var/unitotem-venv
chroot "$ROOTFS" /var/unitotem-venv/bin/pip3 install --no-cache-dir -r /tmp/manager-requirements.txt
PYTAG=$(chroot "$ROOTFS" /var/unitotem-venv/bin/python3 -c "import sys; print(f'cp{sys.version_info[0]}{sys.version_info[1]}')")
URL=$(chroot "$ROOTFS" /var/unitotem-venv/bin/python3 -c "
import json,sys,urllib.request as u
d=json.load(u.urlopen('https://api.github.com/repos/${CEF_RELEASE_REPO}/releases/tags/${CEF_RELEASE_TAG}'))
print(next((a['browser_download_url'] for a in d['assets'] if '-${PYTAG}-' in a['name'] and a['name'].endswith('linux_aarch64.whl')), ''))")
[ -n "$URL" ] || { echo "ERRORE: nessuna ruota cefpython3 ${PYTAG} aarch64 in ${CEF_RELEASE_REPO}@${CEF_RELEASE_TAG}" >&2; exit 1; }
WHL="$ROOTFS/tmp/$(basename "$URL")"
curl -fL -o "$WHL" "$URL"
chroot "$ROOTFS" /var/unitotem-venv/bin/pip3 install --no-cache-dir "/tmp/$(basename "$URL")"
rm -f -- "$WHL" "$ROOTFS/tmp/manager-requirements.txt"

# Slimming (the venv was 3.1 GB, 2.2 GB of it cefpython3; the slot is 6 GiB and was 94% full):
#  1. the aarch64 CEF wheel ships libcef.so with 1.7 GB of debug info + symbol tables (1980 MB file, 243 MB of real code); same for
#     libvk_swiftshader.so and libGLESv2.so. `strip --unneeded` keeps .dynsym (everything dlopen/linking needs).
#  2. the manager imports only QtCore/QtGui/QtWidgets (the page is shown by CEF, not QtWebEngine), but requirements.txt pulls the
#     whole PySide6 meta package: WebEngine (257 MB), Addons (161 MB), Pdf (6 MB) are removed, PySide6-Essentials + shiboken6 stay.
#  3. pip is not needed at runtime.
CEFDIR=/var/unitotem-venv/lib/python3.13/site-packages/cefpython3
for f in libcef.so libvk_swiftshader.so libGLESv2.so libEGL.so; do
    before=$(stat -c %s "$ROOTFS$CEFDIR/$f")
    chroot "$ROOTFS" strip --strip-unneeded "$CEFDIR/$f"
    echo ">>> stripped $f: $((before / 1048576)) MB -> $(( $(stat -c %s "$ROOTFS$CEFDIR/$f") / 1048576 )) MB"
done
chroot "$ROOTFS" /var/unitotem-venv/bin/pip3 uninstall -y PySide6 PySide6-Addons PySide6-WebEngine PySide6-Pdf pip
# the venv must still do its job after the slimming: CEF (the only thing that shows the page) and the three Qt modules the manager uses
chroot "$ROOTFS" /var/unitotem-venv/bin/python3 -c "
from cefpython3 import cefpython as cef
from PySide6 import QtCore, QtGui, QtWidgets
import shiboken6
print('venv slimmed: cefpython', cef.GetVersion()['cef_version'], '| PySide6', QtCore.__version__)"
# sanity: the native venv really holds aarch64 binaries
[ "$(chroot "$ROOTFS" /var/unitotem-venv/bin/python3 -c 'import platform; print(platform.machine())')" = aarch64 ] \
    || { echo "ERRORE: il venv non e' aarch64" >&2; exit 1; }

mv "$ROOTFS/var/unitotem-venv" "$W/pkg/var/unitotem-venv"
dpkg-deb --root-owner-group -Zgzip -b "$W/pkg" "$OUT/unitotem-manager_${VER}_arm64.deb"
ls -la "$OUT/unitotem-manager_${VER}_arm64.deb"
