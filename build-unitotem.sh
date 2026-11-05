#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER="${DOCKER:-docker}"
ARCHES="${ARCHES:-amd64 arm64}"
FORCE_STAGE="${FORCE_STAGE:-}"   # set to 0,1,2 to force rebuild from that stage onward

# Native arm64 build on a Raspberry Pi given by PI_HOST (user@host), when set and reachable. mkinitramfs (ldd in
# copy_exec) and package postinst/trigger scripts (ldconfig, depmod, systemctl)
# execute arm64 code, which qemu-aarch64 emulates slowly. The same stage
# scripts run natively on the Pi without that cost. See docs/system/build.md.
PI_HOST="${PI_HOST:-}"
PI_BUILD_BASE="${PI_BUILD_BASE:-/mnt/data/unitotem-native-build}"

_pi_sshpass() {
    SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS sshpass -p "${PI_PASSWORD:-unitotem}" "$@"
}
_pi_ssh() {
    _pi_sshpass ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        "${PI_HOST}" "$@"
}
_pi_rsync() {
    _pi_sshpass rsync -az -e "sshpass -p ${PI_PASSWORD:-unitotem} ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null" "$@"
}

probe_pi() {
    [ -n "${PI_HOST}" ] || return 1
    command -v sshpass >/dev/null 2>&1 || return 1
    _pi_ssh -o ConnectTimeout=5 true 2>/dev/null
}

# Builds the arm64 images by running the unitotem/stageN-*.sh scripts directly
# on the Pi over SSH. Root is read-only on the Pi; the build tree lives on DATA
# (ample space) and /unitotem, /work, /deploy are symlinks to it, the paths the
# stage scripts hardcode. Always runs the full stage0-3 pass (no should_run
# caching on this path).
# A stage 1 that ran without a lock leaves work/<arch>/<arch>.lock.new: it becomes the lock (commit it).
adopt_lock() {
    local f="${DIR}/work/${ARCH}/${ARCH}.lock.new"
    if [ -f "$f" ] && [ ! -f "${DIR}/unitotem/locks/${ARCH}.lock" ]; then
        mkdir -p "${DIR}/unitotem/locks"
        mv "$f" "${DIR}/unitotem/locks/${ARCH}.lock"
        echo "[${ARCH}] new package lock: unitotem/locks/${ARCH}.lock (commit it)"
    fi
}

