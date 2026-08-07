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

# Imposta la password di root usata per SSH (e per il login su console:
# l'immagine non usa autologin, la sessione X parte da start-xorg.service)
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
apt-get install -y plymouth plymouth-themes plymouth-label libplymouth5
```

`plymouth-label` (non installato in precedenza) serve alla riga di stato del
tema `unitotem` (vedi 9.2): senza, `Image.Text()` ritorna un'immagine 0x0 e
quella riga resta vuota — non blocca il boot, ma va comunque installato qui
perché il tema stesso non lo dichiara come dipendenza di sistema.
`imagemagick` non serve più (era usato solo per generare il logo del
placeholder rimosso in 9.2) ed è stato tolto dalla lista pacchetti.

### 9.2 Tema — proprietà di unitotem-manager, non di questa immagine

Questa immagine **non** installa né seleziona più un tema Plymouth
placeholder (il precedente tema "kiosk": logo + barra di progresso). Il tema
reale, chiamato `unitotem`, matcha pixel-per-pixel la schermata di boot del
viewer (`manager/webview/static/boot-screen.html`) — wordmark "UniTotem" con
l'anello che sostituisce la "o", stessa dimensione, stesso font — ed è
installato **dal pacchetto `unitotem-manager`** (`debian/rules` copia
`plymouth/unitotem/` sotto `/usr/share/plymouth/themes/unitotem/`; il tema
usa PNG pre-renderizzati da `plymouth/generate-assets.py` invece di
`Image.Text()`, così non dipende da `plymouth-label` né da un font per il
logo — solo la riga di stato ne ha bisogno).

`unitotem-manager`'s `debian/postinst` attiva il tema con **due** chiamate,
non una sola:

```bash
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
    default.plymouth /usr/share/plymouth/themes/unitotem/unitotem.plymouth 100
plymouth-set-default-theme unitotem
update-initramfs -u
```

Il motivo per cui servono entrambe: Plymouth (verificato su
`src/main.c:load_settings()`/`show_default_splash()` upstream) legge
**prima** la chiave `Theme=` di `/etc/plymouth/plymouthd.conf` e la usa se
presente — l'alternativa `default.plymouth` è solo l'ultimo fallback,
tentato quando `Theme=` è assente o non risolve. `plymouth-set-default-theme
<nome>` è ciò che scrive/aggiorna quella chiave (`update-alternatives` da
solo non la tocca). Il vecchio tema "kiosk" veniva selezionato proprio con
`plymouth-set-default-theme kiosk`, quindi bastava installare
`unitotem-manager` senza quella seconda chiamata perché la chiave
`Theme=kiosk` restasse a vincere silenziosamente sul tema giusto — bug
storico corretto sia qui (rimuovendo il tema "kiosk" e la sua riga
`Theme=kiosk` da `plymouthd.conf`, vedi sotto) sia nel postinst del
manager.

```bash
cat > /etc/plymouth/plymouthd.conf << 'EOF'
[Daemon]
ShowDelay=0
DeviceTimeout=8
EOF
```

Nessuna chiave `Theme=` qui: finché `unitotem-manager` non è installato,
Plymouth ricade sul fallback di sistema (tipicamente lo splash testuale),
che è preferibile a puntare a un tema placeholder poi rimosso.

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

> **`/var/tmp` is a 64 MiB tmpfs, and that breaks `mkinitramfs`.** Any operation
> that regenerates the initramfs — installing or reconfiguring a `linux-image-*`
> package, installing a DKMS driver — builds its staging tree under `/var/tmp`
> and dies part-way through with `No space left on device`, naming only whichever
> file it happened to be copying and never the tmpfs. The kernel package is then
> left unconfigured and `dpkg` stays wedged until it is retried. Point `TMPDIR`
> at the DATA partition first:
>
> ```bash
> mkdir -p /mnt/data/tmp
> export TMPDIR=/mnt/data/tmp
> dpkg --configure -a
> ```
>
> Being a tmpfs, `/var/tmp` is also empty after every reboot, so nothing meant to
> survive one belongs there.

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
    libva2 libva-drm2 libva-utils \
    mesa-vulkan-drivers mesa-utils libgl1-mesa-dri
```

