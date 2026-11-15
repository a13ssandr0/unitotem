#!/bin/bash
# Runs INSIDE the privileged container of test_write_sd.sh (/repo read-only, /work scratch).
set -uo pipefail
W=/work; SCRIPT=/repo/deploy/script/write-sd.sh
ok=0; fail=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $name"; else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
mkdir -p /work/tmp /tmpfs; mount -t tmpfs -o size=3g tmpfs /tmpfs; export UNITOTEM_TMPFS=/tmpfs
mkdir -p /m
attach() { losetup --find --show --partscan "$1"; }
settle() { sleep 1; partprobe "$1" 2>/dev/null || true; sleep 1; }

# --- source image: the amd64 A/B layout, small
rm -f $W/src.img $W/src.img.xz $W/dst1.img $W/dst2.img $W/small.img
truncate -s 1200M $W/src.img
sgdisk -Z $W/src.img >/dev/null
sgdisk -n 1:0:+64M -t 1:ef00 -c 1:EFI $W/src.img >/dev/null
sgdisk -n 2:0:+300M -t 2:8300 -c 2:ROOT_A $W/src.img >/dev/null
sgdisk -n 3:0:+100M -t 3:8300 -c 3:ROOT_B $W/src.img >/dev/null
sgdisk -n 4:0:+400M -t 4:8300 -c 4:DATA $W/src.img >/dev/null
sgdisk -n 5:34:2047 -t 5:ef02 -c 5:BIOS $W/src.img >/dev/null
L=$(attach $W/src.img); settle "$L"
mkfs.fat -F32 -n EFI "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"; mkfs.ext4 -q -L ROOT_B "${L}p3"; mkfs.ext4 -q -L DATA "${L}p4"
head -c 1031168 /dev/urandom > /tmp/bios.bin; dd if=/tmp/bios.bin of="${L}p5" bs=1M conv=notrunc status=none
printf 'GRUBBOOT' | dd of=$W/src.img bs=1 seek=0 conv=notrunc status=none
mount "${L}p1" /m; mkdir -p /m/EFI/BOOT; head -c 2000000 /dev/urandom > /m/EFI/BOOT/BOOTX64.EFI; umount /m
mount "${L}p2" /m; head -c 40000000 /dev/urandom > /m/system.bin; echo marker-a > /m/marker; umount /m
mount "${L}p4" /m; echo data > /m/data.txt; umount /m
( cd /; for p in 1 2 4; do mkdir -p /s$p; mount -o ro "${L}p$p" /s$p; done
  { cd /s1 && find . -type f -exec md5sum {} +; cd /s2 && find . -type f -exec md5sum {} +; cd /s4 && find . -type f -exec md5sum {} +; } | sort > /tmp/src.md5
  for p in 1 2 4; do umount /s$p; done )
sfdisk -d "$L" | grep -E '^/dev' | sed -E 's#^/dev/loop[0-9]+p##' > /tmp/src.table
SRC_LABELID=$(sfdisk -d "$L" | awk -F': *' '/^label-id:/{print $2}')
ID() { blkid -o value -s UUID "$1"; }
for p in 1 2 3 4; do eval "SRC_UUID$p=$(ID ${L}p$p)"; done
losetup -d "$L"
xz -T0 -k -- $W/src.img; ls -la $W/src.img.xz | awk '{print "xz image bytes: "$5}'

