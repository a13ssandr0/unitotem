#!/bin/bash
# Runs INSIDE the privileged container of test_write_sd.sh (/repo read-only, /work scratch).
set -uo pipefail
W=/work; SCRIPT=/repo/deploy/script/write-sd.sh
ok=0; fail=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $name"; else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
export WRITE_SD_TMP=/work/tmp; mkdir -p $WRITE_SD_TMP
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends pv >/dev/null 2>&1 || { echo 'cannot install pv'; exit 1; }
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
head -c 515584 /dev/urandom > /tmp/bios.bin; dd if=/tmp/bios.bin of="${L}p5" bs=1M conv=notrunc status=none
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
    check "$file: raw BIOS partition identical" cmp -n 515584 /tmp/bios.bin ${dev}p5
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
check "the expanded copy is removed" bash -c "[ -z \"\$(ls -A /work/tmp)\" ]"
losetup -d "$D2"

# --- refusals
truncate -s 600M $W/small.img; D3=$(attach $W/small.img)
check "refuses a disk smaller than the partitions" bash -c "! bash $SCRIPT --yes $W/src.img $D3"
mkfs.ext4 -q "$D3"; mount "$D3" /m
check "refuses a disk with a mounted filesystem" bash -c "! bash $SCRIPT --yes $W/src.img $D3"
umount /m
check "answer n cancels and writes nothing" bash -c "echo n | bash $SCRIPT $W/src.img $D3; [ \$? -ne 0 ] && [ \"\$(blkid -o value -s TYPE $D3)\" = ext4 ]"
check "refuses a regular file" bash -c "! bash $SCRIPT --yes $W/src.img $W/small.img"
check "refuses a missing image" bash -c "! bash $SCRIPT --yes $W/none.img $D3"
losetup -d "$D3"
echo "$ok passed, $fail failed"
[ "$fail" = 0 ]
