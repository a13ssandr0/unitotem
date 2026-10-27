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

# Build-time only: dpkg fsync()s every file it unpacks, which on the container's overlay filesystem dominates
# the install and keeps the CPUs idle. The result is thrown into a tarball and re-checked later, so a crash
# mid-build costs a rerun, not data. Removed again before the tarball is made (see "Clean up").
# Downloaded .debs persist across builds in work/apt-cache (mounted at /aptcache by build-unitotem.sh). A rebuild
# of stage 1 used to fetch ~2 GB again at the link speed - the CPUs sat ~95% idle meanwhile.
if [ -d /aptcache ]; then
    mkdir -p "/aptcache/${ARCH}/partial" "${ROOTFS}/var/cache/apt/archives"
    mount --bind "/aptcache/${ARCH}" "${ROOTFS}/var/cache/apt/archives"
fi
mkdir -p "${ROOTFS}/etc/apt/apt.conf.d"
echo 'Dpkg::Options { "--force-unsafe-io"; };' > "${ROOTFS}/etc/apt/apt.conf.d/99-build-unsafe-io"

# ---------- APT sources ----------

# Written from $RELEASE rather than hardcoded: the two architectures are on
# different Debian releases (see unitotem/common.sh for why), and a hardcoded
# suite here would have silently bootstrapped one base and then pointed apt at
# the other - a mismatch that only shows up much later, as unresolvable
# dependencies deep in a stage.
cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
EOF

if [ "$ARCH" = "arm64" ]; then
    # NOT the legacy raspberrypi.gpg.key URL: that file is a fixed artifact
    # Raspberry Pi stopped updating, still self-signed with SHA1, which
    # Debian's OpenPGP policy has refused since 2026-02-01 - trixie's apt
    # rejected the repo outright ("Sub-process /usr/bin/sqv returned an error
    # code (1) ... SHA1 is not considered secure"). The packaged
    # raspberrypi-archive-keyring is what pi-gen itself trusts (see
    # stage0/00-configure-apt/01-packages in the vendored copy in this repo)
    # and IS kept current: the copy published for trixie
    # (raspberrypi-archive-keyring_2025.1+rpt1_all.deb, confirmed by
    # downloading and inspecting it) carries the same signing key re-signed
    # with SHA512. Fetched per-$RELEASE from the suite's own Packages index
    # rather than a hardcoded filename, so this does not go stale again the
    # same way when Raspberry Pi ships the next re-sign.
    # No early `exit` in the awk program, on purpose: under set -e/pipefail
    # (both active in this script) awk exiting while curl/gzip are still
    # writing to the pipe delivers them a SIGPIPE, and pipefail turns that
    # into a failed pipeline even though $RPI_KEYRING_DEB had already been
    # captured correctly - the script aborted right after this line with no
    # error text at all, reproduced in isolation and confirmed as the actual
    # cause of a native-build failure that otherwise looked silent. The `f`
    # flag is reset on every "Package: " line instead, so a later stanza
    # cannot be mistaken for a match without needing an early exit to prevent it.
    RPI_KEYRING_DEB=$(curl -fsSL "https://archive.raspberrypi.org/debian/dists/${RELEASE}/main/binary-${ARCH}/Packages.gz" \
        | gzip -dc | awk '/^Package: /{f=($0=="Package: raspberrypi-archive-keyring")} f&&/^Filename:/{print $2}')
    [ -n "$RPI_KEYRING_DEB" ] || { echo "ERRORE: raspberrypi-archive-keyring non trovato per ${RELEASE}" >&2; exit 1; }
    curl -fsSL "https://archive.raspberrypi.org/debian/${RPI_KEYRING_DEB}" -o /tmp/rpi-keyring.deb
    dpkg-deb -x /tmp/rpi-keyring.deb /tmp/rpi-keyring
    install -Dm644 /tmp/rpi-keyring/usr/share/keyrings/raspberrypi-archive-keyring.gpg \
        "${ROOTFS}/etc/apt/trusted.gpg.d/raspberrypi.gpg"
    rm -rf /tmp/rpi-keyring.deb /tmp/rpi-keyring
    echo "deb http://archive.raspberrypi.org/debian/ ${RELEASE} main" \
        > "${ROOTFS}/etc/apt/sources.list.d/raspi.list"
