#!/bin/bash
# Shared OTA engine: every operation deploy/remote-deploy.sh needs on a target, as subcommands driven over SSH
# (control channel); bulk partition data is pulled over plain netcat (data channel). CLI: docs/system/deploy-and-recovery.md.
# Runs in the resident fallback initrd and the system's own initramfs; each subcommand takes --disk, so it also
# works standalone on a loop device. Only init-premount/serve-fallback/local-bottom-verify assume an initramfs.
# Bash, not dash: needs pipefail, /dev/tcp and process substitution (the initrd carries bash, see unitotem/files/ota-hook).
set -Eeuo pipefail
. /scripts/functions 2>/dev/null || true   # only present inside an initramfs

# stderr, never stdout: several callers capture a function's output via $(...) (configure_networking_ota's
# returned IP, cmd_probe's KEY=VALUE lines), which a log()/warn() must not leak into.
# kmsg LINE: into the kernel log at debug level (<7>): readable with dmesg, never printed on the console/screen.
kmsg() { printf '<7>%s\n' "$*" > /dev/kmsg 2>/dev/null || true; }
log()  { echo "unitotem-ota: $*" >&2; kmsg "unitotem-ota: $*"; }
warn() { log "WARNING: $*"; }

# ---------------------------------------------------------------------------
# Device helpers
# ---------------------------------------------------------------------------
pdev_target() {
    case "$1" in
        *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
        *)                      echo "${1}${2}" ;;
    esac
}

partnum_of() { printf '%s\n' "${1##*[!0-9]}"; }

# Mount a boot-fs device for writing, tolerating it already being mounted read-only elsewhere (on the resident
# fallback /boot-ota stays mounted ro for the whole session). A plain `mount -t vfat` silently comes up
# read-only when the same block device is already mounted ro, so the existing mount is remounted rw and
# bind-mounted to the caller's path.
ota_mount_bootfs_rw() {
    local dev="$1" mnt="$2" existing
    mkdir -p "$mnt"
    mountpoint -q "$mnt" && { mount -o remount,rw "$mnt" 2>/dev/null || true; return 0; }
    existing=$(awk -v d="$dev" '$1==d{print $2; exit}' /proc/mounts)
    if [ -n "$existing" ]; then
        mount -o remount,rw "$existing" || fail "remount rw of $existing ($dev) failed"
        mount --bind "$existing" "$mnt" || fail "bind-mount of $existing on $mnt failed"
    else
        mount -t vfat "$dev" "$mnt" || fail "mount of bootfs ($dev) failed"
    fi
}

# Companion to ota_mount_bootfs_rw: unmount the caller's path, and put a remaining mount of the device
# (the persistent /boot-ota reader) back to read-only.
ota_umount_bootfs_rw() {
    local dev="$1" mnt="$2" existing
    umount "$mnt" 2>/dev/null || true
    existing=$(awk -v d="$dev" '$1==d{print $2; exit}' /proc/mounts)
    [ -n "$existing" ] && mount -o remount,ro "$existing" 2>/dev/null || true
}

# The root slot is mounted read-only, so the boot-time check must not write either (an `e2fsck -fy` would
# rewrite the superblock on every boot). Look first; only if that finds something let preen make the safe
# repairs, then judge again. Anything still wrong goes to the fallback, where a person decides.
check_root_readonly() {
    local dev="$1" rc=0
    e2fsck -fn "$dev" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    warn "read-only check of $dev: rc=$rc, trying the safe repair (preen)"
    e2fsck -fp "$dev" >/dev/null 2>&1 || true
    e2fsck -fn "$dev" >/dev/null 2>&1
}

run_e2fsck() {
    local rc=0
    e2fsck -fy "$1" || rc=$?
    [ "$rc" -lt 4 ] || fail "e2fsck found uncorrected errors on $1 (rc=$rc)"
}

resolve_disk() {
    local path="$1" tries=0 resolved
    while [ ! -e "$path" ] && [ "$tries" -lt 30 ]; do
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 1
        tries=$((tries + 1))
    done
    [ -e "$path" ] || fail "device not found: $path"
    resolved=$(readlink -f "$path")
    tries=0
    while [ ! -b "$resolved" ] && [ "$tries" -lt 15 ]; do
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 1
        tries=$((tries + 1))
    done
    [ -b "$resolved" ] || fail "device not ready after resolution: $resolved (from $path)"
    echo "$resolved"
}

# KEY=VALUE lines, blank-line terminated, whitelisted keys and value charset. Used for local files only (flag
# file, unitotem-ota.conf, parts.manifest); the flag file's content is written by the arming host.
read_kv_lines() {
    local line key val
    while IFS= read -r line; do
        [ -z "$line" ] && break
        key=${line%%=*}
        val=${line#*=}
        case "$key" in
            UNITOTEM_*|OTA_*)
                case "$val" in *[!A-Za-z0-9_./:=+-]*) continue ;; esac
                eval "$key=\"\$val\""
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Before the partition table is rewritten a failure can roll back to whatever booted this initrd; afterwards
# there is nothing to roll back to, so fail() never reboots: it drops into the fallback console.
# ---------------------------------------------------------------------------
DEBUG="${UNITOTEM_OTA_DEBUG:-0}"
# Newest DATA/history entries kept by migrate-etc-overlay; older ones are deleted.
HISTORY_KEEP=10
# Kept in /run (not a shell variable) because restore-table and restore-part run as separate invocations of
# this script.
NO_RETURN_MARKER=/run/unitotem-ota-point-of-no-return
mark_point_of_no_return() { : > "$NO_RETURN_MARKER"; }
past_point_of_no_return() { [ -f "$NO_RETURN_MARKER" ]; }

fail() {
    log "ERROR: $*"
    if [ "$DEBUG" = 1 ]; then
        log "debug=1: emergency shell (no automatic action)"
        setsid sh -c 'exec sh </dev/console >/dev/console 2>&1' || true
        exit 1
    fi
    if past_point_of_no_return; then
        log "Error after writing the partition table: not rebooting into a half-written disk."
        cmd_serve_fallback --reason "error: $*"
        exit 1
    fi
    log "Error before writing to the disk: no persistent change to undo."
    exit 1
}
trap 'fail "unexpected error at line $LINENO"' ERR

# ---------------------------------------------------------------------------
# Argument parsing: every subcommand takes --long-opt value pairs.
# ---------------------------------------------------------------------------
declare -A ARG
parse_args() {
    ARG=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --*) ARG["${1#--}"]="${2:-}"; shift 2 ;;
            *) fail "unrecognized argument: $1" ;;
        esac
    done
}
need() { [ -n "${ARG[$1]:-}" ] || fail "--$1 required"; }

