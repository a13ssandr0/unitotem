# Debian Minimale Kiosk — root-only — amd64 / arm64 (Raspberry Pi 4/5)
Debian 12 Bookworm

---

## 0. Variabili globali

```bash
ARCH=amd64

DISK=/dev/sda          # SSD/NVMe amd64
# DISK=/dev/mmcblk0   # SD card Raspberry Pi
# DISK=/dev/sda       # USB boot Raspberry Pi

TARGET=/mnt/target

LABEL_ROOT=ROOT
LABEL_DATA=DATA
LABEL_LOG=LOG           # solo Opzione B
```

---

## 1. Partizionamento

### 1A. amd64 — UEFI

#### Opzione A: log in /data
```bash
sgdisk -Z $DISK
sgdisk -n 1:0:+512M  -t 1:ef00 -c 1:EFI   $DISK
sgdisk -n 2:0:+1G    -t 2:8300 -c 2:BOOT  $DISK
sgdisk -n 3:0:+10G   -t 3:8300 -c 3:ROOT  $DISK
sgdisk -n 4:0:0      -t 4:8300 -c 4:DATA  $DISK
partprobe $DISK
```

#### Opzione B: partizione log separata
```bash
sgdisk -Z $DISK
sgdisk -n 1:0:+512M  -t 1:ef00 -c 1:EFI   $DISK
sgdisk -n 2:0:+1G    -t 2:8300 -c 2:BOOT  $DISK
sgdisk -n 3:0:+10G   -t 3:8300 -c 3:ROOT  $DISK
sgdisk -n 4:0:-4G    -t 4:8300 -c 4:DATA  $DISK
sgdisk -n 5:0:0      -t 5:8300 -c 5:LOG   $DISK
partprobe $DISK
```

### 1B. arm64 — Raspberry Pi 4/5

#### Opzione A
```bash
parted -s $DISK mklabel gpt
parted -s $DISK mkpart FIRMWARE fat32  1M    512M
parted -s $DISK mkpart ROOT     ext4   512M  10.5G
parted -s $DISK mkpart DATA     ext4   10.5G 100%
partprobe $DISK
```

#### Opzione B
```bash
parted -s $DISK mklabel gpt
parted -s $DISK mkpart FIRMWARE fat32  1M    512M
parted -s $DISK mkpart ROOT     ext4   512M  10.5G
parted -s $DISK mkpart DATA     ext4   10.5G -4G
parted -s $DISK mkpart LOG      ext4   -4G   100%
partprobe $DISK
```

---

## 2. Formattazione

### amd64
```bash
mkfs.fat  -F32 -n EFI  ${DISK}1
mkfs.ext4 -L BOOT      ${DISK}2
mkfs.ext4 -L ROOT      ${DISK}3
mkfs.ext4 -L DATA -O ^has_journal ${DISK}4
# Opzione B:
mkfs.ext4 -L LOG       ${DISK}5
```

### arm64/Pi
```bash
mkfs.fat  -F32 -n FIRMWARE ${DISK}p1
mkfs.ext4 -L ROOT          ${DISK}p2
mkfs.ext4 -L DATA -O ^has_journal ${DISK}p3
# Opzione B:
mkfs.ext4 -L LOG           ${DISK}p4
```

---

## 3. Mount e bootstrap

```bash
mkdir -p $TARGET

# amd64
mount -L ROOT $TARGET
mkdir -p $TARGET/{boot,boot/efi}
mount -L BOOT $TARGET/boot
mount -L EFI  $TARGET/boot/efi

# arm64/Pi
# mount -L ROOT $TARGET
# mkdir -p $TARGET/boot/firmware
# mount -L FIRMWARE $TARGET/boot/firmware

mkdir -p $TARGET/mnt/data
mount -L DATA $TARGET/mnt/data

# Opzione B:
mkdir -p $TARGET/var/log
mount -L LOG $TARGET/var/log
```

```bash
apt-get install -y debootstrap

# amd64 nativo
debootstrap --arch=amd64 --include=systemd,systemd-sysv,udev,dbus \
    bookworm $TARGET https://deb.debian.org/debian

# arm64 nativo (sul Pi)
# debootstrap --arch=arm64 --include=systemd,systemd-sysv,udev,dbus \
#     bookworm $TARGET https://deb.debian.org/debian

# arm64 cross (su host amd64)
# apt install qemu-user-static
# debootstrap --arch=arm64 --foreign --include=systemd,systemd-sysv,udev,dbus \
#     bookworm $TARGET https://deb.debian.org/debian
# cp /usr/bin/qemu-aarch64-static $TARGET/usr/bin/
# chroot $TARGET /debootstrap/debootstrap --second-stage
```

---

## 4. Preparazione chroot

```bash
mount --bind /dev     $TARGET/dev
mount --bind /dev/pts $TARGET/dev/pts
mount --bind /proc    $TARGET/proc
mount --bind /sys     $TARGET/sys
mount --bind /run     $TARGET/run
cp /etc/resolv.conf $TARGET/etc/resolv.conf

chroot $TARGET /bin/bash
```

---

## 5. Configurazione base

```bash
echo "kiosk" > /etc/hostname
echo "127.0.1.1 kiosk" >> /etc/hosts

apt-get install -y locales
sed -i 's/# it_IT.UTF-8/it_IT.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=it_IT.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime

# Imposta la password di root usata per SSH
# L'autologin su tty1 ignora la password; SSH la richiede
echo "root:CAMBIA_QUESTA_PASSWORD" | chpasswd
# oppure interattivo: passwd root
```

---

## 6. SSH

```bash
apt-get install -y openssh-server

cat > /etc/ssh/sshd_config << 'EOF'
Port 22
Protocol 2

# Permette login root via SSH con password
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Sicurezza base
PermitEmptyPasswords no
MaxAuthTries 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Limita l'accesso alle sole funzioni necessarie
X11Forwarding no
AllowTcpForwarding no
PrintMotd no

# Opzionale: limitare l'accesso a una subnet di gestione
# AllowUsers root
# Match Address 192.168.1.0/24
#     AllowTcpForwarding yes
EOF

systemctl enable ssh

# Crea directory per chiavi autorizzate (autenticazione a chiave pubblica)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# Aggiungere la chiave pubblica di gestione:
# echo "ssh-ed25519 AAAA... admin@host" >> /root/.ssh/authorized_keys
# chmod 600 /root/.ssh/authorized_keys
```

---

## 7. Sorgenti APT e firmware