fi
# No backports entry any more. amd64 used to assemble its GPU support out of
# bookworm-backports because bookworm's own kernel and Mesa were too old for
# recent hardware; on trixie every one of those packages comes from stable, at
# the same version or newer, so the scaffolding is gone rather than carried
# along out of habit.

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
    SNAP=$(python3 /unitotem/pkglock.py snapshot "$PKGLOCK_FILE") || { echo "ERRORE: il lock non registra uno snapshot Debian" >&2; exit 1; }
    echo ">>> package lock: ${PKGLOCK_FILE}, Debian snapshot ${SNAP}"
    cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb http://snapshot.debian.org/archive/debian/${SNAP}/ ${RELEASE} main contrib non-free non-free-firmware
deb http://snapshot.debian.org/archive/debian/${SNAP}/ ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://snapshot.debian.org/archive/debian-security/${SNAP}/ ${RELEASE}-security main contrib non-free non-free-firmware
EOF
    # The build's download cache as one more source: it still holds every version this lock was built from, including those an archive without
    # snapshots (Raspberry Pi) has since dropped. Pins decide the version; this only supplies it when the archives no longer do.
    if [ -d "${ROOTFS}/var/cache/apt/archives" ]; then
        python3 /unitotem/pkglock.py index "${ROOTFS}/var/cache/apt/archives" --arch "${ARCH}" || true
        echo "deb [trusted=yes] file:/var/cache/apt/archives ./" >> "${ROOTFS}/etc/apt/sources.list"
    fi
    echo 'Acquire::Check-Valid-Until "false";' > "${ROOTFS}/etc/apt/apt.conf.d/99-pkglock"
    mkdir -p "${ROOTFS}/etc/apt/preferences.d"
    python3 /unitotem/pkglock.py prefs "$PKGLOCK_FILE" > "${ROOTFS}/etc/apt/preferences.d/99-unitotem-lock"
fi

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get update
PKGLOCK_FROZEN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "$PKGLOCKED" = 1 ]; then
    # the stage-0 base (debootstrap, from an older day) must be at the locked versions too: with the pins this moves each package up OR down to them
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get -y --allow-downgrades dist-upgrade
fi

# ---------- Kernel + firmware + bootloader ----------

if [ "$ARCH" = "amd64" ]; then
    # Kernel 6.12 and 2025 firmware, straight from trixie - the reason this
    # architecture is on trixie at all (see unitotem/common.sh). On bookworm the
    # same versions had to be assembled out of backports because Intel ARC
    # cannot be driven by a 6.1 kernel.
    #
    # linux-headers-amd64 is here so the NVIDIA DKMS build later in this file
    # has matching headers; it is deliberately kept in the shipped image, see
    # the note beside that build.
    apt_install --no-install-recommends \
        linux-image-amd64 \
        linux-headers-amd64 \
        firmware-linux \
        firmware-linux-nonfree \
        firmware-misc-nonfree \
        firmware-intel-graphics
    # firmware-intel-graphics: i915 display (DMC), GuC and HuC firmware. Without it (found on a real Alder Lake PC, 2026-10-18) i915 logs
    # 'failed to load i915/adlp_dmc.bin' and the iHD VA-API driver cannot initialise (vaInitialize failed): no hardware video decode.
    apt_install --no-install-recommends \
        grub-efi-amd64 \
        grub-pc-bin \
        efibootmgr
    # Secure Boot chain, only STAGED in the image (stage 3 copies the signed binaries to EFI/unitotem-sb/ on the ESP; the deploy
    # activates them when the target has Secure Boot on and the operator chose "with shim"): shim-signed (Microsoft-signed shim,
    # dual-signed with the 2011 and 2023 UEFI CAs; embeds the Debian CA), grub-efi-amd64-signed (GRUB signed by the Debian CA)
    # and shim-helpers-amd64-signed (MokManager). The kernel is already Debian-signed. mokutil is for the physical-intervention
    # paths (MOK enrolment of the NVIDIA module's key).
    apt_install --no-install-recommends shim-signed grub-efi-amd64-signed mokutil