# ---------------------------------------------------------------------------
# probe: facts about the current target, printed as KEY=VALUE for remote-deploy.sh to parse.
# ---------------------------------------------------------------------------
cmd_probe() {
    parse_args "$@"
    local disk="" root_dev root_puuid data_dev fw_dev

    if [ -n "${ARG[disk]:-}" ]; then
        disk=$(resolve_disk "${ARG[disk]}")
    fi

    echo "UNITOTEM_ENGINE_VERSION=1"
    echo "UNITOTEM_ARCH_HOST=$(uname -m)"
    [ -d /sys/firmware/efi ] && echo "UNITOTEM_EFI=1" || echo "UNITOTEM_EFI=0"
    local sbv=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c sbx
    if [ -r "$sbv" ]; then sbx=$(od -An -tu1 -j4 -N1 "$sbv" 2>/dev/null | tr -d ' '); echo "UNITOTEM_SECUREBOOT=${sbx:-unknown}"; fi
    # Same capability test remote-deploy.sh's do_probe makes on a running system: the Pi firmware publishes the node
    # only when its EEPROM bootloader understands tryboot (the SoC check leaves out Pi 3 / Zero 2).
    if [ -e /proc/device-tree/chosen/bootloader/tryboot ] && tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | grep -qE 'bcm2711|bcm2712'; then
        echo "UNITOTEM_TRYBOOT=1"
    else
        echo "UNITOTEM_TRYBOOT=0"
    fi

    if [ -n "$disk" ]; then
        local size
        size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
        echo "UNITOTEM_DISK=$disk"
        echo "UNITOTEM_DISKSIZE=$size"

        # Slots are ROOT_A + ROOT_B (ROOT on older layouts). Each slot is judged on its own: the label exists, the
        # filesystem mounts read-only and carries the "is a UniTotem root" marker. (A destroyed slot has no label.)
        local lbl slotdev have_root=0 have_unitotem=0
        for lbl in ROOT ROOT_A ROOT_B; do
            slotdev=$(blkid -L "$lbl" 2>/dev/null || true)
            [ -n "$slotdev" ] && [ "$(lsblk -no PKNAME "$slotdev" 2>/dev/null)" = "${disk##*/}" ] || continue
            have_root=1
            mkdir -p /tmp/ota-probe-root
            if mount -t ext4 -o ro "$slotdev" /tmp/ota-probe-root 2>/dev/null; then
                if [ -f /tmp/ota-probe-root/etc/unitotem/ota-preserve.list ]; then
                    have_unitotem=1; echo "UNITOTEM_SLOT_OK_${lbl}=1"
                fi
                umount /tmp/ota-probe-root 2>/dev/null || true
            fi
        done
        echo "UNITOTEM_HAVE_ROOT=$have_root"
        echo "UNITOTEM_HAVE_UNITOTEM=$have_unitotem"

        data_dev=$(blkid -L DATA 2>/dev/null || true)
        if [ -n "$data_dev" ] && [ "$(lsblk -no PKNAME "$data_dev" 2>/dev/null)" = "${disk##*/}" ] \
           && dumpe2fs -h "$data_dev" >/dev/null 2>&1; then
            echo "UNITOTEM_HAVE_DATA=1"
            echo "UNITOTEM_DATA_UUID=$(blkid -s UUID -o value "$data_dev" 2>/dev/null || echo "")"
            echo "UNITOTEM_DATA_PARTN=$(lsblk -no PARTN "$data_dev" 2>/dev/null | head -1)"
            echo "UNITOTEM_DATA_START=$(cat "/sys/class/block/${data_dev##*/}/start" 2>/dev/null)"
            # Read-only check, never a repair: a recovery that keeps DATA must be sure it is keeping something sound.
            if awk -v d="$data_dev" '$1==d{f=1} END{exit !f}' /proc/mounts; then
                echo "UNITOTEM_DATA_FSCK=mounted"
            else
                local drc=0; e2fsck -fn "$data_dev" >/dev/null 2>&1 || drc=$?
                echo "UNITOTEM_DATA_FSCK=$drc"
            fi
        else
            echo "UNITOTEM_HAVE_DATA=0"
        fi
        echo "UNITOTEM_NPARTS=$(lsblk -lno TYPE "$disk" 2>/dev/null | grep -c '^part$' || true)"

        fw_dev=$(blkid -L FIRMWARE -o device 2>/dev/null || blkid -L EFI -o device 2>/dev/null || true)
        [ -n "$fw_dev" ] && [ "$(lsblk -no PKNAME "$fw_dev" 2>/dev/null)" = "${disk##*/}" ] \
            && echo "UNITOTEM_HAVE_BOOTFS=1" || echo "UNITOTEM_HAVE_BOOTFS=0"
        if [ -n "$fw_dev" ] && command -v fsck.fat >/dev/null 2>&1 && ! awk -v d="$fw_dev" '$1==d{f=1} END{exit !f}' /proc/mounts; then
            local brc=0; fsck.fat -n "$fw_dev" >/dev/null 2>&1 || brc=$?
            echo "UNITOTEM_BOOTFS_FSCK=$brc"
        fi
    fi

    command -v partclone.restore >/dev/null 2>&1 \
        && echo "UNITOTEM_PARTCLONE_VERSION=$(partclone.restore -v 2>&1 | head -1 | awk '{print $2}')"
    # No `tr` here: command substitution drops the trailing NUL of device-tree string properties, and tr may be
    # missing from a minimal initramfs.
    [ -f /proc/device-tree/model ] && echo "UNITOTEM_MODEL=$(cat /proc/device-tree/model 2>/dev/null)"
    true
}

# ---------------------------------------------------------------------------
# restore-table: sfdisk restore with two corrections: last-lba stripped so the usable area is not capped at the
# source disk's size, and the tail partition's size= recomputed against the real disk. The table arrives
# base64'd on the command line (whitespace does not survive an ssh argv round-trip).
# ---------------------------------------------------------------------------
cmd_restore_table() {
    ota_status_set "Writing the partition table"
    parse_args "$@"
    need disk; need table-b64; need tail-part
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local table; table=$(printf '%s' "${ARG[table-b64]}" | base64 -d)
    local tail_part="${ARG[tail-part]}"

    local patched
    patched=$(printf '%s\n' "$table" | grep -v '^last-lba:')

    # sfdisk --dump lines are keyed by the full device path of the disk the dump was taken from (a loop device
    # on the build host), which is not $disk here: match on the trailing "<tail_part> :" instead.
    local disk_sectors tail_start
    disk_sectors=$(blockdev --getsz "$disk")
    tail_start=$(printf '%s\n' "$patched" | grep -E "(^|[^0-9])${tail_part}[[:space:]]*:" | head -1 \
        | grep -oE 'start=[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
    [ -n "$tail_start" ] || fail "cannot find partition ${tail_part} in the supplied table"
    local tail_size=$((disk_sectors - tail_start - 34))
    [ "$tail_size" -gt 0 ] || fail "disk too small for the table (final partition would be negative)"

    patched=$(printf '%s\n' "$patched" | awk -v tp="$tail_part" -v sz="$tail_size" '
        {
            line=$0
            if (line ~ ("(^|[^0-9])" tp "[[:space:]]*:") && line ~ /size=/) {
                sub(/size=[[:space:]]*[0-9]+,?/, "size=" sz ",", line)
            }
            print line
        }')

    # The boot partition is mounted read-only at /boot-ota for the whole fallback session; rewriting the table under
    # a mounted partition makes the kernel keep the old geometry (the re-read fails with EBUSY) if it moves.
    umount /boot-ota 2>/dev/null || true
    log "Writing the partition table on $disk (total sectors: $disk_sectors)..."
    printf '%s\n' "$patched" | sfdisk --force --no-reread "$disk" || fail "sfdisk restore failed"
    mark_point_of_no_return

    if [ -n "${ARG[bootcode-b64]:-}" ]; then
        log "Writing the MBR boot code (440 bytes) to $disk..."
        printf '%s' "${ARG[bootcode-b64]}" | base64 -d | dd of="$disk" bs=440 count=1 conv=notrunc \
            || fail "bootcode write failed"
    fi

    partprobe "$disk" 2>/dev/null || true
    partx -u "$disk" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    echo "UNITOTEM_TABLE_RESTORED=1"
}

# ---------------------------------------------------------------------------
# restore-part: pull one partclone stream over the DATA connection (plain netcat, the target connects out) and
# restore it in place. -C is passed only after verifying that the used bytes (plus margin) fit the real target
# partition, instead of relying on partclone's coarser total-size check.
# ---------------------------------------------------------------------------
cmd_restore_part() {
    parse_args "$@"
    need disk; need part; need cloner; need data-host; need data-port; need used-bytes
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local part_dev; part_dev=$(pdev_target "$disk" "${ARG[part]}")
    [ -b "$part_dev" ] || fail "partition not found: $part_dev"

    local part_sectors used_bytes allow_smaller=0
    used_bytes="${ARG[used-bytes]}"
    part_sectors=$(blockdev --getsz "$part_dev")
    local part_bytes=$((part_sectors * 512))
    local margin=$((used_bytes / 5 + 268435456))   # +20% + 256MiB
    if [ $((used_bytes + margin)) -le "$part_bytes" ]; then
        allow_smaller=1
    fi

    log "Restoring partition ${ARG[part]} ($part_dev, cloner=${ARG[cloner]}) from ${ARG[data-host]}:${ARG[data-port]}..."
    # partclone.restore fails ("open logfile ... error") if /var/log does not exist, and this initrd's /var is a
    # bare tmpfs.
    mkdir -p /var/log
    exec 4<>"/dev/tcp/${ARG[data-host]}/${ARG[data-port]}"

    local restore_flags=(-o "$part_dev" -s -)
    [ "$allow_smaller" = 1 ] && [ "${ARG[cloner]}" != dd ] && restore_flags=(-C "${restore_flags[@]}")

    # Restore always goes through partclone.restore (it reads the image header). pv sits after decompression so it
    # measures the payload that --used-bytes describes; its stderr goes to a file so the UI process is not coupled
    # to the transfer. pv is optional: without it the restore still runs, just with no progress display.
    ota_status_set "Writing partition ${ARG[part]} (${ARG[cloner]})"
    local have_pv=0
    command -v pv >/dev/null 2>&1 && have_pv=1
    # cloner dd (the BIOS-boot partition holding GRUB's core.img): the stream is the raw partition content.
    local -a restore_cmd=(partclone.restore "${restore_flags[@]}" -F -B)
    [ "${ARG[cloner]}" = dd ] && restore_cmd=(dd "of=${part_dev}" bs=512 conv=fsync status=none)
    case "${ARG[comp]:-xz}" in
        xz|zstd)
            local dec=(unxz -dc); [ "${ARG[comp]:-xz}" = zstd ] && dec=(unzstd -dc)
            if [ "$have_pv" = 1 ]; then
                "${dec[@]}" <&4 | pv -n -s "$used_bytes" 2>"$OTA_PCT_FILE" | "${restore_cmd[@]}"
            else
                "${dec[@]}" <&4 | "${restore_cmd[@]}"
            fi
            ;;
        *)    fail "unknown compression: ${ARG[comp]:-}" ;;
    esac || fail "restore failed on $part_dev"
    ota_status_set "Checking the filesystem of partition ${ARG[part]}..."
    exec 4<&-

    if [ "${ARG[cloner]}" != dd ]; then
        e2fsck -fy "$part_dev" >/dev/null 2>&1 || true
        [ "${ARG[fstype]:-}" = ext4 ] && [ -n "${ARG[grow]:-}" ] && resize2fs "$part_dev" >/dev/null 2>&1 || true
    fi
    echo "UNITOTEM_PART_RESTORED=${ARG[part]}"
}

# ---------------------------------------------------------------------------
# format-part: an empty, labelled ext4 (A/B: the inactive ROOT_B slot, which a deploy leaves empty
# for the first update to fill).
# ---------------------------------------------------------------------------
cmd_format_part() {
    parse_args "$@"
    need disk; need part; need label
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local part_dev; part_dev=$(pdev_target "$disk" "${ARG[part]}")
    log "Formatting ${ARG[label]} (${part_dev})..."
    mkfs.ext4 -F -L "${ARG[label]}" "$part_dev" >/dev/null || fail "mkfs.ext4 on ${ARG[label]} failed"
    echo "UNITOTEM_PART_FORMATTED=${ARG[part]}"
}

# grubenv_write FILE key=value... : rewrite a GRUB environment block (1024 bytes: header, one
# key=value per line, '#' padding). Done by hand because the fallback has no grub-editenv, and
# because this is the one place that decides what the next boot is.
grubenv_write() {
    local file="$1"; shift
    # Built with += and $'\n', not $(...), which strips the trailing newline and would fuse the '#' padding
    # onto the last value ("ota-recovery####...").
    local body="# GRUB Environment Block"$'\n' kv
    for kv in "$@"; do body+="$kv"$'\n'; done
    local pad=$((1024 - ${#body}))
    [ "$pad" -ge 0 ] || fail "grubenv too large"
    { printf '%s' "$body"; printf '%*s' "$pad" '' | tr ' ' '#'; } > "$file.new" || fail "grubenv write failed"
    mv -f "$file.new" "$file"
}

# ---------------------------------------------------------------------------
# data-op: DATA partition handling - preserve (no-op) or fresh mkfs.
# ---------------------------------------------------------------------------
cmd_data_op() {
    parse_args "$@"
    need disk; need part; need op
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local part_dev; part_dev=$(pdev_target "$disk" "${ARG[part]}")
    case "${ARG[op]}" in
        preserve) log "DATA preserved (${part_dev})" ;;
        mkfs)
            log "Formatting DATA (${part_dev})..."
            mkfs.ext4 -F -L DATA "$part_dev" || fail "mkfs.ext4 on DATA failed"
            ;;
        *) fail "unknown data-op: ${ARG[op]}" ;;
    esac
    echo "UNITOTEM_DATA_OP_DONE=1"
}

# ---------------------------------------------------------------------------
# write-bootfile: file-level write onto the boot FAT partition (EFI/FIRMWARE), used for the recovery
# kernel/initrd (stage 1) and the real system's kernel8.img/initramfs8/dtbs (stage 2). Content arrives on
# stdin and the target path is always explicit, so stage 2 cannot clobber what stage 1 wrote by accident.
# ---------------------------------------------------------------------------
cmd_write_bootfile() {
    parse_args "$@"
    need disk; need bootfs-part; need name
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    local mnt=/tmp/ota-bootfs subdir="${ARG[subdir]:-}"
    ota_mount_bootfs_rw "$bootfs_dev" "$mnt"
    local dest="$mnt/${subdir:+$subdir/}${ARG[name]}"
    mkdir -p "${dest%/*}"
    cat > "$dest.new"
    mv -f "$dest.new" "$dest"
    sync
    local got; got=$(sha256sum "$dest" | cut -d' ' -f1)
    ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
    echo "UNITOTEM_BOOTFILE_SHA256=$got"
}

cmd_prepare_bootfs() {
    parse_args "$@"
    need disk; need bootfs-part; need fstype
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    if [ "${ARG[fresh]:-0}" = 1 ]; then
        # init-premount keeps this partition mounted read-only on /boot-ota for the whole session, and mkfs.fat
        # refuses a mounted device: release it (and any other mount of it) first; ota_mount_bootfs_rw mounts it
        # again when needed.
        umount /boot-ota 2>/dev/null || true
        local m
        while m=$(awk -v d="$bootfs_dev" '$1==d{print $2; exit}' /proc/mounts) && [ -n "$m" ]; do
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || break
        done
        log "Formatting the boot partition ($bootfs_dev, ${ARG[fstype]})..."
        # --volid: the FAT serial of the image's boot partition. GRUB's EFI/BIOS images locate the directory holding
        # grub.cfg by that serial (search.fs_uuid); a random serial boots to a bare grub prompt.
        local volid_args=()
        [ -n "${ARG[volid]:-}" ] && volid_args=(-i "${ARG[volid]//-/}")
        mkfs.fat -F32 "${volid_args[@]}" -n "${ARG[label]:-BOOT}" "$bootfs_dev" || fail "mkfs.fat on $bootfs_dev failed"
    fi
    echo "UNITOTEM_BOOTFS_READY=1"
}

# populate-bootfs: pulls the boot-fs tarball over the DATA connection and extracts it, excluding everything that
# belongs to the resident fallback (recovery files, unitotem-ota.* state, trial-boot markers).
# config.txt/cmdline.txt are excluded too (arm64: same FIRMWARE partition): overwriting the fallback-pointing
# config.txt would leave a half-written real system after a power cut. Only set-default-recovery and
# promote-default write it. No-op on amd64 (grub.cfg lives on the ext4 BOOT partition).
cmd_populate_bootfs() {
    ota_status_set "Copying boot files (firmware, dtb, overlays)"
    parse_args "$@"
    need disk; need bootfs-part; need data-host; need data-port
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    local mnt=/tmp/ota-bootfs
    ota_mount_bootfs_rw "$bootfs_dev" "$mnt"

    log "Populating the file-level content of the boot partition from ${ARG[data-host]}:${ARG[data-port]}..."
    exec 4<>"/dev/tcp/${ARG[data-host]}/${ARG[data-port]}"
    # tar's exclude matching is unanchored: 'cmdline.txt' would also drop slota/cmdline.txt, which an A/B image needs
    # (os_prefix makes the firmware read it from there). With --layout ab the names are anchored to the top of the
    # archive ("./name"), so only the top-level files are protected.
    local anch="" pre=""
    if [ "${ARG[layout]:-1}" = ab ]; then anch="--anchored"; pre="./"; fi
    unxz -dc <&4 | tar -C "$mnt" -xf - $anch \
        --exclude="${pre}recovery8.img" --exclude="${pre}recovery-vmlinuz" --exclude="${pre}recovery-initrd.img" \
        --exclude="${pre}recovery.sha256" --exclude="${pre}unitotem/*" \
        --exclude="${pre}unitotem-ota.conf" --exclude="${pre}unitotem-ota.state" --exclude="${pre}unitotem-ota.request" \
        --exclude="${pre}unitotem-ota.bootcount" --exclude="${pre}unitotem-ota.last" \
        --exclude="${pre}unitotem-ota.authorized_keys" \
        --exclude="${pre}tryboot.txt" --exclude="${pre}cmdline-trial.txt" \
        --exclude="${pre}config.txt" --exclude="${pre}cmdline.txt" \
        --exclude="${pre}*.unitotem-bak" \
        || fail "bootfs extraction failed"
    exec 4<&-
    sync
    # --secure-boot shim: the image only stages the signed chain (EFI/unitotem-sb/, see unitotem/stage3-image.sh); this
    # activates it. Everything the chain needs is copied first and BOOTX64.EFI (the file the firmware loads) is replaced
    # last through a temporary name and a rename, so a power cut leaves either the old loader or the complete new chain.
    if [ "${ARG[secure-boot]:-}" = shim ]; then
        local sb="$mnt/EFI/unitotem-sb" bt="$mnt/EFI/BOOT" f
        for f in shimx64.efi mmx64.efi grubx64.efi grub.cfg; do
            [ -s "$sb/$f" ] || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: $f missing in EFI/unitotem-sb (image without a signed chain?)"; }
        done
        mkdir -p "$bt" "$mnt/EFI/debian"
        cp "$sb/grubx64.efi" "$bt/grubx64.efi" && cp "$sb/mmx64.efi" "$bt/mmx64.efi" \
            && cp "$sb/grub.cfg" "$bt/grub.cfg" && cp "$sb/grub.cfg" "$mnt/EFI/debian/grub.cfg" \
            || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: chain copy failed"; }
        sync
        cp "$sb/shimx64.efi" "$bt/BOOTX64.EFI.new" && sync && mv -f "$bt/BOOTX64.EFI.new" "$bt/BOOTX64.EFI" \
            || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: shim installation failed"; }
        cmp -s "$sb/shimx64.efi" "$bt/BOOTX64.EFI" || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: the written shim does not match"; }
        echo shim > "$sb/active"; sync
        echo "UNITOTEM_SECURE_BOOT=shim"
    fi
    ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
    echo "UNITOTEM_BOOTFS_POPULATED=1"
}

cmd_read_bootfile() {
    parse_args "$@"
    need disk; need bootfs-part; need name
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    local mnt=/tmp/ota-bootfs subdir="${ARG[subdir]:-}"
    mkdir -p "$mnt"
    mountpoint -q "$mnt" || mount -t vfat -o ro "$bootfs_dev" "$mnt" || fail "mount of bootfs ($bootfs_dev) failed"
    cat "$mnt/${subdir:+$subdir/}${ARG[name]}"
    umount "$mnt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# set-default-recovery: make the resident fallback the boot default. Runs at
# the end of stage 1 - from this point on, any power loss reboots into the
# fallback rather than a half-written disk.
# ---------------------------------------------------------------------------
cmd_set_default_recovery() {
    parse_args "$@"
    need disk; need firmware; need bootfs-part
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    local mnt=/tmp/ota-bootfs
    ota_mount_bootfs_rw "$bootfs_dev" "$mnt"

    case "${ARG[firmware]}" in
        rpi)
            # hdmi_group=2 hdmi_mode=4 is the DMT 640x480@60 mode: the deploy/recovery screen is a text UI that must
            # stay readable on large high-resolution monitors seen from a distance, and DMT 640x480 is accepted by
            # essentially every display. Only the resident fallback has it; the real system's config.txt is untouched.
            cat > "$mnt/config.txt" << 'EOF'
arm_64bit=1
enable_uart=1
hdmi_group=2
hdmi_mode=4
kernel=recovery8.img
initramfs recovery-initrd.img followkernel
EOF
            # ttyS0 = mini-UART on the GPIO14/15 header pins, paired with enable_uart=1 above. Not console=serial0:
            # under the mainline/Debian DTBs that alias is the PL011 (Bluetooth pins), see unitotem/stage2-configure.sh.
            echo "unitotem.ota=1 console=tty1 console=ttyS0,115200" > "$mnt/cmdline.txt"
            ;;
        uefi|bios)
            if [ "${ARG[layout]:-1}" = ab ]; then
                # A/B: GRUB lives in unitotem-grub/ on this partition (put there by populate-bootfs, which must have
                # run). Its grub.cfg has an 'ota-recovery' entry; making it the saved default is a plain file write.
                [ -f "$mnt/unitotem-grub/grub/grub.cfg" ] \
                    || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "A/B: unitotem-grub/grub/grub.cfg missing (populate-bootfs not run?)"; }
                grubenv_write "$mnt/unitotem-grub/grub/grubenv" "saved_entry=ota-recovery"
                sync
                ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
                echo "UNITOTEM_DEFAULT_RECOVERY=1"
                return 0
            fi
            mkdir -p "$mnt/grub"
            cat > "$mnt/grub/grub.cfg" << 'EOF'
