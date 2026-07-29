#!/bin/bash
# Remote deploy of a UniTotem kiosk disk image onto a machine currently
# running an old UniTotem/Debian install, reachable only over SSH.
#
# Usage:
#   ./deploy/remote-deploy.sh probe   root@host
#   ./deploy/remote-deploy.sh deploy  root@host [--image PATH] [--disk BYID]
#                                     [--mode auto|ram|part|net] [--port N]
#                                     [--connect-back] [--console STR]
#                                     [--no-expand] [--debug] [--yes]
#   ./deploy/remote-deploy.sh disarm  root@host
#
# See ~/.claude/plans/prepara-uno-script-che-fluttering-koala.md
# (or debian-kiosk.md's "Deploy remoto" section) for the full design: the
# target is rebooted into a dedicated flasher kernel+initrd
# (deploy/build-flasher.sh) via a one-shot boot entry; the actual flashing
# happens in deploy/flasher/unitotem-flash before the old root is ever
# mounted, so it's safe to dd the disk it just booted from.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${DIR}/deploy/lib.sh"

require_cmd ssh scp sha256sum xz stat awk sed grep nc timeout ip base64

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
SUBCMD="${1:-}"; shift || true
TARGET_USERHOST="${1:-}"; shift || true
[ -n "$SUBCMD" ] && [ -n "$TARGET_USERHOST" ] || {
    echo "Uso: $0 {probe|deploy|disarm} user@host [opzioni]" >&2
    exit 1
}

OPT_IMAGE="" OPT_DISK="" OPT_MODE="auto" OPT_PORT="9700" OPT_CONNECT_BACK=0
OPT_CONSOLE="tty0" OPT_EXPAND=1 OPT_DEBUG=0 OPT_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image)        OPT_IMAGE="$2"; shift 2 ;;
        --disk)         OPT_DISK="$2"; shift 2 ;;
        --mode)         OPT_MODE="$2"; shift 2 ;;
        --port)         OPT_PORT="$2"; shift 2 ;;
        --connect-back) OPT_CONNECT_BACK=1; shift ;;
        --console)      OPT_CONSOLE="$2"; shift 2 ;;
        --no-expand)    OPT_EXPAND=0; shift ;;
        --debug)        OPT_DEBUG=1; shift ;;
        --yes)          OPT_YES=1; shift ;;
        *) die "Opzione sconosciuta: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Probe: one SSH round-trip, parseable KEY: value / DISK: ... lines.
# ---------------------------------------------------------------------------
declare -A P
DISKS=()

do_probe() {
    log "Interrogo ${TARGET_USERHOST}..."
    local out
    out=$(ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" bash -s <<'REMOTE_EOF'
set -u
echo "UNAME_M: $(uname -m)"
[ -d /sys/firmware/efi ] && echo "EFI: 1" || echo "EFI: 0"
MODEL=""
[ -r /proc/device-tree/model ] && MODEL=$(tr -d '\0' < /proc/device-tree/model)
echo "MODEL: ${MODEL:-none}"
command -v grub-reboot >/dev/null 2>&1 && echo "GRUB_REBOOT: 1" || echo "GRUB_REBOOT: 0"
command -v update-grub >/dev/null 2>&1 && echo "UPDATE_GRUB: 1" || echo "UPDATE_GRUB: 0"

ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null || true)
echo "ROOTSRC: ${ROOTSRC:-none}"
echo "ROOTPUUID: $(blkid -s PARTUUID -o value "$ROOTSRC" 2>/dev/null || echo none)"
pk=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null || true)
echo "ROOTDISK: ${pk:+/dev/$pk}"
echo "ROOTSIZE: $(lsblk -bno SIZE "$ROOTSRC" 2>/dev/null || echo 0)"

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

