#!/bin/bash
# arm64 counterpart of inside.sh: the same loopback verification, exercising the arm64-specific
# paths: --firmware rpi/rpi-tryboot, --arch arm64 mount-target (no --boot-part, no separate BOOT
# partition), and populate-real-kernel (the Pi firmware reads kernel8.img/initramfs8/dtbs from
# the FAT firmware partition, never from ROOT).
set -Eeuo pipefail

log() { echo ">>> $*"; }
fail() { echo "!!! FAILED: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Installing the packages needed in the container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    partclone xz-utils util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted \
    socat procps dctrl-tools file device-tree-compiler iproute2 pv >/dev/null

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
log "Creating a ${SIZE_GIB}GiB target disk (sparse, deliberately larger than the 11GiB source)..."
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

log "=== probe (empty disk) ==="
"${ENGINE[@]}" probe --disk "$LOOP" | tee /tmp/probe0.out
check "probe on an empty disk does not report HAVE_UNITOTEM" grep -q 'UNITOTEM_HAVE_UNITOTEM=0' /tmp/probe0.out

log "=== Stage 1: table + fallback ==="
TABLE_B64=$(base64 -w0 < "$PARTS/layout.sfdisk")
BOOTCODE_ARG=()
[ -f "$PARTS/bootcode.bin" ] && BOOTCODE_ARG=(--bootcode-b64 "$(base64 -w0 < "$PARTS/bootcode.bin")")
"${ENGINE[@]}" restore-table --disk "$LOOP" --table-b64 "$TABLE_B64" --tail-part "$DATA_PART" "${BOOTCODE_ARG[@]}"

sfdisk --dump "$LOOP" > /tmp/table-after.sfdisk
record "--- restored table (sfdisk --dump) ---"
cat /tmp/table-after.sfdisk | tee -a "$RESULTS"
data_size_sectors=$(grep -E "${LOOP}p${DATA_PART}[[:space:]]*:" /tmp/table-after.sfdisk | grep -oE 'size=[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
log "DATA size after restore-table: ${data_size_sectors} sectors (~$((data_size_sectors/2048))MiB)"
check "DATA recalculated on the bigger disk (>4GiB in sectors)" \
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

log "Writing the recovery kernel/initrd (arm64: recovery8.img/recovery-initrd.img, no subdir)..."
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery8.img \
    < "$REPO/deploy/arm64/recovery-vmlinuz-arm64"
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img \
    < "$REPO/deploy/arm64/recovery-initrd-arm64.img"

"${ENGINE[@]}" set-default-recovery --disk "$LOOP" --firmware rpi --bootfs-part "$BOOTFS_PART"
log "Stage 1 complete."

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
            log "data-op mkfs on partition $n ('new system' path)"
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
check "ROOT found in the manifest" bash -c "[ -n '$ROOT_PART' ]"

log "=== mount-target (arch arm64, no separate boot-part) ==="
"${ENGINE[@]}" mount-target --disk "$LOOP" --arch arm64 --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART"

check "mounted ROOT has /sbin/init or systemd" bash -c '[ -x /mnt/newroot/sbin/init ] || [ -x /mnt/newroot/usr/lib/systemd/systemd ]'
check "mounted ROOT has /etc/unitotem (UniTotem marker)" test -d /mnt/newroot/etc/unitotem
check "firmware mounted under /boot/firmware" test -d /mnt/newroot/boot/firmware

# Rescue-path content, which exists only inside the built image: a last-resort NetworkManager
# profile (IPv6 stays up on an interface with no connection), IPv6 filtering that matches IPv4,
# and the serial console on ttyS0.
check "last-resort NM profile present" \
    test -f /mnt/newroot/etc/NetworkManager/system-connections/unitotem-fallback.nmconnection
check "NM profile has mode 600 (NetworkManager refuses others)" \
    bash -c '[ "$(stat -c %a /mnt/newroot/etc/NetworkManager/system-connections/unitotem-fallback.nmconnection)" = 600 ]'
check "NM profile also does DHCP (not only link-local, otherwise no network)" \
    grep -q "^method=auto" /mnt/newroot/etc/NetworkManager/system-connections/unitotem-fallback.nmconnection
check "network watchdog installed" test -x /mnt/newroot/usr/sbin/unitotem-net-watchdog
check "watchdog timer enabled" \
    bash -c 'ls /mnt/newroot/etc/systemd/system/timers.target.wants/unitotem-net-watchdog.timer >/dev/null 2>&1'
check "firewall also covers IPv6" grep -q "ip6tables -P INPUT   DROP" /mnt/newroot/sbin/iptables-firewall.sh
check "firewall accepts ICMPv6 (without it IPv6 does not work at all)" \
    grep -q "ip6tables -A INPUT -p ipv6-icmp -j ACCEPT" /mnt/newroot/sbin/iptables-firewall.sh

# Packaging checks for the /var overlay: an fstab tmpfs would mask the overlay underneath it.
check "the overlay hook also covers /var" \
    grep -qE 'for d in etc root var' /mnt/newroot/etc/initramfs-tools/scripts/init-bottom/setup-overlays
check "fstab does not mount tmpfs on /var/lib/* (it would mask the overlay)" \
    bash -c "! grep -qE '^tmpfs[[:space:]]+/var/lib/' /mnt/newroot/etc/fstab"
check "fstab keeps /var/cache and /var/tmp on tmpfs (SD wear)" \
    bash -c "grep -qE '^tmpfs[[:space:]]+/var/cache' /mnt/newroot/etc/fstab && grep -qE '^tmpfs[[:space:]]+/var/tmp' /mnt/newroot/etc/fstab"
# The drop-in, not journald.conf: stage2 does not overwrite the system file.
check "journald asks for persistent storage" \
    bash -c "grep -rqs '^Storage=persistent' /mnt/newroot/etc/systemd/journald.conf.d/"

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

log "=== populate-real-kernel (arm64 only) ==="
"${ENGINE[@]}" populate-real-kernel
check "kernel8.img (real system) written to firmware" test -f /mnt/newroot/boot/firmware/kernel8.img
check "initramfs8 (real system) written to firmware" test -f /mnt/newroot/boot/firmware/initramfs8
check "the real system's kernel8.img is a valid arm64 Image (raw ARMd or gzip)" \
    bash -c 'k=/mnt/newroot/boot/firmware/kernel8.img; [ "$(dd if="$k" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d " \n")" = "1f8b" ] || [ "$(dd if="$k" bs=1 skip=56 count=4 2>/dev/null)" = "ARMd" ]'
check "at least one bcm27* dtb copied to the firmware" bash -c 'ls /mnt/newroot/boot/firmware/bcm27*.dtb >/dev/null 2>&1'

log "=== migrate-etc-overlay ==="
# Seeded markers cover three behaviours: a whitelisted /etc path must come back, a
# non-whitelisted one must NOT (the new image's /etc wins), and the whole /var upper must be
# archived and reset so the previous image's dpkg database does not shadow the new one.
DATA_MNT=/mnt/newroot/mnt/data
mkdir -p "$DATA_MNT/upper/etc/NetworkManager/system-connections" \
         "$DATA_MNT/upper/etc/cron.d" \
         "$DATA_MNT/upper/var/lib/dpkg" \
         "$DATA_MNT/upper/var/log"
echo "keep-me" > "$DATA_MNT/upper/etc/NetworkManager/system-connections/test.nmconnection"
echo "replace-me" > "$DATA_MNT/upper/etc/cron.d/foreign"
echo "old-db" > "$DATA_MNT/upper/var/lib/dpkg/status"
echo "old-log" > "$DATA_MNT/upper/var/log/old.log"

"${ENGINE[@]}" migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data

check "migrate: NetworkManager profile re-imported from the whitelist" \
    test -f "$DATA_MNT/upper/etc/NetworkManager/system-connections/test.nmconnection"
check "migrate: /etc file not in the whitelist is NOT re-imported" \
    bash -c "! test -e '$DATA_MNT/upper/etc/cron.d/foreign'"
check "migrate: upper/var cleared (no dpkg state of the old image)" \
    bash -c "! test -e '$DATA_MNT/upper/var/lib/dpkg/status'"
check "migrate: upper/var still exists, ready for the next boot" \
    test -d "$DATA_MNT/upper/var"
check "migrate: the old /var is archived in history, not lost" \
    bash -c "ls '$DATA_MNT'/history/*/var/log/old.log >/dev/null 2>&1"
check "migrate: the old /etc is archived in history too" \
    bash -c "ls '$DATA_MNT'/history/*/etc/cron.d/foreign >/dev/null 2>&1"

log "=== set-trial-boot (rpi-tryboot) ==="
"${ENGINE[@]}" set-trial-boot --firmware rpi-tryboot --disk "$LOOP" --bootfs-part "$BOOTFS_PART"

log "=== verify: the recovery files and the real system's kernel8.img coexist without clobbering ==="
BOOTFS_MNT=/mnt/newroot/boot/firmware
check "recovery8.img still present" test -f "$BOOTFS_MNT/recovery8.img"
check "recovery-initrd.img still present" test -f "$BOOTFS_MNT/recovery-initrd.img"
got_vmlinuz_sha=$(sha256sum "$BOOTFS_MNT/recovery8.img" | cut -d' ' -f1)
got_initrd_sha=$(sha256sum "$BOOTFS_MNT/recovery-initrd.img" | cut -d' ' -f1)
exp_vmlinuz_sha=$(awk -F= '/UNITOTEM_RECOVERY_VMLINUZ_SHA256/{print $2}' "$REPO/deploy/arm64/recovery.manifest")
exp_initrd_sha=$(awk -F= '/UNITOTEM_RECOVERY_INITRD_SHA256/{print $2}' "$REPO/deploy/arm64/recovery.manifest")
record "recovery8.img sha256: got=${got_vmlinuz_sha} expected=${exp_vmlinuz_sha}"
check "recovery8.img sha256 correct (re-read from disk)" bash -c "[ '$got_vmlinuz_sha' = '$exp_vmlinuz_sha' ]"
record "recovery-initrd.img sha256: got=${got_initrd_sha} expected=${exp_initrd_sha}"
check "recovery-initrd.img sha256 correct (re-read from disk)" bash -c "[ '$got_initrd_sha' = '$exp_initrd_sha' ]"
check "default-recovery config.txt still present and points to the fallback" grep -q "recovery8.img" "$BOOTFS_MNT/config.txt"
check "tryboot.txt written and points to the real kernel" grep -q "kernel8.img" "$BOOTFS_MNT/tryboot.txt"
check "cmdline-trial.txt written" test -f "$BOOTFS_MNT/cmdline-trial.txt"
# ttyS0, not ttyS1: linux-image-rpi-v8 brings Raspberry Pi's own DTBs, which alias serial0 to
# the mini-UART on the GPIO header. A wrong value fails silently (nothing on serial).
check "trial cmdline uses ttyS0 (Raspberry DTBs), not ttyS1" \
    grep -q "console=ttyS0,115200" "$BOOTFS_MNT/cmdline-trial.txt"
# Check of the config-extra.txt splice (append_config_extra in deploy/ota-engine.sh):
# set-trial-boot's rpi-tryboot branch reads /mnt/newroot/etc/unitotem/config-extra.txt (real
# content on the restored ROOT, installed by unitotem/stage2-configure.sh), and
# dtoverlay=vc4-kms-v3d must end up in tryboot.txt, otherwise KMS is never enabled.
check "tryboot.txt includes the KMS dtoverlay (config-extra.txt)" grep -q "dtoverlay=vc4-kms-v3d" "$BOOTFS_MNT/tryboot.txt"

log "=== umount-target ==="
"${ENGINE[@]}" umount-target

log "=== cold fsck ==="
check "fsck.ext4 clean on ROOT" e2fsck -fn "${LOOP}p${ROOT_PART}"
check "fsck.vfat clean on bootfs (FIRMWARE)" fsck.vfat -n "${LOOP}p${BOOTFS_PART}"
check "fsck.ext4 clean on DATA (just formatted)" e2fsck -fn "${LOOP}p${DATA_PART}"
check "DATA label correct" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p${DATA_PART})\" = DATA ]"

log "=== promote-default (simulating a confirmed boot, rpi needs no chroot) ==="
# promote-default runs after boot on the real system's own /. This container is that "/" (no
# chroot), so /etc/unitotem/config-extra.txt is staged as stage2-configure.sh installs it;
# append_config_extra treats a missing file as nothing to add, which would hide a regression.
mkdir -p /etc/unitotem
cp "$REPO/unitotem/files/config-extra.txt" /etc/unitotem/config-extra.txt
"${ENGINE[@]}" promote-default --firmware rpi --disk "$LOOP" --bootfs-part "$BOOTFS_PART"
mkdir -p /mnt/ota-promote-check
mount -t vfat -o ro "${LOOP}p${BOOTFS_PART}" /mnt/ota-promote-check
check "promoted config.txt points to the real kernel (no longer recovery)" grep -q "^kernel=kernel8.img" /mnt/ota-promote-check/config.txt
check "promoted config.txt includes the KMS dtoverlay (config-extra.txt)" grep -q "dtoverlay=vc4-kms-v3d" /mnt/ota-promote-check/config.txt
# Both are in Raspberry Pi OS's config.txt; without them the picture is inset by black bands.
# They arrive through config-extra.txt, so this also proves the splice carries more than the
# dtoverlay line.
check "promoted config.txt disables the firmware KMS setup" \
    grep -q "^disable_fw_kms_setup=1" /mnt/ota-promote-check/config.txt
check "promoted config.txt disables overscan" \
    grep -q "^disable_overscan=1" /mnt/ota-promote-check/config.txt
# Pi 3 is a deploy target (see remote-deploy.sh's model check); without a [pi3] section KMS is
# never enabled there and the board runs on the firmware framebuffer with software rendering.
check "promoted config.txt enables KMS on Pi 3 too" \
    grep -q "^\[pi3\]" /mnt/ota-promote-check/config.txt
check "tryboot.txt removed after promote-default" bash -c '[ ! -f /mnt/ota-promote-check/tryboot.txt ]'
check "cmdline-trial.txt removed after promote-default" bash -c '[ ! -f /mnt/ota-promote-check/cmdline-trial.txt ]'
check "recovery8.img still present after promote (never deleted)" test -f /mnt/ota-promote-check/recovery8.img
umount /mnt/ota-promote-check

log "=== ROUND 2: redeploy onto an ALREADY provisioned target (recreate_table=0) ==="
# Round 1 above provisions an empty disk (recreate_table=1) by calling ota-engine.sh
# subcommands directly; it never drives the orchestration in deploy/remote-deploy.sh
# (run_ota_sequence), which decides which subcommands to call and when. This round covers the
# recreate_table=0 path, the everyday update of an already-provisioned device: it reuses the
# same loop device, already provisioned and promoted by round 1, and drives the REAL
# run_ota_sequence(), extracted from the current deploy/remote-deploy.sh on every run.

log "Emptying overlays/ before round 2 (otherwise the check would pass on round 1 leftovers)..."
mkdir -p /mnt/round2-bootfs-check
mount -o rw "${LOOP}p${BOOTFS_PART}" /mnt/round2-bootfs-check
rm -rf /mnt/round2-bootfs-check/overlays
sync
umount /mnt/round2-bootfs-check

# run_ota_sequence calls die/serve_file_once/wait_port_bound/read_kv_block from deploy/lib.sh,
# which round 1 does not need.
source "$REPO/deploy/lib.sh"
sed -n '/^run_ota_sequence()/,/^}/p' "$REPO/deploy/remote-deploy.sh" > /tmp/run_ota_sequence.sh
check "run_ota_sequence() extracted from remote-deploy.sh" test -s /tmp/run_ota_sequence.sh
source /tmp/run_ota_sequence.sh

# run_ota_sequence reaches "the target" only through ota_ssh/ota_ssh_send (deploy/lib.sh, SSH
# normally). Here the target is this container, so the command is eval'd directly. A real system
# resolves "unitotem-ota-engine" via PATH; a shell function of that name does the same without a
# writable PATH directory. The final `reboot -f` is intercepted: a --privileged container could
# really reboot the Docker host, and the test only verifies what was written to disk.
unitotem-ota-engine() { bash "$REPO/deploy/ota-engine.sh" "$@"; }
ota_ssh() {
    local _h="$1"; shift
    case "$1" in
        *reboot*) log "(round 2: reboot intercepted, not executed - '$1')" ;;
        *) eval "$1" ;;
    esac
}
ota_ssh_send() { local _h="$1"; shift; eval "$1"; }

