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

# The root slot is mounted read-only and nothing is supposed to write it, so the boot-time check must not write
# either: the old `e2fsck -fy` rewrote the superblock (and "fixed" whatever it saw, unattended) on every boot, which
# is one more write in flight each time the power drops. Look first; only if that finds something let preen make
# the repairs that are safe, then judge again. Anything still wrong goes to the fallback, where a person decides.
check_root_readonly() {
    local dev="$1" rc=0
    e2fsck -fn "$dev" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    warn "controllo in sola lettura di $dev: rc=$rc, provo la riparazione sicura (preen)"
    e2fsck -fp "$dev" >/dev/null 2>&1 || true
    e2fsck -fn "$dev" >/dev/null 2>&1
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
        cmd_serve_fallback --reason "error: $*"
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
    ota_status_set "Writing the partition table"
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

    # The boot partition is mounted read-only at /boot-ota for the whole fallback session; rewriting the table under a
    # mounted partition makes the kernel keep the OLD geometry (the re-read fails with EBUSY) when the new table moves it.
    umount /boot-ota 2>/dev/null || true
    log "Writing the partition table on $disk (total sectors: $disk_sectors)..."
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
    # pv sits after decompression so it measures the payload, which is what
    # --used-bytes describes; measuring the compressed side would give a
    # percentage against a total nobody knows. -n makes it emit a bare integer
    # per update, which ota_ui_feed reads back. Its stderr goes to a file
    # rather than a pipe on purpose: the UI runs in a different process, and a
    # pipe would couple the transfer's fate to the reader's.
    # pv is inserted ONLY when it exists, and the no-pv branch is the exact
    # original pipeline. This is not defensive padding: adding pv
    # unconditionally broke the restore outright where pv was absent - the
    # missing binary took the middle of the pipe out, partclone saw immediate
    # EOF and reported "Device size: 0 Byte" with a bitmap CRC error, so a
    # progress indicator destroyed the data path it was meant to report on.
    # Progress is a nicety; the restore is not, and it must never depend on
    # something optional being present.
    ota_status_set "Writing partition ${ARG[part]} (${ARG[cloner]})"
    local have_pv=0
    command -v pv >/dev/null 2>&1 && have_pv=1
    case "${ARG[comp]:-xz}" in
        xz)
            if [ "$have_pv" = 1 ]; then
                unxz -dc <&4 | pv -n -s "$used_bytes" 2>"$OTA_PCT_FILE" | partclone.restore "${restore_flags[@]}" -F -B
            else
                unxz -dc <&4 | partclone.restore "${restore_flags[@]}" -F -B
            fi
            ;;
        zstd)
            if [ "$have_pv" = 1 ]; then
                unzstd -dc <&4 | pv -n -s "$used_bytes" 2>"$OTA_PCT_FILE" | partclone.restore "${restore_flags[@]}" -F -B
            else
                unzstd -dc <&4 | partclone.restore "${restore_flags[@]}" -F -B
            fi
            ;;
        *)    fail "compressione sconosciuta: ${ARG[comp]:-}" ;;
    esac || fail "restore fallito su $part_dev"
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
    log "Formatto ${ARG[label]} (${part_dev})..."
    mkfs.ext4 -F -L "${ARG[label]}" "$part_dev" >/dev/null || fail "mkfs.ext4 su ${ARG[label]} fallito"
    echo "UNITOTEM_PART_FORMATTED=${ARG[part]}"
}

