#!/bin/bash
# Runs INSIDE the privileged container of test_grow_data.sh. Only /dev/loop* devices are touched.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gdisk fdisk parted e2fsprogs dosfstools util-linux coreutils dash >/dev/null 2>&1 \
    || { echo "apt failed"; exit 1; }
BIG=0; [ "${1:-}" = --big ] && BIG=1
W=/work; LOGF=/tmp/grow.log
IMAGE_SIZE=14G; ROOT_SLOT_SIZE=5G; EFI_SIZE=512M; FIRMWARE_SIZE=512M
export LOOP=
pass=0; failn=0
# loop devices of this test are detached on any exit (only those backed by our own files)
cleanup() { for f in t.img big.img pr.img base-amd64.img base-arm64.img; do for l in $(losetup -j $W/$f -O NAME -n 2>/dev/null); do umount -l ${l}p2 ${l}p4 2>/dev/null; losetup -d $l 2>/dev/null; done; done; }
trap cleanup EXIT; trap 'exit 1' TERM INT
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Library under test (function only), with the initramfs log helpers replaced by files.
log_warning_msg() { echo "W: $*" >> "$LOGF"; }
log_success_msg() { echo "I: $*" >> "$LOGF"; }
SRC=/repo/unitotem/files/overlayfs-hook.sh
# dash is the closest to the initramfs shell: run the function under it through a wrapper
runfn() {  # runfn DEV
    : > "$LOGF"
    PATH=/tmp/blkidshim:$PATH GLOGF="$LOGF" GSRC="$SRC" dash -c 'log_warning_msg() { echo "W: $*" >> "$GLOGF"; }; log_success_msg() { echo "I: $*" >> "$GLOGF"; }
             UNITOTEM_SOURCE_ONLY=1; . "$GSRC"; grow_data "$1"; echo "rc=$?" >> "$GLOGF"' _ "$1"
}
# `blkid -L LABEL` in a container sees every loop device of the host (other containers included): the shim restricts it
# to the partitions of the loop device under test ($LOOP).
mkdir -p /tmp/blkidshim
cat > /tmp/blkidshim/blkid <<'SHIM'
#!/bin/bash
if [ "${1:-}" = -L ] && [ -n "${LOOP:-}" ]; then
    for d in ${LOOP}p*; do [ "$(/usr/sbin/blkid -s LABEL -o value "$d" 2>/dev/null)" = "$2" ] && { echo "$d"; exit 0; }; done
    exit 2
fi
exec /usr/sbin/blkid "$@"
SHIM
chmod +x /tmp/blkidshim/blkid
lines() { grep -vc '^rc=' "$LOGF"; }

# the kernel's devtmpfs, so partitions added or re-added by partx get their nodes like on a real system
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
nodes() { :; }

make_img() {  # make_img ARCH FILE  : the exact stage3 partitioning, then tiny filesystems
    local arch=$1 img=$2
    rm -f -- "$img"; truncate -s "$IMAGE_SIZE" "$img"
    if [ "$arch" = amd64 ]; then
        sgdisk -Z "$img" >/dev/null
        sgdisk -n "1:0:+${EFI_SIZE}" -t 1:ef00 -c 1:EFI "$img" >/dev/null
        sgdisk -n "2:0:+${ROOT_SLOT_SIZE}" -t 2:8300 -c 2:ROOT_A "$img" >/dev/null
        sgdisk -n "3:0:+${ROOT_SLOT_SIZE}" -t 3:8300 -c 3:ROOT_B "$img" >/dev/null
        sgdisk -n "4:0:0" -t 4:8300 -c 4:DATA "$img" >/dev/null
        sgdisk -n "5:34:2047" -t 5:ef02 -c 5:BIOS "$img" >/dev/null
    else
        local fe=$((1 + 512)) ae=$((1 + 512 + 5120)) be=$((1 + 512 + 10240))
        parted -s "$img" mklabel gpt
        parted -s "$img" mkpart FIRMWARE fat32 "1M" "${fe}M"
        parted -s "$img" mkpart ROOT_A ext4 "${fe}MiB" "${ae}MiB"
        parted -s "$img" mkpart ROOT_B ext4 "${ae}MiB" "${be}MiB"
        parted -s "$img" mkpart DATA ext4 "${be}MiB" 100%
    fi
    LOOP=$(losetup --find --show --partscan "$img"); nodes
    if [ "$arch" = amd64 ]; then mkfs.fat -F32 -n EFI ${LOOP}p1 >/dev/null; else mkfs.fat -F32 -n FIRMWARE ${LOOP}p1 >/dev/null; fi
    mkfs.ext4 -q -F -L ROOT_A ${LOOP}p2; mkfs.ext4 -q -F -L ROOT_B ${LOOP}p3; mkfs.ext4 -q -F -L DATA ${LOOP}p4
    mkdir -p /mnt/d; mount ${LOOP}p4 /mnt/d
    for i in 1 2 3 4 5 6 7 8; do head -c $((i*1000003)) /dev/urandom > /mnt/d/f$i; done
    mkdir -p /mnt/d/upper/etc.a; cp /etc/passwd /mnt/d/upper/etc.a/
    (cd /mnt/d && find . -type f -exec sha256sum {} + | sort -k2 > /tmp/sums.txt)
    umount /mnt/d; losetup -d "$LOOP"
}

