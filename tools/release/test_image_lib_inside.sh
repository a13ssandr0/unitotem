#!/bin/bash
# Runs INSIDE the privileged container of test_image_lib.sh (/repo read-only, /work scratch).
set -uo pipefail
W=/work; ok=0; fail=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $name"; else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
mkdir -p /tmpfs /m /mt; mount -t tmpfs -o size=3g tmpfs /tmpfs; export UNITOTEM_TMPFS=/tmpfs
rm -f $W/src.img $W/src.img.xz $W/tgt.img

# --- the image: the amd64 A/B layout, small
truncate -s 1200M $W/src.img
sgdisk -Z $W/src.img >/dev/null
sgdisk -n 1:0:+64M -t 1:ef00 -c 1:EFI $W/src.img >/dev/null
sgdisk -n 2:0:+300M -t 2:8300 -c 2:ROOT_A $W/src.img >/dev/null
sgdisk -n 3:0:+100M -t 3:8300 -c 3:ROOT_B $W/src.img >/dev/null
sgdisk -n 4:0:+400M -t 4:8300 -c 4:DATA $W/src.img >/dev/null
sgdisk -n 5:34:2047 -t 5:ef02 -c 5:BIOS $W/src.img >/dev/null
L=$(losetup --find --show --partscan $W/src.img); sleep 1; partprobe "$L"; sleep 1
mkfs.fat -F32 -n EFI "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"; mkfs.ext4 -q -L ROOT_B "${L}p3"; mkfs.ext4 -q -L DATA "${L}p4"
head -c 1031168 /dev/urandom > /tmp/bios.bin; dd if=/tmp/bios.bin of="${L}p5" bs=1M conv=notrunc status=none
mount "${L}p1" /m; mkdir -p /m/EFI/BOOT /m/unitotem; head -c 1000000 /dev/urandom > /m/EFI/BOOT/BOOTX64.EFI; echo recovery > /m/unitotem/recovery-vmlinuz; umount /m
mount "${L}p2" /m; head -c 30000000 /dev/urandom > /m/system.bin; echo marker > /m/marker; umount /m
EFI_MD5=$(mount -o ro "${L}p1" /m && md5sum /m/EFI/BOOT/BOOTX64.EFI | cut -d' ' -f1; umount /m)
ROOT_MD5=$(mount -o ro "${L}p2" /m && md5sum /m/system.bin | cut -d' ' -f1; umount /m)
EFI_VOLID=$(blkid -s UUID -o value "${L}p1"); ROOT_USED=$(dumpe2fs -h "${L}p2" 2>/dev/null | awk -F': *' '/^Block count:/{t=$2}/^Free blocks:/{f=$2}/^Block size:/{b=$2}END{print (t-f)*b}')
sfdisk -d "$L" > /tmp/src.table; losetup -d "$L"
xz -T0 -k -- $W/src.img

source /repo/deploy/script/image-lib.sh

# --- open the compressed image: expanded in tmpfs only, read-only loop
image_open $W/src.img.xz 2>/dev/null; rc=$?
check "image_open on the .xz succeeds" [ "$rc" = 0 ]
check "the expanded image is in tmpfs" bash -c "case '$IMG_FILE' in /tmpfs/*) true;; *) false;; esac"
check "the loop device is read-only" bash -c "[ \"\$(cat /sys/block/$(basename $IMG_LOOP)/ro)\" = 1 ]"
check "partition nodes are found by number" bash -c "[ -b '$(image_node 2)' ] && [ -b '$(image_node 5)' ] && ! image_node 9"

