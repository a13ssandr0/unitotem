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
check "actions: filecopy restore blank data raw" bash -c "[ \"$(blk 1 UNITOTEM_PART_ACTION) $(blk 2 UNITOTEM_PART_ACTION) $(blk 3 UNITOTEM_PART_ACTION) $(blk 4 UNITOTEM_PART_ACTION) $(blk 5 UNITOTEM_PART_ACTION)\" = 'filecopy restore blank data raw' ]"
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
# --- minimal images: boot FAT with unitotem-layout, ROOT_A shrunk to its used size + 16 MiB, no ROOT_B and no DATA
# make_min IMAGE TYPE-CODE BOOT-LABEL SLOT-SECTORS BIOS(yes|no): sets MIN_A_START, MIN_USED (ROOT_A used bytes after the shrink), MIN_MD5
make_min() {
    local img=$1 code=$2 blab=$3 slot=$4 L fsbytes tsec A_END
    rm -f -- "$img"; truncate -s 600M "$img"; sgdisk -Z "$img" >/dev/null
    sgdisk -n 1:0:+64M -t 1:$code -c 1:$blab "$img" >/dev/null
    sgdisk -n 2:0:+300M -t 2:8300 -c 2:ROOT_A "$img" >/dev/null
    if [ "$5" = yes ]; then sgdisk -n 5:34:2047 -t 5:ef02 -c 5:BIOS "$img" >/dev/null; fi
    L=$(losetup --find --show --partscan "$img"); sleep 1; partprobe "$L"; sleep 1
    mkfs.fat -F32 -n "$blab" "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"
    mount "${L}p1" /m; mkdir -p /m/EFI/BOOT; head -c 1000000 /dev/urandom > /m/EFI/BOOT/BOOTX64.EFI
    echo "UNITOTEM_SLOT_SECTORS=$slot" > /m/unitotem-layout; umount /m
    mount "${L}p2" /m; head -c 30000000 /dev/urandom > /m/system.bin; echo marker > /m/marker
    MIN_MD5=$(md5sum < /m/system.bin | cut -d' ' -f1); umount /m
    e2fsck -fy "${L}p2" >/dev/null 2>&1; resize2fs -M "${L}p2" >/dev/null 2>&1
    fsbytes=$(dumpe2fs -h "${L}p2" 2>/dev/null | awk -F': *' '/^Block count:/{b=$2}/^Block size:/{s=$2}END{print b*s}')
    MIN_USED=$(dumpe2fs -h "${L}p2" 2>/dev/null | awk -F': *' '/^Block count:/{t=$2}/^Free blocks:/{f=$2}/^Block size:/{b=$2}END{print (t-f)*b}')
    tsec=$(( (fsbytes + 16 * 1048576 + 1048575) / 1048576 * 1048576 / 512 ))
    losetup -d "$L"
    MIN_A_START=$(sgdisk -i 2 "$img" | awk '/First sector/{print $3}')
    A_END=$((MIN_A_START + tsec - 1))
    sgdisk -d 2 "$img" >/dev/null; sgdisk -n 2:$MIN_A_START:$A_END -t 2:8300 -c 2:ROOT_A "$img" >/dev/null
    truncate -s $(( (A_END + 1 + 2048) * 512 )) "$img"; sgdisk -e "$img" >/dev/null 2>&1
}
# mkbad IMAGE CONTENT: copy of the minimal image whose boot FAT has CONTENT as unitotem-layout ("none": no file)
mkbad() {
    cp -- "$W/min.img" "$1"; local L; L=$(losetup --find --show --partscan "$1"); sleep 1; partprobe "$L"; sleep 1
    mount "${L}p1" /m
    if [ "$2" = none ]; then rm -f /m/unitotem-layout; else echo "$2" > /m/unitotem-layout; fi
    umount /m; losetup -d "$L"
}
make_min $W/min.img ef00 EFI 1048576 yes
MA=$MIN_A_START; MU=$MIN_USED
image_open $W/min.img 2>/dev/null; rc=$?
check "minimal amd64: image_open succeeds" [ "$rc" = 0 ]
MD=/tmpfs/mdesc; rm -rf $MD; image_describe $MD amd64 2>/dev/null; MDRC=$?
check "minimal amd64: image_describe succeeds" [ "$MDRC" = 0 ]
MM=$MD/parts.manifest
mmf() { awk -F= -v k="$1" '$1==k{print $2; exit}' $MM; }
mblk() { awk -v n="$1" -F= '/^UNITOTEM_PART=/{cur=$2} cur==n && $1==k {print $2; exit}' k="$2" $MM; }
SL=1048576; MB=$(( (MA + SL + 2047) / 2048 * 2048 )); MDS=$(( (MB + SL + 2047) / 2048 * 2048 ))
LAY=$(sed -nE 's#^/dev/[^ ]*[^0-9]([0-9]+) : start= *([0-9]+), size= *([0-9]+),.*name="([^"]*)".*#\1 \2 \3 \4#p' $MD/layout.sfdisk | sort -n | tr '\n' ';')
check "minimal amd64: layout 1 EFI, 2 ROOT_A (slot), 3 ROOT_B (slot after A), 4 DATA (after B), 5 BIOS" \
    [ "$LAY" = "1 2048 131072 EFI;2 $MA $SL ROOT_A;3 $MB $SL ROOT_B;4 $MDS 524288 DATA;5 34 2014 BIOS;" ]
