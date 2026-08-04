#!/bin/bash
# Shared OTA engine: every operation deploy/remote-deploy.sh needs on a
# target, exposed as subcommands driven over SSH (control channel) with bulk
# partition data pulled over a plain netcat connection (data channel) - see
# the OTA redesign plan for why the control channel is SSH rather than a
# hand-rolled protocol (deploy/ota-commands.md documents this CLI).
#
# Installed at /usr/lib/unitotem/ota-engine.sh (symlinked from
# /usr/sbin/unitotem-ota-engine) inside the rootfs by kiosk/stage1-packages.sh,
# so it ships both in the resident fallback initrd (kiosk/stage1-recovery-initrd.sh,
# built from that same stage1 rootfs) and in the real system's own initramfs
# (kiosk/stage2-configure.sh installs the init-premount/local-bottom wrappers
# that call it). Every subcommand below takes its own --disk, so it is also
# runnable standalone on any Linux box (against a loop device instead of a
# real disk) with no initramfs involved at all - what makes the host-side
# loopback verification loop possible without a VM or real hardware (see
# the plan's verification section). Only init-premount/serve-fallback/
# local-bottom-verify assume they are actually running inside an initramfs.
#
# Bash on purpose (not dash): needs pipefail, /dev/tcp, and process
# substitution for the progress gauge - this initrd already carries bash for
# it (see kiosk/files/ota-hook).
set -Eeuo pipefail
. /scripts/functions 2>/dev/null || true   # only present inside an initramfs

# stderr, never stdout: several callers capture a function's real output via
# $(...) (configure_networking_ota's returned IP, cmd_probe's KEY=VALUE
# lines, etc.) - a log()/warn() call anywhere in that function must not leak
# into the captured value. Confirmed happening for real: a network warning
# during configure_networking_ota ended up as cmd_serve_fallback's "myip",
# shown as the address in the OTA whiptail screen instead of any real IP.
log()  { echo "unitotem-ota: $*" >&2; echo "unitotem-ota: $*" > /dev/kmsg 2>/dev/null || true; }
warn() { log "ATTENZIONE: $*"; }

# ---------------------------------------------------------------------------
# Reused verbatim from the old whole-disk flasher script (removed from the
# repo once this two-stage design replaced it - see PLAN.md's history for why
# each of these looks the way it does: two real races and one bitmask
# footgun, all found in earlier live testing).
# ---------------------------------------------------------------------------
pdev_target() {
    case "$1" in
        *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
        *)                      echo "${1}${2}" ;;
    esac
}

partnum_of() { printf '%s\n' "${1##*[!0-9]}"; }

# Mount a boot-fs device for writing, tolerating it already being mounted
# read-only elsewhere - which it always is on the resident fallback, where
# /boot-ota stays mounted ro for the whole session (bootcount/flag reads,
# unitotem-ota.conf). Confirmed as a real bug on hardware, not theoretical:
# a plain `mount -t vfat "$dev" "$mnt"` here silently degrades to read-only
# (libmount prints "source write-protected, mounted read-only") whenever the
# kernel already has the same block device mounted ro somewhere else - Linux
# won't hand out a second, independent read-write superblock for a device
# that already has an active reader. Reusing the existing mount (remounted
# rw, bind-mounted to the caller's expected path) avoids that entirely.
ota_mount_bootfs_rw() {
    local dev="$1" mnt="$2" existing
    mkdir -p "$mnt"
    mountpoint -q "$mnt" && { mount -o remount,rw "$mnt" 2>/dev/null || true; return 0; }
    existing=$(awk -v d="$dev" '$1==d{print $2; exit}' /proc/mounts)
    if [ -n "$existing" ]; then
        mount -o remount,rw "$existing" || fail "remount rw di $existing ($dev) fallito"
        mount --bind "$existing" "$mnt" || fail "bind-mount di $existing su $mnt fallito"
    else
        mount -t vfat "$dev" "$mnt" || fail "mount bootfs ($dev) fallito"
    fi
}

# Companion to ota_mount_bootfs_rw: unmount the caller's path, and if the
# device is still mounted elsewhere (the persistent /boot-ota reader), put
# that back to read-only rather than leaving it writable for the rest of the
# session outside an explicit write operation.
ota_umount_bootfs_rw() {
    local dev="$1" mnt="$2" existing
    umount "$mnt" 2>/dev/null || true
    existing=$(awk -v d="$dev" '$1==d{print $2; exit}' /proc/mounts)
    [ -n "$existing" ] && mount -o remount,ro "$existing" 2>/dev/null || true
}

run_e2fsck() {
    local rc=0
    e2fsck -fy "$1" || rc=$?
    [ "$rc" -lt 4 ] || fail "e2fsck ha rilevato errori non corretti su $1 (rc=$rc)"
}

resolve_disk() {
    local path="$1" tries=0 resolved
    while [ ! -e "$path" ] && [ "$tries" -lt 30 ]; do
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 1
        tries=$((tries + 1))
    done
    [ -e "$path" ] || fail "dispositivo non trovato: $path"
    resolved=$(readlink -f "$path")
    tries=0
    while [ ! -b "$resolved" ] && [ "$tries" -lt 15 ]; do
        udevadm settle --timeout=2 2>/dev/null || true
        sleep 1
        tries=$((tries + 1))
    done
    [ -b "$resolved" ] || fail "dispositivo non pronto dopo la risoluzione: $resolved (da $path)"
    echo "$resolved"
}

# KEY=VALUE lines, blank-line terminated, whitelisted keys and value
# charset - used for local files only (flag file, unitotem-ota.conf,
# parts.manifest): those are trusted once read off disk, but the format
# hardening is kept anyway since it costs nothing and the flag file's
# content did, at one point, come over the network during arming.
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
# Failure handling. Phase-dependent per the plan: before the partition table
# is (re)written, a failure can still roll back to whatever booted this
# initrd (the legacy push path's one-shot entry self-reverts on GRUB, and
# rollback_config_swap() below undoes the Pi config.txt swap); once the
# table has been rewritten there is nothing to roll back to, so fail() past
# that point must never reboot - it drops into the same fallback console
# every automatic-recovery trigger uses, keeping the machine remotely
# reachable instead of bouncing into a half-written disk.
# ---------------------------------------------------------------------------
DEBUG="${UNITOTEM_OTA_DEBUG:-0}"
# Persisted to disk (/run survives across separate ssh_t invocations within
# the same boot, which is what each of these subcommands is - a fresh
# process every time) rather than kept only as an in-process variable:
# restore-table and restore-part run as *separate* SSH-driven invocations of
# this same script, so a plain shell variable set in one process would not
# be visible to fail() in another.
NO_RETURN_MARKER=/run/unitotem-ota-point-of-no-return
mark_point_of_no_return() { : > "$NO_RETURN_MARKER"; }
past_point_of_no_return() { [ -f "$NO_RETURN_MARKER" ]; }

