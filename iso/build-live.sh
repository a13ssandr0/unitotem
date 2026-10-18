#!/bin/bash
set -euo pipefail

LIVE_ROOT=/tmp/live-root
ISO_ROOT=/tmp/iso-root
RELEASE=bookworm
MIRROR=http://deb.debian.org/debian

echo "=== UniTotem — ISO Installer Build ==="

# ---- 1. Bootstrap live system ----------------------------------------

echo ">>> [1/7] Bootstrapping minimal live system..."
rm -rf "$LIVE_ROOT"
debootstrap --arch=amd64 \
    --include=systemd,systemd-sysv,udev,dbus,live-boot,initramfs-tools \
    "$RELEASE" "$LIVE_ROOT" "$MIRROR"

# ---- 2. Configure APT and install packages ---------------------------

cat > "$LIVE_ROOT/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

# Prevent service starts during build
echo -e '#!/bin/sh\nexit 101' > "$LIVE_ROOT/usr/sbin/policy-rc.d"
chmod +x "$LIVE_ROOT/usr/sbin/policy-rc.d"

mount --bind /dev      "$LIVE_ROOT/dev"
mkdir -p "$LIVE_ROOT/dev/pts"
mount --bind /dev/pts  "$LIVE_ROOT/dev/pts"
mount --bind /proc     "$LIVE_ROOT/proc"
mount --bind /sys      "$LIVE_ROOT/sys"

echo ">>> [2/7] Installing live system packages..."
chroot "$LIVE_ROOT" apt-get update -q
chroot "$LIVE_ROOT" apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot live-boot-initramfs-tools live-config live-config-systemd \
    whiptail tzdata \
    debootstrap \
    parted gdisk \
    dosfstools e2fsprogs \
    curl ca-certificates wget \
    iw wpasupplicant dhcpcd5 \
    iproute2 iputils-ping net-tools \
    pciutils usbutils \
    util-linux gnupg2 \
    kbd

chroot "$LIVE_ROOT" apt-get clean
rm -rf "$LIVE_ROOT/var/lib/apt/lists/"*

