#!/bin/bash
set -euo pipefail
source /unitotem/common.sh

echo "=== Stage 1: Package Installation (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

echo "Extracting stage 0..."
tar -I pigz -C "${ROOTFS}" -xf "${WORK_DIR}/stage0.tar.gz"

ensure_qemu
mount_chroot
install_policy_rc

# Build-time only: dpkg fsync()s every file it unpacks, which dominates the install on the
# container's overlay filesystem. The result is tarred and re-checked, so a crash costs a rerun.
# Removed again before the tarball is made (see "Clean up").
# Downloaded .debs persist across builds in work/apt-cache (mounted at /aptcache).
if [ -d /aptcache ]; then
    mkdir -p "/aptcache/${ARCH}/partial" "${ROOTFS}/var/cache/apt/archives"
    mount --bind "/aptcache/${ARCH}" "${ROOTFS}/var/cache/apt/archives"
fi
mkdir -p "${ROOTFS}/etc/apt/apt.conf.d"
echo 'Dpkg::Options { "--force-unsafe-io"; };' > "${ROOTFS}/etc/apt/apt.conf.d/99-build-unsafe-io"

# ---------- APT sources ----------

# Written from $RELEASE so the suite always matches the bootstrapped base.
cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-backports main contrib non-free non-free-firmware
EOF

if [ "$ARCH" = "arm64" ]; then
    # The packaged raspberrypi-archive-keyring, not the legacy raspberrypi.gpg.key URL:
    # that key is self-signed with SHA1, which trixie's apt refuses. The trixie package
    # carries the same key re-signed with SHA512. The filename comes from the suite's
    # Packages index. The awk program has no early `exit`: it would SIGPIPE curl/gzip
    # and pipefail would abort the script silently.
    RPI_KEYRING_DEB=$(curl -fsSL "https://archive.raspberrypi.org/debian/dists/${RELEASE}/main/binary-${ARCH}/Packages.gz" \
        | gzip -dc | awk '/^Package: /{f=($0=="Package: raspberrypi-archive-keyring")} f&&/^Filename:/{print $2}')
    [ -n "$RPI_KEYRING_DEB" ] || { echo "ERROR: raspberrypi-archive-keyring not found for ${RELEASE}" >&2; exit 1; }
    curl -fsSL "https://archive.raspberrypi.org/debian/${RPI_KEYRING_DEB}" -o /tmp/rpi-keyring.deb
    dpkg-deb -x /tmp/rpi-keyring.deb /tmp/rpi-keyring
    install -Dm644 /tmp/rpi-keyring/usr/share/keyrings/raspberrypi-archive-keyring.gpg \
        "${ROOTFS}/etc/apt/trusted.gpg.d/raspberrypi.gpg"
    rm -rf /tmp/rpi-keyring.deb /tmp/rpi-keyring
    echo "deb http://archive.raspberrypi.org/debian/ ${RELEASE} main" \
        > "${ROOTFS}/etc/apt/sources.list.d/raspi.list"
fi
if [ "$ARCH" = "amd64" ]; then
    # The NVIDIA driver comes from NVIDIA's CUDA repository, not Debian: Debian's branch 550 does not build on kernel 7.x. The repository
    # is laid out for Debian 13 only, hence the guard. The key is the one of NVIDIA's cuda-keyring package, downloaded over HTTPS (trust on
    # first fetch); its only primary key must have the fingerprint pinned here. NVIDIA publishes no fingerprint page: the key ID 8793F200 is
    # confirmed by a forum thread. The key is used through signed-by only (no apt-key, nothing in trusted.gpg.d).
    [ "$RELEASE" = trixie ] || { echo "ERROR: the NVIDIA repository is debian13 (trixie only), RELEASE=${RELEASE}" >&2; exit 1; }
    NVIDIA_KEY_FPR=02182E60104FCDC26EAE1B8597A5D4CB8793F200
    NVIDIA_REPO=https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64
    rm -rf /tmp/unitotem-nvidia-keyring
    mkdir -p /tmp/unitotem-nvidia-keyring/gnupg
    chmod 700 /tmp/unitotem-nvidia-keyring/gnupg
    curl -fsSL "${NVIDIA_REPO}/cuda-keyring_1.1-1_all.deb" -o /tmp/unitotem-nvidia-keyring/cuda-keyring.deb
    dpkg-deb -x /tmp/unitotem-nvidia-keyring/cuda-keyring.deb /tmp/unitotem-nvidia-keyring/x
    NVIDIA_KEYRING=/tmp/unitotem-nvidia-keyring/x/usr/share/keyrings/cuda-archive-keyring.gpg
    [ -s "$NVIDIA_KEYRING" ] || { echo "ERROR: cuda-archive-keyring.gpg is not in cuda-keyring_1.1-1_all.deb" >&2; exit 1; }
    # 'pub' opens a primary key and the 'fpr' line after it is that key's fingerprint: two keys give two lines, which is a mismatch.
    NVIDIA_FPRS=$(gpg --homedir /tmp/unitotem-nvidia-keyring/gnupg --no-default-keyring --with-colons --show-keys "$NVIDIA_KEYRING" 2>/dev/null \
        | awk -F: '$1=="pub"{want=1; next} $1=="fpr" && want {print $10; want=0}') \
        || { echo "ERROR: cannot read the NVIDIA keyring" >&2; exit 1; }
    [ "$NVIDIA_FPRS" = "$NVIDIA_KEY_FPR" ] || { echo "ERROR: NVIDIA key fingerprint is '${NVIDIA_FPRS}', expected ${NVIDIA_KEY_FPR}" >&2; exit 1; }
    mkdir -p "${ROOTFS}/usr/share/keyrings" "${ROOTFS}/etc/apt/sources.list.d" "${ROOTFS}/etc/apt/preferences.d"
    install -m 644 "$NVIDIA_KEYRING" "${ROOTFS}/usr/share/keyrings/unitotem-nvidia.gpg"
    echo "deb [signed-by=/usr/share/keyrings/unitotem-nvidia.gpg] ${NVIDIA_REPO} /" > "${ROOTFS}/etc/apt/sources.list.d/unitotem-nvidia.list"
    # Stage 1 only (removed in "Package lock: verify or freeze"). NVIDIA's packages come from 995, so they beat the backports pin (990);
    # every other NVIDIA-origin package is excluded, so NVIDIA's dkms, libegl1, ... never replace Debian's.
    cat > "${ROOTFS}/etc/apt/preferences.d/96-unitotem-nvidia" << 'EOF_NV'
