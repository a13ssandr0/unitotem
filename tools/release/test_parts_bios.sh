#!/bin/bash
# Test of make_parts (deploy/parts-lib.sh) for the legacy-BIOS partition (GPT type ef02, labelled BIOS):
# raw dd stream (cloner dd, action raw), manifest fields, stream integrity and content, and no BIOS block
# when the image has no ef02 partition.
# Needs docker with --privileged (loop devices and mounts happen only INSIDE the container). The repo is
# mounted read-only. Scratch images and parts sets live in the container's /tmp and vanish with it.
#   tools/release/test_parts_bios.sh            host side: runs the container
#   tools/release/test_parts_bios.sh --inside   container side
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${PARTS_BUILDER_IMAGE:-unitotem-parts-builder}"

if [ "${1:-}" != --inside ]; then
    docker run --rm --privileged -v "${DIR}:/repo:ro" --workdir /tmp "$IMAGE" \
        bash /repo/tools/release/test_parts_bios.sh --inside
    exit $?
fi

# ---- container side ----
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
W=$(mktemp -d /tmp/parts-bios.XXXXXX)
LOOPS=()
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
cleanup() { local l; for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done; }
trap cleanup EXIT
trap 'exit 1' TERM INT

# make_img IMG WITH_BIOS(0|1): GPT with EFI, ROOT_A, ROOT_B, DATA and optionally BIOS (ef02, LBA 34..2047)
make_img() {
    local img=$1 bios=$2
    rm -f -- "$img"; truncate -s 300M "$img"
    sgdisk -o "$img" >/dev/null
    if [ "$bios" = 1 ]; then
        # random bytes in LBA 34..2047 before any partition is written; the table never reaches that area
        dd if=/dev/urandom of="$img" bs=512 seek=34 count=2014 conv=notrunc status=none
    fi
    sgdisk -n 1:2048:+32M -t 1:ef00 -c 1:EFI "$img" >/dev/null
    sgdisk -n 2:0:+64M -t 2:8300 -c 2:ROOT_A "$img" >/dev/null
    sgdisk -n 3:0:+32M -t 3:8300 -c 3:ROOT_B "$img" >/dev/null
    sgdisk -n 4:0:+64M -t 4:8300 -c 4:DATA "$img" >/dev/null
    if [ "$bios" = 1 ]; then
        sgdisk -n 5:34:2047 -t 5:ef02 -c 5:BIOS "$img" >/dev/null
    fi
}

# populate IMG: writes filesystems into the partitions (read-write loop, detached afterwards)
populate() {
    local img=$1 loop
    loop=$(losetup --find --show --partscan "$img") || return 1
    LOOPS+=("$loop")
    partprobe "$loop" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    mkfs.vfat -n EFI "${loop}p1" >/dev/null || return 1
    mkdir -p "$W/efi" || return 1
    mount "${loop}p1" "$W/efi" || return 1
    mkdir -p "$W/efi/EFI/BOOT" && echo "unitotem test bootx64" > "$W/efi/EFI/BOOT/BOOTX64.EFI"
    umount "$W/efi" || return 1
    mkdir -p "$W/rootA-src/etc" && echo "unitotem root A test" > "$W/rootA-src/etc/unitotem-test" || return 1
    mkfs.ext4 -q -F -L ROOT_A -d "$W/rootA-src" "${loop}p2" || return 1
    mkfs.ext4 -q -F -L ROOT_B "${loop}p3" || return 1
    mkfs.ext4 -q -F -L DATA "${loop}p4" || return 1
    sync
    losetup -d "$loop" || return 1
}

# run_parts IMG OUTDIR: make_parts on a read-only loop device, as deploy/make-parts-image.sh does
run_parts() {
    local img=$1 out=$2 loop rc
    loop=$(losetup --find --show --partscan --read-only "$img") || return 1
    LOOPS+=("$loop")
    partprobe "$loop" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    ( source /repo/deploy/parts-lib.sh; make_parts "$loop" "$out" amd64 testset "$img" ) > "$out.log" 2>&1
    rc=$?
    losetup -d "$loop" 2>/dev/null || true
    return $rc
}