fail() {
    log "ERRORE: $*"
    if [ "$DEBUG" = 1 ]; then
        log "debug=1: shell di emergenza (nessuna azione automatica)"
        setsid sh -c 'exec sh </dev/console >/dev/console 2>&1' || true
        exit 1
    fi
    if past_point_of_no_return; then
        log "Errore dopo la scrittura della tabella delle partizioni: non riavvio su un disco a meta'."
        cmd_serve_fallback --reason "errore: $*"
        exit 1
    fi
    log "Errore prima di scrivere sul disco: nessuna modifica persistente da annullare."
    exit 1
}
trap 'fail "errore inatteso alla riga $LINENO"' ERR

# ---------------------------------------------------------------------------
# Argument parsing: every subcommand takes --long-opt value pairs.
# ---------------------------------------------------------------------------
declare -A ARG
parse_args() {
    ARG=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --*) ARG["${1#--}"]="${2:-}"; shift 2 ;;
            *) fail "argomento non riconosciuto: $1" ;;
        esac
    done
}
need() { [ -n "${ARG[$1]:-}" ] || fail "--$1 richiesto"; }

# ---------------------------------------------------------------------------
# probe: facts about the current target, printed as KEY=VALUE so the caller
# (remote-deploy.sh, over SSH) can parse them the same way it already parses
# do_probe()'s output.
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

    if [ -n "$disk" ]; then
        local size
        size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
        echo "UNITOTEM_DISK=$disk"
        echo "UNITOTEM_DISKSIZE=$size"

        root_dev=$(blkid -L ROOT 2>/dev/null || true)
        if [ -n "$root_dev" ] && [ "$(lsblk -no PKNAME "$root_dev" 2>/dev/null)" = "${disk##*/}" ]; then
            echo "UNITOTEM_HAVE_ROOT=1"
            mkdir -p /tmp/ota-probe-root
            if mount -t ext4 -o ro "$root_dev" /tmp/ota-probe-root 2>/dev/null; then
                [ -d /tmp/ota-probe-root/etc/kiosk ] && echo "UNITOTEM_HAVE_UNITOTEM=1" || echo "UNITOTEM_HAVE_UNITOTEM=0"
                umount /tmp/ota-probe-root 2>/dev/null || true
            else
                echo "UNITOTEM_HAVE_UNITOTEM=0"
            fi
        else
            echo "UNITOTEM_HAVE_ROOT=0"
            echo "UNITOTEM_HAVE_UNITOTEM=0"
        fi

        data_dev=$(blkid -L DATA 2>/dev/null || true)
        if [ -n "$data_dev" ] && [ "$(lsblk -no PKNAME "$data_dev" 2>/dev/null)" = "${disk##*/}" ] \
           && dumpe2fs -h "$data_dev" >/dev/null 2>&1; then
            echo "UNITOTEM_HAVE_DATA=1"
            echo "UNITOTEM_DATA_UUID=$(blkid -s UUID -o value "$data_dev" 2>/dev/null || echo "")"
        else
            echo "UNITOTEM_HAVE_DATA=0"
        fi

        fw_dev=$(blkid -L FIRMWARE -o device 2>/dev/null || blkid -L EFI -o device 2>/dev/null || true)
        [ -n "$fw_dev" ] && [ "$(lsblk -no PKNAME "$fw_dev" 2>/dev/null)" = "${disk##*/}" ] \
            && echo "UNITOTEM_HAVE_BOOTFS=1" || echo "UNITOTEM_HAVE_BOOTFS=0"
    fi

    command -v partclone.restore >/dev/null 2>&1 \
        && echo "UNITOTEM_PARTCLONE_VERSION=$(partclone.restore -v 2>&1 | head -1 | awk '{print $2}')"
    # No `tr` here on purpose: bash command substitution already stores C
    # strings internally and truncates at the first NUL byte, which is
    # exactly the (single, trailing) NUL these device-tree string properties
    # end with - same effective result as `tr -d '\0'` without depending on
    # an external binary that may be missing from a minimal initramfs
    # (confirmed missing on real hardware, see kiosk/files/ota-hook).
    [ -f /proc/device-tree/model ] && echo "UNITOTEM_MODEL=$(cat /proc/device-tree/model 2>/dev/null)"
    true
}

