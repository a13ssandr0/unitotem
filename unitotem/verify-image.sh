#!/bin/bash
# Rules every shipped image must satisfy, checked against the finished, mounted tree - nothing here is left to chance.
#   verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]   (ROOT_MOUNT has the boot FAT mounted under boot/efi or boot/firmware)
# Runs from unitotem/stage3-image.sh before the image is compressed (a violation fails the build) and by hand on a mounted image.
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
if installed unitotem-manager; then
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
for pkg in unitotem unitotem-manager unitotem-node unitotem-viewer python3-cefpython3 plymouth-theme-unitotem; do
    chk "package $pkg is installed at 3.x" bash -c "awk -v p='$pkg' 'BEGIN{RS=\"\";FS=\"\\n\"} \$1==\"Package: \"p{for(i=1;i<=NF;i++) if(\$i ~ /^Version: 3\\./) f=1} END{exit !f}' $R/var/lib/dpkg/status"
done
want=3e; [ "$ARCH" = arm64 ] && want=b7   # ELF e_machine: 0x3e x86-64, 0xb7 aarch64 (no `file` needed: it is not on every build host)
CEFD="$R/usr/lib/python3/dist-packages/cefpython3"
cefso="$CEFD/cefpython_py313.so"
chk "CEF binaries are for this architecture (${cefso##*/})" bash -c "[ -s '$cefso' ] && [ \"\$(od -An -tx1 -j18 -N1 '$cefso' | tr -d ' ')\" = $want ]"
chk "CEF's helper process is executable (a 0644 'subprocess' makes CEF abort with SIGTRAP: Cannot communicate with zygote)" test -x "$CEFD/subprocess"
chk "libcef.so is the same architecture too" bash -c "[ \"\$(od -An -tx1 -j18 -N1 '$CEFD/libcef.so' | tr -d ' ')\" = $want ]"
chk "CEF libraries are stripped (libcef.so < 600 MB; an unstripped aarch64 build is 1980 MB)" bash -c "[ -s '$CEFD/libcef.so' ] && [ \$(stat -c %s '$CEFD/libcef.so') -lt 629145600 ]"
chk "no virtualenv left (the manager runs on the system Python since 3.0.0~dev5)" bash -c "[ ! -e '$R/var/unitotem-venv' ]"
chk "the viewer's Qt comes from Debian packages (python3-pyside6.qtwidgets)" installed python3-pyside6.qtwidgets
chk "the manager unit is Type=notify (the viewer sends READY after its first frame)" bash -c "grep -q '^Type=notify' '$R/usr/lib/systemd/system/unitotem-manager.service'"
chk "the manager waits for X (drop-in)" bash -c "grep -q 'start-xorg.service' '$R/etc/systemd/system/unitotem-manager.service.d/20-unitotem-x.conf'"
chk "DISPLAY/XAUTHORITY drop-in of unitotem-node matches the X cookie path of start-xorg.service" bash -c "grep -q 'XAUTHORITY=/run/unitotem-x11.auth' '$R/usr/lib/systemd/system/unitotem-manager.service.d/10-x11.conf' && grep -q 'unitotem-x11.auth' '$R/etc/systemd/system/start-xorg.service'"

echo "== Screen must never go black by itself"
for t in xset xsetroot xrandr; do chk "$t is installed (x11-xserver-utils survived the compiler removal)" bash -c "test -x '$R/usr/bin/$t'"; done
chk "X server never blanks/powers down on its own (ServerFlags timeouts 0)" bash -c "grep -q 'BlankTime.*\"0\"' '$R/etc/X11/xorg.conf.d/10-unitotem-noblank.conf' && grep -q 'OffTime.*\"0\"' '$R/etc/X11/xorg.conf.d/10-unitotem-noblank.conf'"
chk "no xinitrc is left (the X session is not started through startx/xinit any more)" bash -c "! test -e '$R/etc/unitotem/xinitrc'"

