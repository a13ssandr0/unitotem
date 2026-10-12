#!/bin/bash
# UniTotem Kiosk System Installer
# Text-based TUI installer: collects configuration, then installs everything at once.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TERM=linux

KIOSK_FILES=/usr/local/share/unitotem/files

# ======================================================================
# Boot mode detection (shown immediately on start)
# ======================================================================
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="BIOS"
fi

clear
printf '\033[1;34m'
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │         UniTotem Kiosk System Installer             │"
echo "  └─────────────────────────────────────────────────────┘"
printf '\033[0m'
echo ""
printf "  Boot mode detected: \033[1;32m%s\033[0m\n" "$BOOT_MODE"
echo ""
echo "  This installer will ask a few questions, then download"
echo "  and install the UniTotem Kiosk system on the selected disk."
echo ""
read -rp "  Press ENTER to begin configuration..." _

# ======================================================================
# TUI helpers
# ======================================================================
_menu() {
    local title="$1"; local prompt="$2"; shift 2
    whiptail --title "UniTotem Installer ─ $title" \
             --menu "$prompt" 22 72 12 "$@" \
             3>&1 1>&2 2>&3
}
_input() {
    local title="$1"; local prompt="$2"; local default="${3:-}"
    whiptail --title "UniTotem Installer ─ $title" \
             --inputbox "$prompt" 10 64 "$default" \
             3>&1 1>&2 2>&3
}
_password() {
    local title="$1"; local prompt="$2"
    whiptail --title "UniTotem Installer ─ $title" \
             --passwordbox "$prompt" 10 64 \
             3>&1 1>&2 2>&3
}
_yesno() {
    local title="$1"; local prompt="$2"
    whiptail --title "UniTotem Installer ─ $title" \
             --yesno "$prompt" 12 64
}
_msg() {
    local title="$1"; local prompt="$2"
    whiptail --title "UniTotem Installer ─ $title" \
             --msgbox "$prompt" 12 64
}

cancelled() { clear; echo "Installation cancelled."; exit 0; }

# ======================================================================
# Step 1: Language
# ======================================================================
LOCALE=$(_menu "Language" "Select system language:" \
    "it_IT.UTF-8" "Italian / Italiano" \
    "en_US.UTF-8" "English (United States)" \
    "en_GB.UTF-8" "English (United Kingdom)" \
    "de_DE.UTF-8" "German / Deutsch" \
    "fr_FR.UTF-8" "French / Français" \
    "es_ES.UTF-8" "Spanish / Español" \
    "pt_PT.UTF-8" "Portuguese / Português" \
    "pt_BR.UTF-8" "Brazilian Portuguese" \
    "nl_NL.UTF-8" "Dutch / Nederlands" \
    "pl_PL.UTF-8" "Polish / Polski" \
    "ru_RU.UTF-8" "Russian / Русский" \
    "zh_CN.UTF-8" "Chinese Simplified / 简体中文" \
    "ja_JP.UTF-8" "Japanese / 日本語" \
) || cancelled

# ======================================================================
# Step 2: Keyboard layout
# ======================================================================
KEYMAP=$(_menu "Keyboard Layout" "Select keyboard layout:" \
    "it"       "Italian" \
    "us"       "English (US)" \
    "gb"       "English (UK)" \
    "de"       "German" \
    "fr"       "French" \
    "es"       "Spanish" \
    "pt"       "Portuguese" \
    "br-abnt2" "Brazilian Portuguese" \
    "nl"       "Dutch" \
    "pl"       "Polish" \
    "ru"       "Russian" \
    "dvorak"   "Dvorak (US)" \
) || cancelled

# Apply keyboard immediately so the user can type with the right layout
loadkeys "$KEYMAP" 2>/dev/null || true

