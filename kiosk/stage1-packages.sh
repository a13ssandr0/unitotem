#!/bin/bash
set -euo pipefail
source /kiosk/common.sh

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
# Downloaded .debs persist across builds in work/apt-cache (mounted at /aptcache by build-kiosk.sh). A rebuild
# of stage 1 used to fetch ~2 GB again at the link speed - the CPUs sat ~95% idle meanwhile.
if [ -d /aptcache ]; then
    mkdir -p "/aptcache/${ARCH}/partial" "${ROOTFS}/var/cache/apt/archives"
    mount --bind "/aptcache/${ARCH}" "${ROOTFS}/var/cache/apt/archives"
fi
mkdir -p "${ROOTFS}/etc/apt/apt.conf.d"
echo 'Dpkg::Options { "--force-unsafe-io"; };' > "${ROOTFS}/etc/apt/apt.conf.d/99-build-unsafe-io"

# ---------- APT sources ----------

# Written from $RELEASE rather than hardcoded: the two architectures are on
# different Debian releases (see kiosk/common.sh for why), and a hardcoded
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

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get update

# ---------- Kernel + firmware + bootloader ----------

if [ "$ARCH" = "amd64" ]; then
    # Kernel 6.12 and 2025 firmware, straight from trixie - the reason this
    # architecture is on trixie at all (see kiosk/common.sh). On bookworm the
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
        firmware-misc-nonfree
    apt_install --no-install-recommends \
        grub-efi-amd64 \
        grub-pc-bin \
        efibootmgr

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
    # vc4-kms-v3d(-pi5).dtbo, which kiosk/files/config.txt now enables. See
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

# ---------- OTA payload (deploy/ota-engine.sh, kiosk/files/ota-hook) ----------
# Installed in stage1 (not stage2) deliberately: kiosk/stage1-recovery-initrd.sh
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
install -m 755 /kiosk/files/ota-engine.sh "${ROOTFS}/usr/lib/unitotem/ota-engine.sh"
ln -sf /usr/lib/unitotem/ota-engine.sh "${ROOTFS}/usr/sbin/unitotem-ota-engine"
# framebuffer logo of the deploy/recovery screen (pre-rendered by tools/gen-logo.py)
install -m 644 /kiosk/files/unitotem-logo-256x73.bgrx /kiosk/files/unitotem-logo-640x182.bgrx \
    /kiosk/files/unitotem-logo-256x73.rgb565 /kiosk/files/unitotem-logo-640x182.rgb565 \
    /kiosk/files/unitotem-logo-1280x364.bgrx /kiosk/files/unitotem-logo-1280x364.rgb565 "${ROOTFS}/usr/lib/unitotem/"   # the largest is for the placeholder on 4K; the real system'"'"'s KMS framebuffer can be 16 OR 32 bpp (16 on the Pi 4 test unit)

install -m 755 /kiosk/files/ota-hook "${ROOTFS}/etc/initramfs-tools/hooks/unitotem-ota"
mkdir -p "${ROOTFS}/etc/unitotem"

# ---------- Base system ----------

apt_install \
    locales \
    sudo curl wget ca-certificates gnupg2 \
    openssh-server \
    iproute2 iputils-ping net-tools \
    htop nano less \
    util-linux udev e2fsprogs \
    lsb-release initramfs-tools apt-utils \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    network-manager netplan.io \
    python3 python3-dbus python3-gi python3-pyudev \
    gir1.2-glib-2.0 \
    iptables

# ---------- Plymouth ----------

apt_install \
    plymouth plymouth-themes plymouth-label libplymouth5

# ---------- GPU libraries (common) ----------

apt_install \
    libglvnd0 libglx0 libgles2 libvulkan1 \
    mesa-utils libgl1-mesa-dri

# ---------- GPU drivers (arch-specific) ----------

if [ "$ARCH" = "amd64" ]; then
    # One image, three GPU vendors. That works because libglvnd dispatches GL
    # to whichever vendor's driver is actually present at runtime, so Mesa
    # (Intel/AMD) and the NVIDIA blob coexist without either being chosen at
    # build time. The X server picks its driver the same way: modesetting for
    # Intel, amdgpu for AMD, nvidia for NVIDIA (xserver-xorg-video-all already
    # supplies amdgpu/ati/nouveau; modern Intel is served by the server's
    # built-in modesetting, which is why there is no xserver-xorg-video-intel
    # here - that driver is legacy and hurts on anything recent).

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
    # `kiosk-update enter`, which this image explicitly supports. Without them
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