echo "== X server is a plain systemd unit (Xorg run directly), with a log"
XU="$R/etc/systemd/system/start-xorg.service"
chk "start-xorg.service runs Xorg directly (no startx/xinit)" bash -c "grep -qE '^ExecStart=/usr/bin/Xorg :0 vt1 ' '$XU' && ! grep -qE '^ExecStart=.*(startx|xinit)' '$XU'"
chk "X starts with a black root window and without listening on TCP" bash -c "grep -E '^ExecStart=' '$XU' | grep -q -- ' -br' && grep -E '^ExecStart=' '$XU' | grep -q -- '-nolisten tcp'"
chk "the account merge for A/B updates is installed (unitotem_identity.py next to unitotem-update)" bash -c "test -s '$R/usr/lib/unitotem/unitotem_identity.py' && grep -q 'def merge_identity' '$R/usr/lib/unitotem/unitotem_identity.py' && grep -q 'merge_identity_into' '$R/usr/sbin/unitotem-update'"
chk "group unitotem exists (web UI logins through PAM)" bash -c "grep -q '^unitotem:' '$R/etc/group'"
chk "PAM service of the manager is shipped (/etc/pam.d/unitotem-manager)" test -s "$R/etc/pam.d/unitotem-manager"
if [ "$ARCH" = amd64 ]; then
    chk "Intel graphics firmware is installed (i915 DMC/GuC/HuC; without it VA-API cannot initialise)" bash -c "ls '$R'/lib/firmware/i915/adlp_dmc* >/dev/null 2>&1 || ls '$R'/usr/lib/firmware/i915/adlp_dmc* >/dev/null 2>&1"
    chk "the NVIDIA units do not fail the boot on PCs without an NVIDIA GPU" bash -c "test -s '$R/etc/systemd/system/nvidia-persistenced.service.d/unitotem-only-with-nvidia.conf' && test -s '$R/etc/systemd/system/systemd-modules-load.service.d/unitotem-nvidia-optional.conf'"
fi
chk "root lingers (session D-Bus /run/user/0/bus from boot) and dbus-user-session is installed" bash -c "test -e '$R/var/lib/systemd/linger/root' && test -e '$R/usr/lib/systemd/user/dbus.socket'"
chk "X keeps its log (no -logfile /dev/null): /var/log/Xorg.0.log" bash -c "! grep -E '^ExecStart=' '$XU' | grep -q -- '-logfile'"
chk "the X cookie is created before X starts (xauth + mcookie installed)" bash -c "grep -q 'xauth' '$XU' && grep -q 'mcookie' '$XU' && test -x '$R/usr/bin/xauth' && test -x '$R/usr/bin/mcookie'"
chk "X takes over from a deactivated Plymouth (no blanking quit): deactivate before X, Plymouth removed once X answers" bash -c "grep -q '^ExecStartPre=-/usr/bin/plymouth deactivate' '$XU' && grep -q 'xset q' '$XU' && grep -q 'pkill -KILL -x plymouthd' '$XU' && grep -q '^After=plymouth-start.service' '$XU' && ! grep -qE '^ExecStartPre=.*chvt' '$XU'"
chk "X runs on VT1 and getty@tty1 is masked (nothing may share Plymouth's VT)" bash -c "grep -q 'vt1' '$XU' && test \$(readlink '$R/etc/systemd/system/getty@tty1.service') = /dev/null"
chk "the kernel command line silences systemd status text (it would be repainted on the console during the hand-over)" bash -c "for f in '$FAT/cmdline.txt' '$FAT/slota/cmdline.txt' '$R/etc/default/grub' '$R/etc/default/grub.d/'* '$R/boot/grub/grub.cfg'; do [ -f \"\$f\" ] && grep -q ' systemd.show_status=false' \"\$f\" && exit 0; done; exit 1"
chk "X authority file is the one the manager reads" file_has "$XU" '^Environment=XAUTHORITY=/run/unitotem-x11.auth'
chk "start-xorg service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/start-xorg.service"