### AMD / Radeon
```bash
apt-get install -y \
    firmware-amd-graphics \
    mesa-va-drivers mesa-vulkan-drivers \
    libdrm-amdgpu1 \
    libva2 libva-drm2 libva-utils \
    libgl1-mesa-dri
```

### Nvidia
```bash
apt-get install -y \
    nvidia-driver nvidia-vaapi-driver \
    libva2 libva-drm2 libva-utils

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

## 14. Sessione grafica (X11) e PipeWire

La sessione grafica è un server Xorg puro, **senza window manager**: il viewer
Qt6+CEF di `unitotem-manager` imposta da sé geometria fullscreen, rotazione e
flip di ogni finestra per-schermo, e CEF supporta soltanto l'embedding X11.
Il design completo della sessione (unit systemd, `xinitrc`, `XAUTHORITY`) è
nella **sezione 26**; qui si installano solo i pacchetti.

```bash
apt-get install -y \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
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

Nessun browser standalone e nessuna tastiera virtuale vengono installati: il
rendering degli asset avviene dentro il processo di `unitotem-manager` (CEF
in-process, vedi `manager/webview/`). Il cursore non richiede configurazione
di sessione: lo nasconde il flag `-nocursor` del server X, vedi l'`ExecStart=`
di `start-xorg.service` nella sezione 26.

L'accelerazione video hardware si configura a livello di driver (sezione 13);
su Raspberry Pi VAAPI non esiste e la decodifica passa per i dispositivi V4L2
mem2mem (`/dev/video10` H.264 su tutti i modelli, `/dev/video19` HEVC da Pi 4
in poi) — vedi i commenti in `kiosk/stage1-packages.sh`.

---

## 15. Nota storica — l'architettura Wayland abbandonata

La numerazione di questo documento salta da 15 a 20. Le sezioni 16-19 — e la
15 nella sua forma originale — descrivevano l'architettura grafica iniziale,
oggi inesistente nell'immagine: accelerazione hardware di un Chromium
standalone (wrapper `chromium-kiosk` e relativi flag), configurazione del
compositor sway, tastiera virtuale wvkbd, servizio dBus `kiosk-wm-service`
(controllo del WM via IPC del compositor) e autologin di root che avviava la
sessione da `.bash_profile`. Sono stati rimossi tutti
insieme al compositor; i numeri delle sezioni successive restano invariati per
non invalidare i riferimenti esterni (`PLAN.md` cita `debian-kiosk.md` §28).

In sintesi il motivo dell'abbandono: CEF — il motore di rendering usato da
`unitotem-manager` — sa fare embedding solo di finestre X11, e sway per giunta
rifiuta esplicitamente di girare come root. La discussione completa, con le
alternative valutate e scartate, è nella **sezione 26** insieme al design
attuale.

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

# Le unit che possiedono davvero lo schermo su questa immagine.
# systemctl stop e non pkill: start-xorg.service è Restart=always, quindi
# uccidere il processo lo fa solo ripartire.
KIOSK_UNITS="unitotem-manager.service start-xorg.service"