elif [ "$ARCH" = "arm64" ]; then
    # linux-image-rpi-v8, not the generic Debian linux-image-arm64: the
    # generic kernel's version string never matches raspi-firmware's own
    # z50-raspi-firmware postinst hook (flavour "${kver#*-rpi-}" only
    # recognises v8|v8-rt|2712|v6|v7|v7l), so that hook silently skipped
    # copying kernel8.img/initramfs8/dtbs, and it ships no overlays/ at all
    # (no KMS). The real rpi kernel fixes both: the hook now matches
    # natively (verified against the actual package - flavour resolves to
    # "v8", producing exactly kernel8.img/initramfs8, the filenames this
    # project already expects) and ships overlays/ including
    # vc4-kms-v3d(-pi5).dtbo, which unitotem/files/config.txt now enables. See
    # PLAN.md's arm64 follow-up section for the full history.
    # raspberrypi-bootloader is gone as of trixie - it does not exist in the
    # archive at all any more (apt: "Unable to locate package"), not renamed,
    # not a transitional dummy. Checked what actually replaced it rather than
    # guessing: raspi-firmware's own package description now reads "contains
    # all the proprietary files necessary to boot a Raspberry Pi board", and
    # its .deb ships bootcode.bin/fixup*.dat/start*.elf under
    # /usr/lib/raspi-firmware/ - the exact payload raspberrypi-bootloader used
    # to provide directly under /boot/. Its postinst copies them into
    # /boot/firmware/ on every install (`cp -r /usr/lib/raspi-firmware/*
    # /boot/firmware/`), and that copy is NOT skipped inside this chroot: the
    # postinst's mountpoint guard has `if ischroot; then true # skip mount
    # point check`, and chroot(1) is exactly how apt-get is invoked here. So
    # raspi-firmware alone is a complete replacement, confirmed by reading its
    # actual postinst rather than assuming the merge was safe.
    apt_install --no-install-recommends \
        linux-image-rpi-v8 \
        firmware-brcm80211 \
        firmware-linux \
        firmware-linux-nonfree \
        raspi-firmware
fi

# ---------- OTA payload (deploy/ota-engine.sh, unitotem/files/ota-hook) ----------
# Installed in stage1 (not stage2) deliberately: unitotem/stage1-recovery-initrd.sh
# builds the resident fallback kernel+initrd straight from this rootfs right
# after this stage finishes, and stage2 builds the real system's own
# initramfs from the same base later - one package list covers both, so the
# fallback and the real system's initramfs are never out of sync with each
# other. gdisk/parted are not on the automated OTA restore path (sfdisk
# covers that) but are kept anyway for manual disaster recovery - see the
# OTA redesign plan, decisions table.
apt_install --no-install-recommends \
    partclone gdisk parted fdisk pv netcat-traditional dropbear-bin wpasupplicant whiptail dosfstools xz-utils

mkdir -p "${ROOTFS}/usr/lib/unitotem"
install -m 755 /unitotem/files/ota-engine.sh "${ROOTFS}/usr/lib/unitotem/ota-engine.sh"
ln -sf /usr/lib/unitotem/ota-engine.sh "${ROOTFS}/usr/sbin/unitotem-ota-engine"
# framebuffer frame of the deploy/recovery screen's progress dialog (pre-rendered by tools/gen-frame.py)
for _f in /unitotem/files/unitotem-frame-line.* /unitotem/files/unitotem-frame-corners-*; do
    [ -s "$_f" ] || { echo "ERRORE: pezzo del riquadro mancante: $_f" >&2; exit 1; }
    install -m 644 "$_f" "${ROOTFS}/usr/lib/unitotem/"
done
# framebuffer logo of the deploy/recovery screen (pre-rendered by tools/gen-logo.py)
install -m 644 /unitotem/files/unitotem-logo-256x73.bgrx /unitotem/files/unitotem-logo-640x182.bgrx \
    /unitotem/files/unitotem-logo-256x73.rgb565 /unitotem/files/unitotem-logo-640x182.rgb565 \
    /unitotem/files/unitotem-logo-1280x365.bgrx /unitotem/files/unitotem-logo-1280x365.rgb565 "${ROOTFS}/usr/lib/unitotem/"   # the largest is for the placeholder on 4K; the real system'"'"'s KMS framebuffer can be 16 OR 32 bpp (16 on the Pi 4 test unit)