echo "== Boot splash (Plymouth): the unitotem theme must be the one in the initramfs, not the fallback text theme"
if [ -f "$R/usr/share/plymouth/themes/unitotem/unitotem.plymouth" ]; then
    chk "plymouthd.conf selects the unitotem theme (stage 2 once overwrote it and the initramfs fell back to 'text')" file_has "$R/etc/plymouth/plymouthd.conf" '^Theme=unitotem$'
    chk "the theme has its wordmark and spinner for every screen tier (the script loads wordmark-TIER.png / spinner-TIER.png; dev3 shipped no wordmark)" bash -c "for t in 1280 1920 2560 3840; do for k in wordmark spinner; do test -s '$R/usr/share/plymouth/themes/unitotem/'\$k-\$t.png || { echo missing \$k-\$t.png; exit 1; }; done; done"
    INITRD=""
    if [ "$ARCH" = arm64 ]; then INITRD="$FAT/initramfs8"; [ "$AB" = 1 ] && INITRD="$FAT/slota/initramfs8"
    else INITRD=$(ls -t "$R"/boot/initrd.img-* 2>/dev/null | head -1); fi
    if [ "$ARCH" = arm64 ]; then
        # the Pi firmware reads the initramfs at ~5 MB/s: 40 MB was 8 s of black screen (measured 2026-10-17); slimmed it is ~26 MB
        chk "the Pi initramfs is slim (< 32 MB, no hwdb.bin; unitotem/slim-initramfs.py)" bash -c "[ \$(stat -c %s '$INITRD') -lt 33554432 ] && ! lsinitramfs '$INITRD' | grep -q 'udev/hwdb.bin'"
        chk "the Pi initramfs has no plymouth label plugin (pango/cairo/X11 ~4 MB)" bash -c "! lsinitramfs '$INITRD' | grep -q 'plymouth/label'"
    fi
    chk "the initramfs carries the unitotem theme and the script plugin (${INITRD##*/})" bash -c "l=\$(lsinitramfs '$INITRD' 2>/dev/null) && printf '%s\n' \"\$l\" | grep -q 'plymouth/themes/unitotem/unitotem.script' && printf '%s\n' \"\$l\" | grep -q 'plymouth/script.so'"
fi

echo "== Module-signing key"
chk "no DKMS private signing key in the image (it would be shared by every device; mok.pub stays for enrolment)" bash -c "[ ! -e '$R/var/lib/dkms/mok.key' ]"
[ "$ARCH" = amd64 ] && chk "the public certificate for a MOK enrolment is there (/var/lib/dkms/mok.pub)" test -s "$R/var/lib/dkms/mok.pub"

echo "== The recovery environment carries every command the OTA engine runs"
RINIT="$FAT/unitotem/recovery-initrd.img"; [ "$ARCH" = arm64 ] && RINIT="$FAT/recovery-initrd.img"
chk "recovery initrd has every external command ota-engine.sh runs (tr and cmp were missing: amd64 set-default-recovery and --secure-boot shim died mid-deploy)" \
    bash "$(dirname "${BASH_SOURCE[0]}")/check-recovery-commands.sh" "$R" "$RINIT" "$ENG"

echo "== Ports and logs of the 3.0.0~dev5 manager"
chk "firewall opens 4443/tcp (paired nodes' mutual-TLS link) on IPv4 and IPv6" bash -c "grep -q 'iptables -A INPUT -p tcp --dport 4443 -j ACCEPT' '$R/sbin/iptables-firewall.sh' && grep -q 'ip6tables -A INPUT -p tcp --dport 4443 -j ACCEPT' '$R/sbin/iptables-firewall.sh'"
chk "journald stores INFO (the manager's stderr is INFO: at 'warning' its logs never reached the journal)" file_has "$R/etc/systemd/journald.conf.d/unitotem.conf" '^MaxLevelStore=info'
echo "== Device identity: nothing a node generates for itself may be baked into the image"
for f in etc/unitotem/users.json etc/unitotem/remote.json var/lib/unitotem/claim-code etc/ssl/unitotem.pem; do
    chk "no $f in the image (users, the node's private key, the claim code, the TLS key are created on the device)" bash -c "[ ! -e '$R/$f' ]"