Package: nvidia-* libnvidia-* libgles-nvidia* libegl-nvidia* libglx-nvidia* firmware-nvidia-gsp xserver-xorg-video-nvidia glx-alternative-nvidia
Pin: origin developer.download.nvidia.com
Pin-Priority: 995

Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF_NV
    rm -rf /tmp/unitotem-nvidia-keyring
fi

# trixie-backports is NotAutomatic (priority 100): only the packages named in 97-unitotem-backports (priority 990) come from it.
# A pin, not `apt-get -t`: -t would pull every dependency that has a backports build. The file stays in the image.
mkdir -p "${ROOTFS}/etc/apt/preferences.d"
if [ "$ARCH" = "amd64" ]; then
    cat > "${ROOTFS}/etc/apt/preferences.d/97-unitotem-backports" << 'EOF_BPO'
# trixie-backports: only these packages (and what their dependencies force) come from it; everything else stays on the stable suite
Package: linux-base linux-image-* linux-headers-* linux-kbuild-* linux-compiler-gcc-* linux-support-* firmware-* mesa-* libgl1-mesa-dri libegl-mesa0 libglx-mesa0 libgbm1 libglapi-mesa pipewire pipewire-* libpipewire-* libspa-0.2-* wireplumber wireplumber-* libwireplumber-* gir1.2-wp-*
Pin: release n=trixie-backports
Pin-Priority: 990
EOF_BPO
elif [ "$ARCH" = "arm64" ]; then
    cat > "${ROOTFS}/etc/apt/preferences.d/97-unitotem-backports" << 'EOF_BPO'
# trixie-backports: only PipeWire and WirePlumber come from it (the kernel, firmware and Mesa come from the Raspberry Pi archive / stable)
Package: pipewire pipewire-* libpipewire-* libspa-0.2-* wireplumber wireplumber-* libwireplumber-* gir1.2-wp-*
Pin: release n=trixie-backports
Pin-Priority: 990
EOF_BPO
else
    echo "ERROR: no backports pins for ${ARCH}" >&2; exit 1
fi

# UniTotem Manager repository
curl -fsSL https://a13ssandr0.github.io/unitotem-manager/KEY.gpg \
    > "${ROOTFS}/etc/apt/trusted.gpg.d/unitotem-manager.asc"
curl -fsSL https://a13ssandr0.github.io/unitotem-manager/unitotem-manager.list \
    > "${ROOTFS}/etc/apt/sources.list.d/unitotem-manager.list"

# ---------- Package lock (repeatable builds) ----------
# unitotem/locks/<arch>.lock pins every archive package to an exact version (see tools/pkglock.py). With a lock: the Debian archives are
# read from the snapshot taken when the lock was frozen, every locked package is pinned to its version, and at the end the installed set must be
# EXACTLY the lock. Without a lock (first build, or after `pkglock.py upgrade`): the live archives are used and a new lock is frozen at the end.
# PKGLOCK=off skips all of it.
PKGLOCK_FILE="/unitotem/locks/${ARCH}.lock"
PKGLOCKED=0
if [ "${PKGLOCK:-on}" != off ] && [ -f "$PKGLOCK_FILE" ]; then
    PKGLOCKED=1
    SNAP=$(python3 /unitotem/pkglock.py snapshot "$PKGLOCK_FILE") || { echo "ERROR: the lock records no Debian snapshot" >&2; exit 1; }
    echo ">>> package lock: ${PKGLOCK_FILE}, Debian snapshot ${SNAP}"
    cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb http://snapshot.debian.org/archive/debian/${SNAP}/ ${RELEASE} main contrib non-free non-free-firmware