check "minimal amd64: ROOT_B and DATA carry the Linux data GUID" bash -c "grep 'name=\"ROOT_B\"' $MD/layout.sfdisk | grep -q 0FC63DAF-8483-4772-8E79-3D69D8477DE4 && grep 'name=\"DATA\"' $MD/layout.sfdisk | grep -q 0FC63DAF-8483-4772-8E79-3D69D8477DE4"
check "minimal amd64: manifest synth, layout 2, five partitions, DATA 4, boot 1, gpt" \
    [ "$(mmf UNITOTEM_SYNTH)" = 1 ] && [ "$(mmf UNITOTEM_LAYOUT)" = 2 ] && [ "$(mmf UNITOTEM_NPARTS)" = 5 ] && [ "$(mmf UNITOTEM_DATA_PART)" = 4 ] && [ "$(mmf UNITOTEM_BOOTFS_PART)" = 1 ] && [ "$(mmf UNITOTEM_TABLE)" = gpt ]
check "minimal amd64: min disk from the synthesized DATA start" [ "$(mmf UNITOTEM_MIN_DISK_BYTES)" = $(( (MDS + 2048 + 33) * 512 )) ]
check "minimal amd64: actions filecopy restore blank data raw" \
    [ "$(mblk 1 UNITOTEM_PART_ACTION) $(mblk 2 UNITOTEM_PART_ACTION) $(mblk 3 UNITOTEM_PART_ACTION) $(mblk 4 UNITOTEM_PART_ACTION) $(mblk 5 UNITOTEM_PART_ACTION)" = 'filecopy restore blank data raw' ]
check "minimal amd64: ROOT_A restore size is the slot, used bytes are the shrunk fs's" \
    [ "$(mblk 2 UNITOTEM_PART_SECTORS) $(mblk 2 UNITOTEM_PART_USED_BYTES) $(mblk 2 UNITOTEM_PART_START)" = "$SL $MU $MA" ]
check "minimal amd64: ROOT_B and DATA blocks: labels, sizes, start, no cloner" \
    [ "$(mblk 3 UNITOTEM_PART_LABEL) $(mblk 3 UNITOTEM_PART_SECTORS) $(mblk 3 UNITOTEM_PART_CLONER) $(mblk 4 UNITOTEM_PART_LABEL) $(mblk 4 UNITOTEM_PART_SECTORS) $(mblk 4 UNITOTEM_PART_START)" = "ROOT_B $SL none DATA 524288 $MDS" ]
check "minimal amd64: the boot tar holds unitotem-layout" bash -c "tar -tJf $MD/p1-EFI.bootfs.tar.xz | grep -q 'unitotem-layout$'"
rm -rf /tmpfs/mdos; mkdir -p /tmpfs/mdos; cp $MD/layout.sfdisk $MD/bootcode.bin /tmpfs/mdos/
image_table_dos /tmpfs/mdos 2>/dev/null; MDOS=$?
check "minimal amd64: the table is refused as MBR (five partitions)" [ "$MDOS" != 0 ]
image_close
check "minimal amd64: the GPT of the shrunk image is valid (backup moved to the new end)" bash -c "sgdisk -v $W/min.img | grep -q 'No problems found'"
check "minimal amd64: image_close detaches the loop device" bash -c "! losetup -a | grep -q min.img"

