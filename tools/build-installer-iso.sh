#!/bin/bash
# Builds the amd64 installer ISO (hybrid: BIOS El Torito + EFI, also writable raw to a USB stick) from a flash image.
# Usage: tools/build-installer-iso.sh --flash unitotem-<date>-amd64-flash.img.xz [--out DIR] [--date YYYY-MM-DD]
#          [--kernel FILE --initrd FILE]
# Output: DIR/unitotem-installer-<date>-amd64.iso and .sha256 (default DIR: work/installer-iso).
# Kernel, initrd and the signed Secure Boot chain (shim, MokManager, GRUB) come from the flash image's EFI partition
# (unitotem/recovery-vmlinuz, unitotem/recovery-initrd.img, EFI/unitotem-sb/); --kernel/--initrd override the first two.
# Runs in a debian:trixie container (docker) unless the tools are present and INSTALLER_ISO_INNER=1.
# Design and tests: docs/system/installer-iso.md.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FLASH='' OUT="$HERE/work/installer-iso" DATE='' KERNEL='' INITRD=''
while [ $# -gt 0 ]; do
    case $1 in
        --flash)  FLASH=$2; shift 2 ;;
        --out)    OUT=$2; shift 2 ;;
        --date)   DATE=$2; shift 2 ;;
        --kernel) KERNEL=$2; shift 2 ;;
        --initrd) INITRD=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -f "$FLASH" ] || { echo "flash image not found: $FLASH" >&2; exit 2; }