while read -r name size type tran model; do
    [ "$type" = "disk" ] || continue
    case "$name" in /dev/loop*|/dev/sr*|/dev/ram*|/dev/zram*|/dev/fd*) continue ;; esac
    bid=none
    # by-id first (has a serial/WWN, survives PCI slot/bus renumbering) -
    # many virtio-blk disks (typical in test VMs, but seen on some real
    # controllers too) don't get one at all, since udev only creates it
    # when the device exposes a serial number; by-path (encodes the PCI/
    # bus topology) is available for virtually every block device, so it's
    # the fallback rather than falling back to the unstable /dev/vdX name.
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
        # We only ever build/deploy an arm64 image - even a Pi that's
        # currently running a 32-bit (armhf) old UniTotem install needs
        # 64-bit-capable hardware for the new one. Heuristic on the
        # device-tree model string (Pi 3/4/5 and Zero 2 W are BCM2837/2711/
        # 2712, all 64-bit capable; plain Pi 1/2/Zero/Zero W are not) -
        # good enough to catch the common case, not exhaustive over every
        # revision string.
        echo "${P[MODEL]}" | grep -qiE "raspberry pi (3|4|5|.*zero 2)" \
            || die "modello rilevato (${P[MODEL]}) non risulta a 64-bit: l'immagine deployata è sempre arm64, non installabile qui"
        ARCH=arm64; FIRMWARE=rpi
    elif [ "${P[EFI]}" = 1 ]; then
        ARCH=amd64; FIRMWARE=uefi
    else
        ARCH=amd64; FIRMWARE=bios
    fi
}

print_probe() {
    echo "Architettura target immagine : ${ARCH}  (${P[UNAME_M]}, modello: ${P[MODEL]})"
    echo "Firmware                     : ${FIRMWARE}"
    echo "RAM disponibile               : $(bytes_human "${P[MEMAVAIL]}")"
    echo "Spazio libero su /            : $(bytes_human "${P[ROOTFREE]}")"
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
# Disk selection: always confirmed interactively unless --disk was given and
# --yes is set. Never assumes the boot disk is the target.
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
        echo "!!! Il disco ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE")) verrà interamente cancellato. !!!"
        read -rp "Digita 'SI' per procedere: " ans
        [ "$ans" = "SI" ] || die "annullato dall'utente"
    fi
}

# ---------------------------------------------------------------------------
# Mode selection
# ---------------------------------------------------------------------------
decide_mode() {
    local comp_size=$1
    if [ "$OPT_MODE" != auto ]; then echo "$OPT_MODE"; return; fi

    if [ "${P[ROOTDISK]:-}" != "$TARGET_DISK" ]; then
        echo ram; return
    fi
    if [ "${P[MEMAVAIL]:-0}" -ge $((comp_size + 512 * 1024 * 1024)) ]; then
        echo ram; return
    fi
    if [ "${P[ROOTFREE]:-0}" -ge $((comp_size + 512 * 1024 * 1024)) ]; then
        echo part; return
    fi
    local rootsize=${P[ROOTSIZE]:-0} rootfree=${P[ROOTFREE]:-0}
    local rootused=$((rootsize - rootfree))
    local shrunk_headroom=$((rootsize - (rootused * 12 / 10 + 200 * 1024 * 1024)))
    if [ "$shrunk_headroom" -ge $((comp_size + 128 * 1024 * 1024)) ]; then
        echo part; return
    fi
    echo net
}

# ---------------------------------------------------------------------------
# Boot-entry arming
# ---------------------------------------------------------------------------
build_flash_cmdline() {
    local mode=$1
    local args="unitotem.flash=1 unitotem.mode=${mode} unitotem.disk=${TARGET_DISK_BYID} unitotem.firmware=${FIRMWARE} unitotem.expand=${OPT_EXPAND} console=${OPT_CONSOLE}"
    [ "$OPT_DEBUG" = 1 ] && args="${args} unitotem.debug=1"

    if [ "$FIRMWARE" = rpi ]; then
        args="${args} unitotem.bootdisk=${BOOT_DISK_BYID} unitotem.bootpart=${P[BOOTPARTNUM]}"
    fi

    case "$mode" in
        ram|part)
            args="${args} unitotem.srcpart=/dev/disk/by-partuuid/${P[ROOTPUUID]} unitotem.srcdir=/unitotem-deploy"
            ;;
        net)
            local netmode; [ "$OPT_CONNECT_BACK" = 1 ] && netmode=connect || netmode=listen
            args="${args} unitotem.netmode=${netmode} unitotem.netport=${OPT_PORT} unitotem.netcfg=dhcp"
            [ "$netmode" = connect ] && args="${args} unitotem.netaddr=${HOST_IP}"
            ;;
    esac
    echo "$args"
}

