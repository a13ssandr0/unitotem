#!/bin/bash
# Runs INSIDE the privileged container of test_preboot_image.sh (/repo read-only, /work scratch).
set -uo pipefail
W=/work/t; ok=0; fail=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $name"; else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
mkdir -p /tmpfs /m /m2; mount -t tmpfs -o size=1g tmpfs /tmpfs; export UNITOTEM_TMPFS=/tmpfs
rm -rf $W; mkdir -p $W
LEVEL=20261115173059
ENGINE_OLD=$W/old-engine.sh; ENGINE=$W/engine.sh
echo "NEW ENGINE" > $ENGINE

# recovery kernel and initrd: the initrd is an uncompressed cpio with an OLD engine
mkdir -p $W/rec/usr/lib/unitotem; echo "OLD ENGINE" > $W/rec/usr/lib/unitotem/ota-engine.sh; echo init > $W/rec/init
head -c 100000 /dev/urandom > $W/vmlinuz
( cd $W/rec && printf 'init\nusr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet ) > $W/initrd
INITRD_SIZE=$(stat -c %s $W/initrd)
FWFILES="bootcode.bin start.elf fixup.dat start4.elf fixup4.dat start_x.elf start4x.elf fixup_x.dat bcm2710-rpi-3-b.dtb bcm2711-rpi-4-b.dtb LICENCE.broadcom"
# the firmware directory of a stage-2 rootfs (boot/firmware): firmware, the full system's files and an overlay
mkdir -p $W/fwfix; for f in $FWFILES; do echo "fw-$f" > $W/fwfix/$f; done
echo "full system config" > $W/fwfix/config.txt; echo "full system cmdline" > $W/fwfix/cmdline.txt; echo kernel > $W/fwfix/kernel8.img; echo ramfs > $W/fwfix/initramfs8
mkdir -p $W/fwfix/overlays; echo ov > $W/fwfix/overlays/vc4-kms-v3d.dtbo

# ---------- boot tree (unitotem/make-boot-tree.sh) ----------
TREE=$W/tree
check "make-boot-tree needs the recovery files and the engine" bash -c "! bash /repo/unitotem/make-boot-tree.sh --firmware $W/fwfix --recovery-vmlinuz $W/none --recovery-initrd $W/initrd --level $LEVEL --engine $ENGINE --out $W/none-tree 2>/dev/null"
check "make-boot-tree refuses a level that is not 14 digits" bash -c "! bash /repo/unitotem/make-boot-tree.sh --firmware $W/fwfix --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --level 2026 --engine $ENGINE --out $W/bad-tree 2>/dev/null"
check "make-boot-tree refuses a firmware directory without start4.elf" bash -c "mkdir -p $W/fwnoelf && cp $W/fwfix/start.elf $W/fwfix/fixup.dat $W/fwfix/bcm2710-rpi-3-b.dtb $W/fwfix/bcm2711-rpi-4-b.dtb $W/fwnoelf/ && ! bash /repo/unitotem/make-boot-tree.sh --firmware $W/fwnoelf --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --level $LEVEL --engine $ENGINE --out $W/bad-tree2 2>/dev/null"
check "make-boot-tree needs exactly one of --stage2 and --firmware" bash -c "! bash /repo/unitotem/make-boot-tree.sh --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --level $LEVEL --engine $ENGINE --out $W/bad-tree3 2>/dev/null"
bash /repo/unitotem/make-boot-tree.sh --firmware $W/fwfix --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --level $LEVEL --engine $ENGINE --out $TREE > $W/tree.log 2>&1
check "make-boot-tree from a firmware directory succeeds" test -s $TREE/boot-tree.sha256
bash /repo/unitotem/make-boot-tree.sh --firmware $W/fwfix --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --level $LEVEL --engine $ENGINE --out $W/tree-again > $W/tree-again.log 2>&1
check "boot tree is reproducible: a second build of the same inputs is byte-identical" diff -r $TREE $W/tree-again
check "boot tree lists exactly the preboot set (no full-system files, no overlays, no _x variants)" bash -c "cd $TREE && [ \"\$(find . -maxdepth 1 -type f -printf '%f\\n' | LC_ALL=C sort | tr '\n' ' ')\" = 'LICENCE.broadcom bcm2710-rpi-3-b.dtb bcm2711-rpi-4-b.dtb boot-tree.sha256 bootcode.bin cmdline.txt config.txt fixup.dat fixup4.dat recovery-initrd.img recovery8.img start.elf start4.elf ' ]"
check "boot tree manifest verifies and carries the level line" bash -c "cd $TREE && sha256sum -c --quiet boot-tree.sha256 && head -1 boot-tree.sha256 | grep -qx '# unitotem-recovery-level: $LEVEL'"
check "boot tree recovery kernel is the given one" cmp $TREE/recovery8.img $W/vmlinuz
check "boot tree initrd starts with the original archive, byte for byte" bash -c "head -c $INITRD_SIZE $TREE/recovery-initrd.img | cmp - $W/initrd"
check "boot tree initrd carries the repository's engine (appended entry)" bash -c "tail -c +$((INITRD_SIZE + 1)) $TREE/recovery-initrd.img | cpio -i --to-stdout usr/lib/unitotem/ota-engine.sh 2>/dev/null | grep -qx 'NEW ENGINE'"
check "boot tree config.txt boots the recovery kernel and initrd (64-bit, 640x480)" bash -c "grep -qx 'kernel=recovery8.img' $TREE/config.txt && grep -q 'initramfs recovery-initrd.img followkernel' $TREE/config.txt && grep -qx arm_64bit=1 $TREE/config.txt && grep -qx hdmi_mode=4 $TREE/config.txt"
check "boot tree cmdline.txt: recover mode, no key, no password" bash -c "grep -qx 'unitotem.ota=recover console=tty1 console=ttyS0,115200' $TREE/cmdline.txt && ! grep -q -i 'authkey\|password\|ssh-' $TREE/cmdline.txt"
check "boot tree: a changed file fails the manifest" bash -c "cp -r $TREE $W/tree-bad && echo x >> $W/tree-bad/start.elf && cd $W/tree-bad && ! sha256sum -c --quiet boot-tree.sha256"

# ---------- engine already in the initrd (stage 1b layout: a plain archive, then a zstd segment) ----------
# An initrd that carries the current engine is copied unchanged; a stale or absent copy gets the engine appended.
echo "OLD ENGINE" > $ENGINE_OLD
mkdir -p $W/zs-same/usr/lib/unitotem $W/zs-old/usr/lib/unitotem
cp $ENGINE $W/zs-same/usr/lib/unitotem/ota-engine.sh; cp $ENGINE_OLD $W/zs-old/usr/lib/unitotem/ota-engine.sh
( cd $W/zs-same && printf 'usr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet ) | zstd -q -c > $W/zs-same.zst
( cd $W/zs-old && printf 'usr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet ) | zstd -q -c > $W/zs-old.zst
( cd $W/rec && printf 'init\n' | cpio -o -H newc --quiet ) > $W/plain-init.cpio
cat $W/plain-init.cpio $W/zs-same.zst > $W/initrd-same
cat $W/plain-init.cpio $W/zs-old.zst > $W/initrd-old
cat $W/plain-init.cpio > $W/initrd-absent
# the engine entry of an initrd: the last one, as extraction gives it
engine_of() { python3 -I /repo/unitotem/initrd-scan.py get "$1" usr/lib/unitotem/ota-engine.sh | cmp -s - "$2"; }
make_tree() { bash /repo/unitotem/make-boot-tree.sh --firmware $W/fwfix --recovery-vmlinuz $W/vmlinuz --recovery-initrd "$1" --level $LEVEL --engine $ENGINE --out "$2" > "$2.log" 2>&1; }
identical_kept() { make_tree $W/initrd-same $W/tree-same && cmp $W/tree-same/recovery-initrd.img $W/initrd-same; }
stale_appended() { make_tree $W/initrd-old $W/tree-old && cmp -n $(stat -c %s $W/initrd-old) $W/tree-old/recovery-initrd.img $W/initrd-old && engine_of $W/tree-old/recovery-initrd.img $ENGINE; }
absent_appended() { make_tree $W/initrd-absent $W/tree-absent && cmp -n $(stat -c %s $W/initrd-absent) $W/tree-absent/recovery-initrd.img $W/initrd-absent && engine_of $W/tree-absent/recovery-initrd.img $ENGINE; }
appended_kept() { make_tree $TREE/recovery-initrd.img $W/tree-again-app && cmp $W/tree-again-app/recovery-initrd.img $TREE/recovery-initrd.img; }
check "initrd with the current engine in a zstd segment is copied unchanged, byte for byte" identical_kept
check "initrd with a stale engine in a zstd segment gets the current engine appended (last entry wins)" stale_appended
check "initrd without an engine gets the current engine appended" absent_appended
check "initrd that already ends with the current engine is copied unchanged (second run)" appended_kept
check "make-boot-tree reports that the engine is already in the initrd" bash -c "grep -q 'already in it, not appended' $W/tree-same.log"
check "the stage-1b layout passes the engine check (initrd-scan.py get: current engine)" engine_of $W/tree-same/recovery-initrd.img $ENGINE

# stage-2 input: a gzip tarball of a rootfs; only its boot/firmware top-level files go into the tree
mkdir -p $W/s2/boot; cp -r $W/fwfix $W/s2/boot/firmware; echo etc > $W/s2/etc-marker
( cd $W/s2 && tar -czf $W/stage2.tar.gz . )
echo "UNITOTEM_RECOVERY_BUILD_DATE=2026-11-15T17:30:59Z" > $W/recovery.manifest
bash /repo/unitotem/make-boot-tree.sh --stage2 $W/stage2.tar.gz --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --recovery-manifest $W/recovery.manifest --engine $ENGINE --out $W/tree-s2 > $W/tree-s2.log 2>&1
check "make-boot-tree --stage2 succeeds, level from the recovery manifest" bash -c "test -s $W/tree-s2/boot-tree.sha256 && head -1 $W/tree-s2/boot-tree.sha256 | grep -qx '# unitotem-recovery-level: $LEVEL'"
check "make-boot-tree refuses --recovery-manifest with --level" bash -c "! bash /repo/unitotem/make-boot-tree.sh --stage2 $W/stage2.tar.gz --recovery-vmlinuz $W/vmlinuz --recovery-initrd $W/initrd --recovery-manifest $W/recovery.manifest --level $LEVEL --engine $ENGINE --out $W/none-tree4 2>/dev/null"
check "stage2 input: the same set as the firmware input (overlays and full-system files left out)" bash -c "diff -r $TREE $W/tree-s2 -x boot-tree.sha256 >/dev/null 2>&1"

# ---------- image of the arm64 build (FIRMWARE partition, ROOT_A) ----------
truncate -s 300M $W/fake.img
sgdisk -Z $W/fake.img >/dev/null; sgdisk -n 1:0:+100M -t 1:0700 -c 1:FIRMWARE $W/fake.img >/dev/null; sgdisk -n 2:0:+100M -t 2:8300 -c 2:ROOT_A $W/fake.img >/dev/null
L=$(losetup --find --show --partscan $W/fake.img); sleep 1; partprobe "$L"; sleep 1
mkfs.fat -F32 -n FIRMWARE "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"
mount "${L}p1" /m
for f in $FWFILES; do echo "fw-$f" > /m/$f; done
echo "full system config" > /m/config.txt; echo "full system cmdline" > /m/cmdline.txt; echo kernel > /m/kernel8.img
cp $W/vmlinuz /m/recovery8.img; cp $W/initrd /m/recovery-initrd.img; echo "# unitotem-recovery-level: $LEVEL" > /m/recovery.sha256
mkdir -p /m/slota; echo kernel > /m/slota/kernel8.img; umount /m; losetup -d "$L"

# ---------- make-preboot-image.sh ----------
bash /repo/deploy/script/make-preboot-image.sh --image $W/fake.img --engine $ENGINE --out $W/out.img --no-xz --size-mib 64 > $W/mk.log 2>&1
check "make-preboot-image refuses --engine without --image (whatever the default tree is)" bash -c "! bash /repo/deploy/script/make-preboot-image.sh --engine $ENGINE --out $W/none.img --no-xz --size-mib 64 2>/dev/null"
check "make-preboot-image refuses --tree and --image together" bash -c "! bash /repo/deploy/script/make-preboot-image.sh --tree $TREE --image $W/fake.img --out $W/none.img 2>/dev/null"
check "make-preboot-image refuses --engine with --tree" bash -c "! bash /repo/deploy/script/make-preboot-image.sh --tree $TREE --engine $ENGINE --out $W/none.img 2>/dev/null"
check "make-preboot-image --image succeeds" test -s $W/out.img
tail -3 $W/mk.log
bash /repo/deploy/script/make-preboot-image.sh --tree $TREE --out $W/tree.img --no-xz --size-mib 64 > $W/mkt.log 2>&1
check "make-preboot-image --tree succeeds" test -s $W/tree.img
check "make-preboot-image --tree refuses a tree whose file does not match its manifest" bash -c "! bash /repo/deploy/script/make-preboot-image.sh --tree $W/tree-bad --out $W/none.img --no-xz --size-mib 64 2>/dev/null"
check "MBR with one bootable FAT partition (type c) from 1 MiB" bash -c "sfdisk -d $W/out.img | grep -q 'start= *2048.*type=c.*bootable'"
O=$(losetup --find --show --partscan $W/out.img); sleep 1; partprobe "$O"; sleep 1
check "the partition is FAT labelled FIRMWARE" bash -c "[ \"\$(blkid -s LABEL -o value ${O}p1)\" = FIRMWARE ] && [ \"\$(blkid -s TYPE -o value ${O}p1)\" = vfat ]"
mount -o ro "${O}p1" /m
check "firmware of both boards: Pi 3 and Pi 4 files and device trees" bash -c "cd /m && ls start.elf fixup.dat start4.elf fixup4.dat bcm2710-rpi-3-b.dtb bcm2711-rpi-4-b.dtb bootcode.bin"
check "the _x/_db variants, the slot directories and the full-system files are left out" bash -c "[ ! -e /m/start_x.elf ] && [ ! -d /m/slota ] && [ ! -e /m/kernel8.img ] && [ ! -d /m/overlays ] && ! grep -q 'full system' /m/config.txt"
check "the recovery kernel is the given one" cmp /m/recovery8.img $W/vmlinuz
check "config.txt boots the recovery kernel and initrd (64-bit)" bash -c "grep -qx 'kernel=recovery8.img' /m/config.txt && grep -q 'initramfs recovery-initrd.img followkernel' /m/config.txt && grep -qx arm_64bit=1 /m/config.txt"
check "cmdline.txt: recover mode (waits for the host), no key, no password" bash -c "grep -q 'unitotem.ota=recover' /m/cmdline.txt && ! grep -q -i 'authkey\|password\|ssh-' /m/cmdline.txt"
check "no authorized keys file, no request file on the card" bash -c "! ls /m | grep -q -i 'authorized\|ota.request'"
check "the initrd starts with the original archive, byte for byte" bash -c "head -c $INITRD_SIZE /m/recovery-initrd.img | cmp - $W/initrd"
check "the engine of the appended archive is the repository's" bash -c "tail -c +$((INITRD_SIZE + 1)) /m/recovery-initrd.img | cpio -i --to-stdout usr/lib/unitotem/ota-engine.sh 2>/dev/null | grep -qx 'NEW ENGINE'"
( cd /m && find . -type f | LC_ALL=C sort | xargs md5sum ) > $W/card-image.md5
umount /m; losetup -d "$O"

O=$(losetup --find --show --partscan $W/tree.img); sleep 1; partprobe "$O"; sleep 1
mount -o ro "${O}p1" /m
check "--tree card holds the boot tree byte for byte (manifest verifies on the card)" bash -c "cd /m && sha256sum -c --quiet boot-tree.sha256 && [ \"\$(ls | wc -l)\" = \$(ls $TREE | wc -l) ]"
check "--tree card and --image card have identical files (firmware, recovery set, config, cmdline)" bash -c "cd /m && find . -type f | LC_ALL=C sort | xargs md5sum | diff - $W/card-image.md5"
( cd $TREE && find . -type f | LC_ALL=C sort | xargs md5sum ) > $W/tree.md5
umount /m; losetup -d "$O"

# write-preboot.sh: build and write to a (loop) card in one go
truncate -s 256M $W/card.img; C=$(losetup --find --show --partscan $W/card.img)
bash /repo/deploy/script/write-preboot.sh --yes --image $W/fake.img --out $W/wp.img $C > $W/wp.log 2>&1
check "write-preboot.sh --image builds the image and writes the card" bash -c "sleep 1; partprobe $C; sleep 1; [ \"\$(blkid -s LABEL -o value ${C}p1)\" = FIRMWARE ]"
mount -o ro "${C}p1" /m; check "the card holds the recovery kernel, the config and the cmdline" bash -c "cmp /m/recovery8.img $W/vmlinuz && grep -q recover /m/cmdline.txt && [ -f /m/start.elf ]"; umount /m
bash /repo/deploy/script/write-preboot.sh --yes --tree $TREE --out $W/wp2.img $C > $W/wp2.log 2>&1
partprobe "$C"; sleep 1; mount -o ro "${C}p1" /m; check "write-preboot.sh --tree writes the card from the boot tree" bash -c "cd /m && find . -type f | LC_ALL=C sort | xargs md5sum | diff - $W/tree.md5"; umount /m
check "the card's table is the preboot one: MBR, FAT type c" bash -c "sfdisk -d $C | grep -qx 'label: dos' && sfdisk -d $C | grep -q 'type=c'"
losetup -d "$C"
echo "$ok passed, $fail failed"
[ "$fail" = 0 ]