```bash
cat > /etc/apt/sources.list << 'EOF'
deb https://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb https://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

# Solo arm64/Pi
# cat >> /etc/apt/sources.list << 'EOF'
# deb http://archive.raspberrypi.org/debian/ bookworm main
# EOF
# curl -fsSL https://archive.raspberrypi.org/debian/raspberrypi.gpg.key \
#     | gpg --dearmor -o /etc/apt/trusted.gpg.d/raspberrypi.gpg

apt-get update
```

---

## 8. Kernel e bootloader

### amd64
```bash
apt-get install -y \
    linux-image-amd64 \
    firmware-linux \
    firmware-linux-nonfree \
    firmware-misc-nonfree \
    grub-efi-amd64 \
    efibootmgr

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian
# GRUB_CMDLINE aggiornato nella sezione Plymouth (sezione 9)
```

### arm64 — Raspberry Pi 4/5 — config.txt unificato

`config.txt` supporta filtri condizionali `[pi4]`, `[pi5]`, `[all]` nativamente.
Un singolo file funziona per entrambi i modelli senza script aggiuntivi.

```bash
apt-get install -y \
    linux-image-arm64 \
    firmware-brcm80211 \
    firmware-linux \
    firmware-linux-nonfree \
    raspberrypi-bootloader \
    raspi-firmware

cat > /boot/firmware/config.txt << 'EOF'
# Configurazioni comuni a tutti i modelli
[all]
arm_64bit=1
max_framebuffers=2
disable_splash=1
boot_delay=0

# Raspberry Pi 4: driver KMS vc4
[pi4]
dtoverlay=vc4-kms-v3d
dtparam=audio=on

# Raspberry Pi 5: driver KMS v3d-pi5
[pi5]
dtoverlay=vc4-kms-v3d-pi5
dtparam=audio=on

# Ripristina contesto [all] per configurazioni comuni successive
[all]
# Aggiungere qui ulteriori parametri comuni
EOF

# cmdline.txt aggiornato nella sezione Plymouth (sezione 9)
```

### Nota: condizionali in modprobe.d e initramfs/modules

`config.txt` è l'unico dei tre file a supportare la sintassi condizionale
`[pi4]`/`[pi5]` nativa. Gli altri due NON la supportano:

**modprobe.d**: nessuna sintassi condizionale. Includere entrambi i moduli è sicuro:
il kernel carica solo quello che corrisponde all'hardware rilevato dal device tree.
```bash
# /etc/modules-load.d/rpi-gpu.conf — entrambi, nessun conflitto
cat > /etc/modules-load.d/rpi-gpu.conf << 'EOF'
vc4
v3d
EOF
```

**initramfs modules**: stesso principio. Includere entrambi nella lista;
al boot viene inizializzato solo il driver compatibile con l'hardware presente.
```bash
cat >> /etc/initramfs-tools/modules << 'EOF'
vc4
v3d
EOF
```

Per chi volesse comunque caricare condizionalmente tramite udev (più pulito
ma non necessario):
```bash
cat > /etc/udev/rules.d/50-rpi-gpu.rules << 'EOF'
SUBSYSTEM=="platform", DRIVER=="vc4-drm", RUN+="/sbin/modprobe vc4"
SUBSYSTEM=="platform", DRIVER=="v3d",     RUN+="/sbin/modprobe v3d"
EOF
```

---

## 9. Plymouth — schermata di avvio

### 9.1 Installazione

```bash
apt-get install -y plymouth plymouth-themes libplymouth5 imagemagick
```

### 9.2 Tema personalizzato

```bash
mkdir -p /usr/share/plymouth/themes/kiosk

cat > /usr/share/plymouth/themes/kiosk/kiosk.plymouth << 'EOF'
[Plymouth Theme]
Name=Kiosk
Description=Kiosk boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/kiosk
ScriptFile=/usr/share/plymouth/themes/kiosk/kiosk.script
EOF
```

```bash
cat > /usr/share/plymouth/themes/kiosk/kiosk.script << 'EOF'
# --- Sfondo ---
Window.SetBackgroundTopColor   (0.05, 0.05, 0.08);
Window.SetBackgroundBottomColor(0.02, 0.02, 0.04);

# --- Logo (PNG 256x256 o 512x512, sostituire con il proprio) ---
logo_img = Image("logo.png");
logo_spr = Sprite(logo_img);
logo_spr.SetX(Window.GetWidth()  / 2 - logo_img.GetWidth()  / 2);
logo_spr.SetY(Window.GetHeight() / 2 - logo_img.GetHeight() / 2 - 40);
logo_spr.SetZ(10);

# --- Barra di progresso: sfondo ---
bar_w   = Math.Int(Window.GetWidth() * 0.38);
bar_bg  = Image.CreateFilledRoundedRectangle(bar_w, 5, 2, 0.14, 0.14, 0.18, 1.0);
bar_spr = Sprite(bar_bg);
bar_x   = Window.GetWidth() / 2 - bar_bg.GetWidth() / 2;
bar_y   = Window.GetHeight() / 2 + logo_img.GetHeight() / 2 + 28;
bar_spr.SetPosition(bar_x, bar_y, 10);

# --- Barra di progresso: riempimento ---
fill_spr = Sprite();
fill_spr.SetZ(11);

fun BootProgressCallback(duration, progress) {
    w = Math.Int(bar_w * progress);
    if (w < 2) { w = 2; }
    fill_spr.SetImage(
        Image.CreateFilledRoundedRectangle(w, 5, 2, 0.22, 0.52, 0.95, 1.0)
    );
    fill_spr.SetPosition(bar_x, bar_y, 11);
}
Plymouth.SetBootProgressFunction(BootProgressCallback);

# --- Riga stato servizi ---
# Riceve automaticamente da systemd il nome di ogni unità in avvio.
# SetUpdateStatusFunction → ogni unità
# SetMessageFunction      → messaggi espliciti (errori, avvisi)
status_spr = Sprite();
status_spr.SetZ(20);

fun ShowStatus(text) {
    img = Image.Text(text, 0.50, 0.50, 0.55, 1, "monospace 10");
    status_spr.SetImage(img);
    status_spr.SetX(Window.GetWidth() / 2 - img.GetWidth() / 2);
    status_spr.SetY(Window.GetHeight() - 50);
}

Plymouth.SetUpdateStatusFunction(ShowStatus);
Plymouth.SetMessageFunction(ShowStatus);
EOF
```