set default=0
set timeout=0
menuentry 'UniTotem OTA' {
    linux /unitotem/recovery-vmlinuz unitotem.ota=1 console=tty0
    initrd /unitotem/recovery-initrd.img
}
EOF
            ;;
        *) fail "unknown firmware: ${ARG[firmware]}" ;;
    esac
    sync
    ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
    echo "UNITOTEM_DEFAULT_RECOVERY=1"
}

# ---------------------------------------------------------------------------
# set-trial-boot / promote-default: the real system boots on trial (GRUB one-shot, tryboot on Pi 4/5, or a
# config.txt swap on legacy firmware) while the fallback stays default until unitotem-boot-ok.service confirms;
# only then does promote-default flip the permanent default.
# The rpi branches write a minimal config.txt/tryboot.txt with only the kernel=/initramfs= lines, so the fallback
# never depends on the image's config.txt; other boot options come from unitotem/files/config-extra.txt (appended
# after those lines, installed by stage2-configure.sh). A missing file (amd64) is not an error.
append_config_extra() {
    local extra_file="$1" dest="$2"
    [ -f "$extra_file" ] && cat "$extra_file" >> "$dest"
}

# ab_write_pending TARGET_ROOT : the update bookkeeping for a first deploy, identical to what `unitotem-update apply`
# leaves behind, so the boot-ok / confirm path is the same for a fresh install and for every later update.
ab_write_pending() {
    local t="$1" ver ud now
    ver=$(cat "$t/usr/share/unitotem/release-version" 2>/dev/null || echo unknown)
    ud="$t/mnt/data/unitotem/update"
    TZ=UTC0 printf -v now '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    mkdir -p "$ud"
    printf '{"slot": "a", "from": null, "version": "%s", "armed_at": "%s"}\n' "$ver" "$now" > "$ud/pending.json"
    printf '{"a": {"version": "%s", "valid": true, "prepared": true}, "b": {"version": null, "valid": false}}\n' "$ver" > "$ud/slots.json"
    sync
}

cmd_set_trial_boot() {
    ota_status_set "Preparing the trial boot"
    parse_args "$@"
    need firmware
    case "${ARG[firmware]}" in
        uefi|bios)
            if [ "${ARG[layout]:-1}" = ab ]; then
                need target
                local t="${ARG[target]}" ge="${ARG[target]}/boot/efi/unitotem-grub/grub/grubenv"
                [ -f "$ge" ] || fail "A/B: grubenv missing in $ge (ESP mounted on the target?)"
                # Trial = one-shot next_entry; saved_entry stays on the fallback until unitotem-boot-ok
                # confirms. The same state unitotem-update writes for an in-place update, so the boot-ok
                # path is identical for a first deploy and for every later one.
                ab_write_pending "$t"
                grubenv_write "$ge" "saved_entry=ota-recovery" "next_entry=slot-a"
                sync
                ota_final_status
                echo "UNITOTEM_TRIAL_ARMED=1"
                return 0
            fi
            # This runs in the fallback environment: every grub-* command below operates on the restored system at
            # ${ARG[target]} (/mnt/newroot, mounted by mount-target), not on the fallback's own /boot/grub.
            need target
            local t="${ARG[target]}"
            cat > "${t}/etc/grub.d/99_unitotem_trial" << 'EOF'
#!/bin/sh
exec tail -n +3 "$0"
menuentry 'UniTotem (trial)' {
    linux /vmlinuz root=LABEL=ROOT ro quiet unitotem.ota.bootcount=1
    initrd /initrd.img
}
EOF
            chmod +x "${t}/etc/grub.d/99_unitotem_trial"
            mount --bind /dev  "${t}/dev"
            mount --bind /proc "${t}/proc"
            mount --bind /sys  "${t}/sys"
            if [ -d /sys/firmware/efi ]; then
                mount -t efivarfs efivarfs "${t}/sys/firmware/efi/efivars" 2>/dev/null || true
            fi
            (chroot "$t" sh -c 'command -v update-grub >/dev/null 2>&1 && update-grub' \
                || chroot "$t" grub-mkconfig -o /boot/grub/grub.cfg) \
                || { umount -lf "${t}/sys/firmware/efi/efivars" "${t}/dev" "${t}/proc" "${t}/sys" 2>/dev/null || true; fail "grub-mkconfig failed"; }
            chroot "$t" grub-reboot 'UniTotem (trial)' \
                || { umount -lf "${t}/sys/firmware/efi/efivars" "${t}/dev" "${t}/proc" "${t}/sys" 2>/dev/null || true; fail "grub-reboot failed"; }
            umount -lf "${t}/sys/firmware/efi/efivars" 2>/dev/null || true
            umount -lf "${t}/dev" "${t}/proc" "${t}/sys" 2>/dev/null || true
            ;;
        rpi-tryboot)
            need disk; need bootfs-part
            if [ "${ARG[layout]:-1}" = ab ]; then
                need target
                local t="${ARG[target]}"
                local disk; disk=$(resolve_disk "${ARG[disk]}")
                local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
                local mnt=/tmp/ota-bootfs
                ota_mount_bootfs_rw "$bootfs_dev" "$mnt"
                # The trial config is a complete config (the firmware reads tryboot.txt instead of config.txt, never both):
                # slot A's kernel/initramfs/dtbs/cmdline come from slota/ through os_prefix. config.txt keeps pointing at
                # the fallback until unitotem-boot-ok confirms, so a power cut, a hang or an unbootable slot ends on the
                # fallback at the next plain boot.
                {
                    echo "[all]"
                    echo "arm_64bit=1"
                    echo "enable_uart=1"
                    echo "os_prefix=slota/"
                    echo "kernel=kernel8.img"
                    echo "initramfs initramfs8 followkernel"
                } > "$mnt/tryboot.txt"
                append_config_extra "$t/etc/unitotem/config-extra.txt" "$mnt/tryboot.txt"
                sync; ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
                ab_write_pending "$t"
                ota_final_status
                echo "UNITOTEM_TRIAL_ARMED=1"
                return 0
            fi
            local disk; disk=$(resolve_disk "${ARG[disk]}")
            local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
            local mnt=/tmp/ota-bootfs
            ota_mount_bootfs_rw "$bootfs_dev" "$mnt"
            cat > "$mnt/tryboot.txt" << 'EOF'
[all]
enable_uart=1
kernel=kernel8.img
initramfs initramfs8 followkernel
cmdline=cmdline-trial.txt
EOF
            append_config_extra /mnt/newroot/etc/unitotem/config-extra.txt "$mnt/tryboot.txt"
            echo "console=tty1 console=ttyS0,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet unitotem.ota.bootcount=1" \
                > "$mnt/cmdline-trial.txt"
            sync; ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
            ;;
        rpi-legacy)
            need disk; need bootfs-part
            local disk; disk=$(resolve_disk "${ARG[disk]}")
            local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
            local mnt=/tmp/ota-bootfs
            ota_mount_bootfs_rw "$bootfs_dev" "$mnt"
            cp -a "$mnt/config.txt"  "$mnt/config.txt.unitotem-bak"
            cp -a "$mnt/cmdline.txt" "$mnt/cmdline.txt.unitotem-bak" 2>/dev/null || true
            cat > "$mnt/config.txt" << 'EOF'
arm_64bit=1
enable_uart=1
kernel=kernel8.img
initramfs initramfs8 followkernel
EOF
            append_config_extra /mnt/newroot/etc/unitotem/config-extra.txt "$mnt/config.txt"
            echo "console=tty1 console=ttyS0,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet unitotem.ota.bootcount=1" \
                > "$mnt/cmdline.txt"
            sync; ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
            ;;
        *) fail "unknown trial-boot mode: ${ARG[firmware]}" ;;
    esac
    ota_final_status
    echo "UNITOTEM_TRIAL_ARMED=1"
}

cmd_promote_default() {
    parse_args "$@"
    need firmware
    case "${ARG[firmware]}" in
        uefi|bios)
            mount -o remount,rw / 2>/dev/null || true
            rm -f /etc/grub.d/99_unitotem_trial
            (command -v update-grub >/dev/null 2>&1 && update-grub) \
                || grub-mkconfig -o /boot/grub/grub.cfg || true
            ;;
        rpi)
            need disk; need bootfs-part
            local disk; disk=$(resolve_disk "${ARG[disk]}")
            local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
            local mnt=/tmp/ota-bootfs
            ota_mount_bootfs_rw "$bootfs_dev" "$mnt"
            # The config below has no os_prefix: on an A/B device it would drop the slot selection. A/B devices are
            # promoted by unitotem-update confirm (config.txt os_prefix), so refuse before anything is written.
            if grep -q '^os_prefix=' "$mnt/config.txt" 2>/dev/null; then
                ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
                fail "promote-default refused: A/B device (os_prefix in config.txt), promotion is done by unitotem-update"
            fi
            cat > "$mnt/config.txt" << 'EOF'
arm_64bit=1
enable_uart=1
kernel=kernel8.img
initramfs initramfs8 followkernel
EOF
            # promote-default runs post-boot via unitotem-boot-ok on the real system, so the extra-config file is this
            # system's own /etc/unitotem, not /mnt/newroot's.
            append_config_extra /etc/unitotem/config-extra.txt "$mnt/config.txt"
            echo "console=tty1 console=ttyS0,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet" > "$mnt/cmdline.txt"
            rm -f "$mnt/tryboot.txt" "$mnt/cmdline-trial.txt" \
                  "$mnt/config.txt.unitotem-bak" "$mnt/cmdline.txt.unitotem-bak"
            sync; ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
            ;;
        *) fail "unknown firmware: ${ARG[firmware]}" ;;
    esac
    echo "UNITOTEM_PROMOTED=1"
}

