#!/bin/bash
# arm64 counterpart of inside.sh - same §11.1 loopback verification, but
# exercising the arm64-specific paths that inside.sh (amd64) never touches:
# --firmware rpi/rpi-tryboot, --arch arm64 mount-target (no --boot-part, no
# separate BOOT partition), and populate-real-kernel (arm64 only - the Pi
# firmware reads kernel8.img/initramfs8/dtbs from the FAT firmware partition,
# never from ROOT). This path had never been exercised at all before this
# run - only amd64 had been through §11.1.
set -Eeuo pipefail

log() { echo ">>> $*"; }
fail() { echo "!!! FALLITO: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Installo i pacchetti necessari nel container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    partclone xz-utils util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted \
    socat procps dctrl-tools file device-tree-compiler iproute2 >/dev/null

REPO=/repo
PARTS=/work/parts
TARGET_IMG=/work/target.img
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

SIZE_GIB="${TARGET_SIZE_GIB:-16}"
log "Creo disco target da ${SIZE_GIB}GiB (sparse, piu' grande della sorgente da 11GiB apposta)..."
rm -f "$TARGET_IMG"
truncate -s "${SIZE_GIB}G" "$TARGET_IMG"

LOOP=$(losetup --find --show --partscan "$TARGET_IMG")
log "Loop device: $LOOP"

cleanup() {
    set +e
    umount -lf /mnt/newroot/mnt/data /mnt/newroot/boot/firmware /mnt/newroot 2>/dev/null
    umount -lf /mnt/ota-bootfs 2>/dev/null
    umount -lf /mnt/round2-bootfs-check /mnt/round2-promote-check 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
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
log "manifest: DATA_PART=$DATA_PART BOOTFS_PART=$BOOTFS_PART HAS_ESP=${M[UNITOTEM_HAS_ESP]} RAW_SIZE=${M[UNITOTEM_RAW_SIZE]} TOTAL_USED=${M[UNITOTEM_TOTAL_USED_BYTES]}"

log "=== probe (disco vuoto) ==="
"${ENGINE[@]}" probe --disk "$LOOP" | tee /tmp/probe0.out
check "probe su disco vuoto non segnala HAVE_UNITOTEM" grep -q 'UNITOTEM_HAVE_UNITOTEM=0' /tmp/probe0.out

log "=== Stage 1: tabella + fallback ==="
TABLE_B64=$(base64 -w0 < "$PARTS/layout.sfdisk")
BOOTCODE_ARG=()
[ -f "$PARTS/bootcode.bin" ] && BOOTCODE_ARG=(--bootcode-b64 "$(base64 -w0 < "$PARTS/bootcode.bin")")
"${ENGINE[@]}" restore-table --disk "$LOOP" --table-b64 "$TABLE_B64" --tail-part "$DATA_PART" "${BOOTCODE_ARG[@]}"

sfdisk --dump "$LOOP" > /tmp/table-after.sfdisk
record "--- tabella ripristinata (sfdisk --dump) ---"
cat /tmp/table-after.sfdisk | tee -a "$RESULTS"
data_size_sectors=$(grep -E "${LOOP}p${DATA_PART}[[:space:]]*:" /tmp/table-after.sfdisk | grep -oE 'size=[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
log "DATA size dopo restore-table: ${data_size_sectors} settori (~$((data_size_sectors/2048))MiB)"
check "DATA ricalcolata su disco piu' grande (>4GiB in settori)" \
    bash -c "[ ${data_size_sectors:-0} -gt 8388608 ]"

ensure_partition_nodes() {
    local loop="$1" base p majmin maj min
    base=$(basename "$loop")
    for p in /sys/class/block/${base}p*; do
        [ -e "$p" ] || continue
        local node="/dev/$(basename "$p")"
        [ -b "$node" ] && continue
        majmin=$(cat "$p/dev")
        maj=${majmin%:*}; min=${majmin#*:}
        mknod "$node" b "$maj" "$min"
    done
}
ensure_partition_nodes "$LOOP"

"${ENGINE[@]}" prepare-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --fstype vfat --fresh 1 --label FIRMWARE

log "Scrivo kernel/initrd di recovery (arm64: recovery8.img/recovery-initrd.img, no subdir)..."
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery8.img \
    < "$REPO/deploy/arm64/recovery-vmlinuz-arm64"
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img \
    < "$REPO/deploy/arm64/recovery-initrd-arm64.img"

"${ENGINE[@]}" set-default-recovery --disk "$LOOP" --firmware rpi --bootfs-part "$BOOTFS_PART"
log "Stage 1 completato."

log "=== Stage 2: contenuto reale ==="
BOOTFS_STREAM=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "$PARTS/parts.manifest")
if [ -n "$BOOTFS_STREAM" ]; then
    log "Popolo contenuto file-level della boot fs da ${BOOTFS_STREAM}..."
    socat -u "FILE:$PARTS/$BOOTFS_STREAM" "TCP-LISTEN:9700,reuseaddr" &
    NCPID=$!
    sleep 0.5
    "${ENGINE[@]}" populate-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --data-host 127.0.0.1 --data-port 9700
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
            "${ENGINE[@]}" restore-part --disk "$LOOP" --part "$n" --cloner "$cloner" --comp "$comp" \
                --used-bytes "$used" --data-host 127.0.0.1 --data-port 9701 --fstype "${BLOCK[UNITOTEM_PART_FSTYPE]:-}"
            wait "$ncpid" 2>/dev/null || true
            ;;
        data)
            log "data-op mkfs su partizione $n (percorso 'sistema nuovo')"
            "${ENGINE[@]}" data-op --disk "$LOOP" --part "$n" --op mkfs
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

log "=== mount-target (arch arm64, niente boot-part separato) ==="
"${ENGINE[@]}" mount-target --disk "$LOOP" --arch arm64 --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART"

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
"${ENGINE[@]}" set-trial-boot --firmware rpi-tryboot --disk "$LOOP" --bootfs-part "$BOOTFS_PART"

log "=== verifica: i file di recovery e il kernel8.img del sistema reale convivono senza clobbering ==="
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
check "config.txt di default-recovery ancora presente e punta al fallback" grep -q "recovery8.img" "$BOOTFS_MNT/config.txt"
check "tryboot.txt scritto e punta al kernel reale" grep -q "kernel8.img" "$BOOTFS_MNT/tryboot.txt"
check "cmdline-trial.txt scritto" test -f "$BOOTFS_MNT/cmdline-trial.txt"
# Regression check for the config-extra.txt splice (deploy/ota-engine.sh's
# append_config_extra): set-trial-boot's rpi-tryboot branch reads
# /mnt/newroot/etc/unitotem/config-extra.txt, which is real content on this
# just-restored ROOT (installed by kiosk/stage2-configure.sh, no simulation
# needed here unlike promote-default below) - dtoverlay=vc4-kms-v3d missing
# from tryboot.txt is exactly the bug that shipped an OTA pipeline where KMS
# never reached a single real device (found on real hardware this session).
check "tryboot.txt include il dtoverlay KMS (config-extra.txt)" grep -q "dtoverlay=vc4-kms-v3d" "$BOOTFS_MNT/tryboot.txt"

log "=== umount-target ==="
"${ENGINE[@]}" umount-target

log "=== fsck a freddo ==="
check "fsck.ext4 pulito su ROOT" e2fsck -fn "${LOOP}p${ROOT_PART}"
check "fsck.vfat pulito su bootfs (FIRMWARE)" fsck.vfat -n "${LOOP}p${BOOTFS_PART}"
check "fsck.ext4 pulito su DATA (appena formattata)" e2fsck -fn "${LOOP}p${DATA_PART}"
check "label DATA corretta" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p${DATA_PART})\" = DATA ]"

log "=== promote-default (simulando boot confermato, rpi non richiede chroot) ==="
# promote-default runs post-boot on the real system's own / (see
# deploy/ota-engine.sh's append_config_extra comment) - this test container
# IS that "/" here (no chroot), so /etc/unitotem/config-extra.txt has to be
# staged manually to match what kiosk/stage2-configure.sh installs onto a
# real ROOT. Without this the check below would silently no-op instead of
# catching a regression (append_config_extra treats a missing file as
# nothing-to-add, not an error).
mkdir -p /etc/unitotem
cp "$REPO/kiosk/files/config-extra.txt" /etc/unitotem/config-extra.txt
"${ENGINE[@]}" promote-default --firmware rpi --disk "$LOOP" --bootfs-part "$BOOTFS_PART"
mkdir -p /mnt/ota-promote-check
mount -t vfat -o ro "${LOOP}p${BOOTFS_PART}" /mnt/ota-promote-check
check "config.txt promosso punta al kernel reale (non piu' recovery)" grep -q "^kernel=kernel8.img" /mnt/ota-promote-check/config.txt
check "config.txt promosso include il dtoverlay KMS (config-extra.txt)" grep -q "dtoverlay=vc4-kms-v3d" /mnt/ota-promote-check/config.txt
check "tryboot.txt rimosso dopo promote-default" bash -c '[ ! -f /mnt/ota-promote-check/tryboot.txt ]'
check "cmdline-trial.txt rimosso dopo promote-default" bash -c '[ ! -f /mnt/ota-promote-check/cmdline-trial.txt ]'
check "recovery8.img ancora presente dopo promote (mai cancellato)" test -f /mnt/ota-promote-check/recovery8.img
umount /mnt/ota-promote-check

log "=== ROUND 2: redeploy su target GIA' provisionato (recreate_table=0) ==="
# Everything above only ever exercises a fresh/first-time provisioning
# (recreate_table=1, since it always starts from an empty loop device) by
# hand-rolling calls to ota-engine.sh subcommands directly - it never drives
# deploy/remote-deploy.sh's own orchestration logic (run_ota_sequence),
# which decides WHICH subcommands to call and when. That orchestration
# logic is exactly where two real bugs lived this session (config.txt's
# dtoverlay= never spliced in, populate-bootfs never called at all) for the
# recreate_table=0 path - an already-provisioned device's normal, everyday
# OTA update, the common case in production. Round 1 above could not have
# caught either regardless of what scenario it simulated, since it never
# calls into remote-deploy.sh's code at all.
#
# This round reuses the SAME loop device, already fully provisioned and
# promoted by round 1, and drives the REAL run_ota_sequence() - extracted
# fresh from the current deploy/remote-deploy.sh every run (never a stale
# hand-copy: a stale scratchpad copy of this same function silently diverged
# from a fix and caused a real, confusing failure earlier this session).

log "Svuoto overlays/ apposta prima del round 2 (altrimenti il controllo passerebbe per residuo del round 1, non per verifica reale)..."
mkdir -p /mnt/round2-bootfs-check
mount -o rw "${LOOP}p${BOOTFS_PART}" /mnt/round2-bootfs-check
rm -rf /mnt/round2-bootfs-check/overlays
sync
umount /mnt/round2-bootfs-check

# run_ota_sequence calls die/serve_file_once/wait_port_bound/read_kv_block,
# all from deploy/lib.sh - never sourced above since round 1 doesn't need
# them (it drives ota-engine.sh subcommands directly, no ssh/lib wrapper).
source "$REPO/deploy/lib.sh"
sed -n '/^run_ota_sequence()/,/^}/p' "$REPO/deploy/remote-deploy.sh" > /tmp/run_ota_sequence.sh
check "run_ota_sequence() estratta da remote-deploy.sh" test -s /tmp/run_ota_sequence.sh
source /tmp/run_ota_sequence.sh

# run_ota_sequence's only I/O to "the target" is through ota_ssh/ota_ssh_send
# (deploy/lib.sh) - both normally SSH out as (host, cmd...). Here "the
# target" IS this container, so eval the command directly instead; a real
# deployed system resolves "unitotem-ota-engine" via PATH
# (/usr/sbin/unitotem-ota-engine -> .../ota-engine.sh, kiosk/stage1-packages.sh).
# A shell function of that exact name achieves the same resolution when
# eval'd, without needing a writable PATH directory - debian:bookworm's
# /usr/local/bin turned out to be read-only in this container image (bash
# function names may contain hyphens, this is valid syntax).
# The final `reboot -f` this function issues as its last step is
# intercepted, not run for real - a --privileged container CAN actually
# reboot the Docker host via a real reboot(2), and the test only needs to
# verify what was WRITTEN to disk, not a live boot.
unitotem-ota-engine() { bash "$REPO/deploy/ota-engine.sh" "$@"; }
ota_ssh() {
    local _h="$1"; shift
    case "$1" in
        *reboot*) log "(round 2: reboot intercettato, non eseguito per davvero - '$1')" ;;
        *) eval "$1" ;;
    esac
}
ota_ssh_send() { local _h="$1"; shift; eval "$1"; }