```bash
# Logo placeholder — sostituire con il proprio PNG
convert -size 256x256 xc:none \
    -fill "rgba(34,130,242,0.9)" \
    -draw "roundrectangle 20,20,235,235,30,30" \
    /usr/share/plymouth/themes/kiosk/logo.png

# Attiva il tema
update-alternatives --install \
    /usr/share/plymouth/themes/default.plymouth \
    default.plymouth \
    /usr/share/plymouth/themes/kiosk/kiosk.plymouth \
    100
plymouth-set-default-theme kiosk

cat > /etc/plymouth/plymouthd.conf << 'EOF'
[Daemon]
Theme=kiosk
ShowDelay=0
DeviceTimeout=8
EOF
```

### 9.3 Integrazione bootloader

```bash
# amd64 — GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.systemd.show_status=false rd.udev.log_level=3"/' \
    /etc/default/grub
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub

# arm64/Pi — cmdline.txt
# echo "console=tty1 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet splash \
#     loglevel=3 rd.systemd.show_status=false plymouth.ignore-serial-consoles" \
#     > /boot/firmware/cmdline.txt

# Framebuffer nell'initramfs per Plymouth
echo "FRAMEBUFFER=y" >> /etc/initramfs-tools/initramfs.conf
```

### 9.4 Messaggi personalizzati da servizi

```bash
# Da un ExecStartPre= in un'unità systemd, o da uno script:
plymouth message --text="Caricamento configurazione di rete..."
plymouth update  --status="Avvio servizio principale"

# Test interattivo senza reboot
plymouthd --no-daemon --debug &
sleep 1
plymouth --show-splash
plymouth update --status="Test avvio servizio XYZ..."
sleep 2
plymouth message --text="Servizio XYZ pronto"
sleep 2
plymouth --quit
```

---

## 10. fstab

```bash
# amd64 — Opzione A
cat > /etc/fstab << 'EOF'
LABEL=EFI   /boot/efi  vfat  defaults,noatime                           0 2
LABEL=BOOT  /boot      ext4  defaults,noatime                           0 2
LABEL=ROOT  /          ext4  defaults,noatime,ro                        0 1
tmpfs       /tmp       tmpfs defaults,noatime,nosuid,nodev,size=256M    0 0
tmpfs       /run       tmpfs defaults,noatime,nosuid,nodev,mode=0755    0 0
tmpfs       /var/cache tmpfs defaults,noatime,nosuid,nodev,size=512M    0 0
tmpfs       /var/tmp   tmpfs defaults,noatime,nosuid,nodev,size=64M     0 0
EOF
# Opzione B: aggiungere
# echo "LABEL=LOG /var/log ext4 defaults,noatime,nosuid,nodev 0 2" >> /etc/fstab

# arm64/Pi — Opzione A
# cat > /etc/fstab << 'EOF'
# LABEL=FIRMWARE /boot/firmware vfat defaults,noatime                    0 2
# LABEL=ROOT     /              ext4 defaults,noatime,ro                 0 1
# tmpfs /tmp       tmpfs defaults,noatime,nosuid,nodev,size=256M         0 0
# tmpfs /run       tmpfs defaults,noatime,nosuid,nodev,mode=0755         0 0
# tmpfs /var/cache tmpfs defaults,noatime,nosuid,nodev,size=512M         0 0
# tmpfs /var/tmp   tmpfs defaults,noatime,nosuid,nodev,size=64M          0 0
# EOF

# DATA non in fstab: montata dall'initramfs hook, persiste dopo switch_root
```

---

## 11. Pacchetti sistema base

```bash
apt-get install -y \
    sudo curl wget ca-certificates gnupg2 \
    iproute2 iputils-ping net-tools \
    htop nano less \
    util-linux e2fsprogs \
    lsb-release initramfs-tools apt-utils \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    build-essential git \
    python3 python3-dbus python3-gi python3-pyudev \
    gir1.2-glib-2.0
```

---

## 12. Rete — NetworkManager + netplan

```bash
apt-get install -y network-manager netplan.io

cat > /etc/netplan/00-default.yaml << 'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 /etc/netplan/00-default.yaml
systemctl enable NetworkManager
```

---

## 13. Driver GPU e firmware

### Intel (Gen 8+)
```bash
apt-get install -y \
    intel-media-va-driver-non-free i965-va-driver-shaders \
    libva2 libva-drm2 libva-wayland2 libva-utils \
    mesa-vulkan-drivers mesa-utils libgl1-mesa-dri
```

### AMD / Radeon
```bash
apt-get install -y \
    firmware-amd-graphics \
    mesa-va-drivers mesa-vulkan-drivers \
    libdrm-amdgpu1 \
    libva2 libva-drm2 libva-wayland2 libva-utils \
    libgl1-mesa-dri
```

### Nvidia
```bash
apt-get install -y \
    nvidia-driver nvidia-vaapi-driver \
    libva2 libva-drm2 libva-wayland2 libva-utils

echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf
echo "nvidia-drm" >> /etc/modules-load.d/nvidia.conf
```

### Raspberry Pi 4/5
```bash
apt-get install -y \
    mesa-utils libgl1-mesa-dri libgles2-mesa \
    libva2 libva-drm2 libva-utils \
    v4l-utils libv4l-dev libv4l2rds0
```

### Tutte le architetture — librerie comuni
```bash
apt-get install -y libglvnd0 libglx0 libgles2 vulkan-tools libvulkan1
```

---

> **⚠️ OBSOLETE (sezioni 14-19): architettura Sway/Wayland abbandonata.**
> Sway rifiuta di girare come root (`sway/main.c:170`) e CEF (usato da
> unitotem-manager per il rendering) è architetturalmente legato a X11 -
> non può essere reso nativo-Wayland (reparenting di finestre X11 tramite
> `CefWindowInfo.SetAsChild`, incompatibile col modello di sicurezza
> Wayland). L'intera pipeline Sway + chromium-kiosk + kiosk-wm-service
> (controllo via DBus) + autologin è stata sostituita da X11 puro senza
> window manager, con unitotem-manager che incorpora CEF direttamente nel
> proprio processo Qt6 (niente più browser Chromium standalone). Vedi
> **sezione 26** per il design attuale, completo e verificato. Queste
> sezioni restano solo come riferimento storico.

## 14. Wayland + PipeWire

