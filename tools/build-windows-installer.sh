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
for t in xz sfdisk mcopy zip sha256sum docker; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

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
for f in shimx64.efi mmx64.efi grubx64.efi; do mcopy -n -i "$M" "::EFI/unitotem-sb/$f" "$STAGE/payload/$f"; done
rm -f -- "$WORK/esp.img" "$WORK/head.img"
[ -z "$INITRD" ] || cp -- "$INITRD" "$STAGE/payload/initrd.img"

# Legacy BIOS loader: lnxboot.img + core.img (modules built in, two-line embedded config), loaded by bootmgr.
cat > "$WORK/embedded.cfg" <<'CFG'
search --no-floppy --file --set=root /unitotem/recovery-vmlinuz
configfile /unitotem/grub.cfg
CFG
docker run --rm -v "$WORK:/w" debian:bookworm bash -c '
    set -e
    apt-get update -qq >/dev/null && apt-get install -y -qq grub-pc-bin grub-common >/dev/null
    grub-mkimage -O i386-pc -o /w/core.img -c /w/embedded.cfg -p /unitotem \
        biosdisk part_msdos part_gpt ntfs fat ext2 linux normal search search_fs_file echo configfile boot
    cat /usr/lib/grub/i386-pc/lnxboot.img /w/core.img > /w/g2.img
    dpkg -s grub-pc-bin | sed -n "s/^Version: /grub-pc-bin /p" > /w/grub-version.txt'
cp -- "$WORK/g2.img" "$STAGE/payload/g2.img"

cp -- "$SRC/Install-UniTotem.ps1" "$SRC/grub.cfg.template" "$SRC/grub-bios.cfg.template" "$STAGE/payload/" 
mv -- "$STAGE/payload/Install-UniTotem.ps1" "$STAGE/Install-UniTotem.ps1"
cp -- "$SRC/README.txt" "$STAGE/README.txt"
( cd "$STAGE/payload" && sha256sum vmlinuz initrd.img shimx64.efi mmx64.efi grubx64.efi g2.img grub.cfg.template grub-bios.cfg.template > SHA256SUMS )
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
