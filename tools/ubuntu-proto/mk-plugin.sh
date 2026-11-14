#!/bin/bash
# Runs INSIDE the test VM after the driver packages are installed: builds the sysext tree of the NVIDIA files into /root/ext-$1.
# $1 = tag (e.g. nvidia-580). Files: every file of the NVIDIA-related packages under /usr, the signed modules directory and
# the regenerated module indexes (the extension's modules.dep wins over the base's in the merged /usr).
set -euo pipefail
TAG=$1; OUT=/root/ext-$TAG; KVER=$(uname -r)
rm -rf "$OUT"; mkdir -p "$OUT/usr/lib/extension-release.d"
pk=$(dpkg-query -W -f='${Package}\n' | grep -E 'nvidia|ocl-icd|egl-wayland|libnvidia' || true)
for p in $pk; do dpkg -L "$p"; done | sed -E 's#^/(lib|bin|sbin)/#/usr/\1/#' | sort -u | grep '^/usr/' | while read -r f; do
    [ -f "$f" ] || [ -L "$f" ] || continue
    case "$f" in /usr/lib/modules/*/kernel/nvidia-*) continue;; /usr/share/doc/*|/usr/share/man/*|/usr/share/lintian/*|/usr/lib/modules/*/modules.*) continue;; esac
    cp -a --parents "$f" "$OUT"
done
# the signed modules are assembled by the packages' postinst: not owned by a package, taken from the directory (only the tag's own)
find "/usr/lib/modules/$KVER/kernel/${2:-$TAG}" -type f | while read -r f; do cp -a --parents "$f" "$OUT"; done
for f in /usr/lib/modules/$KVER/modules.*; do [ -f "$f" ] && cp -a --parents "$f" "$OUT"; done
# systemd units that live in /etc become /usr/lib ones
mkdir -p "$OUT/usr/lib/modprobe.d"; [ -f /etc/modprobe.d/nvidia-graphics-drivers-kms.conf ] && cp /etc/modprobe.d/nvidia-graphics-drivers-kms.conf "$OUT/usr/lib/modprobe.d/"
ID=$(. /etc/os-release; echo "$ID"); VID=$(. /etc/os-release; echo "$VERSION_ID")
printf 'ID=%s\nVERSION_ID=%s\nSYSEXT_LEVEL=%s\nSYSEXT_ID=unitotem-%s\n' "$ID" "$VID" 1 "$TAG" >"$OUT/usr/lib/extension-release.d/extension-release.unitotem-$TAG"
du -sh "$OUT"; find "$OUT" -type f | wc -l
mksquashfs "$OUT" "/root/unitotem-$TAG-$KVER.sysext.raw" -comp zstd -Xcompression-level 19 -noappend -quiet
ls -la /root/unitotem-$TAG-$KVER.sysext.raw