push_flasher_kernel() {
    local vmlinuz="${DIR}/deploy/${ARCH}/flash-vmlinuz-${ARCH}"
    local initrd="${DIR}/deploy/${ARCH}/flash-initrd-${ARCH}.img"
    [ -f "$vmlinuz" ] && [ -f "$initrd" ] \
        || die "flasher mancante per ${ARCH}: esegui prima ./deploy/build-flasher.sh"

    log "Copio kernel/initrd del flasher in ${P[BOOTMNT]}..."
    ssh_t "mount -o remount,rw '${P[BOOTMNT]}' 2>/dev/null; true"
    scp_t "$vmlinuz" "${TARGET_USERHOST}:${P[BOOTMNT]}/unitotem-flash-vmlinuz"
    scp_t "$initrd"  "${TARGET_USERHOST}:${P[BOOTMNT]}/unitotem-flash-initrd.img"
}

push_deploy_payload() {
    local image=$1 manifest=$2
    log "Copio l'immagine sul target (/unitotem-deploy)..."
    ssh_t "mkdir -p /unitotem-deploy"
    scp_t "$manifest" "${TARGET_USERHOST}:/unitotem-deploy/unitotem-deploy.manifest"
    scp_t "$image"    "${TARGET_USERHOST}:/unitotem-deploy/$(basename "$image")"
}

arm_grub() {
    # ssh flattens all remote-command argv entries into one space-joined
    # string that the remote shell re-splits on whitespace - $cmdline itself
    # is many space-separated unitotem.* tokens, so it can't be passed as a
    # plain argument without being torn apart. base64 it instead: the
    # encoded form has no whitespace, so the join-then-resplit round-trip is
    # lossless.
    local cmdline_b64; cmdline_b64=$(printf '%s' "$1" | base64 -w0)
    log "Aggiungo la voce GRUB one-shot 'UniTotem Flash'..."
    ssh_t bash -s -- "$cmdline_b64" <<'REMOTE_EOF'
set -eu
CMDLINE="$(printf '%s' "$1" | base64 -d)"
mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw /boot 2>/dev/null || true
# 99 (not e.g. 09): grub-mkconfig sorts /etc/grub.d/* alphabetically, so a
# lower number would make this menuentry index 0 - and on a stock
# GRUB_DEFAULT=0 config (the common case, not "saved"), grub-reboot's
# one-shot clears next_entry back to index 0 once consumed, which would
# then just be *this* entry again: an infinite flash-boot loop instead of
# falling back to the real OS. Sorting last leaves index 0 as whatever it
# already was.
cat > /etc/grub.d/99_unitotem_flash << EOF
#!/bin/sh
exec tail -n +3 "\$0"
# UniTotem: voce one-shot generata da deploy/remote-deploy.sh - rimossa da
# 'disarm' o dopo un flash riuscito (che sovrascrive comunque il disco).
menuentry 'UniTotem Flash' {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    linux /unitotem-flash-vmlinuz ${CMDLINE}
    initrd /unitotem-flash-initrd.img
}
EOF
chmod +x /etc/grub.d/99_unitotem_flash
if command -v update-grub >/dev/null 2>&1; then
    update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "Né update-grub né grub-mkconfig trovati sul target" >&2
    exit 1
fi
grub-reboot 'UniTotem Flash'
REMOTE_EOF
}