# ---------------------------------------------------------------------------
# mount-target / umount-target: the restored ROOT (plus BOOT/EFI on amd64), mounted at /mnt/newroot for
# migrate-etc-overlay and set-trial-boot --target to operate on before the target is booted.
# ---------------------------------------------------------------------------
cmd_mount_target() {
    ota_status_set "Mounting the newly written system"
    parse_args "$@"
    need disk
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    mkdir -p /mnt/newroot
    local root_dev; root_dev=$(pdev_target "$disk" "${ARG[root-part]:?--root-part required}")
    mountpoint -q /mnt/newroot || mount -t ext4 "$root_dev" /mnt/newroot || fail "mount of ROOT (new system) failed"
    if [ -n "${ARG[boot-part]:-}" ]; then
        mkdir -p /mnt/newroot/boot
        mount -t ext4 "$(pdev_target "$disk" "${ARG[boot-part]}")" /mnt/newroot/boot || fail "mount of BOOT failed"
    fi
    if [ -n "${ARG[bootfs-part]:-}" ]; then
        # amd64: FAT partition is the ESP, mounted under BOOT at /boot/efi.
        # arm64: FAT partition IS /boot/firmware directly (no separate BOOT).
        local bootfs_mnt=/mnt/newroot/boot/efi
        [ "${ARG[arch]:-amd64}" = arm64 ] && bootfs_mnt=/mnt/newroot/boot/firmware
        # ota_mount_bootfs_rw, not a plain mount: /boot-ota keeps this device mounted ro for the whole session, and a
        # plain mount would silently come up read-only too.
        ota_mount_bootfs_rw "$(pdev_target "$disk" "${ARG[bootfs-part]}")" "$bootfs_mnt"
    fi
    if [ -n "${ARG[data-part]:-}" ]; then
        mkdir -p /mnt/newroot/mnt/data
        mount -t ext4 "$(pdev_target "$disk" "${ARG[data-part]}")" /mnt/newroot/mnt/data 2>/dev/null || true
    fi
    echo "UNITOTEM_MOUNTED=1"
}

cmd_umount_target() {
    umount -lf /mnt/newroot/mnt/data     2>/dev/null || true
    umount -lf /mnt/newroot/boot/efi     2>/dev/null || true
    umount -lf /mnt/newroot/boot/firmware 2>/dev/null || true
    umount -lf /mnt/newroot/boot         2>/dev/null || true
    umount -lf /mnt/newroot              2>/dev/null || true
    # Best-effort: put the persistent /boot-ota reader back to read-only (the lazy unmounts above only detach the
    # bind-mounted copy under /mnt/newroot, not the original mount that ota_mount_bootfs_rw remounted rw).
    local fw_dev; fw_dev=$(blkid -L FIRMWARE -o device 2>/dev/null || blkid -L EFI -o device 2>/dev/null || true)
    [ -n "$fw_dev" ] && ota_umount_bootfs_rw "$fw_dev" /nonexistent 2>/dev/null || true
    echo "UNITOTEM_UNMOUNTED=1"
}

# populate-real-kernel: arm64 only. The Pi firmware reads kernel8.img/initramfs8/dtbs only from the FAT firmware
# partition, so the restored ROOT's /boot/vmlinuz-*, /boot/initrd.img-* and dtbs (/usr/lib/linux-image-*) are copied
# across at file level, never touching the recovery8.img/recovery-initrd.img/recovery.sha256 files. amd64 needs no
# equivalent: its kernel lives on the BOOT ext4 partition and GRUB's trial entry uses its /vmlinuz,/initrd.img symlinks.
cmd_populate_real_kernel() {
    ota_status_set "Installing the system kernel"
    parse_args "$@"
    [ -d /mnt/newroot/boot/firmware ] || { echo "UNITOTEM_KERNEL_POPULATED=skip"; return 0; }
    # A bash glob instead of `ls`: this initrd's `ls` does not parse options.
    local kver=""
    for _d in /mnt/newroot/lib/modules/*/; do kver="${_d%/}"; kver="${kver##*/}"; break; done
    [ -n "$kver" ] || fail "no kernel found in /mnt/newroot/lib/modules"
    cp "/mnt/newroot/boot/vmlinuz-${kver}"    /mnt/newroot/boot/firmware/kernel8.img
    cp "/mnt/newroot/boot/initrd.img-${kver}" /mnt/newroot/boot/firmware/initramfs8
    cp "/mnt/newroot/usr/lib/linux-image-${kver}"/broadcom/bcm27*.dtb /mnt/newroot/boot/firmware/ 2>/dev/null || true
    sync
    echo "UNITOTEM_KERNEL_POPULATED=1"
}

# ---------------------------------------------------------------------------
# etc-overlay migration: the new image's /etc always wins; DATA's old overlay content is moved aside wholesale,
# then only an explicit whitelist is reintroduced.
# ---------------------------------------------------------------------------
# prune_history DATA KEEP_NAME: keeps the newest HISTORY_KEEP DATA/history entries, deletes the rest. Only names of
# the form YYYYMMDDTHHMMSSZ are candidates (fixed width, so name order is time order); KEEP_NAME is never removed.
prune_history() {
    local hist="$1/history" keep_name="$2" d name i
    local -a names=()
    [ -d "$hist" ] || return 0
    for d in "$hist"/*; do
        [ -d "$d" ] || continue
        name="${d##*/}"
        [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
        names+=("$name")
    done
    local n=${#names[@]}
    (( n > HISTORY_KEEP )) || return 0
    for (( i = 0; i < n - HISTORY_KEEP; i++ )); do
        [ "${names[i]}" = "$keep_name" ] && continue
        rm -rf -- "$hist/${names[i]}"
    done
}

cmd_migrate_etc_overlay() {
    ota_status_set "Migrating configuration from DATA"
    parse_args "$@"
    need root-mnt; need data-mnt
    local root="${ARG[root-mnt]}" data="${ARG[data-mnt]}"
    # A/B: the new system is slot A and keeps its overlay state in upper/<d>.a (see unitotem/files/overlayfs-hook.sh).
    # Slot B is about to be formatted empty, so what a previous install left for it and the update bookkeeping
    # describing it are stale and removed.
    local sfx=""
    if [ -n "${ARG[slot]:-}" ]; then
        sfx=".${ARG[slot]}"
        local other; other=b; [ "${ARG[slot]}" = b ] && other=a
        local dd
        for dd in etc root var; do
            rm -rf "$data/upper/$dd.$other" "$data/work/$dd.$other"
        done
        rm -f "$data/unitotem/update/pending.json" "$data/unitotem/update/slots.json" "$data/unitotem/update/last-result.json"
    fi
    # bash's printf %()T builtin instead of `date`, which is missing from the fallback (this is only a
    # history-directory name).
    local ts; TZ=UTC0 printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    # /var is archived and reset alongside /etc: it is overlaid too (see unitotem/files/overlayfs-hook.sh) and an OTA
    # replaces the whole ROOT partition, so the previous image's upper would shadow the new image's /var (its dpkg
    # database and /var/unitotem-venv, the manager's Python environment).
    # No whitelist for /var: everything under it is image-derived state or logs, and the whole upper is moved into
    # history/, where the logs can still be read.
    local d
    for d in etc var; do
        if [ -d "$data/upper/$d$sfx" ]; then
            mkdir -p "$data/history/$ts"
            mv "$data/upper/$d$sfx" "$data/history/$ts/$d" 2>/dev/null || true
            mv "$data/work/$d$sfx"  "$data/history/$ts/$d.work" 2>/dev/null || true
            mkdir -p "$data/upper/$d$sfx" "$data/work/$d$sfx"
        fi
    done
    local list="$root/etc/unitotem/ota-preserve.list"
    if [ -f "$list" ] && [ -d "$data/history/$ts/etc" ]; then
        while IFS= read -r pattern; do
            case "$pattern" in ''|'#'*|*=*) continue ;; esac
            for src in "$data/history/$ts/etc"/$pattern; do
                [ -e "$src" ] || continue
                rel="${src#"$data/history/$ts/etc/"}"
                reldir="${rel%/*}"; [ "$reldir" = "$rel" ] && reldir="."
                mkdir -p "$data/upper/etc$sfx/$reldir"
                cp -a "$src" "$data/upper/etc$sfx/$rel"
            done
        done < "$list"
    fi
    prune_history "$data" "$ts"
    echo "UNITOTEM_ETC_MIGRATED=1"
}

