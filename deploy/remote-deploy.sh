#!/bin/bash
# Two-stage OTA deploy orchestrator (host side). Drives deploy/ota-engine.sh on the target over SSH (the system's
# sshd, then dropbear on port 2222 in the fallback initramfs, see ota_ssh() in lib.sh); bulk partition data goes
# over a separate netcat connection (serve_file_once/wait_port_bound in lib.sh), never through SSH.
#
# Usage:
#   ./deploy/remote-deploy.sh probe   root@host
#   ./deploy/remote-deploy.sh changes root@host [--json]
#   ./deploy/remote-deploy.sh deploy  root@host [--parts DIR] [--disk BYID]
#                                     [--port N] [--wipe-data] [--backup-dir DIR] [--no-backup]
#                                     [--console STR] [--yes]
#                                     [--accept-changes DIGEST]
#                                     [--secure-boot shim|noshim|abort]
#   ./deploy/remote-deploy.sh disarm  root@host
#
#   ./deploy/remote-deploy.sh recover HOST[:PORT] [--fallback-user NAME] [--parts DIR] ...
#
# Exit codes of `changes`: 0 no changes, 1 changes found, 2 check failed on the target, 3 target has no unitotem-ota-changes.
#
# OTA fallback credentials (port 2222), read from the environment only (deploy/lib.sh, ota_auth_for):
#   OTA_FALLBACK_KEY=PATH       private key (default: the per-target key of the host, created when arming)
#   OTA_FALLBACK_USER=NAME      login user (default root); --fallback-user NAME sets it
#   OTA_FALLBACK_PASSWORD=...   password, when no key is available
#   OTA_FALLBACK_OPEN=1         empty password: first access to a device with no admin and no key
#
# Machine-readable contract for `changes` and `--accept-changes` (used by the web interface): docs/system/deploy-and-recovery.md.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${DIR}/deploy/lib.sh"

require_cmd ssh scp sshpass sha256sum xz stat awk sed grep socat ss timeout ip base64 curl

# The sudo askpass helper holds the target password, so it must not outlive the run (including failure or
# Ctrl-C). No-op when logged in as root or when sudo is passwordless.
trap 'clear_target_privilege; [ -z "${RECOVERY_TMP:-}" ] || rm -rf -- "${RECOVERY_TMP}"' EXIT

# ---------------------------------------------------------------------------
SUBCMD="${1:-}"; shift || true

case "$SUBCMD" in
    probe|deploy|disarm|changes)
        TARGET_USERHOST="${1:-}"; shift || true
        [ -n "$TARGET_USERHOST" ] || { echo "Usage: $0 $SUBCMD user@host [options]" >&2; exit 1; }
        ;;
    recover)
        RECOVER_HOSTPORT="${1:-}"; shift || true
        [ -n "$RECOVER_HOSTPORT" ] || { echo "Usage: $0 recover HOST[:PORT] [options]" >&2; exit 1; }
        ;;
    *) echo "Usage: $0 {probe|deploy|changes|disarm|recover} ... [options]" >&2; exit 1 ;;
esac

OPT_PARTS="" OPT_DISK="" OPT_PORT="9700" OPT_WIPE_DATA=0
# Backup of the UniTotem data of a target that already runs UniTotem, taken before anything is overwritten (default: backups/ in the repository).
OPT_BACKUP_DIR="${UNITOTEM_BACKUP_DIR:-${DIR}/backups}" OPT_NO_BACKUP=0
# Empty by default: build_legacy_cmdline() picks the console per architecture (tty0 for amd64, tty1 +
# serial for arm64) unless --console is given.
OPT_CONSOLE="" OPT_YES=0 OPT_FALLBACK_ONLY=0
# What to do when the target has Secure Boot enabled (amd64/UEFI): shim | noshim | abort. Empty = ask (or
# refuse, when non-interactive). See secure_boot_gate.
OPT_SECURE_BOOT="" SB_MODE=""
# Non-interactive confirmation of a known change set. Carries the digest the operator was shown, so a
# UI-driven deploy cannot proceed over a different set of changes - see cmd_changes.
OPT_ACCEPT_CHANGES="" OPT_JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --parts)      OPT_PARTS="$2"; shift 2 ;;
        --disk)       OPT_DISK="$2"; shift 2 ;;
        --port)       OPT_PORT="$2"; shift 2 ;;
        --wipe-data)  OPT_WIPE_DATA=1; shift ;;
        --backup-dir) OPT_BACKUP_DIR="$2"; shift 2 ;;
        --no-backup)  OPT_NO_BACKUP=1; shift ;;
        --console)    OPT_CONSOLE="$2"; shift 2 ;;
        --yes)        OPT_YES=1; shift ;;
        --fallback-only) OPT_FALLBACK_ONLY=1; shift ;;
        --fallback-user) [[ "${2:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--fallback-user: invalid user name '${2:-}'"
                         OTA_FALLBACK_USER="$2"; shift 2 ;;
        --accept-changes) OPT_ACCEPT_CHANGES="$2"; shift 2 ;;
        --json)       OPT_JSON=1; shift ;;
        --secure-boot) OPT_SECURE_BOOT="$2"; shift 2
                       case "$OPT_SECURE_BOOT" in shim|noshim|abort) ;; *) die "--secure-boot: allowed values are shim, noshim, abort" ;; esac ;;
        *) die "Unknown option: $1" ;;
    esac
done

# A caller that supplies --accept-changes has been shown what will be destroyed and has confirmed it: the
# digest IS the confirmation. It implies --yes so the generic prompts do not block a UI-driven deploy. The
# digest is verified by changes_gate before this flag is consulted.
[ -n "$OPT_ACCEPT_CHANGES" ] && OPT_YES=1

# ---------------------------------------------------------------------------
# Probe: one SSH round-trip, parseable KEY: value / DISK: ... lines: UniTotem/DATA detection, tryboot
# capability, and the network hints deploy/ota-engine.sh's recovery environment needs to reach back out.
# ---------------------------------------------------------------------------
declare -A P
DISKS=()

do_probe() {
    log "Probing ${TARGET_USERHOST}..."
    local out
    # ssh_t, not a raw ssh: the probe reads block devices (blkid, dumpe2fs, lsblk), and an unprivileged
    # reader would silently report HAVE_DATA: 0 on a device that has DATA, which the deploy would reformat.
    out=$(ssh_t bash -s <<'REMOTE_EOF'
set -u
echo "UNAME_M: $(uname -m)"
[ -d /sys/firmware/efi ] && echo "EFI: 1" || echo "EFI: 0"
MODEL=""
[ -r /proc/device-tree/model ] && MODEL=$(tr -d '\0' < /proc/device-tree/model)
echo "MODEL: ${MODEL:-none}"
# Tryboot capability, from the device tree the Raspberry Pi firmware injects into
# /proc/device-tree/chosen/bootloader (no vcgencmd or rpi-eeprom needed). The node is published only by the
# EEPROM bootloader and only when it understands tryboot, so its presence is the signal; the SoC check
# excludes boards with no EEPROM bootloader (Pi 3 / Zero 2 boot bootcode.bin off the SD). It describes
# hardware and firmware, not the running OS.
SOC=""
[ -r /proc/device-tree/compatible ] && SOC=$(tr -d '\0' < /proc/device-tree/compatible)
echo "SOC: ${SOC:-none}"
TRYBOOT=0
if [ -e /proc/device-tree/chosen/bootloader/tryboot ]; then
    case "$SOC" in
        *bcm2711*|*bcm2712*) TRYBOOT=1 ;;
    esac
fi
echo "TRYBOOT: $TRYBOOT"
BLTS=0
[ -r /proc/device-tree/chosen/bootloader/build-timestamp ] \
    && BLTS=$(od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/build-timestamp 2>/dev/null | tr -d ' ')
echo "BOOTLOADER_TS: ${BLTS:-0}"
# Secure Boot: the SecureBoot EFI variable (4 attribute bytes, then 1 = enabled, 0 = disabled). Readable only on a UEFI boot;
# "unknown" when it cannot be read (legacy BIOS, no efivarfs), never guessed.
SBV=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
SB=unknown
if [ -r "$SBV" ]; then
    v=$(od -An -tu1 -j4 -N1 "$SBV" 2>/dev/null | tr -d ' ')
    case "$v" in 0|1) SB=$v ;; esac
fi
echo "SECUREBOOT: $SB"
command -v grub-reboot >/dev/null 2>&1 && echo "GRUB_REBOOT: 1" || echo "GRUB_REBOOT: 0"
command -v update-grub >/dev/null 2>&1 && echo "UPDATE_GRUB: 1" || echo "UPDATE_GRUB: 0"
command -v systemctl >/dev/null 2>&1 && echo "SYSTEMD: 1" || echo "SYSTEMD: 0"

[ -f /etc/unitotem/ota-preserve.list ] && echo "HAVE_UNITOTEM: 1" || echo "HAVE_UNITOTEM: 0"
# UniTotem 1.x/2.x ran on an ordinary single-root Debian/Raspberry Pi OS as the unitotem-manager package (no A/B, no ota-preserve.list).
LEGACY_VER=$(dpkg-query -W -f='${Version}' unitotem-manager 2>/dev/null || true)
case "$LEGACY_VER" in 1.*|2.*) echo "LEGACY_UNITOTEM: $LEGACY_VER" ;; *) echo "LEGACY_UNITOTEM: none" ;; esac

ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null || true)
echo "ROOTSRC: ${ROOTSRC:-none}"
echo "ROOTPUUID: $(blkid -s PARTUUID -o value "$ROOTSRC" 2>/dev/null || echo none)"
pk=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null || true)
echo "ROOTDISK: ${pk:+/dev/$pk}"
echo "ROOTSIZE: $(lsblk -bno SIZE "$ROOTSRC" 2>/dev/null || echo 0)"