# ---------------------------------------------------------------------------
# restore-table: sfdisk restore with the two corrections that matter (see
# the plan's "dettagli del restore sfdisk"): last-lba stripped so the usable
# area isn't capped at the source disk's size, and the tail partition's
# size= recomputed against the REAL disk rather than trusted as dumped.
# Table arrives base64'd on the command line (same reasoning as
# remote-deploy.sh's arm_grub/arm_rpi: no whitespace survives an ssh argv
# round-trip otherwise).
# ---------------------------------------------------------------------------
cmd_restore_table() {
    parse_args "$@"
    need disk; need table-b64; need tail-part
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local table; table=$(printf '%s' "${ARG[table-b64]}" | base64 -d)
    local tail_part="${ARG[tail-part]}"

    local patched
    patched=$(printf '%s\n' "$table" | grep -v '^last-lba:')

    # sfdisk --dump lines are keyed by the FULL device path of each
    # partition (e.g. "/dev/sda3 : start=..., size=..., ..."), on the disk
    # the dump was taken from - which is generally not $disk here (the dump
    # comes from the parts set, generated against a loop device on the
    # build host). Match on the trailing "<tail_part> :" instead of the
    # whole path, which is stable across both.
    local disk_sectors tail_start
    disk_sectors=$(blockdev --getsz "$disk")
    tail_start=$(printf '%s\n' "$patched" | grep -E "(^|[^0-9])${tail_part}[[:space:]]*:" | head -1 \
        | grep -oE 'start=[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
    [ -n "$tail_start" ] || fail "impossibile trovare la partizione ${tail_part} nella tabella fornita"
    local tail_size=$((disk_sectors - tail_start - 34))
    [ "$tail_size" -gt 0 ] || fail "disco troppo piccolo per la tabella (partizione finale risulterebbe negativa)"

    patched=$(printf '%s\n' "$patched" | awk -v tp="$tail_part" -v sz="$tail_size" '
        {
            line=$0
            if (line ~ ("(^|[^0-9])" tp "[[:space:]]*:") && line ~ /size=/) {
                sub(/size=[[:space:]]*[0-9]+,?/, "size=" sz ",", line)
            }
            print line
        }')

    log "Ripristino la tabella delle partizioni su $disk (settori totali: $disk_sectors)..."
    printf '%s\n' "$patched" | sfdisk --force --no-reread "$disk" || fail "sfdisk restore fallito"
    mark_point_of_no_return

    if [ -n "${ARG[bootcode-b64]:-}" ]; then
        log "Scrivo il boot code MBR (440 byte) su $disk..."
        printf '%s' "${ARG[bootcode-b64]}" | base64 -d | dd of="$disk" bs=440 count=1 conv=notrunc \
            || fail "scrittura bootcode fallita"
    fi

    partprobe "$disk" 2>/dev/null || true
    partx -u "$disk" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    echo "UNITOTEM_TABLE_RESTORED=1"
}

# ---------------------------------------------------------------------------
# restore-part: pull one partclone stream over the DATA connection (plain
# netcat, target connects out - see the plan for why) and restore it
# in-place. -C is only ever passed after WE have verified the used bytes
# actually fit the real target partition (never trusting partclone's blunter
# total-size gate blindly, and never passing -C unconditionally either -
# see the plan's partclone risk section for the reasoning and the verified
# partclone.restore behaviour it's based on).
# ---------------------------------------------------------------------------
cmd_restore_part() {
    parse_args "$@"
    need disk; need part; need cloner; need data-host; need data-port; need used-bytes
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local part_dev; part_dev=$(pdev_target "$disk" "${ARG[part]}")
    [ -b "$part_dev" ] || fail "partizione non trovata: $part_dev"

    local part_sectors used_bytes allow_smaller=0
    used_bytes="${ARG[used-bytes]}"
    part_sectors=$(blockdev --getsz "$part_dev")
    local part_bytes=$((part_sectors * 512))
    local margin=$((used_bytes / 5 + 268435456))   # +20% + 256MiB
    if [ $((used_bytes + margin)) -le "$part_bytes" ]; then
        allow_smaller=1
    fi

    log "Restore partizione ${ARG[part]} ($part_dev, cloner=${ARG[cloner]}) da ${ARG[data-host]}:${ARG[data-port]}..."
    # partclone.restore always tries to open /var/log/partclone.log and
    # fails outright ("open logfile ... error") if the directory doesn't
    # exist - confirmed as a real hardware bug, not theoretical: this
    # initrd's /var is a bare tmpfs with nothing pre-creating /var/log, so
    # every restore-part call failed immediately, before ever touching the
    # data connection.
    mkdir -p /var/log
    exec 4<>"/dev/tcp/${ARG[data-host]}/${ARG[data-port]}"

    local restore_flags=(-o "$part_dev" -s -)
    [ "$allow_smaller" = 1 ] && [ "${ARG[cloner]}" != dd ] && restore_flags=(-C "${restore_flags[@]}")

    # Restore always goes through partclone.restore regardless of which
    # partclone.<fstype> made the image (that binary choice only matters on
    # the generation side, in deploy/make-parts.sh) - it reads the image's
    # own header to know how to lay the blocks back out.
    case "${ARG[comp]:-xz}" in
        xz)   unxz -dc <&4 | partclone.restore "${restore_flags[@]}" -F -B ;;
        zstd) unzstd -dc <&4 | partclone.restore "${restore_flags[@]}" -F -B ;;
        *)    fail "compressione sconosciuta: ${ARG[comp]:-}" ;;
    esac || fail "restore fallito su $part_dev"
    exec 4<&-

    if [ "${ARG[cloner]}" != dd ]; then
        e2fsck -fy "$part_dev" >/dev/null 2>&1 || true
        [ "${ARG[fstype]:-}" = ext4 ] && [ -n "${ARG[grow]:-}" ] && resize2fs "$part_dev" >/dev/null 2>&1 || true
    fi
    echo "UNITOTEM_PART_RESTORED=${ARG[part]}"
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
        preserve) log "DATA preservata (${part_dev})" ;;
        mkfs)
            log "Formatto DATA (${part_dev})..."
            mkfs.ext4 -F -L DATA -O ^has_journal "$part_dev" || fail "mkfs.ext4 su DATA fallito"
            ;;
        *) fail "data-op sconosciuta: ${ARG[op]}" ;;
    esac
    echo "UNITOTEM_DATA_OP_DONE=1"
}

# ---------------------------------------------------------------------------
# write-bootfile: file-level write onto the boot FAT partition (EFI/
# FIRMWARE), used both for the recovery kernel/initrd (stage 1) and the real
# system's own kernel8.img/initramfs8/dtbs (stage 2, populate-bootfs step) -
# one code path, so stage 2 can never clobber what stage 1 wrote by
# accident: content arrives on stdin, target path is always explicit.
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
        log "Formatto la partizione di boot ($bootfs_dev, ${ARG[fstype]})..."
        mkfs.fat -F32 -n "${ARG[label]:-BOOT}" "$bootfs_dev" || fail "mkfs.fat su $bootfs_dev fallito"
    fi
    echo "UNITOTEM_BOOTFS_READY=1"
}