# ======================================================================
# Step 3: Timezone
# ======================================================================
TIMEZONE=$(_menu "Timezone" "Select timezone:" \
    "Europe/Rome"         "Italy (Rome)" \
    "Europe/London"       "UK (London)" \
    "Europe/Paris"        "France (Paris)" \
    "Europe/Berlin"       "Germany (Berlin)" \
    "Europe/Madrid"       "Spain (Madrid)" \
    "Europe/Lisbon"       "Portugal (Lisbon)" \
    "Europe/Amsterdam"    "Netherlands (Amsterdam)" \
    "Europe/Brussels"     "Belgium (Brussels)" \
    "Europe/Warsaw"       "Poland (Warsaw)" \
    "Europe/Moscow"       "Russia (Moscow)" \
    "Europe/Istanbul"     "Turkey (Istanbul)" \
    "America/New_York"    "USA Eastern (New York)" \
    "America/Chicago"     "USA Central (Chicago)" \
    "America/Denver"      "USA Mountain (Denver)" \
    "America/Los_Angeles" "USA Pacific (Los Angeles)" \
    "America/Sao_Paulo"   "Brazil (São Paulo)" \
    "Asia/Tokyo"          "Japan (Tokyo)" \
    "Asia/Shanghai"       "China (Shanghai)" \
    "Asia/Singapore"      "Singapore" \
    "Asia/Dubai"          "UAE (Dubai)" \
    "Asia/Kolkata"        "India (Kolkata)" \
    "Australia/Sydney"    "Australia (Sydney)" \
    "UTC"                 "UTC" \
) || cancelled

