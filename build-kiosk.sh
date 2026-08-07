#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER="${DOCKER:-docker}"
ARCHES="${ARCHES:-amd64 arm64}"
FORCE_STAGE="${FORCE_STAGE:-}"   # set to 0,1,2 to force rebuild from that stage onward

# Native arm64 build on the real Pi, when reachable: cross-building arm64
# under qemu-aarch64 pays real emulation cost (mkinitramfs's own ldd-based
# dependency resolution in copy_exec, package postinst/trigger scripts like
# ldconfig/depmod/systemctl) - genuine ARM64 code execution, not something
# either this pipeline or upstream pi-gen avoids when actually cross-arch
# building. Running the exact same stage scripts natively on the Pi itself
# pays none of that cost. See CLAUDE.md for the policy and why (2026-08-02).
PI_HOST="${PI_HOST:-root@<pi-host>}"
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
    command -v sshpass >/dev/null 2>&1 || return 1
    _pi_ssh -o ConnectTimeout=5 true 2>/dev/null
}

# Builds one arch's images by running the same kiosk/stageN-*.sh scripts
# directly on the Pi over SSH, instead of under Docker+qemu-aarch64 here.
# root is read-only by design on the Pi (appliance rootfs) - the build tree
# lives on DATA (ample free space, unlike the small ROOT partition), and
# root only gets remounted rw for the one-time creation of the /kiosk,
# /work, /deploy compat symlinks the stage scripts hardcode, then remounted
# back ro immediately. Always does a full stage0-3 pass (no should_run-style
# incremental caching yet for this path) - still far faster than an
# incremental qemu build, since zero emulation cost applies at all.
build_natively_on_pi() {
    echo "[arm64] Pi raggiungibile (${PI_HOST}): build nativa, nessuna emulazione qemu"

    # /var/lib/dpkg va rimontato a parte: e' un bind su ROOT (vedi
    # kiosk/files/overlayfs-hook.sh) e un bind porta i propri flag, quindi
    # resta read-only anche dopo il remount di /. Senza, apt fallisce con
    # "Not using locking for read only lock file /var/lib/dpkg/lock" e la
    # build nativa ripiega su qemu - osservato, ed e' la stessa asimmetria
    # gia' corretta in kiosk/files/kiosk-update: questo era il secondo
    # chiamante, mancato la prima volta.
    #
    # root resta scrivibile per l'intera build (non solo per creare i
    # symlink): apt-get install scrive su /var/lib/dpkg, /usr, /etc - un
    # secondo remount,ro subito dopo i symlink avrebbe fatto fallire quello.
    # Torna a ro comunque vada, in un trap così un fallimento a metà non
    # lascia il root del kiosk scrivibile in produzione.
    _pi_ssh "trap 'mount -o remount,ro / 2>/dev/null || true' EXIT; \
        mkdir -p '${PI_BUILD_BASE}/kiosk' '${PI_BUILD_BASE}/work' '${PI_BUILD_BASE}/deploy' && \
        mount -o remount,rw / && \
        { mountpoint -q /var/lib/dpkg && mount -o remount,rw /var/lib/dpkg || true; } && \
        ln -sfn '${PI_BUILD_BASE}/kiosk' /kiosk && \
        ln -sfn '${PI_BUILD_BASE}/work' /work && \
        ln -sfn '${PI_BUILD_BASE}/deploy' /deploy" \
        || { echo "[arm64] impossibile preparare l'albero di build sul Pi" >&2; return 1; }

    echo "[arm64] Sincronizzo i sorgenti sul Pi..."
    _pi_rsync -r --delete "${DIR}/kiosk/" "${PI_HOST}:${PI_BUILD_BASE}/kiosk/"
    _pi_rsync "${DIR}/deploy/ota-engine.sh" "${PI_HOST}:${PI_BUILD_BASE}/kiosk/files/ota-engine.sh"
    _pi_rsync "${DIR}/deploy/parts-lib.sh" "${PI_HOST}:${PI_BUILD_BASE}/kiosk/deploy-parts-lib.sh" 2>/dev/null || true

    # Both paths are moved off their container-friendly defaults, each after
    # failing here for its own reason: /tmp on the Pi is a 256 MB tmpfs mounted
    # nodev, which debootstrap refuses outright ("Cannot install into target
    # ... mounted with noexec or nodev"), and /mnt is where DATA is mounted, so
    # stage3 mounting the image there hid the very build tree it was about to
    # copy. Both failures sent the whole native build back to qemu without
    # saying why.
    local envvars="ARCH=arm64 ROOTFS='${PI_BUILD_BASE}/rootfs' IMG_MNT='${PI_BUILD_BASE}/imgmnt'"
    local var
    for var in RELEASE MIRROR KIOSK_HOSTNAME ROOT_PASSWORD KIOSK_LOCALE KIOSK_TIMEZONE IMAGE_SIZE; do
        [ -n "${!var:-}" ] && envvars="${envvars} ${var}='${!var}'"
    done

    # Una sola sessione ssh per tutta la build reale: root deve restare
    # scrivibile dall'apt-get install fino all'ultimo stage, un remount,ro
    # a metà (come accadrebbe con sessioni ssh separate) farebbe fallire gli
    # stage successivi con "Read-only file system".
    _pi_ssh "set -e; \
        trap 'mount -o remount,ro / 2>/dev/null || true' EXIT; \
        mount -o remount,rw /; \
        { mountpoint -q /var/lib/dpkg && mount -o remount,rw /var/lib/dpkg; } || true; \
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            debootstrap qemu-user-static dosfstools e2fsprogs gdisk parted kpartx util-linux \
            xz-utils pigz curl ca-certificates wget gnupg2 rsync git partclone \
            device-tree-compiler initramfs-tools-core cpio >/dev/null; \
        for s in stage0-bootstrap.sh stage1-packages.sh stage1-recovery-initrd.sh \
                 stage2-configure.sh stage3-image.sh; do \
            echo \"[arm64] (nativo) Eseguo \$s...\"; \
            env ${envvars} bash /kiosk/\$s; \
        done" \
        || { echo "[arm64] build nativa fallita sul Pi" >&2; return 1; }

    echo "[arm64] Recupero i risultati dal Pi..."
    mkdir -p "${DIR}/work/arm64" "${DIR}/deploy/arm64"
    _pi_rsync "${PI_HOST}:${PI_BUILD_BASE}/work/arm64/" "${DIR}/work/arm64/"
    _pi_rsync "${PI_HOST}:${PI_BUILD_BASE}/deploy/arm64/" "${DIR}/deploy/arm64/"
    echo "[arm64] Build nativa completata."
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
echo ">>> Building kiosk builder image..."
${DOCKER} build -f "${DIR}/Dockerfile.kiosk" -t kiosk-builder "${DIR}"

mkdir -p "${DIR}/work" "${DIR}/deploy"

for ARCH in ${ARCHES}; do
    echo ""
    echo "=================================================="
    echo "  Building for ARCH=${ARCH}"
    echo "=================================================="

    if [ "${ARCH}" = "arm64" ] && [ "${PI_NATIVE_BUILD:-1}" = 1 ] && probe_pi; then
        if build_natively_on_pi; then
            echo "[${ARCH}] Done (build nativa)! Image in: deploy/${ARCH}/"
            continue
        fi
        echo "[arm64] Build nativa fallita, ripiego su Docker+qemu-aarch64..." >&2
    fi

    mkdir -p "${DIR}/work/${ARCH}" "${DIR}/deploy/${ARCH}"

    RUN_OPTS=(
        --rm
        --privileged
        -v /dev:/dev
        -v "${DIR}/work:/work"
        -v "${DIR}/deploy:/deploy"
        -e "ARCH=${ARCH}"
    )

    # Pass through optional config overrides
    for VAR in RELEASE MIRROR KIOSK_HOSTNAME ROOT_PASSWORD \
               KIOSK_LOCALE KIOSK_TIMEZONE IMAGE_SIZE; do
        [ -n "${!VAR:-}" ] && RUN_OPTS+=(-e "${VAR}=${!VAR}")
    done

    # Helper: should we (re-)run a stage? Not just "does the tarball exist" -
    # a stale-but-present tarball is exactly how a fixed
    # kiosk/stageN-*.sh/kiosk/files/*/deploy/ota-engine.sh silently fails to
    # make it into a rebuilt image (see the OTA redesign plan's build-cache
    # note in kiosk/common.sh's intent - this used to only check existence,
    # which meant an edited stage1-packages.sh was NOT enough to trigger a
    # stage1 rebuild, discovered live when a real fix did not end up in the
    # image it was supposed to fix).
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
        # kiosk/files/* and deploy/ota-engine.sh only matter to the stages
        # that actually consume them (stage1-packages.sh and
        # stage1-recovery-initrd.sh install ota-engine.sh/ota-hook, stage2
        # installs fstab/grub-default/the real system's own OTA hook) -
        # stage0 (bootstrap) and stage3 (image assembly from an already-built
        # stage2 tarball) touch neither. Confirmed the hard way: with
        # ota-engine.sh treated as an unconditional dependency of every
        # stage, editing it forced a full stage0 re-bootstrap (~150 packages
        # re-downloaded) with nothing in stage0 actually depending on it.
        local extra_deps=()
        case "$stage_num" in
            1|2) extra_deps=("${DIR}/kiosk/files"/* "${DIR}/deploy/ota-engine.sh") ;;
        esac
        # The previous stage's tarball is this stage's actual input, and it was
        # missing from this list. The consequence was not theoretical: stage1
        # was rebuilt with a changed package set, stage2 saw none of its own
        # sources change and skipped, so stage3 assembled the image from a
        # stage2 tarball built the day before - and the "cleaned" image still
        # contained everything the change had removed. Nothing in the log said
        # so; the package count being identical was the only hint.
        local prev_tarball=""
        if [ "$stage_num" -gt 0 ]; then
            prev_tarball="${DIR}/work/${ARCH}/stage$((stage_num - 1)).tar.gz"
        fi
        local dep newest_dep=""
        for dep in "${DIR}/kiosk/stage${stage_num}"*.sh "${DIR}/kiosk/common.sh" \
                   "${extra_deps[@]}" "${DIR}/Dockerfile.kiosk" \
                   ${prev_tarball:+"$prev_tarball"}; do
            [ -e "$dep" ] || continue
            if [ -z "$newest_dep" ] || [ "$dep" -nt "$newest_dep" ]; then newest_dep="$dep"; fi
        done
        if [ -n "$newest_dep" ] && [ "$newest_dep" -nt "$tarball" ]; then
            echo "[${ARCH}] Stage ${stage_num}: rebuild (${newest_dep} e' piu' recente del tarball in cache)"
            rm -f "${tarball}"
            return 0
        fi
        echo "[${ARCH}] Stage ${stage_num}: skipping (tarball esiste ed e' aggiornato)"
        return 1
    }

    # Stage 0: Bootstrap
    if should_run 0; then
        echo "[${ARCH}] Stage 0: Bootstrap..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage0-bootstrap.sh
    fi

    # Stage 1: Packages
    STAGE1_RAN=0
    if should_run 1; then
        echo "[${ARCH}] Stage 1: Installing packages..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage1-packages.sh
        STAGE1_RAN=1
    fi

    # Stage 1b: Recovery (OTA fallback) kernel+initrd, built from stage1
    # before stage2 layers kiosk-specific configuration on. Rebuilt whenever
    # stage1 itself was just (re)built (it consumes stage1.tar.gz directly),
    # or if its artifacts are simply missing (e.g. work/ kept but deploy/
    # cleaned).
    if [ "${STAGE1_RAN}" = 1 ] || [ ! -f "${DIR}/deploy/${ARCH}/recovery.manifest" ]; then
        echo "[${ARCH}] Stage 1b: Building recovery (fallback) kernel+initrd..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage1-recovery-initrd.sh
    else
        echo "[${ARCH}] Stage 1b: skipping (recovery.manifest exists)"
    fi

    # Stage 2: Configure
    if should_run 2; then
        echo "[${ARCH}] Stage 2: Configuring system..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage2-configure.sh
    fi

    # Stage 3: Create disk image (always runs to produce fresh image)
    echo "[${ARCH}] Stage 3: Creating disk image..."
    ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage3-image.sh

    echo "[${ARCH}] Done! Image in: deploy/${ARCH}/"
done

echo ""
echo "All builds complete."
ls -lh "${DIR}/deploy"/*/*