# populate-bootfs: pulls the boot-fs filecopy tarball over the DATA
# connection (same /dev/tcp pull as restore-part) and extracts it, always
# EXCLUDING anything that belongs to the resident fallback - a real restore
# must never be able to clobber recovery8.img/recovery-vmlinuz/-initrd.img,
# unitotem-ota.* state, or the trial-boot markers, whether the target is
# brand new or already prepared.
#
# config.txt/cmdline.txt are excluded too, and this one matters a lot more
# than it looks: on arm64 those files live directly on this same FIRMWARE
# partition (there's no separate ext4 BOOT partition like amd64 has), so the
# source image's own tar of this partition necessarily contains its own
# copy of them - already pointing at the *real* kernel8.img, since that's
# what a normal built image ships. Without this exclude, this step would
# silently overwrite the fallback-pointing config.txt that Stage 1's
# set-default-recovery just wrote, for the entire window between here and
# promote-default - meaning a power cut during the rest of Stage 2 (ROOT
# restore, DATA mkfs) would boot straight into an untested, half-written
# real system instead of the fallback, defeating the whole point of Level 1
# of the fallback guarantee. Confirmed happening for real via the arm64
# loopback test (§11.1) before this exclude was added. config.txt's only
# legitimate writers are set-default-recovery (Stage 1: point at the
# fallback) and promote-default (after a confirmed boot: point at the real
# kernel) - nothing else, including this file-level populate, should ever
# touch it. (No-op on amd64: grub.cfg lives on the ext4 BOOT partition
# there, never on the FAT ESP this tar covers.)
cmd_populate_bootfs() {
    parse_args "$@"
    need disk; need bootfs-part; need data-host; need data-port
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    local mnt=/tmp/ota-bootfs
    ota_mount_bootfs_rw "$bootfs_dev" "$mnt"

    log "Popolo il contenuto file-level della partizione di boot da ${ARG[data-host]}:${ARG[data-port]}..."
    exec 4<>"/dev/tcp/${ARG[data-host]}/${ARG[data-port]}"
    unxz -dc <&4 | tar -C "$mnt" -xf - \
        --exclude='recovery8.img' --exclude='recovery-vmlinuz' --exclude='recovery-initrd.img' \
        --exclude='recovery.sha256' --exclude='unitotem/*' \
        --exclude='unitotem-ota.conf' --exclude='unitotem-ota.state' --exclude='unitotem-ota.request' \
        --exclude='unitotem-ota.bootcount' --exclude='unitotem-ota.last' \
        --exclude='tryboot.txt' --exclude='cmdline-trial.txt' \
        --exclude='config.txt' --exclude='cmdline.txt' \
        --exclude='*.unitotem-bak' \
        || fail "estrazione bootfs fallita"
    exec 4<&-
    sync
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
    mountpoint -q "$mnt" || mount -t vfat -o ro "$bootfs_dev" "$mnt" || fail "mount bootfs ($bootfs_dev) fallito"
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
            cat > "$mnt/config.txt" << 'EOF'
arm_64bit=1
enable_uart=1
kernel=recovery8.img
initramfs recovery-initrd.img followkernel
EOF
            # ttyS1 = mini-UART on the GPIO14/15 header pins. Deliberately not
            # console=serial0: that alias means the PL011 (Bluetooth pins) under
            # the mainline/Debian DTBs we ship, the opposite of what it means
            # under Raspberry Pi's own DTBs - see the longer note in
            # kiosk/stage2-configure.sh. Pairs with enable_uart=1 above.
            echo "unitotem.ota=1 console=tty1 console=ttyS1,115200" > "$mnt/cmdline.txt"
            ;;
        uefi|bios)
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
        *) fail "firmware sconosciuto: ${ARG[firmware]}" ;;
    esac
    sync
    ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
    echo "UNITOTEM_DEFAULT_RECOVERY=1"
}

# ---------------------------------------------------------------------------
# set-trial-boot / promote-default: the real system boots "on trial" (GRUB
# one-shot, tryboot on Pi4/5, or a verified config.txt swap on legacy
# firmware) with the fallback staying default until unitotem-boot-ok.service
# confirms; only then does promote-default flip the permanent default.
#
# Both rpi branches below write a hardcoded, minimal config.txt/tryboot.txt
# (just the kernel=/initramfs= boot-selection lines they themselves own) -
# on purpose, since these functions must never depend on a full untrusted
# copy of the real image's config.txt to keep the fallback guarantee simple.
# kiosk/files/config.txt itself never actually reaches a real device's boot
# partition through this pipeline for that same reason. Any OTHER boot
# config (dtoverlay=, dtparam=, framebuffer/splash tuning - anything that
# isn't boot-selection) has to be spliced back in explicitly: this appends
# kiosk/files/config-extra.txt, installed onto ROOT at build time
# (kiosk/stage2-configure.sh), after the hardcoded lines. Best-effort - a
# missing file (e.g. amd64, which has no config.txt at all) is not an error.
append_config_extra() {
    local extra_file="$1" dest="$2"
    [ -f "$extra_file" ] && cat "$extra_file" >> "$dest"
}

cmd_set_trial_boot() {
    parse_args "$@"
    need firmware
    case "${ARG[firmware]}" in
        uefi|bios)
            # This runs inside the fallback/recovery environment, not on the
            # target - every grub-* command below has to operate on the
            # just-restored system at ${ARG[target]} (/mnt/newroot, already
            # mounted by mount-target), not on the recovery environment's
            # own (nonexistent, in any persistent sense) /boot/grub.
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
                || { umount -lf "${t}/sys/firmware/efi/efivars" "${t}/dev" "${t}/proc" "${t}/sys" 2>/dev/null || true; fail "grub-mkconfig fallito"; }
            chroot "$t" grub-reboot 'UniTotem (trial)' \
                || { umount -lf "${t}/sys/firmware/efi/efivars" "${t}/dev" "${t}/proc" "${t}/sys" 2>/dev/null || true; fail "grub-reboot fallito"; }
            umount -lf "${t}/sys/firmware/efi/efivars" 2>/dev/null || true
            umount -lf "${t}/dev" "${t}/proc" "${t}/sys" 2>/dev/null || true
            ;;
        rpi-tryboot)
            need disk; need bootfs-part
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
            echo "console=tty1 console=ttyS1,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet unitotem.ota.bootcount=1" \
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
            echo "console=tty1 console=ttyS1,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet unitotem.ota.bootcount=1" \
                > "$mnt/cmdline.txt"
            sync; ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
            ;;
        *) fail "modalita' trial-boot sconosciuta: ${ARG[firmware]}" ;;
    esac
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
            cat > "$mnt/config.txt" << 'EOF'
arm_64bit=1
enable_uart=1
kernel=kernel8.img
initramfs initramfs8 followkernel
EOF
            # promote-default runs post-boot, via unitotem-boot-ok on the
            # real system itself (not from within the fallback against a
            # /mnt/newroot that isn't booted yet) - so the extra-config file
            # is this system's own local /etc/unitotem, not /mnt/newroot's.
            append_config_extra /etc/unitotem/config-extra.txt "$mnt/config.txt"
            echo "console=tty1 console=ttyS1,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet" > "$mnt/cmdline.txt"
            rm -f "$mnt/tryboot.txt" "$mnt/cmdline-trial.txt" \
                  "$mnt/config.txt.unitotem-bak" "$mnt/cmdline.txt.unitotem-bak"
            sync; ota_umount_bootfs_rw "$bootfs_dev" "$mnt"
            ;;
        *) fail "firmware sconosciuto: ${ARG[firmware]}" ;;
    esac
    echo "UNITOTEM_PROMOTED=1"
}