mkbad $W/bad1.img none
image_open $W/bad1.img 2>/dev/null; rm -rf /tmpfs/bad1d; image_describe /tmpfs/bad1d amd64 >/dev/null 2>$W/bad1.err; B1=$?
image_close
check "minimal image without unitotem-layout is refused" bash -c "[ $B1 != 0 ] && grep -q 'no valid unitotem-layout' $W/bad1.err"
mkbad $W/bad2.img "UNITOTEM_SLOT_SECTORS=12x"
image_open $W/bad2.img 2>/dev/null; rm -rf /tmpfs/bad2d; image_describe /tmpfs/bad2d amd64 >/dev/null 2>&1; B2=$?
image_close
check "minimal image with a non-numeric slot is refused" [ "$B2" != 0 ]
mkbad $W/bad3.img "UNITOTEM_SLOT_SECTORS=1000"
image_open $W/bad3.img 2>/dev/null; rm -rf /tmpfs/bad3d; image_describe /tmpfs/bad3d amd64 >/dev/null 2>$W/bad3.err; B3=$?
image_close
check "minimal image with a slot below 512 MiB is refused" bash -c "[ $B3 != 0 ] && grep -q 'out of bounds' $W/bad3.err"

# minimal arm64 (FIRMWARE, ROOT_A): descriptor, MBR conversion applied to a disk, and the ROOT_A stream restored the way the engine does
make_min $W/minarm.img 0700 FIRMWARE 1048576 no
AS=$MIN_A_START; AU=$MIN_USED; AMD5=$MIN_MD5
AB=$(( (AS + SL + 2047) / 2048 * 2048 )); AD_S=$(( (AB + SL + 2047) / 2048 * 2048 ))
image_open $W/minarm.img 2>/dev/null; rm -rf /tmpfs/adesc; image_describe /tmpfs/adesc arm64 2>/dev/null; ADR=$?
image_stream 2 > $W/minarm.pc.xz 2>/dev/null; SRC=$?
image_close
check "minimal arm64: descriptor and ROOT_A stream written" bash -c "[ $ADR = 0 ] && [ $SRC = 0 ] && [ \"\$(awk -F= '/^UNITOTEM_NPARTS=/{print \$2}' /tmpfs/adesc/parts.manifest)\" = 4 ]"
rm -rf /tmpfs/ados; mkdir -p /tmpfs/ados; cp /tmpfs/adesc/layout.sfdisk /tmpfs/adesc/bootcode.bin /tmpfs/adesc/parts.manifest /tmpfs/ados/
image_table_dos /tmpfs/ados 2>/dev/null; ADRC=$?
check "minimal arm64: MBR conversion: label dos, boot code dropped, manifest dos" \
    bash -c "[ $ADRC = 0 ] && grep -qx 'label: dos' /tmpfs/ados/layout.sfdisk && [ ! -e /tmpfs/ados/bootcode.bin ] && grep -qx UNITOTEM_TABLE=dos /tmpfs/ados/parts.manifest"
truncate -s 2G $W/minarm-dst.img; AL=$(losetup --find --show $W/minarm-dst.img)
sfdisk -q $AL < /tmpfs/ados/layout.sfdisk 2>/dev/null
GOT=$(sfdisk -d $AL | grep ' : start=' | sed -E 's/.*start= *([0-9]+), size= *([0-9]+), type=([0-9a-f]+).*/\1 \2 \3/' | tr '\n' ';')
check "minimal arm64: sfdisk applies the MBR: 2048/131072 c, ROOT_A, ROOT_B and DATA as 83" \
    [ "$GOT" = "2048 131072 c;$AS $SL 83;$AB $SL 83;$AD_S 524288 83;" ]
losetup -d "$AL"
truncate -s 512M $W/grow.img; GT=$(losetup --find --show $W/grow.img)
unxz -dc $W/minarm.pc.xz | partclone.restore -C -o "$GT" -s - -F -B >/dev/null 2>&1; RRC=$?
e2fsck -fy "$GT" >/dev/null 2>&1; ERC=$?
resize2fs "$GT" >/dev/null 2>&1; RZ=$?
BS=$(dumpe2fs -h "$GT" 2>/dev/null | awk -F': *' '/^Block count:/{b=$2}/^Block size:/{s=$2}END{print b*s}')
mount -o ro "$GT" /mt 2>/dev/null; GM=$(md5sum < /mt/system.bin 2>/dev/null | cut -d' ' -f1); GK=$(cat /mt/marker 2>/dev/null)
umount /mt 2>/dev/null; losetup -d "$GT"
check "minimal ROOT_A: partclone restore into the slot (-C), e2fsck clean, resize to the slot" \
    [ "$RRC $ERC $RZ $BS" = "0 0 0 536870912" ]