deb http://snapshot.debian.org/archive/debian/${SNAP}/ ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://snapshot.debian.org/archive/debian-security/${SNAP}/ ${RELEASE}-security main contrib non-free non-free-firmware
deb http://snapshot.debian.org/archive/debian/${SNAP}/ ${RELEASE}-backports main contrib non-free non-free-firmware
EOF
    echo 'Acquire::Check-Valid-Until "false";' > "${ROOTFS}/etc/apt/apt.conf.d/99-pkglock"
    mkdir -p "${ROOTFS}/etc/apt/preferences.d"
    python3 /unitotem/pkglock.py prefs "$PKGLOCK_FILE" > "${ROOTFS}/etc/apt/preferences.d/99-unitotem-lock"
fi

# The NVIDIA repository (sources.list.d/unitotem-nvidia.list) has no snapshot and is read live, also with a lock. A locked NVIDIA version
# that NVIDIA has withdrawn makes the installs below fail: renew the lock (tools/pkglock.py upgrade amd64).
chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get update
PKGLOCK_FROZEN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "${PKGLOCK:-on}" != off ]; then
    # The stage-0 base (debootstrap, from an older day) must match what the archives (or the lock's pins) say: with a lock this moves each
    # package up or down to its locked version; without one it brings the base to the current versions, security fixes included.
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades dist-upgrade
fi

# Recommends nobody needs, kept out of stage 1 only (the file is removed in "Clean up", the shipped image has no pin): the speech model of
# libpocketsphinx3 (ffmpeg filter), ghostscript (ImageMagick), iso-codes, Qt/NetworkManager translations, glib data (translations).
# None of them is an alternative of a Depends, so the pin cannot redirect apt to another provider (checked by simulation).
mkdir -p "${ROOTFS}/etc/apt/preferences.d"
cat > "${ROOTFS}/etc/apt/preferences.d/98-unitotem-stage1-skip" << 'EOF_PIN'
Package: pocketsphinx-en-us ghostscript iso-codes qt6-translations-l10n network-manager-l10n libglib2.0-data
Pin: release *
Pin-Priority: -1
EOF_PIN

# ---------- Kernel + firmware + bootloader ----------