# ---------------------------------------------------------------------------
# mount-target / umount-target: the just-restored ROOT (plus BOOT/EFI on
# amd64), mounted at /mnt/newroot for migrate-etc-overlay and set-trial-boot
# --target to operate on before the target is ever booted. DATA is mounted
# separately at /mnt/data by data-op/restore-part's own callers before this
# runs - this only handles the disk being deployed onto.
# ---------------------------------------------------------------------------
cmd_mount_target() {
    parse_args "$@"
    need disk
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    mkdir -p /mnt/newroot
    local root_dev; root_dev=$(pdev_target "$disk" "${ARG[root-part]:?--root-part richiesto}")
    mountpoint -q /mnt/newroot || mount -t ext4 "$root_dev" /mnt/newroot || fail "mount ROOT (nuovo sistema) fallito"
    if [ -n "${ARG[boot-part]:-}" ]; then
        mkdir -p /mnt/newroot/boot
        mount -t ext4 "$(pdev_target "$disk" "${ARG[boot-part]}")" /mnt/newroot/boot || fail "mount BOOT fallito"
    fi
    if [ -n "${ARG[bootfs-part]:-}" ]; then
        # amd64: FAT partition is the ESP, mounted under BOOT at /boot/efi.
        # arm64: FAT partition IS /boot/firmware directly (no separate BOOT).
        local bootfs_mnt=/mnt/newroot/boot/efi
        [ "${ARG[arch]:-amd64}" = arm64 ] && bootfs_mnt=/mnt/newroot/boot/firmware
        # ota_mount_bootfs_rw, not a plain mount: this is the same FIRMWARE/
        # EFI device that /boot-ota keeps mounted ro for the whole fallback
        # session (see the function's own comment) - a plain mount here
        # silently degrades to read-only too, confirmed on hardware
        # (populate-real-kernel's cp failing with "Read-only file system").
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
    # Best-effort: put the persistent /boot-ota reader back to read-only -
    # ota_mount_bootfs_rw (mount-target's bootfs mount) remounted its
    # underlying device rw, and the lazy unmounts above only detach the
    # bind-mounted copy under /mnt/newroot, not that original mount.
    local fw_dev; fw_dev=$(blkid -L FIRMWARE -o device 2>/dev/null || blkid -L EFI -o device 2>/dev/null || true)
    [ -n "$fw_dev" ] && ota_umount_bootfs_rw "$fw_dev" /nonexistent 2>/dev/null || true
    echo "UNITOTEM_UNMOUNTED=1"
}

# populate-real-kernel: arm64 only - the RPi firmware reads kernel8.img/
# initramfs8/dtbs ONLY from the FAT firmware partition, never from ROOT, so
# once ROOT is restored (which carries the real system's own
# /boot/vmlinuz-*, /boot/initrd.img-*, dtbs under /usr/lib/linux-image-*)
# those need copying across. File-level, and deliberately never touches the
# recovery8.img/recovery-initrd.img/recovery.sha256 files already on that
# same partition. amd64 needs no equivalent: its real kernel lives directly
# on the restored BOOT ext4 partition, and GRUB's trial-boot entry already
# points at /mnt/newroot's own /vmlinuz,/initrd.img symlinks.
cmd_populate_real_kernel() {
    parse_args "$@"
    [ -d /mnt/newroot/boot/firmware ] || { echo "UNITOTEM_KERNEL_POPULATED=skip"; return 0; }
    # No `ls` here on purpose: this initrd's `ls` doesn't parse options at
    # all (confirmed on hardware - even a bare `-1` gets treated as a
    # filename, "No such file or directory") - a bash glob sidesteps it
    # entirely, same reasoning as the basename/dirname/tr removals above.
    local kver=""
    for _d in /mnt/newroot/lib/modules/*/; do kver="${_d%/}"; kver="${kver##*/}"; break; done
    [ -n "$kver" ] || fail "nessun kernel trovato in /mnt/newroot/lib/modules"
    cp "/mnt/newroot/boot/vmlinuz-${kver}"    /mnt/newroot/boot/firmware/kernel8.img
    cp "/mnt/newroot/boot/initrd.img-${kver}" /mnt/newroot/boot/firmware/initramfs8
    cp "/mnt/newroot/usr/lib/linux-image-${kver}"/broadcom/bcm27*.dtb /mnt/newroot/boot/firmware/ 2>/dev/null || true
    sync
    echo "UNITOTEM_KERNEL_POPULATED=1"
}

# ---------------------------------------------------------------------------
# etc-overlay migration (plan §7.2): new image's /etc always wins; DATA's
# old overlay content is moved aside wholesale, then only an explicit
# whitelist is reintroduced.
# ---------------------------------------------------------------------------
cmd_migrate_etc_overlay() {
    parse_args "$@"
    need root-mnt; need data-mnt
    local root="${ARG[root-mnt]}" data="${ARG[data-mnt]}"
    # No `date` here on purpose: this is just a history-directory name (no
    # format consumed elsewhere), and `date` is one more external binary
    # missing from the resident fallback (same class of bug as the
    # basename/dirname/tr/ls removals elsewhere in this file - confirmed on
    # hardware: "date: command not found" made this whole function fail).
    # bash's own printf %()T builtin (bash 4.2+, confirmed present as 5.2 on
    # this initrd) needs no external process at all.
    local ts; TZ=UTC0 printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    if [ -d "$data/upper/etc" ]; then
        mkdir -p "$data/history/$ts"
        mv "$data/upper/etc" "$data/history/$ts/etc" 2>/dev/null || true
        mv "$data/work/etc"  "$data/history/$ts/etc.work" 2>/dev/null || true
        mkdir -p "$data/upper/etc" "$data/work/etc"
    fi
    local list="$root/etc/unitotem/ota-preserve.list"
    if [ -f "$list" ] && [ -d "$data/history/$ts/etc" ]; then
        while IFS= read -r pattern; do
            case "$pattern" in ''|'#'*|*=*) continue ;; esac
            for src in "$data/history/$ts/etc"/$pattern; do
                [ -e "$src" ] || continue
                rel="${src#"$data/history/$ts/etc/"}"
                reldir="${rel%/*}"; [ "$reldir" = "$rel" ] && reldir="."
                mkdir -p "$data/upper/etc/$reldir"
                cp -a "$src" "$data/upper/etc/$rel"
            done
        done < "$list"
    fi
    echo "UNITOTEM_ETC_MIGRATED=1"
}

