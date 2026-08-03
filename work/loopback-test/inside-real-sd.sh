#!/bin/bash
# §11.4 step 2: same exact OTA stage1+stage2 sequence as inside-arm64.sh,
# just-verified in loopback (50/50 checks), now run against the real Pi SD
# card (/dev/sdb) instead of a loop file - still entirely via the USB
# reader on the dev host, never touching the Pi itself. A full read-only
# backup of the card was already taken and sha256-verified before this ran
# (work/sd-backup-pre-ota.img). Always takes the "new system" (table
# recreate) path - the card's current content predates this whole two-stage
# redesign (different partition count/layout entirely), so there is no
# meaningful "already UniTotem, preserve the table" case here; this is
# effectively the first-ever deploy of the new layout onto this card.
set -Eeuo pipefail

log() { echo ">>> $*"; }
fail() { echo "!!! FALLITO: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Installo i pacchetti necessari nel container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    partclone xz-utils util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted \
    socat procps dctrl-tools file device-tree-compiler >/dev/null

REPO=/repo
PARTS=/work/parts
DISK=/dev/sdb
ENGINE=(bash "$REPO/deploy/ota-engine.sh")
RESULTS=/work/results.txt
: > "$RESULTS"

record() { echo "$1" | tee -a "$RESULTS"; }
check() {
    local desc="$1"; shift
    if "$@" >/tmp/check.out 2>&1; then
        record "PASS: $desc"
    else
        record "FAIL: $desc -- $(tail -5 /tmp/check.out | tr '\n' '|')"
    fi
}

[ -b "$DISK" ] || fail "$DISK non visibile in questo container (atteso: solo la SD reale, tramite --device)"
log "Disco target: $DISK ($(blockdev --getsize64 "$DISK" 2>/dev/null) byte)"

cleanup() {
    set +e
    umount -lf /mnt/newroot/mnt/data /mnt/newroot/boot/firmware /mnt/newroot 2>/dev/null
    umount -lf /mnt/ota-bootfs /mnt/ota-promote-check 2>/dev/null
}
trap cleanup EXIT

declare -A M
{
    while IFS= read -r line; do
        [ -z "$line" ] && break
        M["${line%%=*}"]="${line#*=}"
    done
} < "$PARTS/parts.manifest"

DATA_PART="${M[UNITOTEM_DATA_PART]}"
BOOTFS_PART="${M[UNITOTEM_BOOTFS_PART]}"
log "manifest: DATA_PART=$DATA_PART BOOTFS_PART=$BOOTFS_PART RAW_SIZE=${M[UNITOTEM_RAW_SIZE]} TOTAL_USED=${M[UNITOTEM_TOTAL_USED_BYTES]}"

log "=== probe (stato attuale della SD, qualunque esso sia) ==="
"${ENGINE[@]}" probe --disk "$DISK" | tee /tmp/probe0.out || true

log "=== Stage 1: tabella + fallback ==="
TABLE_B64=$(base64 -w0 < "$PARTS/layout.sfdisk")
BOOTCODE_ARG=()
[ -f "$PARTS/bootcode.bin" ] && BOOTCODE_ARG=(--bootcode-b64 "$(base64 -w0 < "$PARTS/bootcode.bin")")
"${ENGINE[@]}" restore-table --disk "$DISK" --table-b64 "$TABLE_B64" --tail-part "$DATA_PART" "${BOOTCODE_ARG[@]}"

sfdisk --dump "$DISK" > /tmp/table-after.sfdisk
record "--- tabella ripristinata (sfdisk --dump) ---"
cat /tmp/table-after.sfdisk | tee -a "$RESULTS"

ensure_partition_nodes() {
    local disk="$1" base p majmin maj min
    base=$(basename "$disk")
    for p in /sys/class/block/${base}/${base}*; do
        [ -e "$p" ] || continue
        local node="/dev/$(basename "$p")"
        [ -b "$node" ] && continue
        majmin=$(cat "$p/dev")
        maj=${majmin%:*}; min=${majmin#*:}
        mknod "$node" b "$maj" "$min"
    done
}
ensure_partition_nodes "$DISK"
ls -la "${DISK}"* || true

"${ENGINE[@]}" prepare-bootfs --disk "$DISK" --bootfs-part "$BOOTFS_PART" --fstype vfat --fresh 1 --label FIRMWARE

log "Scrivo kernel/initrd di recovery (arm64: recovery8.img/recovery-initrd.img, no subdir)..."
"${ENGINE[@]}" write-bootfile --disk "$DISK" --bootfs-part "$BOOTFS_PART" --name recovery8.img \
    < "$REPO/deploy/arm64/recovery-vmlinuz-arm64"
"${ENGINE[@]}" write-bootfile --disk "$DISK" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img \
    < "$REPO/deploy/arm64/recovery-initrd-arm64.img"

"${ENGINE[@]}" set-default-recovery --disk "$DISK" --firmware rpi --bootfs-part "$BOOTFS_PART"
log "Stage 1 completato: da qui una perdita di alimentazione riavvia sul fallback."

log "=== Stage 2: contenuto reale ==="
BOOTFS_STREAM=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "$PARTS/parts.manifest")
if [ -n "$BOOTFS_STREAM" ]; then
    log "Popolo contenuto file-level della boot fs da ${BOOTFS_STREAM}..."
    socat -u "FILE:$PARTS/$BOOTFS_STREAM" "TCP-LISTEN:9700,reuseaddr" &
    NCPID=$!
    sleep 0.5
    "${ENGINE[@]}" populate-bootfs --disk "$DISK" --bootfs-part "$BOOTFS_PART" --data-host 127.0.0.1 --data-port 9700
    wait "$NCPID" 2>/dev/null || true
fi

ROOT_PART=""
declare -A BLOCK
process_block() {
    local n="${BLOCK[UNITOTEM_PART]:-}"
    [ -n "$n" ] || return 0
    local label="${BLOCK[UNITOTEM_PART_LABEL]:-}"
    local action="${BLOCK[UNITOTEM_PART_ACTION]:-}"
    [ "$label" = ROOT ] && ROOT_PART="$n"
    case "$action" in
        restore|raw)
            local cloner="${BLOCK[UNITOTEM_PART_CLONER]}"
            local used="${BLOCK[UNITOTEM_PART_USED_BYTES]:-0}"
            local stream="${BLOCK[UNITOTEM_PART_STREAM_FILE]}"
            local comp="${BLOCK[UNITOTEM_PART_COMP]:-xz}"
            log "restore-part $n ($label, cloner=$cloner, used=${used}B)..."
            socat -u "FILE:$PARTS/$stream" "TCP-LISTEN:9701,reuseaddr" &
            local ncpid=$!
            sleep 0.5
            "${ENGINE[@]}" restore-part --disk "$DISK" --part "$n" --cloner "$cloner" --comp "$comp" \
                --used-bytes "$used" --data-host 127.0.0.1 --data-port 9701 --fstype "${BLOCK[UNITOTEM_PART_FSTYPE]:-}"
            wait "$ncpid" 2>/dev/null || true
            ;;
        data)
            log "data-op mkfs su partizione $n (primo deploy del nuovo layout: DATA formattata)"
            "${ENGINE[@]}" data-op --disk "$DISK" --part "$n" --op mkfs
            ;;
    esac
}