verify() {   # verify DEVICE-LOOP FILE
    local dev=$1 file=$2
    check "$file: table (start, size, type, uuid, name) equals the image's" bash -c "diff <(sfdisk -d $dev | grep -E '^/dev' | sed -E 's#^/dev/loop[0-9]+p##') /tmp/src.table"
    check "$file: disk GUID equals the image's" [ "$(sfdisk -d $dev | awk -F': *' '/^label-id:/{print $2}')" = "$SRC_LABELID" ]
    for p in 1 2 3 4; do
        eval "u=\$SRC_UUID$p"
        check "$file: partition $p UUID equals the image's" [ "$(ID ${dev}p$p)" = "$u" ]
    done
    check "$file: labels EFI ROOT_A ROOT_B DATA" bash -c "[ \"\$(blkid -o value -s LABEL ${dev}p1) \$(blkid -o value -s LABEL ${dev}p2) \$(blkid -o value -s LABEL ${dev}p3) \$(blkid -o value -s LABEL ${dev}p4)\" = 'EFI ROOT_A ROOT_B DATA' ]"
    check "$file: raw BIOS partition identical" cmp -n 1031168 /tmp/bios.bin ${dev}p5
    check "$file: MBR boot code copied" bash -c "[ \"\$(dd if=$dev bs=8 count=1 status=none)\" = GRUBBOOT ]"
    for p in 1 2 4; do mkdir -p /d$p; mount -o ro ${dev}p$p /d$p; done
    check "$file: every file of EFI, ROOT_A and DATA identical (md5)" bash -c "diff <({ cd /d1 && find . -type f -exec md5sum {} +; cd /d2 && find . -type f -exec md5sum {} +; cd /d4 && find . -type f -exec md5sum {} +; } | sort) /tmp/src.md5"
    for p in 1 2 4; do umount /d$p; done
    check "$file: ext4 and FAT consistent" bash -c "e2fsck -fn ${dev}p2 && e2fsck -fn ${dev}p3 && e2fsck -fn ${dev}p4 && fsck.fat -n ${dev}p1"
}

# --- write the plain image
truncate -s 2G $W/dst1.img; D1=$(attach $W/dst1.img)
check "write-sd from .img succeeds" bash -c "bash $SCRIPT --yes $W/src.img $D1 2>/tmp/w1.log || { cat /tmp/w1.log >&2; exit 1; }"; cat /tmp/w1.log
settle "$D1"; verify "$D1" dst1
used=$(du -k $W/dst1.img | cut -f1)
echo "target allocated: ${used} KiB of 2097152 KiB (partitions: 1.2 GiB, data in use about 45 MiB)"
check "only the used blocks were written (target allocation under 300 MiB)" [ "$used" -lt 307200 ]
losetup -d "$D1"

# --- write the compressed image
truncate -s 2G $W/dst2.img; D2=$(attach $W/dst2.img)
check "write-sd from .img.xz succeeds" bash -c "bash $SCRIPT --yes $W/src.img.xz $D2 2>/tmp/w2.log || { cat /tmp/w2.log >&2; exit 1; }"; cat /tmp/w2.log
settle "$D2"; verify "$D2" dst2
check "the expanded copy is removed from tmpfs" bash -c "[ -z \"\$(ls -A /tmpfs)\" ]"
check "an image bigger than the free tmpfs is refused" bash -c "mount -o remount,size=20m /tmpfs && bash $SCRIPT --yes $W/src.img.xz $D2 2>&1 | grep -q 'does not fit in'"; mount -o remount,size=3g /tmpfs
check "a directory that is not tmpfs is refused" bash -c "UNITOTEM_TMPFS=/work bash $SCRIPT --yes $W/src.img.xz $D2 2>&1 | grep -q 'is not tmpfs'"
losetup -d "$D2"

# --- refusals
truncate -s 600M $W/small.img; D3=$(attach $W/small.img)
check "refuses a disk smaller than the partitions" bash -c "! bash $SCRIPT --yes $W/src.img $D3"
mkfs.ext4 -q "$D3"; mount "$D3" /m
check "refuses a disk with a mounted filesystem" bash -c "! bash $SCRIPT --yes $W/src.img $D3"
umount /m
check "answer n cancels and writes nothing" bash -c "echo n | bash $SCRIPT $W/src.img $D3; [ \$? -ne 0 ] && [ \"\$(blkid -o value -s TYPE $D3)\" = ext4 ]"
: > $W/empty.img; E=$(losetup --find --show $W/empty.img 2>/dev/null)
check "refuses a device with no medium (size 0), at once" bash -c "timeout 10 bash $SCRIPT --yes $W/src.img $E 2>&1 | grep -q 'has no medium'"
losetup -d "$E" 2>/dev/null; rm -f $W/empty.img
check "refuses a regular file" bash -c "! bash $SCRIPT --yes $W/src.img $W/small.img"
check "refuses a missing image" bash -c "! bash $SCRIPT --yes $W/none.img $D3"
losetup -d "$D3"
# --- minimal image (amd64: EFI with unitotem-layout, ROOT_A shrunk, no ROOT_B, no DATA): written to a disk, the target layout results
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
make_min $W/min.img ef00 EFI 1048576 yes
MA=$MIN_A_START; SL=1048576; MB=$(( (MA + SL + 2047) / 2048 * 2048 )); MDS=$(( (MB + SL + 2047) / 2048 * 2048 ))
truncate -s 2G $W/dst3.img; D3=$(attach $W/dst3.img)
check "write-sd from a minimal .img succeeds" bash -c "bash $SCRIPT --yes $W/min.img $D3 2>$W/w3.log || { cat $W/w3.log >&2; exit 1; }"; cat $W/w3.log
settle "$D3"
check "minimal: table is EFI, ROOT_A (slot), ROOT_B (slot), DATA (256 MiB), BIOS, in that place" \
    [ "$(sfdisk -d $D3 | grep -c ' : start=')" = 5 ] && [ "$(sfdisk -d $D3 | awk -F': *' '/^label:/{print $2}')" = gpt ]