# ---------------------------------------------------------------------------
# serve-fallback: the automatic-recovery / manual-arm entry point. Brings up
# networking, starts dropbear (ephemeral host key, generated fresh every
# time - see the plan for why a build-time-baked key would be a shared
# secret across every shipped image) and blocks, showing a whiptail screen
# with reachability info. Every path into OTA mode (explicit request or a
# failed boot-integrity check) ends up here.
# ---------------------------------------------------------------------------
CONSOLE_TERM_FOR() {
    case "$1" in
        ttyS*|ttyAMA*) echo vt220 ;;
        *) echo linux ;;
    esac
}

configure_networking_ota() {
    local conf=/boot-ota/unitotem-ota.conf iface
    [ -f "$conf" ] && read_kv_lines < "$conf"
    # Belt-and-braces before looking for an interface: don't just trust that
    # udev's own coldplug already bound a driver by this point (confirmed
    # failing in a real boot test - virtio_net.ko was present in the initrd
    # but never got loaded, "ip link show" saw nothing but lo). Harmless
    # no-ops on hardware where these modules don't exist or already loaded.
    modprobe -a virtio_net genet bcmgenet 2>/dev/null || true
    udevadm trigger --subsystem-match=net 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    iface="${OTA_NET_IFACE:-}"
    [ -n "$iface" ] || iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
    [ -n "$iface" ] || { warn "nessuna interfaccia di rete trovata"; return 1; }
    ip link set "$iface" up 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true

    if [ "${OTA_NET_LINK:-wired}" = wifi ] && [ -n "${OTA_WIFI_SSID_B64:-}" ]; then
        local ssid psk
        ssid=$(printf '%s' "$OTA_WIFI_SSID_B64" | base64 -d)
        psk=$(printf '%s' "${OTA_WIFI_PSK_B64:-}" | base64 -d)
        wpa_passphrase "$ssid" "$psk" > /tmp/wpa.conf
        wpa_supplicant -B -i "$iface" -c /tmp/wpa.conf 2>/dev/null || warn "wpa_supplicant fallito"
        sleep 3
    fi

    if [ "${OTA_NET_MODE:-dhcp}" = static ] && [ -n "${OTA_NET_ADDR:-}" ]; then
        ip addr add "$OTA_NET_ADDR" dev "$iface" || true
        [ -n "${OTA_NET_GW:-}" ] && ip route replace default via "$OTA_NET_GW" dev "$iface" || true
    else
        if type configure_networking >/dev/null 2>&1; then
            # initramfs-tools' configure_networking() (sourced into this same
            # shell, not a subprocess) calls its own _set_netdev_from_ip_param()
            # first, which unconditionally does `set -- ${IP}; ...; [ -n "$6" ]`
            # - any $IP value with fewer than 6 colon-separated fields (our
            # "dhcp" shorthand included, or even empty) makes that a reference
            # to a positional parameter beyond $#. Under nounset that's fatal
            # to the shell, not just a nonzero return - confirmed by a real VM
            # boot dying with "/scripts/functions: line 224: $6: unbound
            # variable" here, which `|| warn` never got a chance to catch.
            # It's third-party code not written for -u; disable nounset only
            # for this one call rather than trying to fake a 6-field $IP.
            #
            # Also: configure_networking() ultimately calls klibc's ipconfig,
            # which has a long-documented upstream bug (Debian #552554 and
            # others) where it can block waiting for a DHCP reply and never
            # honor its own -t timeout. Confirmed happening for real on this
            # exact hardware: kernel reported the link up at 10s and stayed
            # alive (still servicing interrupts/scheduling minutes later), but
            # the fallback screen sat frozen on this exact step for 6+ minutes
            # with no progress - a hang inside ipconfig's blocking wait, not a
            # slow-but-finite retry. There is no `timeout` binary in this
            # initramfs to wrap it externally, so enforce a hard wall-clock
            # bound by backgrounding the call and killing it by PID if it
            # doesn't return. This is safe to background even though it's a
            # shell function: the actual effect we care about (the interface
            # getting an address) happens via ipconfig's ioctls on the real
            # kernel interface state, not through a shell variable that would
            # be lost when the subshell exits - confirmed by the next line
            # already reading the result back with `ip addr show`, never from
            # anything configure_networking() itself sets.
            # configure_networking()'s own log_begin_msg/_log_msg print
            # straight to stdout (initramfs-tools code, quiet= isn't set on
            # our cmdline so it's never suppressed) - and this whole function
            # is itself invoked as `myip=$(configure_networking_ota || true)`
            # by the caller, so every one of those internal status lines
            # ("Begin: Waiting up to 180 secs for end0 to become available")
            # was leaking straight into $myip, exactly the same class of bug
            # already fixed for our own log()/warn() calls earlier, just in
            # third-party code this time. Never visible until the DHCP-hang
            # fix above let this call actually return - confirmed for real:
            # once it did, the whiptail box's "Indirizzo:" field showed that
            # exact leaked log text instead of an IP. Redirect its output to
            # /dev/kmsg (same destination our own log() already uses) instead
            # of /dev/null so the diagnostic content isn't lost, just kept out
            # of the one stdout stream this function's caller actually reads.
            local cn_rc=0 cn_pid cn_waited=0 cn_budget=30
            set +u
            # Labelled the same way as dropbear's output above: raw
            # ipconfig/configure_networking chatter on the console is
            # indistinguishable from every other source writing there.
            ( IP=dhcp DEVICE="$iface" configure_networking 2>&1 \
                | while IFS= read -r cn_line; do
                      printf 'unitotem-ota/rete: %s\n' "$cn_line" > /dev/kmsg 2>/dev/null || true
                  done ) &
            cn_pid=$!
            while kill -0 "$cn_pid" 2>/dev/null && [ "$cn_waited" -lt "$cn_budget" ]; do
                sleep 1
                cn_waited=$((cn_waited + 1))
            done
            if kill -0 "$cn_pid" 2>/dev/null; then
                warn "configure_networking bloccato oltre ${cn_budget}s (bug noto di ipconfig, non onora il proprio -t): interrotto a forza"
                kill -9 "$cn_pid" 2>/dev/null
                # wait on a just-kill -9'd job reports its signal-based exit
                # status (137) - under set -e a bare `wait` here would abort
                # this whole script right where it's supposed to recover.
                wait "$cn_pid" 2>/dev/null || true
                # kill -9 on $cn_pid only kills the backgrounded subshell, not
                # its own children - confirmed by hand that the actual hung
                # ipconfig process survives as an orphan otherwise, still
                # holding the interface. No pkill/killall in this initramfs
                # (not worth adding just for this), so walk /proc directly -
                # portable, zero new binary dependencies.
                for _p in /proc/[0-9]*; do
                    _p=${_p#/proc/}
                    [ -r "/proc/$_p/cmdline" ] || continue
                    # No `tr` (may be missing, see the UNITOTEM_MODEL comment
                    # above): argv[0] is what we're matching against and it
                    # comes before the first NUL either way, so plain `cat`
                    # (truncated at that NUL by bash's C-string handling)
                    # captures exactly as much as we need here.
                    case "$(cat "/proc/$_p/cmdline" 2>/dev/null)" in
                        *ipconfig*) kill -9 "$_p" 2>/dev/null || true ;;
                    esac
                done
                cn_rc=124
            else
                # Same errexit trap as above but for the normal path: wait's
                # own exit status mirrors the waited job's, so a plain
                # configure_networking failure (e.g. genuinely no DHCP
                # server) would abort this script right here if unprotected.
                wait "$cn_pid" || cn_rc=$?
            fi
            set -u
            [ "$cn_rc" -eq 0 ] || warn "DHCP (configure_networking) fallito"
        else
            ipconfig -t 10 -d "$iface" 2>/dev/null || warn "DHCP (ipconfig) fallito"
        fi
    fi
    ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

# PWR and ACT blink in ALTERNATION (one on while the other is off), 50/50
# duty, for the whole OTA session - a visual "this device is in
# maintenance/receiving mode" signal that is unmistakable at a glance,
# unlike a single blinking LED which can read as normal activity. Called
# from cmd_serve_fallback, so it covers both the resident fallback and the
# real system's own OTA-capable initramfs (same function, both paths).
# Best-effort and silent throughout: amd64 has no such sysfs path at all,
# and each LED is handled independently so a board exposing only one of the
# two still gets a blink.
#
# The half-period offset is what makes them alternate, and it is NOT
# optional decoration: the kernel's timer trigger always starts a LED in the
# ON phase (changing the trigger forces brightness to 0, and the first timer
# tick then switches it on), so arming both back-to-back makes them blink in
# UNISON - verified on a real Pi 4 by sampling both brightness files, not
# assumed. Offsetting the second arm by half a period is what mirrors them.
#
# The wait is a bash busy-loop on EPOCHREALTIME rather than `sleep 0.5`
# because the resident fallback initramfs ships klibc's sleep, which parses
# only whole seconds and rejects "0.5" outright (there is no busybox in this
# initrd - see PLAN.md's note on that discovery). Burning ~500ms of CPU once
# per OTA session, on a device that is about to sit idle waiting for the
# network, is a fair price for keeping the documented 500ms rate instead of
# slowing the blink to whole seconds just to fit klibc's sleep.
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

    # Only worth offsetting when both LEDs are actually being driven.
    # The [.,] pattern is deliberate: EPOCHREALTIME renders with the
    # LC_NUMERIC decimal separator, which is a comma under this image's own
    # it_IT.UTF-8 locale - stripping only "." would leave a comma in the
    # string and break the arithmetic. $SECONDS caps the spin at ~3s so a
    # missing or malformed EPOCHREALTIME can never hang the fallback here.
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

cmd_serve_fallback() {
    parse_args "$@"
    local reason="${ARG[reason]:-richiesta esplicita}"
    log "Modalita' OTA: $reason"

    ota_led_maintenance

    local myip; myip=$(configure_networking_ota || true)

    mkdir -p /run/dropbear
    dropbearkey -t ed25519 -f /run/dropbear_ed25519_host_key >/dev/null 2>&1 \
        || warn "generazione chiave dropbear fallita"

    # systemd's reboot compat binary (kiosk/files/ota-hook force-copies the
    # real one, not busybox's, so that "reboot -f '0 tryboot'" can reach the
    # kernel) writes its parameter to /run/systemd/reboot-param before
    # calling reboot(2) - confirmed on real hardware: without this directory
    # it fails outright with "Failed to write reboot parameter file: No such
    # file or directory" and never reaches the syscall at all. Nothing else
    # in this initrd ever creates /run/systemd (no real systemd runs here).
    mkdir -p /run/systemd

    # root's password (fixed value, same as kiosk/common.sh's ROOT_PASSWORD
    # default) is baked into /etc/shadow at build time - see
    # kiosk/files/ota-hook - rather than set here at runtime: this initrd's
    # /etc/shadow doesn't exist at all otherwise (confirmed by extracting a
    # real built initrd), and chpasswd/PAM aren't worth pulling in just to
    # set one fixed, known value every boot. dropbear (below) accepts
    # password auth by default; no flag needed for that.

    local term; term=$(CONSOLE_TERM_FOR "${ARG[console-dev]:-tty1}")
    TERM="$term" TERMINFO=/lib/terminfo whiptail --backtitle "UniTotem OTA" \
        --infobox "In modalita' di recupero OTA.\n\nMotivo: ${reason}\nIndirizzo: ${myip:-<nessuno>}\nPorta: 2222\n\nIn attesa di comandi via SSH..." \
        10 60 > /dev/console 2>/dev/null || true

    if [ -f /boot-ota/unitotem-ota.conf ]; then
        read_kv_lines < /boot-ota/unitotem-ota.conf
        if [ -n "${OTA_HOST:-}" ] && [ -n "${OTA_CTRL_PORT:-}" ]; then
            ( dbclient -y -N -R "${OTA_CTRL_PORT}:localhost:2222" "$OTA_HOST" 2>/dev/null & ) || true
        fi
    fi

    # dropbear -E logs to stderr as "[pid] date time message". On a screen
    # where several things write to the same console that pid identifies
    # nothing - you cannot tell which program produced a line, which is
    # exactly the complaint this addresses. Relabel every line with the
    # program name instead, dropping the pid.
    #
    # A bash read loop rather than sed/awk: this runs in the resident
    # fallback, where the binary set is deliberately minimal and neither is
    # guaranteed (the same reasoning that removed basename/dirname/tr/date
    # from this file). Read loops are builtins and always available.
    #
    # No `exec` any more, so the pipeline has to be the thing that blocks.
    # dropbear is started with -F and is never meant to return; if it ever
    # does, park here instead of letting the caller fall through into a
    # normal boot - not falling through is the entire point of the fallback.
    dropbear -F -E -p 2222 -r /run/dropbear_ed25519_host_key 2>&1 \
        | while IFS= read -r line; do
              printf 'dropbear: %s\n' "${line#\[*\] }"
          done
    warn "dropbear e' terminato inaspettatamente: resto in modalita' OTA"
    while :; do sleep 3600; done
}

# ---------------------------------------------------------------------------
# init-premount entry point: decide whether to enter OTA mode at all, and
# why (explicit flag file / cmdline, or a failed pre-mount integrity check).
# Self-clearing flag handling per the plan: mount ro, stat, remount rw, read
# into memory, rm, sync, umount - *then* act, so a crash after the rm always
# resumes a normal boot rather than looping.
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
    # blkid -L can race udev this early in boot and find nothing even though
    # the label genuinely exists - the same class of bug already found and
    # fixed for DATA in kiosk/files/overlayfs-hook.sh (bounded retry, not a
    # single settle beforehand: confirmed live that cmd_init_premount's own
    # `udevadm settle --timeout=10` right before this call is not always
    # enough on its own). Bound kept small (this runs on every single boot,
    # for both FIRMWARE and EFI, only one of which will ever be valid on a
    # given board - a large bound here would add real delay to every normal
    # boot that never has an armed flag file at all).
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

check_bootcount() {
    local mnt=/boot-ota count
    [ -f "$mnt/unitotem-ota.bootcount" ] || return 1
    count=$(cat "$mnt/unitotem-ota.bootcount" 2>/dev/null || echo 0)
    [ "${count:-0}" -ge 3 ]
}

cmd_init_premount() {
    modprobe ext4 2>/dev/null || true
    modprobe vfat 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    if cmdline_get unitotem.ota >/dev/null 2>&1; then
        local mode; mode=$(cmdline_get unitotem.ota)
        [ "$mode" = "1" ] || [ "$mode" = "recover" ] || return 0
        cmd_serve_fallback --reason "cmdline unitotem.ota=$mode"
        return
    fi

    if check_flag_file FIRMWARE vfat || check_flag_file EFI vfat; then
        cmd_serve_fallback --reason "flag file unitotem-ota.request"
        return
    fi

    local root_dev
    root_dev=$(blkid -L ROOT 2>/dev/null || true)
    if [ -z "$root_dev" ]; then
        cmd_serve_fallback --reason "partizione ROOT non trovata"
        return
    fi
    if ! run_e2fsck "$root_dev" 2>/dev/null; then
        cmd_serve_fallback --reason "e2fsck ha rilevato errori non corretti su ROOT"
        return
    fi

    mkdir -p /boot-ota
    # set-trial-boot always seeds the new kernel's cmdline with
    # unitotem.ota.bootcount=1 - the intent (per the parameter's own name)
    # is plainly to start counting fresh for this specific trial run.
    # Confirmed as a real, previously-undiscovered bug: nothing ever
    # actually read this cmdline value, so a trial boot was silently judged
    # against whatever count had *already* accumulated on disk from a
    # completely unrelated earlier failure streak (here: a string of
    # boot-firmware.mount emergency-mode loops, hours before this trial was
    # even armed) - permanently defeating every future trial via
    # check_bootcount's >=3 check regardless of whether the new image
    # actually boots fine.
    local trial_reset=""
    cmdline_get unitotem.ota.bootcount >/dev/null 2>&1 && trial_reset=1
    if [ -z "$trial_reset" ] && check_bootcount; then
        cmd_serve_fallback --reason "tre avvii consecutivi senza conferma (unitotem-boot-ok)"
        return
    fi

    # All checks passed: let mountroot proceed normally. Increment the boot
    # counter now (unitotem-boot-ok.service clears it after multi-user.target
    # is reached) - this is the only layer that catches "boots fine, then
    # userspace dies".
    # Best-effort only: this is telemetry for level-4 detection on the
    # *next* boot, not a condition for this one - a write failure here
    # (worn media, anything) must never abort an otherwise-healthy boot via
    # the ERR trap.
    #
    # /boot-ota is already mounted at this point (read-only) by whichever
    # check_flag_file call above matched a label, and check_bootcount just
    # read from that same mount - reuse it here rather than mounting the
    # *same device* a second time at /tmp/ota-bootcount. Confirmed as a real
    # bug, not just untidy: the kernel handed the second mount request the
    # existing (read-only) superblock instead of a fresh read-write one, so
    # the write always failed with "Read-only file system" even though
    # nothing was actually wrong with the disk or the boot.
    if mountpoint -q /boot-ota; then
        if mount -o remount,rw /boot-ota 2>/dev/null; then
            local n=0
            [ -n "$trial_reset" ] || n=$(cat /boot-ota/unitotem-ota.bootcount 2>/dev/null || echo 0)
            { echo $((n + 1)) > /boot-ota/unitotem-ota.bootcount && sync; } \
                || warn "impossibile aggiornare il contatore di boot (non fatale)"
            mount -o remount,ro /boot-ota 2>/dev/null || true
        else
            warn "impossibile rimontare /boot-ota in scrittura per il contatore di boot (non fatale)"
        fi
    fi
    # /boot-ota must never be left mounted across switch_root: it's a real
    # block-device mount (FIRMWARE/EFI) made inside the initramfs's own tmpfs
    # root, not a bind-mount switch_root knows to move or clean up. Confirmed
    # as a real bug on hardware, not a theoretical one: left mounted here, the
    # real system's own boot-firmware.mount fails with EBUSY on *every*
    # single boot (local-fs.target dependency failure -> permanent emergency
    # mode), because the device stays referenced by this orphaned mount even
    # though it's unreachable (and invisible in /proc/self/mountinfo) from
    # the new root once the old initramfs tmpfs is discarded.
    umount /boot-ota 2>/dev/null || true
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
        warn "init assente su $rootmnt - passo in modalita' OTA"
        umount -lf "$rootmnt" 2>/dev/null || true
        cmd_serve_fallback --reason "/sbin/init assente sul filesystem montato"
        return
    fi
    if [ ! -d "$rootmnt/etc/kiosk" ]; then
        warn "/etc/kiosk assente su $rootmnt - passo in modalita' OTA"
        umount -lf "$rootmnt" 2>/dev/null || true
        cmd_serve_fallback --reason "/etc/kiosk assente sul filesystem montato"
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
        serve-fallback)         cmd_serve_fallback "$@" ;;
        init-premount)          cmd_init_premount "$@" ;;
        local-bottom-verify)    cmd_local_bottom_verify "$@" ;;
        *) echo "Sottocomando sconosciuto: $sub" >&2; exit 1 ;;
    esac
}

main "$@"