check "minimal ROOT_A: files identical after the grow" [ "$GM" = "$AMD5" ] && [ "$GK" = marker ]
# minimal image with an MBR table (type c boot partition, type 83 ROOT_A): found by the labels, described at the target layout, kept MBR
make_dos_min() {   # $1 image
    local img=$1 L fsbytes tsec
    rm -f -- "$img"; truncate -s 600M "$img"
    printf 'label: dos\nstart=2048, size=131072, type=c, bootable\nstart=133120, size=614400, type=83\n' | sfdisk -q "$img"
    L=$(losetup --find --show --partscan "$img"); sleep 1; partprobe "$L"; sleep 1
    mkfs.fat -F32 -n FIRMWARE "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"
    mount "${L}p1" /m; echo "UNITOTEM_SLOT_SECTORS=1048576" > /m/unitotem-layout; umount /m
    mount "${L}p2" /m; head -c 30000000 /dev/urandom > /m/system.bin; umount /m
    e2fsck -fy "${L}p2" >/dev/null 2>&1; resize2fs -M "${L}p2" >/dev/null 2>&1
    fsbytes=$(dumpe2fs -h "${L}p2" 2>/dev/null | awk -F': *' '/^Block count:/{b=$2}/^Block size:/{s=$2}END{print b*s}')
    tsec=$(( (fsbytes + 16 * 1048576 + 1048575) / 1048576 * 1048576 / 512 ))
    losetup -d "$L"
    printf 'label: dos\nstart=2048, size=131072, type=c, bootable\nstart=133120, size=%s, type=83\n' "$tsec" | sfdisk -q --force "$img"
}
make_dos_min $W/mindos.img
image_open $W/mindos.img 2>/dev/null; rm -rf /tmpfs/ddesc; image_describe /tmpfs/ddesc arm64 2>/dev/null; DDR=$?
image_close
DL=$(sed -nE 's#^/dev/[^ ]*[^0-9]([0-9]+) : start= *([0-9]+), size= *([0-9]+), type=([0-9a-f]+).*#\1 \2 \3 \4#p' /tmpfs/ddesc/layout.sfdisk | tr '\n' ';')
check "minimal MBR image: described at the target layout (c, then 83 for ROOT_A, ROOT_B, DATA)" \
    bash -c "[ $DDR = 0 ] && [ '$DL' = '1 2048 131072 c;2 133120 1048576 83;3 1181696 1048576 83;4 2230272 524288 83;' ]"
check "minimal MBR image: manifest synth, dos, four partitions, DATA 4, ROOT_A restore size the slot" \
    bash -c "grep -qx UNITOTEM_SYNTH=1 /tmpfs/ddesc/parts.manifest && grep -qx UNITOTEM_TABLE=dos /tmpfs/ddesc/parts.manifest && grep -qx UNITOTEM_NPARTS=4 /tmpfs/ddesc/parts.manifest && grep -qx UNITOTEM_DATA_PART=4 /tmpfs/ddesc/parts.manifest && grep -qx UNITOTEM_PART_SECTORS=1048576 /tmpfs/ddesc/parts.manifest"
image_table_dos /tmpfs/ddesc 2>/dev/null; DDOS=$?
check "minimal MBR image: image_table_dos leaves an MBR table as it is" bash -c "[ $DDOS = 0 ] && grep -q 'type=83' /tmpfs/ddesc/layout.sfdisk && grep -qx UNITOTEM_TABLE=dos /tmpfs/ddesc/parts.manifest"
check "full-size image: the descriptor has no UNITOTEM_SYNTH key" [ -z "$(grep '^UNITOTEM_SYNTH=' $D/parts.manifest)" ]
D4ACT=$(blk 4 UNITOTEM_PART_ACTION); D3ACT=$(blk 3 UNITOTEM_PART_ACTION)
check "full-size image: ROOT_B and DATA come from the image table (DATA is action data, ROOT_B is blanked, not streamed)" bash -c "grep -q 'name=\"ROOT_B\"' $D/layout.sfdisk && grep -q 'name=\"DATA\"' $D/layout.sfdisk && [ '$D4ACT' = data ] && [ '$D3ACT' = blank ]"
echo "$ok passed, $fail failed"
[ "$fail" = 0 ]
