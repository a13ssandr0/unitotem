#!/bin/bash
# Builds the Ubuntu 26.04 base image (no GPU driver beyond Mesa): GPT, ESP + ROOT, Ubuntu shim/GRUB/kernel. Runs on the build server as root.
set -euo pipefail
W=/nas/build/ubuntu-proto
IMG=$W/${OUTNAME:-base}.img
M=$W/mnt
LOG=$W/build-base.log
exec >>"$LOG" 2>&1
echo "== $(date -u +%T) build-base start"
rm -f "$W/base.done"
cleanup() {
    for d in dev/pts dev sys proc boot/efi; do umount "$M/$d" 2>/dev/null || true; done
    umount "$M" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$M"
rm -f "$IMG"
truncate -s 8G "$IMG"
sgdisk -Z -n1:1M:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:ROOT "$IMG" >/dev/null
LOOP=$(losetup --show -fP "$IMG")
mkfs.vfat -F32 -n EFI "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L ROOT "${LOOP}p2"
mount "${LOOP}p2" "$M"
mkdir -p "$M/boot/efi"
mount "${LOOP}p1" "$M/boot/efi"
debootstrap --variant=minbase --components=main,universe,restricted,multiverse resolute "$M" http://archive.ubuntu.com/ubuntu
cat >"$M/etc/apt/sources.list" <<S
deb http://archive.ubuntu.com/ubuntu resolute main universe restricted multiverse
deb http://archive.ubuntu.com/ubuntu resolute-updates main universe restricted multiverse
deb http://security.ubuntu.com/ubuntu resolute-security main universe restricted multiverse
S
rm -f "$M/etc/apt/sources.list.d/ubuntu.sources"
printf 'LABEL=ROOT / ext4 defaults 0 1\nLABEL=EFI /boot/efi vfat umask=0077 0 2\n' >"$M/etc/fstab"
echo ubuntu-proto >"$M/etc/hostname"
mount -t proc proc "$M/proc"; mount -t sysfs sys "$M/sys"; mount --bind /dev "$M/dev"; mount -t devpts devpts "$M/dev/pts"
cat >"$M/etc/default/grub" <<S
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR=UniTotem-proto
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 root=LABEL=ROOT"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_LINUX_UUID=true
S
chroot "$M" env DEBIAN_FRONTEND=noninteractive bash -euxc '
apt-get update
apt-get install -y --no-install-recommends linux-image-generic linux-firmware shim-signed grub-efi-amd64-signed grub-efi-amd64 initramfs-tools systemd-sysv systemd-resolved openssh-server iproute2 kmod pciutils libdrm-tests libgl1-mesa-dri mesa-utils-bin dbus ca-certificates mokutil efibootmgr squashfs-tools zstd busybox-static
grub-install --target=x86_64-efi --efi-directory=/boot/efi --uefi-secure-boot --removable --no-nvram
update-grub
mkdir -p /root/.ssh; chmod 700 /root/.ssh
echo "root:unitotem" | chpasswd
printf "[Match]\nName=en* eth*\n[Network]\nDHCP=yes\n" >/etc/systemd/network/10-dhcp.network
systemctl enable systemd-networkd systemd-resolved ssh serial-getty@ttyS0
ls /lib/modules; dpkg -l | awk "/^ii +(linux-image|shim|grub-efi)/{print \$2,\$3}"
'
cat "$W/up-key.pub" >"$M/root/.ssh/authorized_keys"
echo "PermitRootLogin yes" >"$M/etc/ssh/sshd_config.d/10-proto.conf"
ls -la "$M/boot/efi/EFI/BOOT" "$M/boot/efi/EFI/ubuntu" 2>&1 || true
for d in EFI/BOOT EFI/ubuntu boot/grub; do mkdir -p "$M/boot/efi/$d"; cat >"$M/boot/efi/$d/grub.cfg" <<S
search --no-floppy --label --set=root ROOT
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
S
done
touch "$W/base.done"
echo "== $(date -u +%T) build-base done"