# ---------------------------------------------------------------------------
# apply-network: carry the target's network settings onto the installed system. migrate-etc-overlay only rescues
# what is already on DATA; a non-UniTotem device keeps its configuration in the ROOT about to be overwritten.
# Values come from remote-deploy.sh's probe and go into DATA's upper/etc, so ota-preserve.list keeps them across OTAs.
# interface-name is not pinned (names differ between systems, eth0 vs end0): NetworkManager binds by device type.
# ---------------------------------------------------------------------------
cmd_apply_network() {
    parse_args "$@"
    need data-mnt
    local data="${ARG[data-mnt]}"
    local link="${ARG[link]:-wired}" mode="${ARG[mode]:-dhcp}"
    local addr="${ARG[addr]:-}" gw="${ARG[gw]:-}" dns="${ARG[dns]:-}"
    local ssid_b64="${ARG[ssid-b64]:-}" psk_b64="${ARG[psk-b64]:-}"
    local dir="$data/upper/etc${ARG[slot]:+.${ARG[slot]}}/NetworkManager/system-connections"

    # Never clobber a profile that migrate-etc-overlay restored: it is the device's own configuration and outranks
    # anything inferred from a probe.
    if ls "$dir"/*.nmconnection >/dev/null 2>&1; then
        echo "UNITOTEM_NET_APPLIED=skip-existing"
        return 0
    fi
    # Wired DHCP needs no profile: NetworkManager brings such a link up on its own.
    if [ "$link" = wired ] && [ "$mode" = dhcp ]; then
        echo "UNITOTEM_NET_APPLIED=not-needed"
        return 0
    fi

    mkdir -p "$dir"
    local f="$dir/unitotem-adopted.nmconnection"
    {
        echo "[connection]"
        echo "id=unitotem-adopted"
        [ "$link" = wifi ] && echo "type=wifi" || echo "type=ethernet"
        echo "autoconnect=true"
        echo ""
        if [ "$link" = wifi ]; then
            echo "[wifi]"
            echo "mode=infrastructure"
            [ -n "$ssid_b64" ] && echo "ssid=$(printf '%s' "$ssid_b64" | base64 -d 2>/dev/null)"
            echo ""
            if [ -n "$psk_b64" ]; then
                echo "[wifi-security]"
                echo "key-mgmt=wpa-psk"
                echo "psk=$(printf '%s' "$psk_b64" | base64 -d 2>/dev/null)"
                echo ""
            fi
        fi
        echo "[ipv4]"
        if [ "$mode" = static ] && [ -n "$addr" ]; then
            echo "method=manual"
            echo "address1=${addr}${gw:+,${gw}}"
            [ -n "$dns" ] && echo "dns=${dns};"
        else
            echo "method=auto"
        fi
        echo ""
        echo "[ipv6]"
        echo "method=auto"
    } > "$f"
    # NetworkManager refuses a keyfile that others can read, and it holds the WiFi passphrase in cleartext.
    chmod 600 "$f"
    echo "UNITOTEM_NET_APPLIED=1"
}

# ---------------------------------------------------------------------------
# Fallback SSH access (dropbear, port 2222). fallback_auth_setup writes /etc/passwd, /etc/shadow and
# /root/.ssh/authorized_keys into the initramfs tmpfs on every start, from read-only sources only:
#   1. unitotem.ota.authkey=<base64 of one ed25519 key line> on the kernel command line
#   2. unitotem-ota.authorized_keys on the boot FAT
#   3. DATA: root's keys, and the keys and password hash of every member of group sudo (the admins)
# Root logs in by key only. Open mode (empty root password, dropbear -B) only when the device has no key and
# no admin account at all: a device that was never configured.
# Test overrides (default: the real paths): OTA_AUTH_ROOT (output prefix), OTA_AUTH_DATADIR (DATA tree used
# instead of mounting DATA), OTA_AUTH_BOOTDIR (directory used instead of the boot FAT), OTA_AUTH_CMDLINE (file
# used instead of /proc/cmdline). Call it in a `||` context: errexit and the ERR trap are then off inside it.
FALLBACK_OPEN=0
AUTH_MAX_KEYS=64
AUTH_MAX_LINE=2048
AUTH_KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$'
AUTH_ED25519_RE='^ssh-ed25519 [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$'
AUTH_NAME_RE='^[a-z_][a-z0-9_-]{0,31}$'
AUTH_HASH_RE='^\$[0-9a-z]+\$[A-Za-z0-9./$,=+-]*$'
AUTH_KEYS=()     # "type base64" of every accepted key, deduplicated
AUTH_ADMINS=()   # "name:hash" per admin; hash is "*" when there is no usable password
AUTH_USABLE=0    # admins with a usable password hash
AUTH_SAVED_SLOT=""   # slot named by the boot FAT grubenv (saved_entry), "" when unknown

# valid_authkey_line LINE [ed25519]: 0 when LINE is one plain public key line (no options) within the length cap.
valid_authkey_line() {
    [ "${#1}" -le "$AUTH_MAX_LINE" ] || return 1
    if [ "${2:-}" = ed25519 ]; then
        [[ $1 =~ $AUTH_ED25519_RE ]]
    else
        [[ $1 =~ $AUTH_KEY_RE ]]
    fi
}

# auth_add_key LINE ED25519_FLAG SOURCE: keeps "type base64" of a valid new key (the comment is dropped).
auth_add_key() {
    local kt kb _rest k x
    if ! valid_authkey_line "$1" "$2"; then
        log "fallback auth: invalid key line from $3 ignored"
        return 0
    fi
    read -r kt kb _rest <<< "$1"
    k="$kt $kb"
    for x in "${AUTH_KEYS[@]}"; do
        if [ "$x" = "$k" ]; then return 0; fi
    done
    if [ "${#AUTH_KEYS[@]}" -ge "$AUTH_MAX_KEYS" ]; then
        log "fallback auth: more than $AUTH_MAX_KEYS keys, the rest from $3 ignored"
        return 0
    fi
    AUTH_KEYS+=("$k")
    return 0
}

# auth_read_keys_file FILE ED25519_FLAG SOURCE: every key line of FILE (a missing file is no keys).
auth_read_keys_file() {
    local line before=${#AUTH_KEYS[@]}
    [ -f "$1" ] && [ -r "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        auth_add_key "$line" "$2" "$3"
    done < "$1"
    if [ "${#AUTH_KEYS[@]}" -ne "$before" ]; then
        log "fallback auth: $(( ${#AUTH_KEYS[@]} - before )) key(s) from $3"
    fi
    return 0
}

# auth_cmdline_get KEY: value of the KEY=value token on the kernel command line.
auth_cmdline_get() {
    local c tok
    local -a toks=()
    c=$(cat "${OTA_AUTH_CMDLINE:-/proc/cmdline}" 2>/dev/null) || return 1
    read -ra toks <<< "$c" || true
    for tok in "${toks[@]}"; do
        case "$tok" in "$1="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac
    done
    return 1
}

# auth_cmdline_key: unitotem.ota.authkey=<base64>, decoded to one ed25519 key line. Anything else is ignored.
auth_cmdline_key() {
    local tok key=""
    tok=$(auth_cmdline_get unitotem.ota.authkey) || return 0
    if [ "${#tok}" -gt 1024 ]; then
        log "fallback auth: unitotem.ota.authkey too long, ignored"
        return 0
    fi
    if ! [[ $tok =~ ^[A-Za-z0-9+/=]+$ ]]; then
        log "fallback auth: unitotem.ota.authkey is not base64, ignored"
        return 0
    fi
    key=$(printf '%s' "$tok" | base64 -d 2>/dev/null | head -n 1) || key=""
    key=${key%$'\r'}
    if valid_authkey_line "$key" ed25519; then
        auth_add_key "$key" ed25519 "kernel command line"
    else
        log "fallback auth: unitotem.ota.authkey is not an ed25519 key line, ignored"
    fi
    return 0
}

# auth_read_saved_slot DIR: AUTH_SAVED_SLOT = a|b from saved_entry=slot-x in DIR/unitotem-grub/grub/grubenv (PC), the slot whose
# DATA state the fallback reads when the command line carries no unitotem.slot (entry "ota-recovery" of the GRUB menu).
auth_read_saved_slot() {
    local f="$1/unitotem-grub/grub/grubenv" v
    [ -r "$f" ] || return 0
    v=$(tr -d '\000' < "$f" 2>/dev/null | grep -a '^saved_entry=' | head -1) || v=""
    case "$v" in saved_entry=slot-a*) AUTH_SAVED_SLOT=a ;; saved_entry=slot-b*) AUTH_SAVED_SLOT=b ;; esac
    return 0
}

# auth_boot_keys: unitotem-ota.authorized_keys on the boot FAT. Uses /boot-ota when mounted, else FIRMWARE or EFI
# mounted read-only on a private directory and unmounted again.
auth_boot_keys() {
    local dir="${OTA_AUTH_BOOTDIR:-}" mnt=/run/ota-auth-boot dev=""
    if [ -n "$dir" ]; then
        auth_read_keys_file "$dir/unitotem-ota.authorized_keys" "" "boot partition"
        auth_read_saved_slot "$dir"
        return 0
    fi
    if mountpoint -q /boot-ota 2>/dev/null; then
        auth_read_keys_file /boot-ota/unitotem-ota.authorized_keys "" "boot partition"
        auth_read_saved_slot /boot-ota
        return 0
    fi
    dev=$(blkid -L FIRMWARE 2>/dev/null) || dev=""
    if [ -z "$dev" ]; then
        dev=$(blkid -L EFI 2>/dev/null) || dev=""
    fi
    if [ -z "$dev" ]; then
        log "fallback auth: no FIRMWARE or EFI partition, boot keys skipped"
        return 0
    fi
    mkdir -p "$mnt" 2>/dev/null || return 0
    if mount -t vfat -o ro "$dev" "$mnt" 2>/dev/null; then
        auth_read_keys_file "$mnt/unitotem-ota.authorized_keys" "" "boot partition"
        auth_read_saved_slot "$mnt"
        umount "$mnt" 2>/dev/null || log "fallback auth: cannot unmount $mnt"
    else
        log "fallback auth: cannot mount the boot partition read-only, boot keys skipped"
    fi
    return 0
}

# auth_sudo_members GROUP_FILE: prints the members of group sudo, one per line (nothing when there are none).
auth_sudo_members() {
    local g x gid mem _rest
    local -a members=()
    [ -f "$1" ] && [ -r "$1" ] || return 0
    while IFS=: read -r g x gid mem _rest || [ -n "$g" ]; do
        if [ "$g" = sudo ]; then
            IFS=, read -ra members <<< "$mem" || true
            printf '%s\n' "${members[@]}"
            return 0
        fi
    done < "$1"
    return 0
}

# auth_shadow_hash SHADOW_FILE USER: the password field of USER (nothing when absent).
auth_shadow_hash() {
    local n h _rest
    [ -f "$1" ] && [ -r "$1" ] || return 0
    while IFS=: read -r n h _rest || [ -n "$n" ]; do
        if [ "$n" = "$2" ]; then printf '%s\n' "$h"; return 0; fi
    done < "$1"
    return 0
}

# auth_data_scan DIR: keys and admins from a DATA tree. The system slot is the one whose /etc is present, the
# current slot (unitotem.slot=) first; without one, the first slot that has a root key file.
auth_data_scan() {
    local d="$1" cur s slot="" u h dup x group_members
    local -a order=(a b)
    cur=$(auth_cmdline_get unitotem.slot) || cur="$AUTH_SAVED_SLOT"
    if [ "$cur" = b ]; then order=(b a); fi
    for s in "${order[@]}"; do
        if [ -f "$d/upper/etc.$s/group" ]; then slot=$s; break; fi
    done
    if [ -z "$slot" ]; then
        for s in "${order[@]}"; do
            if [ -f "$d/upper/root.$s/.ssh/authorized_keys" ]; then slot=$s; break; fi
        done
    fi
    if [ -z "$slot" ]; then
        log "fallback auth: DATA has no system files, only the boot keys can apply"
        return 0
    fi
    log "fallback auth: DATA slot $slot"
    auth_read_keys_file "$d/upper/root.$slot/.ssh/authorized_keys" "" "DATA root"
    group_members=$(auth_sudo_members "$d/upper/etc.$slot/group") || group_members=""
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        if ! [[ $u =~ $AUTH_NAME_RE ]] || [ "$u" = root ]; then
            log "fallback auth: sudo member with an invalid account name ignored"
            continue
        fi
        dup=0
        for x in "${AUTH_ADMINS[@]}"; do
            if [ "${x%%:*}" = "$u" ]; then dup=1; fi
        done
        if [ "$dup" = 1 ]; then continue; fi
        h=$(auth_shadow_hash "$d/upper/etc.$slot/shadow" "$u") || h=""
        if [[ $h =~ $AUTH_HASH_RE ]]; then
            AUTH_USABLE=$((AUTH_USABLE + 1))
        else
            h='*'
        fi
        AUTH_ADMINS+=("$u:$h")
        auth_read_keys_file "$d/unitotem/persist/home/$u/.ssh/authorized_keys" "" "DATA home of $u"
    done <<< "$group_members"
    return 0
}

# auth_data_read: DATA read-only on /run/ota-auth-data (or OTA_AUTH_DATADIR), always unmounted again.
auth_data_read() {
    local mnt=/run/ota-auth-data dev=""
    if [ -n "${OTA_AUTH_DATADIR:-}" ]; then
        auth_data_scan "$OTA_AUTH_DATADIR"
        return 0
    fi
    dev=$(blkid -L DATA 2>/dev/null) || dev=""
    if [ -z "$dev" ]; then
        log "fallback auth: DATA partition not found"
        return 0
    fi
    mkdir -p "$mnt" 2>/dev/null || return 0
    if mount -t ext4 -o ro "$dev" "$mnt" 2>/dev/null; then
        auth_data_scan "$mnt"
        umount "$mnt" 2>/dev/null || log "fallback auth: cannot unmount $mnt"
    else
        log "fallback auth: cannot mount DATA read-only, DATA skipped"
    fi
    return 0
}

# fallback_auth_setup: writes the fallback credentials and sets FALLBACK_OPEN (1 = open mode, dropbear -B).
# Returns non-zero, with root locked, when the files cannot be written.
fallback_auth_setup() {
    local root="${OTA_AUTH_ROOT:-}" open=0 e k
    local pw="${root}/etc/passwd" shadow="${root}/etc/shadow" ak="${root}/root/.ssh/authorized_keys"
    AUTH_KEYS=(); AUTH_ADMINS=(); AUTH_USABLE=0; FALLBACK_OPEN=0; AUTH_SAVED_SLOT=""

    auth_cmdline_key
    auth_boot_keys
    auth_data_read
    if [ "${#AUTH_KEYS[@]}" -eq 0 ] && [ "${#AUTH_ADMINS[@]}" -eq 0 ]; then open=1; fi

    mkdir -p "${root}/etc" "${root}/root/.ssh" || return 1
    chmod 700 "${root}/root/.ssh" || return 1
    (
        umask 077
        {
            printf '%s\n' 'root:x:0:0:root:/root:/bin/sh'
            for e in "${AUTH_ADMINS[@]}"; do printf '%s:x:0:0::/root:/bin/sh\n' "${e%%:*}"; done
        } > "$pw.new" && chmod 644 "$pw.new" && mv -f "$pw.new" "$pw" || exit 1
        {
            if [ "$open" = 1 ]; then printf '%s\n' 'root::19000:0:99999:7:::'; else printf '%s\n' 'root:*:19000:0:99999:7:::'; fi
            for e in "${AUTH_ADMINS[@]}"; do printf '%s:%s:19000:0:99999:7:::\n' "${e%%:*}" "${e#*:}"; done
        } > "$shadow.new" && chmod 600 "$shadow.new" && mv -f "$shadow.new" "$shadow" || exit 1
        {
            for k in "${AUTH_KEYS[@]}"; do printf '%s\n' "$k"; done
        } > "$ak.new" && chmod 600 "$ak.new" && mv -f "$ak.new" "$ak" || exit 1
    ) || return 1
    FALLBACK_OPEN=$open
    if [ "$open" = 1 ]; then
        log "fallback auth: OPEN mode (first access): no key and no admin account found, root has an empty password"
    else
        log "fallback auth: root locked (key login only); keys: ${#AUTH_KEYS[@]}, admins: ${#AUTH_ADMINS[@]}, admin passwords: $AUTH_USABLE"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# serve-fallback: the automatic-recovery / manual-arm entry point. Brings up networking, starts dropbear
# (ephemeral host key generated at every start, since a baked-in key would be shared by every image) and blocks,
# showing a whiptail screen with reachability info. Every path into OTA mode ends up here.
# ---------------------------------------------------------------------------
CONSOLE_TERM_FOR() {
    case "$1" in
        ttyS*|ttyAMA*) echo vt220 ;;
        *) echo linux ;;
    esac
}

# ---------------------------------------------------------------------------
# On-screen status. Subcommands are separate processes over SSH, so none can own the display: they publish phase
# and progress to files under /run and serve-fallback redraws a whiptail gauge from them.
# The gauge goes to /dev/tty1, not /dev/console (with console=ttyS0 last, /dev/console is the serial port).
# Two files: the phase is set once per step, pv appends a percentage per update.
# ---------------------------------------------------------------------------
OTA_STATUS_FILE=/run/unitotem-ota.status
OTA_PCT_FILE=/run/unitotem-ota.pct

# Announce a step. Clears any stale percentage so a finished transfer's 100% is not shown against the next step.
ota_status_set() {
    printf '%s\n' "${1:-}" > "$OTA_STATUS_FILE" 2>/dev/null || true
    : > "$OTA_PCT_FILE" 2>/dev/null || true
}

# Feeds whiptail's gauge protocol: an XXX-delimited block carrying the new percentage and text.
ota_ui_feed() {
    local phase pct
    while :; do
        phase=""
        [ -r "$OTA_STATUS_FILE" ] && read -r phase < "$OTA_STATUS_FILE" 2>/dev/null
        pct=""
        if [ -s "$OTA_PCT_FILE" ]; then
            # The substitution strips non-digits without tr, which is not available here.
            pct=$(tail -n1 "$OTA_PCT_FILE" 2>/dev/null)
            pct="${pct//[!0-9]/}"
        fi
        [ -n "$pct" ] || pct=0
        [ "$pct" -le 100 ] 2>/dev/null || pct=100
        # Header (3 lines) + a blank separator + the phase = 5 lines, the height ota_ui_start sizes the text area for;
        # anything beyond it is dropped.
        printf 'XXX\n%s\n%s\n\n%s\nXXX\n' "$pct" "${OTA_UI_HEADER:-}" "${phase:-Waiting for commands over SSH...}"
        sleep 1
    done
}

# Best-effort: a board with no /dev/tty1 gets no UI, which never holds up an OTA.
# setsid + opening /dev/tty1 as fd 0 gives whiptail a controlling terminal (newt opens /dev/tty and fails
# without one). The gauge is fed through a FIFO because fd 0 is the tty.
OTA_UI_FIFO=/run/unitotem-ota.gauge

ota_ui_start() {
    OTA_UI_HEADER="$1"
    [ -w /dev/tty1 ] || return 0
    command -v whiptail >/dev/null 2>&1 || return 0
    command -v setsid  >/dev/null 2>&1 || return 0
    command -v mkfifo  >/dev/null 2>&1 || return 0
    ota_status_set ""
    rm -f "$OTA_UI_FIFO" 2>/dev/null
    mkfifo "$OTA_UI_FIFO" 2>/dev/null || return 0
    # The redirections belong to setsid: setsid -c applies TIOCSCTTY to its own stdin, while a shell opening the tty
    # uses O_NOCTTY and newt would fail. The initial --gauge text has five lines because whiptail sizes the text
    # area once and clips updates to it; five is what ota_ui_feed sends (3 header + blank + phase), change both together.
    local placeholder=$' \n \n \n \n '
    # (NEWT_COLORS has no effect on this whiptail's own "+---+" border: ota_frame paints that ring of cells black on the
    # framebuffer instead.)
    setsid -c sh -c "TERM=linux TERMINFO=/lib/terminfo exec whiptail \
            --backtitle 'UniTotem OTA' --gauge '$placeholder' 14 72 0 < '$OTA_UI_FIFO'" \
        < /dev/tty1 > /dev/tty1 2>/dev/null &
    ( ota_ui_feed > "$OTA_UI_FIFO" ) &
    OTA_UI_PID=$!
}

configure_one_iface() {
    local iface="$1"
    ip link set "$iface" up 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true

    if [ "${OTA_NET_LINK:-wired}" = wifi ] && [ -n "${OTA_WIFI_SSID_B64:-}" ]; then
        local ssid psk
        ssid=$(printf '%s' "$OTA_WIFI_SSID_B64" | base64 -d)
        psk=$(printf '%s' "${OTA_WIFI_PSK_B64:-}" | base64 -d)
        wpa_passphrase "$ssid" "$psk" > /tmp/wpa.conf
        wpa_supplicant -B -i "$iface" -c /tmp/wpa.conf 2>/dev/null || warn "wpa_supplicant failed"
        sleep 3
    fi

    if [ "${OTA_NET_MODE:-dhcp}" = static ] && [ -n "${OTA_NET_ADDR:-}" ] && [ "$iface" = "${OTA_NET_IFACE:-$iface}" ]; then
        ip addr add "$OTA_NET_ADDR" dev "$iface" || true
        [ -n "${OTA_NET_GW:-}" ] && ip route replace default via "$OTA_NET_GW" dev "$iface" || true
    else
        if type configure_networking >/dev/null 2>&1; then
            # initramfs-tools' configure_networking() is not written for nounset (_set_netdev_from_ip_param reads $6 of a
            # short $IP), so nounset is disabled for this call.
            # It ends in klibc's ipconfig, which can block on DHCP ignoring its -t timeout, and there is no `timeout` here:
            # the call is backgrounded and killed by PID after a wall-clock budget (the address is read back with `ip addr show`).
            # Its stdout goes to /dev/kmsg so it does not leak into `myip=$(configure_networking_ota ...)`.
            local cn_rc=0 cn_pid cn_waited=0 cn_budget=30
            set +u
            ( IP=dhcp DEVICE="$iface" configure_networking 2>&1 \
                | while IFS= read -r cn_line; do
                      kmsg "unitotem-ota/net: $cn_line"
                  done ) &
            cn_pid=$!
            while kill -0 "$cn_pid" 2>/dev/null && [ "$cn_waited" -lt "$cn_budget" ]; do
                sleep 1
                cn_waited=$((cn_waited + 1))
            done
            if kill -0 "$cn_pid" 2>/dev/null; then
                warn "configure_networking stuck beyond ${cn_budget}s (known ipconfig bug, it ignores its own -t): killed"
                kill -9 "$cn_pid" 2>/dev/null
                # wait on a killed job reports 137, which would abort the script under set -e.
                wait "$cn_pid" 2>/dev/null || true
                # kill -9 on $cn_pid kills only the backgrounded subshell; the hung ipconfig would survive as an
                # orphan holding the interface. There is no pkill/killall in this initramfs, so walk /proc.
                for _p in /proc/[0-9]*; do
                    _p=${_p#/proc/}
                    [ -r "/proc/$_p/cmdline" ] || continue
                    # No `tr`: argv[0] comes before the first NUL, where bash's command substitution truncates.
                    case "$(cat "/proc/$_p/cmdline" 2>/dev/null)" in
                        *ipconfig*) kill -9 "$_p" 2>/dev/null || true ;;
                    esac
                done
                cn_rc=124
            else
                # wait mirrors the job's exit status, so a plain configure_networking failure (e.g. no DHCP server)
                # would abort the script here if unprotected.
                wait "$cn_pid" || cn_rc=$?
            fi
            set -u
            [ "$cn_rc" -eq 0 ] || warn "DHCP (configure_networking) failed"
        else
            ipconfig -t 10 -d "$iface" 2>/dev/null || warn "DHCP (ipconfig) failed"
        fi
    fi
    ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

# Network bring-up of the fallback: try every wired interface that has a link (the cable may be in a different port than
# the running system used), the one named in the deploy configuration first. WiFi targets keep the configured interface.
# Prints the first address obtained, nothing if none got one.
configure_networking_ota() {
    local conf=/boot-ota/unitotem-ota.conf iface addr="" ifs="" i w=0 first nw found
    [ -f "$conf" ] && read_kv_lines < "$conf"
    # Do not rely on udev's coldplug having bound a driver yet (virtio_net could be present but not loaded).
    # No-ops where these modules do not exist or are already loaded.
    modprobe -a virtio_net genet bcmgenet 2>/dev/null || true
    udevadm trigger --subsystem-match=net 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    if [ "${OTA_NET_LINK:-wired}" = wifi ]; then
        iface="${OTA_NET_IFACE:-}"
        [ -n "$iface" ] || iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
        [ -n "$iface" ] || { warn "no network interface found"; return 1; }
        configure_one_iface "$iface"
        return 0
    fi
    # A USB Ethernet adapter (Raspberry Pi 3, 3B+) shows up a few seconds after the kernel started: wait up to 30 s for a
    # physical Ethernet device before concluding there is none.
    nw=0
    while [ "$nw" -lt 30 ]; do
        found=0
        for i in /sys/class/net/*; do
            i=${i##*/}
            [ "$i" = lo ] && continue
            [ -e "/sys/class/net/$i/device" ] || continue
            [ "$(cat /sys/class/net/$i/type 2>/dev/null)" = 1 ] || continue
            [ -d "/sys/class/net/$i/wireless" ] && continue
            found=1; break
        done
        [ "$found" = 1 ] && break
        sleep 1; nw=$((nw + 1))
        [ $((nw % 5)) = 0 ] && udevadm trigger --subsystem-match=net 2>/dev/null
    done
    # physical Ethernet devices only (no lo, bridges, veth, tunnels)
    for i in /sys/class/net/*; do
        i=${i##*/}
        [ "$i" = lo ] && continue
        [ -e "/sys/class/net/$i/device" ] || continue
        [ "$(cat /sys/class/net/$i/type 2>/dev/null)" = 1 ] || continue
        [ -d "/sys/class/net/$i/wireless" ] && continue
        ifs="$ifs $i"
        ip link set "$i" up 2>/dev/null || true
    done
    if [ -z "$ifs" ]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
        [ -n "$iface" ] || { warn "no network interface found"; return 1; }
        ifs=" $iface"
    fi
    # give the links a few seconds to negotiate, then order: with carrier first, the configured interface first among them
    while [ "$w" -lt 12 ]; do
        for i in $ifs; do [ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" = 1 ] && break 2; done
        sleep 1; w=$((w + 1))
    done
    first=""
    for i in $ifs; do
        [ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" = 1 ] || continue
        if [ "$i" = "${OTA_NET_IFACE:-}" ]; then first="$i $first"; else first="$first $i"; fi
    done
    for i in $ifs; do case " $first " in *" $i "*) ;; *) first="$first $i" ;; esac; done   # no-carrier ones last, as a final resort
    for i in $first; do
        addr=$(configure_one_iface "$i")
        addr=${addr%%$'\n'*}
        if [ -n "$addr" ]; then
            kmsg "unitotem-ota/net: address $addr on $i"
            printf '%s\n' "$addr"
            return 0
        fi
        warn "no address on $i, trying the next interface"
    done
    return 1
}