install -m 755 /unitotem/files/ota-hook "${ROOTFS}/etc/initramfs-tools/hooks/unitotem-ota"
# zstd -19 instead of the gzip that mkinitramfs falls back to when zstd is missing in the chroot: ~25% smaller, the Pi kernel has CONFIG_RD_ZSTD.
mkdir -p "${ROOTFS}/etc/initramfs-tools/conf.d"
printf 'COMPRESS=zstd\nCOMPRESSLEVEL=19\n' > "${ROOTFS}/etc/initramfs-tools/conf.d/unitotem-compress"
mkdir -p "${ROOTFS}/etc/unitotem"

# ---------- Base system ----------

apt_install \
    locales \
    sudo curl wget ca-certificates gnupg2 \
    openssh-server \
    iproute2 iputils-ping net-tools \
    htop nano less \
    util-linux udev e2fsprogs \
    lsb-release initramfs-tools apt-utils zstd \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    network-manager netplan.io \
    python3 python3-dbus python3-gi python3-pyudev \
    gir1.2-glib-2.0 \
    iptables

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
    # One image, three GPU vendors. That works because libglvnd dispatches GL
    # to whichever vendor's driver is actually present at runtime, so Mesa
    # (Intel/AMD) and the NVIDIA blob coexist without either being chosen at
    # build time. The compositor (labwc) talks to the kernel's KMS drivers
    # directly through libdrm/GBM: i915/xe for Intel, amdgpu for AMD, nvidia-drm
    # for NVIDIA - there is no X driver to choose any more.

    # Mesa 25.0 from trixie: this is what actually makes Intel ARC work (iris +
    # ANV for DG2) and it materially improves RDNA3. mesa-vulkan-drivers and
    # mesa-va-drivers are not in the shared block above, so they are named
    # here rather than being a redundant reinstall.
    apt_install \
        libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers mesa-utils

    # Intel, including ARC. intel-media-va-driver-non-free is the iHD driver
    # and covers Gen8 onwards, DG2/ARC included; i965 is kept for Gen4-8
    # hardware that iHD dropped. Both can be installed: libva selects by PCI
    # ID at runtime.
    apt_install \
        intel-media-va-driver-non-free \
        i965-va-driver-shaders \
        libva2 libva-drm2 vainfo

    # AMD. The kernel driver is in-tree; what is needed from userspace is the
    # firmware (from backports, for RDNA3 and newer) and libdrm.
    apt_install \
        firmware-amd-graphics libdrm-amdgpu1

    # NVIDIA, proprietary. Two consequences worth being explicit about:
    #
    #  - it blacklists nouveau unconditionally (Debian ships that rule with
    #    the package), and the 535 branch covers Maxwell onwards. On a
    #    pre-Maxwell card nvidia will not bind and nouveau is blacklisted, so
    #    that machine loses acceleration. That is the accepted cost of having
    #    working NVDEC and full performance on everything newer.
    #  - the module is built by DKMS here, against this image's own kernel.
    #    DKMS's usual weakness - drifting out of sync when the kernel is
    #    upgraded underneath it - cannot happen on this appliance: nothing is
    #    upgraded in place, an OTA replaces the whole ROOT partition with an
    #    image whose kernel and module were built together.
    #
    # nvidia-vaapi-driver bridges VAAPI onto NVDEC, so the same video path
    # used for Intel and AMD works here too instead of falling back to CPU.
    apt_install \
        nvidia-driver \
        nvidia-vaapi-driver

    # Fail the build rather than ship an image whose NVIDIA module silently
    # did not build: DKMS failures are reported by apt as warnings, and the
    # result would be an image that looks fine and has no NVIDIA support.
    KVER=$(chroot "${ROOTFS}" sh -c 'ls /lib/modules | head -1')
    chroot "${ROOTFS}" test -e "/lib/modules/${KVER}/updates/dkms/nvidia-current.ko.xz" \
        || { echo "ERRORE: il modulo NVIDIA non e' stato costruito per ${KVER}" >&2; exit 1; }
    echo "Modulo NVIDIA costruito per ${KVER}"

    # linux-headers and the DKMS toolchain are deliberately NOT purged here,
    # even though the module is already built and they are worth 94 MiB
    # (measured, and the module does survive their removal). They are what
    # lets DKMS rebuild if someone upgrades the kernel in place through
    # `unitotem-maintenance enter`, which this image explicitly supports. Without them
    # that upgrade would produce a running system with no NVIDIA module and no
    # error anyone would notice until the screen stayed black.