DATADEV=$(blkid -L DATA -o device 2>/dev/null || true)
if [ -n "$DATADEV" ] && dumpe2fs -h "$DATADEV" >/dev/null 2>&1; then
    dpk=$(lsblk -no PKNAME "$DATADEV" 2>/dev/null || true)
    echo "HAVE_DATA: 1"
    echo "DATA_UUID: $(blkid -s UUID -o value "$DATADEV" 2>/dev/null || echo none)"
    echo "DATADISK: ${dpk:+/dev/$dpk}"
else
    echo "HAVE_DATA: 0"
fi

BOOTMNT=/
for m in /boot/firmware /boot; do
    mountpoint -q "$m" 2>/dev/null && { BOOTMNT="$m"; break; }
done
echo "BOOTMNT: $BOOTMNT"
BOOTSRC=$(findmnt -no SOURCE "$BOOTMNT" 2>/dev/null || true)
echo "BOOTSRC: ${BOOTSRC:-none}"
pk=$(lsblk -no PKNAME "$BOOTSRC" 2>/dev/null || true)
echo "BOOTDISK: ${pk:+/dev/$pk}"
BOOTPARTNUM=$(lsblk -no PARTN "$BOOTSRC" 2>/dev/null || true)
[ -z "$BOOTPARTNUM" ] && BOOTPARTNUM=$(echo "$BOOTSRC" | grep -o '[0-9]*$')
echo "BOOTPARTNUM: ${BOOTPARTNUM:-none}"

echo "MEMAVAIL: $(awk '/MemAvailable/{printf "%d", $2*1024}' /proc/meminfo)"
echo "ROOTFREE: $(df -B1 --output=avail / 2>/dev/null | tail -1 | tr -d ' ')"
echo "BOOTFREE: $(df -B1 --output=avail "$BOOTMNT" 2>/dev/null | tail -1 | tr -d ' ')"

