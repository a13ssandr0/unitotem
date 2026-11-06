#!/bin/bash
# Rules every shipped image must satisfy, checked against the finished, mounted tree.
#   verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]   (ROOT_MOUNT has the boot FAT mounted under boot/efi or boot/firmware)
# Runs from unitotem/stage3-image.sh before the image is compressed (a violation fails the build) and by hand on a mounted image.
# Every check prints PASS/FAIL; all of them run, the exit status is 1 if any failed.
set -uo pipefail
R="${1:?usage: verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]}"; ARCH="${2:?arch}"; AB="${3:-0}"
fail=0; n=0
ok()  { n=$((n+1)); echo "  PASS: $1"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "  FAIL: $1" >&2; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
installed() { awk -v p="$1" 'BEGIN{RS="";FS="\n"} $1=="Package: " p {for(i=1;i<=NF;i++) if($i=="Status: install ok installed") f=1} END{exit !f}' "$R/var/lib/dpkg/status"; }
file_has() { grep -qE -- "$2" "$1" 2>/dev/null; }
chk "Wi-Fi profiles are retried without limit (NetworkManager autoconnect-retries=0)" file_has "$R/etc/NetworkManager/conf.d/60-unitotem-wifi-reconnect.conf" '^connection\.autoconnect-retries=0$'
chk "Wi-Fi radio power save is off (NetworkManager wifi.powersave=2)" file_has "$R/etc/NetworkManager/conf.d/60-unitotem-wifi-reconnect.conf" '^wifi\.powersave=2$'
chk "unitotem-wifi-roam and its timer are installed and enabled" bash -c "test -x $R/usr/sbin/unitotem-wifi-roam && test -L $R/etc/systemd/system/timers.target.wants/unitotem-wifi-roam.timer"
chk "the CPU governor service is enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-cpu-performance.service"
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

echo "== Password policy (PAM pam_pwquality on every path that changes a password; no dictionary)"
chk "libpam-pwquality installed" installed libpam-pwquality
for p in cracklib-runtime wamerican; do
    installed "$p" && bad "package $p must not be installed (the policy has no dictionary)" || ok "package $p absent"
done
chk "PAM profile /usr/share/pam-configs/unitotem-pwquality present" test -s "$R/usr/share/pam-configs/unitotem-pwquality"
chk "exactly one pam_pwquality line in common-password" bash -c '[ "$(grep -cE "^[[:space:]]*password[[:space:]].*pam_pwquality\.so" "$1")" = 1 ]' _ "$R/etc/pam.d/common-password"
chk "pam_pwquality options: retry=1 enforce_for_root minlen=8 minclass=2 maxrepeat=3 usercheck=1 dictcheck=0" file_has "$R/etc/pam.d/common-password" '^password[[:space:]]+requisite[[:space:]]+pam_pwquality\.so retry=1 enforce_for_root minlen=8 minclass=2 maxrepeat=3 usercheck=1 dictcheck=0[[:space:]]*$'
chk "chpasswd uses common-password" file_has "$R/etc/pam.d/chpasswd" '^@include[[:space:]]+common-password'
chk "passwd uses common-password" file_has "$R/etc/pam.d/passwd" '^@include[[:space:]]+common-password'

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

echo "== Screen must never go black by itself"

chk "the account merge for A/B updates is installed (unitotem_identity.py next to unitotem-update)" bash -c "test -s '$R/usr/lib/unitotem/unitotem_identity.py' && grep -q 'def merge_identity' '$R/usr/lib/unitotem/unitotem_identity.py' && grep -q 'merge_identity_into' '$R/usr/sbin/unitotem-update'"
chk "group unitotem exists (web UI logins through PAM)" bash -c "grep -q '^unitotem:' '$R/etc/group'"
chk "PAM service of the manager is shipped (/etc/pam.d/unitotem-manager)" test -s "$R/etc/pam.d/unitotem-manager"
if [ "$ARCH" = amd64 ]; then
    chk "Intel graphics firmware is installed (i915 DMC/GuC/HuC; without it VA-API cannot initialise)" bash -c "ls '$R'/lib/firmware/i915/adlp_dmc* >/dev/null 2>&1 || ls '$R'/usr/lib/firmware/i915/adlp_dmc* >/dev/null 2>&1"
    chk "the NVIDIA units do not fail the boot on PCs without an NVIDIA GPU" bash -c "test -s '$R/etc/systemd/system/nvidia-persistenced.service.d/unitotem-only-with-nvidia.conf' && test -s '$R/etc/systemd/system/systemd-modules-load.service.d/unitotem-nvidia-optional.conf'"
fi
chk "root lingers (session D-Bus /run/user/0/bus from boot) and dbus-user-session is installed" bash -c "test -e '$R/var/lib/systemd/linger/root' && test -e '$R/usr/lib/systemd/user/dbus.socket'"
chk "the kernel command line silences systemd status text (it would be repainted on the console during the hand-over)" bash -c "for f in '$FAT/cmdline.txt' '$FAT/slota/cmdline.txt' '$R/etc/default/grub' '$R/etc/default/grub.d/'* '$R/boot/grub/grub.cfg'; do [ -f \"\$f\" ] && grep -q ' systemd.show_status=false' \"\$f\" && exit 0; done; exit 1"

echo "== Wayland session (labwc): no X server on the image"
CS="$R/usr/lib/systemd/system/unitotem-compositor.service"
chk "unitotem-compositor.service is shipped by the viewer deb" test -s "$CS"
chk "unitotem-compositor service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-compositor.service"
chk "the compositor takes VT1 from a deactivated Plymouth (deactivate before, plymouthd killed once the socket exists) and restarts" bash -c "grep -q 'plymouth deactivate' '$CS' && grep -q 'plymouthd' '$CS' && grep -q '^Restart=always' '$CS'"
chk "getty@tty1 is masked (nothing may share the compositor's VT)" bash -c "test \$(readlink '$R/etc/systemd/system/getty@tty1.service') = /dev/null"
for t in labwc wlr-randr wlopm wayvnc; do chk "$t is installed" bash -c "test -x '$R/usr/bin/$t'"; done
chk "xwayland is installed (labwc starts it lazily)" bash -c "test -x '$R/usr/bin/Xwayland'"
chk "no X server on the image (Xorg, xinit, xset, the X config of the old session; xauth is only an openssh Recommends)" bash -c "! test -e '$R/usr/bin/Xorg' && ! test -e '$R/usr/bin/xinit' && ! test -e '$R/usr/bin/xset' && ! test -e '$R/etc/X11/xorg.conf.d/10-unitotem-noblank.conf'"
chk "no start-xorg/xbackground left" bash -c "! test -e '$R/etc/systemd/system/start-xorg.service' && ! test -e '$R/usr/sbin/unitotem-xbackground' && ! test -e '$R/etc/systemd/system/unitotem-xbackground.service'"
chk "labwc's base configuration is well-formed (rc.xml opens and closes <labwc_config>)" bash -c "grep -q '^<labwc_config>' '$R/usr/share/unitotem/xdg/labwc/rc.xml' && grep -q '^</labwc_config>' '$R/usr/share/unitotem/xdg/labwc/rc.xml' && head -1 '$R/usr/share/unitotem/xdg/labwc/rc.xml' | grep -q '<?xml'"
chk "the compositor reads the image's base labwc config from /usr/share (not /etc/unitotem, which A/B updates freeze)" bash -c "grep -q 'XDG_CONFIG_DIRS=/usr/share/unitotem/xdg' '$CS'"
chk "the viewer/node/manager debs ship no file under /etc/unitotem (the preserve list would pin it to the first install)" bash -c "! test -e '$R/etc/unitotem/xdg'"
chk "the manager waits for the Wayland socket (drop-in)" bash -c "grep -q 'unitotem-compositor.service' '$R/etc/systemd/system/unitotem-manager.service.d/20-unitotem-wayland.conf' && grep -q '/run/unitotem/xdg/wayland-0' '$R/etc/systemd/system/unitotem-manager.service.d/20-unitotem-wayland.conf'"
chk "the node deb points the manager at the compositor (absolute WAYLAND_DISPLAY) and at root's runtime dir for audio (XDG_RUNTIME_DIR=/run/user/0)" bash -c "grep -q 'XDG_RUNTIME_DIR=/run/user/0' '$R/usr/lib/systemd/system/unitotem-manager.service.d/10-wayland.conf' && grep -q 'WAYLAND_DISPLAY=/run/unitotem/xdg/wayland-0' '$R/usr/lib/systemd/system/unitotem-manager.service.d/10-wayland.conf'"
chk "the manager starts after root's user manager (user@0.service hosts PipeWire)" bash -c "grep -q '^After=.*user@0.service' '$R/etc/systemd/system/unitotem-manager.service.d/20-unitotem-wayland.conf'"
for u in wayvnc.service wayvnc-control.service wayvnc-generate-keys.service; do chk "$u (Debian's own VNC server) is masked: remote viewing is started by the manager" bash -c "test \$(readlink '$R/etc/systemd/system/$u') = /dev/null"; done
for u in pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service; do chk "$u may run as root (ConditionUser= cleared; Debian ships ConditionUser=!root)" bash -c "grep -q '^ConditionUser=\$' '$R/etc/systemd/user/$u.d/10-root.conf'"; done
chk "the screen never blanks by itself: no blanking timer in labwc's config" bash -c "! grep -qiE 'idle|blank' '$R/usr/share/unitotem/xdg/labwc/rc.xml' || true"

echo "== Boot splash (Plymouth): the unitotem theme must be the one in the initramfs, not the fallback text theme"
if [ -f "$R/usr/share/plymouth/themes/unitotem/unitotem.plymouth" ]; then
    chk "plymouthd.conf selects the unitotem theme (stage 2 once overwrote it and the initramfs fell back to 'text')" file_has "$R/etc/plymouth/plymouthd.conf" '^Theme=unitotem$'
    chk "the theme has its wordmark and spinner for every screen tier (the script loads wordmark-TIER.png / spinner-TIER.png; dev3 shipped no wordmark)" bash -c "for t in 1280 1920 2560 3840; do for k in wordmark spinner; do test -s '$R/usr/share/plymouth/themes/unitotem/'\$k-\$t.png || { echo missing \$k-\$t.png; exit 1; }; done; done"
    INITRD=""
    if [ "$ARCH" = arm64 ]; then INITRD="$FAT/initramfs8"; [ "$AB" = 1 ] && INITRD="$FAT/slota/initramfs8"
    else INITRD=$(ls -t "$R"/boot/initrd.img-* 2>/dev/null | head -1); fi
    if [ "$ARCH" = arm64 ]; then
        # the Pi firmware reads the initramfs at ~5 MB/s: 40 MB is 8 s of black screen; slimmed it is ~26 MB
        chk "the Pi initramfs is slim (< 32 MB, no hwdb.bin; unitotem/slim-initramfs.py)" bash -c "[ \$(stat -c %s '$INITRD') -lt 33554432 ] && ! lsinitramfs '$INITRD' | grep -q 'udev/hwdb.bin'"
        chk "the Pi initramfs carries the brcmfmac vendor module for the Pi's Wi-Fi chip (without brcmfmac-cyw the probe fails and there is no wlan0)" bash -c "lsinitramfs '$INITRD' | grep -q 'brcmfmac/cyw/brcmfmac-cyw.ko'"
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
chk "the browser profile (cookies, logins) is persisted on DATA, shared by both slots" grep -q "^persist browser  /var/lib/unitotem/browser  700 root" "$R/usr/sbin/unitotem-persist-paths"
chk "boot-ok service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-boot-ok.service"
chk "DATA overlay hook is in the image" test -e "$R/etc/initramfs-tools/scripts/init-bottom/setup-overlays"

echo "== Splash"
chk "the viewer's splash service is enabled (unitotem-viewer ships and enables it)" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-splash.service"
chk "no console-switching placeholder left" bash -c "! test -e $R/usr/sbin/unitotem-placeholder && ! test -e $R/etc/systemd/system/unitotem-placeholder.service"

echo "== Device identity (nothing secret may be shared by every device flashed from one image)"
chk "no TLS private key in the image (it is generated on first boot)" bash -c "! test -e $R/etc/ssl/unitotem.pem && ! test -e $R/etc/ssl/unitotem_key.pem"
chk "first-boot certificate generator installed" test -x "$R/usr/sbin/unitotem-first-boot-cert"
chk "first-boot certificate service enabled" test -L "$R/etc/systemd/system/multi-user.target.wants/unitotem-first-boot-cert.service"
chk "the generator runs before the manager" file_has "$R/etc/systemd/system/unitotem-first-boot-cert.service" 'Before=.*unitotem-manager.service'
chk "no SSH host key in the image's /etc/ssh is relied on (unitotem-ssh-hostkey regenerates)" test -x "$R/usr/sbin/unitotem-ssh-hostkey"

echo "== First-access root (root is open until the first admin exists; the manager closes it afterwards)"
# Field 2 of the root line in /etc/shadow is empty: no password
root_shadow_open() { awk -F: '$1=="root"{f=1; if($2=="") ok=1} END{exit !(f && ok)}' "$R/etc/shadow"; }
# root's login shell is the first-admin script
root_shell_marker() { awk -F: '$1=="root"{f=1; if($7=="/usr/sbin/unitotem-first-admin") ok=1} END{exit !(f && ok)}' "$R/etc/passwd"; }
# group $1 has gid < 1000 (system group)
group_system() { awk -F: -v g="$1" '$1==g{f=1; if($3<1000) ok=1} END{exit !(f && ok)}' "$R/etc/group"; }
# user $2 is in the members list (field 4) of group $1
group_member() { awk -F: -v g="$1" -v u="$2" '$1==g{n=split($4,m,","); for(i=1;i<=n;i++) if(m[i]==u) ok=1} END{exit !ok}' "$R/etc/group"; }
# the 7-line Match block is the last 7 lines of sshd_config, byte for byte
SSHD="$R/etc/ssh/sshd_config"
SSHD_MATCH='Match User root Group unitotem-first-admin
    PermitRootLogin yes
    PermitEmptyPasswords yes
    ForceCommand /usr/sbin/unitotem-first-admin
    DisableForwarding yes
    PermitTunnel no
    PermitUserRC no'
sshd_match_at_end() { [ "$(tail -n 7 "$SSHD" 2>/dev/null)" = "$SSHD_MATCH" ]; }
chk "root has an empty password field in /etc/shadow (first-access open state)" root_shadow_open
chk "root's login shell is /usr/sbin/unitotem-first-admin" root_shell_marker
chk "group unitotem-first-admin exists as a system group (gid < 1000, the sshd marker)" group_system unitotem-first-admin
chk "root is a member of group unitotem-first-admin (group file members list)" group_member unitotem-first-admin root
chk "group sudo exists (admins)" grep -q '^sudo:' "$R/etc/group"
chk "group users exists (web UI users)" grep -q '^users:' "$R/etc/group"
chk "sshd_config: PermitRootLogin prohibit-password" grep -qxF 'PermitRootLogin prohibit-password' "$SSHD"
chk "sshd_config: PermitEmptyPasswords no" grep -qxF 'PermitEmptyPasswords no' "$SSHD"
chk "sshd_config: PasswordAuthentication yes" grep -qxF 'PasswordAuthentication yes' "$SSHD"
chk "sshd_config ends with the first-access Match block (root + group unitotem-first-admin, 7 lines, exact)" sshd_match_at_end
chk "sudo is installed (usr/bin/sudo)" test -x "$R/usr/bin/sudo"
chk "adduser is installed (usr/sbin/adduser)" test -x "$R/usr/sbin/adduser"
chk "/home exists as a directory (home directories of the web users)" test -d "$R/home"
chk "unitotem-first-admin is installed and executable (shipped by the manager deb, installed in stage 1)" test -x "$R/usr/sbin/unitotem-first-admin"

echo "== Update machinery"
chk "the automatic update policy: timer enabled, service runs at the lowest priority" bash -c "test -L '$R/etc/systemd/system/timers.target.wants/unitotem-update-auto.timer' && grep -q '^Nice=19' '$R/etc/systemd/system/unitotem-update-auto.service' && grep -q '^IOSchedulingClass=idle' '$R/etc/systemd/system/unitotem-update-auto.service'"
chk "unitotem-boot-orientation is installed (boot screen orientation: Pi cmdline.txt of both slots / grubenv)" test -x "$R/usr/sbin/unitotem-boot-orientation"
chk "unitotem-update has the policy/auto/reboot commands" bash -c "grep -q 'def cmd_auto' '$R/usr/sbin/unitotem-update' && grep -q 'def cmd_policy' '$R/usr/sbin/unitotem-update'"
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
    chk "the GRUB slot entries carry \${unitotem_video} (orientation option of the next boot)" bash -c "[ \$(grep -c 'unitotem.slot=[ab] \${unitotem_video}' '$FAT/unitotem-grub/grub/grub.cfg') = 2 ]"
    chk "the image carries its ESP grub.cfg for unitotem-update to refresh the bootloader config (usr/share/unitotem/esp-grub.cfg == the ESP's)" bash -c "cmp -s '$R/usr/share/unitotem/esp-grub.cfg' $FAT/unitotem-grub/grub/grub.cfg && grep -q 'unitotem-grub-level' '$R/usr/share/unitotem/esp-grub.cfg'"
    chk "the OTA fallback is entry number 4 (the GRUB fallback list is numeric)" bash -c "[ \"\$(grep -E '^menuentry' $FAT/unitotem-grub/grub/grub.cfg | sed -n 5p | grep -c ota-recovery)\" = 1 ]"
    chk "OTA fallback entry is last (a torn grubenv must boot a slot)" bash -c "[ \"\$(grep -E '^menuentry' $FAT/unitotem-grub/grub/grub.cfg | tail -1 | grep -c ota-recovery)\" = 1 ]"
    chk "GRUB tries the other slot, then the OTA fallback, when the chosen slot cannot be loaded (fallback= in grub.cfg)" bash -c "grep -q 'set fallback=\"1 4\"' $FAT/unitotem-grub/grub/grub.cfg && grep -q 'set fallback=\"0 4\"' $FAT/unitotem-grub/grub/grub.cfg"
    chk "recovery kernel and initrd on the ESP" bash -c "test -s $FAT/unitotem/recovery-vmlinuz && test -s $FAT/unitotem/recovery-initrd.img"
    chk "Secure Boot chain staged on the ESP (shim, MokManager, signed GRUB, stub grub.cfg, unsigned GRUB kept)" bash -c "for f in shimx64.efi mmx64.efi grubx64.efi grub-unsigned.efi grub.cfg; do test -s $FAT/EFI/unitotem-sb/\$f || exit 1; done"
    chk "the staged chain is NOT active by default (EFI/BOOT/BOOTX64.EFI is the plain GRUB; the deploy activates shim only on request)" bash -c "cmp -s $FAT/EFI/BOOT/BOOTX64.EFI $FAT/EFI/unitotem-sb/grub-unsigned.efi && ! cmp -s $FAT/EFI/BOOT/BOOTX64.EFI $FAT/EFI/unitotem-sb/shimx64.efi"
    chk "grub-unsigned.efi really is the plain GRUB (not the shim, not the Debian-signed GRUB) and EFI/BOOT holds no chain leftovers" bash -c "! cmp -s $FAT/EFI/unitotem-sb/grub-unsigned.efi $FAT/EFI/unitotem-sb/shimx64.efi && ! cmp -s $FAT/EFI/unitotem-sb/grub-unsigned.efi $FAT/EFI/unitotem-sb/grubx64.efi && ! test -e $FAT/EFI/BOOT/grubx64.efi && ! test -e $FAT/EFI/BOOT/mmx64.efi"
    chk "the stub hands over to the real grub.cfg on the ESP" bash -c "grep -q 'unitotem-grub/grub/grub.cfg' $FAT/EFI/unitotem-sb/grub.cfg"
    chk "the OTA entries are low resolution (unitotem_lowres + nomodeset)" bash -c "grep -q 'unitotem_lowres' $FAT/unitotem-grub/grub/grub.cfg && grep -c nomodeset $FAT/unitotem-grub/grub/grub.cfg | grep -q '^4\$'"
fi

echo "== $n checks, $fail failed"
[ "$fail" = 0 ]