```bash
apt-get install -y \
    sway xwayland wlr-randr \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth

mkdir -p /root/.config/systemd/user/default.target.wants
for svc in pipewire pipewire-pulse wireplumber; do
    ln -sf /usr/lib/systemd/user/${svc}.service \
        /root/.config/systemd/user/default.target.wants/
done
```

---

## 15. Accelerazione hardware Chromium

```bash
apt-get install -y \
    chromium chromium-sandbox \
    libva2 libva-drm2 libva-wayland2 libva-utils \
    ffmpeg libavcodec-extra

mkdir -p /etc/kiosk

cat > /etc/kiosk/chromium-flags << 'EOF'
--ozone-platform=wayland
--enable-features=VaapiVideoDecoder,VaapiVideoEncoder,CanvasOopRasterization
--disable-features=UseChromeOSDirectVideoDecoder
--use-gl=egl
--enable-gpu-rasterization
--enable-zero-copy
--ignore-gpu-blocklist
--enable-accelerated-video-decode
--disable-software-rasterizer
EOF

# Solo Raspberry Pi: sostituire il file sopra
# cat > /etc/kiosk/chromium-flags << 'EOF'
# --ozone-platform=wayland
# --use-v4l2-codec
# --enable-features=PlatformHEVCDecoderSupport,VaapiIgnoreDriverChecks
# --enable-gpu-rasterization
# --use-gl=egl
# --ignore-gpu-blocklist
# EOF

# Solo Nvidia: aggiungere a chromium-flags
# echo "--use-angle=vulkan" >> /etc/kiosk/chromium-flags

cat > /usr/local/bin/chromium-kiosk << 'SCRIPT'
#!/bin/bash
FLAGS=$(grep -v '^#' /etc/kiosk/chromium-flags | tr '\n' ' ')
exec /usr/bin/chromium $FLAGS "$@"
SCRIPT
chmod +x /usr/local/bin/chromium-kiosk
```

---

## 16. Tastiera virtuale (wvkbd)

`wvkbd` è un client Wayland leggero (`virtual-keyboard-unstable-v1`).
Si controlla tramite segnali POSIX: `SIGUSR1` mostra, `SIGUSR2` nasconde.
Non è nei repo Debian; si compila dal sorgente.

```bash
apt-get install -y libwayland-dev libxkbcommon-dev scdoc

git clone https://github.com/jjsullivan5196/wvkbd /tmp/wvkbd
cd /tmp/wvkbd
make
make install          # installa wvkbd-mobintl, wvkbd-compact, ...
cd /
rm -rf /tmp/wvkbd
```

Alternativa dai repo Debian (richiede alcune dipendenze GNOME/libadwaita):
```bash
# apt-get install -y squeekboard
# squeekboard usa sm.puri.OSK0 su dbus e supporta text-input-v3
# (mostra/nasconde automaticamente quando un campo testo prende il focus)
```

---

## 17. Sway — configurazione kiosk

```bash
cat > /etc/kiosk/sway.conf << 'EOF'
bar { mode hide }

default_border none
default_floating_border none
hide_edge_borders both

output * bg #000000 solid_color

for_window [app_id=".*"] fullscreen enable
for_window [class=".*"]  fullscreen enable

# --- Cursore ---
# Il cursore non viene mostrato finché il mouse non viene mosso (comportamento
# default di wlroots: nessun pointer finché non arriva un evento di movimento).
# Gli eventi touch non generano movimento del cursore: il puntatore rimane
# invisibile durante l'uso del touchscreen senza configurazione aggiuntiva.
# hide_cursor nasconde il cursore dopo N millisecondi di inattività del mouse.
seat seat0 hide_cursor 3000
seat seat0 hide_cursor when-typing enable

# --- Input touch ---
input type:touch events enabled

# --- Tastiera virtuale ---
# Avviata nascosta; risponde a SIGUSR1 (mostra) e SIGUSR2 (nasconde).
# -L altezza in pixel del pannello tastiera
exec wvkbd-mobintl --hidden -L 300

# --- Servizio dBus kiosk (eredita SWAYSOCK) ---
exec /usr/local/bin/kiosk-wm-service

# --- Avvio automatico Chromium (decommentare) ---
# exec_always /usr/local/bin/chromium-kiosk https://your-app-url
EOF
```

---

## 18. Servizio dBus per controllo WM

Running as root: nessuna policy dBus aggiuntiva richiesta.

`ShowKeyboard` / `HideKeyboard` inviano SIGUSR1/SIGUSR2 a `wvkbd-mobintl`.