arm_rpi() {
    # See arm_grub() for why this goes through base64 (ssh re-splits
    # multi-word arguments on the remote side).
    local cmdline_b64; cmdline_b64=$(printf '%s' "$1" | base64 -w0)
    log "Preparo config.txt/cmdline.txt per il boot one-shot del flasher..."
    ssh_t bash -s -- "$cmdline_b64" "${P[BOOTMNT]}" <<'REMOTE_EOF'
set -eu
CMDLINE="$(printf '%s' "$1" | base64 -d)"
BOOTMNT="$2"
cd "$BOOTMNT"
[ -f config.txt.unitotem-bak ]  || cp -a config.txt  config.txt.unitotem-bak
[ -f cmdline.txt.unitotem-bak ] || cp -a cmdline.txt cmdline.txt.unitotem-bak
cat > config.txt << EOF
# UniTotem flash boot (one-shot) - vedi config.txt.unitotem-bak per l'originale
arm_64bit=1
kernel=unitotem-flash-vmlinuz
initramfs unitotem-flash-initrd.img followkernel
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
# Net-mode sender (host side)
# ---------------------------------------------------------------------------
net_send() {
    # -q1: close the connection ~1s after stdin EOFs. Without it some nc
    # variants sit forever after sending everything, waiting on the
    # (receive-only, silent) other end to close first.
    local manifest=$1 image=$2 host=$3 port=$4
    if [ "$OPT_CONNECT_BACK" = 1 ]; then
        log "In attesa che il target si connetta (porta ${port})..."
        { cat "$manifest"; echo; cat "$image"; } | timeout 1800 nc -q1 -l -p "$port" \
            || die "invio via rete fallito (connect-back)"
        return
    fi

    # No separate "wait until the port answers" probe here on purpose: the
    # target's "nc -l -p $port" (see unitotem-flash) serves exactly one
    # connection and then exits, so a throwaway readiness probe would
    # itself consume that one connection - confirmed in testing: the
    # transfer failed every time because "wait_for_port"'s own -z probe
    # had already been treated as *the* connection. Retry the real send
    # instead, using -w as a fast per-attempt connect/idle timeout so
    # "nobody listening yet" fails quickly rather than hanging.
    log "Invio manifest + immagine a ${host}:${port} (riprovo finché il target non è pronto)..."
    local waited=0 rc
    while :; do
        rc=0
        { cat "$manifest"; echo; cat "$image"; } | timeout 1800 nc -q1 -w5 "$host" "$port" || rc=$?
        if [ "$rc" -eq 0 ]; then
            return
        fi
        waited=$((waited + 5))
        [ "$waited" -lt 900 ] || die "invio via rete fallito dopo ripetuti tentativi (${host}:${port})"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
cmd_deploy() {
    do_probe
    select_disk

    local image
    if [ -n "$OPT_IMAGE" ]; then
        image="$OPT_IMAGE"
    else
        image=$(ls -t "${DIR}/deploy/${ARCH}/kiosk-"*"-${ARCH}.img.xz" 2>/dev/null | head -1)
    fi
    [ -n "$image" ] && [ -f "$image" ] || die "nessuna immagine trovata per ${ARCH} (usa --image)"

    BOOT_DISK_BYID=""
    if [ "$FIRMWARE" = rpi ]; then
        local d
        for d in "${DISKS[@]}"; do
            IFS='|' read -r name _ _ _ byid <<< "$d"
            [ "$name" = "${P[BOOTDISK]:-}" ] && BOOT_DISK_BYID="$byid"
        done
        [ -n "$BOOT_DISK_BYID" ] || die "impossibile identificare il disco di boot (per il rollback rpi)"
    fi

    log "Genero il manifest di deploy per ${image}..."
    local manifest="${DIR}/work/unitotem-deploy.manifest.$$"
    build_deploy_manifest "$image" "$ARCH" > "$manifest"
    local comp_size raw_size
    comp_size=$(awk -F= '/^UNITOTEM_COMP_SIZE=/{print $2}' "$manifest")
    raw_size=$(awk -F= '/^UNITOTEM_RAW_SIZE=/{print $2}' "$manifest")

    [ "$TARGET_DISK_SIZE" -ge "$raw_size" ] \
        || die "${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE")) è più piccolo dell'immagine ($(bytes_human "$raw_size"))"

    local mode; mode=$(decide_mode "$comp_size")
    echo ""
    echo "Immagine    : $(basename "$image")  ($(bytes_human "$raw_size") raw, $(bytes_human "$comp_size") compressa)"
    echo "Disco target: ${TARGET_DISK} ($(bytes_human "$TARGET_DISK_SIZE"))"
    echo "Modo scelto : ${mode}"
    if [ "$OPT_YES" != 1 ]; then
        read -rp "Procedo con il flash in modo '${mode}'? [scrivi SI]: " ans
        [ "$ans" = "SI" ] || die "annullato dall'utente"
    fi

    local target_ip="${TARGET_USERHOST##*@}"
    HOST_IP=""
    if [ "$mode" = net ] && [ "$OPT_CONNECT_BACK" = 1 ]; then
        HOST_IP=$(ip -o route get "$target_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
        [ -n "$HOST_IP" ] || die "impossibile determinare l'IP locale verso ${target_ip} per --connect-back"
    fi

    push_flasher_kernel

    case "$mode" in
        ram|part) push_deploy_payload "$image" "$manifest" ;;
        net) : ;;  # streamed live after reboot, nothing to push now
    esac

    if [ "$FIRMWARE" = rpi ]; then
        arm_rpi "$(build_flash_cmdline "$mode")"
    else
        [ "${P[GRUB_REBOOT]}" = 1 ] || die "grub-reboot non trovato sul target: impossibile armare una voce one-shot"
        arm_grub "$(build_flash_cmdline "$mode")"
    fi

    do_reboot

    if [ "$mode" = net ]; then
        net_send "$manifest" "$image" "$target_ip" "$OPT_PORT"
    fi

    rm -f "$manifest"

    log "Attendo che il nuovo sistema torni raggiungibile via SSH (fino a 10 minuti)..."
    local waited=0
    sleep 20
    while ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${TARGET_USERHOST}" true 2>/dev/null; do
        sleep 10; waited=$((waited + 10))
        [ "$waited" -lt 600 ] || { warn "il target non è tornato raggiungibile entro 10 minuti - verificare manualmente"; return 0; }
    done

    # SSH tornando raggiungibile non basta a provare il successo: un
    # rollback (unitotem-flash fail() su GRUB) riporta su alla vecchia
    # installazione, che risponde su SSH allo stesso modo. /etc/kiosk è
    # creato solo da kiosk/stage2-configure.sh, quindi la sua assenza
    # smaschera in modo affidabile un flash silenziosamente fallito.
    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${TARGET_USERHOST}" "[ -d /etc/kiosk ]" 2>/dev/null; then
        log "Deploy completato: ${TARGET_USERHOST} è di nuovo raggiungibile sul nuovo sistema."
    else
        warn "${TARGET_USERHOST} è raggiungibile ma non sembra il nuovo sistema (/etc/kiosk assente) - il flash è probabilmente fallito ed è tornato al sistema precedente. Controllare lo schermo del target."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# disarm
