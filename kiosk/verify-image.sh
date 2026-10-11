#!/bin/bash
# Rules every shipped image must satisfy, checked against the finished, mounted tree - nothing here is left to chance.
#   verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]   (ROOT_MOUNT has the boot FAT mounted under boot/efi or boot/firmware)
# Runs from kiosk/stage3-image.sh before the image is compressed (a violation fails the build) and by hand on a mounted image.
# Every check prints PASS/FAIL; all of them run, the exit status is 1 if any failed.
set -uo pipefail
R="${1:?uso: verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]}"; ARCH="${2:?arch}"; AB="${3:-0}"
fail=0; n=0
ok()  { n=$((n+1)); echo "  PASS: $1"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "  FAIL: $1" >&2; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
installed() { awk -v p="$1" 'BEGIN{RS="";FS="\n"} $1=="Package: " p {for(i=1;i<=NF;i++) if($i=="Status: install ok installed") f=1} END{exit !f}' "$R/var/lib/dpkg/status"; }
file_has() { grep -qE -- "$2" "$1" 2>/dev/null; }
FAT=$R/boot/efi; [ "$ARCH" = arm64 ] && FAT=$R/boot/firmware
FAT="${FAT_DIR:-$FAT}"   # by hand on a mounted image the FAT is a separate mount: FAT_DIR=/path
ENG=$R/usr/lib/unitotem/ota-engine.sh

echo "== Language and wording of the on-screen OTA text (English; 'update' by default, 'recovery' only for self-detected faults)"
chk "engine present in the image" test -s "$ENG"
# strings that can reach a display: status lines, the header, the idle text
ITA='ripristin|recuper|attesa|montaggio|preparazione|verifica|copia |migrazione|installazione|ricostruzione|motivo|indirizzo|porta:|partizione|riavvio|errore'
screen=$(grep -hE 'ota_status_set "|ota_ui_start|\$\{phase:-|kind_title=' "$ENG" 2>/dev/null; sed -n '/ota_ui_start "\${kind_title}/,/Port: 2222/p' "$ENG" 2>/dev/null)
chk "no Italian word in the screen strings" bash -c "! printf '%s\n' \"\$1\" | grep -iE '$ITA'" _ "$screen"
chk "default screen title is 'OTA update mode'" file_has "$ENG" 'kind_title="OTA update mode"'
chk "'recovery' title only when kind=recovery is passed" file_has "$ENG" '\[ "\$\{ARG\[kind\]:-update\}" = recovery \]'
chk "reason texts are English (no Italian after --reason)" bash -c "! grep -hE 'serve_fallback --reason \"' \"$ENG\" | grep -iE '$ITA'"
chk "recovery is not used for host-requested updates" bash -c "! grep -E 'update requested by the host' \"$ENG\" | grep -q 'kind recovery'"
chk "Pi fallback is forced to 640x480 (DMT mode 4)" file_has "$ENG" 'hdmi_mode=4'

echo "== AppArmor / auditd rule"
if installed apparmor; then chk "apparmor installed, so auditd must be too" installed auditd; else ok "apparmor package absent (no profile can load)"; fi

echo "== Content removed on purpose"
for p in chromium chromium-browser chromium-common chromium-l10n build-essential gcc g++ cpp gcc-14 g++-14 cpp-14; do
    installed "$p" && bad "package $p must not be installed" || ok "package $p absent"
done
[ "$ARCH" = amd64 ] && chk "NVIDIA module still present after removing the compilers" bash -c "ls $R/lib/modules/*/updates/dkms/nvidia-current.ko* >/dev/null 2>&1"
if [ -e "$R/var/unitotem-venv/bin/python3" ] && [ "$(ls "$R"/var/unitotem-venv/lib 2>/dev/null)" = python3.13 ] && [ -e "$R/usr/share/unitotem-manager/screenctl.py" ]; then
    installed haproxy && bad "haproxy installed alongside a 3.x manager (it would hold ports 80/443)" || ok "haproxy absent with the 3.x manager"
fi

echo "== Needed packages and modules (screen control)"
for p in ddcutil i2c-tools v4l-utils; do chk "package $p installed" installed "$p"; done
chk "i2c-dev loaded at boot" file_has "$R/etc/modules-load.d/unitotem-i2c.conf" '^i2c-dev$'
chk "cron present (manager timers)" installed cron
for p in libxcb-icccm4 libxcb-shape0; do chk "package $p installed (the Qt viewer aborts without it)" installed "$p"; done

echo "== Logo and manager"
for f in unitotem-logo-256x73.bgrx unitotem-logo-640x182.bgrx unitotem-logo-256x73.rgb565 unitotem-logo-640x182.rgb565; do
    chk "framebuffer logo $f in the image" test -s "$R/usr/lib/unitotem/$f"
done
chk "OTA hook carries the logo into the initramfs" file_has "$R/etc/initramfs-tools/hooks/unitotem-ota" 'unitotem-logo-'
chk "manager is 3.x on this architecture" bash -c "awk 'BEGIN{RS=\"\";FS=\"\\n\"} \$1==\"Package: unitotem-manager\"{for(i=1;i<=NF;i++) if(\$i ~ /^Version: 3\\./) f=1} END{exit !f}' $R/var/lib/dpkg/status"
want=3e; [ "$ARCH" = arm64 ] && want=b7   # ELF e_machine: 0x3e x86-64, 0xb7 aarch64 (no `file` needed: it is not on every build host)
cefso=$(ls "$R"/var/unitotem-venv/lib/python3.13/site-packages/cefpython3/*.so 2>/dev/null | head -1)
chk "manager venv binaries are for this architecture (${cefso##*/})" bash -c "[ -n '$cefso' ] && [ \"\$(od -An -tx1 -j18 -N1 '$cefso' | tr -d ' ')\" = $want ]"

echo "== Mount and boot robustness"
chk "boot FAT is ro,nofail in fstab" file_has "$R/etc/fstab" '^LABEL=(EFI|FIRMWARE)[[:space:]].*ro,nofail'
chk "emergency mode reboots instead of waiting forever" file_has "$R/etc/systemd/system/emergency.service.d/unitotem.conf" 'reboot'
chk "rescue mode reboots instead of waiting forever" file_has "$R/etc/systemd/system/rescue.service.d/unitotem.conf" 'reboot'
chk "persistent-paths service installed" test -x "$R/usr/sbin/unitotem-persist-paths"
chk "boot-ok service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-boot-ok.service"
chk "DATA overlay hook is in the image" test -e "$R/etc/initramfs-tools/scripts/init-bottom/setup-overlays"

echo "== Update machinery"
chk "unitotem-update installed" test -x "$R/usr/sbin/unitotem-update"
chk "update root key installed" test -s "$R/usr/share/unitotem/update-keys/root.pub"
chk "release-version present" test -s "$R/usr/share/unitotem/release-version"
chk "unitotem-update uses the monotonic clock for deadlines" bash -c "grep -q 'time.monotonic' $R/usr/sbin/unitotem-update && ! grep -q 'deadline = time.time()' $R/usr/sbin/unitotem-update"
chk "OTA whitelist keeps the manager cert and unitotem* config" bash -c "grep -q '^ssl/unitotem.pem$' $R/etc/unitotem/ota-preserve.list && grep -q '^unitotem\\*$' $R/etc/unitotem/ota-preserve.list"
if [ ! -e "$R/var/unitotem-venv/bin/python3" ] || [ "$ARCH" = arm64 ]; then
    chk "image without a /health manager has the health gate disabled (UPDATE_HEALTH_URL empty)" file_has "$R/etc/unitotem/update.conf" '^UPDATE_HEALTH_URL=$'
fi

if [ "$AB" = 1 ]; then
echo "== A/B layout"
    chk "release version is a plain version string" bash -c "grep -qE '^[0-9]+(\\.[0-9]+)+$' $R/usr/share/unitotem/release-version"
    chk "root= uses the slot label, fstab has no / line" bash -c "! grep -qE '^LABEL=ROOT[[:space:]]+/[[:space:]]' $R/etc/fstab"
    chk "A/B images keep no boot counter service on the FAT (boot-ok skips it)" file_has "$R/usr/sbin/unitotem-boot-ok" 'unitotem.slot='
    chk "overlay hook is slot-aware" file_has "$R/etc/initramfs-tools/scripts/init-bottom/setup-overlays" 'unitotem.slot'
fi

if [ "$ARCH" = arm64 ]; then
echo "== Raspberry boot property (every file a config loads must exist under its os_prefix)"
    cfgs="config.txt"; [ -f "$FAT/tryboot.txt" ] && cfgs="$cfgs tryboot.txt"
    for cfg in $cfgs; do
        pre=$(sed -n 's/^os_prefix=//p' "$FAT/$cfg" | tail -1); k=$(sed -n 's/^kernel=//p' "$FAT/$cfg" | tail -1); k=${k:-kernel8.img}
        i=$(sed -n 's/^initramfs \([^ ]*\) followkernel.*/\1/p' "$FAT/$cfg" | tail -1)
        for f in "$k" ${i:+$i} bcm2711-rpi-4-b.dtb cmdline.txt; do chk "$cfg loads ${pre}$f" test -s "$FAT/$pre$f"; done
    done
    chk "fallback device tree at the TOP of the boot FAT (the fallback config has no os_prefix)" test -s "$FAT/bcm2711-rpi-4-b.dtb"
    chk "overlays at the top of the boot FAT" test -d "$FAT/overlays"
    chk "resident recovery kernel and initramfs on the FAT" bash -c "test -s $FAT/recovery8.img && test -s $FAT/recovery-initrd.img"
    chk "serial console is ttyS0 in the slot cmdline" bash -c "grep -q 'console=ttyS0' $FAT/*cmdline.txt $FAT/slot*/cmdline.txt 2>/dev/null"
elif [ "$AB" = 1 ]; then
echo "== amd64 boot"
    chk "GRUB entries for both slots" bash -c "grep -q 'slot-a' $FAT/unitotem-grub/grub/grub.cfg && grep -q 'slot-b' $FAT/unitotem-grub/grub/grub.cfg"
    chk "OTA fallback entry is last (a torn grubenv must boot a slot)" bash -c "[ \"\$(grep -E '^menuentry' $FAT/unitotem-grub/grub/grub.cfg | tail -1 | grep -c ota-recovery)\" = 1 ]"
    chk "recovery kernel and initrd on the ESP" bash -c "test -s $FAT/unitotem/recovery-vmlinuz && test -s $FAT/unitotem/recovery-initrd.img"
fi

echo "== $n checks, $fail failed"
[ "$fail" = 0 ]