hash_parts() {  # hash_parts LOOP > file : sha256 of every partition except DATA (p4)
    for n in 1 2 3 5; do [ -e ${1}p$n ] && echo "p$n $(sha256sum < ${1}p$n)"; done
}

scenario() {  # scenario NAME ARCH BASE DISKSIZE EXPECT(grow|noop)
    local name=$1 arch=$2 base=$3 size=$4 expect=$5
    echo "=== $name ($arch, disk $size, expect $expect)"
    cp --sparse=always "$base" $W/t.img; truncate -s "$size" $W/t.img
    LOOP=$(losetup --find --show --partscan $W/t.img); nodes
    hash_parts $LOOP > /tmp/h.before
    sgdisk -i 4 $LOOP | grep -E 'unique GUID|name|Partition GUID code' > /tmp/g.before
    local sz0; sz0=$(blockdev --getsz ${LOOP}p4)
    mkdir -p /mnt/r; mount -o ro ${LOOP}p2 /mnt/r   # the root slot is mounted from the same disk
    runfn ${LOOP}p4; cat "$LOGF" | sed 's/^/    log: /'
    local sz1; sz1=$(blockdev --getsz ${LOOP}p4)
    if [ "$expect" = grow ]; then
        local dend=$(( $(blockdev --getsz $LOOP) - 34 ))
        local pend=$(( $(cat /sys/class/block/${LOOP##*/}p4/start) + sz1 ))
        chk "$name: DATA reaches the last usable sector ($pend vs $dend, < 2048 sectors apart)" [ $((dend - pend)) -lt 2048 ]
        chk "$name: DATA grew ($((sz0/2048)) -> $((sz1/2048)) MiB)" [ "$sz1" -gt "$sz0" ]
        local bc bs; bc=$(dumpe2fs -h ${LOOP}p4 2>/dev/null | sed -n 's/^Block count: *//p'); bs=$(dumpe2fs -h ${LOOP}p4 2>/dev/null | sed -n 's/^Block size: *//p')
        chk "$name: filesystem fills the partition ($((bc*bs/512)) of $sz1 sectors)" [ $((sz1 - bc*bs/512)) -lt 4096 ]
        chk "$name: one 'grown' log line" [ "$(lines)" = 1 ]
        umount /mnt/r
        chk "$name: e2fsck -fn DATA clean" e2fsck -fn ${LOOP}p4 >/dev/null 2>&1
        chk "$name: GPT valid (sgdisk -v)" bash -c "sgdisk -v $LOOP 2>&1 | grep -q 'No problems found'"
        sgdisk -i 4 $LOOP | grep -E 'unique GUID|name|Partition GUID code' > /tmp/g.after
        chk "$name: DATA GUID, type and name unchanged" cmp -s /tmp/g.before /tmp/g.after
        chk "$name: backup GPT at the disk end (no sgdisk warning)" bash -c "! sgdisk -p $LOOP 2>&1 | grep -qi 'warning\|corrupt'"
        # second run: no-op
        mount -o ro ${LOOP}p2 /mnt/r
        local c0; c0=$(sgdisk -p $LOOP | md5sum)
        runfn ${LOOP}p4
        chk "$name: second run is a no-op (no log, table unchanged)" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ] && [ \"\$(sgdisk -p $LOOP | md5sum)\" = \"$c0\" ]"
        umount /mnt/r
    else
        chk "$name: DATA size unchanged" [ "$sz1" = "$sz0" ]
        chk "$name: no log line" [ "$(lines)" = 0 ]
        umount /mnt/r
    fi
    mount ${LOOP}p4 /mnt/d
    chk "$name: file checksums unchanged" bash -c "cd /mnt/d && find . -type f -not -name '.*' -exec sha256sum {} + | sort -k2 | cmp -s - /tmp/sums.txt"
    umount /mnt/d
    hash_parts $LOOP > /tmp/h.after
    chk "$name: other partitions byte-identical" cmp -s /tmp/h.before /tmp/h.after
    losetup -d "$LOOP"; rm -f $W/t.img
}

B=$W/base-amd64.img
phase1() {
for arch in amd64 arm64; do
    make_img $arch $W/base-$arch.img
    echo "--- layout $arch"; sgdisk -p $W/base-$arch.img | sed -n '/Number/,$p'
    scenario "$arch-32G"     $arch $W/base-$arch.img 32G grow
    scenario "$arch-15G"     $arch $W/base-$arch.img 15G grow
    scenario "$arch-image"   $arch $W/base-$arch.img 14G noop
    scenario "$arch-nofree"  $arch $W/base-$arch.img 14G noop  # exact image size
done
# no-op variants on amd64 base
B=$W/base-amd64.img
echo "=== less than 64 MiB free"
cp --sparse=always $B $W/t.img; truncate -s $((14*1024+32))M $W/t.img
LOOP=$(losetup --find --show --partscan $W/t.img); nodes; sgdisk -p $LOOP > /tmp/t.before
runfn ${LOOP}p4; chk "32 MiB free: skipped silently, table untouched" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ] && [ \"\$(sgdisk -p $LOOP)\" = \"\$(cat /tmp/t.before)\" ]"
losetup -d $LOOP

echo "=== wrong filesystem (vfat on DATA)"
cp --sparse=always $B $W/t.img; truncate -s 32G $W/t.img
LOOP=$(losetup --find --show --partscan $W/t.img); nodes; mkfs.fat ${LOOP}p4 >/dev/null; sgdisk -p $LOOP > /tmp/t.before
runfn ${LOOP}p4; chk "vfat DATA: one log line, table untouched" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 1 ] && [ \"\$(sgdisk -p $LOOP)\" = \"\$(cat /tmp/t.before)\" ]"
losetup -d $LOOP

echo "=== partition after DATA"
cp --sparse=always $B $W/t.img; truncate -s 32G $W/t.img
sgdisk -e $W/t.img >/dev/null; sgdisk -n 6:30G:+100M -t 6:8300 -c 6:EXTRA $W/t.img >/dev/null
LOOP=$(losetup --find --show --partscan $W/t.img); nodes; sgdisk -p $LOOP > /tmp/t.before
runfn ${LOOP}p4; chk "partition after DATA: one log line, table untouched" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 1 ] && [ \"\$(sgdisk -p $LOOP)\" = \"\$(cat /tmp/t.before)\" ]"
losetup -d $LOOP

echo "=== DATA not found / not a partition"
runfn /dev/nonexistent; chk "missing device: silent, rc=0" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ] && grep -q '^rc=0' $LOGF"
LOOP=$(losetup --find --show $W/base-amd64.img); runfn $LOOP; chk "whole disk device (no partition): silent" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ]"; losetup -d $LOOP

echo "=== interruption: table written + kernel told, filesystem not grown (cut before resize2fs)"
cp --sparse=always $B $W/t.img; truncate -s 32G $W/t.img
LOOP=$(losetup --find --show --partscan $W/t.img); nodes
sgdisk -e $LOOP >/dev/null; echo ", +" | sfdisk --no-reread --no-tell-kernel --wipe never --wipe-partitions never -q -N 4 $LOOP >/dev/null 2>&1; partx -u --nr 4 $LOOP
mount -o ro ${LOOP}p2 /mnt/r
runfn ${LOOP}p4; cat $LOGF | sed 's/^/    log: /'
chk "resumed: filesystem grown by the next run" bash -c "e2fsck -fn ${LOOP}p4 >/dev/null 2>&1 && [ \$(( \$(blockdev --getsz ${LOOP}p4) - \$(dumpe2fs -h ${LOOP}p4 2>/dev/null | awk '/^Block count/{c=\$3} /^Block size/{s=\$3} END{print c*s/512}') )) -lt 4096 ]"
umount /mnt/r; losetup -d $LOOP

echo "=== interruption: cut after sgdisk -e only (table valid, DATA not yet enlarged)"
cp --sparse=always $B $W/t.img; truncate -s 32G $W/t.img
sgdisk -e $W/t.img >/dev/null
LOOP=$(losetup --find --show --partscan $W/t.img); nodes; mount -o ro ${LOOP}p2 /mnt/r
runfn ${LOOP}p4; chk "after -e only: next run completes" bash -c "e2fsck -fn ${LOOP}p4 >/dev/null 2>&1 && [ \$(blockdev --getsz ${LOOP}p4) -gt 40000000 ]"
umount /mnt/r; losetup -d $LOOP

echo "=== failure: resize2fs fails -> one log line, boot continues, next run recovers"
cp --sparse=always $B $W/t.img; truncate -s 32G $W/t.img
LOOP=$(losetup --find --show --partscan $W/t.img); nodes
mkdir -p /tmp/shim; printf '#!/bin/sh\nexit 1\n' > /tmp/shim/resize2fs; chmod +x /tmp/shim/resize2fs
PATH=/tmp/shim:$PATH runfn ${LOOP}p4; cat $LOGF | sed 's/^/    log: /'
chk "resize2fs failure: one warning line, rc=0" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 1 ] && grep -q '^rc=0' $LOGF"
runfn ${LOOP}p4
chk "next run finishes the filesystem" bash -c "e2fsck -fn ${LOOP}p4 >/dev/null 2>&1 && [ \$(blockdev --getsz ${LOOP}p4) -gt 40000000 ]"
losetup -d $LOOP

echo "=== interruption: SIGKILL inside resize2fs (400 GB), next run repairs and grows"
# pristine: the table and the kernel already give DATA its new size, the filesystem is still the small one
cp --sparse=always $B $W/pr.img; truncate -s 400G $W/pr.img
LOOP=$(losetup --find --show --partscan $W/pr.img); nodes
sgdisk -e $LOOP >/dev/null; echo ", +" | sfdisk --no-reread --no-tell-kernel --wipe never --wipe-partitions never -q -N 4 $LOOP >/dev/null 2>&1; partx -u --nr 4 $LOOP
e2fsck -fp ${LOOP}p4 >/dev/null 2>&1
mount -o ro ${LOOP}p2 /mnt/r; umount /mnt/r
# reference checksums of this image's files (/tmp/sums.txt belongs to the last base made, arm64)
mount -o ro ${LOOP}p4 /mnt/d; (cd /mnt/d && find . -type f -not -name '.*' -exec sha256sum {} + | sort -k2) > /tmp/grow-a-sums.txt; umount /mnt/d
losetup -d $LOOP
delays=(0.085 0.09 0.095 0.10); N=60; found=0; tries=0
for ((i=0; i<N; i++)); do
    d=${delays[$((i%4))]}; tries=$((i+1))
    cp --sparse=always $W/pr.img $W/t.img
    LOOP=$(losetup --find --show --partscan $W/t.img); nodes
    resize2fs ${LOOP}p4 >/dev/null 2>&1 & rp=$!; sleep $d; kill -9 $rp 2>/dev/null; wait $rp 2>/dev/null
    e2fsck -fn ${LOOP}p4 >/dev/null 2>&1; rc=$?
    if [ "$rc" = 4 ]; then found=1; break; fi
    losetup -d $LOOP; rm -f -- $W/t.img
done
if [ "$found" = 1 ]; then
    echo "attempts needed: $tries (delay $d)"; echo "    tries: $tries, damage hits: $found"
    e2fsck -fp ${LOOP}p4 >/tmp/grow-a-fp.out 2>&1; rcp=$?
    e2fsck -fn ${LOOP}p4 >/tmp/grow-a-fn.out 2>&1
    echo "    e2fsck -fp rc=$rcp: $(head -n 3 /tmp/grow-a-fp.out | tr '\n' '|')"
    chk "damage is the resize inode one: e2fsck -fp rc 4" [ "$rcp" = 4 ]
    chk "damage is the resize inode one: 'Resize inode not valid' in -fp and -fn output" bash -c "grep -q 'Resize inode not valid' /tmp/grow-a-fp.out && grep -q 'Resize inode not valid' /tmp/grow-a-fn.out"
    mount -o ro ${LOOP}p2 /mnt/r
    runfn ${LOOP}p4; sed 's/^/    log: /' $LOGF
    chk "repair run: exactly the two lines (repaired, then grown)" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 2 ] && grep -qxF 'I: grow: repaired DATA after an interrupted resize' $LOGF && grep -q '^I: grow: DATA grown to ' $LOGF"
    chk "repair run: e2fsck -fn clean" bash -c "e2fsck -fn ${LOOP}p4 >/dev/null 2>&1"
    sz1=$(blockdev --getsz ${LOOP}p4)
    bc=$(dumpe2fs -h ${LOOP}p4 2>/dev/null | sed -n 's/^Block count: *//p'); bs=$(dumpe2fs -h ${LOOP}p4 2>/dev/null | sed -n 's/^Block size: *//p')
    chk "repair run: filesystem fills the partition ($((bc*bs/512)) of $sz1 sectors)" [ $((sz1 - bc*bs/512)) -lt 4096 ]
    mount ${LOOP}p4 /mnt/d
    chk "repair run: file checksums unchanged" bash -c "cd /mnt/d && find . -type f -not -name '.*' -exec sha256sum {} + | sort -k2 | cmp -s - /tmp/grow-a-sums.txt"
    umount /mnt/d
    runfn ${LOOP}p4
    chk "repair run: second run is a no-op (zero log lines)" [ "$(lines)" = 0 ]
    umount /mnt/r; losetup -d $LOOP; rm -f -- $W/t.img
else
    bad "interrupted resize: no damage produced in $N attempts"
fi
rm -f -- $W/pr.img

echo "=== damaged but not smaller than its partition: left alone"
# The warning for this damage comes from the hook's own e2fsck -p, which runs before grow_data.
# grow_data itself logs nothing here: it returns before any fsck or write.
cp --sparse=always $B $W/t.img
LOOP=$(losetup --find --show --partscan $W/t.img); nodes
debugfs -w -R 'clri <7>' ${LOOP}p4 >/dev/null 2>&1   # zero the resize inode (ino 7)
e2fsck -fn ${LOOP}p4 >/tmp/grow-b-fn.out 2>&1; rcb=$?
bc=$(dumpe2fs -h ${LOOP}p4 2>/dev/null | sed -n 's/^Block count: *//p'); bs=$(dumpe2fs -h ${LOOP}p4 2>/dev/null | sed -n 's/^Block size: *//p')
psz=$(blockdev --getsz ${LOOP}p4)
chk "precondition: e2fsck -fn reports damage (rc=$rcb)" [ "$rcb" != 0 ]
chk "precondition: filesystem not smaller than its partition (gap $((psz - bc*bs/512)) sectors)" [ $((psz - bc*bs/512)) -lt 65536 ]
h1=$(dd if=${LOOP}p4 bs=1M status=none | sha256sum)
mount -o ro ${LOOP}p2 /mnt/r
runfn ${LOOP}p4; sed 's/^/    log: /' $LOGF
chk "damaged, not smaller: no log line" [ "$(lines)" = 0 ]
h2=$(dd if=${LOOP}p4 bs=1M status=none | sha256sum)
chk "damaged, not smaller: DATA content unchanged (no e2fsck -fy)" [ "$h1" = "$h2" ]
umount /mnt/r; losetup -d $LOOP; rm -f -- $W/t.img

}
if [ "${PHASE2_ONLY:-0}" = 1 ]; then for arch in amd64 arm64; do make_img $arch $W/base-$arch.img; done; else phase1; fi
if [ "$BIG" = 1 ]; then
    echo "=== timing: 400 GB sparse disk, DATA 3 GiB -> 400 GB"
    for mode in offline online; do
        cp --sparse=always $B $W/big.img; truncate -s 400G $W/big.img
        LOOP=$(losetup --find --show --partscan $W/big.img); nodes
        mount -o ro ${LOOP}p2 /mnt/r
        if [ "$mode" = offline ]; then
            t0=$(date +%s.%N); runfn ${LOOP}p4; t1=$(date +%s.%N)
            echo "TIME offline grow_data (sgdisk+sfdisk+partx+e2fsck -f+resize2fs): $(echo "$t1 - $t0" | bc 2>/dev/null || awk "BEGIN{print $t1-$t0}") s"
            echo "     file blocks actually allocated: $(du -sh $W/big.img | cut -f1)"
        else
            sgdisk -e $LOOP >/dev/null; echo ", +" | sfdisk --no-reread --no-tell-kernel --wipe never --wipe-partitions never -q -N 4 $LOOP >/dev/null 2>&1; partx -u --nr 4 $LOOP
            mount ${LOOP}p4 /mnt/d
            t0=$(date +%s.%N); resize2fs ${LOOP}p4 >/dev/null 2>&1; t1=$(date +%s.%N)
            echo "TIME online resize2fs only: $(awk "BEGIN{print $t1-$t0}") s"
            umount /mnt/d
        fi
        e2fsck -fn ${LOOP}p4 >/dev/null 2>&1 && echo "     e2fsck -fn clean" || echo "     e2fsck -fn NOT clean"
        umount /mnt/r; losetup -d $LOOP; rm -f $W/big.img
    done
    echo "=== SIGKILL of the offline resize2fs at several moments (400 GB), then the next boot's e2fsck -p and grow_data"
    for delay in 0.02 0.05 0.08 0.12; do
        cp --sparse=always $B $W/big.img; truncate -s 400G $W/big.img
        LOOP=$(losetup --find --show --partscan $W/big.img)
        sgdisk -e $LOOP >/dev/null; echo ", +" | sfdisk --no-reread --no-tell-kernel --wipe never --wipe-partitions never -q -N 4 $LOOP >/dev/null 2>&1; partx -u --nr 4 $LOOP
        e2fsck -fp ${LOOP}p4 >/dev/null 2>&1
        resize2fs ${LOOP}p4 >/dev/null 2>&1 & rp=$!; sleep $delay; kill -9 $rp 2>/dev/null; wait $rp 2>/dev/null
        e2fsck -fn ${LOOP}p4 >/tmp/fsck.out 2>&1; r1=$?
        e2fsck -p ${LOOP}p4 >/dev/null 2>&1; r2=$?
        runlib=$(runfn ${LOOP}p4; cat $LOGF | tr '\n' ' ')
        e2fsck -fn ${LOOP}p4 >/dev/null 2>&1; r3=$?
        echo "     kill at ${delay}s: fsck -fn rc=$r1; boot e2fsck -p rc=$r2; grow_data: $runlib; final fsck -fn rc=$r3"
        losetup -d $LOOP; rm -f $W/big.img
    done