# Make sure initrd is rebuilt with live-boot hooks
KVER=$(ls "$LIVE_ROOT/boot/vmlinuz-"* | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
echo ">>> Kernel version: $KVER"
chroot "$LIVE_ROOT" update-initramfs -u -k "$KVER"

# ---- 3. Configure live system ----------------------------------------

echo ">>> [3/7] Configuring live system..."

# Root auto-login on tty1
mkdir -p "$LIVE_ROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$LIVE_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Installer systemd service
cat > "$LIVE_ROOT/etc/systemd/system/unitotem-installer.service" << 'EOF'
[Unit]
Description=UniTotem Installer
After=live-config.service network.target
ConditionPathExists=/usr/local/bin/unitotem-installer.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/unitotem-installer.sh
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
RemainAfterExit=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
chroot "$LIVE_ROOT" systemctl enable unitotem-installer.service

# Copy installer script and bundled kiosk files
install -m 755 /iso-src/installer.sh "$LIVE_ROOT/usr/local/bin/unitotem-installer.sh"
mkdir -p "$LIVE_ROOT/usr/local/share/unitotem/files"
cp -r /iso-src/unitotem-files/. "$LIVE_ROOT/usr/local/share/unitotem/files/"

# live-config: set hostname, disable most tweaks
mkdir -p "$LIVE_ROOT/etc/live/config"
cat > "$LIVE_ROOT/etc/live/config/unitotem.conf" << 'EOF'
LIVE_HOSTNAME="unitotem-installer"
LIVE_USERNAME=""
LIVE_USER_DEFAULT_GROUPS=""
EOF

rm -f "$LIVE_ROOT/usr/sbin/policy-rc.d"
umount -lf "$LIVE_ROOT/dev/pts" 2>/dev/null || true
umount -lf "$LIVE_ROOT/dev"     2>/dev/null || true
umount -lf "$LIVE_ROOT/proc"    2>/dev/null || true
umount -lf "$LIVE_ROOT/sys"     2>/dev/null || true

# ---- 4. Build squashfs -----------------------------------------------

echo ">>> [4/7] Building squashfs..."
mkdir -p "$ISO_ROOT/live"
mksquashfs "$LIVE_ROOT" "$ISO_ROOT/live/filesystem.squashfs" \
    -comp xz -Xbcj x86 \
    -no-progress \
    -e boot -e proc -e sys -e dev -e run 2>/dev/null

# Copy kernel and initrd
cp "$LIVE_ROOT/boot/vmlinuz-$KVER"  "$ISO_ROOT/live/vmlinuz"
cp "$LIVE_ROOT/boot/initrd.img-$KVER" "$ISO_ROOT/live/initrd.img"

# ---- 5. BIOS boot (ISOLINUX) -----------------------------------------

echo ">>> [5/7] Setting up BIOS boot (ISOLINUX)..."
mkdir -p "$ISO_ROOT/isolinux"
cp /usr/lib/ISOLINUX/isolinux.bin         "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32  "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/modules/bios/menu.c32     "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/modules/bios/libutil.c32  "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/modules/bios/libcom32.c32 "$ISO_ROOT/isolinux/"

cat > "$ISO_ROOT/isolinux/isolinux.cfg" << 'EOF'
UI menu.c32
PROMPT 0
TIMEOUT 50

MENU TITLE UniTotem Installer
MENU COLOR title        * #2282F2 #00000000 *
MENU COLOR sel          * #ffffff #2282F2 *
MENU COLOR unsel        * #aaaaaa #00000000 *

LABEL install
    MENU LABEL UniTotem Installer
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live components quiet splash

LABEL install-debug
    MENU LABEL UniTotem Installer (verbose)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live components
EOF

# ---- 6. UEFI boot (GRUB) --------------------------------------------

echo ">>> [6/7] Setting up UEFI boot (GRUB)..."
mkdir -p "$ISO_ROOT/boot/grub"

cat > "$ISO_ROOT/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

insmod all_video
insmod gfxterm
terminal_output gfxterm

menuentry "UniTotem Installer" {
    linux  /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "UniTotem Installer (verbose)" {
    linux  /live/vmlinuz boot=live components
    initrd /live/initrd.img
}
EOF

# Build standalone GRUB EFI binary (includes a stub grub.cfg that finds the ISO)
cat > /tmp/grub-early.cfg << 'EOF'
search --no-floppy --file --set=root /live/vmlinuz
set prefix=($root)/boot/grub
source $prefix/grub.cfg
EOF

grub-mkstandalone \
    -O x86_64-efi \
    -o /tmp/bootx64.efi \
    --modules="part_gpt part_msdos fat iso9660 normal boot linux echo \
               all_video search gfxterm gfxterm_background minicmd ls \
               cat test linuxefi" \
    "boot/grub/grub.cfg=/tmp/grub-early.cfg"

# Create FAT EFI image to embed in ISO (El Torito EFI boot)
# Use loop-mount instead of mtools to avoid FAT32 cluster count issues
EFI_IMG="$ISO_ROOT/boot/grub/efiboot.img"
truncate -s 10M "$EFI_IMG"
mkfs.fat -F16 "$EFI_IMG"
EFI_MNT=/tmp/efi-mnt
mkdir -p "$EFI_MNT"
mount -o loop "$EFI_IMG" "$EFI_MNT"
mkdir -p "$EFI_MNT/EFI/boot"
cp /tmp/bootx64.efi "$EFI_MNT/EFI/boot/bootx64.efi"
umount "$EFI_MNT"

# Also place EFI binary directly in the ISO tree (for USB EFI discovery)
mkdir -p "$ISO_ROOT/EFI/boot"
cp /tmp/bootx64.efi "$ISO_ROOT/EFI/boot/bootx64.efi"

# ---- 7. Build hybrid ISO (BIOS + UEFI) ------------------------------

echo ">>> [7/7] Building hybrid ISO..."
ISO_DATE="$(date +%Y-%m-%d)"
ISO_FILE="/deploy/unitotem-installer-${ISO_DATE}-amd64.iso"

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "UNITOTEM_INSTALLER" \
    \
    -eltorito-boot   isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    \
    --eltorito-alt-boot \
    -e boot/grub/efiboot.img \
    -no-emul-boot \
    \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    \
    -output "$ISO_FILE" \
    "$ISO_ROOT"

echo ""
echo "=== ISO build complete ==="
ls -lh "$ISO_FILE"
