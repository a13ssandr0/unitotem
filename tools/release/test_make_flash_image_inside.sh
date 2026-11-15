#!/bin/bash
# Runs INSIDE the privileged container of test_make_flash_image.sh. Only /dev/loop* devices are touched.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gdisk fdisk e2fsprogs dosfstools util-linux coreutils dash >/dev/null 2>&1 \
    || { echo "apt failed"; exit 1; }
W=/work; SRC=/repo/unitotem/files/overlayfs-hook.sh; MFI=/repo/unitotem/make-flash-image.sh
LOGF=/tmp/mfi.log; SHIMDIR=/tmp/mfishim
export LOOP=
pass=0; failn=0
cleanup() {
    umount /mnt/r 2>/dev/null
    for f in arm64-full.img arm64-flash.img amd64-full.img amd64-flash.img disk.img; do
        for l in $(losetup -j $W/$f -O NAME -n 2>/dev/null); do losetup -d "$l" 2>/dev/null; done
    done
}
trap cleanup EXIT; trap 'exit 1' TERM INT
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# devtmpfs, so partitions attached by losetup --partscan get their nodes
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }

# `blkid -L LABEL` sees every loop device of the host: the shim restricts it to the partitions of $LOOP.
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/blkid" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = -L ] && [ -n "${LOOP:-}" ]; then
    for d in ${LOOP}p*; do [ "$(/usr/sbin/blkid -s LABEL -o value "$d" 2>/dev/null)" = "$2" ] && { echo "$d"; exit 0; }; done
    exit 2
fi
exec /usr/sbin/blkid "$@"
SHIM
chmod +x "$SHIMDIR/blkid"

# layout_complete under dash, as overlayfs-hook.sh runs it.
runlay() {
    : > "$LOGF"
    PATH=$SHIMDIR:$PATH GLOGF="$LOGF" GSRC="$SRC" dash -c '
        log_warning_msg() { echo "W: $*" >> "$GLOGF"; }; log_success_msg() { echo "I: $*" >> "$GLOGF"; }
        UNITOTEM_SOURCE_ONLY=1; . "$GSRC"; layout_complete; echo "rc=$?" >> "$GLOGF"'
}

# ---- helpers (sectors are 512 bytes)
GUID=9f3a1c2e-5b6d-4e7f-8a9b-0c1d2e3f4a5b
# gpt_sec IMG NAME start|size: from the GPT dump (partition names)
gpt_sec() { sfdisk -d "$1" 2>/dev/null | sed -n "s/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name=\"$2\".*/\1 \2/p" | awk -v f="$3" '{print (f=="start")?$1:$2}'; }
# hash_sec IMG START COUNT
hash_sec() { dd if="$1" bs=512 skip="$2" count="$3" status=none | sha256sum | cut -c1-64; }
ndisk()   { sfdisk -d "$1" 2>/dev/null | grep -c ' : start='; }
dline()   { sfdisk -d "$1" 2>/dev/null | grep ' : start=' | sed -n "$2p"; }    # DOS: partition N's dump line
dline_start() { sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"$1"; }
dline_size()  { sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"$1"; }
dline_type()  { sed -nE 's/.*type= *([0-9a-fA-F]+).*/\1/p' <<<"$1"; }
dos_id()  { sfdisk -d "$1" 2>/dev/null | sed -n 's/^label-id: //p'; }
pttype()  { blkid -p -s PTTYPE -o value "$1" 2>/dev/null; }