done

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
chk "the placeholder is NOT enabled by default (the viewer's splash replaces it; it stays installed as a diagnostic tool)" bash -c "[ ! -e '$R/etc/systemd/system/multi-user.target.wants/unitotem-xbackground.service' ]"
chk "the viewer's splash service is enabled (unitotem-viewer ships and enables it)" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-splash.service"
chk "the splash is Type=notify (ready at its first frame) and waits for X's socket itself (no After=start-xorg: it warms up in parallel)" bash -c "grep -q '^Type=notify' '$R/usr/lib/systemd/system/unitotem-splash.service' && ! grep -q '^After=.*start-xorg' '$R/usr/lib/systemd/system/unitotem-splash.service'"
chk "the splash script is in the image" test -s "$R/usr/share/unitotem-manager/plugins/unitotem_viewer/splash.py"
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
chk "unitotem-update can rebuild a damaged slot from the running one (repair + failover bookkeeping)" bash -c "grep -q 'def do_repair' $R/usr/sbin/unitotem-update && grep -q 'def note_failover' $R/usr/sbin/unitotem-update"
chk "partclone.extfs (source of the slot copy) is installed" bash -c "test -x '$R/usr/sbin/partclone.extfs' || test -x '$R/usr/bin/partclone.extfs'"
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
    chk "GRUB tries the other slot, then the OTA fallback, when the chosen slot cannot be loaded (fallback= in grub.cfg)" bash -c "grep -q 'set fallback=\"slot-b ota-recovery\"' $FAT/unitotem-grub/grub/grub.cfg && grep -q 'set fallback=\"slot-a ota-recovery\"' $FAT/unitotem-grub/grub/grub.cfg"
    chk "recovery kernel and initrd on the ESP" bash -c "test -s $FAT/unitotem/recovery-vmlinuz && test -s $FAT/unitotem/recovery-initrd.img"
    chk "Secure Boot chain staged on the ESP (shim, MokManager, signed GRUB, stub grub.cfg, unsigned GRUB kept)" bash -c "for f in shimx64.efi mmx64.efi grubx64.efi grub-unsigned.efi grub.cfg; do test -s $FAT/EFI/unitotem-sb/\$f || exit 1; done"
    chk "the staged chain is NOT active by default (EFI/BOOT/BOOTX64.EFI is the plain GRUB; the deploy activates shim only on request)" bash -c "cmp -s $FAT/EFI/BOOT/BOOTX64.EFI $FAT/EFI/unitotem-sb/grub-unsigned.efi && ! cmp -s $FAT/EFI/BOOT/BOOTX64.EFI $FAT/EFI/unitotem-sb/shimx64.efi"
    chk "grub-unsigned.efi really is the plain GRUB (not the shim, not the Debian-signed GRUB) and EFI/BOOT holds no chain leftovers" bash -c "! cmp -s $FAT/EFI/unitotem-sb/grub-unsigned.efi $FAT/EFI/unitotem-sb/shimx64.efi && ! cmp -s $FAT/EFI/unitotem-sb/grub-unsigned.efi $FAT/EFI/unitotem-sb/grubx64.efi && ! test -e $FAT/EFI/BOOT/grubx64.efi && ! test -e $FAT/EFI/BOOT/mmx64.efi"
    chk "the stub hands over to the real grub.cfg on the ESP" bash -c "grep -q 'unitotem-grub/grub/grub.cfg' $FAT/EFI/unitotem-sb/grub.cfg"
    chk "the OTA entries are low resolution (unitotem_lowres + nomodeset)" bash -c "grep -q 'unitotem_lowres' $FAT/unitotem-grub/grub/grub.cfg && grep -c nomodeset $FAT/unitotem-grub/grub/grub.cfg | grep -q '^4\$'"
fi

echo "== $n checks, $fail failed"
[ "$fail" = 0 ]