```bash
cat > /usr/local/bin/kiosk-wm-service << 'PYEOF'
#!/usr/bin/env python3
"""
Servizio dBus kiosk — system bus — org.kiosk.WM

Metodi:
  Launch(cmdline)     avvia app via swaymsg exec
  Kill()              termina finestra in focus
  Reload()            ricarica config sway
  ListOutputs()       nomi output attivi
  FocusOutput(name)   sposta focus sull'output
  ShowKeyboard()      mostra tastiera virtuale (SIGUSR1 → wvkbd)
  HideKeyboard()      nasconde tastiera virtuale (SIGUSR2 → wvkbd)

Segnali:
  OutputConnected(name, width, height)
  OutputDisconnected(name)
"""
import os, sys, json, struct, socket, subprocess, threading, signal, logging
import dbus, dbus.service, dbus.mainloop.glib
import pyudev
from gi.repository import GLib

logging.basicConfig(level=logging.INFO, stream=sys.stderr)
log = logging.getLogger("kiosk-wm")

BUS_NAME         = "org.kiosk.WM"
OBJ_PATH         = "/org/kiosk/WM"
IFACE            = "org.kiosk.WM"
IPC_MAGIC        = b"i3-ipc"
IPC_SUBSCRIBE    = 2
IPC_EVENT_OUTPUT = 0x80000001


def _sway_sock():
    p = os.environ.get("SWAYSOCK", "")
    if not p:
        raise RuntimeError("SWAYSOCK non impostato")
    return p

def _ipc_send(sock, mtype, payload: bytes):
    sock.sendall(IPC_MAGIC + struct.pack("<II", len(payload), mtype) + payload)

def _ipc_recv(sock):
    hdr = b""
    while len(hdr) < 14:
        c = sock.recv(14 - len(hdr))
        if not c:
            raise EOFError
        hdr += c
    length, mtype = struct.unpack("<II", hdr[6:14])
    data = b""
    while len(data) < length:
        c = sock.recv(length - len(data))
        if not c:
            raise EOFError
        data += c
    return mtype, data

def swaymsg(cmd):
    r = subprocess.run(["swaymsg", "--", cmd],
                       capture_output=True, text=True, timeout=5)
    return json.loads(r.stdout) if r.stdout else {}

def get_outputs():
    r = subprocess.run(["swaymsg", "-t", "get_outputs"],
                       capture_output=True, text=True, timeout=5)
    return json.loads(r.stdout) if r.stdout else []

def signal_wvkbd(sig):
    r = subprocess.run(["pkill", f"-{sig}", "wvkbd-mobintl"],
                       capture_output=True)
    return r.returncode == 0


class KioskWM(dbus.service.Object):
    def __init__(self, bus):
        bn = dbus.service.BusName(BUS_NAME, bus=bus)
        super().__init__(bn, OBJ_PATH)
        self._known: set = set()
        threading.Thread(target=self._watch_sway, daemon=True).start()
        threading.Thread(target=self._watch_udev, daemon=True).start()

    @dbus.service.method(IFACE, in_signature="s", out_signature="i")
    def Launch(self, cmdline):
        swaymsg(f"exec {cmdline}")
        return 0

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def Kill(self):
        swaymsg("kill")

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def Reload(self):
        swaymsg("reload")

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListOutputs(self):
        return [o["name"] for o in get_outputs() if o.get("active")]

    @dbus.service.method(IFACE, in_signature="s", out_signature="")
    def FocusOutput(self, name):
        swaymsg(f"focus output {name}")

    @dbus.service.method(IFACE, in_signature="", out_signature="b")
    def ShowKeyboard(self):
        return signal_wvkbd("USR1")

    @dbus.service.method(IFACE, in_signature="", out_signature="b")
    def HideKeyboard(self):
        return signal_wvkbd("USR2")

    @dbus.service.signal(IFACE, signature="sii")
    def OutputConnected(self, name, width, height):
        pass

    @dbus.service.signal(IFACE, signature="s")
    def OutputDisconnected(self, name):
        pass

    def _refresh(self):
        try:
            outputs = get_outputs()
            current = {o["name"] for o in outputs if o.get("active")}
            for o in outputs:
                n = o["name"]
                if o.get("active") and n not in self._known:
                    w = o.get("rect", {}).get("width",  0)
                    h = o.get("rect", {}).get("height", 0)
                    log.info("output connesso: %s %dx%d", n, w, h)
                    GLib.idle_add(self.OutputConnected, n, w, h)
            for n in self._known - current:
                log.info("output disconnesso: %s", n)
                GLib.idle_add(self.OutputDisconnected, n)
            self._known = current
        except Exception as e:
            log.error("refresh outputs: %s", e)

    def _watch_sway(self):
        import time
        while True:
            try:
                sock = socket.socket(socket.AF_UNIX)
                sock.connect(_sway_sock())
                _ipc_send(sock, IPC_SUBSCRIBE, json.dumps(["output"]).encode())
                _ipc_recv(sock)
                self._known = {o["name"] for o in get_outputs() if o.get("active")}
                while True:
                    mtype, _ = _ipc_recv(sock)
                    if mtype == IPC_EVENT_OUTPUT:
                        self._refresh()
            except Exception as e:
                log.warning("sway IPC: %s — riconnessione in 2s", e)
                time.sleep(2)

    def _watch_udev(self):
        try:
            ctx     = pyudev.Context()
            monitor = pyudev.Monitor.from_netlink(ctx)
            monitor.filter_by("drm")
            for dev in iter(monitor.poll, None):
                if dev.action == "change":
                    GLib.idle_add(self._refresh)
        except Exception as e:
            log.error("udev monitor: %s", e)


if __name__ == "__main__":
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    KioskWM(bus)
    log.info("kiosk-wm-service avviato (%s)", BUS_NAME)
    GLib.MainLoop().run()
PYEOF

chmod +x /usr/local/bin/kiosk-wm-service
```

Utilizzo dall'esterno:
```bash
dbus-send --system --dest=org.kiosk.WM /org/kiosk/WM \
    org.kiosk.WM.Launch string:"/usr/local/bin/chromium-kiosk https://example.com"

dbus-send --system --dest=org.kiosk.WM /org/kiosk/WM org.kiosk.WM.ShowKeyboard
dbus-send --system --dest=org.kiosk.WM /org/kiosk/WM org.kiosk.WM.HideKeyboard

dbus-send --system --print-reply --dest=org.kiosk.WM /org/kiosk/WM \
    org.kiosk.WM.ListOutputs

dbus-monitor --system "type='signal',interface='org.kiosk.WM'"
```

---

## 19. Autologin root e avvio Sway

```bash
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

cat > /root/.bash_profile << 'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR=/run/user/0
    export XDG_SESSION_TYPE=wayland
    export MOZ_ENABLE_WAYLAND=1
    export QT_QPA_PLATFORM=wayland
    export SDL_VIDEODRIVER=wayland
    export CLUTTER_BACKEND=wayland

    # Solo Nvidia — abilitare:
    # export GBM_BACKEND=nvidia-drm
    # export __GLX_VENDOR_LIBRARY_NAME=nvidia
    # export WLR_NO_HARDWARE_CURSORS=1

    exec systemd-cat -t sway sway -c /etc/kiosk/sway.conf
fi
EOF
```

---

## 20. OverlayFS — hook initramfs

```bash
cat > /etc/initramfs-tools/scripts/init-bottom/setup-overlays << 'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

. /scripts/functions

DATA_DEV=$(blkid -L DATA 2>/dev/null)
if [ -z "$DATA_DEV" ]; then
    log_warning_msg "overlay: DATA non trovata, skip — sistema avvia con /etc default"
    exit 0
fi

mkdir -p "${rootmnt}/mnt/data"
if ! mount -t ext4 -o noatime,nodiratime "$DATA_DEV" "${rootmnt}/mnt/data"; then
    log_warning_msg "overlay: mount DATA fallito, skip"
    exit 0
fi

# Overlay /etc
mkdir -p "${rootmnt}/mnt/data/upper/etc" \
         "${rootmnt}/mnt/data/work/etc"
mount -t overlay overlay \
    -o lowerdir="${rootmnt}/etc",\
upperdir="${rootmnt}/mnt/data/upper/etc",\
workdir="${rootmnt}/mnt/data/work/etc" \
    "${rootmnt}/etc" \
    || log_warning_msg "overlay: /etc fallito"

# Overlay /root (home di root)
mkdir -p "${rootmnt}/mnt/data/upper/root" \
         "${rootmnt}/mnt/data/work/root"
mount -t overlay overlay \
    -o lowerdir="${rootmnt}/root",\
upperdir="${rootmnt}/mnt/data/upper/root",\
workdir="${rootmnt}/mnt/data/work/root" \
    "${rootmnt}/root" \
    || log_warning_msg "overlay: /root fallito"

# Opzione A alternativa: log persistenti su DATA
# mkdir -p "${rootmnt}/mnt/data/log"
# mount --bind "${rootmnt}/mnt/data/log" "${rootmnt}/var/log"
HOOK

chmod +x /etc/initramfs-tools/scripts/init-bottom/setup-overlays
echo "overlay" >> /etc/initramfs-tools/modules
```