# ---------- X11 + PipeWire ----------
# No window manager: unitotem-manager's own Qt6+CEF viewer already sets its
# window to exact fullscreen geometry with no decorations on its own, and CEF
# only supports X11 embedding anyway (see manager/webview/window.py), so a
# bare Xorg session (no WM) is all this image needs. The session itself is
# kiosk/files/start-xorg.service + kiosk/files/xinitrc.
#
# Historical note: a compositor-based session was evaluated first and dropped
# - CEF's X11-only embedding would have forced an X server underneath it
# anyway, so the compositor bought nothing and cost a moving part.

# Screen control in the manager (DDC/CI, CEC): ddcutil >= 2.0 (trixie has 2.1), cec-ctl comes from v4l-utils (installed
# above on arm64 only, so named here for both), i2c-tools; the i2c-dev module is loaded at boot (stage2).
apt_install ddcutil v4l-utils i2c-tools

apt_install \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
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

apt_install \
    python3-pip python3-apt python3-venv \
    libopenjp2-7-dev openssl mediainfo rfkill alsa-utils cron libxcb-icccm4 libxcb-shape0

# arm64 has no hand-built manager package, but the manager is Python: when only the amd64 .deb is supplied, an arm64 one is made
# from it (same files, venv rebuilt natively; see kiosk/files/build-manager-arm64.sh). It lives in work/extra-debs-gen/arm64,
# a directory this script owns and wipes, so a stale generated package can never sit next to a newer one.
LOCAL_DEB_DIR=/work/extra-debs/${ARCH}
if [ "$ARCH" = "arm64" ] && ! ls /work/extra-debs/arm64/*.deb >/dev/null 2>&1; then
    SRC_AMD64=$(ls -t /work/extra-debs/amd64/unitotem-manager_*_amd64.deb 2>/dev/null | head -1 || true)
    if [ -n "$SRC_AMD64" ]; then
        echo ">>> generating the arm64 manager package from $SRC_AMD64"
        rm -rf -- /work/extra-debs-gen/arm64
        bash /kiosk/files/build-manager-arm64.sh "${ROOTFS}" "$SRC_AMD64" /work/extra-debs-gen/arm64
        LOCAL_DEB_DIR=/work/extra-debs-gen/arm64
    fi
fi

# There is no image without the 3.x manager: the repository's 2.x package is NOT a fallback. An image that boots into nothing
# (or into a manager that cannot run on a read-only root) is not a degraded image, it is a wrong one, and building it only
# hides that the package was not supplied. Fail here, early, instead of finding out on the device.
if ! ls "$LOCAL_DEB_DIR"/*.deb >/dev/null 2>&1; then
    echo "ERRORE: nessun pacchetto unitotem-manager 3.x fornito (work/extra-debs/${ARCH}/ oppure, per arm64, work/extra-debs/amd64/)." >&2
    echo "        Un'immagine senza il manager 3.x non va costruita." >&2
    exit 1
fi

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
}
if [ "$ARCH" = "arm64" ]; then
    REMOVE=$(purge_list chromium chromium-browser chromium-common chromium-l10n rpi-chromium-mods \
                        build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 \
                        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cpp-aarch64-linux-gnu \
                        gcc-14-aarch64-linux-gnu g++-14-aarch64-linux-gnu cpp-14-aarch64-linux-gnu)
    echo ">>> removing (arm64): $(echo $REMOVE)"
    if [ -n "$REMOVE" ]; then
        # shellcheck disable=SC2086
        { chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get -s purge $REMOVE 2>&1 | grep -E '^(Remv|E:)' | sed 's/^/    dry-run: /'; } || true   # informational only: must never stop the build
        # shellcheck disable=SC2086
        chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $REMOVE
    fi
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
echo ">>> installed size of / after removal: $(du -sxm "${ROOTFS}" | cut -f1) MiB"

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

remove_policy_rc
umount_chroot

echo "Saving stage 1 tarball..."
tar -I pigz -C "${ROOTFS}" -cf "${WORK_DIR}/stage1.tar.gz" .

echo "=== Stage 1 complete ==="
