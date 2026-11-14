#!/bin/bash
# Runs INSIDE the privileged container of test_preboot_image.sh (/repo read-only, /work scratch).
set -uo pipefail
W=/work; ok=0; fail=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $name"; else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
mkdir -p /tmpfs /m; mount -t tmpfs -o size=1g tmpfs /tmpfs; export UNITOTEM_TMPFS=/tmpfs
rm -f $W/fake.img $W/out.img $W/vmlinuz $W/initrd $W/card.img $W/wp.img $W/wp.img.xz

# an arm64 image: GPT, FIRMWARE FAT with the firmware files, ROOT_A
truncate -s 300M $W/fake.img
sgdisk -Z $W/fake.img >/dev/null; sgdisk -n 1:0:+100M -t 1:0700 -c 1:FIRMWARE $W/fake.img >/dev/null; sgdisk -n 2:0:+100M -t 2:8300 -c 2:ROOT_A $W/fake.img >/dev/null
L=$(losetup --find --show --partscan $W/fake.img); sleep 1; partprobe "$L"; sleep 1
mkfs.fat -F32 -n FIRMWARE "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"
mount "${L}p1" /m
for f in bootcode.bin start.elf fixup.dat start4.elf fixup4.dat start_x.elf bcm2710-rpi-3-b.dtb bcm2711-rpi-4-b.dtb LICENCE.broadcom; do echo "fw-$f" > /m/$f; done
mkdir -p /m/slota; echo kernel > /m/slota/kernel8.img; umount /m; losetup -d "$L"

# recovery kernel and initrd: the initrd is an uncompressed cpio with an OLD engine
mkdir -p $W/rec/usr/lib/unitotem; echo "OLD ENGINE" > $W/rec/usr/lib/unitotem/ota-engine.sh; echo init > $W/rec/init
head -c 100000 /dev/urandom > $W/vmlinuz
( cd $W/rec && printf 'init\nusr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet ) > $W/initrd
INITRD_SIZE=$(stat -c %s $W/initrd)
mkdir -p $W/recdir; cp $W/vmlinuz $W/recdir/recovery-vmlinuz-arm64; cp $W/initrd $W/recdir/recovery-initrd-arm64.img
echo "NEW ENGINE" > $W/engine.sh

bash /repo/deploy/script/make-preboot-image.sh --image $W/fake.img --recovery-dir $W/recdir --engine $W/engine.sh --out $W/out.img --no-xz --size-mib 64 > /tmp/mk.log 2>&1
check "make-preboot-image succeeds" test -s $W/out.img
cat /tmp/mk.log | tail -3
check "MBR with one bootable FAT partition (type c) from 1 MiB" bash -c "sfdisk -d $W/out.img | grep -q 'start= *2048.*type=c.*bootable'"
O=$(losetup --find --show --partscan $W/out.img); sleep 1; partprobe "$O"; sleep 1
check "the partition is FAT labelled FIRMWARE" bash -c "[ \"\$(blkid -s LABEL -o value ${O}p1)\" = FIRMWARE ] && [ \"\$(blkid -s TYPE -o value ${O}p1)\" = vfat ]"
mount -o ro "${O}p1" /m
check "firmware of both boards: Pi 3 and Pi 4 files and device trees" bash -c "cd /m && ls start.elf fixup.dat start4.elf fixup4.dat bcm2710-rpi-3-b.dtb bcm2711-rpi-4-b.dtb bootcode.bin"
check "the _x/_db variants and the slot directories are left out" bash -c "[ ! -e /m/start_x.elf ] && [ ! -d /m/slota ]"
check "the recovery kernel is the given one" cmp /m/recovery8.img $W/vmlinuz
check "config.txt boots the recovery kernel and initrd (64-bit)" bash -c "grep -qx 'kernel=recovery8.img' /m/config.txt && grep -q 'initramfs recovery-initrd.img followkernel' /m/config.txt && grep -qx arm_64bit=1 /m/config.txt"
check "cmdline.txt: recover mode (waits for the host), no key, no password" bash -c "grep -q 'unitotem.ota=recover' /m/cmdline.txt && ! grep -q -i 'authkey\|password\|ssh-' /m/cmdline.txt"
check "no authorized keys file, no request file on the card" bash -c "! ls /m | grep -q -i 'authorized\|ota.request'"
check "the initrd starts with the original archive, byte for byte" bash -c "head -c $INITRD_SIZE /m/recovery-initrd.img | cmp - $W/initrd"
check "the engine of the appended archive is the repository's" bash -c "tail -c +$((INITRD_SIZE + 1)) /m/recovery-initrd.img | cpio -i --to-stdout usr/lib/unitotem/ota-engine.sh 2>/dev/null | grep -qx 'NEW ENGINE'"
umount /m; losetup -d "$O"
# write-preboot.sh: build and write to a (loop) card in one go
truncate -s 256M $W/card.img; C=$(losetup --find --show --partscan $W/card.img)
bash /repo/deploy/script/write-preboot.sh --yes --image $W/fake.img --out $W/wp.img $C > /tmp/wp.log 2>&1
check "write-preboot.sh builds the image and writes the card" bash -c "sleep 1; partprobe $C; sleep 1; [ \"\$(blkid -s LABEL -o value ${C}p1)\" = FIRMWARE ]"
mount -o ro "${C}p1" /m; check "the card holds the recovery kernel, the config and the cmdline" bash -c "cmp /m/recovery8.img /repo/build/arm64/recovery/recovery-vmlinuz-arm64 && grep -q recover /m/cmdline.txt && [ -f /m/start.elf ]"; umount /m
check "the card's table is the preboot one: MBR, FAT type c" bash -c "sfdisk -d $C | grep -qx 'label: dos' && sfdisk -d $C | grep -q 'type=c'"
losetup -d "$C"
echo "$ok passed, $fail failed"
[ "$fail" = 0 ]