elif [ "$ARCH" = "arm64" ]; then
    # No VAAPI driver or tooling here, deliberately - vainfo and
    # gstreamer1.0-vaapi used to be installed on this branch, with a comment
    # admitting they were inert and were kept only because the amd64 branch
    # happened to share consumers, which is not a reason to ship them.
    #
    # libva2 itself does still land on the image: gstreamer1.0-plugins-bad
    # depends on it outright, and that package carries elements worth having.
    # So do not read its presence as a leftover - it is a shared library with
    # no driver behind it, which is exactly the situation the removal above
    # was meant to stop advertising. VideoCore has no VAAPI driver at all:
    # hardware
    # video decode on a Pi goes through V4L2 mem2mem devices instead
    # (/dev/video10 "bcm2835-codec-decode" for H.264 on every model, plus
    # /dev/video19 "rpi-hevc-dec" for HEVC on Pi 4 and later). Shipping the
    # VAAPI stack here only invited the reading that VAAPI was available.
    #
    # What is left is diagnostics, not drivers, and each earns its place:
    # v4l-utils gives v4l2-ctl to interrogate those decoders directly,
    # gstreamer1.0-tools gives gst-inspect to confirm the media stack can see
    # them, and raspi-utils gives vcgencmd - the only way to tell whether the
    # board is thermally or voltage throttled. On a kiosk "the video stutters"
    # and "the PSU is undersized" look identical from every other angle.
    apt_install \
        v4l-utils \
        gstreamer1.0-tools \
        raspi-utils
fi

# ---------- Wayland session (labwc) + PipeWire ----------
# The kiosk runs on Wayland only (decision 2026-10-20, see WAYLAND-IMAGE.md in the manager repo): the compositor is labwc, started by
# unitotem-compositor.service (shipped, disabled, by the unitotem-viewer deb; enabled in stage 2). There is no X server on the image;
# xwayland is installed only because labwc starts it lazily and logs an error without it (no X client is run).
# Measured on a Pi 4 and an Intel PC: 60 fps at 1080p, no tearing, a window per output, hot-plug, touch mapping, VNC, screen power.

# Screen control in the manager (DDC/CI, CEC): ddcutil >= 2.0 (trixie has 2.1), cec-ctl comes from v4l-utils (installed
# above on arm64 only, so named here for both), i2c-tools; the i2c-dev module is loaded at boot (stage2).
apt_install ddcutil v4l-utils i2c-tools

apt_install \
    labwc wlr-randr wlopm wayvnc xwayland qt6-wayland kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth

# gstreamer1.0-vaapi is amd64-only: it is a VAAPI plugin, and on a Pi there is
# no VAAPI driver for it to talk to. Leaving it in the shared list would also
# have dragged libva back onto arm64 through dependencies, undoing the removal
# above without anyone noticing.
if [ "$ARCH" = "amd64" ]; then
    apt_install \
        gstreamer1.0-vaapi
fi

# ---------- UniTotem packages ----------

# The manager (3.0.0~dev5 onwards) runs on the system Python with Debian's own packages: no virtualenv, so no pip/venv/-dev libraries
# (python3-pip used to drag build-essential into the arm64 image only to have it purged again).
# tigervnc-scraping-server: unitotem-node only RECOMMENDS it (VNC of the screen on demand, through a root-only UNIX socket, no TCP port) and the
# local debs are installed with --no-install-recommends, so it is asked for here (0.6 MB plus libraries the image mostly has already).
apt_install \
    python3-apt \
    openssl mediainfo rfkill alsa-utils cron libxcb-icccm4 libxcb-shape0 \
    tigervnc-scraping-server