# ======================================================================
# Step 4: Network
# ======================================================================
NET_OK=false
while ! $NET_OK; do

    # Build interface list
    IFACE_MENU=()
    while read -r name state; do
        [ "$name" = "lo" ] && continue
        if [ -d "/sys/class/net/$name/wireless" ]; then
            kind="WiFi"
        else
            kind="Wired"
        fi
        IFACE_MENU+=("$name" "[$kind] $state")
    done < <(ip -br link show | awk '{print $1, tolower($2)}' | grep -v '^lo ')

    if [ ${#IFACE_MENU[@]} -eq 0 ]; then
        _msg "Network" "No network interfaces found.\nPlease check your hardware."
        cancelled
    fi

    IFACE=$(_menu "Network" "Select network interface to configure:" \
        "${IFACE_MENU[@]}") || cancelled

    if [ -d "/sys/class/net/$IFACE/wireless" ]; then
        # ---------- WiFi ----------
        _msg "Network" "Scanning for WiFi networks on $IFACE…\n(may take a few seconds)"
        ip link set "$IFACE" up 2>/dev/null || true
        sleep 3

        mapfile -t SSID_LIST < <(
            iw dev "$IFACE" scan 2>/dev/null \
            | grep 'SSID:' \
            | sed 's/.*SSID: //' \
            | grep -v '^$' \
            | sort -u \
            | head -20
        )

        SSID_MENU=("(manual)" "Enter SSID manually")
        for ssid in "${SSID_LIST[@]}"; do
            SSID_MENU+=("$ssid" "")
        done

        SSID=$(_menu "WiFi" "Select network:" "${SSID_MENU[@]}") || cancelled

        if [ "$SSID" = "(manual)" ]; then
            SSID=$(_input "WiFi" "Enter SSID:") || cancelled
        fi

        WIFI_PASS=$(_password "WiFi" "Password for '$SSID':") || cancelled

        # Kill any existing wpa_supplicant
        pkill -x wpa_supplicant 2>/dev/null || true
        sleep 1
        wpa_passphrase "$SSID" "$WIFI_PASS" > /tmp/wpa.conf
        wpa_supplicant -B -i "$IFACE" -c /tmp/wpa.conf -P /var/run/wpa_supplicant.pid
        dhcpcd "$IFACE" 2>/dev/null || true

    else
        # ---------- Wired ----------
        NET_TYPE=$(_menu "Network" "Connection type for $IFACE:" \
            "dhcp"   "Automatic (DHCP) — recommended" \
            "static" "Manual (static IP)") || cancelled

        if [ "$NET_TYPE" = "dhcp" ]; then
            ip link set "$IFACE" up 2>/dev/null || true
            dhcpcd "$IFACE" 2>/dev/null || true
        else
            IP=$(_input   "Network" "IP address with prefix  (e.g. 192.168.1.100/24):" "") || cancelled
            GW=$(_input   "Network" "Default gateway         (e.g. 192.168.1.1):" "")       || cancelled
            DNS=$(_input  "Network" "DNS server:" "8.8.8.8")                                || cancelled

            ip addr flush dev "$IFACE" 2>/dev/null || true
            ip addr add "$IP" dev "$IFACE"
            ip link set "$IFACE" up
            ip route add default via "$GW" 2>/dev/null || true
            echo "nameserver $DNS" > /etc/resolv.conf
        fi
    fi

    # Test connectivity
    if ping -c 2 -W 8 8.8.8.8 >/dev/null 2>&1; then
        _msg "Network" "Internet connectivity: OK ✓"
        NET_OK=true
    else
        _yesno "Network" "No internet connectivity detected.\n\nDo you want to reconfigure the network?" \
            && NET_OK=false || cancelled
    fi
done

# ======================================================================
# Step 5: Disk selection
# ======================================================================
DISK_MENU=()
while read -r name size model; do
    [[ "$name" =~ ^(loop|sr|fd|ram) ]] && continue
    DISK_MENU+=("/dev/$name" "${size}  ${model}")
done < <(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null)

if [ ${#DISK_MENU[@]} -eq 0 ]; then
    _msg "Disk" "No suitable disks found."
    exit 1
fi

DISK=$(_menu "Disk Selection" \
    "⚠  WARNING: ALL DATA ON THE SELECTED DISK WILL BE ERASED  ⚠\n\nSelect installation target:" \
    "${DISK_MENU[@]}") || cancelled

DISK_INFO=$(lsblk -d -n -o SIZE,MODEL "$DISK" | head -1 | xargs)

# Partition suffix helper: /dev/sda → 1,2,3; /dev/nvme0n1 → p1,p2,p3
pdev() { [[ "$DISK" =~ (nvme|mmcblk) ]] && echo "${DISK}p${1}" || echo "${DISK}${1}"; }

# ======================================================================
# Step 6: Hostname and root password
# ======================================================================
HOSTNAME=$(_input "System" "Hostname for this system:" "unitotem") || cancelled
while true; do
    ROOTPW=$(_password  "System" "Root password:") || cancelled
    ROOTPW2=$(_password "System" "Confirm root password:") || cancelled
    [ "$ROOTPW" = "$ROOTPW2" ] && break
    _msg "Error" "Passwords do not match. Please try again."
done

# ======================================================================
# Confirmation screen
# ======================================================================
whiptail --title "UniTotem Installer ─ Confirm" --yesno \
"Review your choices before installation begins:

  Boot mode : $BOOT_MODE
  Language  : $LOCALE
  Keyboard  : $KEYMAP
  Timezone  : $TIMEZONE
  Network   : $IFACE
  Disk      : $DISK  ($DISK_INFO)
  Hostname  : $HOSTNAME

⚠  ALL DATA ON $DISK WILL BE PERMANENTLY ERASED  ⚠

Proceed with installation?" 22 66 || cancelled

# ======================================================================
# INSTALLATION — all steps in sequence, progress shown as text
# ======================================================================
TARGET=/mnt
RELEASE=bookworm
MIRROR=http://deb.debian.org/debian

_step() {
    echo ""
    printf '\033[1;34m>>> %s\033[0m\n' "$*"
}
_ok()   { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
_info() { printf '\033[0;37m    %s\033[0m\n' "$*"; }

clear
echo ""
printf '\033[1;34m'
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │         Installing UniTotem Kiosk System            │"
echo "  │   Do not power off the machine during installation  │"
echo "  └─────────────────────────────────────────────────────┘"
printf '\033[0m'
echo ""
_info "Boot mode : $BOOT_MODE"
_info "Target    : $DISK  ($DISK_INFO)"
echo ""

# Cleanup trap
cleanup() {
    umount -lf "$TARGET/dev"              2>/dev/null || true
    umount -lf "$TARGET/sys/firmware/efi" 2>/dev/null || true
    umount -lf "$TARGET/sys"              2>/dev/null || true
    umount -lf "$TARGET/proc"             2>/dev/null || true
    umount -lf "$TARGET/mnt/data"         2>/dev/null || true
    [ "$BOOT_MODE" = "UEFI" ] && umount -lf "$TARGET/boot/efi" 2>/dev/null || true
    umount -lf "$TARGET/boot"             2>/dev/null || true
    umount -lf "$TARGET"                  2>/dev/null || true
}
trap cleanup EXIT

# ---- 1/10: Partition ------------------------------------------------
_step "[1/10] Partitioning $DISK…"
wipefs -af "$DISK"
sgdisk -Z "$DISK"
if [ "$BOOT_MODE" = "UEFI" ]; then
    sgdisk -n "1:0:+512M"  -t 1:ef00 -c 1:EFI      "$DISK"
    sgdisk -n "2:0:+1G"    -t 2:8300 -c 2:BOOT     "$DISK"
    sgdisk -n "3:0:+10G"   -t 3:8300 -c 3:ROOT     "$DISK"
    sgdisk -n "4:0:0"      -t 4:8300 -c 4:DATA     "$DISK"
else
    # GPT + 1 MB BIOS boot partition (no filesystem, GRUB embeds core.img here)
    sgdisk -n "1:0:+1M"    -t 1:ef02 -c 1:BIOS_BOOT "$DISK"
    sgdisk -n "2:0:+1G"    -t 2:8300 -c 2:BOOT      "$DISK"
    sgdisk -n "3:0:+10G"   -t 3:8300 -c 3:ROOT      "$DISK"
    sgdisk -n "4:0:0"      -t 4:8300 -c 4:DATA      "$DISK"
fi
partprobe "$DISK" 2>/dev/null || true
sleep 2
_ok "Partitioned"

# ---- 2/10: Format ---------------------------------------------------
_step "[2/10] Formatting partitions…"
if [ "$BOOT_MODE" = "UEFI" ]; then
    mkfs.fat -F32 -n EFI         "$(pdev 1)"
    mkfs.ext4 -F  -L BOOT        "$(pdev 2)"
    mkfs.ext4 -F  -L ROOT        "$(pdev 3)"
    mkfs.ext4 -F  -L DATA -O ^has_journal "$(pdev 4)"
else
    # p1 is the BIOS boot partition — no filesystem
    mkfs.ext4 -F  -L BOOT        "$(pdev 2)"
    mkfs.ext4 -F  -L ROOT        "$(pdev 3)"
    mkfs.ext4 -F  -L DATA -O ^has_journal "$(pdev 4)"
fi
_ok "Formatted"

# ---- 3/10: Mount ----------------------------------------------------
_step "[3/10] Mounting target…"
mount "$(pdev 3)" "$TARGET"
mkdir -p "$TARGET/boot"
mount "$(pdev 2)" "$TARGET/boot"
if [ "$BOOT_MODE" = "UEFI" ]; then
    mkdir -p "$TARGET/boot/efi"
    mount "$(pdev 1)" "$TARGET/boot/efi"
fi
mkdir -p "$TARGET/mnt/data"
mount "$(pdev 4)" "$TARGET/mnt/data"
_ok "Mounted"

# ---- 4/10: Bootstrap ------------------------------------------------
_step "[4/10] Bootstrapping base system (downloads ~80 MB)…"
debootstrap --arch=amd64 \
    --include=systemd,systemd-sysv,udev,dbus \
    "$RELEASE" "$TARGET" "$MIRROR"
_ok "Bootstrap complete"

# Bind-mount kernel interfaces into chroot
mount --bind /dev  "$TARGET/dev"
mount --bind /proc "$TARGET/proc"
mount --bind /sys  "$TARGET/sys"

# Prevent service starts during package installation
echo -e '#!/bin/sh\nexit 101' > "$TARGET/usr/sbin/policy-rc.d"
chmod +x "$TARGET/usr/sbin/policy-rc.d"

# ---- 5/10: APT sources + kernel + bootloader ------------------------
_step "[5/10] Configuring APT and installing kernel + bootloader…"

cat > "$TARGET/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian $RELEASE main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
EOF

# UniTotem Manager repository
curl -fsSL https://a13ssandr0.github.io/unitotem-manager/KEY.gpg \
    > "$TARGET/etc/apt/trusted.gpg.d/unitotem-manager.asc"
curl -fsSL https://a13ssandr0.github.io/unitotem-manager/unitotem-manager.list \
    > "$TARGET/etc/apt/sources.list.d/unitotem-manager.list"

chroot "$TARGET" apt-get update -q

if [ "$BOOT_MODE" = "UEFI" ]; then
    chroot "$TARGET" apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
        grub-efi-amd64 efibootmgr
else
    chroot "$TARGET" apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
        grub-pc
fi
_ok "Kernel and bootloader installed"

# ---- 6/10: Base system + display stack ------------------------------
_step "[6/10] Installing base system and display stack…"

chroot "$TARGET" apt-get install -y \
    locales sudo curl wget ca-certificates gnupg2 \
    openssh-server \
    iproute2 iputils-ping net-tools \
    htop nano less \
    util-linux e2fsprogs \
    lsb-release initramfs-tools apt-utils \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    network-manager netplan.io \
    python3 python3-dbus python3-gi python3-pyudev \
    gir1.2-glib-2.0 \
    iptables \
    plymouth plymouth-themes plymouth-label libplymouth5

chroot "$TARGET" apt-get install -y \
    libglvnd0 libglx0 libgles2 libvulkan1 mesa-utils libgl1-mesa-dri

chroot "$TARGET" apt-get install -y \
    intel-media-va-driver-non-free i965-va-driver-shaders \
    libva2 libva-drm2 vainfo \
    mesa-vulkan-drivers firmware-amd-graphics mesa-va-drivers libdrm-amdgpu1

_ok "Base system installed"

# ---- 7/10: Display stack + multimedia -------------------------------
# No window manager: unitotem-manager's own Qt6+CEF viewer already sets its
# window to exact fullscreen geometry with no decorations, and CEF only
# supports X11 embedding - a bare Xorg session is both sufficient and simpler
# (mirrors kiosk/stage1-packages.sh's "X11 + PipeWire" block).
_step "[7/10] Installing Xorg, PipeWire, Chromium…"

chroot "$TARGET" apt-get install -y \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth

chroot "$TARGET" apt-get install -y \
    chromium chromium-sandbox ffmpeg

_ok "Desktop environment installed"

# ---- 8/10: UniTotem packages ----------------------------------------
_step "[8/10] Installing UniTotem packages…"

chroot "$TARGET" apt-get install -y \
    python3-pip python3-apt python3-venv \
    libopenjp2-7-dev openssl mediainfo haproxy rfkill alsa-utils

chroot "$TARGET" apt-get install -y unitotem-manager

_ok "UniTotem packages installed"

# ---- 9/10: System configuration -------------------------------------
_step "[9/10] Configuring system…"

# Hostname
echo "$HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Locale
sed -i "s/# ${LOCALE} UTF-8/${LOCALE} UTF-8/" "$TARGET/etc/locale.gen"
chroot "$TARGET" locale-gen
echo "LANG=${LOCALE}" > "$TARGET/etc/locale.conf"

# Keyboard (console + X11)
echo "KEYMAP=${KEYMAP}" > "$TARGET/etc/vconsole.conf"
XKBLAYOUT="${KEYMAP%%-*}"
mkdir -p "$TARGET/etc/X11/xorg.conf.d"
cat > "$TARGET/etc/X11/xorg.conf.d/00-keyboard.conf" << EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${XKBLAYOUT}"
EndSection
EOF

# Timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
chroot "$TARGET" dpkg-reconfigure -f noninteractive tzdata

# Root password
chroot "$TARGET" bash -c "echo 'root:${ROOTPW}' | chpasswd"

# SSH
install -m 644 "$KIOSK_FILES/sshd_config" "$TARGET/etc/ssh/sshd_config"
mkdir -p "$TARGET/root/.ssh"
chmod 700 "$TARGET/root/.ssh"

# fstab
if [ "$BOOT_MODE" = "UEFI" ]; then
    install -m 644 "$KIOSK_FILES/fstab-amd64" "$TARGET/etc/fstab"
else
    # BIOS: no EFI partition
    cat > "$TARGET/etc/fstab" << 'EOF'
LABEL=BOOT   /boot       ext4   defaults              0 2
LABEL=ROOT   /           ext4   ro                    0 1
LABEL=DATA   /mnt/data   ext4   defaults,noatime      0 2
tmpfs        /tmp        tmpfs  defaults,nosuid,nodev 0 0
EOF
fi

# NetworkManager / netplan
mkdir -p "$TARGET/etc/netplan"
cat > "$TARGET/etc/netplan/00-default.yaml" << 'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 "$TARGET/etc/netplan/00-default.yaml"

# Plymouth
# No theme is installed/pinned here: the unitotem-manager package installs
# and selects the real "unitotem" theme (via update-alternatives AND
# plymouth-set-default-theme, since plymouthd.conf's Theme= key takes
# priority over the default.plymouth alternative - see
# src/main.c:load_settings()/show_default_splash() upstream) when it's
# installed on top of this image. Pinning a placeholder theme here would
# leave plymouthd.conf's Theme= key pointing at it, which the manager's
# update-alternatives call alone cannot override.
mkdir -p "$TARGET/etc/plymouth"
install -m 644 "$KIOSK_FILES/plymouthd.conf" "$TARGET/etc/plymouth/plymouthd.conf"

# GRUB config
install -m 644 "$KIOSK_FILES/grub-default" "$TARGET/etc/default/grub"

# Kiosk config (X11, no window manager)
mkdir -p "$TARGET/etc/kiosk"
install -m 644 "$KIOSK_FILES/chromium-flags-amd64"   "$TARGET/etc/kiosk/chromium-flags"
cat > "$TARGET/usr/local/bin/chromium-kiosk" << 'SCRIPT'
#!/bin/bash
FLAGS=$(grep -v '^#' /etc/kiosk/chromium-flags | tr '\n' ' ')
exec /usr/bin/chromium $FLAGS "$@"
SCRIPT
chmod +x "$TARGET/usr/local/bin/chromium-kiosk"
install -m 755 "$KIOSK_FILES/kiosk-update"               "$TARGET/usr/local/bin/kiosk-update"

# X session: started as a proper systemd service (not autologin +
# .bash_profile, which is tied to a getty/PAM login session's lifecycle and
# proved fragile). Same unit used by the image build, see
# kiosk/stage2-configure.sh.
install -m 644 "$KIOSK_FILES/start-xorg.service" \
    "$TARGET/etc/systemd/system/start-xorg.service"

# OverlayFS initramfs hook
install -m 755 "$KIOSK_FILES/overlayfs-hook.sh" \
    "$TARGET/etc/initramfs-tools/scripts/init-bottom/setup-overlays"
echo "overlay" >> "$TARGET/etc/initramfs-tools/modules"
echo "FRAMEBUFFER=y" >> "$TARGET/etc/initramfs-tools/initramfs.conf"

# Firewall
install -m 644 "$KIOSK_FILES/iptables-firewall.service" \
    "$TARGET/etc/systemd/system/iptables-firewall.service"
install -m 750 "$KIOSK_FILES/iptables-firewall.sh" \
    "$TARGET/sbin/iptables-firewall.sh"
install -m 644 "$KIOSK_FILES/kiosk-update-mode.service" \
    "$TARGET/etc/systemd/system/kiosk-update-mode.service"

# Journald / sysctl / udev
mkdir -p "$TARGET/etc/systemd/journald.conf.d"
install -m 644 "$KIOSK_FILES/journald.conf" \
    "$TARGET/etc/systemd/journald.conf.d/kiosk.conf"
install -m 644 "$KIOSK_FILES/scheduler.rules" \
    "$TARGET/etc/udev/rules.d/60-scheduler.rules"
cat >> "$TARGET/etc/sysctl.conf" << 'EOF'
vm.dirty_writeback_centisecs = 3000
vm.dirty_expire_centisecs    = 3000
vm.dirty_ratio               = 5
vm.dirty_background_ratio    = 2
EOF
echo 'FSCKFIX=yes' >> "$TARGET/etc/default/rcS"

# PipeWire user services
mkdir -p "$TARGET/root/.config/systemd/user/default.target.wants"
for svc in pipewire pipewire-pulse wireplumber; do
    ln -sf "/usr/lib/systemd/user/${svc}.service" \
        "$TARGET/root/.config/systemd/user/default.target.wants/${svc}.service"
done

# Enable services
chroot "$TARGET" systemctl enable \
    systemd-timesyncd NetworkManager dbus ssh \
    iptables-firewall kiosk-update-mode start-xorg

# Rebuild initramfs
chroot "$TARGET" update-initramfs -u -k all

chroot "$TARGET" apt-get clean
rm -rf "$TARGET/var/lib/apt/lists/"*
rm -f  "$TARGET/usr/sbin/policy-rc.d"

_ok "System configured"

# ---- 10/10: Bootloader ----------------------------------------------
_step "[10/10] Installing bootloader ($BOOT_MODE)…"

if [ "$BOOT_MODE" = "UEFI" ]; then
    chroot "$TARGET" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --boot-directory=/boot \
        --bootloader-id=unitotem \
        --no-nvram \
        --removable
else
    chroot "$TARGET" grub-install \
        --target=i386-pc \
        "$DISK"
fi
chroot "$TARGET" update-grub
_ok "Bootloader installed"

# ---- Unmount --------------------------------------------------------
trap - EXIT
_step "Finalizing…"
sync
umount -lf "$TARGET/dev"              2>/dev/null || true
umount -lf "$TARGET/sys/firmware/efi" 2>/dev/null || true
umount -lf "$TARGET/sys"              2>/dev/null || true
umount -lf "$TARGET/proc"             2>/dev/null || true
umount -lf "$TARGET/mnt/data"         2>/dev/null || true
[ "$BOOT_MODE" = "UEFI" ] && umount -lf "$TARGET/boot/efi" 2>/dev/null || true
umount -lf "$TARGET/boot"             2>/dev/null || true
umount -lf "$TARGET"                  2>/dev/null || true
sync

# ======================================================================
# Done
# ======================================================================
clear
printf '\033[1;32m'
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │            Installation Complete!                   │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │                                                     │"
echo "  │   UniTotem Kiosk has been successfully installed.   │"
printf "  │   Disk: %-44s│\n" "$DISK  ($DISK_INFO)"
printf "  │   Mode: %-44s│\n" "$BOOT_MODE"
echo "  │                                                     │"
echo "  │   Please REMOVE the installation media, then        │"
echo "  │   press ENTER to reboot into your new system.       │"
echo "  │                                                     │"
echo "  └─────────────────────────────────────────────────────┘"
printf '\033[0m'
echo ""
read -rp "  Press ENTER to reboot..." _
reboot