# --- descriptor
D=/tmpfs/desc; image_describe $D amd64 2>/dev/null
M=$D/parts.manifest
mf() { awk -F= -v k="$1" '$1==k{print $2; exit}' $M; }
blk() { awk -v n="$1" -F= '/^UNITOTEM_PART=/{cur=$2} cur==n && $1==k {print $2; exit}' k="$2" $M; }
check "layout 2, arch amd64, five partitions" bash -c "[ '$(mf UNITOTEM_LAYOUT)' = 2 ] && [ '$(mf UNITOTEM_ARCH)' = amd64 ] && [ '$(mf UNITOTEM_NPARTS)' = 5 ]"
check "DATA is partition 4, the boot partition 1" bash -c "[ '$(mf UNITOTEM_DATA_PART)' = 4 ] && [ '$(mf UNITOTEM_BOOTFS_PART)' = 1 ]"
check "actions: filecopy restore format data raw" bash -c "[ \"$(blk 1 UNITOTEM_PART_ACTION) $(blk 2 UNITOTEM_PART_ACTION) $(blk 3 UNITOTEM_PART_ACTION) $(blk 4 UNITOTEM_PART_ACTION) $(blk 5 UNITOTEM_PART_ACTION)\" = 'filecopy restore format data raw' ]"
check "ROOT_A: cloner extfs, used bytes as dumpe2fs says" bash -c "[ '$(blk 2 UNITOTEM_PART_CLONER)' = extfs ] && [ '$(blk 2 UNITOTEM_PART_USED_BYTES)' = '$ROOT_USED' ]"
check "BIOS partition: label from the GPT type, cloner dd" bash -c "[ '$(blk 5 UNITOTEM_PART_LABEL)' = BIOS ] && [ '$(blk 5 UNITOTEM_PART_CLONER)' = dd ]"
check "the boot partition keeps its FAT serial" [ "$(blk 1 UNITOTEM_PART_VOLID)" = "$EFI_VOLID" ]
check "the table is the image's" bash -c "diff <(grep -E '^/dev' $D/layout.sfdisk | sed -E 's#^/dev/loop[0-9]+p##') <(grep -E '^/dev' /tmp/src.table | sed -E 's#^/dev/loop[0-9]+p##')"
check "UNITOTEM_TABLE of a GPT image is gpt" [ "$(mf UNITOTEM_TABLE)" = gpt ]
check "the MBR boot code is 440 bytes" bash -c "[ \$(stat -c %s $D/bootcode.bin) = 440 ]"
mkdir -p /tb; tar -C /tb -xf $D/p1-EFI.bootfs.tar.xz
check "the boot partition tar holds its files" bash -c "[ \"\$(md5sum /tb/EFI/BOOT/BOOTX64.EFI | cut -d' ' -f1)\" = '$EFI_MD5' ] && [ -f /tb/unitotem/recovery-vmlinuz ]"
check "the descriptor is a few KiB besides the boot tar (no partition streams)" bash -c "[ \$(ls $D | grep -c 'pc.xz') = 0 ]"

# --- streams, restored the way the engine does: unxz | partclone.restore / dd
truncate -s 400M $W/tgt.img; T=$(losetup --find --show $W/tgt.img)
image_stream 2 2>/dev/null | unxz -dc | partclone.restore -o "$T" -s - -F -B >/dev/null 2>&1
mount -o ro "$T" /mt 2>/dev/null
check "ROOT_A stream restores the filesystem: file, label and marker" bash -c "[ \"\$(md5sum /mt/system.bin | cut -d' ' -f1)\" = '$ROOT_MD5' ] && [ \"\$(cat /mt/marker)\" = marker ]"
umount /mt 2>/dev/null; losetup -d "$T"
BIOS_GOT=$(image_stream 5 2>/dev/null | unxz -dc | md5sum); BIOS_EXP=$(md5sum < /tmp/bios.bin)
check "BIOS stream is the raw partition" [ "$BIOS_GOT" = "$BIOS_EXP" ]
image_stream 4 >/dev/null 2>&1; NOSTREAM=$?
check "a partition without a stream is refused" [ "$NOSTREAM" != 0 ]