# PWR and ACT blink in alternation for the whole OTA session ("maintenance mode"). Called from cmd_serve_fallback;
# best-effort and silent (amd64 has no such sysfs path; each LED is handled independently).
# The timer trigger starts a LED in the ON phase, so the second is armed half a period later to alternate.
# The wait is a bash busy-loop on EPOCHREALTIME because klibc's sleep parses whole seconds only (~500ms of CPU).
ota_led_maintenance() {
    local half_ms=500
    local have_pwr=0 have_act=0
    [ -w /sys/class/leds/PWR/trigger ] && have_pwr=1
    [ -w /sys/class/leds/ACT/trigger ] && have_act=1
    [ "$have_pwr" = 1 ] || [ "$have_act" = 1 ] || return 0

    _led_arm() {
        local led="$1"
        echo timer      > "/sys/class/leds/${led}/trigger"   2>/dev/null || return 0
        echo "$half_ms" > "/sys/class/leds/${led}/delay_on"  2>/dev/null || true
        echo "$half_ms" > "/sys/class/leds/${led}/delay_off" 2>/dev/null || true
    }

    [ "$have_pwr" = 1 ] && _led_arm PWR

    # Only worth offsetting when both LEDs are driven. The [.,] pattern is needed because EPOCHREALTIME uses the
    # LC_NUMERIC decimal separator (a comma under it_IT.UTF-8). $SECONDS caps the spin at ~3s so a malformed
    # EPOCHREALTIME can never hang the fallback.
    if [ "$have_pwr" = 1 ] && [ "$have_act" = 1 ] && [ -n "${EPOCHREALTIME:-}" ]; then
        local t0="${EPOCHREALTIME/[.,]/}"
        local target=$(( half_ms * 1000 ))
        local guard=$SECONDS
        while (( ${EPOCHREALTIME/[.,]/} - t0 < target )); do
            (( SECONDS - guard < 3 )) || break
        done
    fi

    [ "$have_act" = 1 ] && _led_arm ACT
    return 0
}

# ota_idle_watchdog SECONDS : leave the fallback by rebooting if no host logs in to dropbear within SECONDS, so a transient
# trigger does not leave the device waiting indefinitely. A TCP connection alone does not count: the watchdog stands down
# once dropbear logs a successful authentication (password, key or blank password, see serve-fallback's log file). 0 = never.
ota_idle_watchdog() {
    local limit="${1:-0}" waited=0
    [ "$limit" -gt 0 ] 2>/dev/null || return 0
    while [ "$waited" -lt "$limit" ]; do
        sleep 5; waited=$((waited + 5))
        # dropbear -E: "Password auth succeeded for ...", "Pubkey auth succeeded for ...", "Auth succeeded with blank password for ..."
        grep -q 'uth succeeded' /run/ota-dropbear.log 2>/dev/null && return 0
    done
    log "no host connected within ${limit}s: rebooting to retry the normal boot"
    sync
    reboot -f
}

# ota_splash TITLE LINE : paint the console right away (logo, what is happening, what to expect) so the screen is not
# empty while the network comes up (about ten seconds). Plain text on tty1, best effort.
# ota_logo writes the UniTotem wordmark of the manager's Plymouth theme, pre-rendered (tools/gen-logo.py) to raw pixels,
# straight to the framebuffer (this initramfs has no image decoder). Returns 1 if there is no usable framebuffer or logo,
# so the caller falls back to text.
OTA_LOGO_DIR=${OTA_LOGO_DIR:-/usr/lib/unitotem}
ota_logo() {
    local fb=/sys/class/graphics/fb0 W H bpp stride logo lw lh y0 x0 r
    [ -w /dev/fb0 ] && [ -r "$fb/virtual_size" ] && [ -r "$fb/bits_per_pixel" ] && [ -r "$fb/stride" ] || return 1
    IFS=, read -r W H < "$fb/virtual_size"; read -r bpp < "$fb/bits_per_pixel"; read -r stride < "$fb/stride"
    # 32 bpp: the KMS framebuffer (real system); 16 bpp: the firmware framebuffer of the resident Pi fallback (RGB565)
    local ext bytes
    case "$bpp" in 32) ext=bgrx; bytes=4 ;; 16) ext=rgb565; bytes=2 ;; *) return 1 ;; esac
    # two sizes: a small one for the 640x480 update screen, a large one for native-resolution screens
    if [ "$W" -le 800 ]; then logo=$OTA_LOGO_DIR/unitotem-logo-256x73.$ext; lw=256; lh=73
    else logo=$OTA_LOGO_DIR/unitotem-logo-640x182.$ext; lw=640; lh=182; fi
    [ -r "$logo" ] && [ "$W" -ge "$lw" ] && [ "$H" -ge $((lh + 40)) ] || return 1
    x0=$(( (W - lw) / 2 )); y0=32
    for ((r = 0; r < lh; r++)); do
        dd if="$logo" of=/dev/fb0 bs=$((lw * bytes)) skip=$r count=1 seek=$(( (y0 + r) * stride + x0 * bytes )) \
           oflag=seek_bytes conv=notrunc status=none 2>/dev/null || return 1
    done
    return 0
}