# Network hints for the OTA payload's reconnection: interface, link type, dhcp or static, plus WiFi
# credentials if connected that way. The secret is not deleted after use (it is already in cleartext in the
# NetworkManager/wpa_supplicant config).
# SSH_CONNECTION is absent under sudo (env_reset) and this script runs with `set -u`, so it is defaulted.
# Losing the value is harmless: run_ota_sequence falls back to `ip -o route get <target>` on the host.
SSHCLIENT_IP="${SSH_CONNECTION:-}"
SSHCLIENT_IP="${SSHCLIENT_IP%% *}"
echo "SSHCLIENT: ${SSHCLIENT_IP:-none}"
NETIF=""
if [ -n "$SSHCLIENT_IP" ]; then
    NETIF=$(ip -o route get "$SSHCLIENT_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
[ -n "$NETIF" ] || NETIF=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
echo "NETIF: ${NETIF:-none}"
if [ -n "$NETIF" ]; then
    [ -e "/sys/class/net/${NETIF}/wireless" ] && echo "NETLINK: wifi" || echo "NETLINK: wired"
    if nmcli -t -f IP4.DHCP4 device show "$NETIF" 2>/dev/null | grep -q .; then
        echo "NETMODE: dhcp"
    elif [ -f "/var/lib/dhcp/dhclient.${NETIF}.leases" ] || [ -f "/run/systemd/netif/leases/$(cat /sys/class/net/${NETIF}/ifindex 2>/dev/null)" ]; then
        echo "NETMODE: dhcp"
    else
        echo "NETMODE: static"
        echo "NETADDR: $(ip -o -4 addr show "$NETIF" 2>/dev/null | awk '{print $4; exit}')"
        echo "NETGW: $(ip -o route show default dev "$NETIF" 2>/dev/null | awk '{print $3; exit}')"
        # Resolvers, semicolon-separated as NetworkManager keyfiles want; without them a static device
        # has an address and gateway but no name lookups.
        echo "NETDNS: $(awk '/^nameserver/{printf "%s%s", sep, $2; sep=";"}' /etc/resolv.conf 2>/dev/null)"
    fi
    if [ -e "/sys/class/net/${NETIF}/wireless" ]; then
        CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$NETIF" '$2==d{print $1; exit}')
        if [ -n "$CONN" ]; then
            SSID=$(nmcli -t -f 802-11-wireless.ssid connection show "$CONN" 2>/dev/null | cut -d: -f2)
            PSK=$(nmcli -s -t -f 802-11-wireless-security.psk connection show "$CONN" 2>/dev/null | cut -d: -f2)
            [ -n "$SSID" ] && echo "WIFI_SSID_B64: $(printf '%s' "$SSID" | base64 -w0)"
            [ -n "$PSK" ]  && echo "WIFI_PSK_B64: $(printf '%s' "$PSK" | base64 -w0)"
        fi
    fi
fi

while read -r name size type tran model; do
    [ "$type" = "disk" ] || continue
    case "$name" in /dev/loop*|/dev/sr*|/dev/ram*|/dev/zram*|/dev/fd*) continue ;; esac
    bid=none
    for l in /dev/disk/by-id/* /dev/disk/by-path/*; do
        [ -e "$l" ] || continue
        case "$l" in *-part*) continue ;; esac
        [ "$(readlink -f "$l" 2>/dev/null)" = "$name" ] && { bid="$l"; break; }
    done
    echo "DISK: ${name}|${size}|${tran:-?}|${model:-?}|${bid}"
done < <(lsblk -dpbn -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null)
REMOTE_EOF
) || die "cannot reach ${TARGET_USERHOST} via SSH"

    while IFS= read -r line; do
        case "$line" in
            "DISK: "*) DISKS+=("${line#DISK: }") ;;
            *": "*)    P["${line%%:*}"]="${line#*: }" ;;
        esac
    done <<< "$out"

    [ ${#DISKS[@]} -gt 0 ] || die "no disk detected on the target"

    if echo "${P[MODEL]:-}" | grep -qi "raspberry pi"; then
        echo "${P[MODEL]}" | grep -qiE "raspberry pi (3|4|5|.*zero 2)" \
            || die "detected model (${P[MODEL]}) is not 64-bit: the deployed image is always arm64 and cannot be installed here"
        ARCH=arm64; FIRMWARE=rpi
        # Tryboot needs (1) an EEPROM bootloader that understands it (detected above) and (2) the raspberrypi/linux
        # kernel, since the "0 tryboot" reboot(2) argument reaches the firmware only there; the resident fallback initrd
        # (built from linux-image-rpi-v8) issues the reboot, so that always holds. Boards failing (1) (Pi 3 / Zero 2)
        # use rpi-legacy: a direct config.txt swap protected by the initramfs checks and the boot counter.
        TRYBOOT_CAPABLE="${P[TRYBOOT]:-0}"
    elif [ "${P[EFI]}" = 1 ]; then
        ARCH=amd64; FIRMWARE=uefi; TRYBOOT_CAPABLE=0
    else
        ARCH=amd64; FIRMWARE=bios; TRYBOOT_CAPABLE=0
    fi
}

print_probe() {
    echo "Target image architecture    : ${ARCH}  (${P[UNAME_M]}, model: ${P[MODEL]})"
    if [ "${FIRMWARE}" = rpi ]; then
        local tb_why="EEPROM bootloader without tryboot support (or absent: Pi 3/Zero 2)"
        [ "${TRYBOOT_CAPABLE}" = 1 ] && tb_why="detected via device tree, SoC ${P[SOC]:-n/a}"
        echo "Firmware                     : ${FIRMWARE}  (tryboot: ${TRYBOOT_CAPABLE} - ${tb_why})"
        echo "Trial boot mode              : $([ "${TRYBOOT_CAPABLE}" = 1 ] && echo 'rpi-tryboot (firmware-level protection)' || echo 'rpi-legacy (config.txt swap + boot counter)')"
    else
        echo "Firmware                     : ${FIRMWARE}  (tryboot: ${TRYBOOT_CAPABLE})"
    fi
    if [ "${FIRMWARE}" = uefi ]; then
        case "${P[SECUREBOOT]:-unknown}" in
            1) echo "Secure Boot                  : enabled (deploy will ask how to proceed: see --secure-boot)" ;;
            0) echo "Secure Boot                  : disabled" ;;
            *) echo "Secure Boot                  : cannot be detected" ;;
        esac
    fi
    echo "Already UniTotem             : ${P[HAVE_UNITOTEM]}"
    echo "Earlier UniTotem (single root): ${P[LEGACY_UNITOTEM]:-none}"
    echo "DATA present                 : ${P[HAVE_DATA]}  (UUID: ${P[DATA_UUID]:-n/a})"
    echo "Available RAM                : $(bytes_human "${P[MEMAVAIL]}")"
    echo "Free space on /              : $(bytes_human "${P[ROOTFREE]}")"
    echo "Network towards the host     : interface ${P[NETIF]:-?} (${P[NETLINK]:-?}, ${P[NETMODE]:-?})"
    echo "Current boot disk            : ${P[ROOTDISK]:-?}"
    echo "Detected disks:"
    local i=1 d
    for d in "${DISKS[@]}"; do
        IFS='|' read -r name size tran model byid <<< "$d"
        local tag=""
        [ "$name" = "${P[ROOTDISK]:-}" ] && tag="  <- current boot disk"
        printf "  %2d) %-16s %8s  %-6s %-20s%s\n" "$i" "$name" "$(bytes_human "$size")" "$tran" "$model" "$tag"
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
select_disk() {
    local i=1 d chosen=""
    if [ -n "$OPT_DISK" ]; then
        for d in "${DISKS[@]}"; do
            IFS='|' read -r name size tran model byid <<< "$d"
            if [ "$OPT_DISK" = "$name" ] || [ "$OPT_DISK" = "$byid" ]; then
                chosen="$d"; break
            fi
        done
        [ -n "$chosen" ] || die "--disk $OPT_DISK not found among the detected disks (use 'probe' to list them)"
    fi

    if [ -z "$chosen" ] && [ ${#DISKS[@]} -eq 1 ] && [ "$OPT_YES" = 1 ]; then
        chosen="${DISKS[0]}"
    fi

    if [ -z "$chosen" ] || { [ ${#DISKS[@]} -gt 1 ] && [ "$OPT_YES" != 1 ]; }; then
        print_probe
        if [ -n "$chosen" ]; then
            echo ""
            IFS='|' read -r name size tran model byid <<< "$chosen"
            read -rp "Confirm writing to ${name} ($(bytes_human "$size"))? [type YES]: " ans
            [ "$ans" = "YES" ] || die "cancelled by the user"
        else
            echo ""
            local choice
            read -rp "Which disk should the image be written to? [1-${#DISKS[@]}]: " choice
            [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#DISKS[@]} ] \
                || die "invalid choice"
            chosen="${DISKS[$((choice - 1))]}"
        fi
    fi

    IFS='|' read -r TARGET_DISK_NAME TARGET_DISK_SIZE _ _ TARGET_DISK_BYID <<< "$chosen"
    [ "$TARGET_DISK_BYID" != none ] || die "no stable path (by-id/by-path) for ${TARGET_DISK_NAME}: cannot proceed safely"
    TARGET_DISK="$TARGET_DISK_NAME"

    if [ "$OPT_YES" != 1 ]; then
        echo ""
        echo "!!! Disk ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE")) will be completely rewritten. !!!"
        read -rp "Type 'YES' to proceed: " ans
        [ "$ans" = "YES" ] || die "cancelled by the user"
    fi
}

# ---------------------------------------------------------------------------
# Member of the tar listing $1 whose name without a leading ./ is $2; prints the name as stored (or nothing).
recovery_member() {
    printf '%s\n' "$1" | awk -v w="$2" '{m=$0; sub(/^\.\//,"",m); if (m==w) {print $0; exit}}'
}

# Extracts the member $2 of the xz tarball $1 to the file $3.
recovery_extract() {
    tar -xJOf "$1" "$2" > "$3" 2>/dev/null
}

# Source of the fallback kernel, initrd and level marker written to the boot partition (write-bootfile).
# The parts set's boot tarball is the source (same build as the image); the host copies in deploy/<arch>/ are
# used only when the tarball lacks a member. Usage: recovery_from_parts PARTS_DIR ARCH OUT_DIR.
# Writes OUT_DIR/<FAT name> for the kernel, the initrd and recovery.sha256 and prints one word on stdout:
# parts | host (fallback, warned on stderr) | refused (tarball checksum mismatch) | missing (no host copy).
# Returns 1 for refused and missing.
recovery_from_parts() {
    local parts="$1" arch="$2" out="$3"
    local kname=recovery-vmlinuz prefix=unitotem/
    [ "$arch" = arm64 ] && { kname=recovery8.img; prefix=""; }
    local iname=recovery-initrd.img
    local tb_rel tb list m_k m_i m_s name exp act hk hi
    tb_rel=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' \
        "${parts}/parts.manifest" 2>/dev/null) || tb_rel=""
    tb="${parts}/${tb_rel}"
    list=""
    if [ -n "$tb_rel" ] && [ -f "$tb" ]; then list=$(tar -tJf "$tb" 2>/dev/null) || list=""; fi
    m_k=$(recovery_member "$list" "${prefix}${kname}")
    m_i=$(recovery_member "$list" "${prefix}${iname}")
    m_s=$(recovery_member "$list" "${prefix}recovery.sha256")

    if [ -z "$m_k" ] || [ -z "$m_i" ] || [ -z "$m_s" ]; then
        warn "the parts set's boot tarball has no recovery kernel/initrd/recovery.sha256: using the host copies in deploy/${arch}"
        cp -- "${DIR}/deploy/${arch}/recovery-vmlinuz-${arch}" "${out}/${kname}" 2>/dev/null \
            && cp -- "${DIR}/deploy/${arch}/recovery-initrd-${arch}.img" "${out}/${iname}" 2>/dev/null \
            || { echo missing; return 1; }
        # The host copies carry no level: the sums describe the files written, level 0 (next confirmed boot refreshes).
        hk=$(sha256sum "${out}/${kname}" | awk '{print $1}')
        hi=$(sha256sum "${out}/${iname}" | awk '{print $1}')
        printf '%s  %s\n' "$hk" "$kname" > "${out}/recovery.sha256"
        printf '%s  %s\n' "$hi" "$iname" >> "${out}/recovery.sha256"
        echo host
        return 0
    fi

    if ! recovery_extract "$tb" "$m_s" "${out}/recovery.sha256" \
        || ! recovery_extract "$tb" "$m_k" "${out}/${kname}" \
        || ! recovery_extract "$tb" "$m_i" "${out}/${iname}"; then
        warn "reading the recovery files from the parts set's boot tarball failed"
        echo refused
        return 1
    fi
    for name in "$kname" "$iname"; do
        exp=$(awk -v n="$name" '{m=$2; sub(/^\.\//,"",m); if (m==n) {print $1; exit}}' "${out}/recovery.sha256")
        act=$(sha256sum "${out}/${name}" | awk '{print $1}')
        if [ -z "$exp" ] || [ "$exp" != "$act" ]; then
            warn "${name} does not match the checksum in the parts set's recovery.sha256: refusing it"
            echo refused
            return 1
        fi
    done
    echo parts
}

# ---------------------------------------------------------------------------
# Arming of a non-UniTotem target: push the resident recovery kernel+initrd and boot it via a one-shot
# entry (GRUB) or a config.txt swap (Pi).
# ---------------------------------------------------------------------------
push_recovery_kernel() {
    # No parts set is in hand before the target is armed, so the host copies are the only source here.
    local vmlinuz="${DIR}/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"
    local initrd="${DIR}/deploy/${ARCH}/recovery-initrd-${ARCH}.img"
    [ -f "$vmlinuz" ] && [ -f "$initrd" ] \
        || die "recovery kernel/initrd missing for ${ARCH}: run ./build-unitotem.sh first (it also produces stage 1b)"

    log "Copying the fallback kernel/initrd to ${P[BOOTMNT]}..."
    ssh_t "mount -o remount,rw '${P[BOOTMNT]}' 2>/dev/null; true"
    scp_root "$vmlinuz" "${P[BOOTMNT]}/unitotem-recovery-vmlinuz" \
        || die "copying the fallback kernel failed"
    scp_root "$initrd"  "${P[BOOTMNT]}/unitotem-recovery-initrd.img" \
        || die "copying the fallback initrd failed"
}

# $1 = public key line of the fallback ("ssh-ed25519 BASE64"), armed as unitotem.ota.authkey=<base64 of the line>.
# Prints the kernel command line on one line. Dies when it reaches the 400-character limit (the Pi firmware
# accepts 512 bytes; the margin is kept).
build_legacy_cmdline() {
    local console="$OPT_CONSOLE" authkey cmdline
    if [ -z "$console" ]; then
        [ "$ARCH" = arm64 ] && console="tty1 console=ttyS0,115200" || console="tty0"
    fi
    [ -n "${1:-}" ] || die "build_legacy_cmdline: no fallback public key given"
    authkey=$(printf '%s' "$1" | base64 -w0)
    # fbcon=font:TER16x32: the firmware framebuffer is often the monitor's native size, where the default 8x16 font is
    # tiny; the 16x32 font doubles every glyph (ignored by a kernel that lacks it).
    cmdline="unitotem.ota=1 quiet loglevel=3 fbcon=font:TER16x32 console=${console} unitotem.ota.authkey=${authkey}"
    [ "${#cmdline}" -lt 400 ] || die "kernel command line too long for the fallback boot (${#cmdline} characters, limit 400)"
    echo "$cmdline"
}

arm_grub() {
    local cmdline_b64; cmdline_b64=$(printf '%s' "$1" | base64 -w0)
    log "Adding the one-shot GRUB entry 'UniTotem OTA'..."
    ssh_t bash -s -- "$cmdline_b64" <<'REMOTE_EOF'
set -eu
CMDLINE="$(printf '%s' "$1" | base64 -d)"
mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw /boot 2>/dev/null || true
# 99 so the entry sorts last: with GRUB_DEFAULT=0, an entry at index 0 would be booted again once
# grub-reboot's one-shot is consumed (an endless boot loop instead of the original OS).
cat > /etc/grub.d/99_unitotem_flash << EOF
#!/bin/sh
exec tail -n +3 "\$0"
menuentry 'UniTotem OTA' {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    # low resolution for the OTA screens (as unitotem/files/grub-ab-entries): a small firmware framebuffer mode,
    # kept by gfxpayload=keep, with nomodeset stopping the DRM driver from switching to the native size
    insmod all_video
    insmod gfxterm
    set gfxmode=640x480x32,640x480,800x600x32,800x600,1024x768x32,1024x768,auto
    terminal_output gfxterm
    set gfxpayload=keep
    linux /unitotem-recovery-vmlinuz nomodeset ${CMDLINE}
    initrd /unitotem-recovery-initrd.img
}
EOF
chmod +x /etc/grub.d/99_unitotem_flash
if command -v update-grub >/dev/null 2>&1; then
    update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "Neither update-grub nor grub-mkconfig found on the target" >&2
    exit 1
fi
grub-reboot 'UniTotem OTA'
REMOTE_EOF
}

arm_rpi() {
    local cmdline_b64; cmdline_b64=$(printf '%s' "$1" | base64 -w0)
    log "Preparing config.txt/cmdline.txt for the one-shot fallback boot..."
    ssh_t bash -s -- "$cmdline_b64" "${P[BOOTMNT]}" <<'REMOTE_EOF'
set -eu
CMDLINE="$(printf '%s' "$1" | base64 -d)"
BOOTMNT="$2"
cd "$BOOTMNT"
[ -f config.txt.unitotem-bak ]  || cp -a config.txt  config.txt.unitotem-bak
[ -f cmdline.txt.unitotem-bak ] || cp -a cmdline.txt cmdline.txt.unitotem-bak
# enable_uart=1 is required: build_legacy_cmdline() pairs this config with console=ttyS0,115200, and the
# mini-UART baud derives from the VPU core clock, which only enable_uart=1 pins. Serial is the only
# diagnostic if the fallback boot misbehaves.
cat > config.txt << EOF
arm_64bit=1
enable_uart=1
kernel=unitotem-recovery-vmlinuz
initramfs unitotem-recovery-initrd.img followkernel
EOF
echo "${CMDLINE}" > cmdline.txt
sync
REMOTE_EOF
}

do_reboot() {
    log "Rebooting the target..."
    # systemd-run first: a reboot started as a background child of the ssh/sudo session can be lost when the
    # session is torn down first.
    ssh_t "sync; systemd-run --on-active=3s --no-block systemctl reboot >/dev/null 2>&1 || nohup reboot >/dev/null 2>&1 &" || true
}

# Wait for the OTA dropbear session to come up (after a push) or for the armed target to answer.
# The fallback gets its address by DHCP on whichever wired port has the cable, maybe not the running system's. After
# a minute without an answer the local subnet is scanned for dropbear on port 2222: one hit is taken as the fallback
# (OTA_FOUND_HOST), several are listed.
discover_fallback() {
    local src prefix h open=() ban
    src=$(ip -o route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$src" ] || return 1
    prefix="${src%.*}"
    log "No answer at the expected address: looking for the fallback (dropbear, port 2222) on ${prefix}.0/24..."
    for h in $(seq 1 254); do
        ( ban=$(timeout 2 bash -c "exec 3<>/dev/tcp/${prefix}.${h}/2222 && head -c 20 <&3" 2>/dev/null || true)
          case "$ban" in SSH-2.0-dropbear*) echo "${prefix}.${h}" >> "$OTA_SCAN_FILE" ;; esac ) &
        [ $((h % 64)) -eq 0 ] && wait
    done
    wait
    mapfile -t open < <(sort -u "$OTA_SCAN_FILE" 2>/dev/null)
    case ${#open[@]} in
        0) return 1 ;;
        1) OTA_FOUND_HOST="${open[0]}"
           if [ "$OTA_FOUND_HOST" = "$1" ]; then log "Fallback found at ${OTA_FOUND_HOST}."
           else log "Fallback found at ${OTA_FOUND_HOST} (not the expected address: the cabled network port is not the one the previous system used)."; fi
           return 0 ;;
        *) warn "more than one dropbear on port 2222: ${open[*]}"; return 1 ;;
    esac
}

wait_ota_reachable() {
    local host="$1" waited=0 scanned=0
    OTA_FOUND_HOST=""; OTA_SCAN_FILE=$(mktemp)
    log "Waiting for ${host} to answer on the OTA session (port 2222, up to 10 minutes)..."
    sleep 15
    while ! ota_ssh "$host" true 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        if [ "$waited" -ge 60 ] && [ "$scanned" -eq 0 ]; then
            scanned=1
            if discover_fallback "$host"; then host="$OTA_FOUND_HOST"; continue; fi
        fi
        [ "$waited" -lt 600 ] || { rm -f "$OTA_SCAN_FILE"; die "the target did not enter OTA mode within 10 minutes"; }
    done
    rm -f "$OTA_SCAN_FILE"
    [ -z "$OTA_FOUND_HOST" ] || log "OTA session reached at ${OTA_FOUND_HOST}."
}

# The two-stage sequence, driven by ota-engine.sh subcommands over the OTA SSH session.
# populate-bootfs for the parts set's boot tarball: one place, as it runs in stage 1 for A/B parts and stage 2 otherwise.
populate_bootfs_step() {
    local host="$1" disk="$2" bootfs_part="$3"
    local hostip="${P[SSHCLIENT]:-}"
    [ -n "$hostip" ] && [ "$hostip" != none ] || hostip=$(ip -o route get "${host}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$hostip" ] || die "cannot determine the host IP towards the target"
    local bootfs_tar; bootfs_tar=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")
    [ -n "$bootfs_tar" ] || return 0
    local pid; pid=$(serve_file_once "${OPT_PARTS}/${bootfs_tar}" "$OPT_PORT")
    wait_port_bound "$OPT_PORT" 10 || die "data listener not ready (bootfs)"
    local lay="--layout ab"
    [ "$SB_MODE" = shim ] && lay="$lay --secure-boot shim"
    # shellcheck disable=SC2086
    ota_ssh "$host" "unitotem-ota-engine populate-bootfs --disk '${disk}' --bootfs-part '${bootfs_part}' --data-host '${hostip}' --data-port '${OPT_PORT}' ${lay}"
    wait "$pid" 2>/dev/null || true
}

run_ota_sequence() {
    local host="$1" disk_byid="$2"

    local recreate_table=0
    if [ "${RECOVER_MODE:-0}" = 1 ]; then
        # recover: the caller already judged the disk (see cmd_recover); the table is rewritten only when unusable
        [ "${RECOVER_KEEP_TABLE:-0}" = 1 ] || recreate_table=1
    else
        [ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && [ "$OPT_WIPE_DATA" != 1 ] || recreate_table=1
    fi

    log "Resolving the disk on the target (probe engine)..."
    local probe_out
    probe_out=$(ota_ssh "$host" "unitotem-ota-engine probe --disk '${disk_byid}'")
    declare -A E
    while IFS= read -r line; do
        [ -n "$line" ] && E["${line%%=*}"]="${line#*=}"
    done <<< "$probe_out"
    local disk="${E[UNITOTEM_DISK]:-}"
    [ -n "$disk" ] || die "the target does not resolve the requested disk"

    local bootfs_part="${P_BOOTFS_PART:-1}" data_part="${P_DATA_PART}"
    local firmware_grub="${FIRMWARE}"

    # The fallback files are judged before anything on the target is changed.
    RECOVERY_TMP=$(mktemp -d)
    local rsrc
    rsrc=$(recovery_from_parts "$OPT_PARTS" "$ARCH" "$RECOVERY_TMP") \
        || die "the recovery files of the parts set cannot be used (${rsrc:-error}): the target was not changed"
    [ "$rsrc" = parts ] || log "Fallback files taken from the host copies (deploy/${ARCH}): the parts set has none."

    log "=== Stage 1: installing the fallback ==="
    if [ "$recreate_table" = 1 ]; then
        log "Restoring the partition table..."
        local table_b64; table_b64=$(base64 -w0 < "${OPT_PARTS}/layout.sfdisk")
        local bootcode_arg=""
        if [ -f "${OPT_PARTS}/bootcode.bin" ]; then
            bootcode_arg="--bootcode-b64 $(base64 -w0 < "${OPT_PARTS}/bootcode.bin")"
        fi
        # shellcheck disable=SC2086
        ota_ssh "$host" "unitotem-ota-engine restore-table --disk '${disk}' --table-b64 '${table_b64}' --tail-part '${data_part}' ${bootcode_arg}"
        local bootfs_label; bootfs_label=$([ "$ARCH" = arm64 ] && echo FIRMWARE || echo EFI)
        local volid_arg=""
        [ -n "${P_BOOTFS_VOLID:-}" ] && volid_arg="--volid '${P_BOOTFS_VOLID}'"
        # shellcheck disable=SC2086
        ota_ssh "$host" "unitotem-ota-engine prepare-bootfs --disk '${disk}' --bootfs-part '${bootfs_part}' --fstype vfat --fresh 1 --label ${bootfs_label} ${volid_arg}"
    fi

    if [ "$recreate_table" != 1 ] && [ "${RECOVER_BOOTFS_FRESH:-0}" = 1 ]; then
        # recover with the table and DATA intact but a damaged boot partition: format only that one
        local bootfs_label_r; bootfs_label_r=$([ "$ARCH" = arm64 ] && echo FIRMWARE || echo EFI)
        local volid_arg_r=""; [ -n "${P_BOOTFS_VOLID:-}" ] && volid_arg_r="--volid '${P_BOOTFS_VOLID}'"
        log "Reformatting only the (damaged) boot partition..."
        # shellcheck disable=SC2086
        ota_ssh "$host" "unitotem-ota-engine prepare-bootfs --disk '${disk}' --bootfs-part '${bootfs_part}' --fstype vfat --fresh 1 --label ${bootfs_label_r} ${volid_arg_r}"
    fi

    log "Copying the fallback kernel/initrd to the boot partition..."
    local recovery_name_vmlinuz recovery_name_initrd
    if [ "$ARCH" = arm64 ]; then
        recovery_name_vmlinuz=recovery8.img; recovery_name_initrd=recovery-initrd.img
    else
        recovery_name_vmlinuz=recovery-vmlinuz; recovery_name_initrd=recovery-initrd.img
    fi
    local subdir=""; [ "$ARCH" = amd64 ] && subdir="--subdir unitotem"
    # shellcheck disable=SC2086
    ota_ssh_send "$host" "unitotem-ota-engine write-bootfile --disk '${disk}' --bootfs-part '${bootfs_part}' --name ${recovery_name_vmlinuz} ${subdir}" \
        < "${RECOVERY_TMP}/${recovery_name_vmlinuz}"
    # shellcheck disable=SC2086
    ota_ssh_send "$host" "unitotem-ota-engine write-bootfile --disk '${disk}' --bootfs-part '${bootfs_part}' --name ${recovery_name_initrd} ${subdir}" \
        < "${RECOVERY_TMP}/${recovery_name_initrd}"
    # Last: the level marker on the target (the complete marker, written after the pair).
    # shellcheck disable=SC2086
    ota_ssh_send "$host" "unitotem-ota-engine write-bootfile --disk '${disk}' --bootfs-part '${bootfs_part}' --name recovery.sha256 ${subdir}" \
        < "${RECOVERY_TMP}/recovery.sha256"
    rm -rf -- "$RECOVERY_TMP"
    RECOVERY_TMP=""

    # A/B: the boot partition's file-level content carries GRUB itself and the grub.cfg whose 'ota-recovery'
    # entry set-default-recovery selects, so it must be there BEFORE the default is switched, and is not
    # repeated in stage 2.
    local bootfs_populated=0
    populate_bootfs_step "$host" "$disk" "$bootfs_part" || die "populating the boot partition failed"
    bootfs_populated=1
    ota_ssh "$host" "unitotem-ota-engine set-default-recovery --disk '${disk}' --firmware '${firmware_grub}' --bootfs-part '${bootfs_part}' --layout ab"
    log "Stage 1 complete: from here any power loss reboots into the fallback."

    log "=== Stage 2: UniTotem image ==="
    local hostip="${P[SSHCLIENT]:-}"
    [ -n "$hostip" ] && [ "$hostip" != none ] || hostip=$(ip -o route get "${host}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$hostip" ] || die "cannot determine the host IP towards the target"

    # Always populate the boot partition's file-level content (overlays/, bootcode.bin, README...), not only
    # when the table is recreated: without the .dtbo files in overlays/ no DRM device is created. Safe on an
    # already-provisioned target: cmd_populate_bootfs excludes config.txt/cmdline.txt, the recovery
    # kernel/initrd stage 1 just wrote, and every unitotem-ota.* runtime state file.
    if [ "$bootfs_populated" != 1 ]; then
        log "Populating the file-level content of the boot partition..."
        populate_bootfs_step "$host" "$disk" "$bootfs_part" || die "populating the boot partition failed"
    fi

    local -A block
    local partnum label cloner action used stream comp
    # The manifest is fed on fd 9, not stdin, in addition to ota_ssh's -n: an ssh inheriting the loop's stdin
    # would eat the rest of the manifest and drop every partition after the first restore.
    while read_kv_block block <&9; do
        partnum="${block[UNITOTEM_PART]:-}"
        [ -n "$partnum" ] || continue
        label="${block[UNITOTEM_PART_LABEL]:-}"
        action="${block[UNITOTEM_PART_ACTION]:-}"
        case "$action" in
            restore|raw)
                cloner="${block[UNITOTEM_PART_CLONER]}"
                used="${block[UNITOTEM_PART_USED_BYTES]}"
                stream="${block[UNITOTEM_PART_STREAM_FILE]}"
                comp="${block[UNITOTEM_PART_COMP]:-xz}"
                log "Restoring partition ${partnum} (${label}, ${cloner})..."
                local pid; pid=$(serve_file_once "${OPT_PARTS}/${stream}" "$OPT_PORT")
                wait_port_bound "$OPT_PORT" 10 || die "data listener not ready (partition ${partnum})"
                ota_ssh "$host" "unitotem-ota-engine restore-part --disk '${disk}' --part '${partnum}' --cloner '${cloner}' --comp '${comp}' --used-bytes '${used}' --data-host '${hostip}' --data-port '${OPT_PORT}'"
                wait "$pid" 2>/dev/null || true
                ;;
            format)
                ota_ssh "$host" "unitotem-ota-engine format-part --disk '${disk}' --part '${partnum}' --label '${label}'"
                ;;
            data)
                if [ "$OPT_WIPE_DATA" = 1 ] || [ "${P[HAVE_DATA]:-0}" != 1 ]; then
                    ota_ssh "$host" "unitotem-ota-engine data-op --disk '${disk}' --part '${partnum}' --op mkfs"
                else
                    ota_ssh "$host" "unitotem-ota-engine data-op --disk '${disk}' --part '${partnum}' --op preserve"
                fi
                ;;
        esac
    done 9< "${OPT_PARTS}/parts.manifest"

    log "Mounting the restored system..."
    local mount_args="--disk '${disk}' --arch '${ARCH}' --root-part '${P_ROOT_PART}' --bootfs-part '${bootfs_part}' --data-part '${data_part}'"
    [ "$ARCH" = amd64 ] && [ -n "${P_BOOT_PART:-}" ] && mount_args="${mount_args} --boot-part '${P_BOOT_PART}'"
    # shellcheck disable=SC2086
    ota_ssh "$host" "unitotem-ota-engine mount-target ${mount_args}"

    local slot_arg="--slot a"
    ota_ssh "$host" "unitotem-ota-engine migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data ${slot_arg}" || warn "/etc migration failed (non-fatal: the new system uses its own /etc)"

    # Carry the probed network settings onto the installed system. A non-UniTotem device's configuration lives
    # in the root filesystem being overwritten, so migrate-etc-overlay (which only rescues what DATA held) has
    # nothing to restore. Skipped when a profile was migrated and when the link is wired DHCP. Non-fatal.
    local net_args="${slot_arg} --data-mnt /mnt/newroot/mnt/data --link '${P[NETLINK]:-wired}' --mode '${P[NETMODE]:-dhcp}'"
    [ -n "${P[NETADDR]:-}" ]        && net_args="${net_args} --addr '${P[NETADDR]}'"
    [ -n "${P[NETGW]:-}" ]          && net_args="${net_args} --gw '${P[NETGW]}'"
    [ -n "${P[NETDNS]:-}" ]         && net_args="${net_args} --dns '${P[NETDNS]}'"
    [ -n "${P[WIFI_SSID_B64]:-}" ]  && net_args="${net_args} --ssid-b64 '${P[WIFI_SSID_B64]}'"
    [ -n "${P[WIFI_PSK_B64]:-}" ]   && net_args="${net_args} --psk-b64 '${P[WIFI_PSK_B64]}'"
    # shellcheck disable=SC2086
    ota_ssh "$host" "unitotem-ota-engine apply-network ${net_args}" \
        || warn "applying the network settings failed (non-fatal)"

    # Layout 2 only: rpi-tryboot on Raspberry (P_LAYOUT check), GRUB on amd64/UEFI.
    if [ "$FIRMWARE" = rpi ]; then
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware rpi-tryboot --disk '${disk}' --bootfs-part '${bootfs_part}' --target /mnt/newroot --layout ab"
    else
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware '${FIRMWARE}' --target /mnt/newroot --layout ab"
    fi

    ota_ssh "$host" "unitotem-ota-engine umount-target" || true

    log "Rebooting into the real system for a trial..."
    # rpi-tryboot needs the literal argument "0 tryboot" passed to reboot(2) so the firmware reads tryboot.txt
    # instead of config.txt (which points at the fallback until promote-default runs); a plain reboot would
    # boot the fallback again. rpi-legacy (config.txt already swapped by set-trial-boot) and uefi/bios
    # (grub-reboot's one-shot) need nothing special. The real systemd reboot binary is required, not BusyBox's
    # (see unitotem/files/ota-hook), and `-f` skips the logind/D-Bus path that this initrd cannot satisfy.
    if [ "$FIRMWARE" = rpi ]; then
        ota_ssh "$host" "sync; reboot -f '0 tryboot'" 2>/dev/null || true
    else
        ota_ssh "$host" "sync; reboot -f" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
load_parts() {
    OPT_PARTS="${OPT_PARTS:-$(ls -td "${DIR}/deploy/${ARCH}/"*.parts 2>/dev/null | head -1)}"
    [ -n "$OPT_PARTS" ] && [ -d "$OPT_PARTS" ] \
        || die "no parts set found for ${ARCH} (use --parts or run deploy/make-parts.sh first)"

    P_DATA_PART=$(awk -F= '/^UNITOTEM_DATA_PART=/{print $2}' "${OPT_PARTS}/parts.manifest")
    P_BOOTFS_PART=$(awk -F= '/^UNITOTEM_BOOTFS_PART=/{print $2}' "${OPT_PARTS}/parts.manifest")
    # Partition number for a label: remember the last UNITOTEM_PART= seen, print it at the matching label line.
    part_num_for_label() {
        awk -F= -v want="$1" '
            /^UNITOTEM_PART=/{n=$2}
            /^UNITOTEM_PART_LABEL=/{if($2==want){print n; exit}}
        ' "${OPT_PARTS}/parts.manifest"
    }
    P_LAYOUT=$(awk -F= '/^UNITOTEM_LAYOUT=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")
    [ "$P_LAYOUT" = 2 ] || die "the parts set is not A/B (UNITOTEM_LAYOUT=${P_LAYOUT:-none}): only A/B parts sets (layout 2) are supported"
    [ "$ARCH" = amd64 ] || { [ "$ARCH" = arm64 ] && [ "$FIRMWARE" = rpi ] && [ "$TRYBOOT_CAPABLE" = 1 ]; } \
        || die "the A/B layout is supported on amd64 (UEFI and legacy BIOS) and on Raspberry with tryboot (target: ${ARCH}/${FIRMWARE}, tryboot=${TRYBOOT_CAPABLE:-0}); Raspberry without tryboot is not supported"
    P_ROOT_PART=$(part_num_for_label ROOT_A)
    P_BOOT_PART=$(part_num_for_label BOOT)
    P_BOOTFS_VOLID=$(awk -F= '/^UNITOTEM_PART_VOLID=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")
}

# A target that already runs UniTotem gets its data (everything on DATA: media, settings, accounts, update state) saved on this machine before
# anything is written. The archive is checked by reading it back; if the backup fails the deploy stops. --no-backup skips it.
# The scratch tree of native image builds on the target (unitotem-native-build) is not UniTotem data and is left out.
backup_running_system() {
    [ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && [ "$OPT_NO_BACKUP" != 1 ] && [ "$OPT_FALLBACK_ONLY" != 1 ] || return 0
    local label="${TARGET_USERHOST##*@}" ver ts used avail out
    ts=$(date +%Y%m%d-%H%M%S)
    ssh_t "[ -d /mnt/data ]" >/dev/null 2>&1 || { warn "no /mnt/data on the target: nothing to back up"; return 0; }
    ver=$(ssh_t "cat /usr/share/unitotem/release-version 2>/dev/null" | tr -d '\r\n'); ver="${ver:-unknown}"
    used=$(ssh_t "du -sk --exclude=unitotem-native-build /mnt/data 2>/dev/null | cut -f1" | tr -dc '0-9')
    mkdir -p "$OPT_BACKUP_DIR" || die "cannot create the backup directory ${OPT_BACKUP_DIR}"
    avail=$(df -Pk "$OPT_BACKUP_DIR" | awk 'NR==2{print $4}')
    [ -z "$used" ] || [ "${avail:-0}" -gt "$used" ] || die "not enough space in ${OPT_BACKUP_DIR} for the backup ($((used / 1024)) MiB of data, $((avail / 1024)) MiB free); free space or use --backup-dir"
    log "Backing up the UniTotem data of ${label} (${ver}, about $(( ${used:-0} / 1024 )) MiB) to ${OPT_BACKUP_DIR}..."
    out=$(backup_stream "$OPT_BACKUP_DIR" "unitotem-data-${label}-${ver}-${ts}" ssh_t "tar -C /mnt/data --numeric-owner --exclude=./unitotem-native-build -cf - .") \
        || die "the backup of ${label} failed: nothing was changed on the target (--no-backup skips the backup)"
    log "Backup written and verified: ${out}"
}

# UniTotem 1.x/2.x on a single-root system keeps its data in a few places of the ordinary root filesystem: settings in /etc/unitotem, the uploaded
# media next to the package, root's crontab (the scheduled reboots/shutdowns), the network profiles, hostname, the TLS certificate and the kiosk
# launch file. They are saved before the disk is replaced, with the same checks as the A/B backup.
LEGACY_DATA_PATHS="etc/unitotem usr/share/unitotem-manager/static/uploaded var/spool/cron/crontabs/root etc/netplan etc/hostname etc/hosts etc/ssl/unitotem.pem etc/asound.conf etc/X11/xinit/xinitrc"
backup_legacy_system() {
    [ -n "${P[LEGACY_UNITOTEM]:-}" ] && [ "${P[LEGACY_UNITOTEM]}" != none ] && [ "${P[HAVE_UNITOTEM]:-0}" != 1 ] \
        && [ "$OPT_NO_BACKUP" != 1 ] && [ "$OPT_FALLBACK_ONLY" != 1 ] || return 0
    local label="${TARGET_USERHOST##*@}" ver="${P[LEGACY_UNITOTEM]}" ts used avail out
    ts=$(date +%Y%m%d-%H%M%S)
    used=$(ssh_t "cd /; du -sck $LEGACY_DATA_PATHS 2>/dev/null | tail -1 | cut -f1" | tr -dc '0-9')
    mkdir -p "$OPT_BACKUP_DIR" || die "cannot create the backup directory ${OPT_BACKUP_DIR}"
    avail=$(df -Pk "$OPT_BACKUP_DIR" | awk 'NR==2{print $4}')
    [ -z "$used" ] || [ "${avail:-0}" -gt "$used" ] || die "not enough space in ${OPT_BACKUP_DIR} for the backup ($((used / 1024)) MiB of data, $((avail / 1024)) MiB free); free space or use --backup-dir"
    log "Backing up the data of UniTotem ${ver} (single root) of ${label}, about $(( ${used:-0} / 1024 )) MiB, to ${OPT_BACKUP_DIR}..."
    out=$(backup_stream "$OPT_BACKUP_DIR" "unitotem-legacy-${label}-${ver}-${ts}" ssh_t \
        "cd /; tar --numeric-owner --ignore-failed-read -cf - \$(for p in $LEGACY_DATA_PATHS; do [ -e \$p ] && echo \$p; done)") \
        || die "the backup of ${label} failed: nothing was changed on the target (--no-backup skips the backup)"
    log "Backup written and verified: ${out}"
}

# Credential-free check of the freshly deployed system: a new system has no known account (root is open to the
# first-administrator script only), so the probe uses the web interface. Prints the answer that matched and
# returns 0: HTTPS /login is 200, or 302/303 to .../setup; else plain HTTP / redirects to https.
post_deploy_probe() {
    local ip="$1" answer code redir
    answer=$(curl -k -s -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "https://${ip}/login" 2>/dev/null) || answer=""
    answer="${answer% }"
    code="${answer%% *}"; redir="${answer#* }"
    if [ "$code" = 200 ] || { { [ "$code" = 302 ] || [ "$code" = 303 ]; } && [[ "$redir" == */setup ]]; }; then
        echo "$answer"; return 0
    fi
    answer=$(curl -s -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "http://${ip}/" 2>/dev/null) || answer=""
    answer="${answer% }"
    code="${answer%% *}"; redir="${answer#* }"
    case "$code" in
        301|302|307|308) [[ "$redir" == https://* ]] && { echo "$answer"; return 0; } ;;
    esac
    return 1
}

cmd_deploy() {
    do_probe
    select_disk

    load_parts
    local min_disk; min_disk=$(awk -F= '/^UNITOTEM_MIN_DISK_BYTES=/{print $2}' "${OPT_PARTS}/parts.manifest")
    [ "$TARGET_DISK_SIZE" -ge "$min_disk" ] \
        || die "${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE")) is smaller than the required minimum ($(bytes_human "$min_disk"))"

    echo ""
    echo "Parts set   : $(basename "$OPT_PARTS")"
    echo "Target disk : ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE"))"
    echo "Target      : $([ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && echo 'already UniTotem (prepared path)' || { [ -n "${P[LEGACY_UNITOTEM]:-}" ] && [ "${P[LEGACY_UNITOTEM]}" != none ] && echo "UniTotem ${P[LEGACY_UNITOTEM]} on a single-root system (fallback push, data backed up first)" || echo 'other system (fallback push)'; })"

    secure_boot_gate
    changes_gate

    if [ "$OPT_YES" != 1 ]; then
        read -rp "Proceed with the deploy? [type YES]: " ans
        [ "$ans" = "YES" ] || die "cancelled by the user"
    fi

    local target_ip="${TARGET_USERHOST##*@}"

    backup_running_system
    backup_legacy_system

    # The fallback accepts only this key (armed below); the private key stays on this machine.
    ota_arm_key "$target_ip"
    local arm_pub; arm_pub=$(ota_key_publine "$OTA_ARM_KEY") || die "cannot read the public key ${OTA_ARM_KEY}.pub"

    if [ "${P[HAVE_UNITOTEM]:-0}" = 1 ]; then
        log "Arming OTA from the running system..."
        local wipe_arg=""; [ "$OPT_WIPE_DATA" = 1 ] && wipe_arg="--wipe-data"
        # Not `|| die`: this command reboots the target, so ssh's exit status is a race ("Connection closed by
        # remote host" even when arming succeeded). The verdict is wait_ota_reachable below: if arming failed
        # the fallback never appears. The target-side script defers its reboot (unitotem/files/unitotem-ota-arm),
        # and this stays tolerant for targets running an older image.
        # The public line goes on stdin: --authkey-file - (unitotem-ota-arm validates it before any write).
        ssh_t "unitotem-ota-arm --port 2222 ${wipe_arg} --authkey-file -" <<< "$arm_pub" \
            || warn "SSH session closed while arming (expected: the target is rebooting) - checking for the fallback to appear"
    else
        local legacy_cmdline
        legacy_cmdline=$(build_legacy_cmdline "$arm_pub") || exit 1
        push_recovery_kernel
        if [ "$FIRMWARE" = rpi ]; then
            arm_rpi "$legacy_cmdline"
        else
            [ "${P[GRUB_REBOOT]}" = 1 ] || die "grub-reboot not found on the target: cannot arm a one-shot entry"
            arm_grub "$legacy_cmdline"
        fi
        do_reboot
    fi

    wait_ota_reachable "$target_ip"
    target_ip="${OTA_FOUND_HOST:-$target_ip}"
    if [ "$OPT_FALLBACK_ONLY" = 1 ]; then
        log "Fallback ready at ${target_ip}:2222. Nothing written to the disk (--fallback-only)."
        return 0
    fi
    run_ota_sequence "$target_ip" "$TARGET_DISK_BYID"

    if [ "$SB_MODE" = noshim ]; then
        echo ""
        echo "=============================================================="
        echo " INSTALLATION COMPLETE, BUT THE SYSTEM WILL NOT BOOT BY ITSELF"
        echo "=============================================================="
        echo " Secure Boot is active and you chose to install without shim: at reboot the firmware shows 'Security Violation'."
        echo " A PHYSICAL INTERVENTION is needed: enter the firmware setup, disable Secure Boot, then reboot."
        echo "=============================================================="
        return 0
    fi

    log "OTA sequence sent. Waiting for ${target_ip} to answer on the new system (up to 10 minutes)..."
    local waited=0 answer
    sleep 30
    while ! answer=$(post_deploy_probe "$target_ip"); do
        sleep 10; waited=$((waited + 10))
        [ "$waited" -lt 600 ] || { warn "${target_ip} did not answer on the new system within 10 minutes - check manually (it may still be in stage 2, or waiting in the fallback)"; return 0; }
    done
    log "Deploy complete: ${target_ip} answers on the new system (HTTPS /login: ${answer})."
    return 0
}