# The packages come from the manager's own build (its tools/build-debs.sh), one directory per architecture:
#   work/extra-debs/<arch>/  unitotem (metapackage), unitotem-manager, unitotem-node, unitotem-viewer, plymouth-theme-unitotem (all arch-all,
#   identical on both architectures), python3-cefpython3 (the only binary one: amd64 or arm64), and the two libraries Debian does not ship
#   (python3-fastapi-login, python3-sdbus-networkmanager). apt resolves everything else from Debian trixie (and the Raspberry Pi repository).
LOCAL_DEB_DIR=/work/extra-debs/${ARCH}
# There is no image without the 3.x manager: the repository's 2.x package is NOT a fallback. An image that boots into nothing
# (or into a manager that cannot run on a read-only root) is not a degraded image, it is a wrong one, and building it only
# hides that the package was not supplied. Fail here, early, instead of finding out on the device.
if ! ls "$LOCAL_DEB_DIR"/*.deb >/dev/null 2>&1; then
    echo "ERRORE: nessun pacchetto unitotem 3.x fornito (work/extra-debs/${ARCH}/)." >&2
    echo "        Un'immagine senza il manager 3.x non va costruita." >&2
    exit 1
fi
# ...and the SET must be complete: a missing binary package would otherwise surface as an apt dependency error far from the cause.
for pkg in unitotem_ unitotem-manager_ unitotem-node_ unitotem-viewer_ plymouth-theme-unitotem_ "python3-cefpython3_" python3-fastapi-login_ python3-sdbus-networkmanager_; do
    ls "$LOCAL_DEB_DIR"/${pkg}*.deb >/dev/null 2>&1 \
        || { echo "ERRORE: manca ${pkg}*.deb in work/extra-debs/${ARCH}/ (serve il set completo del manager: vedi il commento sopra)" >&2; exit 1; }
done
ls "$LOCAL_DEB_DIR"/python3-cefpython3_*_${ARCH}.deb >/dev/null 2>&1 \
    || { echo "ERRORE: python3-cefpython3 per ${ARCH} non e' in work/extra-debs/${ARCH}/ (un .deb di un'altra architettura non si installa)" >&2; exit 1; }

# Local override: any .deb in work/extra-debs/<arch>/ is installed over what the apt repository provided. This is how
# an image gets a manager build that is not published yet (e.g. one with the /health endpoint the A/B update
# gate waits for). Empty/absent directory = nothing happens.
if ls "$LOCAL_DEB_DIR"/*.deb >/dev/null 2>&1; then
    mkdir -p "${ROOTFS}/tmp/extra-debs"
    printf 'local .deb installed: %s\n' "$LOCAL_DEB_DIR"/*.deb
    cp "$LOCAL_DEB_DIR"/*.deb "${ROOTFS}/tmp/extra-debs/"
    chroot "${ROOTFS}" sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades /tmp/extra-debs/*.deb"
    # The 2.x manager package pulled haproxy in as a dependency (it forwarded 80/443 to the app); the 3.x one binds
    # those ports itself, and a still-enabled haproxy answers them with a 503 instead. Only when a local 3.x .deb
    # replaced the repository package.
    if chroot "${ROOTFS}" dpkg -s haproxy >/dev/null 2>&1; then
        chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y haproxy
    fi
    rm -rf "${ROOTFS}/tmp/extra-debs"
    # CEF starts its helper process by exec'ing cefpython3/subprocess. 3.0.0~dev5 of python3-cefpython3 shipped it as 0644 (the wheel is a zip
    # and loses the exec bit): CEF then dies with "failed to execvp ... Cannot communicate with zygote" (SIGTRAP) and the manager restart-loops.
    # dpkg-statoverride is the Debian way to fix a packaged file's mode without editing the package; a fixed package makes this a no-op.
    CEFSUB=/usr/lib/python3/dist-packages/cefpython3/subprocess
    if [ ! -x "${ROOTFS}${CEFSUB}" ]; then
        echo ">>> WARNING: ${CEFSUB} is not executable in the package: applying a dpkg-statoverride 0755 (fix python3-cefpython3)"
        chroot "${ROOTFS}" dpkg-statoverride --update --add root root 0755 "${CEFSUB}"
    fi
    [ -x "${ROOTFS}${CEFSUB}" ] || { echo "ERRORE: ${CEFSUB} non e' eseguibile" >&2; exit 1; }
    for pkg in unitotem unitotem-manager unitotem-node unitotem-viewer python3-cefpython3 plymouth-theme-unitotem; do
        v=$(chroot "${ROOTFS}" dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
        case "$v" in 3.*) ;; *) echo "ERRORE: $pkg non e' installato alla versione 3.x (trovato: '${v}')" >&2; exit 1 ;; esac
    done
fi

# ---------- Package lock: verify or freeze ----------
if [ "$PKGLOCKED" = 1 ]; then
    python3 /unitotem/pkglock.py verify "$PKGLOCK_FILE" "${ROOTFS}" || { echo "ERRORE: l'immagine non coincide col lock dei pacchetti (vedi sopra): aggiornare il lock con tools/pkglock.py upgrade ${ARCH} se i pacchetti sono cambiati apposta" >&2; exit 1; }
    # the shipped image does not carry the snapshot sources or the pins (a device never runs apt): back to the ordinary ones
    rm -f "${ROOTFS}/etc/apt/preferences.d/99-unitotem-lock" "${ROOTFS}/etc/apt/apt.conf.d/99-pkglock"
    cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
EOF
elif [ "${PKGLOCK:-on}" != off ]; then
    mkdir -p "${WORK_DIR}"
    python3 /unitotem/pkglock.py freeze "${ROOTFS}" --arch "${ARCH}" --release "${RELEASE}" --snapshot "${PKGLOCK_FROZEN_AT}" --out "${WORK_DIR}/${ARCH}.lock.new"
    echo ">>> NUOVO LOCK dei pacchetti in work/${ARCH}/${ARCH}.lock.new: copiarlo in unitotem/locks/${ARCH}.lock e committarlo"
fi

# ---------- Clean up ----------
rm -f "${ROOTFS}/etc/apt/apt.conf.d/99-build-unsafe-io"
# Unmount the cache BEFORE apt-get clean: clean empties the archive directory, which would wipe the cache.
mountpoint -q "${ROOTFS}/var/cache/apt/archives" && umount "${ROOTFS}/var/cache/apt/archives"

# ---------- Remove what the shipped system does not need ----------
# Approved by the user (2026-10-11): Chromium and the compilers. Updates are whole images now, nothing is built or
# upgraded in place at runtime, so the DKMS rebuild rationale for keeping the toolchain no longer applies.
#
# Chromium (arm64 only - amd64 never had it): pulled in as a RECOMMENDED dependency of the 2.x manager package, whose
# viewer is Qt + CEF; ~500 MB. The compilers come in through python3-pip -> build-essential (arm64) and dkms ->
# build-essential (amd64).
#
# What is removed is printed first (the dry run is in the build log) and the module that matters is asserted after.
purge_list() { # names from $@ that are actually installed
    local p; for p in "$@"; do chroot "${ROOTFS}" dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && echo "$p"; done
    # Always succeed: the loop's own status is that of the LAST name, so with set -e an image where the last package is absent (arm64 since
    # 3.0.0~dev5 has neither Chromium nor compilers) silently killed the build right after the package install, with no message.
    return 0
}
if [ "$ARCH" = "arm64" ]; then
    REMOVE=$(purge_list chromium chromium-browser chromium-common chromium-l10n rpi-chromium-mods)
    echo ">>> removing (arm64, apt): $(echo $REMOVE)"
    if [ -n "$REMOVE" ]; then
        # shellcheck disable=SC2086
        { chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get -s purge $REMOVE 2>&1 | grep -E '^(Remv|E:)' | sed 's/^/    dry-run: /'; } || true   # informational only: must never stop the build
        # shellcheck disable=SC2086
        chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $REMOVE
    fi
    # The compilers go with dpkg --force-depends, NOT with apt: a package that depends on cpp would be taken along by `apt-get purge cpp`
    # (that is how the earlier X images lost xset). The price is an unmet-dependency note in `dpkg --audit`, harmless on an image that never runs apt.
    REMOVE_CC=$(purge_list build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 \
                           gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cpp-aarch64-linux-gnu \
                           gcc-14-aarch64-linux-gnu g++-14-aarch64-linux-gnu cpp-14-aarch64-linux-gnu)
    echo ">>> removing (arm64, dpkg --force-depends): $(echo $REMOVE_CC)"
    # shellcheck disable=SC2086
    [ -z "$REMOVE_CC" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $REMOVE_CC
    # the manager must still be there: apt may have taken it along if it had a hard dependency on any of the above
    chroot "${ROOTFS}" dpkg-query -W -f='${Status}' unitotem-manager | grep -q 'ok installed' \
        || { echo "ERRORE: la rimozione di Chromium/compilatori ha portato via unitotem-manager" >&2; exit 1; }
else
    # dkms (and nvidia-kernel-dkms, which needs it) depend on the compilers, so apt would remove them too and their
    # prerm would delete the built NVIDIA module. dpkg --force-depends removes only the compilers and leaves the
    # module and the dkms packages alone; the price is an unmet-dependency note on dkms in `dpkg --audit`, which is
    # harmless on an image that never builds anything (and is why this is not done with apt).
    REMOVE=$(purge_list build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 \
                        gcc-x86-64-linux-gnu g++-x86-64-linux-gnu cpp-x86-64-linux-gnu \
                        gcc-14-x86-64-linux-gnu g++-14-x86-64-linux-gnu cpp-14-x86-64-linux-gnu)
    echo ">>> removing (amd64, dpkg --force-depends): $(echo $REMOVE)"
    # shellcheck disable=SC2086
    [ -z "$REMOVE" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $REMOVE
    KVER=$(chroot "${ROOTFS}" sh -c 'ls /lib/modules | head -1')
    chroot "${ROOTFS}" test -e "/lib/modules/${KVER}/updates/dkms/nvidia-current.ko.xz" \
        || { echo "ERRORE: il modulo NVIDIA e' sparito rimuovendo i compilatori" >&2; exit 1; }
fi
# The NVIDIA module (amd64) is signed at build time with a key DKMS generated inside this build: /var/lib/dkms/mok.key (private) and
# mok.pub. The private half is the SAME in every device flashed from the image, and once a device has enrolled mok.pub (mokutil --import,
# needed under Secure Boot) anyone holding the image could sign modules that device accepts. Nothing at runtime needs it: updates are whole
# images, DKMS never rebuilds anything on a device. Keep only the public certificate, which is what an enrolment needs.
if [ "$ARCH" = "amd64" ] && [ -e "${ROOTFS}/var/lib/dkms/mok.key" ]; then
    rm -f "${ROOTFS}/var/lib/dkms/mok.key"
    echo ">>> removed the DKMS module-signing private key from the image (mok.pub kept)"
fi
# No X server on the image: the NVIDIA driver (amd64) and a few packages pull xserver-xorg-core in as a dependency, but nothing starts it.
# dpkg --force-depends like the compilers (an unmet-dependency note in `dpkg --audit` on an image that never runs apt; the NVIDIA kernel module
# and its libraries do not need the X server). xwayland (installed above, no Xorg needed) stays.
XPURGE=$(purge_list xserver-xorg-core xserver-xorg-legacy xserver-xorg xserver-xorg-input-all xserver-xorg-video-all xinit x11-xserver-utils)
echo ">>> removing the X server (dpkg --force-depends): $(echo $XPURGE)"
# shellcheck disable=SC2086
[ -z "$XPURGE" ] || chroot "${ROOTFS}" dpkg --force-depends --purge $XPURGE
# What the Wayland session needs must have survived the removals above, on every architecture.
for t in labwc wlr-randr wlopm wayvnc; do
    chroot "${ROOTFS}" sh -c "command -v $t >/dev/null" || { echo "ERRORE: $t e' sparito con la rimozione dei compilatori/Chromium" >&2; exit 1; }
done
echo ">>> installed size of / after removal: $(du -sxm "${ROOTFS}" | cut -f1) MiB"

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

remove_policy_rc
umount_chroot

echo "Saving stage 1 tarball..."
tar -I pigz -C "${ROOTFS}" -cf "${WORK_DIR}/stage1.tar.gz" .

echo "=== Stage 1 complete ==="