GOTP=$(sfdisk -d $D3 | grep -E ' : start=' | sed -E 's/^[^ ]+ : start= *([0-9]+), size= *([0-9]+), type=.*name="([^"]*)".*/\1 \2 \3/' | sort -n | tr '\n' ';')
check "minimal: partitions at the target starts and sizes" [ "$GOTP" = "34 2014 BIOS;2048 131072 EFI;$MA $SL ROOT_A;$MB $SL ROOT_B;$MDS 524288 DATA;" ]
check "minimal: ROOT_B and DATA carry the Linux data GUID, BIOS the BIOS GUID" bash -c "sfdisk -d $D3 | grep 'name=\"ROOT_B\"' | grep -q 0FC63DAF-8483-4772-8E79-3D69D8477DE4 && sfdisk -d $D3 | grep 'name=\"DATA\"' | grep -q 0FC63DAF-8483-4772-8E79-3D69D8477DE4 && sfdisk -d $D3 | grep 'name=\"BIOS\"' | grep -q 21686148-6449-6E6F-744E-656564454649"
check "minimal: labels EFI ROOT_A ROOT_B DATA" bash -c "[ \"\$(blkid -o value -s LABEL ${D3}p1 ${D3}p2 ${D3}p3 ${D3}p4 | tr '\n' ' ')\" = 'EFI ROOT_A ROOT_B DATA ' ]"
mkdir -p /d1 /d2 /d3 /d4; mount -o ro ${D3}p3 /d3; mount -o ro ${D3}p4 /d4
check "minimal: ROOT_B and DATA are empty ext4 (no files)" bash -c "[ \"\$(find /d3 /d4 -mindepth 1 -not -name lost+found | wc -l)\" = 0 ] && [ \"\$(blkid -o value -s TYPE ${D3}p3 ${D3}p4 | sort -u)\" = ext4 ]"
umount /d3 /d4
check "minimal: ROOT_A grown to the slot (filesystem size = partition size)" bash -c "[ \"\$(dumpe2fs -h ${D3}p2 2>/dev/null | awk -F': *' '/^Block count:/{b=\$2}/^Block size:/{s=\$2}END{print b*s}')\" = $(( SL * 512 )) ]"
check "minimal: ext4 of ROOT_A, ROOT_B, DATA clean and FAT of EFI clean" bash -c "e2fsck -fn ${D3}p2 && e2fsck -fn ${D3}p3 && e2fsck -fn ${D3}p4 && fsck.fat -n ${D3}p1"
mount -o ro ${D3}p2 /d2; check "minimal: ROOT_A files identical to the image (md5) and the marker" bash -c "[ \"\$(md5sum /d2/system.bin | cut -d' ' -f1)\" = '$MIN_MD5' ] && [ \"\$(cat /d2/marker)\" = marker ]"; umount /d2
mount -o ro ${D3}p1 /d1; check "minimal: EFI keeps the image's files and unitotem-layout" bash -c "[ -f /d1/unitotem-layout ] && grep -qx 'UNITOTEM_SLOT_SECTORS=1048576' /d1/unitotem-layout && [ -f /d1/EFI/BOOT/BOOTX64.EFI ]"; umount /d1
losetup -d "$D3"
# --- minimal image with an MBR table (the arm64 flash image is MBR): written to a disk, the target layout results (MBR, four primaries)
make_dos_min() {   # $1 image
    local img=$1 L fsbytes tsec
    rm -f -- "$img"; truncate -s 600M "$img"
    printf 'label: dos\nstart=2048, size=131072, type=c, bootable\nstart=133120, size=614400, type=83\n' | sfdisk -q "$img"
    L=$(losetup --find --show --partscan "$img"); sleep 1; partprobe "$L"; sleep 1
    mkfs.fat -F32 -n FIRMWARE "${L}p1" >/dev/null; mkfs.ext4 -q -L ROOT_A "${L}p2"
    mount "${L}p1" /m; echo "UNITOTEM_SLOT_SECTORS=1048576" > /m/unitotem-layout; umount /m
    mount "${L}p2" /m; head -c 30000000 /dev/urandom > /m/system.bin; echo marker > /m/marker; MIN_MD5=$(md5sum < /m/system.bin | cut -d' ' -f1); umount /m
    e2fsck -fy "${L}p2" >/dev/null 2>&1; resize2fs -M "${L}p2" >/dev/null 2>&1
    fsbytes=$(dumpe2fs -h "${L}p2" 2>/dev/null | awk -F': *' '/^Block count:/{b=$2}/^Block size:/{s=$2}END{print b*s}')
    tsec=$(( (fsbytes + 16 * 1048576 + 1048575) / 1048576 * 1048576 / 512 ))
    losetup -d "$L"
    printf 'label: dos\nstart=2048, size=131072, type=c, bootable\nstart=133120, size=%s, type=83\n' "$tsec" | sfdisk -q --force "$img"
}
make_dos_min $W/mindos.img
SL=1048576; DB=1181696; DD=2230272
truncate -s 2G $W/dst4.img; D4=$(attach $W/dst4.img)
check "write-sd from a minimal MBR .img succeeds" bash -c "bash $SCRIPT --yes $W/mindos.img $D4 2>$W/w4.log || { cat $W/w4.log >&2; exit 1; }"; cat $W/w4.log
settle "$D4"
GOTD=$(sfdisk -d $D4 | grep ' : start=' | sed -E 's/^[^ ]+ : start= *([0-9]+), size= *([0-9]+), type=([0-9a-f]+).*/\1 \2 \3/' | sort -n | tr '\n' ';')
check "minimal MBR: table is dos with 2048/c, ROOT_A, ROOT_B, DATA as 83 at the target starts" [ "$(sfdisk -d $D4 | awk -F': *' '/^label:/{print $2}')" = dos ] && [ "$GOTD" = "2048 131072 c;133120 $SL 83;$DB $SL 83;$DD 524288 83;" ]
check "minimal MBR: labels FIRMWARE ROOT_A ROOT_B DATA" bash -c "[ \"\$(blkid -o value -s LABEL ${D4}p1 ${D4}p2 ${D4}p3 ${D4}p4 | tr '\n' ' ')\" = 'FIRMWARE ROOT_A ROOT_B DATA ' ]"
check "minimal MBR: ROOT_A grown to the slot, ROOT_B and DATA empty ext4, all clean" bash -c "[ \"\$(dumpe2fs -h ${D4}p2 2>/dev/null | awk -F': *' '/^Block count:/{b=\$2}/^Block size:/{s=\$2}END{print b*s}')\" = $(( SL * 512 )) ] && e2fsck -fn ${D4}p2 && e2fsck -fn ${D4}p3 && e2fsck -fn ${D4}p4 && fsck.fat -n ${D4}p1"
mkdir -p /d2 /d3 /d4; mount -o ro ${D4}p2 /d2; mount -o ro ${D4}p3 /d3; mount -o ro ${D4}p4 /d4
check "minimal MBR: ROOT_A files identical (md5), ROOT_B and DATA empty" bash -c "[ \"\$(md5sum /d2/system.bin | cut -d' ' -f1)\" = '$MIN_MD5' ] && [ \"\$(find /d3 /d4 -mindepth 1 -not -name lost+found | wc -l)\" = 0 ]"
umount /d2 /d3 /d4
losetup -d "$D4"
echo "$ok passed, $fail failed"
[ "$fail" = 0 ]
