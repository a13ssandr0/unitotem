#!/bin/bash
# Runs INSIDE the privileged container of test_first_boot_layout_dos.sh. Only /dev/loop* devices are touched.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gdisk fdisk e2fsprogs dosfstools util-linux coreutils dash >/dev/null 2>&1 \
    || { echo "apt failed"; exit 1; }
W=/work; LOGF=/tmp/layout-dos.log; STUBS=/tmp/dosstub; SRC=/repo/unitotem/files/overlayfs-hook.sh
export LOOP=
pass=0; failn=0
cleanup() {
    for m in /mnt/r /mnt/d /mnt/b; do umount "$m" 2>/dev/null; done
    for f in t.img gpt.img; do
        for l in $(losetup -j $W/$f -O NAME -n 2>/dev/null); do losetup -d "$l" 2>/dev/null; done
    done
}
trap cleanup EXIT; trap 'exit 1' TERM INT
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# the kernel's devtmpfs, so partitions added by partx get their nodes like on a real system
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }

# `blkid -L LABEL` sees every loop device of the host: the shim restricts it to the partitions of $LOOP.
mkdir -p /tmp/blkidshim "$STUBS"
cat > /tmp/blkidshim/blkid <<'SHIM'
#!/bin/bash
if [ "${1:-}" = -L ] && [ -n "${LOOP:-}" ]; then
    for d in ${LOOP}p*; do [ "$(/usr/sbin/blkid -s LABEL -o value "$d" 2>/dev/null)" = "$2" ] && { echo "$d"; exit 0; }; done
    exit 2
fi
exec /usr/sbin/blkid "$@"
SHIM
chmod +x /tmp/blkidshim/blkid

# Power-cut stubs: when due, a stub kills the function's own shell ($PPID, the dash running layout_complete) and
# itself before it does anything, so the cut lands exactly at that call and nothing after it runs.
REAL_MKE2FS=$(command -v mke2fs); REAL_SFDISK=$(command -v sfdisk)
cat > "$STUBS/mke2fs" <<EOF
#!/bin/sh
n=\$(cat $STUBS/mk.n 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > $STUBS/mk.n
[ "\$n" = "\${STUB_MKE2FS_KILL:-0}" ] && kill -9 \$PPID \$\$
exec $REAL_MKE2FS "\$@"
EOF
cat > "$STUBS/sfdisk" <<EOF
#!/bin/sh
case " \$* " in
    *" --part-type "*)
        n=\$(cat $STUBS/pt.n 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > $STUBS/pt.n
        [ "\$n" = "\${STUB_PT_KILL:-0}" ] && kill -9 \$PPID \$\$ ;;
    *" --append "*)
        [ "\${STUB_APPEND_KILL:-0}" = 1 ] && kill -9 \$PPID \$\$ ;;
esac
exec $REAL_SFDISK "\$@"
EOF
chmod +x "$STUBS/mke2fs" "$STUBS/sfdisk"

# layout_complete under dash, as overlayfs-hook.sh runs it. EXTRA_PATH: stub directory (optional).
runlay() {
    : > "$LOGF"
    PATH=${EXTRA_PATH:+$EXTRA_PATH:}/tmp/blkidshim:$PATH GLOGF="$LOGF" GSRC="$SRC" dash -c '
        log_warning_msg() { echo "W: $*" >> "$GLOGF"; }; log_success_msg() { echo "I: $*" >> "$GLOGF"; }
        UNITOTEM_SOURCE_ONLY=1; . "$GSRC"; layout_complete; echo "rc=$?" >> "$GLOGF"'
}
stubs_off() { unset STUB_MKE2FS_KILL STUB_PT_KILL STUB_APPEND_KILL; EXTRA_PATH=; rm -f -- "$STUBS/mk.n" "$STUBS/pt.n"; }