---

## 21. Crash-resistance e ottimizzazioni I/O

```bash
cat >> /etc/sysctl.conf << 'EOF'
vm.dirty_writeback_centisecs = 3000
vm.dirty_expire_centisecs    = 3000
vm.dirty_ratio               = 5
vm.dirty_background_ratio    = 2
EOF

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/kiosk.conf << 'EOF'
[Journal]
# Opzione A (log in DATA o su tmpfs): Storage=volatile → solo RAM
# Storage=volatile
# Opzione B (partizione LOG dedicata):
Storage=persistent
Compress=yes
SystemMaxUse=512M
RuntimeMaxUse=64M
SyncIntervalSec=5min
MaxLevelStore=warning
EOF

cat > /etc/udev/rules.d/60-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-9]n[0-9]|mmcblk[0-9]", \
    ATTR{queue/rotational}=="0", \
    ATTR{queue/scheduler}="mq-deadline"
EOF

echo 'FSCKFIX=yes' >> /etc/default/rcS
```

---

## 22. Modalità aggiornamento

Il rootfs è montato read-only. Per installare aggiornamenti è necessario
rimontarlo in lettura-scrittura. Le partizioni overlay (DATA) sono sempre
read-write: le modifiche a `/etc` e `/root` sono già persistenti in qualsiasi
modalità; il remount di `/` serve solo per scrivere in `/usr`, `/lib`, `/bin`.

### 22.1 Script di aggiornamento

```bash
cat > /usr/local/bin/kiosk-update << 'SCRIPT'
#!/bin/bash
set -e

_enter() {
    echo "[kiosk-update] Fermo il kiosk..."
    pkill -x sway 2>/dev/null || true
    sleep 1

    echo "[kiosk-update] Rimonto rootfs in rw..."
    mount -o remount,rw /

    # /var/cache/apt è su tmpfs (512 MB, vedi fstab).
    # Per aggiornamenti grandi: espandere temporaneamente la cache
    mount -o remount,size=1G /var/cache

    echo "[kiosk-update] Pronti. Percorso di scrittura per directory:"
    echo "  /etc  /root       → overlay su DATA (sempre persistente)"
    echo "  /usr  /lib  /bin  → rootfs (ora scrivibile)"
    echo ""
    echo "Eseguire: apt-get update && apt-get upgrade"
    echo "Al termine: kiosk-update exit [--initramfs]"
}

_exit() {
    local regen_initramfs=0
    [ "$1" = "--initramfs" ] && regen_initramfs=1

    if [ $regen_initramfs -eq 1 ]; then
        echo "[kiosk-update] Rigenero initramfs..."
        update-initramfs -u -k all
    fi

    # Aggiorna GRUB se necessario (solo amd64)
    if command -v update-grub &>/dev/null; then
        update-grub 2>/dev/null || true
    fi

    echo "[kiosk-update] Rimonto rootfs in ro..."
    # Sincronizza prima di rimontare
    sync
    mount -o remount,ro / 2>/dev/null || true

    echo "[kiosk-update] Riavvio in 5 secondi..."
    sleep 5
    systemctl reboot
}

case "$1" in
    enter) _enter ;;
    exit)  _exit "$2" ;;
    *)
        echo "Uso: $0 enter | exit [--initramfs]"
        echo "  enter            rimonta / rw, ferma il kiosk"
        echo "  exit             rimonta / ro, riavvia"
        echo "  exit --initramfs rigenera initramfs prima del riavvio"
        exit 1
        ;;
esac
SCRIPT

chmod +x /usr/local/bin/kiosk-update
```

### 22.2 Modalità aggiornamento tramite parametro kernel

Permette di avviare in modalità aggiornamento senza accesso fisico alla console,
utile per aggiornamenti OTA: il sistema di gestione aggiunge `kiosk.update=1`
alla cmdline del prossimo boot (via SSH), poi riavvia.

```bash
# Servizio che intercetta kiosk.update=1 e ferma il kiosk automaticamente
cat > /etc/systemd/system/kiosk-update-mode.service << 'EOF'
[Unit]
Description=Kiosk — Modalità Aggiornamento
# Attivo solo se kernel è stato avviato con kiosk.update=1
ConditionKernelCommandLine=kiosk.update=1
# Impedisce l'avvio del kiosk (getty@tty1 dipende da questa unit)
Before=getty@tty1.service
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Rimonta rootfs in rw e segnala che è pronto per aggiornamenti
ExecStart=/bin/mount -o remount,rw /
ExecStart=/bin/mount -o remount,size=1G /var/cache
ExecStart=/usr/bin/logger -t kiosk-update "Sistema in modalità aggiornamento — connettersi via SSH"

[Install]
WantedBy=multi-user.target
EOF

systemctl enable kiosk-update-mode.service
```

```bash
# amd64: voce GRUB per avvio manuale in modalità aggiornamento
# Aggiungere a /etc/grub.d/40_custom:
cat >> /etc/grub.d/40_custom << 'EOF'

menuentry 'Debian Kiosk — Modalità Aggiornamento' {
    load_video
    insmod gzio
    insmod part_gpt
    insmod ext2
    search --no-floppy --label --set=root BOOT
    linux  /vmlinuz root=LABEL=ROOT ro kiosk.update=1
    initrd /initrd.img
}
EOF

# arm64/Pi: per avvio OTA in update mode, modificare cmdline.txt via SSH:
# ssh root@<ip> "echo '... kiosk.update=1' > /boot/firmware/cmdline.txt && reboot"
# Dopo l'aggiornamento, ripristinare cmdline.txt all'originale tramite kiosk-update exit
```

### 22.3 Flusso tipico di aggiornamento via SSH