fi

# ---------------------------------------------------------------- phase 2: layout completion from a flash image
runlay() {  # runlay : layout_complete then grow_data, as overlayfs-hook.sh does (ROOT_A found by label)
    : > "$LOGF"
    PATH=/tmp/blkidshim:$PATH GLOGF="$LOGF" GSRC="$SRC" dash -c 'log_warning_msg() { echo "W: $*" >> "$GLOGF"; }; log_success_msg() { echo "I: $*" >> "$GLOGF"; }
        UNITOTEM_SOURCE_ONLY=1; . "$GSRC"; layout_complete; echo "rc=$?" >> "$GLOGF"
        d=$(blkid -L DATA) && grow_data "$d"'
}
part_hash() { dd if="$1" bs=1M status=none | sha256sum | cut -c1-64; }

flash_of() {  # flash_of ARCH : make the flash image of base-ARCH.img
    bash /repo/unitotem/make-flash-image.sh $W/base-$1.img $W/flash-$1.img
}

layout_scenario() {  # layout_scenario NAME ARCH DISKSIZE
    local name=$1 arch=$2 size=$3 f=$W/flash-$2.img
    echo "=== $name ($arch flash image on a $size disk)"
    cp --sparse=always $f $W/t.img; truncate -s $size $W/t.img
    LOOP=$(losetup --find --show --partscan $W/t.img)
    local rootp=2 bootp=1
    hroot=$(part_hash ${LOOP}p$rootp); hboot=$(part_hash ${LOOP}p$bootp)
    [ "$arch" = amd64 ] && hbios=$(part_hash ${LOOP}p5)
    mkdir -p /mnt/r; mount -o ro ${LOOP}p$rootp /mnt/r
    t0=$(date +%s.%N); runlay; t1=$(date +%s.%N)
    sed 's/^/    log: /' "$LOGF"; echo "    elapsed: $(awk "BEGIN{print $t1-$t0}") s"
    chk "$name: one 'created' log line" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 1 ] && grep -q 'created ROOT_B DATA' $LOGF"
    chk "$name: ROOT_B is exactly 5 GiB (10485760 sectors), label ROOT_B" bash -c "[ \$(blockdev --getsz ${LOOP}p3) = 10485760 ] && [ \"\$(blkid -s LABEL -o value ${LOOP}p3)\" = ROOT_B ]"
    chk "$name: ROOT_B starts right after ROOT_A, 1 MiB aligned" bash -c "[ \$(( \$(cat /sys/class/block/${LOOP##*/}p3/start) % 2048 )) = 0 ] && [ \$(cat /sys/class/block/${LOOP##*/}p3/start) = \$(( \$(cat /sys/class/block/${LOOP##*/}p2/start) + \$(cat /sys/class/block/${LOOP##*/}p2/size) )) ]"
    local dend=$(( $(blockdev --getsz $LOOP) - 34 )); local pend=$(( $(cat /sys/class/block/${LOOP##*/}p4/start) + $(blockdev --getsz ${LOOP}p4) ))
    chk "$name: DATA reaches the last usable sector ($pend vs $dend)" [ $((dend - pend)) -lt 2048 ]
    chk "$name: DATA is ext4, label DATA" bash -c "[ \"\$(blkid -s TYPE -o value ${LOOP}p4)\" = ext4 ] && [ \"\$(blkid -s LABEL -o value ${LOOP}p4)\" = DATA ]"
    chk "$name: GPT names and type codes" bash -c "sgdisk -p $LOOP | grep -E '^ +3 ' | grep -q '8300  ROOT_B' && sgdisk -p $LOOP | grep -E '^ +4 ' | grep -q '8300  DATA'"
    chk "$name: no pending flag left" bash -c "! sfdisk -d $LOOP | grep -q GUID:48"
    chk "$name: GPT valid, backup at the disk end" bash -c "sgdisk -v $LOOP 2>&1 | grep -q 'No problems found' && ! sgdisk -p $LOOP 2>&1 | grep -qi 'warning\|corrupt'"
    chk "$name: e2fsck -fn ROOT_B and DATA clean" bash -c "e2fsck -fn ${LOOP}p3 >/dev/null 2>&1 && e2fsck -fn ${LOOP}p4 >/dev/null 2>&1"
    chk "$name: slot_sound's lookup finds ROOT_B (blkid -t PARTLABEL, LABEL) and it holds no system" bash -c "[ \"\$(blkid -t PARTLABEL=ROOT_B -o device)\" = ${LOOP}p3 ] && [ \"\$(blkid -s LABEL -o value ${LOOP}p3)\" = ROOT_B ] && mkdir -p /mnt/b && mount -o ro ${LOOP}p3 /mnt/b && ! test -e /mnt/b/usr/share/unitotem/release-version; r=\$?; umount /mnt/b; exit \$r"
    chk "$name: only one filesystem labelled ROOT_A (no stale copy)" bash -c "[ \$(blkid | grep -c 'LABEL=\"ROOT_A\"') = 1 ]"
    chk "$name: ROOT_A still mounted and readable" bash -c "ls /mnt/r/lost+found >/dev/null"
    umount /mnt/r
    chk "$name: ROOT_A byte-identical" [ "$hroot" = "$(part_hash ${LOOP}p$rootp)" ]
    chk "$name: boot partition byte-identical" [ "$hboot" = "$(part_hash ${LOOP}p$bootp)" ]
    [ "$arch" = amd64 ] && chk "$name: BIOS-boot partition byte-identical" [ "$hbios" = "$(part_hash ${LOOP}p5)" ]
    mount ${LOOP}p4 /mnt/d; chk "$name: DATA mounts, holds only lost+found (empty like stage3's)" bash -c "[ \"\$(ls -A /mnt/d)\" = lost+found ]"; 
    chk "$name: mkdir -p seeding paths work on the new DATA (hook, persist-paths, ssh-hostkey)" bash -c "mkdir -p /mnt/d/upper/etc.a /mnt/d/work/etc.a /mnt/d/unitotem/persist /mnt/d/unitotem/ssh-host-keys && ls /mnt/d/unitotem/persist >/dev/null"
    umount /mnt/d
    sgdisk -p $LOOP > /tmp/lay.t1
    mount -o ro ${LOOP}p2 /mnt/r; runlay; umount /mnt/r
    chk "$name: second run is a no-op (no log, table unchanged)" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ] && sgdisk -p $LOOP | cmp -s - /tmp/lay.t1"
    losetup -d $LOOP; rm -f $W/t.img
}

for arch in amd64 arm64; do
    echo "=== flash image of $arch"
    flash_of $arch | sed 's/^/    /'
    echo "--- flash layout $arch ($(stat -c %s $W/flash-$arch.img) bytes, $(du -h $W/flash-$arch.img | cut -f1) allocated)"; sgdisk -p $W/flash-$arch.img | sed -n '/Number/,$p'
    chk "flash-$arch: sgdisk -v clean and only the kept partitions" bash -c "sgdisk -v $W/flash-$arch.img 2>&1 | grep -q 'No problems found' && ! sgdisk -p $W/flash-$arch.img | grep -Eq 'ROOT_B|DATA'"
    layout_scenario "$arch-layout-20G" $arch 20G
    layout_scenario "$arch-layout-2G-more" $arch $(( $(stat -c %s $W/flash-$arch.img) / 1048576 + 5400 ))M
done

# ---- negative and interruption cases (amd64 flash image)
F=$W/flash-amd64.img
fsz=$(( $(stat -c %s $F) / 1048576 ))
fresh() {  # fresh SIZE_MIB : attach a copy of the flash image on a disk of that size, ROOT_A mounted
    cp --sparse=always $F $W/t.img; truncate -s $1M $W/t.img
    LOOP=$(losetup --find --show --partscan $W/t.img); mkdir -p /mnt/r; mount -o ro ${LOOP}p2 /mnt/r
}
done_() { umount /mnt/r 2>/dev/null; umount /mnt/d 2>/dev/null; losetup -d $LOOP; rm -f $W/t.img; }

echo "=== not enough free space (flash + 5300 MiB < 5 GiB + 256 MiB after ROOT_A)"
fresh $((fsz + 5300)); sgdisk -p $LOOP > /tmp/lay.t0; runlay
chk "tight disk: one log line, table untouched" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 1 ] && grep -q 'not enough free space' $LOGF && sgdisk -p $LOOP | cmp -s - /tmp/lay.t0"
done_

echo "=== crash after the table write (mke2fs fails): flagged partitions, next boot completes"
fresh 20480; mkdir -p /tmp/shim2; printf '#!/bin/sh\nexit 1\n' > /tmp/shim2/mke2fs; chmod +x /tmp/shim2/mke2fs
PATH=/tmp/shim2:$PATH runlay; sed 's/^/    log: /' $LOGF
chk "after the table write: table has ROOT_B and DATA, both flagged" bash -c "[ \$(sfdisk -d $LOOP | grep -c GUID:48) = 2 ]"
chk "after the table write: one warning, boot continues" bash -c "grep -q 'mke2fs ROOT_B failed' $LOGF && grep -q '^rc=0' $LOGF"
runlay; sed 's/^/    log: /' $LOGF
chk "next run: both formatted, flags cleared, DATA grown path no-op" bash -c "e2fsck -fn ${LOOP}p3 >/dev/null 2>&1 && e2fsck -fn ${LOOP}p4 >/dev/null 2>&1 && ! sfdisk -d $LOOP | grep -q GUID:48 && grep -q 'created ROOT_B DATA' $LOGF"
done_

echo "=== crash between ROOT_B and DATA formats"
fresh 20480; printf '#!/bin/sh\nif [ -e /tmp/shim3.n ]; then exit 1; fi\n: > /tmp/shim3.n\nexec /sbin/mke2fs "$@"\n' > /tmp/shim2/mke2fs; chmod +x /tmp/shim2/mke2fs; rm -f /tmp/shim3.n
PATH=/tmp/shim2:$PATH runlay; sed 's/^/    log: /' $LOGF
chk "ROOT_B done, DATA still flagged" bash -c "[ \$(sfdisk -d $LOOP | grep -c GUID:48) = 1 ] && sfdisk -d $LOOP | grep 'GUID:48' | grep -q DATA && [ \"\$(blkid -s LABEL -o value ${LOOP}p3)\" = ROOT_B ]"
rm -f /tmp/shim3.n; runlay
chk "next run completes DATA" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p4)\" = DATA ] && ! sfdisk -d $LOOP | grep -q GUID:48"
done_