lines()   { grep -vc '^rc=' "$LOGF"; }
part_hash() { dd if="$1" bs=1M status=none | sha256sum | cut -c1-64; }
lid()     { sfdisk -d "$1" 2>/dev/null | sed -n 's/^label-id: //p'; }
table()   { sfdisk -d "$LOOP" 2>/dev/null | md5sum | cut -c1-32; }
dump_norm() { sfdisk -d "$LOOP" 2>/dev/null | sed -E 's#/dev/loop[0-9]+#DEV#g'; }
pfield()  { sfdisk -d "$LOOP" 2>/dev/null | grep "^${LOOP}p$1 " | sed -n "s/.*$2= *\([0-9]*\),.*/\1/p"; }
ptype()   { sfdisk -d "$LOOP" 2>/dev/null | grep "^${LOOP}p$1 " | sed -n 's/.*type=\([0-9a-f]*\).*/\1/p'; }
pfs()     { blkid -p -s TYPE -o value "${LOOP}p$1" 2>/dev/null; }
plabel()  { blkid -p -s LABEL -o value "${LOOP}p$1" 2>/dev/null; }
dsz()     { blockdev --getsz "$LOOP"; }

# mkdisk FILE SIZE SFDISK_SCRIPT "N:LABEL ...": fresh DOS table on a new file; p1 FAT, ext4 on the listed partitions,
# ROOT_A-like payload on p2 when present.
mkdisk() {
    local f=$1 size=$2 script=$3 labels=$4 spec n lbl
    rm -f -- "$f"; truncate -s "$size" "$f"
    printf '%b\n' "$script" | sfdisk --no-reread -q "$f" >/dev/null
    LOOP=$(losetup --find --show --partscan "$f")
    mkfs.fat -F32 -n FIRMWARE ${LOOP}p1 >/dev/null
    for spec in $labels; do
        n=${spec%%:*}; lbl=${spec#*:}
        mkfs.ext4 -q -F -L "$lbl" ${LOOP}p$n
    done
    mkdir -p /mnt/b
    if mount ${LOOP}p2 /mnt/b 2>/dev/null; then head -c 3000000 /dev/urandom > /mnt/b/payload; umount /mnt/b; fi
    losetup -d "$LOOP"; LOOP=
}
# attach FILE SIZE ROOTNUM: a copy of the base on a disk of SIZE, ROOT_A (partition ROOTNUM) mounted read-only
attach() {
    cp --sparse=always "$1" $W/t.img; truncate -s "$2" $W/t.img
    LOOP=$(losetup --find --show --partscan $W/t.img)
    mkdir -p /mnt/r; mount -o ro ${LOOP}p$3 /mnt/r
}
detach() { umount /mnt/r 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; LOOP=; rm -f -- $W/t.img; }

# Base A: p1 FAT 512 MiB, p2 ROOT_A 5 GiB, nothing after (the Pi 3 card of the test rig).
BASE_A=$W/dos-a.img
mkdisk $BASE_A 16G 'start=2048, size=1048576, type=c\nstart=1050624, size=10485760, type=83' '2:ROOT_A'
ROOTA_END=$((1050624 + 10485760))

# ---------------------------------------------------------------- (a)
t_a_log()    { [ "$(lines)" = 1 ] && grep -q '^I: layout: created DATA ROOT_B$' "$LOGF"; }
t_a_types()  { [ "$(ptype 2)" = 83 ] && [ "$(ptype 3)" = 83 ] && [ "$(ptype 4)" = 83 ]; }
t_a_labels() { [ "$(plabel 3)" = ROOT_B ] && [ "$(plabel 4)" = DATA ] && [ "$(pfs 3)" = ext4 ] && [ "$(pfs 4)" = ext4 ]; }
t_a_geom()   { [ "$(pfield 3 start)" = "$ROOTA_END" ] && [ "$(pfield 3 size)" = 10485760 ] \
               && [ "$(pfield 4 start)" = $((ROOTA_END + 10485760)) ] \
               && [ $(( $(pfield 4 start) + $(pfield 4 size) )) = "$(dsz)" ] \
               && [ $(( $(pfield 3 start) % 2048 )) = 0 ] && [ $(( $(pfield 4 start) % 2048 )) = 0 ]; }
t_a_nopending() { ! sfdisk -d "$LOOP" | grep -Eq 'type=(da|db)(,|$)'; }
t_a_data_empty() { mkdir -p /mnt/d; mount ${LOOP}p4 /mnt/d && [ "$(ls -A /mnt/d)" = lost+found ]; local r=$?; umount /mnt/d 2>/dev/null; return $r; }
t_c_p1p2()   { [ "$(part_hash ${LOOP}p1)" = "$H1" ] && [ "$(part_hash ${LOOP}p2)" = "$H2" ] && [ "$(lid "$LOOP")" = "$LID0" ]; }
t_a_p1p2()   { [ "$(part_hash ${LOOP}p1)" = "$H1" ] && [ "$(part_hash ${LOOP}p2)" = "$H2" ]; }
t_lid0()     { [ "$(lid "$LOOP")" = "$LID0" ]; }
t_fsck()     { e2fsck -fn ${LOOP}p3 >/dev/null 2>&1 && e2fsck -fn ${LOOP}p4 >/dev/null 2>&1; }

echo "=== (a) 16 GB DOS disk, p1 FAT + p2 ROOT_A: ROOT_B and DATA created"
attach $BASE_A 16G 2
H1=$(part_hash ${LOOP}p1); H2=$(part_hash ${LOOP}p2); LID0=$(lid "$LOOP")
runlay; sed 's/^/    log: /' "$LOGF"
chk "(a) one 'created DATA ROOT_B' log line" t_a_log
chk "(a) p2 stays 83, p3 and p4 type 83" t_a_types
chk "(a) labels ROOT_B and DATA, ext4" t_a_labels
chk "(a) p3 = ROOT_B (size of ROOT_A, right after it, 1 MiB aligned), p4 = DATA to the last sector" t_a_geom
chk "(a) no pending type (da/db) left" t_a_nopending
chk "(a) label-id unchanged" t_lid0
chk "(a) e2fsck -fn ROOT_B and DATA clean" t_fsck
chk "(a) DATA holds only lost+found (empty like stage3's)" t_a_data_empty
chk "(a) p1 and p2 byte-identical" t_a_p1p2
REF_NORM=$(dump_norm); echo "$REF_NORM" | sed 's/^/    table: /'
detach

# ---------------------------------------------------------------- (b)
t_b_noop() { [ "$(lines)" = 0 ] && [ "$(table)" = "$TBL0" ]; }
echo "=== (b) second run is a no-op"
attach $BASE_A 16G 2; runlay; TBL0=$(table)
runlay
chk "(b) second run: no log line, table unchanged" t_b_noop
detach

# ---------------------------------------------------------------- (c)
t_c_layout() { [ "$(ptype 3)" = 83 ] && [ "$(plabel 3)" = DATA ] && [ "$(pfs 3)" = ext4 ] && [ ! -b ${LOOP}p4 ] \
               && [ "$(pfield 3 start)" = "$ROOTA_END" ] && [ $(( $(pfield 3 start) + $(pfield 3 size) )) = "$(dsz)" ]; }
t_c_log()    { [ "$(lines)" = 1 ] && grep -q '^I: layout: created DATA$' "$LOGF"; }
t_c_noop()   { [ "$(lines)" = 0 ] && [ "$(table)" = "$TBL0" ]; }
echo "=== (c) small DOS disk, room for DATA only: DATA becomes p3, no ROOT_B"
attach $BASE_A 6032M 2; H1=$(part_hash ${LOOP}p1); H2=$(part_hash ${LOOP}p2); LID0=$(lid "$LOOP")
runlay; sed 's/^/    log: /' "$LOGF"
chk "(c) DATA is p3 (label DATA, ext4, type 83, to the last sector), no ROOT_B, no p4" t_c_layout
chk "(c) one 'created DATA' log line" t_c_log
chk "(c) p1 and p2 byte-identical, label-id unchanged" t_c_p1p2
chk "(c) e2fsck -fn DATA clean" e2fsck -fn ${LOOP}p3
TBL0=$(table); runlay
chk "(c) second run: no-op" t_c_noop
detach

# ---------------------------------------------------------------- (d)
t_d_table() { [ "$(table)" = "$TBL0" ] && [ "$(part_hash ${LOOP}p1)" = "$H1" ] && [ "$(part_hash ${LOOP}p2)" = "$H2" ]; }
t_d_warn()  { [ "$(lines)" = 1 ] && grep -q '^W: layout: not enough free space' "$LOGF" && grep -q '^rc=0' "$LOGF"; }
echo "=== (d) DOS disk without room: nothing changed, one warning"
attach $BASE_A 5732M 2; TBL0=$(table); H1=$(part_hash ${LOOP}p1); H2=$(part_hash ${LOOP}p2)
runlay; sed 's/^/    log: /' "$LOGF"
chk "(d) one warning (not enough free space), rc=0" t_d_warn
chk "(d) table unchanged, p1 and p2 byte-identical" t_d_table
detach

# ---------------------------------------------------------------- (e)
t_e_table() { [ "$(table)" = "$TBL0" ] && [ "$(part_hash ${LOOP}p1)" = "$H1" ]; }
t_e1_warn() { [ "$(lines)" = 1 ] && grep -q '^W: layout: no free primary partition' "$LOGF"; }
t_e2_warn() { [ "$(lines)" = 1 ] && grep -q '^W: layout: extended partition present' "$LOGF"; }
echo "=== (e1) four primaries, ROOT_A is p4: nothing changed, one warning"
E4=$W/dos-4.img
mkdisk $E4 16G 'start=2048, size=1048576, type=c\nstart=1050624, size=2097152, type=83\nstart=3147776, size=262144, type=83\nstart=3409920, size=10485760, type=83' '2:EXTRA 3:SMALL 4:ROOT_A'
attach $E4 16G 4; TBL0=$(table); H1=$(part_hash ${LOOP}p1)
runlay; sed 's/^/    log: /' "$LOGF"
chk "(e1) log is the no-free-primary warning" t_e1_warn
chk "(e1) table and p1 unchanged" t_e_table
detach
echo "=== (e2) extended partition, ROOT_A logical (p5): nothing changed, one warning"
EX=$W/dos-ext.img
mkdisk $EX 16G 'start=2048, size=1048576, type=c\nstart=1050624, size=10487808, type=f\nstart=1052672, size=10485760, type=83' '5:ROOT_A'
attach $EX 16G 5; TBL0=$(table); H1=$(part_hash ${LOOP}p1)
runlay; sed 's/^/    log: /' "$LOGF"
chk "(e2) log is the extended-partition warning" t_e2_warn
chk "(e2) table and p1 unchanged" t_e_table
detach

# ---------------------------------------------------------------- (i)
t_i_silent() { [ "$(lines)" = 0 ] && [ "$(table)" = "$TBL0" ]; }
echo "=== (i) ROOT_A not the last partition: silent, table unchanged"
AF=$W/dos-after.img
mkdisk $AF 16G 'start=2048, size=1048576, type=c\nstart=1050624, size=10485760, type=83\nstart=11536384, size=2097152, type=83' '2:ROOT_A 3:EXTRA'
attach $AF 16G 2; TBL0=$(table)
runlay; sed 's/^/    log: /' "$LOGF"
chk "(i) no log line, table unchanged" t_i_silent
detach

# ---------------------------------------------------------------- (f)
# cut_run NAME VAR=VALUE...: fresh copy of base A; the stub named by VAR cuts the first run; the clean run must finish
# with exactly the state of (a).
t_f_cut()   { ! grep -q '^rc=' "$LOGF"; }
t_f_final() { [ "$(ptype 3)" = 83 ] && [ "$(ptype 4)" = 83 ] && [ "$(plabel 3)" = ROOT_B ] && [ "$(plabel 4)" = DATA ] \
              && [ "$(pfs 3)" = ext4 ] && [ "$(pfs 4)" = ext4 ] && [ "$(lid "$LOOP")" = "$LID0" ] && t_a_p1p2 \
              && [ "$(dump_norm)" = "$REF_NORM" ]; }
t_f_state() { local f3 f4; f3=$(pfs 3); f4=$(pfs 4); [ "$(ptype 3) ${f3:-none} $(ptype 4) ${f4:-none}" = "$EXPECT" ]; }
cut_run() {
    local name=$1 expect=$2; shift 2
    attach $BASE_A 16G 2; H1=$(part_hash ${LOOP}p1); H2=$(part_hash ${LOOP}p2); LID0=$(lid "$LOOP")
    stubs_off
    local kv
    for kv in "$@"; do export "$kv"; done
    rm -f -- "$STUBS/mk.n" "$STUBS/pt.n"
    EXTRA_PATH=$STUBS runlay; sed 's/^/    cut log: /' "$LOGF"
    chk "(f) $name: the cut stopped layout_complete (no rc line)" t_f_cut
    EXPECT="$expect"
    chk "(f) $name: state after the cut is 'p3type p3fs p4type p4fs = $expect'" t_f_state
    stubs_off
    runlay; sed 's/^/    clean log: /' "$LOGF"
    chk "(f) $name: clean run completes (rc=0)" grep -q '^rc=0' "$LOGF"
    chk "(f) $name: final state equals (a): types 83, labels, ext4, label-id, p1/p2 identical" t_f_final
    chk "(f) $name: e2fsck -fn ROOT_B and DATA clean" t_fsck
    detach
}
t_f_nothing() { [ "$(table)" = "$TBL0" ] && [ "$(pfs 3)" = "" ] && [ "$(pfs 4)" = "" ] && ! grep -q '^rc=' "$LOGF"; }
echo "=== (f) power cuts, then the clean run: final state equals (a)"
attach $BASE_A 16G 2; LID0=$(lid "$LOOP"); TBL0=$(table); stubs_off
export STUB_APPEND_KILL=1; EXTRA_PATH=$STUBS runlay; unset STUB_APPEND_KILL; stubs_off
chk "(f) cut before the table write: table unchanged, nothing formatted" t_f_nothing
detach
cut_run "after the table write, before any mke2fs"   "da none db none"   STUB_MKE2FS_KILL=1
cut_run "after DATA mke2fs, DATA type still db"      "da none db ext4"   STUB_PT_KILL=1
cut_run "after DATA type 83, ROOT_B not formatted"   "da none 83 ext4"   STUB_MKE2FS_KILL=2
cut_run "after ROOT_B mke2fs, ROOT_B type still da"  "da ext4 83 ext4"   STUB_PT_KILL=2

# ---------------------------------------------------------------- (g)
t_g_log()   { [ "$(lines)" = 1 ] && grep -q '^I: layout: created ROOT_B DATA$' "$LOGF"; }
t_g_names() { sgdisk -p "$LOOP" | grep -Eq '^ +3 .*8300 +ROOT_B$' && sgdisk -p "$LOOP" | grep -Eq '^ +4 .*8300 +DATA$' \
              && ! sfdisk -d "$LOOP" | grep -q GUID:48; }
t_g_gpt()   { [ "$(blkid -p -s PTTYPE -o value "$LOOP")" = gpt ] && ! sfdisk -d "$LOOP" | grep -Eq 'type=(da|db)' \
              && sgdisk -v "$LOOP" 2>&1 | grep -q 'No problems found'; }
echo "=== (g) GPT disk: the GPT path, unchanged"
rm -f -- $W/gpt.img; truncate -s 16G $W/gpt.img
sgdisk -Z $W/gpt.img >/dev/null
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:EFI $W/gpt.img >/dev/null
sgdisk -n 2:0:+5G -t 2:8300 -c 2:ROOT_A $W/gpt.img >/dev/null
LOOP=$(losetup --find --show --partscan $W/gpt.img)
mkfs.fat -F32 -n EFI ${LOOP}p1 >/dev/null; mkfs.ext4 -q -F -L ROOT_A ${LOOP}p2
mkdir -p /mnt/r; mount -o ro ${LOOP}p2 /mnt/r
runlay; sed 's/^/    log: /' "$LOGF"
chk "(g) GPT: one 'created ROOT_B DATA' log line (GPT path wording)" t_g_log
chk "(g) GPT: ROOT_B and DATA named, type 8300, flags cleared" t_g_names
chk "(g) GPT: no DOS type (da/db), GPT valid" t_g_gpt
umount /mnt/r; losetup -d "$LOOP"; LOOP=
rm -f -- $W/gpt.img

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
