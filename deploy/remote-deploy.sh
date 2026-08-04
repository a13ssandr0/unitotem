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
#   ./deploy/remote-deploy.sh deploy  root@host [--parts DIR] [--disk BYID]
#                                     [--port N] [--wipe-data]
#                                     [--console STR] [--debug] [--yes]
#   ./deploy/remote-deploy.sh disarm  root@host
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
    probe|deploy|disarm)
        TARGET_USERHOST="${1:-}"; shift || true
        [ -n "$TARGET_USERHOST" ] || { echo "Uso: $0 $SUBCMD user@host [opzioni]" >&2; exit 1; }
        ;;
    recover)
        RECOVER_HOSTPORT="${1:-}"; shift || true
        [ -n "$RECOVER_HOSTPORT" ] || { echo "Uso: $0 recover HOST[:PORT] [opzioni]" >&2; exit 1; }
        ;;
    serve) ;;
    *) echo "Uso: $0 {probe|deploy|disarm|recover|serve} ... [opzioni]" >&2; exit 1 ;;
esac

OPT_PARTS="" OPT_DISK="" OPT_PORT="9700" OPT_WIPE_DATA=0
# Empty by default rather than a fixed "tty0": build_legacy_cmdline() picks
# an arch-appropriate console when this is unset (tty0 for amd64, tty1 +
# serial for arm64 - matching every other cmdline.txt this project writes),
# and still honors an explicit --console override when one is given.
OPT_CONSOLE="" OPT_DEBUG=0 OPT_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --parts)      OPT_PARTS="$2"; shift 2 ;;
        --disk)       OPT_DISK="$2"; shift 2 ;;
        --port)       OPT_PORT="$2"; shift 2 ;;
        --wipe-data)  OPT_WIPE_DATA=1; shift ;;
        --console)    OPT_CONSOLE="$2"; shift 2 ;;
        --debug)      OPT_DEBUG=1; shift ;;
        --yes)        OPT_YES=1; shift ;;
        *) die "Opzione sconosciuta: $1" ;;
    esac
done

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
        [ "$ARCH" = arm64 ] && console="tty1 console=ttyS1,115200" || console="tty0"
    fi
    echo "unitotem.ota=1 console=${console}"
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
    linux /unitotem-recovery-vmlinuz ${CMDLINE}
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
# it: build_legacy_cmdline() pairs this config with console=ttyS1,115200,
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
    ssh_t "sync; nohup reboot >/dev/null 2>&1 &" || true
}

# ---------------------------------------------------------------------------
# Wait for the OTA dropbear session to come up (legacy push) or for the
# already-armed target to answer it (prepared path - same wait, just no
# push/arm beforehand).
# ---------------------------------------------------------------------------
wait_ota_reachable() {
    local host="$1" waited=0
    log "Attendo che ${host} risponda sulla sessione OTA (porta 2222, fino a 10 minuti)..."
    sleep 15
    while ! ota_ssh "$host" true 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        [ "$waited" -lt 600 ] || die "il target non e' entrato in modalita' OTA entro 10 minuti"
    done
}

# ---------------------------------------------------------------------------
# The actual two-stage sequence, driven entirely by ota-engine.sh
# subcommands over the OTA SSH session, once it is reachable. See the
# plan's "sequenza a due stage".
# ---------------------------------------------------------------------------
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
        ota_ssh "$host" "unitotem-ota-engine prepare-bootfs --disk '${disk}' --bootfs-part '${bootfs_part}' --fstype vfat --fresh 1 --label ${bootfs_label}"
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

    ota_ssh "$host" "unitotem-ota-engine set-default-recovery --disk '${disk}' --firmware '${firmware_grub}' --bootfs-part '${bootfs_part}'"
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
    log "Popolo il contenuto file-level della partizione di boot..."
    local bootfs_tar; bootfs_tar=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "${OPT_PARTS}/parts.manifest")
    if [ -n "$bootfs_tar" ]; then
        local pid; pid=$(serve_file_once "${OPT_PARTS}/${bootfs_tar}" "$OPT_PORT")
        wait_port_bound "$OPT_PORT" 10 || die "listener dati non pronto (bootfs)"
        ota_ssh "$host" "unitotem-ota-engine populate-bootfs --disk '${disk}' --bootfs-part '${bootfs_part}' --data-host '${hostip}' --data-port '${OPT_PORT}'"
        wait "$pid" 2>/dev/null || true
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

    if [ "$ARCH" = arm64 ]; then
        log "Popolo kernel/initrd/dtb del sistema reale sulla partizione di boot..."
        ota_ssh "$host" "unitotem-ota-engine populate-real-kernel"
    fi

    ota_ssh "$host" "unitotem-ota-engine migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data" || warn "migrazione /etc fallita (non fatale, il sistema nuovo usa comunque il proprio /etc)"

    local trial_mode="$FIRMWARE"
    [ "$FIRMWARE" = rpi ] && trial_mode=$([ "$TRYBOOT_CAPABLE" = 1 ] && echo rpi-tryboot || echo rpi-legacy)
    if [ "$FIRMWARE" = rpi ]; then
        ota_ssh "$host" "unitotem-ota-engine set-trial-boot --firmware '${trial_mode}' --disk '${disk}' --bootfs-part '${bootfs_part}'"
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
    P_ROOT_PART=$(part_num_for_label ROOT)
    P_BOOT_PART=$(part_num_for_label BOOT)

    echo ""
    echo "Parts set   : $(basename "$OPT_PARTS")"
    echo "Disco target: ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE"))"
    echo "Target      : $([ "${P[HAVE_UNITOTEM]:-0}" = 1 ] && echo 'gia'\'' UniTotem (percorso preparato)' || echo 'sistema legacy (push del fallback)')"
    if [ "$OPT_YES" != 1 ]; then
        read -rp "Procedo con il deploy? [scrivi SI]: " ans
        [ "$ans" = "SI" ] || die "annullato dall'utente"
    fi

    local target_ip="${TARGET_USERHOST##*@}"

    if [ "${P[HAVE_UNITOTEM]:-0}" = 1 ]; then
        log "Armo l'OTA dal sistema in esecuzione..."
        local wipe_arg=""; [ "$OPT_WIPE_DATA" = 1 ] && wipe_arg="--wipe-data"
        # shellcheck disable=SC2086
        ssh_t "unitotem-ota-arm --port 2222 ${wipe_arg}" || die "unitotem-ota-arm fallito sul target"
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
    run_ota_sequence "$target_ip" "$TARGET_DISK_BYID"

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
    while ! _sshpass ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${post}" true 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        [ "$waited" -lt 600 ] || { warn "il target non e' tornato raggiungibile entro 10 minuti - verificare manualmente (potrebbe essere ancora in stage 2, o nel fallback in attesa)"; return 0; }
    done

    if _sshpass ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${post}" "[ -d /etc/kiosk ]" 2>/dev/null; then
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
    deploy)  cmd_deploy ;;
    disarm)  cmd_disarm ;;
    recover) cmd_recover ;;
    serve)   cmd_serve ;;
esac