# ---------------------------------------------------------------------------
# recover: when the disk is about to be laid out again (DATA not kept) but DATA still mounts, its content is saved first. A DATA that does not
# mount cannot be saved: that is reported and the recovery goes on (the operator already confirmed it).
backup_fallback_data() {
    local host="$1" ts; ts=$(date +%Y%m%d-%H%M%S)
    log "DATA will be rewritten: saving its content first to ${OPT_BACKUP_DIR}..."
    local out
    out=$(backup_stream "$OPT_BACKUP_DIR" "unitotem-data-${host}-recovery-${ts}" ota_ssh "$host" \
        'd=$(blkid -L DATA) && mkdir -p /tmp/dbk && mount -t ext4 -o ro "$d" /tmp/dbk && { tar -C /tmp/dbk --numeric-owner --exclude=./unitotem-native-build -cf - .; r=$?; umount /tmp/dbk; exit $r; }') \
        && log "Backup written and verified: ${out}" \
        || warn "DATA could not be saved (it does not mount or the transfer failed): continuing without a backup"
}

cmd_recover() {
    # The target is already in the OTA fallback (both slots unusable, or an unrepairable boot failure): nothing to
    # arm, everything is learned from the engine's probe. DATA is kept when the partition table still has the
    # expected shape and DATA passes a read-only fsck; otherwise (or with --wipe-data) the disk is laid out again
    # and DATA is lost.
    local host port
    [[ "$RECOVER_HOSTPORT" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)(:([0-9]{1,5}))?$ ]] \
        || die "recover: invalid address '${RECOVER_HOSTPORT}' (HOST or HOST:PORT)"
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-${OTA_PORT:-2222}}"
    (( 10#$port >= 1 && 10#$port <= 65535 )) || die "recover: port out of range: ${port}"
    # OTA_SSH_OPTS (deploy/lib.sh) is built at source time: replace the port value after its -p flag.
    local i
    for i in "${!OTA_SSH_OPTS[@]}"; do
        [ "${OTA_SSH_OPTS[i]}" = -p ] && OTA_SSH_OPTS[i+1]="$((10#$port))"
    done
    log "Connecting to the target in fallback (${host}:$((10#$port)))..."
    # Credentials: ota_ssh (ota_auth_for) uses the per-target key of this host when it exists, else OTA_FALLBACK_KEY,
    # OTA_FALLBACK_OPEN=1 or OTA_FALLBACK_PASSWORD from the environment; --fallback-user sets the login user.
    ota_ssh "$host" true || die "cannot reach ${host} on the OTA session (port 2222): check the fallback credentials (OTA_FALLBACK_KEY, or OTA_FALLBACK_USER with OTA_FALLBACK_PASSWORD, or OTA_FALLBACK_OPEN=1)"

    # Disk: --disk, else the one that carries our partitions, else the only disk.
    local disk="$OPT_DISK" cand d
    if [ -z "$disk" ]; then
        local disks; disks=$(ota_ssh "$host" "lsblk -dpno NAME,TYPE | awk '\$2==\"disk\"{print \$1}' | grep -v -E '/dev/(loop|ram|zram|sr|fd)'")
        local n=0
        for d in $disks; do
            n=$((n + 1))
            if ota_ssh "$host" "blkid -L DATA; blkid -L ROOT_A; blkid -L ROOT; blkid -L EFI; blkid -L FIRMWARE" 2>/dev/null | grep -q "^${d}"; then cand="$d"; break; fi
        done
        [ -n "${cand:-}" ] || { [ "$n" = 1 ] && cand="$disks"; }
        [ -n "${cand:-}" ] || die "cannot choose the disk automatically: repeat with --disk /dev/..."
        disk="$cand"
    fi

    declare -A E
    local line probe_out
    probe_out=$(ota_ssh "$host" "unitotem-ota-engine probe --disk '${disk}'")
    while IFS= read -r line; do [ -n "$line" ] && E["${line%%=*}"]="${line#*=}"; done <<< "$probe_out"
    [ -n "${E[UNITOTEM_DISK]:-}" ] || die "the target does not resolve the disk ${disk}"

    case "${E[UNITOTEM_ARCH_HOST]:-}" in
        aarch64) ARCH=arm64; FIRMWARE=rpi; TRYBOOT_CAPABLE="${E[UNITOTEM_TRYBOOT]:-0}" ;;
        x86_64)  ARCH=amd64; FIRMWARE=$([ "${E[UNITOTEM_EFI]:-0}" = 1 ] && echo uefi || echo bios); TRYBOOT_CAPABLE=0 ;;
        *) die "unrecognised target architecture: ${E[UNITOTEM_ARCH_HOST]:-?}" ;;
    esac
    load_parts

    # The table must still have the shape the parts set would write: same number of partitions, DATA on the expected
    # number and start sector (otherwise restore-part would write the slots over a different geometry than DATA's).
    local nparts_exp data_start_exp
    nparts_exp=$(grep -c ' : start=' "${OPT_PARTS}/layout.sfdisk" || true)
    data_start_exp=$(grep -E "(^|[^0-9])${P_DATA_PART}[[:space:]]*:" "${OPT_PARTS}/layout.sfdisk" | head -1 | grep -oE 'start=[[:space:]]*[0-9]+' | grep -oE '[0-9]+' || true)
    # asked here, not of the engine: the recovery initrd on the target may be older than this script
    E[UNITOTEM_DATA_START]=$(ota_ssh "$host" 'd=$(blkid -L DATA 2>/dev/null) && cat /sys/class/block/${d##*/}/start' 2>/dev/null || true)
    local keep=1 why=""
    [ "$OPT_WIPE_DATA" != 1 ]                                  || { keep=0; why="--wipe-data requested"; }
    [ "${E[UNITOTEM_HAVE_DATA]:-0}" = 1 ]                      || { keep=0; why="the DATA partition is not readable"; }
    [ "${E[UNITOTEM_DATA_FSCK]:-x}" = 0 ]                      || { keep=0; why="DATA fails the read-only check (fsck=${E[UNITOTEM_DATA_FSCK]:-n/a})"; }
    [ "$(echo ${E[UNITOTEM_DATA_PARTN]:-x})" = "$P_DATA_PART" ]    || { keep=0; why="DATA is not on the expected partition ${P_DATA_PART}"; }
    [ "${E[UNITOTEM_DATA_START]:-x}" = "$data_start_exp" ]     || { keep=0; why="DATA does not start at the expected sector (${E[UNITOTEM_DATA_START]:-?} instead of ${data_start_exp})"; }
    [ "${E[UNITOTEM_NPARTS]:-0}" = "$nparts_exp" ]             || { keep=0; why="the table has ${E[UNITOTEM_NPARTS]:-0} partitions, ${nparts_exp} are needed"; }
    RECOVER_MODE=1; RECOVER_KEEP_TABLE=$keep
    RECOVER_BOOTFS_FRESH=0
    if [ "${E[UNITOTEM_HAVE_BOOTFS]:-0}" != 1 ] || { [ -n "${E[UNITOTEM_BOOTFS_FSCK]:-}" ] && [ "${E[UNITOTEM_BOOTFS_FSCK]}" != 0 ]; }; then
        RECOVER_BOOTFS_FRESH=1
    fi
    P[HAVE_DATA]=$keep
    P[HAVE_UNITOTEM]=$keep
    P[SSHCLIENT]="${OTA_HOSTIP:-none}"   # OTA_HOSTIP: the address the target reaches this machine at, when it is not the one routing to it (QEMU NAT, tests)
    # Secure Boot on: only the signed chain (shim) can boot; without it the recovered machine would stop at "Security Violation"
    [ "${E[UNITOTEM_SECUREBOOT]:-}" = 1 ] && SB_MODE=shim

    echo ""
    echo "Recovery    : ${host}  disk ${disk}  (${ARCH}/${FIRMWARE})"
    echo "Parts set   : $(basename "$OPT_PARTS")"
    if [ "$keep" = 1 ]; then
        echo "DATA        : INTACT, will be PRESERVED (table unchanged)"
        [ "$RECOVER_BOOTFS_FRESH" = 1 ] && echo "Boot        : boot partition damaged, will be reformatted"
    else
        echo "DATA        : NOT preservable (${why}) - the disk is rewritten from scratch"
    fi
    if [ "$OPT_YES" != 1 ]; then
        read -rp "Proceed with the recovery? [type YES]: " ans
        [ "$ans" = "YES" ] || die "cancelled by the user"
    fi

    if [ "$keep" != 1 ] && [ "${E[UNITOTEM_HAVE_DATA]:-0}" = 1 ] && [ "$OPT_NO_BACKUP" != 1 ]; then
        backup_fallback_data "$host"
    fi
    run_ota_sequence "$host" "$disk"
    log "Recovery sequence sent: the target reboots into the restored system."
}

