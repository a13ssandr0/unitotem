#!/bin/bash
# Runs INSIDE a privileged throwaway container as root. Exercises the real
# deploy/ota-engine.sh subcommand sequence as run_ota_sequence in deploy/remote-deploy.sh
# drives it over SSH, against a loop device standing in for the target disk. It simulates a
# fresh (non-UniTotem) target, so the full table-recreate + DATA-mkfs path runs, not just a
# same-layout restore.
set -Eeuo pipefail

log() { echo ">>> $*"; }
fail() { echo "!!! FAILED: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Installing the packages needed in the container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    partclone xz-utils util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted \
    socat procps dctrl-tools file grub-common >/dev/null

REPO=/repo
PARTS=/work/parts
TARGET_IMG=/work/target.img
ENGINE=(bash "$REPO/deploy/ota-engine.sh")
RESULTS=/work/results.txt
: > "$RESULTS"

record() { echo "$1" | tee -a "$RESULTS"; }
check() {
    # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/tmp/check.out 2>&1; then
        record "PASS: $desc"
    else
        record "FAIL: $desc -- $(tail -5 /tmp/check.out | tr '\n' '|')"
    fi
}

SIZE_GIB="${TARGET_SIZE_GIB:-16}"
log "Creating a ${SIZE_GIB}GiB target disk (sparse, deliberately larger than the 11GiB source - exercises the size= recalculation of DATA)..."
rm -f "$TARGET_IMG"
truncate -s "${SIZE_GIB}G" "$TARGET_IMG"

LOOP=$(losetup --find --show --partscan "$TARGET_IMG")
log "Loop device: $LOOP"

cleanup() {
    set +e
    umount -lf /mnt/newroot/mnt/data /mnt/newroot/boot/efi /mnt/newroot/boot /mnt/newroot 2>/dev/null
    umount -lf /mnt/ota-bootfs 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# --- parse manifest header -------------------------------------------------
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

# --- probe (empty disk, must not explode) ----------------------------------
log "=== probe (empty disk) ==="
"${ENGINE[@]}" probe --disk "$LOOP" | tee /tmp/probe0.out
check "probe on an empty disk does not report HAVE_UNITOTEM" grep -q 'UNITOTEM_HAVE_UNITOTEM=0' /tmp/probe0.out

# --- stage 1: restore-table + bootfs prep + recovery files + default -------
log "=== Stage 1: table + fallback ==="
TABLE_B64=$(base64 -w0 < "$PARTS/layout.sfdisk")
BOOTCODE_ARG=()
[ -f "$PARTS/bootcode.bin" ] && BOOTCODE_ARG=(--bootcode-b64 "$(base64 -w0 < "$PARTS/bootcode.bin")")
"${ENGINE[@]}" restore-table --disk "$LOOP" --table-b64 "$TABLE_B64" --tail-part "$DATA_PART" "${BOOTCODE_ARG[@]}"

sfdisk --dump "$LOOP" > /tmp/table-after.sfdisk
record "--- restored table (sfdisk --dump) ---"
cat /tmp/table-after.sfdisk | tee -a "$RESULTS"
# sfdisk --dump always reports last-lba for the disk's current geometry. What proves
# last-lba was stripped from the input is that DATA grew to fill the bigger target disk.
# DATA (tail partition) must have grown well past its size in the 11GiB source
data_size_sectors=$(grep -E "${LOOP}p${DATA_PART}[[:space:]]*:" /tmp/table-after.sfdisk | grep -oE 'size=[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
log "DATA size after restore-table: ${data_size_sectors} sectors (~$((data_size_sectors/2048))MiB)"
check "DATA recalculated on the bigger disk (>4GiB in sectors, not the small original size)" \
    bash -c "[ ${data_size_sectors:-0} -gt 8388608 ]"

# The container runs no udevd, so nothing turns the kernel's partition re-read into
# /dev/loopNpM nodes (real targets run udev). The nodes are created with mknod from the
# major:minor in sysfs.
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

"${ENGINE[@]}" prepare-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --fstype vfat --fresh 1 --label EFI

log "Writing the recovery kernel/initrd..."
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-vmlinuz --subdir unitotem \
    < "$REPO/deploy/amd64/recovery-vmlinuz-amd64"
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img --subdir unitotem \
    < "$REPO/deploy/amd64/recovery-initrd-amd64.img"

"${ENGINE[@]}" set-default-recovery --disk "$LOOP" --firmware uefi --bootfs-part "$BOOTFS_PART"
log "Stage 1 complete (barrier passed: from here on a failure must not reboot into a half-written disk)."

# --- stage 2: bootfs file-level content + per-partition restore + DATA -----
log "=== Stage 2: real content ==="
BOOTFS_STREAM=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "$PARTS/parts.manifest")
if [ -n "$BOOTFS_STREAM" ]; then
    log "Populating the file-level content of the boot fs from ${BOOTFS_STREAM}..."
    socat -u "FILE:$PARTS/$BOOTFS_STREAM" "TCP-LISTEN:9700,reuseaddr" &
    NCPID=$!
    sleep 0.5
    "${ENGINE[@]}" populate-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --data-host 127.0.0.1 --data-port 9700
    wait "$NCPID" 2>/dev/null || true
fi

ROOT_PART="" BOOT_PART=""
declare -A BLOCK
process_block() {
    local n="${BLOCK[UNITOTEM_PART]:-}"
    [ -n "$n" ] || return 0
    local label="${BLOCK[UNITOTEM_PART_LABEL]:-}"
    local action="${BLOCK[UNITOTEM_PART_ACTION]:-}"
    case "$label" in
        ROOT) ROOT_PART="$n" ;;
        BOOT) BOOT_PART="$n" ;;
    esac
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
            log "data-op mkfs on partition $n ('new system' path: table recreated -> DATA formatted)"
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

log "ROOT_PART=$ROOT_PART BOOT_PART=$BOOT_PART"
check "ROOT found in the manifest" bash -c "[ -n '$ROOT_PART' ]"

# --- mount-target / populate-real-kernel(skip amd64) / migrate-etc-overlay -
log "=== mount-target ==="
MOUNT_ARGS=(--disk "$LOOP" --arch amd64 --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART")
[ -n "$BOOT_PART" ] && MOUNT_ARGS+=(--boot-part "$BOOT_PART")
"${ENGINE[@]}" mount-target "${MOUNT_ARGS[@]}"

check "mounted ROOT has /sbin/init or systemd" bash -c '[ -x /mnt/newroot/sbin/init ] || [ -x /mnt/newroot/usr/lib/systemd/systemd ]'
check "mounted ROOT has /etc/unitotem (UniTotem marker)" test -d /mnt/newroot/etc/unitotem
check "BOOT/ESP mounted under /boot/efi has grub" test -d /mnt/newroot/boot/efi/EFI

check "unitotem-ota-changes installed" test -x /mnt/newroot/usr/sbin/unitotem-ota-changes
check "baseline generated by stage3" test -s /mnt/newroot/usr/lib/unitotem/baseline/packages
check "baseline: manifest of unowned files is not empty" \
    test -s /mnt/newroot/usr/lib/unitotem/baseline/unowned.sha256
# The exact number varies, but a wrong order of magnitude means a broken usr-merge
# normalization: without it the "unowned" files double.
check "baseline: plausible count of unowned files (<6000)" \
    bash -c '[ "$(wc -l < /mnt/newroot/usr/lib/unitotem/baseline/unowned.sha256)" -lt 6000 ]'
check "baseline: the manifest does not list itself" \
    bash -c "! grep -q '/usr/lib/unitotem/baseline/' /mnt/newroot/usr/lib/unitotem/baseline/unowned.sha256"
check "the overlay hook pins /var/lib/dpkg to ROOT" \
    grep -q 'dpkg_pin' /mnt/newroot/etc/initramfs-tools/scripts/init-bottom/setup-overlays
check "automatic apt timers masked" \
    bash -c 'ls -l /mnt/newroot/etc/systemd/system/apt-daily.timer 2>/dev/null | grep -q /dev/null'
check "unitotem-maintenance stops the real services, not sway" \
    bash -c "grep -q 'start-xorg.service' /mnt/newroot/usr/local/bin/unitotem-maintenance && ! grep -qE '^[^#]*pkill -x sway' /mnt/newroot/usr/local/bin/unitotem-maintenance"

# The image's suite and its sources.list must agree: otherwise apt proposes a half-downgrade
# in maintenance mode.
check "the amd64 image is Debian 13 (trixie)" \
    grep -q "VERSION_CODENAME=trixie" /mnt/newroot/etc/os-release
check "the image's sources.list point to trixie, not bookworm" \
    bash -c "grep -q ' trixie ' /mnt/newroot/etc/apt/sources.list && ! grep -q bookworm /mnt/newroot/etc/apt/sources.list"
check "no backports leftover in the image" \
    bash -c "! ls /mnt/newroot/etc/apt/sources.list.d/backports.list >/dev/null 2>&1"

# --- amd64 video drivers: the image must drive NVIDIA, AMD and Intel (ARC included)
# without knowing the machine in advance. Each check covers a piece whose absence would
# otherwise show up only as a black screen on that hardware.
check "kernel 6.12+ (needed by ARC)" \
    bash -c 'ls /mnt/newroot/lib/modules/ | grep -qE "^6\\.(1[2-9]|[2-9][0-9])"'
check "Mesa 25.x (iris/ANV per DG2, RDNA3)" \
    bash -c 'chroot /mnt/newroot dpkg-query -W -f="\${Version}" libgl1-mesa-dri 2>/dev/null | grep -q "^25\\."'
check "NVIDIA module built by DKMS in the image" \
    bash -c 'ls /mnt/newroot/lib/modules/*/updates/dkms/nvidia-current.ko* >/dev/null 2>&1'
check "NVIDIA X driver present" \
    bash -c 'ls /mnt/newroot/usr/lib/xorg/modules/drivers/nvidia_drv.so >/dev/null 2>&1'
check "VAAPI su NVDEC (nvidia-vaapi-driver)" \
    bash -c 'ls /mnt/newroot/usr/lib/x86_64-linux-gnu/dri/nvidia_drv_video.so >/dev/null 2>&1'
check "Intel iHD VAAPI driver (covers ARC/DG2)" \
    test -e /mnt/newroot/usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so
check "AMD VAAPI driver (radeonsi via mesa-va-drivers)" \
    test -e /mnt/newroot/usr/lib/x86_64-linux-gnu/dri/radeonsi_drv_video.so
check "amdgpu X driver present" \
    test -e /mnt/newroot/usr/lib/xorg/modules/drivers/amdgpu_drv.so
check "GPU firmware is current (2025, not 2023)" \
    bash -c 'chroot /mnt/newroot dpkg-query -W -f="\${Version}" firmware-amd-graphics 2>/dev/null | grep -q "^2025"'

# Same packaging checks as on the arm64 side: fstab-amd64 and fstab-arm64 are separate files.
# The overlay hook is shared by both architectures.
check "the overlay hook also covers /var" \
    grep -qE 'for d in etc root var' /mnt/newroot/etc/initramfs-tools/scripts/init-bottom/setup-overlays
check "fstab does not mount tmpfs on /var/lib/* (it would mask the overlay)" \
    bash -c "! grep -qE '^tmpfs[[:space:]]+/var/lib/' /mnt/newroot/etc/fstab"
check "fstab keeps /var/cache and /var/tmp on tmpfs (disk wear)" \
    bash -c "grep -qE '^tmpfs[[:space:]]+/var/cache' /mnt/newroot/etc/fstab && grep -qE '^tmpfs[[:space:]]+/var/tmp' /mnt/newroot/etc/fstab"
check "journald asks for persistent storage" \
    bash -c "grep -rqs '^Storage=persistent' /mnt/newroot/etc/systemd/journald.conf.d/"

DATA_MNT=/mnt/newroot/mnt/data
mkdir -p "$DATA_MNT/upper/etc/cron.d" "$DATA_MNT/upper/var/lib/dpkg"
echo "old-db" > "$DATA_MNT/upper/var/lib/dpkg/status"
echo "replace-me" > "$DATA_MNT/upper/etc/cron.d/foreign"

"${ENGINE[@]}" migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data

check "migrate: upper/var cleared (no dpkg state of the old image)" \
    bash -c "! test -e '$DATA_MNT/upper/var/lib/dpkg/status'"
check "migrate: the old /var is archived in history, not lost" \
    bash -c "ls '$DATA_MNT'/history/*/var/lib/dpkg/status >/dev/null 2>&1"
check "migrate: /etc file not in the whitelist is NOT re-imported" \
    bash -c "! test -e '$DATA_MNT/upper/etc/cron.d/foreign'"

log "=== set-trial-boot (uefi, chroot into the freshly written target) ==="
"${ENGINE[@]}" set-trial-boot --firmware uefi --target /mnt/newroot
check "trial grub entry created" test -f /mnt/newroot/etc/grub.d/99_unitotem_trial
check "regenerated grub.cfg mentions 'UniTotem (trial)'" grep -q 'UniTotem (trial)' /mnt/newroot/boot/grub/grub.cfg
check "grubenv points to the trial as next entry" bash -c "grub-editenv /mnt/newroot/boot/grub/grubenv list 2>/dev/null | grep -q 'next_entry=.*UniTotem (trial)'"

# --- verify recovery files were NOT clobbered by stage 2's bootfs populate -
# bootfs is already mounted by mount-target at /mnt/newroot/boot/efi; read it from there.
log "=== verify: the recovery files survive the stage 2 populate-bootfs ==="
BOOTFS_MNT=/mnt/newroot/boot/efi
check "recovery-vmlinuz still present" test -f "$BOOTFS_MNT/unitotem/recovery-vmlinuz"
check "recovery-initrd.img still present" test -f "$BOOTFS_MNT/unitotem/recovery-initrd.img"
got_vmlinuz_sha=$(sha256sum "$BOOTFS_MNT/unitotem/recovery-vmlinuz" | cut -d' ' -f1)
got_initrd_sha=$(sha256sum "$BOOTFS_MNT/unitotem/recovery-initrd.img" | cut -d' ' -f1)
exp_vmlinuz_sha=$(awk -F= '/UNITOTEM_RECOVERY_VMLINUZ_SHA256/{print $2}' "$REPO/deploy/amd64/recovery.manifest")
exp_initrd_sha=$(awk -F= '/UNITOTEM_RECOVERY_INITRD_SHA256/{print $2}' "$REPO/deploy/amd64/recovery.manifest")
record "recovery-vmlinuz sha256: got=${got_vmlinuz_sha} expected=${exp_vmlinuz_sha}"
check "recovery-vmlinuz sha256 correct (re-read from disk)" bash -c "[ '$got_vmlinuz_sha' = '$exp_vmlinuz_sha' ]"
record "recovery-initrd.img sha256: got=${got_initrd_sha} expected=${exp_initrd_sha}"
check "recovery-initrd.img sha256 correct (re-read from disk)" bash -c "[ '$got_initrd_sha' = '$exp_initrd_sha' ]"
check "BOOTX64.EFI present (populated by stage 2 at file level, does not clobber unitotem/)" test -f "$BOOTFS_MNT/EFI/BOOT/BOOTX64.EFI"
check "default-recovery grub.cfg still present and points to the fallback" grep -q "recovery-vmlinuz" "$BOOTFS_MNT/grub/grub.cfg"

log "=== umount-target ==="
"${ENGINE[@]}" umount-target

# --- cold fsck of every restored partition ---------------------------------
log "=== cold fsck ==="
check "fsck.ext4 clean on ROOT" e2fsck -fn "${LOOP}p${ROOT_PART}"
[ -n "$BOOT_PART" ] && check "fsck.ext4 clean on BOOT" e2fsck -fn "${LOOP}p${BOOT_PART}"
check "fsck.vfat clean on bootfs (EFI)" fsck.vfat -n "${LOOP}p${BOOTFS_PART}"
check "fsck.ext4 clean on DATA (just formatted)" e2fsck -fn "${LOOP}p${DATA_PART}"
check "DATA label correct" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p${DATA_PART})\" = DATA ]"

# --- promote-default: chroot into the target, as unitotem-boot-ok.service does after a
# confirmed boot of the real system.
log "=== promote-default (simulating a confirmed boot) ==="
"${ENGINE[@]}" mount-target "${MOUNT_ARGS[@]}"
cp "$REPO/deploy/ota-engine.sh" /mnt/newroot/tmp/ota-engine.sh
mount --bind /dev  /mnt/newroot/dev
mount --bind /proc /mnt/newroot/proc
mount --bind /sys  /mnt/newroot/sys
chroot /mnt/newroot bash /tmp/ota-engine.sh promote-default --firmware uefi
umount -lf /mnt/newroot/dev /mnt/newroot/proc /mnt/newroot/sys
check "trial entry removed after promote-default" bash -c '[ ! -f /mnt/newroot/etc/grub.d/99_unitotem_trial ]'
check "regenerated grub.cfg no longer mentions the trial after promote" bash -c '! grep -q "UniTotem (trial)" /mnt/newroot/boot/grub/grub.cfg'
rm -f /mnt/newroot/tmp/ota-engine.sh
"${ENGINE[@]}" umount-target

log "=== RESULTS ==="
cat "$RESULTS"
if grep -q '^FAIL' "$RESULTS"; then
    log "SOME CHECKS FAILED"
    exit 1
else
    log "ALL CHECKS PASSED"
fi
