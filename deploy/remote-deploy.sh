#!/bin/bash
# Two-stage OTA deploy orchestrator - host side. Drives deploy/ota-engine.sh
# on the target entirely over SSH: the real system's sshd for everything
# before the target reboots into OTA mode, then dropbear (inside the
# fallback/recovery initramfs, ephemeral host key, port 2222 - see
# deploy/lib.sh's ota_ssh()) for every ota-engine.sh subcommand after that.
# Bulk partition data always goes over a separate plain-netcat connection
# (deploy/lib.sh's serve_file_once/wait_port_bound) - never through SSH.
#
# See ~/.claude/plans/prepara-uno-script-che-fluttering-koala.md
# for the full design.
#
# Usage:
#   ./deploy/remote-deploy.sh probe   root@host
#   ./deploy/remote-deploy.sh changes root@host [--json]
#   ./deploy/remote-deploy.sh deploy  root@host [--parts DIR] [--disk BYID]
#                                     [--port N] [--wipe-data]
#                                     [--console STR] [--debug] [--yes]
#                                     [--accept-changes DIGEST]
#                                     [--secure-boot shim|noshim|abort]
#   ./deploy/remote-deploy.sh disarm  root@host
#
# See API-OTA.md for the machine-readable contract behind `changes` and
# `--accept-changes` - it is what the UniTotem web interface drives.
#   ./deploy/remote-deploy.sh recover HOST[:PORT] [--parts DIR] ...
#   ./deploy/remote-deploy.sh serve   [--parts DIR] ...
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${DIR}/deploy/lib.sh"

require_cmd ssh scp sshpass sha256sum xz stat awk sed grep socat ss timeout ip base64

# The sudo askpass helper holds the target password, so it must not outlive
# the run - including on failure or Ctrl-C. No-op when we were already root
# or when sudo turned out to be passwordless.
trap clear_target_privilege EXIT

# ---------------------------------------------------------------------------
SUBCMD="${1:-}"; shift || true

case "$SUBCMD" in
    probe|deploy|disarm|changes)
        TARGET_USERHOST="${1:-}"; shift || true
        [ -n "$TARGET_USERHOST" ] || { echo "Uso: $0 $SUBCMD user@host [opzioni]" >&2; exit 1; }
        ;;
    recover)
        RECOVER_HOSTPORT="${1:-}"; shift || true
        [ -n "$RECOVER_HOSTPORT" ] || { echo "Uso: $0 recover HOST[:PORT] [opzioni]" >&2; exit 1; }
        ;;
    serve) ;;
    *) echo "Uso: $0 {probe|deploy|changes|disarm|recover|serve} ... [opzioni]" >&2; exit 1 ;;
esac

OPT_PARTS="" OPT_DISK="" OPT_PORT="9700" OPT_WIPE_DATA=0
# Empty by default rather than a fixed "tty0": build_legacy_cmdline() picks
# an arch-appropriate console when this is unset (tty0 for amd64, tty1 +
# serial for arm64 - matching every other cmdline.txt this project writes),
# and still honors an explicit --console override when one is given.
OPT_CONSOLE="" OPT_DEBUG=0 OPT_YES=0 OPT_FALLBACK_ONLY=0
# What to do when the target has Secure Boot enabled (amd64/UEFI): shim | noshim | abort. Empty = ask (or refuse, when
# non-interactive). See secure_boot_gate.
OPT_SECURE_BOOT="" SB_MODE=""
# Non-interactive confirmation of a known change set. Carries the digest the
# operator was actually shown, so a UI-driven deploy cannot proceed over a
# different set of changes than the one that was approved - see cmd_changes.
OPT_ACCEPT_CHANGES="" OPT_JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --parts)      OPT_PARTS="$2"; shift 2 ;;
        --disk)       OPT_DISK="$2"; shift 2 ;;
        --port)       OPT_PORT="$2"; shift 2 ;;
        --wipe-data)  OPT_WIPE_DATA=1; shift ;;
        --console)    OPT_CONSOLE="$2"; shift 2 ;;
        --debug)      OPT_DEBUG=1; shift ;;
        --yes)        OPT_YES=1; shift ;;
        --fallback-only) OPT_FALLBACK_ONLY=1; shift ;;
        --accept-changes) OPT_ACCEPT_CHANGES="$2"; shift 2 ;;
        --json)       OPT_JSON=1; shift ;;
        --secure-boot) OPT_SECURE_BOOT="$2"; shift 2
                       case "$OPT_SECURE_BOOT" in shim|noshim|abort) ;; *) die "--secure-boot: valori ammessi shim, noshim, abort" ;; esac ;;
        *) die "Opzione sconosciuta: $1" ;;
    esac
done

# A caller that supplies --accept-changes has already been shown what will be
# destroyed and has confirmed it - that digest IS the confirmation, and it is
# a stricter one than typing SI. Without this the generic prompts (disk
# choice, final "procedo?") still block on a terminal that a web UI does not
# have, so a UI-driven deploy could never actually complete. The digest is
# still verified before anything is armed: changes_gate checks it before this
# flag is ever consulted.
[ -n "$OPT_ACCEPT_CHANGES" ] && OPT_YES=1

# ---------------------------------------------------------------------------
# Probe: one SSH round-trip, parseable KEY: value / DISK: ... lines. Adds
# to the pre-redesign do_probe(): UniTotem/DATA detection, tryboot
# capability, and the network hints deploy/ota-engine.sh's recovery
# environment needs to reach back out (see the plan's "sonda di rete").
# ---------------------------------------------------------------------------
declare -A P
DISKS=()