# What has changed on the target since its image was built. An OTA replaces ROOT wholesale, so local edits are lost.
# The scan runs on the target (/usr/sbin/unitotem-ota-changes needs dpkg, so it cannot live in the fallback's
# ota-engine.sh); this side presents the result and gates on it.

# exit 0 = nothing changed, 1 = changes found, 2 = the check itself failed. 127 means the target has no such
# command (an image that predates it), which does not block a deploy.
CHANGES_OUT="" CHANGES_RC=0
run_changes_check() {
    local flag="${1:-}"
    CHANGES_OUT=$(ssh_t "command -v unitotem-ota-changes >/dev/null 2>&1 || exit 127; unitotem-ota-changes check ${flag}" 2>&1) \
        && CHANGES_RC=0 || CHANGES_RC=$?
}

cmd_changes() {
    setup_target_privilege
    if [ "$OPT_JSON" = 1 ]; then
        run_changes_check --json
    else
        run_changes_check
    fi
    case "$CHANGES_RC" in
        0|1) printf '%s\n' "$CHANGES_OUT" ;;
        127) echo "changes: the target has no unitotem-ota-changes (image predates this feature)" >&2; return 3 ;;
        *)   echo "changes: check failed on the target (exit ${CHANGES_RC}): ${CHANGES_OUT}" >&2; return 2 ;;
    esac
    return "$CHANGES_RC"
}