# A rounded frame around the progress dialog, drawn on the framebuffer for any resolution.
# Geometry: console columns/rows (stty), cell size = framebuffer / console size, dialog centered by newt (72x14
# cells, fewer on small screens). whiptail's own border ring is painted black (it redraws only changed cells), then
# the frame is laid out in the margin: pre-rendered anti-aliased corners sized from the cell height, straight edges
# cut from a solid-colour line. Only the frame and blank ring are written, never the interior. Formats: 32/24/16 bpp.
# Returns 1 (and says why on stderr) if there is no usable framebuffer.
ota_frame() {
    # OTA_FB_DEV / OTA_FB_SYS / OTA_CONSOLE_SIZE ("rows cols") replace the real devices, so the layout can be tested on
    # fake framebuffers of many sizes and depths.
    local fb=${OTA_FB_SYS:-/sys/class/graphics/fb0} fbdev=${OTA_FB_DEV:-/dev/fb0} W H bpp stride ext bytes rows cols cw ch
    [ -w "$fbdev" ] && [ -r "$fb/virtual_size" ] || { echo "ota_frame: no framebuffer" >&2; return 1; }
    IFS=, read -r W H < "$fb/virtual_size"; read -r bpp < "$fb/bits_per_pixel"; read -r stride < "$fb/stride"
    case "$bpp" in
        32) ext=bgrx; bytes=4 ;; 24) ext=bgr24; bytes=3 ;; 16) ext=rgb565; bytes=2 ;;
        *) echo "ota_frame: unsupported framebuffer depth $bpp" >&2; return 1 ;;
    esac
    if read -r rows cols < <(if [ -n "${OTA_CONSOLE_SIZE:-}" ]; then echo "$OTA_CONSOLE_SIZE"; else stty -F /dev/tty1 size 2>/dev/null; fi) \
        && [ "${cols:-0}" -gt 0 ] && [ "${rows:-0}" -gt 0 ]; then
        cw=$((W / cols)); ch=$((H / rows))
    else                                   # no stty: the usual fbcon fonts, 8x16 and 16x32 on large screens
        cw=8; ch=16; [ "$W" -gt 1024 ] && { cw=16; ch=32; }
        cols=$((W / cw)); rows=$((H / ch))
    fi
    [ "$cw" -ge 4 ] && [ "$ch" -ge 8 ] || { echo "ota_frame: implausible cell size ${cw}x${ch}" >&2; return 1; }

    # the dialog (ota_ui_start asks for 72x14 cells; newt shrinks it on a small console and centers it)
    local dw=72 dh=14 dx0 dy0 dx1 dy1
    [ "$cols" -ge $((dw + 4)) ] || dw=$((cols - 4)); [ "$rows" -ge $((dh + 2)) ] || dh=$((rows - 2))
    dx0=$(( (cols - dw) / 2 * cw )); dy0=$(( (rows - dh) / 2 * ch )); dx1=$((dx0 + dw * cw)); dy1=$((dy0 + dh * ch))

    wr() { # wr SRC_FILE SKIP_BYTES X Y LEN_BYTES : copy LEN bytes of SRC (from SKIP) to pixel (X,Y)
        dd if="$1" iflag=skip_bytes skip="$2" of="$fbdev" bs="$5" count=1 seek=$(( $4 * stride + $3 * bytes )) \
           oflag=seek_bytes conv=notrunc status=none 2>/dev/null
    }
    local y
    # 1. blank whiptail's own border: the ring of cells around the dialog
    for ((y = dy0; y < dy0 + ch; y++)); do wr /dev/zero 0 "$dx0" "$y" $(( (dx1 - dx0) * bytes )) || return 1; done
    for ((y = dy1 - ch; y < dy1; y++)); do wr /dev/zero 0 "$dx0" "$y" $(( (dx1 - dx0) * bytes )) || return 1; done
    for ((y = dy0 + ch; y < dy1 - ch; y++)); do
        wr /dev/zero 0 "$dx0" "$y" $((cw * bytes)) || return 1
        wr /dev/zero 0 $((dx1 - cw)) "$y" $((cw * bytes)) || return 1
    done

    # 2. the frame, in the margin outside the dialog
    local r t m fx0 fy0 fx1 fy1 d=$OTA_LOGO_DIR
    r=12; t=2
    local cand
    for cand in 64:13 48:10 32:6 24:5 16:3 12:2; do
        [ "${cand%%:*}" -le "$ch" ] && { r=${cand%%:*}; t=${cand##*:}; break; }
    done
    m=$(( cw * 3 / 4 )); [ "$m" -ge 4 ] || m=4
    fx0=$((dx0 - m)); fy0=$((dy0 - m)); fx1=$((dx1 + m)); fy1=$((dy1 + m))
    [ "$fx0" -ge 0 ] && [ "$fy0" -ge 0 ] && [ "$fx1" -le "$W" ] && [ "$fy1" -le "$H" ] \
        || { echo "ota_frame: the frame does not fit the screen" >&2; return 1; }
    local cf="$d/unitotem-frame-corners-$r.$ext" lf="$d/unitotem-frame-line.$ext" rb=$((r * bytes)) csz=$((r * r * bytes))
    [ -r "$cf" ] && [ -r "$lf" ] || { echo "ota_frame: frame pieces missing in $d" >&2; return 1; }
    for ((y = 0; y < r; y++)); do
        wr "$cf" $((0 * csz + y * rb)) "$fx0"        $((fy0 + y))       "$rb" || return 1     # top-left
        wr "$cf" $((1 * csz + y * rb)) $((fx1 - r))  $((fy0 + y))       "$rb" || return 1     # top-right
        wr "$cf" $((2 * csz + y * rb)) "$fx0"        $((fy1 - r + y))   "$rb" || return 1     # bottom-left
        wr "$cf" $((3 * csz + y * rb)) $((fx1 - r))  $((fy1 - r + y))   "$rb" || return 1     # bottom-right
    done
    local len=$((fx1 - fx0 - 2 * r)) x done_len chunk
    for ((y = 0; y < t; y++)); do                      # top and bottom edges, in chunks of at most 4096 px (the line blob)
        x=$((fx0 + r)); done_len=0
        while [ "$done_len" -lt "$len" ]; do
            chunk=$((len - done_len)); [ "$chunk" -le 4096 ] || chunk=4096
            wr "$lf" 0 "$x" $((fy0 + y)) $((chunk * bytes)) || return 1
            wr "$lf" 0 "$x" $((fy1 - t + y)) $((chunk * bytes)) || return 1
            x=$((x + chunk)); done_len=$((done_len + chunk))
        done
    done
    for ((y = fy0 + r; y < fy1 - r; y++)); do          # left and right edges
        wr "$lf" 0 "$fx0" "$y" $((t * bytes)) || return 1
        wr "$lf" 0 $((fx1 - t)) "$y" $((t * bytes)) || return 1
    done
    return 0
}

ota_splash() {
    [ -w /dev/tty1 ] || return 0
    printf '\033[2J\033[H\033[?25l' > /dev/tty1 2>/dev/null || true
    local row=2
    if ota_logo; then
        row=12     # below the bitmap (16 px text rows at 640x480; the logo spans rows 2..7 there, 2..13 at native size)
        printf '\033[%d;1H' "$row" > /dev/tty1 2>/dev/null || true
    else
        {
            printf '\033[1;36m\n\n\n'
            printf '      _   _       _ _____       _\n'
            printf '     | | | |_ __ (_)_   _|__ __| |_ ___ _ __ ___\n'
            printf '     | | | | '"'"'_ \| | | |/ _ \ _|  _/ _ \ '"'"'_ ` _ \\\n'
            printf '     | |_| | | | | | | | (_) | |_| ||  __/ | | | | |\n'
            printf '      \___/|_| |_|_| |_|\___/ \__|\__\___|_| |_| |_|\n'
            printf '\033[0m'
        } > /dev/tty1 2>/dev/null || true
    fi
    printf '\n\n     %s\n\n     %s\n' "${1:-}" "${2:-}" > /dev/tty1 2>/dev/null || true
}

# The last thing an update shows before the machine restarts.
ota_final_status() {
    ota_status_set "Update written. Restarting into the new system..."
    echo 100 > "$OTA_PCT_FILE" 2>/dev/null || true
}

cmd_serve_fallback() {
    parse_args "$@"
    # The screen is the progress dialog: kernel messages only for emergencies, and this process's own stdout/stderr go to
    # a file instead of the console (they stay in the kernel log at debug level, see kmsg/log).
    echo "1 4 1 7" > /proc/sys/kernel/printk 2>/dev/null || true
    exec >> /run/ota-serve.log 2>&1
    local reason="${ARG[reason]:-requested explicitly}"
    log "OTA mode: $reason"
    if [ "${ARG[kind]:-update}" = recovery ]; then
        ota_splash "OTA recovery mode" "A fault was detected: $reason. Starting the network, please wait..."
    else
        ota_splash "OTA update mode" "Starting the network, please wait..."
    fi
    # Default wait for a host is 10 minutes; callers override it with idle-timeout (`recover` waits forever).
    ( ota_idle_watchdog "${ARG[idle-timeout]:-600}" ) </dev/null >/dev/null 2>&1 &

    ota_led_maintenance

    local myip; myip=$(configure_networking_ota || true)
    # No address yet (an adapter that appears late): keep trying in the background for about 35 minutes. dropbear listens on
    # every interface, so it answers as soon as one has an address.
    if [ -z "$myip" ]; then
        (
            rn=0
            while [ "$rn" -lt 60 ]; do
                [ -n "$(configure_networking_ota 2>/dev/null || true)" ] && break
                rn=$((rn + 1)); sleep 5
            done
        ) </dev/null >/dev/null 2>&1 &
    fi

    mkdir -p /run/dropbear
    dropbearkey -t ed25519 -f /run/dropbear_ed25519_host_key >/dev/null 2>&1 \
        || warn "dropbear key generation failed"

    # systemd's reboot binary (copied by unitotem/files/ota-hook so that "reboot -f '0 tryboot'" reaches the kernel)
    # writes its parameter to /run/systemd/reboot-param and fails without this directory; nothing else in this initrd
    # creates it.
    mkdir -p /run/systemd

    # Fallback root credentials are written at run time by fallback_auth_setup, called right before dropbear.

    # The gauge stays up for the whole session (a one-shot --infobox would be overwritten; /dev/console is the serial
    # port, see ota_ui_start). `|| true` is required: a `||` context suppresses errexit and the ERR trap for the whole
    # function body, so a broken UI can fail to draw but never aborts serve-fallback.
    # "recovery" in the title is reserved for faults the device detected itself; an update is the default.
    local kind_title="OTA update mode"
    [ "${ARG[kind]:-update}" = recovery ] && kind_title="OTA recovery mode"
    ota_ui_start "${kind_title}
Reason: ${reason}
Address: ${myip:-none}   Port: 2222" || true
    # the progress screen clears the console when it starts: put the logo back above it once it is up
    ( sleep 2; ota_logo; ota_frame ) </dev/null >/dev/null 2>&1 &

    # Fallback credentials and mode. The `||` context keeps a failed DATA or boot mount from aborting here: the
    # credentials then stay locked (FALLBACK_OPEN=0).
    fallback_auth_setup || warn "fallback credentials not written: root login stays locked"
    # dropbear -E logs "[pid] date time message"; every line is relabelled with the program name, dropping the pid. A
    # bash read loop is used because sed/awk are not guaranteed in the minimal fallback. The pipeline is what blocks:
    # dropbear runs with -F and never returns, and if it does, park here instead of falling through into a normal boot.
    # The console belongs to the progress screen: dropbear's log goes to a file and to the kernel log at debug level.
    # -T 3: three auth tries. -j -k: no local or remote port forwarding. -B (blank passwords) only in open mode.
    local -a dbopts=(-F -E -p 2222 -r /run/dropbear_ed25519_host_key -T 3 -j -k)
    if [ "$FALLBACK_OPEN" = 1 ]; then dbopts+=(-B); fi
    dropbear "${dbopts[@]}" 2>&1 \
        | while IFS= read -r line; do
              printf 'dropbear: %s\n' "${line#\[*\] }" >> /run/ota-dropbear.log
              kmsg "dropbear: ${line#\[*\] }"
          done
    warn "dropbear exited unexpectedly: staying in OTA mode"
    while :; do sleep 3600; done
}

# ---------------------------------------------------------------------------
# init-premount entry point: decide whether to enter OTA mode, and why (explicit flag file or cmdline, or a failed
# pre-mount integrity check). The flag file is self-clearing: mount ro, stat, remount rw, read into memory, rm, sync,
# umount, and only then act, so a crash after the rm resumes a normal boot instead of looping.
# ---------------------------------------------------------------------------
cmdline_get() {
    local tok c; c=$(cat /proc/cmdline)
    for tok in $c; do
        case "$tok" in "$1="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac
    done
    return 1
}

check_flag_file() {
    local label="$1" fstype="$2" mnt=/boot-ota dev tries=0
    # blkid -L can race udev this early in boot (as for DATA in unitotem/files/overlayfs-hook.sh), and a single settle
    # is not always enough, so retry. The bound is small because this runs on every boot.
    dev=$(blkid -L "$label" 2>/dev/null) || true
    while [ -z "$dev" ] && [ "$tries" -lt 5 ]; do
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 1
        dev=$(blkid -L "$label" 2>/dev/null) || true
        tries=$((tries + 1))
    done
    [ -n "$dev" ] || return 1
    mkdir -p "$mnt"
    mount -t "$fstype" -o ro "$dev" "$mnt" 2>/dev/null || return 1
    if [ -f "$mnt/unitotem-ota.request" ]; then
        mount -o remount,rw "$mnt" 2>/dev/null || { umount "$mnt"; return 1; }
        cat "$mnt/unitotem-ota.request" > /tmp/unitotem-ota.request
        rm -f "$mnt/unitotem-ota.request"
        sync
        mount -o remount,ro "$mnt" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Boot counter, every layout (A/B, single root, Raspberry without tryboot, amd64 UEFI and BIOS). The file
# unitotem-ota.bootcount on the boot FAT holds "N\n" (N 0..9); anything else counts as 0. Each boot that reaches
# bootcount_gate adds 1, and the userspace health gate writes 0 once the manager is healthy. At 3 or more the boot
# is served by the OTA fallback instead of the root: the count is set to 2, so the first normal boot after the
# recovery session counts 3, and a boot that fails again returns to recovery. The file is rewritten in place
# (same size), so no FAT allocation changes on every boot.
OTA_BOOTFS_MNT=${OTA_BOOTFS_MNT:-/boot-ota}
BOOTCOUNT_RECOVERY=0

# bootcount_read: prints the count (0 when the file is absent or not exactly "N\n").
bootcount_read() {
    local LC_ALL=C f="$OTA_BOOTFS_MNT/unitotem-ota.bootcount" raw=""
    [ -f "$f" ] && read -r -N 3 raw < "$f" || true
    case "$raw" in
        [0-9]$'\n') printf '%s\n' "${raw%?}" ;;
        *) printf '0\n' ;;
    esac
}