# grubenv_write FILE key=value... : rewrite a GRUB environment block (1024 bytes: header, one
# key=value per line, '#' padding). Done by hand because the fallback has no grub-editenv, and
# because this is the one place that decides what the next boot is.
grubenv_write() {
    local file="$1"; shift
    # Built with += and $'\n', not $(...): command substitution strips the trailing newline, which would
    # fuse the '#' padding onto the last value ("ota-recovery####...") and silently change what GRUB reads.
    local body="# GRUB Environment Block"$'\n' kv
    for kv in "$@"; do body+="$kv"$'\n'; done
    local pad=$((1024 - ${#body}))
    [ "$pad" -ge 0 ] || fail "grubenv troppo grande"
    { printf '%s' "$body"; printf '%*s' "$pad" '' | tr ' ' '#'; } > "$file.new" || fail "scrittura grubenv fallita"
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
        preserve) log "DATA preservata (${part_dev})" ;;
        mkfs)
            log "Formatto DATA (${part_dev})..."
            mkfs.ext4 -F -L DATA "$part_dev" || fail "mkfs.ext4 su DATA fallito"
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
        # When the fallback was entered through the flag file, init-premount left this very partition mounted
        # read-only on /boot-ota (it keeps it for the whole session), and mkfs.fat refuses a mounted device:
        # "contains a mounted filesystem" - after sfdisk had already rewritten the table. Let go of it first.
        # (Other mounts of the device are released too; ota_mount_bootfs_rw mounts it afresh when needed.)
        umount /boot-ota 2>/dev/null || true
        local m
        while m=$(awk -v d="$bootfs_dev" '$1==d{print $2; exit}' /proc/mounts) && [ -n "$m" ]; do
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || break
        done
        log "Formatto la partizione di boot ($bootfs_dev, ${ARG[fstype]})..."
        # --volid: the FAT serial of the image's own boot partition. GRUB's EFI/BIOS images locate the
        # directory holding grub.cfg by that serial (search.fs_uuid), so a freshly formatted partition
        # with a random one boots to a bare grub prompt.
        local volid_args=()
        [ -n "${ARG[volid]:-}" ] && volid_args=(-i "${ARG[volid]//-/}")
        mkfs.fat -F32 "${volid_args[@]}" -n "${ARG[label]:-BOOT}" "$bootfs_dev" || fail "mkfs.fat su $bootfs_dev fallito"
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
    ota_status_set "Copying boot files (firmware, dtb, overlays)"
    parse_args "$@"
    need disk; need bootfs-part; need data-host; need data-port
    local disk; disk=$(resolve_disk "${ARG[disk]}")
    local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
    local mnt=/tmp/ota-bootfs
    ota_mount_bootfs_rw "$bootfs_dev" "$mnt"

    log "Popolo il contenuto file-level della partizione di boot da ${ARG[data-host]}:${ARG[data-port]}..."
    exec 4<>"/dev/tcp/${ARG[data-host]}/${ARG[data-port]}"
    # tar's default exclude matching is unanchored: 'cmdline.txt' also drops slota/cmdline.txt, which an A/B image
    # needs (os_prefix makes the firmware read it from there). With --layout ab the names are anchored to the top
    # of the archive ("./name"), so only the real top-level files are protected.
    local anch="" pre=""
    if [ "${ARG[layout]:-1}" = ab ]; then anch="--anchored"; pre="./"; fi
    unxz -dc <&4 | tar -C "$mnt" -xf - $anch \
        --exclude="${pre}recovery8.img" --exclude="${pre}recovery-vmlinuz" --exclude="${pre}recovery-initrd.img" \
        --exclude="${pre}recovery.sha256" --exclude="${pre}unitotem/*" \
        --exclude="${pre}unitotem-ota.conf" --exclude="${pre}unitotem-ota.state" --exclude="${pre}unitotem-ota.request" \
        --exclude="${pre}unitotem-ota.bootcount" --exclude="${pre}unitotem-ota.last" \
        --exclude="${pre}tryboot.txt" --exclude="${pre}cmdline-trial.txt" \
        --exclude="${pre}config.txt" --exclude="${pre}cmdline.txt" \
        --exclude="${pre}*.unitotem-bak" \
        || fail "estrazione bootfs fallita"
    exec 4<&-
    sync
    # --secure-boot shim: the image only STAGES the signed chain (EFI/unitotem-sb/, see kiosk/stage3-image.sh); this activates it.
    # Everything the chain needs is copied first and BOOTX64.EFI - the one file the firmware loads - is replaced last, through a
    # temporary name and a rename, so a cut leaves either the old loader or the complete new chain, never a half-written shim.
    if [ "${ARG[secure-boot]:-}" = shim ]; then
        local sb="$mnt/EFI/unitotem-sb" bt="$mnt/EFI/BOOT" f
        for f in shimx64.efi mmx64.efi grubx64.efi grub.cfg; do
            [ -s "$sb/$f" ] || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: $f assente in EFI/unitotem-sb (immagine senza catena firmata?)"; }
        done
        mkdir -p "$bt" "$mnt/EFI/debian"
        cp "$sb/grubx64.efi" "$bt/grubx64.efi" && cp "$sb/mmx64.efi" "$bt/mmx64.efi" \
            && cp "$sb/grub.cfg" "$bt/grub.cfg" && cp "$sb/grub.cfg" "$mnt/EFI/debian/grub.cfg" \
            || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: copia della catena fallita"; }
        sync
        cp "$sb/shimx64.efi" "$bt/BOOTX64.EFI.new" && sync && mv -f "$bt/BOOTX64.EFI.new" "$bt/BOOTX64.EFI" \
            || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: installazione dello shim fallita"; }
        cmp -s "$sb/shimx64.efi" "$bt/BOOTX64.EFI" || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "Secure Boot: lo shim scritto non coincide"; }
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
            # hdmi_group=2 hdmi_mode=4 is the DMT 640x480@60 mode: the deploy/recovery screen is a text UI, and on a large
            # high-resolution monitor seen from a distance (the real case) 80 columns at 640x480 are readable where
            # the same text at 1080p/4K is a few pixels high. DMT 640x480 is accepted by essentially every display.
            # Only the resident fallback has it; the real system's own config.txt is untouched.
            cat > "$mnt/config.txt" << 'EOF'
arm_64bit=1
enable_uart=1
hdmi_group=2
hdmi_mode=4
kernel=recovery8.img
initramfs recovery-initrd.img followkernel
EOF
            # ttyS1 = mini-UART on the GPIO14/15 header pins. Deliberately not
            # console=serial0: that alias means the PL011 (Bluetooth pins) under
            # the mainline/Debian DTBs we ship, the opposite of what it means
            # under Raspberry Pi's own DTBs - see the longer note in
            # kiosk/stage2-configure.sh. Pairs with enable_uart=1 above.
            echo "unitotem.ota=1 console=tty1 console=ttyS0,115200" > "$mnt/cmdline.txt"
            ;;
        uefi|bios)
            if [ "${ARG[layout]:-1}" = ab ]; then
                # A/B: GRUB lives in unitotem-grub/ on this partition (put there by populate-bootfs, which
                # must have run). Its grub.cfg has an 'ota-recovery' entry; making it the saved default is
                # the whole job, and it is a plain file write.
                [ -f "$mnt/unitotem-grub/grub/grub.cfg" ] \
                    || { ota_umount_bootfs_rw "$bootfs_dev" "$mnt"; fail "A/B: unitotem-grub/grub/grub.cfg assente (populate-bootfs non eseguito?)"; }
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
                [ -f "$ge" ] || fail "A/B: grubenv assente in $ge (ESP montata sul target?)"
                # Trial = one-shot next_entry; saved_entry stays on the fallback until unitotem-boot-ok
                # confirms. The same state unitotem-update writes for an in-place update, so the boot-ok
                # path is identical for a first deploy and for every later one.
                ab_write_pending "$t"
                grubenv_write "$ge" "saved_entry=ota-recovery" "next_entry=slot-a"
                sync
                ota_final_status
                ota_final_status
    echo "UNITOTEM_TRIAL_ARMED=1"
                return 0
            fi
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
            if [ "${ARG[layout]:-1}" = ab ]; then
                need target
                local t="${ARG[target]}"
                local disk; disk=$(resolve_disk "${ARG[disk]}")
                local bootfs_dev; bootfs_dev=$(pdev_target "$disk" "${ARG[bootfs-part]}")
                local mnt=/tmp/ota-bootfs
                ota_mount_bootfs_rw "$bootfs_dev" "$mnt"
                # The trial config is a COMPLETE config (the firmware reads tryboot.txt instead of config.txt, never
                # both): slot A's kernel/initramfs/dtbs/cmdline come from slota/ through os_prefix. config.txt keeps
                # pointing at the fallback until unitotem-boot-ok confirms - a power cut, a hang or an unbootable
                # slot all end on the fallback at the next plain boot.
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
        *) fail "modalita' trial-boot sconosciuta: ${ARG[firmware]}" ;;
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
            echo "console=tty1 console=ttyS0,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet" > "$mnt/cmdline.txt"
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
    ota_status_set "Mounting the newly written system"
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
    ota_status_set "Installing the system kernel"
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
    ota_status_set "Migrating configuration from DATA"
    parse_args "$@"
    need root-mnt; need data-mnt
    local root="${ARG[root-mnt]}" data="${ARG[data-mnt]}"
    # A/B: the new system is slot A and keeps its overlay state in upper/<d>.a (see
    # kiosk/files/overlayfs-hook.sh). Slot B is about to be formatted empty, so whatever a previous
    # install left for it, and the update bookkeeping that described it, is stale and goes.
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
    # No `date` here on purpose: this is just a history-directory name (no
    # format consumed elsewhere), and `date` is one more external binary
    # missing from the resident fallback (same class of bug as the
    # basename/dirname/tr/ls removals elsewhere in this file - confirmed on
    # hardware: "date: command not found" made this whole function fail).
    # bash's own printf %()T builtin (bash 4.2+, confirmed present as 5.2 on
    # this initrd) needs no external process at all.
    local ts; TZ=UTC0 printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    # /var is archived and reset alongside /etc, and for this one it is not a
    # nicety but a correctness requirement. /var is overlaid too now (see
    # kiosk/files/overlayfs-hook.sh), and an OTA replaces the whole ROOT
    # partition: left in place, the previous image's upper would shadow the
    # new image's /var - its dpkg database, and /var/unitotem-venv, the
    # manager's Python environment. The new system would be running with the
    # old one's idea of what is installed.
    #
    # No whitelist for /var, unlike /etc: everything under it is either
    # image-derived state that the new image supplies itself, or logs, and the
    # logs are not lost - the whole upper is moved into history/ where it can
    # still be read after the fact.
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
    echo "UNITOTEM_ETC_MIGRATED=1"
}