# Secure Boot (amd64/UEFI). The firmware refuses anything not signed by a key it trusts, and UniTotem's own GRUB is
# unsigned. The operator must pick explicitly: boot through Debian's Microsoft-signed shim (the chain is staged in the
# image and activated by populate-bootfs --secure-boot shim), or install as-is and fix the firmware afterwards. Both
# can need someone at the machine, so the choice is never made silently.
secure_boot_gate() {
    [ "$ARCH" = amd64 ] && [ "$FIRMWARE" = uefi ] || return 0
    case "${P[SECUREBOOT]:-unknown}" in
        0) [ -z "$OPT_SECURE_BOOT" ] || warn "--secure-boot ${OPT_SECURE_BOOT}: ignored, Secure Boot is not active on the target"; return 0 ;;
        1) ;;
        *) warn "Secure Boot state cannot be detected on the target: proceeding as if it were off (if it is on, the installed system will not boot)"; return 0 ;;
    esac

    # A UniTotem already running with Secure Boot on boots through a trusted path: keep the shim chain (only with an
    # A/B parts set, the only one that stages it; otherwise fall through to the choice).
    if [ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && [ -z "$OPT_SECURE_BOOT" ]; then
        log "Secure Boot is active and the target is already UniTotem: keeping the shim chain"
        SB_MODE=shim; return 0
    fi

    if [ -z "$OPT_SECURE_BOOT" ]; then
        [ "$OPT_YES" != 1 ] \
            || die "Secure Boot is ACTIVE on the target: choose explicitly with --secure-boot shim | noshim (or disable it in the firmware and run again)"
        echo ""
        echo "=============================================================="
        echo " SECURE BOOT is ACTIVE on the target"
        echo "=============================================================="
        echo " The firmware only accepts boot programs signed with a key it knows."
        echo " UniTotem's GRUB is not signed. How should I proceed?"
        echo ""
        echo "  1) INSTALL WITH SHIM"
        echo "     Boot goes through shim (Microsoft-signed) -> Debian-signed GRUB and kernel: no change to the firmware needed."
        echo "     WARNING, a PHYSICAL INTERVENTION on the machine may be needed:"
        echo "       - with an NVIDIA GPU the proprietary driver is an unsigned module: a key (MOK) must be enrolled"
        echo "         from the console at first boot, otherwise there is no accelerated video driver;"
        echo "       - if the firmware does not trust the Microsoft UEFI CA (custom Secure Boot), shim is rejected."
        echo "     If the current system is not Debian, the first step (one-shot GRUB entry) may fail: its shim"
        echo "     rejects the Debian kernel (\"bad shim signature\") and the machine stops at the GRUB prompt."
        echo ""
        echo "  2) INSTALL WITHOUT SHIM"
        echo "     The install completes, but at reboot the firmware rejects the unsigned GRUB (\"Security Violation\")."
        echo "     A PHYSICAL INTERVENTION is REQUIRED: disable Secure Boot in the firmware (or enroll the hash)."
        echo ""
        echo "  3) ABORT"
        echo "     Nothing is touched. Disable Secure Boot in the firmware and run the deploy again."
        echo "=============================================================="
        local c
        read -rp "Choice [1/2/3]: " c
        case "$c" in 1) OPT_SECURE_BOOT=shim ;; 2) OPT_SECURE_BOOT=noshim ;; *) OPT_SECURE_BOOT=abort ;; esac
    fi

    case "$OPT_SECURE_BOOT" in
        abort)  die "aborted: Secure Boot is active on the target. Disable it in the firmware (or choose --secure-boot shim|noshim) and run again" ;;
        shim)
            SB_MODE=shim
            warn "Secure Boot: installing with shim. With an NVIDIA GPU the MOK key must be enrolled from the console (physical intervention)."
            ;;
        noshim)
            SB_MODE=noshim
            warn "Secure Boot: installing WITHOUT shim. At reboot the firmware will show 'Security Violation': a physical intervention is needed (disable Secure Boot)."
            ;;
    esac
}