# bootcount_write N: stores N (0..9). Remount rw, one write, sync, remount ro; never retried. Returns 1 when the
# boot FAT is not mounted or not writable.
bootcount_write() {
    local LC_ALL=C n="$1" f="$OTA_BOOTFS_MNT/unitotem-ota.bootcount" raw="" rc=0
    case "$n" in [0-9]) ;; *) return 1 ;; esac
    mountpoint -q "$OTA_BOOTFS_MNT" 2>/dev/null || return 1
    mount -o remount,rw "$OTA_BOOTFS_MNT" 2>/dev/null || return 1
    # Two bytes exactly: rewritten in place. Absent or any other size: created anew (once).
    if [ -f "$f" ]; then read -r -N 3 raw < "$f" || true; fi
    if [ "${#raw}" = 2 ]; then
        printf '%s\n' "$n" | dd of="$f" conv=notrunc bs=2 count=1 2>/dev/null || rc=1
    else
        printf '%s\n' "$n" > "$f" 2>/dev/null || rc=1
    fi
    sync
    mount -o remount,ro "$OTA_BOOTFS_MNT" 2>/dev/null || true
    return "$rc"
}

# bootcount_gate: the counter decision for this boot. Sets BOOTCOUNT_RECOVERY=1 when the OTA fallback was entered
# (serve-fallback blocks; it returns only in tests). The legacy trial token unitotem.ota.bootcount on the command
# line starts the count fresh. Never aborts the boot on a write failure.
bootcount_gate() {
    local n
    BOOTCOUNT_RECOVERY=0
    if cmdline_get unitotem.ota.bootcount >/dev/null 2>&1; then
        n=0
    else
        n=$(bootcount_read)
    fi
    if [ "$n" -ge 3 ]; then
        bootcount_write 2 || warn "cannot update the boot counter before recovery (non-fatal)"
        sync
        BOOTCOUNT_RECOVERY=1
        cmd_serve_fallback --reason "three consecutive boots without a healthy manager" --kind recovery --idle-timeout 21600
        return 0
    fi
    bootcount_write $((n + 1)) || warn "cannot update the boot counter (non-fatal)"
    return 0
}

# Self-healing boot, initramfs half. The slot GRUB/the Pi firmware chose has a root that is missing or fails the read-only
# check: if the other slot is sound, make it the default and reboot into it (the running system then repairs the damaged
# one, see unitotem-update repair). Returns 1 whenever it cannot (no A/B, other slot not sound, already failed over once):
# the caller then goes to the OTA fallback and waits for a host. The guard file is written before the switch and removed
# by userspace once a system has come up, so two flaky slots cannot make the device ping-pong forever.
ab_failover() {
    local cur other odev guard=/boot-ota/unitotem-ota.failover
    cur=$(cmdline_get unitotem.slot 2>/dev/null) || return 1
    case "$cur" in a) other=b ;; b) other=a ;; *) return 1 ;; esac
    mountpoint -q /boot-ota || return 1
    [ ! -e "$guard" ] || { warn "failover already done once without a successful boot: not switching again"; return 1; }
    case "$other" in a) odev=$(blkid -L ROOT_A 2>/dev/null) ;; b) odev=$(blkid -L ROOT_B 2>/dev/null) ;; esac
    [ -n "$odev" ] || return 1
    check_root_readonly "$odev" || return 1
    mkdir -p /tmp/ota-failover-root
    mount -t ext4 -o ro "$odev" /tmp/ota-failover-root 2>/dev/null || return 1
    local sound=1; [ -f /tmp/ota-failover-root/etc/unitotem/ota-preserve.list ] || sound=0
    umount /tmp/ota-failover-root 2>/dev/null || true
    [ "$sound" = 1 ] || return 1
    mount -o remount,rw /boot-ota 2>/dev/null || return 1
    echo "$cur->$other" > "$guard" || { mount -o remount,ro /boot-ota 2>/dev/null; return 1; }
    if grep -qs 'Raspberry Pi' /proc/device-tree/model; then
        # the firmware picks the slot through os_prefix in config.txt (a half-armed tryboot.txt must not override it)
        grep -q '^os_prefix=' /boot-ota/config.txt 2>/dev/null || { rm -f "$guard"; mount -o remount,ro /boot-ota 2>/dev/null; return 1; }
        sed "s|^os_prefix=.*|os_prefix=slot${other}/|" /boot-ota/config.txt > /boot-ota/config.txt.new && mv -f /boot-ota/config.txt.new /boot-ota/config.txt \
            || { rm -f "$guard"; mount -o remount,ro /boot-ota 2>/dev/null; return 1; }
        rm -f /boot-ota/tryboot.txt
    else
        local genv=/boot-ota/unitotem-grub/grub/grubenv
        [ -f "$genv" ] || { rm -f "$guard"; mount -o remount,ro /boot-ota 2>/dev/null; return 1; }
        # keep every variable except the two that choose the boot, which are rewritten
        local keep=() kv
        while IFS= read -r kv; do
            case "$kv" in \#*|"") continue ;; saved_entry=*|next_entry=*) continue ;; esac
            keep+=("$kv")
        done < "$genv"
        grubenv_write "$genv" "${keep[@]}" "saved_entry=slot-${other}" || { rm -f "$guard"; mount -o remount,ro /boot-ota 2>/dev/null; return 1; }
    fi
    sync
    warn "slot ${cur} is unusable, slot ${other} is sound: switching the default and rebooting"
    reboot -f
    sleep 30
    return 0
}

cmd_init_premount() {
    modprobe ext4 2>/dev/null || true
    modprobe vfat 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    if cmdline_get unitotem.ota >/dev/null 2>&1; then
        local mode; mode=$(cmdline_get unitotem.ota)
        [ "$mode" = "1" ] || [ "$mode" = "recover" ] || return 0
        cmd_serve_fallback --reason "kernel command line unitotem.ota=$mode" --kind "$([ "$mode" = recover ] && echo recovery || echo update)" --idle-timeout "$([ "$mode" = recover ] && echo 0 || echo 1800)"
        return
    fi

    # Only the boot partition that exists on this board is looked for: a Pi has FIRMWARE and no EFI, a PC the reverse,
    # and check_flag_file retries a missing label for ~5 s.
    local bootfs_label=FIRMWARE
    grep -qs 'Raspberry Pi' /proc/device-tree/model || bootfs_label=EFI   # amd64 images (UEFI or BIOS boot) carry the EFI partition
    if check_flag_file "$bootfs_label" vfat; then
        cmd_serve_fallback --reason "update requested by the host" --kind update --idle-timeout 1800
        return
    fi

    # The slot to validate is the one the bootloader chose, named in root= on the command line (ROOT_A or ROOT_B).
    local root_label root_dev tries=0
    root_label=$(cmdline_get root 2>/dev/null || true)
    case "$root_label" in LABEL=*) root_label=${root_label#LABEL=} ;; *) root_label=ROOT ;; esac
    root_dev=$(blkid -L "$root_label" 2>/dev/null || true)
    while [ -z "$root_dev" ] && [ "$tries" -lt 5 ]; do
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 1
        root_dev=$(blkid -L "$root_label" 2>/dev/null || true)
        tries=$((tries + 1))
    done
    if [ -z "$root_dev" ]; then
        ab_failover && return
        cmd_serve_fallback --reason "partition $root_label not found" --kind recovery --idle-timeout 21600
        return
    fi
    if ! check_root_readonly "$root_dev"; then
        ab_failover && return
        cmd_serve_fallback --reason "unrepaired filesystem errors on $root_label" --kind recovery --idle-timeout 21600
        return
    fi

    mkdir -p "$OTA_BOOTFS_MNT"
    # Boot counter (every layout). /boot-ota is still mounted read-only by check_flag_file and is reused: a second
    # mount of the same device would get the existing read-only superblock. Three failed boots enter the fallback
    # from the gate; it blocks in serve-fallback with the boot FAT still mounted (its boot keys are read from there).
    bootcount_gate
    if [ "$BOOTCOUNT_RECOVERY" = 1 ]; then
        return 0
    fi
    # /boot-ota must never be left mounted across switch_root: it is a block-device mount inside the initramfs tmpfs,
    # which switch_root does not move or clean up. Left mounted, the system's boot-firmware.mount fails with EBUSY on
    # every boot (the device stays referenced by the orphaned mount) and boot ends in emergency mode.
    umount "$OTA_BOOTFS_MNT" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# local-bottom verify: post-mount sanity on the real rootfs, before
# overlayfs-hook.sh stacks the DATA overlay on top.
# ---------------------------------------------------------------------------
cmd_local_bottom_verify() {
    parse_args "$@"
    need rootmnt
    local rootmnt="${ARG[rootmnt]}"
    if [ ! -x "$rootmnt/sbin/init" ] && [ ! -x "$rootmnt/usr/lib/systemd/systemd" ]; then
        warn "init missing on $rootmnt - switching to OTA mode"
        umount -lf "$rootmnt" 2>/dev/null || true
        cmd_serve_fallback --reason "/sbin/init missing on the mounted filesystem" --kind recovery --idle-timeout 21600
        return
    fi
    if [ ! -f "$rootmnt/etc/unitotem/ota-preserve.list" ]; then
        warn "/etc/unitotem missing on $rootmnt - switching to OTA mode"
        umount -lf "$rootmnt" 2>/dev/null || true
        cmd_serve_fallback --reason "/etc/unitotem missing on the mounted filesystem" --kind recovery --idle-timeout 21600
        return
    fi
}

# ---------------------------------------------------------------------------
main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        probe)                 cmd_probe "$@" ;;
        restore-table)         cmd_restore_table "$@" ;;
        restore-part)          cmd_restore_part "$@" ;;
        data-op)                cmd_data_op "$@" ;;
        format-part)            cmd_format_part "$@" ;;
        write-bootfile)         cmd_write_bootfile "$@" ;;
        read-bootfile)          cmd_read_bootfile "$@" ;;
        prepare-bootfs)         cmd_prepare_bootfs "$@" ;;
        populate-bootfs)        cmd_populate_bootfs "$@" ;;
        set-default-recovery)   cmd_set_default_recovery "$@" ;;
        set-trial-boot)         cmd_set_trial_boot "$@" ;;
        promote-default)        cmd_promote_default "$@" ;;
        mount-target)           cmd_mount_target "$@" ;;
        umount-target)          cmd_umount_target "$@" ;;
        populate-real-kernel)   cmd_populate_real_kernel "$@" ;;
        migrate-etc-overlay)    cmd_migrate_etc_overlay "$@" ;;
        apply-network)          cmd_apply_network "$@" ;;
        serve-fallback)         cmd_serve_fallback "$@" ;;
        init-premount)          cmd_init_premount "$@" ;;
        local-bottom-verify)    cmd_local_bottom_verify "$@" ;;
        *) echo "Unknown subcommand: $sub" >&2; exit 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    main "$@"
fi