# run_ota_sequence locates the recovery kernel/initrd through ${DIR}/deploy/${ARCH}/...; $DIR is
# remote-deploy.sh's repo-root variable, assigned outside the extracted function, so it is set here.
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
log "Round 2: run_ota_sequence complete."

mkdir -p /mnt/round2-bootfs-check
mount -o ro "${LOOP}p${BOOTFS_PART}" /mnt/round2-bootfs-check
check "round2: overlays/ repopulated on an already provisioned target (recreate_table=0)" \
    test -f /mnt/round2-bootfs-check/overlays/vc4-kms-v3d.dtbo
check "round2: config.txt (trial, rpi-legacy) includes the KMS dtoverlay" \
    grep -q "dtoverlay=vc4-kms-v3d" /mnt/round2-bootfs-check/config.txt
check "round2: config.txt (trial) still points to the real kernel" \
    grep -q "^kernel=kernel8.img" /mnt/round2-bootfs-check/config.txt
check "round2: recovery8.img still present (not clobbered by the second populate-bootfs)" \
    test -f /mnt/round2-bootfs-check/recovery8.img
umount /mnt/round2-bootfs-check

check "round2: fsck.ext4 clean on DATA (preserved, not reformatted)" e2fsck -fn "${LOOP}p${DATA_PART}"