```bash
# 1. Connettersi via SSH
ssh root@<ip>

# 2a. Se il sistema è già avviato normalmente:
kiosk-update enter

# 2b. Oppure riavviare in update mode (se si usa il parametro kernel):
# grub-reboot "Debian Kiosk — Modalità Aggiornamento" && reboot

# 3. Aggiornare
apt-get update
apt-get upgrade

# 4. Se aggiornato il kernel o l'initramfs:
kiosk-update exit --initramfs

# 4b. Altrimenti:
kiosk-update exit
```

---

## 23. Abilitazione servizi e rigenerazione initramfs

```bash
systemctl enable \
    systemd-timesyncd \
    NetworkManager \
    dbus \
    udev \
    systemd-logind \
    ssh

# Rigenera initramfs con overlay hook + Plymouth + moduli GPU
update-initramfs -u -k all

# Solo amd64
update-grub
```

---

## 24. Uscita dal chroot e smontaggio

```bash
exit

umount -R $TARGET/dev
umount -R $TARGET/proc
umount -R $TARGET/sys
umount -R $TARGET/run

# Opzione B:
# umount $TARGET/var/log

umount $TARGET/mnt/data

# amd64:
umount $TARGET/boot/efi
umount $TARGET/boot

# arm64/Pi:
# umount $TARGET/boot/firmware

umount $TARGET
sync
```

---

## 25. Note post-installazione

**Verifica accelerazione video:**
```bash
vainfo
ffmpeg -hwaccels
# Pi: v4l2-ctl --list-devices
```

**Verifica cursore e touch in Sway:**
```bash
# Il cursore deve essere invisibile a schermo fermo
# Al tocco del touchscreen il cursore non deve comparire
# Al movimento del mouse deve comparire e sparire dopo 3 secondi
```

**Test Plymouth:**
```bash
plymouthd --no-daemon --debug &
sleep 1 && plymouth --show-splash
plymouth update --status="Test servizio avvio..."
sleep 3 && plymouth --quit
```

**Reset stato persistente (ripristina /etc e /root ai default del rootfs):**
```bash
# Con sistema smontato o da recovery
mount -L DATA /mnt/data
rm -rf /mnt/data/upper/etc  /mnt/data/work/etc
rm -rf /mnt/data/upper/root /mnt/data/work/root
```

**Opzione A vs Opzione B — riepilogo:**

| Aspetto                    | Opzione A (log in DATA)       | Opzione B (partizione LOG)      |
|----------------------------|-------------------------------|---------------------------------|
| Partizioni totali (amd64)  | 4                             | 5                               |
| Log sopravvivono reset DATA | No                           | Sì                              |
| Isolamento guasti           | Log non separati             | Piena separazione               |
| Raccomandazione             | SD card + `Storage=volatile` | SSD + `Storage=persistent`      |

---

## 26. X11 senza window manager (design attuale)

Sostituisce le sezioni 14-19 (Sway/Wayland, obsolete). CEF (usato da
`unitotem-manager` per il rendering degli asset) è vincolato architetturalmente
a X11 (`CefWindowInfo.SetAsChild` fa reparenting di una finestra X11 nativa
dentro la finestra Qt - incompatibile col modello di sicurezza Wayland, che
non permette embedding cross-client di superfici). Sway inoltre rifiuta
esplicitamente di girare come root (`sway/main.c:170`). Cage (che permette
root) ha un modello multi-monitor incompatibile (solo `-m last`/`-m extend`,
non monitor indipendenti). Weston sarebbe stato praticabile ma è comunque un
compositor Wayland - stesso muro architetturale con CEF. Si è quindi passati
a X11 puro, senza window manager: `unitotem-manager` stesso (Qt6 + CEF, in
process, vedi `manager/webview/`) gestisce direttamente posizionamento,
dimensione, rotazione e flip di ogni finestra per-schermo; non serve nessun
WM a gestire quelle responsabilità.

**Pacchetti** (sostituisce sezioni 14-16; niente più `sway`, `xwayland`,
`chromium`, `wvkbd` - `chromium-kiosk` non era comunque mai invocato da
nessuna parte del codice):
```bash
apt-get install -y \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth
```

**Avvio**: niente autologin + `.bash_profile` (l'approccio iniziale di questa
migrazione, abbandonato: causava un crash-loop non diagnosticato del terminale
dopo ~159s, `KDSETMODE failed`/`VT_GETSTATE failed: Input/output error`).
Si è recuperato invece il pattern proven della vecchia versione di unitotem:
X avviato come vero servizio systemd indipendente da qualunque sessione di
login, su una VT dedicata (tty8, per non contendere tty1).

`/etc/systemd/system/start-xorg.service`:
```ini
[Unit]
Description=X11 session (kiosk)
After=multi-user.target

[Service]
TTYPath=/dev/tty8
StandardInput=tty
StandardOutput=journal
UnsetEnvironment=TERM
# startx/xinit ricadono su $HOME/.Xauthority SOLO se $XAUTHORITY non è già
# impostato - e $HOME/.Xauthority non è scrivibile sulla root read-only di
# questa immagine, il che faceva ritentare a xinit la connessione a X
# all'infinito con un cookie mai valido, senza mai lanciare xinitrc
# (start-xorg.service risultava "active" per l'intera durata - solo
# unitotem-manager.service, incapace di connettersi, andava in crash-loop
# con SIGABRT). Puntare XAUTHORITY su questo path fisso in tmpfs fa sì che
# xinit lo popoli direttamente lì; è lo stesso path che legge
# unitotem-manager.service via il proprio Environment=XAUTHORITY= (vedi
# unitotem-manager.service e xinitrc) - non serve nessun passaggio/copia.
Environment=XAUTHORITY=/run/unitotem-x11.auth

ExecStartPre=/usr/bin/chvt 8
ExecStart=/usr/bin/startx /etc/kiosk/xinitrc -- vt8 -keeptty -nocursor -verbose 3 -logfile /dev/null
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

`/etc/kiosk/xinitrc`:
```sh
#!/bin/sh
# Sessione X per il kiosk unitotem. Nessun window manager: il viewer Qt6+CEF
# di unitotem-manager (avviato indipendentemente come servizio systemd, vedi
# start-xorg.service + Environment=DISPLAY=:0 di unitotem-manager.service)
# imposta già le proprie finestre a geometria fullscreen esatta senza
# decorazioni, quindi qui non serve gestire finestre - solo tuning del server
# X (il cursore è già nascosto dal flag -nocursor di Xorg) e mantenere viva
# la sessione.