# run_ota_sequence references ${DIR}/deploy/${ARCH}/recovery-{vmlinuz,initrd}-...
# to locate the recovery kernel/initrd it re-pushes in Stage 1 - $DIR is
# remote-deploy.sh's own repo-root variable, assigned outside the extracted
# function boundary above, so it has to be set explicitly here (the exact
# same $DIR-scoping bug bit an ad-hoc scratchpad copy of this same function
# earlier this session - not repeating it here).
DIR="$REPO"
ARCH=arm64
FIRMWARE=rpi
TRYBOOT_CAPABLE=0
OPT_PARTS="$PARTS"
OPT_PORT=9702
OPT_WIPE_DATA=0
P_ROOT_PART="$ROOT_PART"
P_BOOTFS_PART="$BOOTFS_PART"
P_DATA_PART="$DATA_PART"
declare -A P
P[HAVE_UNITOTEM]=1
P[HAVE_DATA]=1
P[SSHCLIENT]=127.0.0.1

run_ota_sequence "127.0.0.1" "$LOOP"
log "Round 2: run_ota_sequence completata."

mkdir -p /mnt/round2-bootfs-check
mount -o ro "${LOOP}p${BOOTFS_PART}" /mnt/round2-bootfs-check
check "round2: overlays/ ripopolata su un target gia' provisionato (recreate_table=0)" \
    test -f /mnt/round2-bootfs-check/overlays/vc4-kms-v3d.dtbo