# fresh_full IMG SIZE SGDISK_LINES SPECS: GPT disk (one sgdisk argument set per line), then a filesystem per partition
# (SPECS: "N:LABEL:vfat|ext4" words). ROOT_A carries a random payload (the byte-compare target).
fresh_full() {
    local f=$1 size=$2 script=$3 specs=$4 spec n lbl fs
    rm -f -- "$f"; truncate -s "$size" "$f"
    sgdisk -Z -U "$GUID" "$f" >/dev/null
    while IFS= read -r line; do
        [ -n "$line" ] && { sgdisk $line "$f" >/dev/null || { echo "fixture: sgdisk $line failed"; exit 1; }; }
    done <<<"$(printf '%b' "$script")"
    LOOP=$(losetup --find --show --partscan "$f")
    for spec in $specs; do
        IFS=: read -r n lbl fs <<<"$spec"
        case "$fs" in
            vfat) mkfs.fat -F32 -n "$lbl" "${LOOP}p$n" >/dev/null ;;
            ext4) mkfs.ext4 -q -F -L "$lbl" "${LOOP}p$n"
                  if [ "$lbl" = ROOT_A ]; then
                      mkdir -p /mnt/r; mount "${LOOP}p$n" /mnt/r
                      head -c 5000000 /dev/urandom > /mnt/r/payload; sync; umount /mnt/r
                  fi ;;
        esac
    done
    losetup -d "$LOOP"; LOOP=
}

echo "=== synthetic full images (GPT, names as stage3)"
fresh_full $W/arm64-full.img 2G \
    '-n 1:2048:+64M -t 1:ef00 -c 1:FIRMWARE\n-n 2:0:+256M -t 2:8300 -c 2:ROOT_A\n-n 3:0:+256M -t 3:8300 -c 3:ROOT_B\n-n 4:0:0 -t 4:8300 -c 4:DATA' \
    '1:FIRMWARE:vfat 2:ROOT_A:ext4 3:ROOT_B:ext4 4:DATA:ext4'
fresh_full $W/amd64-full.img 2G \
    '-n 1:2048:+64M -t 1:ef00 -c 1:EFI\n-n 2:0:+256M -t 2:8300 -c 2:ROOT_A\n-n 3:0:+256M -t 3:8300 -c 3:ROOT_B\n-n 4:0:0 -t 4:8300 -c 4:DATA\n-n 5:34:2047 -t 5:ef02 -c 5:BIOS' \
    '1:EFI:vfat 2:ROOT_A:ext4 3:ROOT_B:ext4 4:DATA:ext4'
FULLA=$W/arm64-full.img; FULLG=$W/amd64-full.img
FLA=$W/arm64-flash.img; FLG=$W/amd64-flash.img
FA_START=$(gpt_sec "$FULLA" ROOT_A start); FA_SIZE=$(gpt_sec "$FULLA" ROOT_A size)
FW_START=$(gpt_sec "$FULLA" FIRMWARE start); FW_SIZE=$(gpt_sec "$FULLA" FIRMWARE size)

# ---- arm64 checks
t_a_dos()      { [ "$(pttype "$FLA")" = dos ]; }
t_a_id()       { [ "$(dos_id "$FLA")" = 0x9f3a1c2e ]; }
t_a_count()    { [ "$(ndisk "$FLA")" = 2 ]; }
t_a_p1()       { local l; l=$(dline "$FLA" 1); [ "$(dline_start "$l")" = "$FW_START" ] && [ "$(dline_size "$l")" = "$FW_SIZE" ] \
                 && [ "$(dline_type "$l")" = c ] && grep -q 'bootable' <<<"$l"; }
t_a_p2()       { local l; l=$(dline "$FLA" 2); [ "$(dline_start "$l")" = "$FA_START" ] && [ "$(dline_size "$l")" = "$FA_SIZE" ] \
                 && [ "$(dline_type "$l")" = 83 ]; }
t_a_verify()   { sfdisk -V "$FLA" >/dev/null 2>&1; }
t_a_fw_bytes() { [ "$(hash_sec "$FULLA" "$FW_START" "$FW_SIZE")" = "$(hash_sec "$FLA" "$FW_START" "$FW_SIZE")" ]; }
t_a_ro_bytes() { [ "$(hash_sec "$FULLA" "$FA_START" "$FA_SIZE")" = "$(hash_sec "$FLA" "$FA_START" "$FA_SIZE")" ]; }
t_a_fsck()     { local lo r; lo=$(losetup --find --show --read-only --partscan "$FLA") || return 1
                 e2fsck -fn "${lo}p2" >/dev/null 2>&1; r=$?; losetup -d "$lo"; [ "$r" = 0 ]; }
