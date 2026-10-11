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
CEF_RELEASE_TAG="${CEF_RELEASE_TAG:-v147.0.0-arm64}"

W=$(mktemp -d); trap 'rm -rf -- "$W"' EXIT
dpkg-deb -R "$SRC" "$W/pkg"
VER=$(dpkg-deb -f "$SRC" Version)
echo ">>> manager arm64: repackaging $(basename "$SRC") ($VER); dropping its amd64 venv, building a native one"
rm -rf -- "$W/pkg/var/unitotem-venv"
sed -i 's/^Architecture: .*/Architecture: arm64/' "$W/pkg/DEBIAN/control"
grep -q '^Architecture: arm64$' "$W/pkg/DEBIAN/control"

# the venv has absolute paths in its scripts: it must be built where it will live, so build it in the chroot at /var/unitotem-venv
chroot "$ROOTFS" rm -rf /var/unitotem-venv
cp "$W/pkg/usr/share/unitotem-manager/requirements.txt" "$ROOTFS/tmp/manager-requirements.txt"
chroot "$ROOTFS" python3 -m venv --system-site-packages --copies /var/unitotem-venv
chroot "$ROOTFS" /var/unitotem-venv/bin/pip3 install --no-cache-dir -r /tmp/manager-requirements.txt
PYTAG=$(chroot "$ROOTFS" /var/unitotem-venv/bin/python3 -c "import sys; print(f'cp{sys.version_info[0]}{sys.version_info[1]}')")
URL=$(python3 -c "
import json,sys,urllib.request as u
d=json.load(u.urlopen('https://api.github.com/repos/${CEF_RELEASE_REPO}/releases/tags/${CEF_RELEASE_TAG}'))
print(next((a['browser_download_url'] for a in d['assets'] if '-${PYTAG}-' in a['name'] and a['name'].endswith('linux_aarch64.whl')), ''))")
[ -n "$URL" ] || { echo "ERRORE: nessuna ruota cefpython3 ${PYTAG} aarch64 in ${CEF_RELEASE_REPO}@${CEF_RELEASE_TAG}" >&2; exit 1; }
WHL="$ROOTFS/tmp/$(basename "$URL")"
curl -fL -o "$WHL" "$URL"
chroot "$ROOTFS" /var/unitotem-venv/bin/pip3 install --no-cache-dir "/tmp/$(basename "$URL")"
rm -f -- "$WHL" "$ROOTFS/tmp/manager-requirements.txt"
# sanity: the native venv really holds aarch64 binaries
[ "$(chroot "$ROOTFS" /var/unitotem-venv/bin/python3 -c 'import platform; print(platform.machine())')" = aarch64 ] \
    || { echo "ERRORE: il venv non e' aarch64" >&2; exit 1; }

mkdir -p "$W/pkg/var"
cp -a "$ROOTFS/var/unitotem-venv" "$W/pkg/var/unitotem-venv"
chroot "$ROOTFS" rm -rf /var/unitotem-venv
mkdir -p "$OUT"
dpkg-deb --root-owner-group -Zgzip -b "$W/pkg" "$OUT/unitotem-manager_${VER}_arm64.deb"
ls -la "$OUT/unitotem-manager_${VER}_arm64.deb"
