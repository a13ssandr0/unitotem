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
for f in unitotem-logo-256x73.bgrx unitotem-logo-640x182.bgrx unitotem-logo-1280x365.bgrx unitotem-logo-256x73.rgb565 unitotem-logo-640x182.rgb565 unitotem-logo-1280x365.rgb565; do
    chk "framebuffer logo $f in the image" test -s "$R/usr/lib/unitotem/$f"
done
for e in bgrx bgr24 rgb565; do
    chk "frame line blob ($e) in the image" test -s "$R/usr/lib/unitotem/unitotem-frame-line.$e"
    for rad in 12 16 24 32 48 64; do chk "frame corners r=$rad ($e) in the image" test -s "$R/usr/lib/unitotem/unitotem-frame-corners-$rad.$e"; done
done
chk "stty is in the initramfs hook list (the frame geometry comes from the console size)" file_has "$R/etc/initramfs-tools/hooks/unitotem-ota" ' stty'
chk "the frame works at any resolution (no fixed-geometry guard left in ota_frame)" bash -c "! grep -q 'W\" = 640' $R/usr/lib/unitotem/ota-engine.sh"
chk "OTA hook carries the frame into the initramfs" file_has "$R/etc/initramfs-tools/hooks/unitotem-ota" 'unitotem-frame-'
chk "the engine draws the rounded frame and blanks whiptail's own border" bash -c "grep -q 'ota_frame' $R/usr/lib/unitotem/ota-engine.sh && grep -q 'blank whiptail' $R/usr/lib/unitotem/ota-engine.sh"
chk "OTA hook carries the logo into the initramfs" file_has "$R/etc/initramfs-tools/hooks/unitotem-ota" 'unitotem-logo-'
chk "manager is 3.x on this architecture" bash -c "awk 'BEGIN{RS=\"\";FS=\"\\n\"} \$1==\"Package: unitotem-manager\"{for(i=1;i<=NF;i++) if(\$i ~ /^Version: 3\\./) f=1} END{exit !f}' $R/var/lib/dpkg/status"
want=3e; [ "$ARCH" = arm64 ] && want=b7   # ELF e_machine: 0x3e x86-64, 0xb7 aarch64 (no `file` needed: it is not on every build host)
cefso=$(ls "$R"/var/unitotem-venv/lib/python3.13/site-packages/cefpython3/*.so 2>/dev/null | head -1)
chk "manager venv binaries are for this architecture (${cefso##*/})" bash -c "[ -n '$cefso' ] && [ \"\$(od -An -tx1 -j18 -N1 '$cefso' | tr -d ' ')\" = $want ]"

SP="$R/var/unitotem-venv/lib/python3.13/site-packages"
chk "CEF libraries are stripped (libcef.so < 600 MB; the unstripped arm64 wheel's is 1980 MB)" bash -c "[ -s '$SP/cefpython3/libcef.so' ] && [ \$(stat -c %s '$SP/cefpython3/libcef.so') -lt 629145600 ]"
chk "no unused PySide6 wheels in the manager venv (WebEngine/Addons/Pdf)" bash -c "! ls -d '$SP'/pyside6_webengine-*.dist-info '$SP'/pyside6_addons-*.dist-info '$SP'/pyside6_pdf-*.dist-info >/dev/null 2>&1 && [ ! -e '$SP/PySide6/Qt/lib/libQt6WebEngineCore.so.6' ]"
chk "the Qt modules the manager imports are still there (PySide6-Essentials)" test -e "$SP/PySide6/QtWidgets.abi3.so"
chk "the venv stays below 1.2 GB (it was 3.1 GB)" bash -c "[ \$(du -sk '$R/var/unitotem-venv' | cut -f1) -lt 1258291 ]"

echo "== Screen must never go black by itself"
for t in xset xsetroot xrandr; do chk "$t is installed (x11-xserver-utils survived the compiler removal)" bash -c "test -x '$R/usr/bin/$t'"; done
chk "X server never blanks/powers down on its own (ServerFlags timeouts 0)" bash -c "grep -q 'BlankTime.*\"0\"' '$R/etc/X11/xorg.conf.d/10-unitotem-noblank.conf' && grep -q 'OffTime.*\"0\"' '$R/etc/X11/xorg.conf.d/10-unitotem-noblank.conf'"
chk "no xinitrc is left (the X session is not started through startx/xinit any more)" bash -c "! test -e '$R/etc/kiosk/xinitrc'"

echo "== X server is a plain systemd unit (Xorg run directly), with a log"
XU="$R/etc/systemd/system/start-xorg.service"
chk "start-xorg.service runs Xorg directly (no startx/xinit)" bash -c "grep -qE '^ExecStart=/usr/bin/Xorg :0 vt8 ' '$XU' && ! grep -qE '^ExecStart=.*(startx|xinit)' '$XU'"
chk "X starts without clearing the screen and without listening on TCP" bash -c "grep -E '^ExecStart=' '$XU' | grep -q -- '-background none' && grep -E '^ExecStart=' '$XU' | grep -q -- '-nolisten tcp'"
chk "X keeps its log (no -logfile /dev/null): /var/log/Xorg.0.log" bash -c "! grep -E '^ExecStart=' '$XU' | grep -q -- '-logfile'"
chk "the X cookie is created before X starts (xauth + mcookie installed)" bash -c "grep -q 'xauth' '$XU' && grep -q 'mcookie' '$XU' && test -x '$R/usr/bin/xauth' && test -x '$R/usr/bin/mcookie'"
chk "X starts once Plymouth has released the display (After=plymouth-quit.service)" file_has "$XU" '^After=plymouth-quit.service'
chk "X authority file is the one the manager reads" file_has "$XU" '^Environment=XAUTHORITY=/run/unitotem-x11.auth'
chk "start-xorg service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/start-xorg.service"

echo "== Boot splash (Plymouth): the unitotem theme must be the one in the initramfs, not the fallback text theme"
if [ -f "$R/usr/share/plymouth/themes/unitotem/unitotem.plymouth" ]; then
    chk "plymouthd.conf selects the unitotem theme (stage 2 once overwrote it and the initramfs fell back to 'text')" file_has "$R/etc/plymouth/plymouthd.conf" '^Theme=unitotem$'
    chk "the theme has its wordmark and spinner for every screen tier (the script loads wordmark-TIER.png / spinner-TIER.png; dev3 shipped no wordmark)" bash -c "for t in 1280 1920 2560 3840; do for k in wordmark spinner; do test -s '$R/usr/share/plymouth/themes/unitotem/'\$k-\$t.png || { echo missing \$k-\$t.png; exit 1; }; done; done"
    INITRD=""
    if [ "$ARCH" = arm64 ]; then INITRD="$FAT/initramfs8"; [ "$AB" = 1 ] && INITRD="$FAT/slota/initramfs8"
    else INITRD=$(ls -t "$R"/boot/initrd.img-* 2>/dev/null | head -1); fi
    chk "the initramfs carries the unitotem theme and the script plugin (${INITRD##*/})" bash -c "l=\$(lsinitramfs '$INITRD' 2>/dev/null) && printf '%s\n' \"\$l\" | grep -q 'plymouth/themes/unitotem/unitotem.script' && printf '%s\n' \"\$l\" | grep -q 'plymouth/script.so'"
fi

echo "== Mount and boot robustness"
chk "boot FAT is ro,nofail in fstab" file_has "$R/etc/fstab" '^LABEL=(EFI|FIRMWARE)[[:space:]].*ro,nofail'
chk "emergency mode reboots instead of waiting forever" file_has "$R/etc/systemd/system/emergency.service.d/unitotem.conf" 'reboot'
chk "rescue mode reboots instead of waiting forever" file_has "$R/etc/systemd/system/rescue.service.d/unitotem.conf" 'reboot'
chk "persistent-paths service installed" test -x "$R/usr/sbin/unitotem-persist-paths"
chk "boot-ok service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-boot-ok.service"
chk "DATA overlay hook is in the image" test -e "$R/etc/initramfs-tools/scripts/init-bottom/setup-overlays"

echo "== Placeholder screen = the X background (boot OK / video works, whenever the manager is missing or shows nothing)"
chk "X background program installed" test -x "$R/usr/sbin/unitotem-xbackground"
chk "it runs as its own service after X, restarted with it" bash -c "grep -q '^After=start-xorg.service' '$R/etc/systemd/system/unitotem-xbackground.service' && grep -q '^PartOf=start-xorg.service' '$R/etc/systemd/system/unitotem-xbackground.service' && grep -q '^ExecStart=.*unitotem-xbackground' '$R/etc/systemd/system/unitotem-xbackground.service'"
chk "the placeholder service is enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-xbackground.service"
chk "python3 present for the X background" test -x "$R/usr/bin/python3"
chk "console fonts for its text (large DejaVu Bold sizes)" bash -c "test -s $R/usr/share/consolefonts/Lat15-DejaVuBold59x32.psf.gz && test -s $R/usr/share/consolefonts/Lat15-DejaVuBold118x64.psf.gz"
chk "its text is English and says BOOT OK / VIDEO OUTPUT WORKS" bash -c "grep -q 'BOOT OK  -  VIDEO OUTPUT WORKS' $R/usr/sbin/unitotem-xbackground && ! grep -iE 'avvio|schermo|funziona' $R/usr/sbin/unitotem-xbackground"
chk "it also covers the manager-not-installed case" file_has "$R/usr/sbin/unitotem-xbackground" 'manager is not installed'
chk "no console-switching placeholder left" bash -c "! test -e $R/usr/sbin/unitotem-placeholder && ! test -e $R/etc/systemd/system/unitotem-placeholder.service"

echo "== Device identity (nothing secret may be shared by every device flashed from one image)"
chk "no TLS private key in the image (it is generated on first boot)" bash -c "! test -e $R/etc/ssl/unitotem.pem && ! test -e $R/etc/ssl/unitotem_key.pem"
chk "first-boot certificate generator installed" test -x "$R/usr/sbin/unitotem-first-boot-cert"
chk "first-boot certificate service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-first-boot-cert.service"
chk "the generator runs before the manager" file_has "$R/etc/systemd/system/unitotem-first-boot-cert.service" 'Before=.*unitotem-manager.service'
chk "no SSH host key in the image's /etc/ssh is relied on (unitotem-ssh-hostkey regenerates)" test -x "$R/usr/sbin/unitotem-ssh-hostkey"

echo "== Update machinery"
chk "unitotem-update installed" test -x "$R/usr/sbin/unitotem-update"
chk "update root key installed" test -s "$R/usr/share/unitotem/update-keys/root.pub"
chk "release-version present" test -s "$R/usr/share/unitotem/release-version"
chk "unitotem-update uses the monotonic clock for deadlines" bash -c "grep -q 'time.monotonic' $R/usr/sbin/unitotem-update && ! grep -q 'deadline = time.time()' $R/usr/sbin/unitotem-update"
chk "OTA whitelist keeps the manager cert and unitotem* config" bash -c "grep -q '^ssl/unitotem.pem$' $R/etc/unitotem/ota-preserve.list && grep -q '^unitotem\\*$' $R/etc/unitotem/ota-preserve.list"
chk "the health gate is on (the 3.x manager provides /health; update.conf does not blank UPDATE_HEALTH_URL)" bash -c "! grep -q '^UPDATE_HEALTH_URL=\$' $R/etc/unitotem/update.conf 2>/dev/null"

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
    chk "Secure Boot chain staged on the ESP (shim, MokManager, signed GRUB, stub grub.cfg, unsigned GRUB kept)" bash -c "for f in shimx64.efi mmx64.efi grubx64.efi grub-unsigned.efi grub.cfg; do test -s $FAT/EFI/unitotem-sb/\$f || exit 1; done"
    chk "the staged chain is NOT active by default (EFI/BOOT/BOOTX64.EFI is the plain GRUB; the deploy activates shim only on request)" bash -c "cmp -s $FAT/EFI/BOOT/BOOTX64.EFI $FAT/EFI/unitotem-sb/grub-unsigned.efi && ! cmp -s $FAT/EFI/BOOT/BOOTX64.EFI $FAT/EFI/unitotem-sb/shimx64.efi"
    chk "grub-unsigned.efi really is the plain GRUB (not the shim, not the Debian-signed GRUB) and EFI/BOOT holds no chain leftovers" bash -c "! cmp -s $FAT/EFI/unitotem-sb/grub-unsigned.efi $FAT/EFI/unitotem-sb/shimx64.efi && ! cmp -s $FAT/EFI/unitotem-sb/grub-unsigned.efi $FAT/EFI/unitotem-sb/grubx64.efi && ! test -e $FAT/EFI/BOOT/grubx64.efi && ! test -e $FAT/EFI/BOOT/mmx64.efi"
    chk "the stub hands over to the real grub.cfg on the ESP" bash -c "grep -q 'unitotem-grub/grub/grub.cfg' $FAT/EFI/unitotem-sb/grub.cfg"
    chk "the OTA entries are low resolution (unitotem_lowres + nomodeset)" bash -c "grep -q 'unitotem_lowres' $FAT/unitotem-grub/grub/grub.cfg && grep -c nomodeset $FAT/unitotem-grub/grub/grub.cfg | grep -q '^4\$'"
fi

echo "== $n checks, $fail failed"
[ "$fail" = 0 ]