t_a_size()     { [ "$(stat -c %s "$FLA")" = $(( (FA_START + FA_SIZE) * 512 + 1048576 )) ]; }

echo "=== (1) arm64: make-flash-image writes a DOS flash image"
bash "$MFI" "$FULLA" "$FLA" > "$W/arm64-mfi.out" 2>&1; rc1=$?
sed 's/^/    mfi: /' "$W/arm64-mfi.out"
chk "(1) make-flash-image exits 0" [ "$rc1" = 0 ]
chk "(1) PTTYPE dos" t_a_dos
chk "(1) label-id 0x9f3a1c2e (first 8 hex digits of the disk GUID)" t_a_id
chk "(1) two partitions" t_a_count
chk "(1) p1 FIRMWARE: start 2048 (as full), type c, bootable" t_a_p1
chk "(1) p2 ROOT_A: start and size as full, type 83" t_a_p2
chk "(1) sfdisk -V clean" t_a_verify
chk "(1) FIRMWARE bytes identical to the full image" t_a_fw_bytes
chk "(1) ROOT_A bytes identical to the full image" t_a_ro_bytes
chk "(1) ROOT_A filesystem clean (e2fsck -fn)" t_a_fsck
chk "(1) file size = end of ROOT_A + 1 MiB" t_a_size

# ---- (1b) layout_mbr completes the flash image on a 6 GiB disk
t_b_log()     { [ "$(grep -c '^I: layout: created' "$LOGF")" = 1 ] && grep -q '^rc=0' "$LOGF"; }
t_b_four()    { [ "$(ndisk "$LOOP")" = 4 ] && ! sfdisk -d "$LOOP" | grep -Eq 'type=(5|f|85)(,|$)'; }
t_b_names()   { [ "$(blkid -p -s LABEL -o value ${LOOP}p3)" = ROOT_B ] && [ "$(blkid -p -s LABEL -o value ${LOOP}p4)" = DATA ] \
                && [ "$(blkid -p -s TYPE -o value ${LOOP}p3)" = ext4 ] && [ "$(blkid -p -s TYPE -o value ${LOOP}p4)" = ext4 ]; }
t_b_types()   { [ "$(dline_type "$(dline "$LOOP" 3)")" = 83 ] && [ "$(dline_type "$(dline "$LOOP" 4)")" = 83 ] \
                && [ "$(dline_type "$(dline "$LOOP" 1)")" = c ] && [ "$(dline_type "$(dline "$LOOP" 2)")" = 83 ]; }
t_b_nopend()  { ! sfdisk -d "$LOOP" | grep -Eq 'type=(da|db)(,|$)'; }
t_b_bytes()   { [ "$(hash_sec "$LOOP" "$FW_START" "$FW_SIZE")" = "$(hash_sec "$FLA" "$FW_START" "$FW_SIZE")" ] \
                && [ "$(hash_sec "$LOOP" "$FA_START" "$FA_SIZE")" = "$(hash_sec "$FLA" "$FA_START" "$FA_SIZE")" ]; }
t_b_id()      { [ "$(dos_id "$LOOP")" = 0x9f3a1c2e ]; }
t_b_verify()  { sfdisk -V "$LOOP" >/dev/null 2>&1; }
t_b_fsck()    { e2fsck -fn ${LOOP}p3 >/dev/null 2>&1 && e2fsck -fn ${LOOP}p4 >/dev/null 2>&1; }
t_b_noop()    { [ "$(grep -c '^I:' "$LOGF")" = 0 ] && grep -q '^rc=0' "$LOGF"; }