changes_gate() {
    # A non-UniTotem device has no baseline to compare against, and the whole disk is overwritten anyway.
    if [ "${P[HAVE_UNITOTEM]:-0}" != 1 ]; then
        return 0
    fi

    log "Checking the changes made on the target since installation..."
    run_changes_check

    if [ "$CHANGES_RC" = 127 ]; then
        # Expected when the running image predates the tool.
        warn "the target does not provide unitotem-ota-changes: cannot tell what will be overwritten"
        return 0
    fi
    if [ "$CHANGES_RC" -gt 1 ]; then
        warn "change check failed (${CHANGES_OUT}) - continuing without it"
        return 0
    fi
    if [ "$CHANGES_RC" = 0 ]; then
        log "No changes from the installed image."
        return 0
    fi

    local verdict digest
    verdict=$(printf '%s\n' "$CHANGES_OUT" | awk '/^Verdict:/{print $2; exit}')
    digest=$(printf '%s\n' "$CHANGES_OUT" | awk '/^Digest:/{print $2; exit}')

    echo ""
    echo "=============================================================="
    echo " The deploy replaces ROOT: the following would be LOST."
    echo "=============================================================="
    printf '%s\n' "$CHANGES_OUT"
    echo "=============================================================="

    # A caller-supplied digest must still describe what is on the device now, so a package installed between the
    # operator's review and the confirmation cannot be destroyed unseen.
    if [ -n "$OPT_ACCEPT_CHANGES" ]; then
        if [ "$OPT_ACCEPT_CHANGES" = "$digest" ]; then
            log "Changes accepted (digest matches)."
            return 0
        fi
        die "the supplied digest does not match the current changes (expected ${digest}) - the system changed since it was shown"
    fi

    if [ "$OPT_YES" = 1 ]; then
        warn "--yes: proceeding and overwriting the changes listed above (verdict: ${verdict})"
        return 0
    fi

    local ans
    case "$verdict" in
        packages-only) read -rp "Only installed packages are affected. Proceed and lose them? [type YES]: " ans ;;
        *)             read -rp "Files were also changed that packages do NOT explain. Proceed? [type YES]: " ans ;;
    esac
    [ "$ans" = "YES" ] || die "cancelled by the user"
}