echo "=== stale signatures in the new areas (reused card)"
fresh 20480; B=$(( $(cat /sys/class/block/${LOOP##*/}p2/start) + $(cat /sys/class/block/${LOOP##*/}p2/size) ))
umount /mnt/r
dd if=${LOOP}p2 of=$LOOP bs=512 seek=$B count=16384 conv=notrunc status=none            # a copy of ROOT_A (label ROOT_A) where ROOT_B will start
dd if=${LOOP}p2 of=$LOOP bs=512 seek=$((B+10485760)) count=16384 conv=notrunc status=none  # and where DATA will start
partx -u $LOOP 2>/dev/null; mount -o ro ${LOOP}p2 /mnt/r
runlay
chk "stale ROOT_A copies are gone: one ROOT_A, ROOT_B and DATA labelled right" bash -c "[ \$(blkid | grep -c 'LABEL=\"ROOT_A\"') = 1 ] && [ \"\$(blkid -s LABEL -o value ${LOOP}p3)\" = ROOT_B ] && [ \"\$(blkid -s LABEL -o value ${LOOP}p4)\" = DATA ]"
done_

echo "=== ROOT_A is not the last partition"
fresh 20480; umount /mnt/r; sgdisk -e $LOOP >/dev/null 2>&1; sgdisk -n 6:15G:+100M -t 6:8300 -c 6:EXTRA $LOOP >/dev/null 2>&1; partx -a --nr 6 $LOOP 2>/dev/null; mount -o ro ${LOOP}p2 /mnt/r
sgdisk -p $LOOP > /tmp/lay.t0; runlay; sed 's/^/    log: /' $LOGF; sgdisk -p $LOOP | diff /tmp/lay.t0 - | sed 's/^/    diff: /'
chk "partition after ROOT_A: silent skip, table untouched" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ] && sgdisk -p $LOOP | cmp -s - /tmp/lay.t0"
done_

echo "=== DATA exists but ROOT_B does not: not a minimal image, untouched"
fresh 20480; umount /mnt/r; sgdisk -e $LOOP >/dev/null 2>&1; sgdisk -n 4:15G:+1G -t 4:8300 -c 4:DATA $LOOP >/dev/null 2>&1; sgdisk -p $LOOP > /tmp/lay.t0
sgdisk -v $LOOP >/dev/null; mount -o ro ${LOOP}p2 /mnt/r; runlay
chk "DATA without ROOT_B: nothing created, table untouched" bash -c "! sgdisk -p $LOOP | grep -q ROOT_B && sgdisk -p $LOOP | cmp -s - /tmp/lay.t0"
done_

echo "=== full image (ROOT_B and DATA exist): layout is a no-op"
cp --sparse=always $W/base-amd64.img $W/t.img; LOOP=$(losetup --find --show --partscan $W/t.img); mkdir -p /mnt/r; mount -o ro ${LOOP}p2 /mnt/r
sgdisk -p $LOOP > /tmp/lay.t0; runlay
chk "full image: no log, table untouched" bash -c "[ \"\$(grep -vc '^rc=' $LOGF)\" = 0 ] && sgdisk -p $LOOP | cmp -s - /tmp/lay.t0"
done_

echo "=== mke2fs defaults without a config file (initramfs) vs mkfs.ext4 -L DATA (stage3)"
truncate -s 3G $W/f1.img; truncate -s 3G $W/f2.img
mke2fs -t ext4 -F -q -L DATA $W/f1.img; MKE2FS_CONFIG=/nonexistent mke2fs -t ext4 -F -q -L DATA $W/f2.img
f1=$(dumpe2fs -h $W/f1.img 2>/dev/null | grep -E '^(Filesystem features|Inode size|Block size|Journal size|Default mount)' ); f2=$(dumpe2fs -h $W/f2.img 2>/dev/null | grep -E '^(Filesystem features|Inode size|Block size|Journal size|Default mount)')
echo "    stage3 : $(echo "$f1" | tr '\n' '|')"; echo "    no conf: $(echo "$f2" | tr '\n' '|')"
chk "mke2fs without mke2fs.conf yields the same features, inode size, journal as stage3's mkfs.ext4" [ "$f1" = "$f2" ]
rm -f $W/f1.img $W/f2.img

if [ "$BIG" = 1 ]; then
    echo "=== timing: flash image on a 400 GB disk (ROOT_B 5 GiB + DATA ~395 GB created at first boot)"
    cp --sparse=always $F $W/big.img; truncate -s 400G $W/big.img
    LOOP=$(losetup --find --show --partscan $W/big.img); mkdir -p /mnt/r; mount -o ro ${LOOP}p2 /mnt/r
    t0=$(date +%s.%N); runlay; t1=$(date +%s.%N)
    echo "TIME layout_complete on 400 GB (sgdisk, wipes, table, partx, mke2fs ROOT_B 5G + DATA 395G): $(awk "BEGIN{print $t1-$t0}") s; allocated $(du -sh $W/big.img | cut -f1)"
    e2fsck -fn ${LOOP}p4 >/dev/null 2>&1 && echo "     DATA e2fsck clean"; umount /mnt/r; losetup -d $LOOP; rm -f $W/big.img
fi

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