build_natively_on_pi() {
    echo "[arm64] Pi reachable (${PI_HOST}): native build, no qemu emulation"

    # /var/lib/dpkg is a bind mount with its own flags, so it stays read-only
    # after remounting / and must be remounted separately; otherwise apt fails
    # with "Not using locking for read only lock file".
    # Root stays writable for the whole build (apt-get install writes to
    # /var/lib/dpkg, /usr, /etc) and returns to ro in a trap, however the
    # session ends.
    _pi_ssh "trap 'mount -o remount,ro / 2>/dev/null || true' EXIT; \
        mkdir -p '${PI_BUILD_BASE}/unitotem' '${PI_BUILD_BASE}/work' '${PI_BUILD_BASE}/deploy' && \
        mount -o remount,rw / && \
        { mountpoint -q /var/lib/dpkg && mount -o remount,rw /var/lib/dpkg || true; } && \
        ln -sfn '${PI_BUILD_BASE}/unitotem' /unitotem && \
        ln -sfn '${PI_BUILD_BASE}/work' /work && \
        ln -sfn '${PI_BUILD_BASE}/deploy' /deploy" \
        || { echo "[arm64] cannot prepare the build tree on the Pi" >&2; return 1; }

    # An interrupted build leaves stage2's chroot bind mounts (proc, sys, dev)
    # inside the rootfs, and stage0's `rm -rf "${ROOTFS}"` then fails with
    # "Directory not empty". Unmount them, deepest first, lazily, best effort.
    _pi_ssh "awk -v b='${PI_BUILD_BASE}' 'index(\$2, b)==1 {print \$2}' /proc/mounts \
        | sort -r | xargs -r -n1 umount -lf" >/dev/null 2>&1 || true

    echo "[arm64] Syncing sources to the Pi..."
    _pi_rsync -r --delete "${DIR}/unitotem/" "${PI_HOST}:${PI_BUILD_BASE}/unitotem/"
    _pi_rsync "${DIR}/deploy/ota-engine.sh" "${PI_HOST}:${PI_BUILD_BASE}/unitotem/files/ota-engine.sh"
    _pi_rsync "${DIR}/deploy/parts-lib.sh" "${PI_HOST}:${PI_BUILD_BASE}/unitotem/deploy-parts-lib.sh" 2>/dev/null || true
    _pi_rsync "${DIR}/tools/pkglock.py" "${PI_HOST}:${PI_BUILD_BASE}/unitotem/pkglock.py"
    # Locally supplied packages (work/extra-debs/<arch>/*.deb) - the manager package among them - are inputs of stage 1 and
    # must be on the Pi too; the arm64 manager package is generated there from the amd64 one.
    if [ -d "${DIR}/work/extra-debs" ]; then
        _pi_ssh "mkdir -p '${PI_BUILD_BASE}/work/extra-debs'" && \
            _pi_rsync -r --delete "${DIR}/work/extra-debs/" "${PI_HOST}:${PI_BUILD_BASE}/work/extra-debs/"
    fi

    # ROOTFS and IMG_MNT are moved off their container defaults: /tmp on the Pi
    # is a small nodev tmpfs, which debootstrap refuses, and /mnt is where DATA
    # is mounted, so mounting the image there would hide the build tree.
    local envvars="ARCH=arm64 ROOTFS='${PI_BUILD_BASE}/rootfs' IMG_MNT='${PI_BUILD_BASE}/imgmnt'"
    local var
    for var in RELEASE MIRROR UNITOTEM_HOSTNAME ROOT_PASSWORD UNITOTEM_LOCALE UNITOTEM_TIMEZONE IMAGE_SIZE AB_LAYOUT ROOT_SLOT_SIZE RELEASE_VERSION; do
        [ -n "${!var:-}" ] && envvars="${envvars} ${var}='${!var}'"
    done

    # One ssh session for the whole build: root must stay writable from
    # apt-get install to the last stage; a remount,ro in between would fail
    # later stages with "Read-only file system".
    _pi_ssh "set -e; \
        trap 'mount -o remount,ro / 2>/dev/null || true' EXIT; \
        mount -o remount,rw /; \
        { mountpoint -q /var/lib/dpkg && mount -o remount,rw /var/lib/dpkg; } || true; \
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            debootstrap qemu-user-static dosfstools e2fsprogs gdisk parted kpartx util-linux \
            xz-utils pigz zstd curl ca-certificates wget gnupg2 rsync git partclone python3 \
            device-tree-compiler initramfs-tools-core cpio >/dev/null; \
        for s in stage0-bootstrap.sh stage1-packages.sh stage1-recovery-initrd.sh \
                 stage2-configure.sh stage3-image.sh; do \
            echo \"[arm64] (native) Running \$s...\"; \
            env ${envvars} bash /unitotem/\$s; \
        done" \
        || { echo "[arm64] native build failed on the Pi" >&2; return 1; }

    echo "[arm64] Fetching results from the Pi..."
    mkdir -p "${DIR}/work/arm64" "${DIR}/deploy/arm64"
    _pi_rsync "${PI_HOST}:${PI_BUILD_BASE}/work/arm64/" "${DIR}/work/arm64/"
    _pi_rsync "${PI_HOST}:${PI_BUILD_BASE}/deploy/arm64/" "${DIR}/deploy/arm64/"
    adopt_lock
    echo "[arm64] Native build complete."
}

if ! ${DOCKER} info >/dev/null 2>&1; then
    echo "Docker not available or not running" >&2
    exit 1
fi

# Register QEMU binfmt for arm64 cross-compilation
echo ">>> Setting up QEMU binfmt handlers..."
${DOCKER} run --rm --privileged tonistiigi/binfmt --install arm64 2>/dev/null \
    || ${DOCKER} run --rm --privileged multiarch/qemu-user-static --reset -p yes \
    || echo "Warning: could not register binfmt handlers (may already be registered)"

# Build the builder image
echo ">>> Building unitotem builder image..."
${DOCKER} build -f "${DIR}/Dockerfile.unitotem" -t unitotem-builder "${DIR}"

mkdir -p "${DIR}/work" "${DIR}/deploy"