# ---------------------------------------------------------------------------
cmd_disarm() {
    do_probe
    log "Rimuovo l'arming su ${TARGET_USERHOST} (${FIRMWARE})..."
    if [ "$FIRMWARE" = rpi ]; then
        ssh_t bash -s -- "${P[BOOTMNT]}" <<'REMOTE_EOF'
set -eu
cd "$1"
# "if" (not "test && action") on purpose: under set -e a bare "[ cond ] &&
# action" statement aborts the script when cond is merely false, which is
# the normal case here (e.g. disarm run when nothing was ever armed).
if [ -f config.txt.unitotem-bak ];  then mv -f config.txt.unitotem-bak  config.txt;  fi
if [ -f cmdline.txt.unitotem-bak ]; then mv -f cmdline.txt.unitotem-bak cmdline.txt; fi
rm -f unitotem-flash-vmlinuz unitotem-flash-initrd.img
sync
REMOTE_EOF
    else
        ssh_t bash -s <<'REMOTE_EOF'
set -eu
rm -f /etc/grub.d/99_unitotem_flash
command -v update-grub >/dev/null 2>&1 && update-grub || grub-mkconfig -o /boot/grub/grub.cfg
rm -f "$(findmnt -no TARGET /boot 2>/dev/null || echo /boot)/unitotem-flash-vmlinuz" \
      "$(findmnt -no TARGET /boot 2>/dev/null || echo /boot)/unitotem-flash-initrd.img"
REMOTE_EOF
    fi
    ssh_t "rm -rf /unitotem-deploy" || true
    log "Disarmato. Il target riavvierà normalmente."
}

case "$SUBCMD" in
    probe)  do_probe; print_probe ;;
    deploy) cmd_deploy ;;
    disarm) cmd_disarm ;;
    *) die "Sottocomando sconosciuto: ${SUBCMD} (probe|deploy|disarm)" ;;
esac