# Guards for stdin handling. ota_ssh runs inside `while read_kv_block ... done < parts.manifest`;
# ssh without -n would forward the caller's stdin and eat the rest of the manifest, so the DATA
# block would be skipped. Round 2 mocks ota_ssh with a plain eval, which cannot show this, so the
# two protections are asserted directly. grep -F: the pattern contains ${...}, which a BRE
# would silently fail to match.
check "guard: run_ota_sequence reads the manifest on fd 9, not stdin" \
    grep -qF 'done 9< "${OPT_PARTS}/parts.manifest"' /tmp/run_ota_sequence.sh
check "guard: ota_ssh passes -n (does not consume the caller's stdin)" \
    grep -qF '_ota_ssh_exec -n "$OTA_AUTH_TARGET"' "$REPO/deploy/lib.sh"

log "=== round2: promote-default (second confirmed boot) ==="
cp "$REPO/unitotem/files/config-extra.txt" /etc/unitotem/config-extra.txt
"${ENGINE[@]}" promote-default --firmware rpi --disk "$LOOP" --bootfs-part "$BOOTFS_PART"
mkdir -p /mnt/round2-promote-check
mount -o ro "${LOOP}p${BOOTFS_PART}" /mnt/round2-promote-check
check "round2: promoted config.txt points to the real kernel" \
    grep -q "^kernel=kernel8.img" /mnt/round2-promote-check/config.txt
check "round2: promoted config.txt includes the KMS dtoverlay" \
    grep -q "dtoverlay=vc4-kms-v3d" /mnt/round2-promote-check/config.txt
check "round2: overlays/vc4-kms-v3d.dtbo still present after promote" \
    test -f /mnt/round2-promote-check/overlays/vc4-kms-v3d.dtbo
check "round2: config.txt.unitotem-bak cleaned up after promote" \
    bash -c '[ ! -f /mnt/round2-promote-check/config.txt.unitotem-bak ]'
umount /mnt/round2-promote-check

log "=== RESULTS ==="
cat "$RESULTS"
if grep -q '^FAIL' "$RESULTS"; then
    log "SOME CHECKS FAILED"
    exit 1
else
    log "ALL CHECKS PASSED"
fi