xset -dpms
xset s off
xset s noblank
xsetroot -solid black

# $XAUTHORITY è già il path fisso /run/unitotem-x11.auth qui (vedi
# Environment= di start-xorg.service) - sia questa sessione X sia
# unitotem-manager.service (un'altra unit systemd) puntano allo stesso file,
# quindi non serve nessun handoff/copia.

exec sleep infinity
```

`unitotem-manager.service` (rilevante):
```ini
Environment=DISPLAY=:0
Environment=XAUTHORITY=/run/unitotem-x11.auth
```

`manager/webview/app.py`'s `WebviewApp.display_available()` controlla sia
`$DISPLAY` sia l'esistenza reale del socket `/tmp/.X11-unix/X{num}` *prima*
di toccare Qt/CEF: costruirli senza un display utilizzabile abortisce
l'intero processo a livello nativo (SIGABRT, non catturabile da Python).
`manager/main.py` fa polling (ogni 5s) finché un display non diventa
disponibile invece di considerarlo un errore fatale - un nodo senza monitor
collegato è una situazione supportata e potenzialmente permanente, non solo
transitoria.

---

## 27. Test multi-monitor in VM (QEMU) - hot-plug/hot-unplug

`unitotem-manager` deve rilevare in automatico il numero di schermi collegati
(`QApplication.screenAdded`/`screenRemoved` in `manager/webview/app.py`) e
notificare il cambiamento al server via WebSocket (`WebviewInfo`), che
ribroadcasta `Viewers/list` a tutti i client connessi - la pagina Viewers e la
pagina Settings/Display della webui devono aggiornarsi da sole, senza reload.
Verificato via analisi del codice + test con un solo schermo; la verifica
end-to-end con un vero hot-plug in VM resta **bloccata**, vedi sotto.

**Config QEMU per due schermi:**
```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -device virtio-vga,max_outputs=2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=overlay.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:443 \
  -device virtio-net-pci,netdev=net0 \
  -spice port=5900,addr=127.0.0.1,disable-ticketing=on,image-compression=off \
  -chardev spicevmc,id=vdagent,name=vdagent \
  -device virtio-serial-pci \
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
  -monitor unix:monitor.sock,server,nowait -daemonize -pidfile qemu.pid
```
`max_outputs=2` dà al guest un secondo output virtio-gpu (`Virtual-2` in
`xrandr`), ma **disconnesso** finché nessun consumer SPICE lo reclama - serve
SPICE (non VNC: VNC non seleziona head, mostra sempre e solo il primo) più un
client reale. Consumer headless per test automatizzati (screenshot via
QEMU `screendump`/`virsh screenshot`, non serve un display reale sull'host):
```bash
docker run -d --network host --name spice-consumer debian:bookworm sleep 3600
docker exec spice-consumer bash -c \
  "apt-get update -qq && apt-get install -y -qq virt-viewer xvfb"
docker exec -d spice-consumer bash -c "Xvfb :99 -screen 0 2600x850x24"
docker exec -d spice-consumer bash -c \
  "DISPLAY=:99 remote-viewer -f spice://127.0.0.1:5900"
```

**Tentativi che NON bastano a far comparire un secondo schermo** (verificato
empiricamente, in ordine):
- `xrandr --output Virtual-2 --auto` - rifiutato, nessun EDID su un output
  "disconnected".
- Forzare un CRTC/mode a mano (`xrandr --newmode` + `--addmode` +
  `--output ... --mode ...`) - accettato da Xorg (compare in `xrandr --query`
  con un mode attivo!) ma **Qt6/XCB lo ignora comunque**: `QApplication.
  screens()` filtra rigorosamente sul bit RandR `Connected`, non su CRTC/mode
  attivi. Confermato controllando `Viewers/list` lato webui dopo ogni
  tentativo - nessun nuovo screen mai comparso.
- RandR 1.5 `xrandr --setmonitor NOME WxH+X+Y sorgente` (raggruppamento
  logico "Monitor", indipendente dal Connected di un Output) - stesso esito,
  Qt non lo enumera.
- Backend display QEMU `-display dbus,p2p=on` (pensato per essere
  headless-friendly) invece di SPICE - stesso esito: senza un consumer che
  *renderizzi attivamente* quel canale, l'output resta disconnected.
- Comandi QMP diretti - **non esistono**: `query-qmp-schema` non ha nessun
  comando per lo stato connesso/dimensione di un output virtio-gpu.
  `display-update`/`display-reload` esistono ma sono VNC-only (cambiano solo
  le opzioni di listen). Il meccanismo reale (`dpy_set_ui_info()`) è una API
  C interna, mai esposta via QMP - invocata solo dal backend display in
  risposta al messaggio "monitors config" del protocollo SPICE.

**Blocco reale, non risolto:** un client SPICE reale (`remote-viewer`) si
connette e apre entrambi i canali (`SpiceDisplayChannel 0` e `1` nei log),
ma la negoziazione "monitors config" che flippa `Connected` nel guest passa
SOLO per `spice-vdagent` (guest) + `spice-vdagentd`, e `spice-vdagentd`
rifiuta di attivare l'agent senza una sessione logind valida - cosa che
questa immagine, per design, non ha (X avviato da `start-xorg.service`
direttamente, niente display manager, niente sessione PAM/logind legata a
un seat). Tentato un workaround con una sessione logind fittizia
(`systemd-run -p PAMName=login -p User=root ...`, la sessione VIENE creata
- confermata via `loginctl list-sessions` - ma `spice-vdagentd` continua a
fallire con errori diversi a seconda dei flag: "no session info, max 1
session agent allowed" / "Error getting active session: No data available").
Non approfondito oltre: richiederebbe o patchare/ricompilare spice-vdagentd,
o investire in un setup libvirt+SPICE più maturo (con un vero desktop
manager sul lato client, es. GNOME Boxes/virt-manager, che gestisce
l'autoconf in un modo che questo setup manuale non replica).

**Cosa resta da fare per completare la verifica hot-plug/hot-unplug**, se
serve in futuro: risolvere il blocco spice-vdagent sopra (o sostituirlo con
un approccio diverso, es. patch minima a spice-vdagentd per bypassare il
controllo sessione quando non c'è logind, dato che è comunque uno scenario
legittimo per un guest headless/kiosk), poi verificare che
`screenAdded`/`screenRemoved` scattino davvero e che la pagina Viewers/
Settings/Display della webui si aggiorni senza reload sia in hot-plug sia in
hot-unplug.