# The kernel version of the rootfs. Fails unless /lib/modules holds exactly one kernel: a second one (stable and backports) would make
# the checks below test an arbitrary one.
rootfs_kver() {
    local dirs n
    dirs=$(chroot "${ROOTFS}" find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n') || dirs=""
    n=$(printf '%s' "$dirs" | grep -c . || true)
    if [ "$n" != 1 ]; then
        echo "ERROR: expected exactly one kernel in /lib/modules, found ${n}: $(echo $dirs)" >&2
        return 1
    fi
    echo "$dirs"
}

# The NVIDIA module DKMS builds (nvidia-kernel-open-dkms 620: nvidia.ko, or a compressed nvidia.ko.*) for kernel $1.
nvidia_module_present() {
    chroot "${ROOTFS}" sh -c "ls /lib/modules/$1/updates/dkms/nvidia.ko* >/dev/null 2>&1"
}

if [ "$ARCH" = "amd64" ]; then
    # Kernel and firmware come from trixie-backports (pinned in 97-unitotem-backports).
    # linux-headers-amd64 provides the headers for the NVIDIA DKMS build below and
    # stays in the shipped image (see the note beside that build).
    # initramfs-tools first: the 7.2 kernel depends on `dracut | initramfs-tools` and apt would pick dracut.
    apt_install --no-install-recommends initramfs-tools zstd
    apt_install --no-install-recommends \
        linux-image-amd64 \
        linux-headers-amd64 \
        firmware-linux \
        firmware-linux-nonfree \
        firmware-misc-nonfree \
        firmware-intel-graphics \
        firmware-iwlwifi \
        firmware-realtek \
        firmware-atheros \
        firmware-mediatek \
        firmware-brcm80211 \
        firmware-intel-misc \
        intel-microcode \
        amd64-microcode
    # firmware-nvidia-graphics (stable, not the backports build: 63 MiB installed against 153 MiB, same gp10x blobs): the signed
    # firmware nouveau needs on Pascal and older GPUs (GP106 acr/gr/sec2). Without it labwc dies at 'nvc0_screen_create' and the kiosk
    # never starts. Installed here because apt cannot install anything after the compiler purge.
    apt_install --no-install-recommends firmware-nvidia-graphics/trixie
    # Wi-Fi and Bluetooth firmware of the common PC cards (Intel, Realtek, Atheros, MediaTek, Broadcom): in Debian 13
    # firmware-linux-nonfree depends only on firmware-misc-nonfree and firmware-amd-graphics, so without these a PC has no
    # Wi-Fi or Bluetooth (the kernel drivers are there, the firmware files are not). intel-microcode and amd64-microcode:
    # CPU microcode updates, loaded early from the initramfs.
    # firmware-intel-graphics: i915 display (DMC), GuC and HuC firmware. Without it i915 logs
    # 'failed to load i915/adlp_dmc.bin' and the iHD VA-API driver cannot initialise (vaInitialize failed): no hardware video decode.
    apt_install --no-install-recommends \
        grub-efi-amd64 \
        grub-pc-bin \
        efibootmgr
    # Secure Boot chain, the image's boot loader (stage 3 puts the signed binaries in EFI/BOOT on the ESP, shim as BOOTX64.EFI): shim-signed
    # (Microsoft-signed shim, dual-signed with the 2011 and 2023 UEFI CAs; embeds the Debian CA), grub-efi-amd64-signed (GRUB signed by the
    # Debian CA) and shim-helpers-amd64-signed (MokManager). The kernel is already Debian-signed. mokutil is for the physical-intervention
    # path (MOK enrolment of the NVIDIA module's key).
    apt_install --no-install-recommends shim-signed grub-efi-amd64-signed mokutil

elif [ "$ARCH" = "arm64" ]; then
    # linux-image-rpi-v8, not linux-image-arm64: its version matches raspi-firmware's z50 postinst hook (flavour v8)
    # and it ships overlays/ (KMS). raspi-firmware provides bootcode.bin/fixup*/start*.elf, copied into /boot/firmware
    # even inside this chroot.
    apt_install --no-install-recommends \
        linux-image-rpi-v8 \
        firmware-brcm80211 \
        raspi-firmware
fi

# ---------- OTA payload (deploy/ota-engine.sh, unitotem/files/ota-hook) ----------
# Installed in stage1 so one package list covers both the resident fallback
# (unitotem/stage1-recovery-initrd.sh builds it from this rootfs) and the real
# system's initramfs (stage2). gdisk/parted are kept for manual disaster recovery.
apt_install --no-install-recommends \
    partclone gdisk parted fdisk pv netcat-traditional dropbear-bin wpasupplicant whiptail dosfstools xz-utils

mkdir -p "${ROOTFS}/usr/lib/unitotem"
install -m 755 /unitotem/files/ota-engine.sh "${ROOTFS}/usr/lib/unitotem/ota-engine.sh"
ln -sf /usr/lib/unitotem/ota-engine.sh "${ROOTFS}/usr/sbin/unitotem-ota-engine"
# framebuffer frame of the deploy/recovery screen's progress dialog (pre-rendered by tools/gen-frame.py)
for _f in /unitotem/files/unitotem-frame-line.* /unitotem/files/unitotem-frame-corners-*; do
    [ -s "$_f" ] || { echo "ERROR: frame piece missing: $_f" >&2; exit 1; }
    install -m 644 "$_f" "${ROOTFS}/usr/lib/unitotem/"
done
# framebuffer logo of the deploy/recovery screen (pre-rendered by tools/gen-logo.py)
install -m 644 /unitotem/files/unitotem-logo-256x73.bgrx /unitotem/files/unitotem-logo-640x182.bgrx \
    /unitotem/files/unitotem-logo-256x73.rgb565 /unitotem/files/unitotem-logo-640x182.rgb565 \
    /unitotem/files/unitotem-logo-1280x365.bgrx /unitotem/files/unitotem-logo-1280x365.rgb565 "${ROOTFS}/usr/lib/unitotem/"   # the largest is for the placeholder on 4K; the real system'"'"'s KMS framebuffer can be 16 OR 32 bpp (16 on a Raspberry Pi 4)

install -m 755 /unitotem/files/ota-hook "${ROOTFS}/etc/initramfs-tools/hooks/unitotem-ota"
# zstd -19 instead of the gzip that mkinitramfs falls back to when zstd is missing in the chroot: ~25% smaller, the Pi kernel has CONFIG_RD_ZSTD.
mkdir -p "${ROOTFS}/etc/initramfs-tools/conf.d"
printf 'COMPRESS=zstd\nCOMPRESSLEVEL=19\n' > "${ROOTFS}/etc/initramfs-tools/conf.d/unitotem-compress"
mkdir -p "${ROOTFS}/etc/unitotem"

# ---------- Base system ----------

apt_install \
    locales \
    sudo adduser curl wget ca-certificates gnupg2 \
    openssh-server \
    iproute2 iputils-ping net-tools \
    htop btop nano less \
    util-linux udev e2fsprogs \
    lsb-release initramfs-tools apt-utils zstd \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    network-manager netplan.io \
    python3 python3-dbus python3-gi python3-pyudev python3-libgpiod \
    gir1.2-glib-2.0 \
    iptables

# Password quality (PAM profile in stage2). No Recommends: they would add cracklib-runtime and wamerican, which the policy does not use (dictcheck=0).
apt_install --no-install-recommends libpam-pwquality

# ---------- Plymouth ----------

# plymouth-label (pango/cairo/X11/harfbuzz/..., ~4 MB of initramfs) and plymouth-themes are NOT installed: the UniTotem theme is built
# from pre-rendered PNGs and draws no text (plymouth-theme-unitotem depends on plymouth only). The firmware reads the initramfs
# at ~5 MB/s, so every MB of it is ~0.2 s of black screen at boot.
apt_install \
    plymouth libplymouth5

# ---------- GPU libraries (common) ----------

apt_install \
    libglvnd0 libglx0 libgles2 libvulkan1 \
    mesa-utils libgl1-mesa-dri

# ---------- GPU drivers (arch-specific) ----------

if [ "$ARCH" = "amd64" ]; then
    # One image, three GPU vendors: libglvnd dispatches GL to whichever driver is
    # present at runtime, so Mesa (Intel/AMD) and the NVIDIA blob coexist. The
    # compositor (labwc) uses the kernel KMS drivers (i915/xe, amdgpu, nvidia-drm)
    # through libdrm/GBM.

    # Mesa from trixie-backports (iris, radeonsi). mesa-va-drivers is not in the shared block above. mesa-vulkan-drivers
    # (libvulkan1 recommends it) is purged in "Remove what the shipped system does not need": the viewer uses ANGLE-GL only.
    apt_install \
        libgl1-mesa-dri mesa-va-drivers mesa-utils

    # Intel, including ARC. intel-media-va-driver-non-free is the iHD driver
    # and covers Gen8 onwards, DG2/ARC included; i965 is kept for Gen4-8
    # hardware that iHD dropped. Both can be installed: libva selects by PCI
    # ID at runtime.
    apt_install \
        intel-media-va-driver-non-free \
        i965-va-driver-shaders \
        libva2 libva-drm2 vainfo

    # AMD: the kernel driver is in-tree; userspace needs the firmware and libdrm.
    apt_install \
        firmware-amd-graphics libdrm-amdgpu1

    # NVIDIA proprietary driver, branch 620 with the open kernel modules, from NVIDIA's repository (source block at the top of this file).
    # Turing and newer only: the open modules do not support Maxwell, Pascal or Volta, which run on nouveau/NVK.
    # --no-install-recommends: no CUDA, NVDEC or Vulkan libraries. The module is built by DKMS against this image's kernel, which stays
    # matched because nothing upgrades in place. nvidia-kernel-support blacklists nouveau; stage 2 loads nvidia-drm and falls back to nouveau
    # for an NVIDIA display device the open modules do not drive.
    # No nvidia-vaapi-driver: Chromium does not use VA-API on NVIDIA (manager gpu.py, _NVIDIA_DRM_NAMES).
    apt_install --no-install-recommends \
        nvidia-kernel-open-dkms nvidia-kernel-support firmware-nvidia-gsp \
        libnvidia-allocator1 libnvidia-egl-gbm1 libgles-nvidia1 libgles-nvidia2 libegl-nvidia0 libglx-nvidia0 nvidia-egl-icd

    # Fail the build if the NVIDIA module did not build: apt only warns about DKMS failures.
    KVER=$(rootfs_kver)
    nvidia_module_present "$KVER" \
        || { echo "ERROR: the NVIDIA module was not built for ${KVER}" >&2; exit 1; }
    echo "NVIDIA module built for ${KVER}"

    # linux-headers and the DKMS toolchain are not purged here: they let DKMS rebuild
    # the module after an in-place kernel upgrade through `unitotem-maintenance enter`.

elif [ "$ARCH" = "arm64" ]; then
    # No VAAPI on arm64 (VideoCore has none): hardware decode goes through V4L2 mem2mem (/dev/video10 for H.264,
    # /dev/video19 for HEVC on Pi 4+).
    # Diagnostics only: v4l2-ctl, vcgencmd (throttling detection).
    apt_install \
        v4l-utils \
        raspi-utils
fi

# ---------- Wayland session (labwc) + PipeWire ----------
# The kiosk runs on Wayland only: the compositor is labwc, started by
# unitotem-compositor.service (shipped, disabled, by the unitotem-viewer deb; enabled in stage 2). There is no X server on the image;
# xwayland is installed only because labwc starts it lazily and logs an error without it (no X client is run).

# Screen control in the manager (DDC/CI, CEC): ddcutil >= 2.0 (trixie has 2.1), cec-ctl comes from v4l-utils (installed
# above on arm64 only, so named here for both), i2c-tools; the i2c-dev module is loaded at boot (stage2).
apt_install ddcutil v4l-utils i2c-tools

apt_install \
    labwc wlr-randr wlopm wayvnc xwayland qt6-wayland kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    libspa-0.2-bluetooth
# No GStreamer: the viewer is CEF (own ffmpeg) and the VNC server is wayvnc.

# ---------- UniTotem packages ----------

# The manager (3.0.0~dev5 onwards) runs on the system Python with Debian's own packages: no virtualenv, so no pip/venv/-dev libraries
# (python3-pip would pull build-essential into the arm64 image).
apt_install \
    python3-apt \
    openssl mediainfo rfkill alsa-utils cron libxcb-icccm4 libxcb-shape0

# The packages come from the manager's own build (its tools/build-debs.sh), one directory per architecture:
#   work/extra-debs/<arch>/  unitotem (metapackage), unitotem-manager, unitotem-node, unitotem-viewer, plymouth-theme-unitotem (all arch-all,
#   identical on both architectures), python3-cefpython3 (the only binary one: amd64 or arm64), and the two libraries Debian does not ship
#   (python3-fastapi-login, python3-sdbus-networkmanager). apt resolves everything else from Debian trixie (and the Raspberry Pi repository).
LOCAL_DEB_DIR=/work/extra-debs/${ARCH}
# There is no image without the 3.x manager: the repository's 2.x package is not a
# substitute. Fail here, early, instead of finding out on the device.
if ! ls "$LOCAL_DEB_DIR"/*.deb >/dev/null 2>&1; then
    echo "ERROR: no unitotem 3.x package supplied (work/extra-debs/${ARCH}/)." >&2
    echo "       An image without the 3.x manager must not be built." >&2
    exit 1
fi
# ...and the SET must be complete: a missing binary package would otherwise surface as an apt dependency error far from the cause.
for pkg in unitotem_ unitotem-manager_ unitotem-node_ unitotem-viewer_ plymouth-theme-unitotem_ "python3-cefpython3_" python3-fastapi-login_ python3-sdbus-networkmanager_; do
    ls "$LOCAL_DEB_DIR"/${pkg}*.deb >/dev/null 2>&1 \
        || { echo "ERROR: ${pkg}*.deb missing in work/extra-debs/${ARCH}/ (the complete manager set is required, see the comment above)" >&2; exit 1; }
done
ls "$LOCAL_DEB_DIR"/python3-cefpython3_*_${ARCH}.deb >/dev/null 2>&1 \
    || { echo "ERROR: python3-cefpython3 for ${ARCH} is not in work/extra-debs/${ARCH}/ (a .deb of another architecture cannot be installed)" >&2; exit 1; }

# Every .deb in work/extra-debs/<arch>/ is installed over what the apt repository provided,
# so an image can carry a manager build that is not published.
if ls "$LOCAL_DEB_DIR"/*.deb >/dev/null 2>&1; then
    mkdir -p "${ROOTFS}/tmp/extra-debs"
    printf 'local .deb installed: %s\n' "$LOCAL_DEB_DIR"/*.deb
    cp "$LOCAL_DEB_DIR"/*.deb "${ROOTFS}/tmp/extra-debs/"
    chroot "${ROOTFS}" sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades /tmp/extra-debs/*.deb"
    # haproxy (a dependency of the repository's 2.x manager) would answer ports 80/443
    # with a 503; the 3.x manager binds them itself.
    if chroot "${ROOTFS}" dpkg -s haproxy >/dev/null 2>&1; then
        chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y haproxy
    fi
    rm -rf "${ROOTFS}/tmp/extra-debs"
    # CEF execs cefpython3/subprocess; python3-cefpython3 3.0.0~dev5 shipped it as 0644,
    # so CEF died with "Cannot communicate with zygote". dpkg-statoverride fixes the mode;
    # a fixed package makes this a no-op.
    CEFSUB=/usr/lib/python3/dist-packages/cefpython3/subprocess
    if [ ! -x "${ROOTFS}${CEFSUB}" ]; then
        echo ">>> WARNING: ${CEFSUB} is not executable in the package: applying a dpkg-statoverride 0755 (fix python3-cefpython3)"
        chroot "${ROOTFS}" dpkg-statoverride --update --add root root 0755 "${CEFSUB}"
    fi
    [ -x "${ROOTFS}${CEFSUB}" ] || { echo "ERROR: ${CEFSUB} is not executable" >&2; exit 1; }
    for pkg in unitotem unitotem-manager unitotem-node unitotem-viewer python3-cefpython3 plymouth-theme-unitotem; do
        v=$(chroot "${ROOTFS}" dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
        case "$v" in 3.*) ;; *) echo "ERROR: $pkg is not installed at version 3.x (found: '${v}')" >&2; exit 1 ;; esac
    done
fi

# ---------- Clean up ----------
rm -f "${ROOTFS}/etc/apt/apt.conf.d/99-build-unsafe-io" "${ROOTFS}/etc/apt/preferences.d/98-unitotem-stage1-skip"
# Unmount the cache BEFORE apt-get clean: clean empties the archive directory, which would wipe the cache.
mountpoint -q "${ROOTFS}/var/cache/apt/archives" && umount "${ROOTFS}/var/cache/apt/archives"

# ---------- Remove what the shipped system does not need ----------
# Chromium and the compilers are removed: updates are whole images, nothing is built or
# upgraded in place at runtime. Chromium (arm64 only) came in as a recommended dependency
# of the 2.x manager; the compilers come in through build-essential (python3-pip on arm64,
# dkms on amd64). The removal list is printed first and the NVIDIA module is asserted after.
purge_list() { # names from $@ that are actually installed
    local p; for p in "$@"; do chroot "${ROOTFS}" dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && echo "$p"; done
    # Always succeed: the loop's status is that of the last name, which would stop the build under set -e.
    return 0
}
# Libraries the product never loads, pulled in by Recommends or by a Depends that links nothing:
#  - mesa-vulkan-drivers: the viewer renders through ANGLE-GL (libgallium keeps llvmpipe and radeonsi); nothing depends on it.
# No NVIDIA library is listed: the NVIDIA set is installed with --no-install-recommends and pulls no CUDA, NVDEC or Vulkan ICD library
# (simulated against NVIDIA's repository, 2026-11-08). libnvidia-allocator1, libnvidia-egl-gbm1 and libgles-nvidia* are needed by labwc.
# apt (not dpkg --force-depends): the dry run shows what else would go, and the DKMS module is asserted afterwards.
# Before the compilers are force-purged below: afterwards dpkg has unmet dependencies (linux-headers needs gcc-14) and apt refuses to remove anything.
REMOVE_LIBS=$(purge_list mesa-vulkan-drivers)
echo ">>> removing unused libraries (apt): $(echo $REMOVE_LIBS)"
if [ -n "$(echo $REMOVE_LIBS)" ]; then
    # shellcheck disable=SC2086
    { chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get -s purge $REMOVE_LIBS 2>&1 | grep -E '^(Remv|E:)' | sed 's/^/    dry-run: /'; } || true
    # shellcheck disable=SC2086
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $REMOVE_LIBS
fi
if [ "$ARCH" = "arm64" ]; then
    REMOVE=$(purge_list chromium chromium-browser chromium-common chromium-l10n rpi-chromium-mods)
    echo ">>> removing (arm64, apt): $(echo $REMOVE)"
    if [ -n "$REMOVE" ]; then
        # shellcheck disable=SC2086
        { chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get -s purge $REMOVE 2>&1 | grep -E '^(Remv|E:)' | sed 's/^/    dry-run: /'; } || true   # informational only: must never stop the build
        # shellcheck disable=SC2086
        chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $REMOVE
    fi
    # The compilers go with dpkg --force-depends, not apt: `apt-get purge cpp` would also take
    # packages that depend on cpp. Harmless unmet-dependency note in `dpkg --audit`.
    REMOVE_CC=$(purge_list build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 \
                           gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cpp-aarch64-linux-gnu \
                           gcc-14-aarch64-linux-gnu g++-14-aarch64-linux-gnu cpp-14-aarch64-linux-gnu)
    echo ">>> removing (arm64, dpkg --force-depends): $(echo $REMOVE_CC)"
    # shellcheck disable=SC2086
    [ -z "$REMOVE_CC" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $REMOVE_CC
    # the manager must still be there: apt may have taken it along if it had a hard dependency on any of the above
    chroot "${ROOTFS}" dpkg-query -W -f='${Status}' unitotem-manager | grep -q 'ok installed' \
        || { echo "ERROR: removing Chromium/compilers also removed unitotem-manager" >&2; exit 1; }
else
    # dkms depends on the compilers, so apt would remove them and dkms's prerm would delete the
    # built NVIDIA module. dpkg --force-depends removes only the compilers.
    # gcc-14-for-host and cpp-14-for-host: the kernel headers (7.2) depend on them.
    REMOVE=$(purge_list build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 gcc-14-for-host cpp-14-for-host \
                        gcc-x86-64-linux-gnu g++-x86-64-linux-gnu cpp-x86-64-linux-gnu \
                        gcc-14-x86-64-linux-gnu g++-14-x86-64-linux-gnu cpp-14-x86-64-linux-gnu)
    echo ">>> removing (amd64, dpkg --force-depends): $(echo $REMOVE)"
    # shellcheck disable=SC2086
    [ -z "$REMOVE" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $REMOVE
    KVER=$(rootfs_kver)
    nvidia_module_present "$KVER" \
        || { echo "ERROR: the NVIDIA module disappeared when removing the compilers" >&2; exit 1; }
fi
# libshiboken6 declares a dependency on libclang1-19 (the generator's library) but no shared object of it links or loads libclang.
# dpkg --force-depends like the compilers; libllvm19 stays (Mesa).
CLANG=$(purge_list libclang1-19)
echo ">>> removing (dpkg --force-depends): $(echo $CLANG)"
# shellcheck disable=SC2086
[ -z "$CLANG" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $CLANG
if [ "$ARCH" = "amd64" ]; then
    KVER=$(rootfs_kver)
    nvidia_module_present "$KVER" \
        || { echo "ERROR: the NVIDIA module disappeared when removing the NVIDIA extras" >&2; exit 1; }
fi
# The NVIDIA module (amd64) is signed with a DKMS key generated in this build
# (/var/lib/dkms/mok.key). That private key would be the same on every device, and a device
# that enrolled mok.pub (Secure Boot) would accept modules signed by anyone holding the image.
# Nothing at runtime needs it: keep only the public certificate.
if [ "$ARCH" = "amd64" ] && [ -e "${ROOTFS}/var/lib/dkms/mok.key" ]; then
    rm -f "${ROOTFS}/var/lib/dkms/mok.key"
    echo ">>> removed the DKMS module-signing private key from the image (mok.pub kept)"
fi
# No X server on the image: the NVIDIA driver and a few packages pull xserver-xorg-core in,
# but nothing starts it. Removed with dpkg --force-depends like the compilers; xwayland stays.
XPURGE=$(purge_list xserver-xorg-core xserver-xorg-legacy xserver-xorg xserver-xorg-input-all xserver-xorg-video-all xinit x11-xserver-utils)
echo ">>> removing the X server (dpkg --force-depends): $(echo $XPURGE)"
# shellcheck disable=SC2086
[ -z "$XPURGE" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $XPURGE
# What the Wayland session needs must have survived the removals above, on every architecture.
for t in labwc wlr-randr wlopm wayvnc; do
    chroot "${ROOTFS}" sh -c "command -v $t >/dev/null" || { echo "ERROR: $t disappeared with the removal of compilers/Chromium" >&2; exit 1; }
done
# ...and so must the libraries behind them (llvmpipe/radeonsi, the ffmpeg chain of wayvnc).
for pkg in mesa-libgallium libllvm19 libneatvnc0 libavcodec61; do
    chroot "${ROOTFS}" dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' \
        || { [ "$pkg" = libneatvnc0 ] && chroot "${ROOTFS}" dpkg-query -W -f='${Status}' libneatvnc1 2>/dev/null | grep -q 'ok installed'; } \
        || { echo "ERROR: $pkg disappeared with the removal of unused libraries" >&2; exit 1; }
done
echo ">>> installed size of / after removal: $(du -sxm "${ROOTFS}" | cut -f1) MiB"

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

remove_policy_rc
umount_chroot

echo "Saving stage 1 tarball..."
# ---------- Package lock: verify or freeze ----------
if [ "$PKGLOCKED" = 1 ]; then
    python3 /unitotem/pkglock.py verify "$PKGLOCK_FILE" "${ROOTFS}" || { echo "ERROR: the image does not match the package lock (see above): run tools/pkglock.py upgrade ${ARCH} if the packages changed on purpose" >&2; exit 1; }
    # the shipped image does not carry the snapshot sources or the pins (a device never runs apt): back to the ordinary ones
    rm -f "${ROOTFS}/etc/apt/preferences.d/99-unitotem-lock" "${ROOTFS}/etc/apt/apt.conf.d/99-pkglock"
    cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-backports main contrib non-free non-free-firmware
EOF
elif [ "${PKGLOCK:-on}" != off ]; then
    mkdir -p "${WORK_DIR}"
    python3 /unitotem/pkglock.py freeze "${ROOTFS}" --arch "${ARCH}" --release "${RELEASE}" --snapshot "${PKGLOCK_FROZEN_AT}" --out "${WORK_DIR}/${ARCH}.lock.new"
    echo ">>> NEW package lock in work/${ARCH}/${ARCH}.lock.new: copy it to unitotem/locks/${ARCH}.lock and commit it"
fi
# The NVIDIA repository is a build-time source, like the snapshot sources above: the image carries none of its files (amd64 only, no-op elsewhere).
rm -f "${ROOTFS}/etc/apt/sources.list.d/unitotem-nvidia.list" "${ROOTFS}/usr/share/keyrings/unitotem-nvidia.gpg" "${ROOTFS}/etc/apt/preferences.d/96-unitotem-nvidia"

tar -I pigz -C "${ROOTFS}" -cf "${WORK_DIR}/stage1.tar.gz" .

echo "=== Stage 1 complete ==="