do_probe() {
    log "Interrogo ${TARGET_USERHOST}..."
    local out
    # ssh_t, not a raw ssh: the probe reads block devices (blkid, dumpe2fs,
    # lsblk) to decide whether DATA exists and what the layout is, and an
    # unprivileged reader gets permission denied on /dev/mmcblk*. That would
    # not fail loudly - it would just report HAVE_DATA: 0 on a device that
    # does have DATA, and the deploy would reformat it.
    out=$(ssh_t bash -s <<'REMOTE_EOF'
set -u
echo "UNAME_M: $(uname -m)"
[ -d /sys/firmware/efi ] && echo "EFI: 1" || echo "EFI: 0"
MODEL=""
[ -r /proc/device-tree/model ] && MODEL=$(tr -d '\0' < /proc/device-tree/model)
echo "MODEL: ${MODEL:-none}"
# Tryboot capability, straight from the device tree the Raspberry Pi
# firmware injects into /proc/device-tree/chosen/bootloader - readable with
# no vcgencmd and no rpi-eeprom package on the target (neither is installed
# by this project). That node is published only by the EEPROM bootloader,
# and only when it understands tryboot, so its mere presence IS the
# capability signal; the SoC check then excludes the boards that have no
# EEPROM bootloader at all (Pi 3 / Zero 2 boot bootcode.bin off the SD).
# Note this describes hardware+firmware, not the running OS, so the answer
# is the same whether we probe a stock Raspberry Pi OS or a deployed
# UniTotem.
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

[ -d /etc/kiosk ] && echo "HAVE_UNITOTEM: 1" || echo "HAVE_UNITOTEM: 0"

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

# Network hints for the OTA payload's reconnection: interface/link type/
# dhcp-vs-static as currently configured, plus WiFi credentials if that's
# how this box is connected. See the plan's "sonda di rete" - the secret is
# not deleted after use (see deploy/ota-engine.sh's serve-fallback and the
# plan's reasoning: it is already in cleartext in NetworkManager/wpa_supplicant
# config either way, so removing it from unitotem-ota.conf buys nothing).
# SSH_CONNECTION is absent whenever this runs under sudo (env_reset strips
# it), and this script runs with `set -u`, so it must be defaulted or the
# whole probe dies with "unbound variable" the moment the target is reached
# as a non-root user. Losing the value is harmless: run_ota_sequence already
# falls back to `ip -o route get <target>` on the host side, which arguably
# beats trusting the target to echo our own address back at us.
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
        # Without this a statically-addressed device gets carried over with an
        # address and a gateway but no resolver, which looks like a working
        # network right up until the first name lookup. Semicolon-separated,
        # which is the form NetworkManager keyfiles want.
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
) || die "impossibile contattare ${TARGET_USERHOST} via SSH"

    while IFS= read -r line; do
        case "$line" in
            "DISK: "*) DISKS+=("${line#DISK: }") ;;
            *": "*)    P["${line%%:*}"]="${line#*: }" ;;
        esac
    done <<< "$out"

    [ ${#DISKS[@]} -gt 0 ] || die "nessun disco rilevato sul target"

    if echo "${P[MODEL]:-}" | grep -qi "raspberry pi"; then
        echo "${P[MODEL]}" | grep -qiE "raspberry pi (3|4|5|.*zero 2)" \
            || die "modello rilevato (${P[MODEL]}) non risulta a 64-bit: l'immagine deployata e' sempre arm64, non installabile qui"
        ARCH=arm64; FIRMWARE=rpi
        # Tryboot needs two independent things, so both are checked rather
        # than assumed:
        #  1. the FIRMWARE side - an EEPROM bootloader that understands
        #     tryboot. Detected above from /proc/device-tree/chosen/bootloader,
        #     which the firmware itself publishes (no vcgencmd/rpi-eeprom
        #     needed on the target).
        #  2. the KERNEL side - the "0 tryboot" reboot(2) argument only
        #     reaches the firmware's PM_RSTS flag on the raspberrypi/linux
        #     fork; it is silently ignored on a mainline/Debian generic
        #     kernel (confirmed on this very hardware, and matching
        #     raspberrypi/rpi-eeprom#716). That was the original blocker and
        #     is now satisfied: kiosk/stage1-packages.sh installs
        #     linux-image-rpi-v8, and - the part that actually matters here -
        #     the reboot is issued from the RESIDENT FALLBACK initrd, which
        #     kiosk/stage1-recovery-initrd.sh builds from that same rpi
        #     kernel. So the kernel doing the tryboot reboot is always ours,
        #     never whatever the probed system happens to run.
        # Falls back to rpi-legacy (direct config.txt swap, protected by the
        # initramfs integrity checks + boot counter) on any board that fails
        # check 1 - Pi 3 / Zero 2, which have no EEPROM bootloader at all.
        TRYBOOT_CAPABLE="${P[TRYBOOT]:-0}"
    elif [ "${P[EFI]}" = 1 ]; then
        ARCH=amd64; FIRMWARE=uefi; TRYBOOT_CAPABLE=0
    else
        ARCH=amd64; FIRMWARE=bios; TRYBOOT_CAPABLE=0
    fi
}

print_probe() {
    echo "Architettura target immagine : ${ARCH}  (${P[UNAME_M]}, modello: ${P[MODEL]})"
    if [ "${FIRMWARE}" = rpi ]; then
        local tb_why="EEPROM bootloader senza supporto tryboot (o assente: Pi 3/Zero 2)"
        [ "${TRYBOOT_CAPABLE}" = 1 ] && tb_why="rilevato via device-tree, SoC ${P[SOC]:-n/d}"
        echo "Firmware                     : ${FIRMWARE}  (tryboot: ${TRYBOOT_CAPABLE} - ${tb_why})"
        echo "Modalita' boot di prova      : $([ "${TRYBOOT_CAPABLE}" = 1 ] && echo 'rpi-tryboot (protezione a livello firmware)' || echo 'rpi-legacy (swap config.txt + boot counter)')"
    else
        echo "Firmware                     : ${FIRMWARE}  (tryboot: ${TRYBOOT_CAPABLE})"
    fi
    if [ "${FIRMWARE}" = uefi ]; then
        case "${P[SECUREBOOT]:-unknown}" in
            1) echo "Secure Boot                  : ATTIVO (il deploy chiedera' come procedere: vedi --secure-boot)" ;;
            0) echo "Secure Boot                  : disattivato" ;;
            *) echo "Secure Boot                  : non rilevabile" ;;
        esac
    fi
    echo "Gia' UniTotem                : ${P[HAVE_UNITOTEM]}"
    echo "DATA presente                : ${P[HAVE_DATA]}  (UUID: ${P[DATA_UUID]:-n/d})"
    echo "RAM disponibile               : $(bytes_human "${P[MEMAVAIL]}")"
    echo "Spazio libero su /            : $(bytes_human "${P[ROOTFREE]}")"
    echo "Rete verso l'host             : interfaccia ${P[NETIF]:-?} (${P[NETLINK]:-?}, ${P[NETMODE]:-?})"
    echo "Disco di avvio corrente       : ${P[ROOTDISK]:-?}"
    echo "Dischi rilevati:"
    local i=1 d
    for d in "${DISKS[@]}"; do
        IFS='|' read -r name size tran model byid <<< "$d"
        local tag=""
        [ "$name" = "${P[ROOTDISK]:-}" ] && tag="  <- disco di avvio corrente"
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
        [ -n "$chosen" ] || die "--disk $OPT_DISK non trovato tra i dischi rilevati (usa 'probe' per elencarli)"
    fi

    if [ -z "$chosen" ] && [ ${#DISKS[@]} -eq 1 ] && [ "$OPT_YES" = 1 ]; then
        chosen="${DISKS[0]}"
    fi

    if [ -z "$chosen" ] || { [ ${#DISKS[@]} -gt 1 ] && [ "$OPT_YES" != 1 ]; }; then
        print_probe
        if [ -n "$chosen" ]; then
            echo ""
            IFS='|' read -r name size tran model byid <<< "$chosen"
            read -rp "Confermi la scrittura su ${name} ($(bytes_human "$size"))? [scrivi SI]: " ans
            [ "$ans" = "SI" ] || die "annullato dall'utente"
        else
            echo ""
            local choice
            read -rp "Su quale disco scrivere l'immagine? [1-${#DISKS[@]}]: " choice
            [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#DISKS[@]} ] \
                || die "scelta non valida"
            chosen="${DISKS[$((choice - 1))]}"
        fi
    fi

    IFS='|' read -r TARGET_DISK_NAME TARGET_DISK_SIZE _ _ TARGET_DISK_BYID <<< "$chosen"
    [ "$TARGET_DISK_BYID" != none ] || die "nessun path stabile (by-id/by-path) per ${TARGET_DISK_NAME} - impossibile procedere in sicurezza"
    TARGET_DISK="$TARGET_DISK_NAME"

    if [ "$OPT_YES" != 1 ]; then
        echo ""
        echo "!!! Il disco ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE")) verra' interamente riscritto. !!!"
        read -rp "Digita 'SI' per procedere: " ans
        [ "$ans" = "SI" ] || die "annullato dall'utente"
    fi
}

# ---------------------------------------------------------------------------
# Legacy-target arming: push the resident recovery kernel+initrd and boot it
# via a one-shot entry (GRUB) or a config.txt swap (Pi) - verbatim from the
# pre-redesign remote-deploy.sh, only the pushed artifacts changed (recovery
# kernel/initrd instead of a dedicated flasher build).
# ---------------------------------------------------------------------------
push_recovery_kernel() {
    local vmlinuz="${DIR}/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"
    local initrd="${DIR}/deploy/${ARCH}/recovery-initrd-${ARCH}.img"
    [ -f "$vmlinuz" ] && [ -f "$initrd" ] \
        || die "recovery kernel/initrd mancanti per ${ARCH}: esegui prima ./build-kiosk.sh (produce anche lo stage 1b)"

    log "Copio kernel/initrd di fallback in ${P[BOOTMNT]}..."
    ssh_t "mount -o remount,rw '${P[BOOTMNT]}' 2>/dev/null; true"
    scp_root "$vmlinuz" "${P[BOOTMNT]}/unitotem-recovery-vmlinuz" \
        || die "copia del kernel di fallback fallita"
    scp_root "$initrd"  "${P[BOOTMNT]}/unitotem-recovery-initrd.img" \
        || die "copia dell'initrd di fallback fallita"
}

build_legacy_cmdline() {
    local console="$OPT_CONSOLE"
    if [ -z "$console" ]; then
        [ "$ARCH" = arm64 ] && console="tty1 console=ttyS0,115200" || console="tty0"
    fi
    # fbcon=font:TER16x32: the firmware framebuffer is often the monitor's native size (a 1080p screen with the 8x16 default font gets a 240x67
    # console of tiny text); the 16x32 terminus font doubles every glyph (ignored by a kernel that lacks it).
    echo "unitotem.ota=1 quiet loglevel=3 fbcon=font:TER16x32 console=${console}"
}

arm_grub() {
    local cmdline_b64; cmdline_b64=$(printf '%s' "$1" | base64 -w0)
    log "Aggiungo la voce GRUB one-shot 'UniTotem OTA'..."
    ssh_t bash -s -- "$cmdline_b64" <<'REMOTE_EOF'
set -eu
CMDLINE="$(printf '%s' "$1" | base64 -d)"
mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw /boot 2>/dev/null || true
# 99 (not e.g. 09): grub-mkconfig sorts /etc/grub.d/* alphabetically, so a
# lower number would make this menuentry index 0 - and on a stock
# GRUB_DEFAULT=0 config, grub-reboot's one-shot clears next_entry back to
# index 0 once consumed, which would then just be *this* entry again: an
# infinite boot loop instead of falling back to the real OS. Sorting last
# leaves index 0 as whatever it already was.
cat > /etc/grub.d/99_unitotem_flash << EOF
#!/bin/sh
exec tail -n +3 "\$0"
menuentry 'UniTotem OTA' {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    # low resolution for the OTA screens (readable from far away, same as kiosk/files/grub-ab-entries): GRUB sets a small firmware
    # framebuffer mode, gfxpayload=keep hands it to the kernel and nomodeset stops the DRM driver from switching to the native size
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
    echo "Ne' update-grub ne' grub-mkconfig trovati sul target" >&2
    exit 1
fi
grub-reboot 'UniTotem OTA'
REMOTE_EOF
}

arm_rpi() {
    local cmdline_b64; cmdline_b64=$(printf '%s' "$1" | base64 -w0)
    log "Preparo config.txt/cmdline.txt per il boot one-shot del fallback..."
    ssh_t bash -s -- "$cmdline_b64" "${P[BOOTMNT]}" <<'REMOTE_EOF'
set -eu
CMDLINE="$(printf '%s' "$1" | base64 -d)"
BOOTMNT="$2"
cd "$BOOTMNT"
[ -f config.txt.unitotem-bak ]  || cp -a config.txt  config.txt.unitotem-bak
[ -f cmdline.txt.unitotem-bak ] || cp -a cmdline.txt cmdline.txt.unitotem-bak
# enable_uart=1 is not optional here even though nothing in this file reads
# it: build_legacy_cmdline() pairs this config with console=ttyS0,115200,
# and on a Pi the mini-UART derives its baud from the VPU core clock, which
# only enable_uart=1 pins. Without it the serial console is silently dead -
# and this config.txt replaces the target's own wholesale, so whatever the
# previous OS had is gone. That matters precisely here: this is the legacy
# arming path onto a foreign OS, where the very next boot is into the
# fallback, and serial is the only diagnostic left if that boot misbehaves.
# Every config.txt writer in deploy/ota-engine.sh already sets it; this one
# was the outlier.
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
    log "Riavvio il target..."
    # systemd-run first: a reboot started as a background child of the ssh/sudo session was silently lost on a KDE neon desktop target
    # (the session was torn down first), the target stayed up and the whole deploy waited for a fallback that never came.
    ssh_t "sync; systemd-run --on-active=3s --no-block systemctl reboot >/dev/null 2>&1 || nohup reboot >/dev/null 2>&1 &" || true
}

# ---------------------------------------------------------------------------
# Wait for the OTA dropbear session to come up (legacy push) or for the
# already-armed target to answer it (prepared path - same wait, just no
# push/arm beforehand).
# ---------------------------------------------------------------------------
# The fallback gets its address by DHCP on whichever wired port has the cable, which is not necessarily the port (and address) the running
# system used - a two-NIC mini PC came up on a different address than the one this script was waiting on. After a minute without an answer
# the local subnet is scanned for a dropbear on port 2222: exactly one hit is taken as the fallback (OTA_FOUND_HOST), several are listed.
discover_fallback() {
    local src prefix h open=() ban
    src=$(ip -o route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$src" ] || return 1
    prefix="${src%.*}"
    log "Nessuna risposta all'indirizzo atteso: cerco il fallback (dropbear, porta 2222) nella rete ${prefix}.0/24..."
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
           if [ "$OTA_FOUND_HOST" = "$1" ]; then log "Fallback trovato a ${OTA_FOUND_HOST}."
           else log "Fallback trovato a ${OTA_FOUND_HOST} (indirizzo diverso da quello atteso: la scheda di rete con il cavo non e' quella del sistema precedente)."; fi
           return 0 ;;
        *) warn "piu' di un dropbear sulla porta 2222: ${open[*]}"; return 1 ;;
    esac
}

wait_ota_reachable() {
    local host="$1" waited=0 scanned=0
    OTA_FOUND_HOST=""; OTA_SCAN_FILE=$(mktemp)
    log "Attendo che ${host} risponda sulla sessione OTA (porta 2222, fino a 10 minuti)..."
    sleep 15
    while ! ota_ssh "$host" true 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        if [ "$waited" -ge 60 ] && [ "$scanned" -eq 0 ]; then
            scanned=1
            if discover_fallback "$host"; then host="$OTA_FOUND_HOST"; continue; fi
        fi
        [ "$waited" -lt 600 ] || { rm -f "$OTA_SCAN_FILE"; die "il target non e' entrato in modalita' OTA entro 10 minuti"; }
    done
    rm -f "$OTA_SCAN_FILE"
    [ -z "$OTA_FOUND_HOST" ] || log "Sessione OTA raggiunta su ${OTA_FOUND_HOST}."
}

# ---------------------------------------------------------------------------
# The actual two-stage sequence, driven entirely by ota-engine.sh
# subcommands over the OTA SSH session, once it is reachable. See the
# plan's "sequenza a due stage".
# ---------------------------------------------------------------------------
# populate-bootfs for the parts set's boot-partition tarball. One place, because A/B runs it in stage 1
# and every other layout in stage 2.
populate_bootfs_step() {
    local host="$1" disk="$2" bootfs_part="$3"
    local hostip="${P[SSHCLIENT]:-}"
    [ -n "$hostip" ] && [ "$hostip" != none ] || hostip=$(ip -o route get "${host}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$hostip" ] || die "impossibile determinare l'IP dell'host verso il target"
    local bootfs_tar; bootfs_tar=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")
    [ -n "$bootfs_tar" ] || return 0
    local pid; pid=$(serve_file_once "${OPT_PARTS}/${bootfs_tar}" "$OPT_PORT")
    wait_port_bound "$OPT_PORT" 10 || die "listener dati non pronto (bootfs)"
    local lay=""; [ "${P_LAYOUT:-1}" = 2 ] && lay="--layout ab"
    [ "$SB_MODE" = shim ] && lay="$lay --secure-boot shim"
    # shellcheck disable=SC2086
    ota_ssh "$host" "unitotem-ota-engine populate-bootfs --disk '${disk}' --bootfs-part '${bootfs_part}' --data-host '${hostip}' --data-port '${OPT_PORT}' ${lay}"
    wait "$pid" 2>/dev/null || true
}

run_ota_sequence() {
    local host="$1" disk_byid="$2"

    local recreate_table=0
    [ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && [ "$OPT_WIPE_DATA" != 1 ] || recreate_table=1

    log "Risolvo il disco sul target (probe engine)..."
    local probe_out
    probe_out=$(ota_ssh "$host" "unitotem-ota-engine probe --disk '${disk_byid}'")
    declare -A E
    while IFS= read -r line; do
        [ -n "$line" ] && E["${line%%=*}"]="${line#*=}"
    done <<< "$probe_out"
    local disk="${E[UNITOTEM_DISK]:-}"
    [ -n "$disk" ] || die "il target non risolve il disco richiesto"

    local bootfs_part="${P_BOOTFS_PART:-1}" data_part="${P_DATA_PART}"
    local firmware_grub="${FIRMWARE}"

    log "=== Stage 1: installazione del fallback ==="
    if [ "$recreate_table" = 1 ]; then
        log "Ripristino la tabella delle partizioni..."
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

    log "Copio il kernel/initrd di fallback sulla partizione di boot..."
    local recovery_name_vmlinuz recovery_name_initrd
    if [ "$ARCH" = arm64 ]; then
        recovery_name_vmlinuz=recovery8.img; recovery_name_initrd=recovery-initrd.img
    else
        recovery_name_vmlinuz=recovery-vmlinuz; recovery_name_initrd=recovery-initrd.img
    fi
    local subdir=""; [ "$ARCH" = amd64 ] && subdir="--subdir unitotem"
    # shellcheck disable=SC2086
    ota_ssh_send "$host" "unitotem-ota-engine write-bootfile --disk '${disk}' --bootfs-part '${bootfs_part}' --name ${recovery_name_vmlinuz} ${subdir}" \
        < "${DIR}/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"
    # shellcheck disable=SC2086
    ota_ssh_send "$host" "unitotem-ota-engine write-bootfile --disk '${disk}' --bootfs-part '${bootfs_part}' --name ${recovery_name_initrd} ${subdir}" \
        < "${DIR}/deploy/${ARCH}/recovery-initrd-${ARCH}.img"

    # A/B (amd64): the boot partition's file-level content carries GRUB itself and the grub.cfg whose
    # 'ota-recovery' entry set-default-recovery selects, so it has to be there BEFORE the default is
    # switched - and it must not be repeated in stage 2.
    local bootfs_populated=0
    if [ "${P_LAYOUT:-1}" = 2 ]; then
        populate_bootfs_step "$host" "$disk" "$bootfs_part" || die "popolamento della partizione di boot fallito"
        bootfs_populated=1
        ota_ssh "$host" "unitotem-ota-engine set-default-recovery --disk '${disk}' --firmware '${firmware_grub}' --bootfs-part '${bootfs_part}' --layout ab"
    else
        ota_ssh "$host" "unitotem-ota-engine set-default-recovery --disk '${disk}' --firmware '${firmware_grub}' --bootfs-part '${bootfs_part}'"
    fi
    log "Stage 1 completato: da qui ogni perdita di alimentazione riavvia sul fallback."

    log "=== Stage 2: immagine UniTotem ==="
    local hostip="${P[SSHCLIENT]:-}"
    [ -n "$hostip" ] && [ "$hostip" != none ] || hostip=$(ip -o route get "${host}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$hostip" ] || die "impossibile determinare l'IP dell'host verso il target"

    # Always populate the boot partition's file-level content (overlays/,
    # bootcode.bin, README etc.) - not just on recreate_table (first
    # provisioning). Found the hard way: real hardware kept an empty
    # /boot/firmware/overlays/ across every OTA update it had ever received,
    # since this whole block used to be recreate_table-gated - vc4/v3d
    # loaded as kernel modules regardless, but with no .dtbo to apply, no
    # DRM device was ever created (dtoverlay=vc4-kms-v3d in config.txt alone
    # is not enough - see the config-extra.txt fix above for why config.txt
    # itself needed a separate splice; this is the same class of gap for a
    # different file). Safe on an already-provisioned target: cmd_populate_bootfs
    # has its own exclude list protecting config.txt/cmdline.txt, the
    # recovery kernel/initrd Stage 1 just wrote, and every unitotem-ota.*
    # runtime state file.
    if [ "$bootfs_populated" != 1 ]; then
        log "Popolo il contenuto file-level della partizione di boot..."
        populate_bootfs_step "$host" "$disk" "$bootfs_part" || die "popolamento della partizione di boot fallito"
    fi

    local -A block
    local partnum label cloner action used stream comp
    # The manifest is fed on fd 9, not stdin, and read_kv_block is pointed at
    # it explicitly. Belt and braces with ota_ssh's -n: this loop runs ssh on
    # every iteration, and an ssh that inherits the loop's stdin eats the rest
    # of the manifest, silently dropping every partition after the first
    # restore. That exact failure shipped - a from-scratch deploy never
    # reached the DATA block, so DATA got a GPT name but no filesystem. Fixing
    # only ota_ssh would leave the same trap armed for the next command added
    # here; decoupling the manifest from stdin removes the whole class.
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
                log "Restore partizione ${partnum} (${label}, ${cloner})..."
                local pid; pid=$(serve_file_once "${OPT_PARTS}/${stream}" "$OPT_PORT")
                wait_port_bound "$OPT_PORT" 10 || die "listener dati non pronto (partizione ${partnum})"
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

    log "Monto il sistema appena ripristinato..."
    local mount_args="--disk '${disk}' --arch '${ARCH}' --root-part '${P_ROOT_PART}' --bootfs-part '${bootfs_part}' --data-part '${data_part}'"
    [ "$ARCH" = amd64 ] && [ -n "${P_BOOT_PART:-}" ] && mount_args="${mount_args} --boot-part '${P_BOOT_PART}'"
    # shellcheck disable=SC2086
    ota_ssh "$host" "unitotem-ota-engine mount-target ${mount_args}"

    if [ "$ARCH" = arm64 ] && [ "${P_LAYOUT:-1}" != 2 ]; then
        # (A/B images already carry their kernel, initramfs and dtbs in slota/ on the boot partition.)
        log "Popolo kernel/initrd/dtb del sistema reale sulla partizione di boot..."
        ota_ssh "$host" "unitotem-ota-engine populate-real-kernel"
    fi

    local slot_arg=""; [ "${P_LAYOUT:-1}" = 2 ] && slot_arg="--slot a"
    ota_ssh "$host" "unitotem-ota-engine migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data ${slot_arg}" || warn "migrazione /etc fallita (non fatale, il sistema nuovo usa comunque il proprio /etc)"

    # Carry the probed network settings onto the installed system. This is
    # what makes ADOPTION keep working: a foreign device's configuration
    # lives in the root filesystem being overwritten, so migrate-etc-overlay
    # (which only rescues what DATA already held) has nothing to restore for
    # it. Skips itself when a profile was migrated, and when the link is
    # wired DHCP and therefore needs no profile at all. Non-fatal: a target
    # that cannot be reconfigured is still better off booting.
    local net_args="${slot_arg} --data-mnt /mnt/newroot/mnt/data --link '${P[NETLINK]:-wired}' --mode '${P[NETMODE]:-dhcp}'"
    [ -n "${P[NETADDR]:-}" ]        && net_args="${net_args} --addr '${P[NETADDR]}'"
    [ -n "${P[NETGW]:-}" ]          && net_args="${net_args} --gw '${P[NETGW]}'"
    [ -n "${P[NETDNS]:-}" ]         && net_args="${net_args} --dns '${P[NETDNS]}'"
    [ -n "${P[WIFI_SSID_B64]:-}" ]  && net_args="${net_args} --ssid-b64 '${P[WIFI_SSID_B64]}'"
    [ -n "${P[WIFI_PSK_B64]:-}" ]   && net_args="${net_args} --psk-b64 '${P[WIFI_PSK_B64]}'"
    # shellcheck disable=SC2086
    ota_ssh "$host" "unitotem-ota-engine apply-network ${net_args}" \
        || warn "applicazione dei parametri di rete fallita (non fatale)"

    local trial_mode="$FIRMWARE"
    [ "$FIRMWARE" = rpi ] && trial_mode=$([ "$TRYBOOT_CAPABLE" = 1 ] && echo rpi-tryboot || echo rpi-legacy)
    if [ "$FIRMWARE" = rpi ] && [ "${P_LAYOUT:-1}" = 2 ]; then
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware '${trial_mode}' --disk '${disk}' --bootfs-part '${bootfs_part}' --target /mnt/newroot --layout ab"
    elif [ "$FIRMWARE" = rpi ]; then
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware '${trial_mode}' --disk '${disk}' --bootfs-part '${bootfs_part}'"
    elif [ "${P_LAYOUT:-1}" = 2 ]; then
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware '${trial_mode}' --target /mnt/newroot --layout ab"
    else
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware '${trial_mode}' --target /mnt/newroot"
    fi

    ota_ssh "$host" "unitotem-ota-engine umount-target" || true

    log "Riavvio in prova sul sistema reale..."
    # rpi-tryboot needs the literal argument "0 tryboot" passed through to
    # the kernel's reboot(2) syscall for the Pi's firmware to read
    # tryboot.txt on the next boot instead of config.txt (which still points
    # at the fallback by design, until promote-default runs) - a plain
    # reboot does not do this at all, it would just boot the fallback again.
    # rpi-legacy doesn't need it (config.txt was already swapped directly by
    # set-trial-boot above) and neither does uefi/bios (grub-reboot's
    # one-shot is picked up by any normal reboot). See kiosk/files/ota-hook
    # for why this needs the real systemd-provided reboot binary, not
    # BusyBox's (which doesn't support this argument at all), and why a
    # plain `reboot ARG` alone is not enough either - `-f` is what skips the
    # logind/D-Bus path this initrd has no way to satisfy (no systemd
    # running), verified empirically, not just from reading systemd's
    # source.
    if [ "$trial_mode" = rpi-tryboot ]; then
        ota_ssh "$host" "sync; reboot -f '0 tryboot'" 2>/dev/null || true
    else
        ota_ssh "$host" "sync; reboot -f" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
cmd_deploy() {
    do_probe
    select_disk

    OPT_PARTS="${OPT_PARTS:-$(ls -td "${DIR}/deploy/${ARCH}/"*.parts 2>/dev/null | head -1)}"
    [ -n "$OPT_PARTS" ] && [ -d "$OPT_PARTS" ] \
        || die "nessun parts set trovato per ${ARCH} (usa --parts o esegui prima deploy/make-parts.sh)"

    local min_disk; min_disk=$(awk -F= '/^UNITOTEM_MIN_DISK_BYTES=/{print $2}' "${OPT_PARTS}/parts.manifest")
    [ "$TARGET_DISK_SIZE" -ge "$min_disk" ] \
        || die "${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE")) e' piu' piccolo del minimo richiesto ($(bytes_human "$min_disk"))"

    P_DATA_PART=$(awk -F= '/^UNITOTEM_DATA_PART=/{print $2}' "${OPT_PARTS}/parts.manifest")
    P_BOOTFS_PART=$(awk -F= '/^UNITOTEM_BOOTFS_PART=/{print $2}' "${OPT_PARTS}/parts.manifest")
    # Partition number for a given label: scan blocks, remember the last
    # UNITOTEM_PART= seen, print it when the matching label line is hit.
    part_num_for_label() {
        awk -F= -v want="$1" '
            /^UNITOTEM_PART=/{n=$2}
            /^UNITOTEM_PART_LABEL=/{if($2==want){print n; exit}}
        ' "${OPT_PARTS}/parts.manifest"
    }
    P_LAYOUT=$(awk -F= '/^UNITOTEM_LAYOUT=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")
    P_LAYOUT="${P_LAYOUT:-1}"
    if [ "$P_LAYOUT" = 2 ]; then
        { [ "$ARCH" = amd64 ] && [ "$FIRMWARE" = uefi ]; } || { [ "$ARCH" = arm64 ] && [ "$FIRMWARE" = rpi ] && [ "$TRYBOOT_CAPABLE" = 1 ]; } \
            || die "il layout A/B e' implementato per amd64/UEFI e per Raspberry con tryboot (target: ${ARCH}/${FIRMWARE}, tryboot=${TRYBOOT_CAPABLE:-0}); BIOS legacy e Raspberry senza tryboot non ancora"
        P_ROOT_PART=$(part_num_for_label ROOT_A)
    else
        P_ROOT_PART=$(part_num_for_label ROOT)
    fi
    P_BOOT_PART=$(part_num_for_label BOOT)
    P_BOOTFS_VOLID=$(awk -F= '/^UNITOTEM_PART_VOLID=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")

    echo ""
    echo "Parts set   : $(basename "$OPT_PARTS")"
    echo "Disco target: ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE"))"
    echo "Target      : $([ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && echo 'gia'\'' UniTotem (percorso preparato)' || echo 'sistema legacy (push del fallback)')"

    secure_boot_gate
    changes_gate

    if [ "$OPT_YES" != 1 ]; then
        read -rp "Procedo con il deploy? [scrivi SI]: " ans
        [ "$ans" = "SI" ] || die "annullato dall'utente"
    fi

    local target_ip="${TARGET_USERHOST##*@}"

    if [ "${P[HAVE_UNITOTEM]:-0}" = 1 ]; then
        log "Armo l'OTA dal sistema in esecuzione..."
        local wipe_arg=""; [ "$OPT_WIPE_DATA" = 1 ] && wipe_arg="--wipe-data"
        # shellcheck disable=SC2086
        # Not `|| die`: this command's job is to reboot the target, so ssh's
        # exit status is a race, not a result. The reboot tears sshd down and
        # the session dies with it ("Connection closed by remote host"), which
        # ssh reports as failure even though the arming succeeded - observed
        # every single time on real hardware, and worked around by hand each
        # time. The actual verdict is wait_ota_reachable below: if arming
        # really failed, the target simply stays up and the fallback never
        # appears, which that call reports clearly. The target-side script
        # also defers its reboot now (see kiosk/files/unitotem-ota-arm), but
        # this stays tolerant regardless - a target still running an older
        # image has the old script, and the race is timing-dependent anyway.
        ssh_t "unitotem-ota-arm --port 2222 ${wipe_arg}" \
            || warn "sessione SSH chiusa durante l'arming (atteso: il target si sta riavviando) - verifico la comparsa del fallback"
    else
        push_recovery_kernel
        if [ "$FIRMWARE" = rpi ]; then
            arm_rpi "$(build_legacy_cmdline)"
        else
            [ "${P[GRUB_REBOOT]}" = 1 ] || die "grub-reboot non trovato sul target: impossibile armare una voce one-shot"
            arm_grub "$(build_legacy_cmdline)"
        fi
        do_reboot
    fi

    wait_ota_reachable "$target_ip"
    target_ip="${OTA_FOUND_HOST:-$target_ip}"
    if [ "$OPT_FALLBACK_ONLY" = 1 ]; then
        log "Fallback pronto a ${target_ip}:2222. Nessuna scrittura sul disco (--fallback-only)."
        return 0
    fi
    run_ota_sequence "$target_ip" "$TARGET_DISK_BYID"

    if [ "$SB_MODE" = noshim ]; then
        echo ""
        echo "=============================================================="
        echo " INSTALLAZIONE COMPLETATA, MA IL SISTEMA NON PARTIRA' DA SOLO"
        echo "=============================================================="
        echo " Secure Boot e' attivo e hai scelto di installare senza shim: al riavvio il firmware mostra 'Security Violation'."
        echo " Serve un INTERVENTO FISICO: entra nel setup del firmware e disattiva Secure Boot, poi riavvia."
        echo "=============================================================="
        return 0
    fi

    # The account to check afterwards is root@, NOT whatever we logged in as:
    # the machine that comes back is the freshly deployed UniTotem, whose only
    # known account is root. The user we armed from (a stock "pi", say) exists
    # on the OS that was just replaced and is gone. The askpass helper written
    # for that old user is gone with it, so escalation state is dropped too.
    local post="root@${target_ip}"
    clear_target_privilege
    TARGET_USERHOST="$post"; TARGET_SUDO=""; TARGET_PRIV_READY=1

    log "Sequenza OTA inviata. Attendo che ${post} torni raggiungibile sul sistema reale (fino a 10 minuti)..."
    local waited=0
    sleep 30
    while ! OTA_PASSWORD="$OTA_FALLBACK_PASSWORD" _sshpass ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${post}" true 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        [ "$waited" -lt 600 ] || { warn "il target non e' tornato raggiungibile entro 10 minuti - verificare manualmente (potrebbe essere ancora in stage 2, o nel fallback in attesa)"; return 0; }
    done

    if OTA_PASSWORD="$OTA_FALLBACK_PASSWORD" _sshpass ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${post}" "[ -d /etc/kiosk ]" 2>/dev/null; then
        log "Deploy completato: ${post} e' raggiungibile sul nuovo sistema."
    else
        warn "${post} e' raggiungibile ma non sembra il sistema nuovo - potrebbe essere ancora il fallback in attesa di comandi."
        return 1
    fi
}

# ---------------------------------------------------------------------------
cmd_recover() {
    local host="${RECOVER_HOSTPORT%%:*}"
    do_probe_skip=1
    log "Mi collego al target in fallback (${host})..."
    ota_ssh "$host" true || die "impossibile raggiungere ${host} sulla sessione OTA"
    die "recover: specifica manualmente --disk e usa deploy/ota-engine.sh via ota_ssh per una sessione di recupero guidata (percorso avanzato, non ancora automatizzato end-to-end)"
}

cmd_serve() {
    log "In ascolto per un target che richiama casa (reverse tunnel dropbear, porta 2222)..."
    log "Nessuna azione automatica ulteriore: usa 'ssh -p 2222 root@localhost' una volta stabilito il tunnel."
    while :; do sleep 3600; done
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# What has been changed on the target since its image was built.
#
# An OTA replaces ROOT wholesale, so anything installed or edited on the
# running system is destroyed by it. Saying so beforehand is the difference
# between an update and a surprise. The heavy lifting is on the target
# (/usr/sbin/unitotem-ota-changes, which needs dpkg and so cannot live in the
# fallback's ota-engine.sh); this side only presents it and gates on it.
# ---------------------------------------------------------------------------

# exit 0 = nothing changed, 1 = changes found, 2 = the check itself failed.
# Anything else means the target has no such command, which is the normal
# state of a device whose image predates it - not an error worth blocking a
# deploy over.
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
        127) die "il target non ha unitotem-ota-changes (immagine anteriore a questa funzione)" ;;
        *)   die "controllo delle modifiche fallito sul target: ${CHANGES_OUT}" ;;
    esac
    return "$CHANGES_RC"
}

# Secure Boot (amd64/UEFI). The firmware refuses to run anything not signed by a key it trusts. UniTotem's own GRUB is unsigned, so
# there are two ways in and the operator must pick one explicitly: boot through Debian's Microsoft-signed shim (the chain is staged in
# the image and activated by populate-bootfs --secure-boot shim), or install as-is and fix the firmware afterwards. The choice is
# never made silently, because both can need someone standing at the machine.
secure_boot_gate() {
    [ "$ARCH" = amd64 ] && [ "$FIRMWARE" = uefi ] || return 0
    case "${P[SECUREBOOT]:-unknown}" in
        0) [ -z "$OPT_SECURE_BOOT" ] || warn "--secure-boot ${OPT_SECURE_BOOT}: ignorato, Secure Boot non e' attivo sul target"; return 0 ;;
        1) ;;
        *) warn "stato di Secure Boot non rilevabile sul target: procedo come se fosse disattivato (se e' attivo, il sistema installato non partira')"; return 0 ;;
    esac

    # An UniTotem already running with Secure Boot on is booting through some trusted path: keep the shim chain.
    # (only with an A/B parts set: the shim chain is staged only in those images; with another layout fall through to the choice)
    if [ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && [ "${P_LAYOUT:-1}" = 2 ] && [ -z "$OPT_SECURE_BOOT" ]; then
        log "Secure Boot attivo e il target e' gia' UniTotem: mantengo la catena shim"
        SB_MODE=shim; return 0
    fi

    if [ -z "$OPT_SECURE_BOOT" ]; then
        [ "$OPT_YES" != 1 ] \
            || die "Secure Boot e' ATTIVO sul target: scegli esplicitamente --secure-boot shim | noshim (oppure disattivalo nel firmware e rilancia)"
        echo ""
        echo "=============================================================="
        echo " SECURE BOOT e' ATTIVO sul target"
        echo "=============================================================="
        echo " Il firmware accetta solo programmi di avvio firmati con una chiave che conosce."
        echo " Il GRUB di UniTotem non e' firmato. Come procedo?"
        echo ""
        echo "  1) INSTALLA CON SHIM"
        echo "     L'avvio passa da shim (firmato Microsoft) -> GRUB e kernel firmati Debian: parte senza toccare il firmware."
        echo "     ATTENZIONE, puo' servire un INTERVENTO FISICO sulla macchina:"
        echo "       - con una GPU NVIDIA il driver proprietario e' un modulo non firmato: va registrata una chiave (MOK)"
        echo "         dalla console al primo avvio, altrimenti niente driver video accelerato;"
        echo "       - se il firmware non si fida della CA Microsoft UEFI (Secure Boot personalizzato) shim e' rifiutato."
        echo "     Se il sistema attuale non e' Debian, il primo passaggio (voce GRUB una tantum) puo' fallire: il suo shim"
        echo "     rifiuta il kernel Debian (\"bad shim signature\") e la macchina si ferma al prompt di GRUB."
        echo ""
        echo "  2) INSTALLA SENZA SHIM"
        echo "     L'installazione termina, ma al riavvio il firmware rifiutera' il GRUB non firmato (\"Security Violation\")."
        echo "     Un INTERVENTO FISICO e' NECESSARIO per forza: disattivare Secure Boot dal firmware (o registrarne l'hash)."
        echo ""
        echo "  3) ANNULLA"
        echo "     Non viene toccato nulla. Disattiva Secure Boot nel firmware e rilancia il deploy."
        echo "=============================================================="
        local c
        read -rp "Scelta [1/2/3]: " c
        case "$c" in 1) OPT_SECURE_BOOT=shim ;; 2) OPT_SECURE_BOOT=noshim ;; *) OPT_SECURE_BOOT=abort ;; esac
    fi

    case "$OPT_SECURE_BOOT" in
        abort)  die "annullato: Secure Boot e' attivo sul target. Disattivalo nel firmware (o scegli --secure-boot shim|noshim) e rilancia" ;;
        shim)
            [ "${P_LAYOUT:-1}" = 2 ] || die "la catena shim e' staged solo nelle immagini A/B: questo parts set non la contiene (usa un'immagine A/B o --secure-boot noshim)"
            SB_MODE=shim
            warn "Secure Boot: installo con shim. Se il target ha una GPU NVIDIA servira' registrare la chiave MOK dalla console (intervento fisico)."
            ;;
        noshim)
            SB_MODE=noshim
            warn "Secure Boot: installo SENZA shim. Al riavvio il firmware mostrera' 'Security Violation': serve un intervento fisico (disattivare Secure Boot)."
            ;;
    esac
}