_enter() {
    echo "[kiosk-update] Fermo il kiosk..."
    for u in $KIOSK_UNITS; do
        systemctl stop "$u" 2>/dev/null || true
    done
    # Verificato, non dato per scontato: aggiornare mentre il kiosk tiene
    # ancora il display è esattamente ciò che questo passo deve impedire.
    for u in $KIOSK_UNITS; do
        if systemctl is-active --quiet "$u"; then
            echo "[kiosk-update] ERRORE: non sono riuscito a fermare $u" >&2
            exit 1
        fi
    done

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
    ssh \
    start-xorg          # sessione X del kiosk, vedi sezioni 14 e 26

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

**Verifica sessione X e cursore:**
```bash
systemctl status start-xorg
ls /tmp/.X11-unix/           # deve esistere il socket X0
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth xrandr

# Il cursore non deve mai comparire: lo disabilita il flag -nocursor del
# server X (vedi ExecStart= di start-xorg.service), né al tocco del
# touchscreen né muovendo il mouse.
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

La sessione grafica dell'immagine è un server X11 puro senza window manager:
`unitotem-manager` stesso (Qt6 + CEF, in process, vedi `manager/webview/`)
gestisce direttamente posizionamento, dimensione, rotazione e flip di ogni
finestra per-schermo, quindi non c'è nessuna responsabilità che resti a un WM.

**Perché non un compositor** (nota storica, cfr. sezione 15): CEF — il motore
usato da `unitotem-manager` per il rendering degli asset — è vincolato
architetturalmente a X11, perché `CefWindowInfo.SetAsChild` fa reparenting di
una finestra X11 nativa dentro la finestra Qt, cosa incompatibile col modello
di sicurezza Wayland (che non permette embedding cross-client di superfici).
A quel vincolo si aggiungeva che sway rifiuta esplicitamente di girare come
root (`sway/main.c:170`); cage (che invece lo permette) ha un modello
multi-monitor incompatibile (solo `-m last`/`-m extend`, non monitor
indipendenti); weston sarebbe stato praticabile ma resta un compositor
Wayland, quindi stesso muro con CEF. Da qui il passaggio a X11 puro, e la
rimozione del browser Chromium standalone (`chromium-kiosk` non era comunque
mai invocato da nessuna parte del codice) e della tastiera virtuale.

**Pacchetti** (gli stessi della sezione 14):
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
**Verificato end-to-end**, hot-plug e hot-unplug entrambi, senza mai
riavviare `unitotem-manager` (vedi metodo sotto).

**Config QEMU per due schermi** (basta `max_outputs=2`, non serve SPICE):
```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -device virtio-vga,max_outputs=2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=overlay.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:443 \
  -device virtio-net-pci,netdev=net0 \
  -vnc :1 -monitor unix:monitor.sock,server,nowait -daemonize -pidfile qemu.pid
```

`max_outputs=2` dà al guest un secondo connettore virtio-gpu (`Virtual-2` in
`xrandr`, `card0-Virtual-2` in `/sys/class/drm`), ma parte **disconnected**
finché nessuno lo "pluggia". Un primo tentativo con SPICE + un client
SPICE reale (headless via Docker+Xvfb+`remote-viewer`) si è rivelato un
vicolo cieco: il client apre davvero entrambi i canali display, ma il flip
dello stato connesso nel guest passa per forza per la negoziazione
"monitors config" di `spice-vdagent`, e `spice-vdagentd` rifiuta di attivare
l'agent senza una sessione logind valida - cosa che questa immagine, per
design (X avviato da `start-xorg.service` senza alcun display manager), non
ha. Tentato anche di creare una sessione logind fittizia
(`systemd-run -p PAMName=login -p User=root ...` - la sessione VIENE creata,
confermata via `loginctl list-sessions`) ma `spice-vdagentd` continua a
rifiutarsi con errori diversi a seconda dei flag. Anche `xrandr --auto`
(rifiutato, nessun EDID), `xrandr --setmonitor` (raggruppamento RandR 1.5,
Qt non lo enumera comunque - filtra rigorosamente sul bit `Connected` di un
Output, non su CRTC/mode attivi o su un "Monitor" logico), il backend
`-display dbus,p2p=on`, e i comandi QMP (nessuno esiste per lo stato di un
output virtio-gpu: `query-qmp-schema` non ne ha; `display-update`/
`display-reload` sono VNC-only) - tutti vicoli ciechi, nessuno flippa il
bit `Connected`.

**La soluzione reale: il connettore DRM del kernel è la fonte di verità, e
da root la si controlla direttamente via debugfs** - non serve affatto
passare per SPICE/X11/vdagent. Il connettore di ogni output virtio-gpu
espone un file `force` standard di debugfs (feature generica del DRM core,
non specifica di virtio-gpu):

```bash
mount | grep debugfs                       # deve essere montato (di solito lo è)
ls /sys/kernel/debug/dri/0/                 # Virtual-1  Virtual-2  crtc-0  crtc-1  ...

# "Plug" - forza il connettore a connected, scatena un evento hotplug DRM/udev
echo on > /sys/kernel/debug/dri/0/Virtual-2/force

# Xorg riceve l'evento e aggiorna RandR - basta assegnargli un mode
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth xrandr --query   # elenca i mode disponibili
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth \
  xrandr --output Virtual-2 --mode 3840x2160 --right-of Virtual-1

# "Unplug" - serve ANCHE spegnere il CRTC, altrimenti resta attivo anche se
# il connettore risulta "disconnected" (proprio come su hardware vero, un
# semplice sensore di presenza non basta a interrompere l'output video)
echo off > /sys/kernel/debug/dri/0/Virtual-2/force
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth xrandr --output Virtual-2 --off
```

Nota: `/sys/class/drm/card0-Virtual-2/status` (il file sysfs "informativo",
diverso dal debugfs `force`) può continuare a mostrare `disconnected` anche
a forzatura riuscita - è il probe EDID grezzo, non quello che Xorg/RandR
usano davvero (che è l'ioctl KMS `drm_mode_getconnector`, che il debugfs
override sovrascrive correttamente). Il segnale affidabile è `xrandr
--query`, non quel file.

**Verifica end-to-end** (nessun riavvio di `unitotem-manager` in tutta la
sequenza):
1. Boot con `max_outputs=2`: `unitotem-manager` all'avvio vede solo
   `Virtual-1` (1 screen, 1 window) - `Virtual-2` non è ancora forzato.
2. `echo on > .../Virtual-2/force` + `xrandr --output Virtual-2 --mode ...`:
   entro ~1s `Viewers/list` (via WebSocket) mostra 2 screens e 2 windows,
   con la geometria del nuovo screen esattamente corrispondente al mode
   appena assegnato - `screenAdded` è scattato per davvero.
3. `xrandr --output Virtual-2 --off` (dopo `force off`): entro ~1s
   `Viewers/list` torna a 1 screen/1 window - `screenRemoved` è scattato.
4. Ripetuto il "plug" con un mode diverso (es. `1024x768` poi `3840x2160`):
   il nuovo `window_id` è sempre incrementale (mai riusato), la geometria
   riportata combacia sempre con l'ultimo mode assegnato.

Metodo di verifica usato: query dirette del WebSocket `/ws` (login via
`/auth/token`, poi ascolto dei frame `Viewers/list`) con un browser headless
(Playwright in Docker, dato che né Playwright né un browser erano installati
sull'host) - non serve controllare la webui visivamente, il payload JSON è
già la prova diretta che `unitotem-manager` ha rilevato il cambiamento.

## 28. Deploy remoto — OTA a due stage via rete

Il deploy dell'immagine (`kiosk-<data>-<arch>.img.xz`, vedi §8 e
`kiosk/stage3-image.sh`) avviene interamente via rete, senza mai estrarre la
SD/il disco dalla macchina target né montare la sua root mentre gira. Design
completo, storia delle verifiche su hardware reale e dettagli implementativi
sono in `PLAN.md` (fonte autorevole) — questa sezione è solo un riassunto
orientato all'uso.

Il precedente approccio whole-disk `dd` (staging `ram`/`part`/`net`,
`deploy/build-flasher.sh` + `deploy/flasher/`) è stato interamente sostituito
da questo design e rimosso dal repository.

### 28.1 Come funziona, in breve

Ogni immagine porta con sé, generato dallo stage1 della build
(`kiosk/stage1-recovery-initrd.sh`), un kernel+initrd di **fallback
residente** minimale (nessun rootfs UniTotem, solo il necessario per parlare
SSH e ricevere un OTA) scritto sulla partizione di boot FAT accanto al kernel
del sistema reale. Il deploy procede in due stage:

1. **Stage 1** — installa/aggiorna il fallback sulla partizione di boot e lo
   rende **il default di avvio**: da questo momento qualunque perdita di
   alimentazione riporta la macchina in modalità ricevente, mai su un disco
   scritto a metà.
2. **Stage 2** — ripristina ROOT (e BOOT su amd64) per-partizione con
   `partclone`, preserva DATA di default, ripopola kernel/initrd/dtb del
   sistema reale, arma un **avvio di prova** (mai il default finché non è
   confermato), riavvia. Solo dopo che `unitotem-boot-ok.service` conferma il
   boot (raggiunto `multi-user.target`), il sistema reale viene promosso a
   default.

Due canali di rete indipendenti: **controllo = SSH** (`dropbear` nel
fallback, autenticazione a password fissa — stessa credenziale di accesso
interattivo, `root`/`unitotem` — chiave host effimera rigenerata a ogni
avvio, mai condivisa fra dispositivi), **dati = netcat puro** (una
connessione dedicata per partizione, nessun protocollo binario inventato). Il
guadagno rispetto a un `dd` whole-disk non è nella banda ma nei **byte
scritti**: solo lo spazio realmente occupato (~3 GiB tipici), non l'intera
immagine (12 GiB).

Quattro livelli indipendenti garantiscono che il fallback resti sempre
raggiungibile anche in caso di guasto durante o dopo il deploy: default di
boot, validazione pre-mount e post-mount nell'initramfs del sistema reale,
contatore di boot (tre avvii consecutivi non confermati → fallback
automatico).

### 28.2 Uso

```bash
./deploy/make-parts.sh --arch arm64 --image deploy/arm64/kiosk-<data>-arm64.img.xz   # genera il parts set

./deploy/remote-deploy.sh probe   root@totem-01
./deploy/remote-deploy.sh deploy  root@totem-01                    # target gia' UniTotem: arma da remoto
./deploy/remote-deploy.sh deploy  root@totem-01 --wipe-data        # come sopra, ma riformatta DATA
./deploy/remote-deploy.sh disarm  root@totem-01                    # annulla un arming non ancora avviato
```

Da un sistema UniTotem già in esecuzione, l'arming può anche partire in
locale: `/usr/sbin/unitotem-ota-arm --host <ip-host> [--port N] [--wipe-data]`.

### 28.3 Limiti noti

- Solo Raspberry Pi (arm64) e amd64 (UEFI o BIOS) — il firmware del target
  viene rilevato automaticamente (`/sys/firmware/efi`,
  `/proc/device-tree/model`).
- `blkid -L ROOT/DATA` per l'indirizzamento post-restore è per etichetta: con
  più dischi UniTotem collegati alla stessa macchina il risultato è ambiguo
  (`probe` scansiona tutti i dischi e avvisa se trova etichette duplicate).
- Sui Raspberry Pi con kernel Debian generico (non ancora passati a
  `linux-image-rpi-v8`, follow-up separato) l'avvio di prova non usa
  `tryboot` a livello firmware (non supportato da questo kernel) ma uno
  scambio diretto di `config.txt`, protetto dagli stessi quattro livelli di
  garanzia del fallback invece che dalla protezione firmware.
- `deploy/remote-deploy.sh recover`/`serve` (percorso di recupero per un
  target già in fallback con host sconosciuto) restano un percorso avanzato
  non ancora automatizzato end-to-end.