in_header=1
while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
        if [ "$in_header" = 1 ]; then in_header=0; BLOCK=(); continue; fi
        process_block
        BLOCK=()
        continue
    fi
    [ "$in_header" = 1 ] && continue
    BLOCK["${line%%=*}"]="${line#*=}"
done < "$PARTS/parts.manifest"
process_block

log "ROOT_PART=$ROOT_PART"
check "ROOT individuata nel manifest" bash -c "[ -n '$ROOT_PART' ]"

log "=== mount-target (arch arm64) ==="
"${ENGINE[@]}" mount-target --disk "$DISK" --arch arm64 --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART"

check "ROOT montata ha /sbin/init o systemd" bash -c '[ -x /mnt/newroot/sbin/init ] || [ -x /mnt/newroot/usr/lib/systemd/systemd ]'
check "ROOT montata ha /etc/kiosk (marker UniTotem)" test -d /mnt/newroot/etc/kiosk
check "firmware montata sotto /boot/firmware" test -d /mnt/newroot/boot/firmware

log "=== populate-real-kernel (arm64 only) ==="
"${ENGINE[@]}" populate-real-kernel
check "kernel8.img (sistema reale) scritto su firmware" test -f /mnt/newroot/boot/firmware/kernel8.img
check "initramfs8 (sistema reale) scritto su firmware" test -f /mnt/newroot/boot/firmware/initramfs8
check "kernel8.img del sistema reale e' un Image arm64 valido (ARMd grezzo o gzip)" \
    bash -c 'k=/mnt/newroot/boot/firmware/kernel8.img; [ "$(dd if="$k" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d " \n")" = "1f8b" ] || [ "$(dd if="$k" bs=1 skip=56 count=4 2>/dev/null)" = "ARMd" ]'