changes_gate() {
    # A foreign device being adopted has no baseline to compare against, and
    # nothing on it is being preserved anyway - the whole disk is going.
    if [ "${P[HAVE_UNITOTEM]:-0}" != 1 ]; then
        return 0
    fi

    log "Controllo le modifiche fatte sul target dall'installazione..."
    run_changes_check

    if [ "$CHANGES_RC" = 127 ]; then
        # Expected on the first deploy that installs the tool: the image
        # running right now was built before it existed.
        warn "il target non espone unitotem-ota-changes: impossibile dire cosa verra' sovrascritto"
        return 0
    fi
    if [ "$CHANGES_RC" -gt 1 ]; then
        warn "controllo delle modifiche non riuscito (${CHANGES_OUT}) - proseguo senza"
        return 0
    fi
    if [ "$CHANGES_RC" = 0 ]; then
        log "Nessuna modifica rispetto all'immagine installata."
        return 0
    fi

    local verdict digest
    verdict=$(printf '%s\n' "$CHANGES_OUT" | awk '/^Esito:/{print $2; exit}')
    digest=$(printf '%s\n' "$CHANGES_OUT" | awk '/^Digest:/{print $2; exit}')

    echo ""
    echo "=============================================================="
    echo " Il deploy sostituisce ROOT: quanto segue andrebbe PERDUTO."
    echo "=============================================================="
    printf '%s\n' "$CHANGES_OUT"
    echo "=============================================================="

    # A digest supplied by the caller must still describe what is on the
    # device *now*. If someone installed a package between the moment the
    # operator looked at the list and the moment they confirmed, this is what
    # stops the deploy from silently destroying something nobody was shown.
    if [ -n "$OPT_ACCEPT_CHANGES" ]; then
        if [ "$OPT_ACCEPT_CHANGES" = "$digest" ]; then
            log "Modifiche accettate (digest corrispondente)."
            return 0
        fi
        die "il digest fornito non corrisponde alle modifiche attuali (atteso ${digest}) - il sistema e' cambiato da quando e' stato mostrato"
    fi

    if [ "$OPT_YES" = 1 ]; then
        warn "--yes: procedo sovrascrivendo le modifiche elencate sopra (esito: ${verdict})"
        return 0
    fi

    local ans
    case "$verdict" in
        packages-only) read -rp "Sono solo pacchetti installati. Procedo e li perdo? [scrivi SI]: " ans ;;
        *)             read -rp "Ci sono anche file modificati NON spiegati da pacchetti. Procedo? [scrivi SI]: " ans ;;
    esac
    [ "$ans" = "SI" ] || die "annullato dall'utente"
}

cmd_disarm() {
    do_probe
    log "Rimuovo l'arming su ${TARGET_USERHOST} (${FIRMWARE})..."
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
    log "Disarmato. Il target riavviera' normalmente."
}

case "$SUBCMD" in
    probe)   do_probe; print_probe ;;
    changes) cmd_changes ;;
    deploy)  cmd_deploy ;;
    disarm)  cmd_disarm ;;
    recover) cmd_recover ;;
    serve)   cmd_serve ;;
esac