# manifest_block MANIFEST LABEL: the partition block whose UNITOTEM_PART_LABEL is LABEL
manifest_block() { awk -v L="UNITOTEM_PART_LABEL=$2" 'BEGIN{RS="";FS="\n"} { for(i=1;i<=NF;i++) if($i==L){print; exit} }' "$1"; }
# mval TEXT KEY: value of KEY in TEXT
mval() { printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# ---- set 1: image with the ef02 BIOS partition ----
OUT1="$W/with-bios.parts"
make_img "$W/with.img" 1
populate "$W/with.img" || bad "populate image with BIOS partition"
dd if="$W/with.img" of="$W/expected.bin" bs=512 skip=34 count=2014 status=none
chk "expected region (LBA 34..2047) is not all zero" [ "$(tr -d '\000' < "$W/expected.bin" | wc -c)" -gt 0 ]
run_parts "$W/with.img" "$OUT1"; rc=$?
chk "make_parts exits 0 (image with BIOS)" [ "$rc" = 0 ]
M1="$OUT1/parts.manifest"
chk "parts.manifest written" [ -s "$M1" ]
B=$(manifest_block "$M1" BIOS)
chk "manifest has a BIOS block" [ -n "$B" ]
chk "BIOS block: UNITOTEM_PART_ACTION=raw" [ "$(mval "$B" UNITOTEM_PART_ACTION)" = raw ]
chk "BIOS block: UNITOTEM_PART_CLONER=dd" [ "$(mval "$B" UNITOTEM_PART_CLONER)" = dd ]
chk "BIOS block: UNITOTEM_PART_START=34" [ "$(mval "$B" UNITOTEM_PART_START)" = 34 ]
chk "BIOS block: UNITOTEM_PART_SECTORS=2014" [ "$(mval "$B" UNITOTEM_PART_SECTORS)" = 2014 ]
S=$(mval "$B" UNITOTEM_PART_STREAM_FILE)
chk "BIOS block: UNITOTEM_PART_STREAM_FILE=p5-BIOS.raw.pc.xz" [ "$S" = p5-BIOS.raw.pc.xz ]
chk "BIOS stream exists and is non-empty" [ -s "$OUT1/$S" ]
chk "BIOS stream sha256 equals UNITOTEM_PART_STREAM_SHA256" [ "$(sha "$OUT1/$S")" = "$(mval "$B" UNITOTEM_PART_STREAM_SHA256)" ]
chk "BIOS stream size equals UNITOTEM_PART_STREAM_BYTES" [ "$(stat -c%s "$OUT1/$S")" = "$(mval "$B" UNITOTEM_PART_STREAM_BYTES)" ]
chk "xz -dc of BIOS stream is byte-identical to LBA 34..2047" bash -c 'xz -dc "$1" | cmp -s - "$2"' _ "$OUT1/$S" "$W/expected.bin"
chk "UNITOTEM_LAYOUT=2 (ROOT_A present)" [ "$(mval "$(cat "$M1")" UNITOTEM_LAYOUT)" = 2 ]
chk "UNITOTEM_NPARTS=5 (EFI, ROOT_A, ROOT_B, DATA, BIOS)" [ "$(mval "$(cat "$M1")" UNITOTEM_NPARTS)" = 5 ]
RA=$(manifest_block "$M1" ROOT_A)
chk "ROOT_A uses cloner extfs" [ "$(mval "$RA" UNITOTEM_PART_CLONER)" = extfs ]
chk "ROOT_A stream exists" [ -s "$OUT1/$(mval "$RA" UNITOTEM_PART_STREAM_FILE)" ]
RB=$(manifest_block "$M1" ROOT_B)
chk "ROOT_B is not streamed (action format, no stream file)" bash -c '[ "$1" = format ] && [ -z "$2" ]' _ "$(mval "$RB" UNITOTEM_PART_ACTION)" "$(mval "$RB" UNITOTEM_PART_STREAM_FILE)"
DB=$(manifest_block "$M1" DATA)
chk "DATA is not streamed (action data, no stream file)" bash -c '[ "$1" = data ] && [ -z "$2" ]' _ "$(mval "$DB" UNITOTEM_PART_ACTION)" "$(mval "$DB" UNITOTEM_PART_STREAM_FILE)"
chk "SHA256SUMS verifies (BIOS set)" bash -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$OUT1"

# ---- set 2: image without an ef02 partition ----
OUT2="$W/no-bios.parts"
make_img "$W/nobios.img" 0
populate "$W/nobios.img" || bad "populate image without BIOS partition"
run_parts "$W/nobios.img" "$OUT2"; rc=$?
chk "make_parts exits 0 (image without BIOS)" [ "$rc" = 0 ]
M2="$OUT2/parts.manifest"
chk "no BIOS block without ef02 partition" [ -z "$(manifest_block "$M2" BIOS)" ]
chk "no BIOS stream without ef02 partition" [ -z "$(ls "$OUT2" | grep BIOS)" ]
chk "UNITOTEM_NPARTS=4 without ef02 partition" [ "$(mval "$(cat "$M2")" UNITOTEM_NPARTS)" = 4 ]
chk "SHA256SUMS verifies (no-BIOS set)" bash -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$OUT2"

echo "RESULT: ${pass} passed, ${failn} failed"
[ "$failn" = 0 ]