cmd_disarm() {
    do_probe
    log "Removing the arming on ${TARGET_USERHOST} (${FIRMWARE})..."
    if [ "$FIRMWARE" = rpi ]; then
        ssh_t bash -s -- "${P[BOOTMNT]}" <<'REMOTE_EOF'
set -eu
cd "$1"
if [ -f config.txt.unitotem-bak ];  then mv -f config.txt.unitotem-bak  config.txt;  fi
if [ -f cmdline.txt.unitotem-bak ]; then mv -f cmdline.txt.unitotem-bak cmdline.txt; fi
rm -f unitotem-recovery-vmlinuz unitotem-recovery-initrd.img
sync
REMOTE_EOF
    else
        ssh_t bash -s <<'REMOTE_EOF'
set -eu
rm -f /etc/grub.d/99_unitotem_flash
command -v update-grub >/dev/null 2>&1 && update-grub || grub-mkconfig -o /boot/grub/grub.cfg
rm -f "$(findmnt -no TARGET /boot 2>/dev/null || echo /boot)/unitotem-recovery-vmlinuz" \
      "$(findmnt -no TARGET /boot 2>/dev/null || echo /boot)/unitotem-recovery-initrd.img"
REMOTE_EOF
    fi
    log "Disarmed. The target will reboot normally."
}

case "$SUBCMD" in
    probe)   do_probe; print_probe ;;
    changes) cmd_changes ;;
    deploy)  cmd_deploy ;;
    disarm)  cmd_disarm ;;
    recover) cmd_recover ;;
esac
