#!/bin/bash
# Builds the Windows installer folder and zip from an amd64 flash image.
#   tools/build-windows-installer.sh [--image FILE.img.xz] [--initrd FILE] [--out DIR]
# Output: DIR/unitotem-windows-installer.zip and DIR/SHA256SUMS (default DIR: work/windows-installer).
set -euo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=""; INITRD=""; OUT="$DIR/work/windows-installer"
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE=${2:?}; shift 2 ;;
        --initrd) INITRD=${2:?}; shift 2 ;;
        --out) OUT=${2:?}; shift 2 ;;
        *) echo "usage: $0 [--image FILE.img.xz] [--initrd FILE] [--out DIR]" >&2; exit 1 ;;
    esac
done
if [ -z "$IMAGE" ]; then
    IMAGE=$(ls -1 "$DIR"/work/flash-images/unitotem-*-amd64-flash.img.xz | sort | tail -n 1)
fi
[ -f "$IMAGE" ] || { echo "image not found: $IMAGE" >&2; exit 1; }
for t in xz sfdisk mcopy zip sha256sum curl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

SRC="$DIR/tools/windows-installer"
WORK=$(mktemp -d "$DIR/work/winins.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
STAGE="$WORK/unitotem-windows-installer"
mkdir -p "$STAGE/payload" "$OUT"

# EFI System partition of the flash image: start and size from the GPT in the first MiB.
xz -dc -- "$IMAGE" | head -c 1048576 > "$WORK/head.img" || true   # SIGPIPE from head is expected
[ "$(stat -c %s "$WORK/head.img")" -eq 1048576 ] || { echo "cannot read the image" >&2; exit 1; }
read -r START SIZE < <(python3 -I - "$WORK/head.img" <<'PY'
# Primary GPT: header at LBA 1, entries from the LBA it names; the EFI System partition type GUID.
import struct, sys, uuid
d = open(sys.argv[1], "rb").read()
assert d[512:520] == b"EFI PART", "no GPT"
lba, n, size = struct.unpack_from("<QII", d, 512 + 72)
esp = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
for i in range(n):
    e = d[lba * 512 + i * size: lba * 512 + (i + 1) * size]
    if e[:16] == esp:
        first, last = struct.unpack_from("<QQ", e, 32)
        print(first, last - first + 1)
        break
else:
    raise SystemExit("no EFI System partition")
PY
)
[[ $START =~ ^[0-9]+$ && $SIZE =~ ^[0-9]+$ ]] || { echo "cannot read the partition table" >&2; exit 1; }
END=$(( (START + SIZE) * 512 ))
xz -dc -- "$IMAGE" | head -c "$END" > "$WORK/esp.img" || true
[ "$(stat -c %s "$WORK/esp.img")" -eq "$END" ] || { echo "short read of the ESP" >&2; exit 1; }
M="$WORK/esp.img@@$((START * 512))"
mcopy -n -i "$M" ::unitotem/recovery-vmlinuz "$STAGE/payload/vmlinuz"
mcopy -n -i "$M" ::unitotem/recovery-initrd.img "$STAGE/payload/initrd.img"
mcopy -n -i "$M" ::EFI/BOOT/BOOTX64.EFI "$STAGE/payload/shimx64.efi"; for f in mmx64.efi grubx64.efi; do mcopy -n -i "$M" "::EFI/BOOT/$f" "$STAGE/payload/$f"; done
rm -f -- "$WORK/esp.img" "$WORK/head.img"
[ -z "$INITRD" ] || cp -- "$INITRD" "$STAGE/payload/initrd.img"

# Legacy BIOS boot method: GRUB4DOS (GPL-2.0), pinned by the SHA-256 of the official release archive.
G4D_URL=https://github.com/chenall/grub4dos/releases/download/2020-08-09-0da21fe/grub4dos-0.4.6a-2020-08-09.7z
G4D_SHA256=73fd88d7eb231bf0321f6159e0f40e7d4dd18529d8b6f6dde2a0f1b2555c571f
command -v 7z >/dev/null || { echo "missing tool: 7z (p7zip-full)" >&2; exit 1; }
curl -fsSL --retry 3 -o "$WORK/grub4dos.7z" -- "$G4D_URL"
GOT=$(sha256sum -- "$WORK/grub4dos.7z" | cut -d' ' -f1)
[ "$GOT" = "$G4D_SHA256" ] || { echo "grub4dos archive hash mismatch: $GOT" >&2; exit 1; }
7z x -y -o"$WORK/g4d" "$WORK/grub4dos.7z" >/dev/null
for f in grldr grldr.mbr COPYING; do cp -- "$WORK/g4d/grub4dos-0.4.6a/$f" "$STAGE/payload/$f"; done
mv -- "$STAGE/payload/COPYING" "$STAGE/payload/COPYING-grub4dos"

cp -- "$SRC/Install-UniTotem.ps1" "$SRC/grub.cfg.template" "$SRC/menu.lst.template" "$STAGE/payload/"
mv -- "$STAGE/payload/Install-UniTotem.ps1" "$STAGE/Install-UniTotem.ps1"
cp -- "$SRC/README.txt" "$STAGE/README.txt"
( cd "$STAGE/payload" && sha256sum vmlinuz initrd.img shimx64.efi mmx64.efi grubx64.efi grldr grldr.mbr COPYING-grub4dos grub.cfg.template menu.lst.template > SHA256SUMS )
# No SSH public key line may ship in the text files of the payload (exceptions: none).
if grep -rIlE -e '(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) +[A-Za-z0-9+/=]{40,}' -- "$STAGE"; then
    echo "build refused: an SSH public key line is in the payload (files above)" >&2; exit 1
fi
# Windows PowerShell 5.1 reads BOM-less files as ANSI: the script must be pure ASCII.
if LC_ALL=C grep -q -P '[^\x00-\x7F]' "$STAGE/Install-UniTotem.ps1"; then echo "non-ASCII in Install-UniTotem.ps1" >&2; exit 1; fi
# CRLF line endings for the text files read on Windows.
for f in "$STAGE/Install-UniTotem.ps1" "$STAGE/README.txt"; do sed -i 's/$/\r/' "$f"; done

rm -f -- "$OUT/unitotem-windows-installer.zip"
( cd "$WORK" && zip -q -r "$OUT/unitotem-windows-installer.zip" unitotem-windows-installer )
( cd "$OUT" && sha256sum unitotem-windows-installer.zip > SHA256SUMS )
cat "$OUT/SHA256SUMS"; ls -l "$OUT/unitotem-windows-installer.zip"