# --- close, refusals
image_close
check "image_close removes the expansion from tmpfs" bash -c "[ -z \"\$(ls -A /tmpfs | grep -v '^desc\$')\" ]"
check "image_close detaches the loop device" bash -c "! losetup -a | grep -q src.img"
mount -o remount,size=20m /tmpfs
check "an image bigger than the free tmpfs is refused" bash -c "source /repo/deploy/script/image-lib.sh; image_open $W/src.img.xz 2>&1 | grep -q 'does not fit in'"
mount -o remount,size=3g /tmpfs
check "a directory that is not tmpfs is refused" bash -c "source /repo/deploy/script/image-lib.sh; IMG_TMPFS=/work image_open $W/src.img.xz 2>&1 | grep -q 'is not tmpfs'"
check "a plain image is used where it is" bash -c "source /repo/deploy/script/image-lib.sh; image_open $W/src.img && [ \"\$IMG_FILE\" = $W/src.img ] && [ -b \"\$(image_node 1)\" ]; image_close"
# --- MBR conversion (Pi 3 targets): four primaries from the GPT layout, applied to a blank disk
source /repo/deploy/script/image-lib.sh
rm -rf /tmpfs/dos5; mkdir -p /tmpfs/dos5; cp $D/layout.sfdisk $D/bootcode.bin /tmpfs/dos5/
image_table_dos /tmpfs/dos5 2>/dev/null; DOS5=$?
check "a table of five partitions is refused as MBR" [ "$DOS5" != 0 ]
rm -rf /tmpfs/dos; mkdir -p /tmpfs/dos; grep -v 'name="BIOS"' $D/layout.sfdisk > /tmpfs/dos/layout.sfdisk; cp $D/bootcode.bin /tmpfs/dos/
printf 'UNITOTEM_TABLE=gpt\n' > /tmpfs/dos/parts.manifest
image_table_dos /tmpfs/dos; DOSRC=$?
check "four partitions convert" [ "$DOSRC" = 0 ]
check "the converted table is dos, boot code dropped" bash -c "grep -qx 'label: dos' /tmpfs/dos/layout.sfdisk && [ ! -e /tmpfs/dos/bootcode.bin ]"
check "the manifest says dos after the conversion" [ "$(awk -F= '/^UNITOTEM_TABLE=/{print $2}' /tmpfs/dos/parts.manifest)" = dos ]
truncate -s 2G $W/tgt.img; sfdisk -q $W/tgt.img < /tmpfs/dos/layout.sfdisk 2>/dev/null
sfdisk -d $W/tgt.img | grep ' : start=' | sed -E 's#^[^ ]+ : start= *([0-9]+), size= *([0-9]+),? *type=([0-9a-f]+).*#\1 \2 \3#' > /tmp/dos.got
grep '^/dev' $D/layout.sfdisk | grep -v BIOS | sed -E 's#^[^ ]+ : start= *([0-9]+), size= *([0-9]+),.*name="([^"]*)".*#\1 \2 \3#; s# (FIRMWARE|EFI)$# c#; s# (ROOT_A|ROOT_B|DATA)$# 83#' > /tmp/dos.exp
check "sfdisk applies it: label dos, same starts and sizes, FAT type c, Linux 83" bash -c "sfdisk -d $W/tgt.img | grep -qx 'label: dos' && diff /tmp/dos.got /tmp/dos.exp"
check "the disk id is the first 32 bits of the GPT disk GUID" bash -c "[ \"\$(sfdisk -d $W/tgt.img | awk -F': *' '/^label-id:/{print \$2}')\" = 0x\$(awk -F': *' '/^label-id:/{print \$2}' $D/layout.sfdisk | tr -d '-' | cut -c1-8 | tr A-F a-f) ]"

# --- the fixture dump for the loopback harness
bash /repo/tools/release/image-streams.sh $W/src.img /tmpfs/dump amd64 >/dev/null 2>&1
check "image-streams.sh writes the descriptor and the ROOT_A and BIOS streams" bash -c "ls /tmpfs/dump/p2-ROOT_A.pc.xz /tmpfs/dump/p5-BIOS.pc.xz /tmpfs/dump/parts.manifest && grep -qx 'UNITOTEM_PART_STREAM_FILE=p2-ROOT_A.pc.xz' /tmpfs/dump/parts.manifest"
echo "$ok passed, $fail failed"
[ "$fail" = 0 ]
