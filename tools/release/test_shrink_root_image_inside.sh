#!/bin/bash
# Runs INSIDE the privileged container of test_shrink_root_image.sh. Only /dev/loop* devices are touched.
# The arm64 table is written by the dos_table function of unitotem/stage3-image.sh (extracted, not copied).
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gdisk fdisk e2fsprogs dosfstools util-linux coreutils dash >/dev/null 2>&1 \
    || { echo "apt failed"; exit 1; }
W=/work; SHRINK=/repo/unitotem/shrink-root-image.sh; STAGE3=/repo/unitotem/stage3-image.sh; SRC=/repo/unitotem/files/overlayfs-hook.sh
LOGF=/tmp/srk.log; SHIMDIR=/tmp/srkshim
export LOOP=
FW_MIB=64; SLOT_MIB=5120; SLOT=10485760      # FIRMWARE 64 MiB, ROOT_A slot 5 GiB (sectors: SLOT)
DISK_SIZE=14G                                # sparse disk for the first-boot layout completion
DOS_IMG=$W/dos.img; GPT_IMG=$W/gpt.img; DISK=$W/disk.img; DOS3=$W/dos3.img
pass=0; failn=0
cleanup() {
    umount /mnt/r 2>/dev/null
    losetup -a 2>/dev/null | grep "$W/" | cut -d: -f1 | while read -r d; do losetup -d "$d" 2>/dev/null; done
}
trap cleanup EXIT; trap 'exit 1' TERM INT
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# devtmpfs, so partitions attached by losetup --partscan get their nodes
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }

# the arm64 table writer of stage3, as it is (the function only)
sed -n '/^dos_table()/,/^}/p' "$STAGE3" > "$W/dos_table.fn"
[ -s "$W/dos_table.fn" ] || { echo "dos_table not found in $STAGE3"; exit 1; }
. "$W/dos_table.fn"

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
dl()       { sfdisk -d "$1" 2>/dev/null | grep ' : start='; }          # one dump line per partition, in order
dline()    { dl "$1" | sed -n "$2p"; }                                  # partition N's dump line (N from 1)
dstart()   { sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"$1"; }
dsize()    { sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"$1"; }
dtype()    { sed -nE 's/.*type= *([0-9a-fA-F]+).*/\1/p' <<<"$1"; }
dlabel()   { sfdisk -d "$1" 2>/dev/null | sed -n 's/^label: //p'; }
dlabelid() { sfdisk -d "$1" 2>/dev/null | sed -n 's/^label-id: //p'; }
# at_part IMG START COUNT CMD...: CMD runs with the partition (sectors START..START+COUNT-1) attached read-only as its last argument
at_part() {
    local img=$1 s=$2 c=$3 lo rc; shift 3
    lo=$(losetup --find --show --read-only --offset $((s * 512)) --sizelimit $((c * 512)) "$img") || return 1
    "$@" "$lo"; rc=$?
    losetup -d "$lo"
    return $rc
}
fsbytes()  { local d; d=$(dumpe2fs -h "$1" 2>/dev/null); echo $(( $(sed -n 's/^Block count: *//p' <<<"$d") * $(sed -n 's/^Block size: *//p' <<<"$d") )); }
# tree_sum DEV: digest of the read-only mounted file tree (types, paths, sizes, file contents)
tree_sum() {
    mkdir -p /mnt/r
    mount -o ro "$1" /mnt/r 2>/dev/null || { echo "mount-failed"; return 0; }
    (cd /mnt/r && find . -xdev -printf '%y %p %s\n' | sort && find . -xdev -type f -print0 | sort -z | xargs -0 sha256sum) \
        | sha256sum | cut -c1-64
    umount /mnt/r
}
# GPT entry fields of IMG PART: first and last sector, name, type GUID
gfirst() { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
glast()  { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^Last sector: \([0-9]*\).*/\1/p'; }
gname()  { sgdisk -i "$2" "$1" 2>/dev/null | sed -n "s/^Partition name: '\(.*\)'$/\1/p"; }
gcode()  { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p'; }
filesize() { stat -c %s "$1"; }
hash_file() { sha256sum "$1" | cut -c1-64; }

# populate DEV: a filesystem with a random payload and a small tree (the byte-compare target)
populate() {
    mkdir -p /mnt/r
    mount "$1" /mnt/r
    mkdir -p /mnt/r/usr/share/unitotem /mnt/r/etc/unitotem
    head -c 5000000 /dev/urandom > /mnt/r/usr/share/unitotem/payload
    echo "release" > /mnt/r/usr/share/unitotem/release-version
    sync; umount /mnt/r
}
# make_dos_img IMG: the stage3 arm64 A/B table (FIRMWARE p1, ROOT_A p2 at the slot size), filesystems, payload
make_dos_img() {
    : > "$1"; truncate -s $(( (1 + FW_MIB + SLOT_MIB + 1) * 1048576 )) "$1"
    dos_table "$1" "$FW_MIB" "$SLOT_MIB" || { echo "fixture: dos_table failed"; exit 1; }
    LOOP=$(losetup --find --show --partscan "$1")
    mkfs.fat -F32 -n FIRMWARE "${LOOP}p1" >/dev/null
    mkfs.ext4 -q -F -L ROOT_A "${LOOP}p2"
    populate "${LOOP}p2"
    losetup -d "$LOOP"; LOOP=
}
# make_gpt_img IMG: the amd64 A/B layout as stage3 writes it (EFI p1, ROOT_A p2, BIOS p5 in the gap)
make_gpt_img() {
    : > "$1"; truncate -s $(( (1 + FW_MIB + SLOT_MIB + 1) * 1048576 )) "$1"
    sgdisk -Z "$1" >/dev/null
    sgdisk -n "1:0:+${FW_MIB}M"       -t 1:ef00 -c 1:EFI     "$1" >/dev/null
    sgdisk -n "2:0:+${SLOT_MIB}M"     -t 2:8300 -c 2:ROOT_A  "$1" >/dev/null
    sgdisk -n "5:34:2047"             -t 5:ef02 -c 5:BIOS    "$1" >/dev/null
    LOOP=$(losetup --find --show --partscan "$1")
    mkfs.fat -F32 -n EFI "${LOOP}p1" >/dev/null
    mkfs.ext4 -q -F -L ROOT_A "${LOOP}p2"
    populate "${LOOP}p2"
    losetup -d "$LOOP"; LOOP=
}

echo "=== fixtures"
make_dos_img "$DOS_IMG"
make_gpt_img "$GPT_IMG"
: > "$DOS3"; truncate -s 2G "$DOS3"; dos_table "$DOS3" 64 1024 data

# ---- DOS (arm64): the table written by stage3
t_d_label()   { [ "$(dlabel "$DOS_IMG")" = dos ]; }
t_d_p1()      { local l; l=$(dline "$DOS_IMG" 1); [ "$(dstart "$l")" = 2048 ] && [ "$(dsize "$l")" = $((FW_MIB * 2048)) ] \
                && [ "$(dtype "$l")" = c ] && grep -q 'bootable' <<<"$l"; }
t_d_p2()      { local l; l=$(dline "$DOS_IMG" 2); [ "$(dstart "$l")" = $(( (1 + FW_MIB) * 2048 )) ] \
                && [ "$(dsize "$l")" = $((SLOT_MIB * 2048)) ] && [ "$(dtype "$l")" = 83 ]; }
t_d_names()   { at_part "$DOS_IMG" 2048 $((FW_MIB * 2048)) blkid -p -s LABEL -o value | grep -qx FIRMWARE \
                && at_part "$DOS_IMG" $(( (1 + FW_MIB) * 2048 )) $((SLOT_MIB * 2048)) blkid -p -s LABEL -o value | grep -qx ROOT_A; }
t_d_verify()  { sfdisk -V "$DOS_IMG" >/dev/null 2>&1; }
t_d_size()    { [ "$(filesize "$DOS_IMG")" = $(( (1 + FW_MIB + SLOT_MIB + 1) * 1048576 )) ]; }
t_d3_count()  { [ "$(dl "$DOS3" | wc -l)" = 3 ] && ! sfdisk -d "$DOS3" | grep -Eq 'type=(5|f|85)(,|$)'; }
t_d3_p3()     { local l total; l=$(dline "$DOS3" 3); total=$(( $(filesize "$DOS3") / 512 ))
                [ "$(dtype "$l")" = 83 ] && [ $(( $(dstart "$l") + $(dsize "$l") - 1 )) = $((total - 1)) ]; }
echo "=== DOS table as stage3 writes it"
chk "(a) table: label dos" t_d_label
chk "(a) p1 FIRMWARE: start 2048, 64 MiB, type c, bootable" t_d_p1
chk "(a) p2 ROOT_A: after p1, slot size, type 83" t_d_p2
chk "(a) filesystem labels FIRMWARE and ROOT_A (no partition names exist)" t_d_names
chk "(a) sfdisk -V clean" t_d_verify
chk "(a) file size = end of ROOT_A + 1 MiB" t_d_size
chk "(a) DOS with DATA: three primaries, no extended" t_d3_count
chk "(a) DOS with DATA: p3 type 83 to the last sector" t_d3_p3

# ---- GPT (amd64): the table as stage3 writes it, before the shrink
t_g_gpt()     { [ "$(dlabel "$GPT_IMG")" = gpt ]; }
t_g_parts()   { [ "$(gname "$GPT_IMG" 2)" = ROOT_A ] && [ "$(gname "$GPT_IMG" 5)" = BIOS ] && [ "$(gcode "$GPT_IMG" 5)" = 21686148-6449-6E6F-744E-656564454649 ]; }
t_g_verify()  { sgdisk -v "$GPT_IMG" 2>&1 | grep -q 'No problems found'; }
echo "=== GPT table as stage3 writes it"
chk "(b) table: label gpt, ROOT_A and BIOS names" t_g_gpt
chk "(b) ROOT_A named ROOT_A, BIOS ef02 present" t_g_parts
chk "(b) sgdisk -v clean" t_g_verify

# ---- shrink, DOS: run 1
echo "=== shrink DOS (arm64)"
D_START=$(( (1 + FW_MIB) * 2048 ))
REF_D=$(at_part "$DOS_IMG" "$D_START" "$((SLOT_MIB * 2048))" tree_sum)
ID_D=$(dlabelid "$DOS_IMG")
bash "$SHRINK" "$DOS_IMG" > "$W/dos-shrink1.out" 2>&1; rc=$?
sed 's/^/    shrink: /' "$W/dos-shrink1.out"
t_sd_rc()     { [ "$rc" = 0 ]; }
t_sd_label()  { [ "$(dlabelid "$DOS_IMG")" = "$ID_D" ] && [ "$(dlabel "$DOS_IMG")" = dos ] && sfdisk -V "$DOS_IMG" >/dev/null 2>&1; }
t_sd_p1()     { local l; l=$(dline "$DOS_IMG" 1); [ "$(dstart "$l")" = 2048 ] && [ "$(dsize "$l")" = $((FW_MIB * 2048)) ] \
                && [ "$(dtype "$l")" = c ] && grep -q 'bootable' <<<"$l"; }
t_sd_p2()     { local l sz; l=$(dline "$DOS_IMG" 2); sz=$(dsize "$l")
                [ "$(dstart "$l")" = "$D_START" ] && [ "$(dtype "$l")" = 83 ] && [ "$sz" -lt $((SLOT_MIB * 2048)) ] \
                && [ $(( sz % 2048 )) = 0 ]; }
t_sd_file()   { local l; l=$(dline "$DOS_IMG" 2); [ "$(filesize "$DOS_IMG")" = $(( ($(dstart "$l") + $(dsize "$l")) * 512 + 1048576 )) ]; }
t_sd_label2() { at_part "$DOS_IMG" "$D_START" "$(dsize "$(dline "$DOS_IMG" 2)")" blkid -p -s LABEL -o value | grep -qx ROOT_A; }
t_sd_fsck()   { at_part "$DOS_IMG" "$D_START" "$(dsize "$(dline "$DOS_IMG" 2)")" e2fsck -fn >/dev/null 2>&1; }
t_sd_fits()   { local l fb; l=$(dline "$DOS_IMG" 2); fb=$(at_part "$DOS_IMG" "$D_START" "$(dsize "$l")" fsbytes); \
                [ -n "$fb" ] && [ "$fb" -le $(( $(dsize "$l") * 512 )) ]; }
t_sd_tree()   { local l; l=$(dline "$DOS_IMG" 2); [ "$(at_part "$DOS_IMG" "$D_START" "$(dsize "$l")" tree_sum)" = "$REF_D" ]; }
chk "(a) shrink exits 0" t_sd_rc
chk "(a) table still dos, label-id unchanged, sfdisk -V clean" t_sd_label
chk "(a) p1 FIRMWARE unchanged: start 2048, 64 MiB, type c, bootable" t_sd_p1
chk "(a) p2 ROOT_A: same start, type 83, smaller than the slot, MiB aligned" t_sd_p2
chk "(a) file ends 1 MiB after p2" t_sd_file
chk "(a) p2 still labelled ROOT_A" t_sd_label2
chk "(a) ROOT_A filesystem clean (e2fsck -fn)" t_sd_fsck
chk "(a) ROOT_A filesystem fits its partition" t_sd_fits
chk "(a) ROOT_A file tree unchanged" t_sd_tree

# idem_ok OLD NEW START COUNT: the table sectors (first and last MiB), the file size and the ROOT_A block count are
# unchanged; sb_only OLD NEW START: every byte that differs lies in the ROOT_A primary superblock (1024..2047)
idem_ok() {
    cmp -s -n 1048576 "$1" "$2" && cmp -s <(tail -c 1048576 "$1") <(tail -c 1048576 "$2") \
        && [ "$(filesize "$1")" = "$(filesize "$2")" ] \
        && [ "$(at_part "$1" "$3" "$4" fsbytes)" = "$(at_part "$2" "$3" "$4" fsbytes)" ]
}
sb_only() {
    local lo=$(( $3 * 512 + 1024 )) hi=$(( $3 * 512 + 2048 ))
    echo "    bytes differing between runs: $(cmp -l "$1" "$2" | wc -l)"
    { cmp -l "$1" "$2" || true; } | awk -v lo="$lo" -v hi="$hi" '{o=$1-1; if (o<lo || o>=hi) bad++} END{exit (bad+0 == 0) ? 0 : 1}'
}

# ---- shrink, DOS: run 2 changes nothing
echo "=== shrink DOS: second run"
cp --sparse=always "$DOS_IMG" "$W/dos-before.img"
bash "$SHRINK" "$DOS_IMG" > "$W/dos-shrink2.out" 2>&1; rc2=$?
sed 's/^/    shrink: /' "$W/dos-shrink2.out"
D_COUNT=$(dsize "$(dline "$DOS_IMG" 2)")
chk "(a) second run exits 0" [ "$rc2" = 0 ]
chk "(a) second run: table, file size and block count unchanged" idem_ok "$W/dos-before.img" "$DOS_IMG" "$D_START" "$D_COUNT"
chk "(a) second run: only ROOT_A superblock bytes differ (e2fsck check time)" sb_only "$W/dos-before.img" "$DOS_IMG" "$D_START"

# ---- shrink, GPT: run 1 and run 2
echo "=== shrink GPT (amd64)"
G_START=$(gfirst "$GPT_IMG" 2)
REF_G=$(at_part "$GPT_IMG" "$G_START" "$((SLOT_MIB * 2048))" tree_sum)
bash "$SHRINK" "$GPT_IMG" > "$W/gpt-shrink1.out" 2>&1; rc=$?
sed 's/^/    shrink: /' "$W/gpt-shrink1.out"
G_END=$(glast "$GPT_IMG" 2)
t_sg_rc()    { [ "$rc" = 0 ]; }
t_sg_verify(){ sgdisk -v "$GPT_IMG" 2>&1 | grep -q 'No problems found'; }
t_sg_p2()    { [ "$(gname "$GPT_IMG" 2)" = ROOT_A ] && [ "$(gfirst "$GPT_IMG" 2)" = "$G_START" ] \
               && [ "$(glast "$GPT_IMG" 2)" -lt $(( G_START + SLOT_MIB * 2048 - 1 )) ]; }
t_sg_keep()  { [ "$(gname "$GPT_IMG" 1)" = EFI ] && [ "$(gcode "$GPT_IMG" 5)" = 21686148-6449-6E6F-744E-656564454649 ]; }
t_sg_fsck()  { at_part "$GPT_IMG" "$G_START" "$((G_END - G_START + 1))" e2fsck -fn >/dev/null 2>&1; }
t_sg_fits()  { local fb; fb=$(at_part "$GPT_IMG" "$G_START" "$((G_END - G_START + 1))" fsbytes); \
               [ -n "$fb" ] && [ "$fb" -le $(( (G_END - G_START + 1) * 512 )) ]; }
t_sg_tree()  { [ "$(at_part "$GPT_IMG" "$G_START" "$((G_END - G_START + 1))" tree_sum)" = "$REF_G" ]; }
echo "=== shrink GPT: run 1"
chk "(b) shrink exits 0" t_sg_rc
chk "(b) sgdisk -v clean, backup GPT at the new end" t_sg_verify
chk "(b) partition 2 still ROOT_A, same start, smaller" t_sg_p2
chk "(b) EFI and BIOS entries unchanged" t_sg_keep
chk "(b) ROOT_A filesystem clean (e2fsck -fn)" t_sg_fsck
chk "(b) ROOT_A filesystem fits its partition" t_sg_fits
chk "(b) ROOT_A file tree unchanged" t_sg_tree
echo "=== shrink GPT: second run"
cp --sparse=always "$GPT_IMG" "$W/gpt-before.img"
bash "$SHRINK" "$GPT_IMG" > "$W/gpt-shrink2.out" 2>&1; rc2=$?
sed 's/^/    shrink: /' "$W/gpt-shrink2.out"
G_START=$(gfirst "$GPT_IMG" 2); G_END=$(glast "$GPT_IMG" 2)
chk "(b) second run exits 0" [ "$rc2" = 0 ]
chk "(b) second run: table, file size and block count unchanged" idem_ok "$W/gpt-before.img" "$GPT_IMG" "$G_START" $((G_END - G_START + 1))
chk "(b) second run: only ROOT_A superblock bytes differ (e2fsck check time)" sb_only "$W/gpt-before.img" "$GPT_IMG" "$G_START"

# ---- first boot on the shrunk DOS image: layout_complete on a 14G disk
echo "=== layout_complete on the shrunk DOS image (14G disk)"
: > "$DISK"; cp --sparse=always "$DOS_IMG" "$DISK"; truncate -s "$DISK_SIZE" "$DISK"
LOOP=$(losetup --find --show --partscan "$DISK")
runlay; sed 's/^/    layout log: /' "$LOGF"
DSZ=$(blockdev --getsz "$LOOP")
t_b_log()    { [ "$(grep -c '^I: layout: created' "$LOGF")" = 1 ] && grep -q '^rc=0' "$LOGF"; }
t_b_nowarn() { ! grep -q '^W:' "$LOGF"; }
t_b_four()   { [ "$(dl "$LOOP" | wc -l)" = 4 ] && ! sfdisk -d "$LOOP" | grep -Eq 'type=(5|f|85)(,|$)'; }
t_b_types()  { [ "$(dtype "$(dline "$LOOP" 1)")" = c ] && [ "$(dtype "$(dline "$LOOP" 2)")" = 83 ] \
               && [ "$(dtype "$(dline "$LOOP" 3)")" = 83 ] && [ "$(dtype "$(dline "$LOOP" 4)")" = 83 ] \
               && ! sfdisk -d "$LOOP" | grep -Eq 'type=(da|db)(,|$)'; }
t_b_names()  { [ -z "$(blkid -p -s LABEL -o value ${LOOP}p3)" ] && [ -z "$(blkid -p -s TYPE -o value ${LOOP}p3)" ] \
               && [ "$(blkid -p -s LABEL -o value ${LOOP}p4)" = DATA ] && [ "$(blkid -p -s TYPE -o value ${LOOP}p4)" = ext4 ]; }
t_c_slot()   { [ "$(dsize "$(dline "$LOOP" 2)")" = "$SLOT" ] && [ "$(dstart "$(dline "$LOOP" 2)")" = "$D_START" ]; }
t_c_rootb()  { local bs=$(( (D_START + SLOT + 2047) / 2048 * 2048 ))
               [ "$(dstart "$(dline "$LOOP" 3)")" = "$bs" ] && [ "$(dsize "$(dline "$LOOP" 3)")" = "$SLOT" ] \
               && [ -z "$(blkid -p -s LABEL -o value ${LOOP}p3)" ] && [ -z "$(blkid -p -s TYPE -o value ${LOOP}p3)" ]; }
t_c_data()   { local ds=$(( (D_START + SLOT + 2047) / 2048 * 2048 + SLOT )) l
               l=$(dline "$LOOP" 4)
               [ "$(dstart "$l")" = "$ds" ] && [ $(( $(dstart "$l") + $(dsize "$l") - 1 )) = $((DSZ - 1)) ]; }
t_c_fsbytes(){ [ "$(fsbytes "${LOOP}p2")" = "$(blockdev --getsize64 "${LOOP}p2")" ] && [ "$(blockdev --getsize64 "${LOOP}p2")" = $(( SLOT * 512 )) ]; }
t_c_tree()   { [ "$(tree_sum "${LOOP}p2")" = "$REF_D" ]; }
t_c_fsck()   { e2fsck -fn "${LOOP}p2" >/dev/null 2>&1; }
t_c_dfsck()  { e2fsck -fn "${LOOP}p4" >/dev/null 2>&1; }
t_c_id()     { [ "$(dlabelid "$LOOP")" = "$ID_D" ]; }
t_c_verify() { sfdisk -V "$LOOP" >/dev/null 2>&1; }
t_c_noop()   { [ "$(grep -c '^I:' "$LOGF")" = 0 ] && grep -q '^rc=0' "$LOGF"; }
chk "(c) layout log: one 'created' line, rc=0" t_b_log
chk "(c) no warning" t_b_nowarn
chk "(c) four primaries, no extended" t_b_four
chk "(c) p2 ROOT_A grown to the slot, same start" t_c_slot
chk "(c) p3 ROOT_B after ROOT_A, slot size, blank" t_c_rootb
chk "(c) p4 DATA after ROOT_B, to the disk end, ext4 labelled DATA" t_c_data
chk "(c) p3 blank, p4 labelled DATA" t_b_names
chk "(c) types p1 c, p2 83, p3 83, p4 83; no pending type" t_b_types
chk "(c) ROOT_A filesystem = partition" t_c_fsbytes
chk "(c) ROOT_A file tree unchanged" t_c_tree
chk "(c) ROOT_A filesystem clean (e2fsck -fn)" t_c_fsck
chk "(c) DATA filesystem clean" t_c_dfsck
chk "(c) label-id unchanged" t_c_id
chk "(c) sfdisk -V clean" t_c_verify
runlay; chk "(c) second run: no log line, rc=0" t_c_noop
losetup -d "$LOOP"; LOOP=

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