FLASH=$(readlink -f -- "$FLASH")
base=$(basename -- "$FLASH")
[[ $base =~ ^unitotem-([0-9]{4}-[0-9]{2}-[0-9]{2})-amd64-flash\.img\.xz$ ]] || { echo "not an amd64 flash image: $base" >&2; exit 2; }
[ -n "$DATE" ] || DATE=${BASH_REMATCH[1]}
[[ $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date: $DATE" >&2; exit 2; }
mkdir -p -- "$OUT"
OUT=$(readlink -f -- "$OUT")

if [ "${INSTALLER_ISO_INNER:-}" != 1 ]; then
    command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
    mounts=() args=()
    [ -n "$KERNEL" ] && { mounts+=(-v "$(dirname -- "$(readlink -f -- "$KERNEL")"):/kin:ro"); args+=(--kernel "/kin/$(basename -- "$KERNEL")"); }
    [ -n "$INITRD" ] && { mounts+=(-v "$(dirname -- "$(readlink -f -- "$INITRD")"):/iin:ro"); args+=(--initrd "/iin/$(basename -- "$INITRD")"); }
    exec docker run --rm -e INSTALLER_ISO_INNER=1 -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
        -v "$HERE:/repo:ro" -v "$(dirname -- "$FLASH"):/in:ro" -v "$OUT:/out" "${mounts[@]}" \
        debian:trixie bash /repo/tools/build-installer-iso.sh --flash "/in/$base" --out /out --date "$DATE" "${args[@]}"
fi

# ---------------------------------------------------------------- inside the container
export DEBIAN_FRONTEND=noninteractive
if ! command -v xorriso >/dev/null || ! command -v grub-mkimage >/dev/null || ! command -v mcopy >/dev/null || ! command -v unmkinitramfs >/dev/null || ! command -v zstd >/dev/null || ! command -v readelf >/dev/null || ! command -v python3 >/dev/null; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends xorriso grub-pc-bin grub-common mtools dosfstools gdisk xz-utils cpio gzip coreutils initramfs-tools-core zstd kmod binutils python3 util-linux >/dev/null
fi

W=$(mktemp -d /tmp/installer-iso.XXXXXX)
trap 'rm -rf -- "$W"' EXIT
TREE=$W/tree; ESPDIR=$W/esp; OVL=$W/overlay
mkdir -p "$TREE/boot/grub" "$TREE/boot/unitotem" "$TREE/unitotem" "$ESPDIR" "$OVL/usr/lib/unitotem" "$OVL/scripts/init-premount"

echo "== extract kernel, initrd and Secure Boot chain from the EFI partition"
# The EFI partition is the first partition; read only its bytes from the start of the image.
head -c 2MiB < <(xz -dc -- "$FLASH") > "$W/head.img" 2>/dev/null || true
read -r ESP_START ESP_SIZE < <(sgdisk -i 1 "$W/head.img" 2>/dev/null | awk '/^First sector/ {s=$3} /^Partition size/ {z=$3} END {print s, z}')
[[ ${ESP_START:-} =~ ^[0-9]+$ && ${ESP_SIZE:-} =~ ^[0-9]+$ ]] || { echo "cannot read the partition table of $base" >&2; exit 1; }
set +o pipefail
xz -dc -- "$FLASH" | head -c $(( (ESP_START + ESP_SIZE) * 512 )) > "$W/esp-region.img"
set -o pipefail
IMGP="$W/esp-region.img@@$((ESP_START * 512))"
export MTOOLS_SKIP_CHECK=1
mkdir -p "$W/x"
mcopy -i "$IMGP" ::unitotem/recovery-vmlinuz ::unitotem/recovery-initrd.img ::unitotem/recovery.sha256 "$W/x/"
for f in shimx64.efi mmx64.efi grubx64.efi; do mcopy -i "$IMGP" "::EFI/unitotem-sb/$f" "$ESPDIR/$f"; done
[ -z "$KERNEL" ] || cp -- "$KERNEL" "$W/x/recovery-vmlinuz"
[ -z "$INITRD" ] || cp -- "$INITRD" "$W/x/recovery-initrd.img"
if [ -z "$KERNEL$INITRD" ]; then
    (cd "$W/x" && grep -v '^#' recovery.sha256 | sha256sum -c --quiet -)
fi
rm -f -- "$W/esp-region.img" "$W/head.img"
cp -- "$W/x/recovery-vmlinuz" "$TREE/boot/unitotem/vmlinuz"
cp -- "$W/x/recovery-initrd.img" "$TREE/boot/unitotem/initrd.img"

echo "== payload"
cp -- "$FLASH" "$TREE/unitotem/$base"
XZ_BYTES=$(stat -c %s -- "$FLASH")
XZ_SHA=$(sha256sum -- "$FLASH" | cut -d' ' -f1)
RAW_BYTES=$(xz --robot -l -- "$FLASH" | awk '$1 == "totals" {print $5}')
RAW_SHA=$(xz -dc -- "$FLASH" | sha256sum | cut -d' ' -f1)
[[ $RAW_SHA =~ ^[0-9a-f]{64}$ && $RAW_BYTES =~ ^[0-9]+$ ]] || { echo "cannot hash the flash image" >&2; exit 1; }
cat > "$TREE/unitotem/payload.info" <<EOF
image=$base
xz_sha256=$XZ_SHA
xz_bytes=$XZ_BYTES
raw_sha256=$RAW_SHA
raw_bytes=$RAW_BYTES
EOF

echo "== installer initramfs (the recovery initramfs, reduced)"
# unmkinitramfs unpacks the early microcode archive and the main archive; only the main one is kept.
RT=$W/rtree
unmkinitramfs "$TREE/boot/unitotem/initrd.img" "$W/unpacked" >/dev/null
if [ -d "$W/unpacked/main" ]; then mv "$W/unpacked/main" "$RT"; else mv "$W/unpacked" "$RT"; fi
RECOVERY_BYTES=$(stat -c %s -- "$TREE/boot/unitotem/initrd.img")
python3 -I "$HERE/tools/slim-installer-initrd.py" "$RT"
[ ! -e "$RT/usr/bin/install" ] || { echo "the recovery initramfs already has /usr/bin/install" >&2; exit 1; }
install -m 755 -- "$HERE/unitotem/files/unitotem-installer" "$RT/usr/bin/install"
install -m 755 -- "$HERE/unitotem/files/unitotem-ssh" "$RT/usr/bin/unitotem-ssh"
install -m 755 -- "$HERE/unitotem/files/unitotem-installer-start" "$RT/usr/lib/unitotem/unitotem-installer-start"
install -m 755 -- "$(command -v flock)" "$RT/usr/bin/flock"
# replaces the recovery initramfs' init-premount entry (always the OTA fallback)
cat > "$RT/scripts/init-premount/zz-unitotem-ota" <<'EOF2'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac
exec /usr/lib/unitotem/unitotem-installer-start
EOF2
chmod 755 "$RT/scripts/init-premount/zz-unitotem-ota"
# the programs the installer and the console screen run must exist; the ones it never runs must not
for c in bash whiptail pv xz dd sha256sum sgdisk blockdev blkid lsblk mount umount mountpoint udevadm dropbear dropbearkey \
         ip ipconfig awk sed tr cut od cmp cp mv head tail grep readlink stty setsid kill sleep sync reboot poweroff flock \
         modprobe; do
    [ -e "$RT/usr/bin/$c" ] || [ -e "$RT/usr/sbin/$c" ] || { echo "installer initramfs lacks $c" >&2; exit 1; }
done
for c in partclone.restore wpa_supplicant plymouth grub-install parted; do
    [ ! -e "$RT/usr/bin/$c" ] && [ ! -e "$RT/usr/sbin/$c" ] || { echo "installer initramfs still has $c" >&2; exit 1; }
done
(cd "$RT" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --quiet --owner 0:0 | xz -9 -T0 --check=crc32) > "$TREE/boot/unitotem/initrd.img"
INITRD_BYTES=$(stat -c %s -- "$TREE/boot/unitotem/initrd.img")
echo "initramfs: recovery $RECOVERY_BYTES bytes, installer $INITRD_BYTES bytes"

echo "== GRUB"
cat > "$TREE/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0
terminal_output console
# menu also on the first serial port when one exists (headless installs)
if serial --unit=0 --speed=115200; then
    terminal_input --append serial
    terminal_output --append serial
fi
menuentry "Install UniTotem" {
    linux /boot/unitotem/vmlinuz quiet loglevel=3 consoleblank=0 plymouth.enable=0 console=tty0
    initrd /boot/unitotem/initrd.img
}
menuentry "Install UniTotem (serial console)" {
    linux /boot/unitotem/vmlinuz quiet loglevel=3 consoleblank=0 plymouth.enable=0 console=tty0 console=ttyS0,115200 unitotem.installer.tty=ttyS0
    initrd /boot/unitotem/initrd.img
}
menuentry "Install UniTotem (safe graphics)" {
    linux /boot/unitotem/vmlinuz quiet loglevel=3 consoleblank=0 plymouth.enable=0 nomodeset console=tty0
    initrd /boot/unitotem/initrd.img
}
EOF
: > "$TREE/boot/grub/unitotem-iso"
# BIOS: core image with the modules it needs built in, eltorito boot image = cdboot + core
mkdir -p "$TREE/boot/grub/i386-pc"
cp -- /usr/lib/grub/i386-pc/*.mod /usr/lib/grub/i386-pc/*.lst "$TREE/boot/grub/i386-pc/"
grub-mkimage -O i386-pc -o "$W/core.img" -p /boot/grub biosdisk iso9660 part_msdos part_gpt normal linux configfile search search_fs_file echo test
cat /usr/lib/grub/i386-pc/cdboot.img "$W/core.img" > "$TREE/boot/grub/eltorito.img"
# UEFI: Debian-signed shim -> signed GRUB (monolithic), configuration stub next to them
mkdir -p "$ESPDIR/EFI/BOOT" "$ESPDIR/EFI/debian"
mv -- "$ESPDIR/shimx64.efi" "$ESPDIR/EFI/BOOT/BOOTX64.EFI"
mv -- "$ESPDIR/mmx64.efi" "$ESPDIR/EFI/BOOT/mmx64.efi"
cp -- "$ESPDIR/grubx64.efi" "$ESPDIR/EFI/BOOT/grubx64.efi"
mv -- "$ESPDIR/grubx64.efi" "$ESPDIR/EFI/debian/grubx64.efi"
cat > "$ESPDIR/EFI/BOOT/grub.cfg" <<'EOF'
search --file --set=root /boot/grub/unitotem-iso
configfile /boot/grub/grub.cfg
EOF
cp -- "$ESPDIR/EFI/BOOT/grub.cfg" "$ESPDIR/EFI/debian/grub.cfg"
# GRUB takes its prefix from the CD device, so the configuration stub is also on the ISO filesystem
cp -a -- "$ESPDIR/EFI" "$TREE/EFI"
truncate -s 24M "$W/esp.img"
mkfs.vfat -F 16 -n UNITOTEMEFI "$W/esp.img" >/dev/null
(cd "$ESPDIR" && mcopy -s -i "$W/esp.img" EFI ::)

echo "== ISO"
# No SSH public key line may ship in the text files of the payload (exceptions: none).
if grep -rIlE -e '(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) +[A-Za-z0-9+/=]{40,}' -- "$TREE"; then
    echo "build refused: an SSH public key line is in the payload (files above)" >&2; exit 1
fi
ISO="$OUT/unitotem-installer-$DATE-amd64.iso"
rm -f -- "$ISO"
xorriso -as mkisofs -quiet -iso-level 3 -full-iso9660-filenames -rational-rock -volid UNITOTEM_ISO \
    -publisher UniTotem -appid "UniTotem installer" \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img -partition_offset 16 \
    -appended_part_as_gpt -append_partition 2 0xef "$W/esp.img" -iso_mbr_part_type 0x00 \
    -c boot/grub/boot.cat -b boot/grub/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
    -o "$ISO" "$TREE"
(cd "$OUT" && sha256sum "$(basename -- "$ISO")" > "$(basename -- "$ISO").sha256")
if [ -n "${HOST_UID:-}" ]; then chown "$HOST_UID:$HOST_GID" -- "$ISO" "$ISO.sha256"; fi
ls -l -- "$ISO"
echo "payload raw bytes $RAW_BYTES sha256 $RAW_SHA"