# The architectures share nothing (own work/<arch>, deploy/<arch>, apt cache subdirectory), so with more than one
# they are built side by side, each in a child of this script with its output prefixed. A sequential loop left the
# machine ~90% idle: most of a build is waiting on the network or on dpkg, and waiting overlaps well.
# BUILD_CHILD marks the children; ARCHES=<one> runs them through the ordinary loop below.
if [ -z "${BUILD_CHILD:-}" ] && [ "$(echo ${ARCHES} | wc -w)" -gt 1 ]; then
    declare -A CHILD_PID
    for a in ${ARCHES}; do
        BUILD_CHILD=1 ARCHES="$a" bash "${BASH_SOURCE[0]}" > >(sed -u "s/^/[$a] /") 2>&1 &
        CHILD_PID[$a]=$!
    done
    rc=0
    for a in "${!CHILD_PID[@]}"; do
        wait "${CHILD_PID[$a]}" || { echo "[$a] build FAILED" >&2; rc=1; }
    done
    [ "$rc" = 0 ] && echo "All builds complete." || echo "At least one build failed." >&2
    exit "$rc"
fi

for ARCH in ${ARCHES}; do
    echo ""
    echo "=================================================="
    echo "  Building for ARCH=${ARCH}"
    echo "=================================================="

    # Package lock gate: report what is newer than the locked versions. Security updates renew the lock: the old one is retired and this
    # build reinstalls every package from stage 1 at the current versions, freezing a new lock. Other updates are only reported.
    # PKGLOCK=off skips the gate; PKGLOCK_KEEP=1 keeps the lock whatever the check finds.
    if [ "${PKGLOCK:-on}" != off ] && [ -f "${DIR}/unitotem/locks/${ARCH}.lock" ]; then
        set +e
        python3 "${DIR}/tools/pkglock.py" check "${DIR}/unitotem/locks/${ARCH}.lock"
        gate=$?
        set -e
        if [ "$gate" = 20 ] && [ "${PKGLOCK_KEEP:-0}" != 1 ]; then
            echo "[${ARCH}] security updates found: renewing the package lock, this build starts from stage 1" >&2
            python3 "${DIR}/tools/pkglock.py" upgrade "${ARCH}"
            FORCE_STAGE=1
        elif [ "$gate" = 2 ]; then
            echo "[${ARCH}] warning: update check failed (network?): continuing with the locked versions" >&2
        fi
    elif [ "${PKGLOCK:-on}" != off ]; then
        echo "[${ARCH}] no package lock (unitotem/locks/${ARCH}.lock): this build freezes a new one"
    fi

    if [ "${ARCH}" = "arm64" ] && [ "${PI_NATIVE_BUILD:-1}" = 1 ] && probe_pi; then
        if build_natively_on_pi; then
            echo "[${ARCH}] Done (native build)! Image in: deploy/${ARCH}/"
            continue
        fi
        echo "[arm64] Native build failed, falling back to Docker+qemu-aarch64..." >&2
    fi

    mkdir -p "${DIR}/work/${ARCH}" "${DIR}/deploy/${ARCH}" "${DIR}/work/apt-cache" "${DIR}/unitotem/locks"

    RUN_OPTS=(
        --rm
        --privileged
        -v /dev:/dev
        -v "${DIR}/work:/work"
        -v "${DIR}/deploy:/deploy"
        -v "${DIR}/work/apt-cache:/aptcache"
        -v "${DIR}/unitotem/locks:/unitotem/locks:ro"
        -e "ARCH=${ARCH}"
    )

    # Pass through optional config overrides
    for VAR in RELEASE MIRROR UNITOTEM_HOSTNAME ROOT_PASSWORD \
               UNITOTEM_LOCALE UNITOTEM_TIMEZONE IMAGE_SIZE AB_LAYOUT ROOT_SLOT_SIZE RELEASE_VERSION; do
        [ -n "${!VAR:-}" ] && RUN_OPTS+=(-e "${VAR}=${!VAR}")
    done

    # Should this stage be (re-)run? A stage reruns when its tarball is missing
    # or older than any of its inputs (stage scripts, files, ota-engine.sh,
    # the previous stage's tarball).
    should_run() {
        local stage_num=$1
        local tarball="${DIR}/work/${ARCH}/stage${stage_num}.tar.gz"
        if [ -n "${FORCE_STAGE}" ] && [ "${stage_num}" -ge "${FORCE_STAGE}" ]; then
            echo "[${ARCH}] Stage ${stage_num}: forced rebuild"
            rm -f "${tarball}"
            return 0
        fi
        if [ ! -f "${tarball}" ]; then
            return 0
        fi
        # unitotem/files/* and deploy/ota-engine.sh only matter to stages 1 and 2;
        # stage0 and stage3 do not consume them.
        # stage2 bakes the layout in (root= on the cmdline, fstab, GRUB entries) and a
        # timestamp comparison cannot see an environment variable change.
        if [ "$stage_num" = 2 ] && [ "$(cat "${DIR}/work/${ARCH}/stage2.layout" 2>/dev/null || echo 0)" != "${AB_LAYOUT:-1}" ]; then
            echo "[${ARCH}] Stage 2: rebuild (AB_LAYOUT differs from the cached tarball)"
            rm -f "${tarball}"
            return 0
        fi
        local extra_deps=()
        case "$stage_num" in
            1|2) extra_deps=("${DIR}/unitotem/files"/* "${DIR}/deploy/ota-engine.sh") ;;
        esac
        # The previous stage's tarball is this stage's input: without it a rebuilt
        # stage1 would leave a stale stage2 tarball in use.
        local prev_tarball=""
        if [ "$stage_num" -gt 0 ]; then
            prev_tarball="${DIR}/work/${ARCH}/stage$((stage_num - 1)).tar.gz"
        fi
        local dep newest_dep=""
        for dep in "${DIR}/unitotem/stage${stage_num}"*.sh "${DIR}/unitotem/common.sh" \
                   "${extra_deps[@]}" "${DIR}/Dockerfile.unitotem" \
                   ${prev_tarball:+"$prev_tarball"}; do
            [ -e "$dep" ] || continue
            if [ -z "$newest_dep" ] || [ "$dep" -nt "$newest_dep" ]; then newest_dep="$dep"; fi
        done
        if [ -n "$newest_dep" ] && [ "$newest_dep" -nt "$tarball" ]; then
            echo "[${ARCH}] Stage ${stage_num}: rebuild (${newest_dep} is newer than the cached tarball)"
            rm -f "${tarball}"
            return 0
        fi
        echo "[${ARCH}] Stage ${stage_num}: skipping (tarball exists and is up to date)"
        return 1
    }

    # Stage 0: Bootstrap
    if should_run 0; then
        echo "[${ARCH}] Stage 0: Bootstrap..."
        ${DOCKER} run "${RUN_OPTS[@]}" unitotem-builder /unitotem/stage0-bootstrap.sh
    fi

    # Stage 1: Packages
    STAGE1_RAN=0
    if should_run 1; then
        echo "[${ARCH}] Stage 1: Installing packages..."
        ${DOCKER} run "${RUN_OPTS[@]}" unitotem-builder /unitotem/stage1-packages.sh
        STAGE1_RAN=1
    fi

    # Stage 1b: recovery (OTA fallback) kernel+initrd, built from stage1 before
    # stage2 adds the kiosk configuration. Rebuilt when stage1 just ran or its
    # artifacts are missing.
    if [ "${STAGE1_RAN}" = 1 ] || [ ! -f "${DIR}/deploy/${ARCH}/recovery.manifest" ]; then
        echo "[${ARCH}] Stage 1b: Building recovery (fallback) kernel+initrd..."
        ${DOCKER} run "${RUN_OPTS[@]}" unitotem-builder /unitotem/stage1-recovery-initrd.sh
    else
        echo "[${ARCH}] Stage 1b: skipping (recovery.manifest exists)"
    fi

    # Stage 2: Configure
    if should_run 2; then
        echo "[${ARCH}] Stage 2: Configuring system..."
        ${DOCKER} run "${RUN_OPTS[@]}" unitotem-builder /unitotem/stage2-configure.sh
        echo "${AB_LAYOUT:-1}" > "${DIR}/work/${ARCH}/stage2.layout"
    fi

    # Stage 3: Create disk image (always runs to produce fresh image)
    echo "[${ARCH}] Stage 3: Creating disk image..."
    ${DOCKER} run "${RUN_OPTS[@]}" unitotem-builder /unitotem/stage3-image.sh

    adopt_lock
    echo "[${ARCH}] Done! Image in: deploy/${ARCH}/"
done

echo ""
echo "All builds complete."
ls -lh "${DIR}/deploy"/*/*
