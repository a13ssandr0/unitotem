#!/bin/bash
# arm64 boot tree: the FIRMWARE content that the full image and the preboot card share, assembled once per build.
#   make-boot-tree.sh --out DIR (--stage2 TAR | --firmware DIR) --recovery-vmlinuz FILE --recovery-initrd FILE
#                     (--recovery-manifest FILE | --level N) --engine FILE
# Holds the Pi firmware (bootcode.bin, start*.elf, fixup*.dat, *.dtb, LICENCE.broadcom; the _x and _db variants left out),
# recovery8.img (the recovery kernel), recovery-initrd.img (the recovery initrd with the repository's engine appended: a later
# cpio entry replaces an earlier one; appended only when the stage-1b initrd lacks the identical engine), config.txt and cmdline.txt of the recovery boot, and boot-tree.sha256.
# Stage 3 copies the files into the full image; make-preboot-image.sh --tree writes them to the card. Docs: docs/system/build.md.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

OUT="" STAGE2="" FW="" RVM="" RIN="" MAN="" LEVEL="" ENGINE=""
die() { echo "make-boot-tree.sh: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift 2 ;;
        --stage2) STAGE2=$2; shift 2 ;;
        --firmware) FW=$2; shift 2 ;;
        --recovery-vmlinuz) RVM=$2; shift 2 ;;
        --recovery-initrd) RIN=$2; shift 2 ;;
        --recovery-manifest) MAN=$2; shift 2 ;;
        --level) LEVEL=$2; shift 2 ;;
        --engine) ENGINE=$2; shift 2 ;;
        *) die "unknown option $1" ;;
    esac
done
[ -n "$OUT" ] && [ -n "$RVM" ] && [ -n "$RIN" ] && [ -n "$ENGINE" ] || die "--out, --recovery-vmlinuz, --recovery-initrd and --engine are required"
if { [ -n "$STAGE2" ] && [ -n "$FW" ]; } || { [ -z "$STAGE2" ] && [ -z "$FW" ]; }; then
    die "give exactly one of --stage2 and --firmware"
fi
if [ -n "$MAN" ]; then
    [ -z "$LEVEL" ] || die "give --recovery-manifest or --level, not both"
    LEVEL=$(sed -n 's/^UNITOTEM_RECOVERY_BUILD_DATE=//p' "$MAN" | tr -cd '0-9')
fi
# Level of the set: the build date as 14 digits (2026-10-19T05:56:32Z -> 20261019055632).
[[ "$LEVEL" =~ ^[0-9]{14}$ ]] || die "recovery level is not 14 digits ('$LEVEL')"
for f in "$RVM" "$RIN" "$ENGINE"; do [ -s "$f" ] || die "missing $f"; done

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/boot-tree.XXXXXX")
trap 'rm -rf -- "$TMPROOT"' EXIT

# Firmware source: the boot firmware of stage 2 (overlays are not part of the tree).
if [ -n "$STAGE2" ]; then
    [ -s "$STAGE2" ] || die "missing $STAGE2"
    DECOMPRESS=$(command -v pigz || command -v gzip)
    "$DECOMPRESS" -dc -- "$STAGE2" | tar -C "$TMPROOT" -xf - --exclude='./boot/firmware/overlays' ./boot/firmware
    FW="$TMPROOT/boot/firmware"
fi
[ -d "$FW" ] || die "no firmware directory $FW"

rm -rf -- "$OUT"
mkdir -p -- "$OUT"
shopt -s nullglob
for src in "$FW"/bootcode.bin "$FW"/start*.elf "$FW"/fixup*.dat "$FW"/*.dtb "$FW"/LICENCE.broadcom; do
    [ -f "$src" ] && cp -- "$src" "$OUT/"
done
shopt -u nullglob
# the Pi 3 and Pi 4 firmware and device trees are what the arm64 boards need; the extra start*_x/_db variants stay out
rm -f -- "$OUT"/start_x.elf "$OUT"/start4x.elf "$OUT"/start_db.elf "$OUT"/start4db.elf \
         "$OUT"/fixup_x.dat "$OUT"/fixup4x.dat "$OUT"/fixup_db.dat "$OUT"/fixup4db.dat
for need in start.elf fixup.dat bcm2710-rpi-3-b.dtb start4.elf fixup4.dat bcm2711-rpi-4-b.dtb; do
    [ -s "$OUT/$need" ] || die "the firmware does not contain $need"
done

cp -- "$RVM" "$OUT/recovery8.img"
cp -- "$RIN" "$OUT/recovery-initrd.img"
# The repository's engine, whatever engine the stored recovery initrd was built with. Stage 1b already puts the current engine in the
# initrd: then the file is kept byte for byte. Absent or different (a later entry replaces an earlier one): appended.
if python3 -I "$HERE/initrd-scan.py" get "$RIN" usr/lib/unitotem/ota-engine.sh > "$TMPROOT/rin-engine" 2>/dev/null \
   && cmp -s -- "$TMPROOT/rin-engine" "$ENGINE"; then
    echo "recovery initrd: the repository's engine is already in it, not appended"
else
    install -D -m 755 -- "$ENGINE" "$TMPROOT/ov/usr/lib/unitotem/ota-engine.sh"
    touch -d @0 -- "$TMPROOT/ov/usr/lib/unitotem/ota-engine.sh"
    # --reproducible and --renumber-inodes: the same engine gives the same bytes in every build (the tree is compared byte for byte)
    ( cd "$TMPROOT/ov" && printf 'usr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet --owner=0:0 --reproducible --renumber-inodes ) >> "$OUT/recovery-initrd.img"
fi

# Same settings as the resident fallback of a deployed device (ota-engine.sh set-default-recovery): 640x480 DMT mode so the
# text is readable from a distance. ttyS0 is the header UART.
cat > "$OUT/config.txt" << 'EOF2'
arm_64bit=1
enable_uart=1
hdmi_group=2
hdmi_mode=4
kernel=recovery8.img
initramfs recovery-initrd.img followkernel
EOF2
# unitotem.ota=recover: wait for the host with NO idle timeout (unitotem.ota=1 reboots after 30 minutes without a host)
echo "unitotem.ota=recover console=tty1 console=ttyS0,115200" > "$OUT/cmdline.txt"

# Checksums of every file of the tree, the level line first (boot-tree.sha256 is not in its own list).
NAMES=()
while IFS= read -r n; do NAMES+=("$n"); done < <(find "$OUT" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
{
    echo "# unitotem-recovery-level: $LEVEL"
    ( cd "$OUT" && sha256sum -- "${NAMES[@]}" )
} > "$OUT/boot-tree.sha256"
chmod 644 -- "$OUT"/*
sync
echo "boot tree: ${#NAMES[@]} files in $OUT, recovery level $LEVEL"