check "almeno un dtb bcm27* copiato sulla firmware" bash -c 'ls /mnt/newroot/boot/firmware/bcm27*.dtb >/dev/null 2>&1'

"${ENGINE[@]}" migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data

log "=== set-trial-boot (rpi-tryboot) ==="
"${ENGINE[@]}" set-trial-boot --firmware rpi-tryboot --disk "$DISK" --bootfs-part "$BOOTFS_PART"

log "=== verifica: config.txt e i file di recovery sopravvivono a stage 2 ==="
BOOTFS_MNT=/mnt/newroot/boot/firmware
check "recovery8.img ancora presente" test -f "$BOOTFS_MNT/recovery8.img"
check "recovery-initrd.img ancora presente" test -f "$BOOTFS_MNT/recovery-initrd.img"
got_vmlinuz_sha=$(sha256sum "$BOOTFS_MNT/recovery8.img" | cut -d' ' -f1)
got_initrd_sha=$(sha256sum "$BOOTFS_MNT/recovery-initrd.img" | cut -d' ' -f1)
exp_vmlinuz_sha=$(awk -F= '/UNITOTEM_RECOVERY_VMLINUZ_SHA256/{print $2}' "$REPO/deploy/arm64/recovery.manifest")
exp_initrd_sha=$(awk -F= '/UNITOTEM_RECOVERY_INITRD_SHA256/{print $2}' "$REPO/deploy/arm64/recovery.manifest")
record "recovery8.img sha256: got=${got_vmlinuz_sha} expected=${exp_vmlinuz_sha}"
check "recovery8.img sha256 corretto (riletto dal disco)" bash -c "[ '$got_vmlinuz_sha' = '$exp_vmlinuz_sha' ]"
record "recovery-initrd.img sha256: got=${got_initrd_sha} expected=${exp_initrd_sha}"
check "recovery-initrd.img sha256 corretto (riletto dal disco)" bash -c "[ '$got_initrd_sha' = '$exp_initrd_sha' ]"
check "config.txt punta ancora al fallback (recovery8.img)" grep -q "^kernel=recovery8.img" "$BOOTFS_MNT/config.txt"
check "tryboot.txt scritto e punta al kernel reale" grep -q "kernel8.img" "$BOOTFS_MNT/tryboot.txt"
check "cmdline-trial.txt scritto" test -f "$BOOTFS_MNT/cmdline-trial.txt"
# See inside-arm64.sh's matching check: /mnt/newroot/etc/unitotem/config-extra.txt
# is real content on this just-restored ROOT (installed by
# kiosk/stage2-configure.sh) - dtoverlay=vc4-kms-v3d missing from tryboot.txt
# is exactly the bug that shipped an OTA pipeline where KMS never reached a
# single real device (found on real hardware this session).
check "tryboot.txt include il dtoverlay KMS (config-extra.txt)" grep -q "dtoverlay=vc4-kms-v3d" "$BOOTFS_MNT/tryboot.txt"

log "=== umount-target ==="
"${ENGINE[@]}" umount-target

log "=== fsck a freddo (SD reale) ==="
check "fsck.ext4 pulito su ROOT" e2fsck -fn "${DISK}${ROOT_PART}"
check "fsck.vfat pulito su bootfs (FIRMWARE)" fsck.vfat -n "${DISK}${BOOTFS_PART}"
check "fsck.ext4 pulito su DATA (appena formattata)" e2fsck -fn "${DISK}${DATA_PART}"
check "label DATA corretta" bash -c "[ \"\$(blkid -s LABEL -o value ${DISK}${DATA_PART})\" = DATA ]"

log "=== RISULTATI (SD reale, prima di promote-default: il fallback resta il default) ==="
cat "$RESULTS"
if grep -q '^FAIL' "$RESULTS"; then
    log "ALCUNI CONTROLLI SONO FALLITI - la SD resta comunque avviabile sul fallback (default non cambiato)"
    exit 1
else
    log "TUTTI I CONTROLLI SONO PASSATI - SD pronta per il primo avvio di prova sul Pi reale"
fi