check "round2: config.txt (trial, rpi-legacy) include il dtoverlay KMS" \
    grep -q "dtoverlay=vc4-kms-v3d" /mnt/round2-bootfs-check/config.txt
check "round2: config.txt (trial) punta ancora al kernel reale" \
    grep -q "^kernel=kernel8.img" /mnt/round2-bootfs-check/config.txt
check "round2: recovery8.img ancora presente (non clobberato dal secondo populate-bootfs)" \
    test -f /mnt/round2-bootfs-check/recovery8.img
umount /mnt/round2-bootfs-check

check "round2: fsck.ext4 pulito su DATA (preservata, non riformattata)" e2fsck -fn "${LOOP}p${DATA_PART}"

log "=== round2: promote-default (secondo boot confermato) ==="
cp "$REPO/kiosk/files/config-extra.txt" /etc/unitotem/config-extra.txt
"${ENGINE[@]}" promote-default --firmware rpi --disk "$LOOP" --bootfs-part "$BOOTFS_PART"
mkdir -p /mnt/round2-promote-check
mount -o ro "${LOOP}p${BOOTFS_PART}" /mnt/round2-promote-check
check "round2: config.txt promosso punta al kernel reale" \
    grep -q "^kernel=kernel8.img" /mnt/round2-promote-check/config.txt
check "round2: config.txt promosso include il dtoverlay KMS" \
    grep -q "dtoverlay=vc4-kms-v3d" /mnt/round2-promote-check/config.txt
check "round2: overlays/vc4-kms-v3d.dtbo ancora presente dopo promote" \
    test -f /mnt/round2-promote-check/overlays/vc4-kms-v3d.dtbo
check "round2: config.txt.unitotem-bak ripulito dopo promote" \
    bash -c '[ ! -f /mnt/round2-promote-check/config.txt.unitotem-bak ]'
umount /mnt/round2-promote-check

log "=== RISULTATI ==="
cat "$RESULTS"
if grep -q '^FAIL' "$RESULTS"; then
    log "ALCUNI CONTROLLI SONO FALLITI"
    exit 1
else
    log "TUTTI I CONTROLLI SONO PASSATI"
fi