# ---------------------------------------------------------------------------
# apply-network: carry the target's existing network settings onto the system
# being installed.
#
# migrate-etc-overlay only rescues what is already on DATA, which covers a
# UniTotem being updated but does nothing when ADOPTING a foreign device: its
# configuration lives in the root filesystem we are about to overwrite, and
# no DATA overlay ever held it. Without this the machine comes back on
# NetworkManager's defaults - fine for wired DHCP, but it silently strands
# any device on a static address, and takes a WiFi-only device off the
# network entirely with no way back short of physical access.
#
# The values come from remote-deploy.sh's probe, which already collects them
# for the fallback's own dial-home; this just stops throwing them away
# afterwards. Written into DATA's upper/etc, not the new root's /etc, so the
# profile survives later OTAs through the ota-preserve.list whitelist rather
# than being replaced by the next image.
#
# interface-name is deliberately NOT pinned: predictable names differ between
# distributions (Raspberry Pi OS calls the built-in NIC eth0, this image
# calls it end0), so a pinned name from the OS being replaced would match
# nothing here. Leaving it out lets NetworkManager bind the profile to
# whatever device of that type exists.
# ---------------------------------------------------------------------------
cmd_apply_network() {
    parse_args "$@"
    need data-mnt
    local data="${ARG[data-mnt]}"
    local link="${ARG[link]:-wired}" mode="${ARG[mode]:-dhcp}"
    local addr="${ARG[addr]:-}" gw="${ARG[gw]:-}" dns="${ARG[dns]:-}"
    local ssid_b64="${ARG[ssid-b64]:-}" psk_b64="${ARG[psk-b64]:-}"
    local dir="$data/upper/etc${ARG[slot]:+.${ARG[slot]}}/NetworkManager/system-connections"

    # Never clobber a profile that migrate-etc-overlay just restored: that one
    # is the device's own established configuration and outranks anything
    # inferred from a probe.
    if ls "$dir"/*.nmconnection >/dev/null 2>&1; then
        echo "UNITOTEM_NET_APPLIED=skip-esistente"
        return 0
    fi
    # Wired DHCP needs no profile at all - NetworkManager brings such a link
    # up on its own, and an explicit profile would only be one more thing to
    # disagree with it.
    if [ "$link" = wired ] && [ "$mode" = dhcp ]; then
        echo "UNITOTEM_NET_APPLIED=non-necessario"
        return 0
    fi

    mkdir -p "$dir"
    local f="$dir/unitotem-adottata.nmconnection"
    {
        echo "[connection]"
        echo "id=unitotem-adottata"
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
    # NetworkManager refuses to load a keyfile that others can read, and it
    # holds the WiFi passphrase in cleartext.
    chmod 600 "$f"
    echo "UNITOTEM_NET_APPLIED=1"
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

# ---------------------------------------------------------------------------
# On-screen status. Every subcommand is a SEPARATE process invoked over SSH by
# the host, so none of them can own the display; the only long-lived process on
# the target is serve-fallback. They therefore publish phase and progress to
# files under /run, and serve-fallback runs one loop that redraws a whiptail
# gauge from them.
#
# The gauge is drawn on /dev/tty1, deliberately NOT /dev/console. With the
# cmdline this project writes (console=tty1 console=ttyS0,115200) the kernel
# makes the LAST entry /dev/console, so /dev/console is the serial port - the
# previous code wrote the whiptail box there and it went out the UART instead
# of appearing on the screen, which is why the display stayed blank during an
# OTA. Serial keeps the kernel log; the screen gets the UI.
#
# Two files rather than one: the phase is set once per step, while pv appends a
# percentage per update, so mixing them would mean rewriting the phase
# thousands of times. Both live in /run, which is a tmpfs here, so nothing
# survives to confuse the next boot.
# ---------------------------------------------------------------------------
OTA_STATUS_FILE=/run/unitotem-ota.status
OTA_PCT_FILE=/run/unitotem-ota.pct

# Announce a step. Clears any stale percentage so a finished transfer's 100%
# is not shown against the next, not-yet-started one.
ota_status_set() {
    printf '%s\n' "${1:-}" > "$OTA_STATUS_FILE" 2>/dev/null || true
    : > "$OTA_PCT_FILE" 2>/dev/null || true
}

# Feeds whiptail's gauge protocol: a XXX-delimited block carrying the new
# percentage and the new text.
ota_ui_feed() {
    local phase pct
    while :; do
        phase=""
        [ -r "$OTA_STATUS_FILE" ] && read -r phase < "$OTA_STATUS_FILE" 2>/dev/null
        pct=""
        if [ -s "$OTA_PCT_FILE" ]; then
            # tail is copy_exec'd into this initrd; the substitution strips
            # anything that is not a digit without needing tr, which is NOT
            # present here (confirmed on hardware: "tr: not found").
            pct=$(tail -n1 "$OTA_PCT_FILE" 2>/dev/null)
            pct="${pct//[!0-9]/}"
        fi
        [ -n "$pct" ] || pct=0
        [ "$pct" -le 100 ] 2>/dev/null || pct=100
        # Header (3 lines) + a blank separator + the phase = 5 lines, which is
        # exactly what ota_ui_start sizes the text area for. Keep the two in
        # step: anything beyond that height is silently dropped, not wrapped.
        printf 'XXX\n%s\n%s\n\n%s\nXXX\n' "$pct" "${OTA_UI_HEADER:-}" "${phase:-Waiting for commands over SSH...}"
        sleep 1
    done
}

# Best-effort throughout: a board with no /dev/tty1 (amd64 serial-only, or a
# headless unit) simply gets no UI, and that must never hold up an OTA.
#
# Two details here are not stylistic, both learned by watching it fail on real
# hardware:
#
#   setsid + opening /dev/tty1 as fd 0 is what gives the process a CONTROLLING
#   terminal. Redirecting whiptail's stdout to /dev/tty1 is not enough: newt
#   opens /dev/tty rather than using stdout, so without a controlling terminal
#   it exits immediately with "Failed to open terminal" - which is exactly what
#   happened, silently, while the status files underneath were updating
#   correctly the whole time. A process only acquires a controlling terminal by
#   opening one as a session leader, hence setsid.
#
#   The gauge is fed through a FIFO rather than a pipe because stdin is spoken
#   for: fd 0 has to be the tty to establish it as controlling, so the
#   percentage stream needs its own channel. PLAN.md's original sketch already
#   said the gauge would be fed by a FIFO; that detail turned out to be
#   load-bearing rather than incidental.
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
    # The redirections belong to setsid, NOT to the inner shell. setsid -c
    # applies TIOCSCTTY to its OWN stdin, so the tty has to be there; with the
    # redirection inside the child it failed with "Inappropriate ioctl for
    # device". Letting the child open the tty instead does not work either -
    # shells open with O_NOCTTY, so newt still died on "open /dev/tty: No such
    # device or address". Both were seen on hardware before this form worked.
    #
    # The initial --gauge text is five blank-ish lines, and its LINE COUNT is
    # the point, not its content: whiptail sizes the text area once, when the
    # dialog is created, and clips every later update to that height. An empty
    # initial text gave a zero-line area, so no update ever showed anything; a
    # one-line one showed only the first line of each update - which is what a
    # real OTA looked like on screen, header only, no reason, no address, no
    # phase. Five lines is what ota_ui_feed sends (3 header + blank + phase);
    # change one and change the other.
    local placeholder=$' \n \n \n \n '
    # (NEWT_COLORS was tried to hide whiptail's own "+---+" border and has no effect on this whiptail: ota_frame paints that ring of
    # cells black on the framebuffer instead.)
    setsid -c sh -c "TERM=linux TERMINFO=/lib/terminfo exec whiptail \
            --backtitle 'UniTotem OTA' --gauge '$placeholder' 14 72 0 < '$OTA_UI_FIFO'" \
        < /dev/tty1 > /dev/tty1 2>/dev/null &
    ( ota_ui_feed > "$OTA_UI_FIFO" ) &
    OTA_UI_PID=$!
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

# ota_idle_watchdog SECONDS : leave the fallback by rebooting if no host ever connects to dropbear (port 2222 =
# 0x08AE in /proc/net/tcp*) within SECONDS. The fallback used to wait forever, which turned every transient trigger
# (a few cut-short boots, a flaky read) into a device that stays dark until somebody with a laptop arrives. Once a
# host HAS connected the watchdog stands down for good: whoever is repairing the device is in control. 0 = never.
ota_idle_watchdog() {
    local limit="${1:-0}" waited=0
    [ "$limit" -gt 0 ] 2>/dev/null || return 0
    while [ "$waited" -lt "$limit" ]; do
        sleep 5; waited=$((waited + 5))
        grep -qE ':08AE [0-9A-F]+:[0-9A-F]+ 01 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
    done
    log "nessun host si e' collegato entro ${limit}s: riavvio per ritentare l'avvio normale"
    sync
    reboot -f
}

# ota_splash TITLE LINE : paint the console right away - a logo, what is happening and what to expect - so the screen is
# never an empty black rectangle while the network comes up (about ten seconds) before the progress screen can start. Plain
# text on tty1 (fbcon draws it on the framebuffer), best effort: no tty, no splash, and nothing else depends on it.
# The logo is the UniTotem wordmark of the manager's Plymouth theme, pre-rendered (tools/gen-logo.py) to raw 32-bit pixels and
# written straight to the framebuffer: this initramfs has no image decoder. Returns 1 if there is no usable framebuffer or
# logo, so the caller can fall back to text.
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

# A rounded frame around the progress dialog, drawn on the framebuffer for WHATEVER resolution the screen has. whiptail draws its
# own border at any size, so the replacement must too: nothing here is tied to one geometry.
#
# The geometry comes from the console itself: columns/rows from the tty (stty), cell size = framebuffer size / console size, and
# the dialog is where newt centers it - 72x14 cells (as many as fit on a small screen) in the middle. Around it:
#   1. whiptail's own border (the outer ring of its cells) is painted black - it is drawn once and whiptail only redraws cells that
#      change, so what is painted over it stays;
#   2. the frame is laid out in the margin outside the dialog: radius from the cell height (the nearest pre-rendered one that fits,
#      thickness following it), four pre-rendered anti-aliased corners, and straight edges cut from a solid-colour line blob.
# Only the frame's own pixels and the blank ring are ever written - never the dialog interior, which belongs to whiptail.
# Formats: 32, 24 and 16 bits per pixel. Returns 1 (and says why on stderr) only if there is no usable framebuffer at all.
ota_frame() {
    # OTA_FB_DEV / OTA_FB_SYS / OTA_CONSOLE_SIZE ("rows cols") replace the real devices: the layout is tested on fake framebuffers
    # of many sizes and depths (work/loopback-test/test-frame.sh), because only one of them can be on a screen at a time.
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

# The last thing an update shows before the machine restarts: say so, at 100%, instead of leaving the previous step on
# screen until the screen goes dark.
ota_final_status() {
    ota_status_set "Update written. Restarting into the new system..."
    echo 100 > "$OTA_PCT_FILE" 2>/dev/null || true
}

cmd_serve_fallback() {
    parse_args "$@"
    local reason="${ARG[reason]:-requested explicitly}"
    log "OTA mode: $reason"
    if [ "${ARG[kind]:-update}" = recovery ]; then
        ota_splash "OTA recovery mode" "A fault was detected: $reason. Starting the network, please wait..."
    else
        ota_splash "OTA update mode" "Starting the network, please wait..."
    fi
    # Automatic triggers wait 10 minutes for a host, requested ones 30 (the deploy that asked for it connects within
    # a minute or two), `recover` forever. Overridable per call.
    ( ota_idle_watchdog "${ARG[idle-timeout]:-600}" ) </dev/null >/dev/null 2>&1 &

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

    # Replaces a one-shot --infobox that was written to /dev/console. It had
    # two independent faults: /dev/console is the serial port here (see
    # ota_ui_start), and --infobox returns immediately without persisting, so
    # even on the right device it would have been overwritten by the next
    # message. The gauge below stays up for the whole session and reports what
    # each step is doing.
    # `|| true` is not decoration. The first version of this UI raised an
    # unexpected error inside serve-fallback on real hardware - "ERRORE: errore
    # inatteso alla riga 949", straight into the ERR trap and the rollback
    # handler - so the comment above about the UI never holding up an OTA was
    # an intention with nothing enforcing it. A `||` context suppresses errexit
    # and the ERR trap for the whole function body, which makes it true: the
    # worst a broken UI can now do is not draw.
    # An update is the normal reason to be here, so it is the default: "OTA update mode". "Recovery" is reserved for the
    # device having detected a fault by itself (missing/damaged root, repeated failed boots) - showing that word during an
    # ordinary update would be a false alarm for whoever is standing in front of the screen.
    local kind_title="OTA update mode"
    [ "${ARG[kind]:-update}" = recovery ] && kind_title="OTA recovery mode"
    ota_ui_start "${kind_title}
Reason: ${reason}
Address: ${myip:-none}   Port: 2222" || true
    # the progress screen clears the console when it starts: put the logo back above it once it is up
    ( sleep 2; ota_logo; ota_frame ) </dev/null >/dev/null 2>&1 &

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
        cmd_serve_fallback --reason "kernel command line unitotem.ota=$mode" --kind "$([ "$mode" = recover ] && echo recovery || echo update)" --idle-timeout "$([ "$mode" = recover ] && echo 0 || echo 1800)"
        return
    fi

    if check_flag_file FIRMWARE vfat || check_flag_file EFI vfat; then
        cmd_serve_fallback --reason "update requested by the host" --kind update --idle-timeout 1800
        return
    fi

    # The slot to validate is the one the bootloader chose, named in root= on the command line
    # (A/B layout: ROOT_A or ROOT_B). Checking a fixed "ROOT" here sent every A/B boot straight
    # into OTA mode. Single-ROOT images carry root=LABEL=ROOT, so this is the same lookup as before.
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
        cmd_serve_fallback --reason "partition $root_label not found" --kind recovery
        return
    fi
    if ! check_root_readonly "$root_dev"; then
        cmd_serve_fallback --reason "unrepaired filesystem errors on $root_label" --kind recovery
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
    # A/B images (unitotem.slot= on the command line) do not use the boot counter at all. Their safety net for a
    # bad update is the one-shot trial plus the health gate, which need no FAT write; and the counter cannot tell
    # a broken system from a supply that browns out: three boots cut short by a storm sent the device into the RAM
    # fallback to wait for a host, and every boot also wrote the FAT that holds the bootloader.
    if cmdline_get unitotem.slot >/dev/null 2>&1; then
        umount /boot-ota 2>/dev/null || true
        return 0
    fi
    if [ -z "$trial_reset" ] && check_bootcount; then
        cmd_serve_fallback --reason "three consecutive boots without confirmation (unitotem-boot-ok)" --kind recovery
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
        cmd_serve_fallback --reason "/sbin/init missing on the mounted filesystem" --kind recovery
        return
    fi
    if [ ! -d "$rootmnt/etc/kiosk" ]; then
        warn "/etc/kiosk assente su $rootmnt - passo in modalita' OTA"
        umount -lf "$rootmnt" 2>/dev/null || true
        cmd_serve_fallback --reason "/etc/kiosk missing on the mounted filesystem" --kind recovery
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
        *) echo "Sottocomando sconosciuto: $sub" >&2; exit 1 ;;
    esac
}

main "$@"