echo "=== (1b) arm64: layout_mbr completes the flash image to four primaries"
cp --sparse=always "$FLA" $W/disk.img; truncate -s 6G $W/disk.img
LOOP=$(losetup --find --show --partscan $W/disk.img)
runlay; sed 's/^/    layout log: /' "$LOGF"
chk "(1b) layout log: one 'created' line, rc=0" t_b_log
chk "(1b) four partitions, all primaries (no extended)" t_b_four
chk "(1b) p3 ROOT_B and p4 DATA: labels, ext4" t_b_names
chk "(1b) types: p1 c, p2 83, p3 83, p4 83" t_b_types
chk "(1b) no pending type (da/db) left" t_b_nopend
chk "(1b) FIRMWARE and ROOT_A bytes identical to the flash image" t_b_bytes
chk "(1b) label-id unchanged" t_b_id
chk "(1b) sfdisk -V clean" t_b_verify
chk "(1b) e2fsck -fn ROOT_B and DATA clean" t_b_fsck
runlay; chk "(1b) second run: no log line, rc=0" t_b_noop
losetup -d "$LOOP"; LOOP=; rm -f -- $W/disk.img

# ---- amd64 checks
t_g_gpt()     { [ "$(pttype "$FLG")" = gpt ]; }
t_g_guid()    { [ "$(sgdisk -p "$FLG" | sed -n 's/^Disk identifier (GUID): //p')" = "$(sgdisk -p "$FULLG" | sed -n 's/^Disk identifier (GUID): //p')" ]; }
t_g_parts()   { sgdisk -p "$FLG" | grep -Eq '^ +1 .* [Ee][Ff]00 +EFI$' && sgdisk -p "$FLG" | grep -Eq '^ +2 .* 8300 +ROOT_A$' \
                && sgdisk -p "$FLG" | grep -Eq '^ +5 .* [Ee][Ff]02 +BIOS$' && [ "$(sgdisk -p "$FLG" | grep -cE '^ +[0-9]+ ')" = 3 ]; }
t_g_sgv()     { sgdisk -v "$FLG" 2>&1 | grep -q 'No problems found'; }
t_g_sfv()     { sfdisk -V "$FLG" >/dev/null 2>&1; }
t_g_bytes()   { local nm s n c; for nm in BIOS EFI ROOT_A; do
                    s=$(gpt_sec "$FULLG" $nm start); c=$(gpt_sec "$FULLG" $nm size)
                    [ "$(hash_sec "$FULLG" "$s" "$c")" = "$(hash_sec "$FLG" "$s" "$c")" ] || return 1
                done; }
t_h_log()     { grep -q '^I: layout: created' "$LOGF" && grep -q '^rc=0' "$LOGF"; }
t_h_names()   { sgdisk -p "$LOOP" | grep -Eq ' ROOT_B$' && sgdisk -p "$LOOP" | grep -Eq ' DATA$' && sgdisk -v "$LOOP" 2>&1 | grep -q 'No problems found'; }

echo "=== (2) amd64: make-flash-image keeps the GPT output"
bash "$MFI" "$FULLG" "$FLG" > "$W/amd64-mfi.out" 2>&1; rc2=$?
sed 's/^/    mfi: /' "$W/amd64-mfi.out"
chk "(2) make-flash-image exits 0" [ "$rc2" = 0 ]
chk "(2) PTTYPE gpt" t_g_gpt
chk "(2) disk GUID unchanged" t_g_guid
chk "(2) partitions 1 EFI ef00, 2 ROOT_A 8300, 5 BIOS ef02; no others" t_g_parts
chk "(2) sgdisk -v clean" t_g_sgv
chk "(2) sfdisk -V clean" t_g_sfv
chk "(2) BIOS, EFI and ROOT_A bytes identical to the full image" t_g_bytes

echo "=== (2b) amd64: layout_complete on the GPT flash image (GPT path)"
cp --sparse=always "$FLG" $W/disk.img; truncate -s 6G $W/disk.img
LOOP=$(losetup --find --show --partscan $W/disk.img)
runlay; sed 's/^/    layout log: /' "$LOGF"
chk "(2b) ROOT_B and DATA created as GPT entries, rc=0" t_h_log
chk "(2b) names ROOT_B and DATA, GPT valid" t_h_names
losetup -d "$LOOP"; LOOP=; rm -f -- $W/disk.img

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
