# Image build pipeline

Paths: relative to the repository root.

Builds one UniTotem disk image per architecture: `deploy/<arch>/unitotem-<YYYY-MM-DD>-<arch>.img.xz` (GPT on amd64, DOS on arm64; [storage](storage-and-persistence.md#layout)). Stages 0-3 run in the `unitotem-builder` Docker image, or natively on an arm64 device when one is reachable.

## Files

| Path | Role |
|---|---|
| `build-unitotem.sh` | Entry point: builder image, binfmt, per-arch loop, package-lock gate, stage caching, native arm64 path, Docker path |
| `Dockerfile.unitotem` | Builder image (debian:bookworm): debootstrap, qemu-user-static, aria2, zstd, partclone, initramfs-tools-core, python3. Copies `unitotem/`, `deploy/script/ota-engine.sh`, `deploy/script/parts-lib.sh`, `tools/pkglock.py` to `/unitotem/` |
| `unitotem/common.sh` | Defaults, A/B sizes, chroot mount helpers, `apt_install` (aria2 prefetch, then apt) |
| `unitotem/stage0-bootstrap.sh` | debootstrap base to `build/<arch>/stage0.tar.gz` |
| `unitotem/stage1-packages.sh` | Apt sources, package lock, kernel, firmware, bootloader, GPU, Wayland, manager .debs, purge, lock verify/freeze -> `stage1.tar.gz` |
| `unitotem/stage1-recovery-initrd.sh` | Resident OTA fallback kernel+initrd and `recovery.manifest` (Docker path; native variant: [Native recovery initrd](#native-recovery-initrd)) |
| `unitotem/build-recovery-initrd.sh`, `unitotem/build-recovery-initrd.py` | Native builder of the same kernel+initrd and manifest: host Python, no chroot, no target binary runs |
| `unitotem/ninitrd/` | Native builder package: `assemble.py` (staging, cpio), `stage.py` (copy_file, copy_exec, libraries), `modules.py` (modules, firmware), `stockhooks.py` (stock hooks), `otahook.py` (list directives), `lists.py` (list reader) |
| `unitotem/files/ota-initrd.list` | Names the fallback initrd carries (directive table in [Native recovery initrd](#native-recovery-initrd)); read by `ota-hook` and by the native builder |
| `unitotem/stage2-configure.sh` | Hostname, locale, timezone, root first-access state, boot config, fstab, NetworkManager, services, initramfs, arm64 FIRMWARE files -> `stage2.tar.gz` |
| `unitotem/make-boot-tree.sh` | arm64: the boot tree (`build/arm64/boot-tree/`): Pi firmware, recovery kernel and initrd, recovery `config.txt`/`cmdline.txt`, `boot-tree.sha256`. Stage 3 and the preboot card read it |
| `unitotem/stage3-image.sh` | Partition table, format, populate, bootloader, boot assertions, baseline, verify, fsck, shrink, xz |
| `unitotem/shrink-root-image.sh` | A/B: ROOT_A shrunk to its minimum, partition and file cut to fit, on GPT and DOS (stage 3) |
| `unitotem/verify-image.sh` | Static rule checks on the mounted image (PASS/FAIL) |
| `unitotem/check-recovery-commands.sh` | Every external command of `ota-engine.sh` exists in the recovery initrd |
| `unitotem/check-engine-copy.sh` | The `ota-engine.sh` inside an initramfs is the repository's (verify-image: recovery initrd and slot initramfs) |
| `unitotem/initrd-scan.py` | Reads the entries of an initramfs (`list`, `get`): plain, zstd, gzip, xz segments in any order. The checks and the boot tree use it; `lsinitramfs` fails on a zstd initrd with an appended archive |
| `unitotem/slim-initramfs.py` | arm64 initramfs reduction: no `hwdb.bin`, Raspberry Pi Wi-Fi firmware only |
| `unitotem/locks/<arch>.lock` | Pinned package set (see `package-lock.md`) |
| `unitotem/files/` | Payload copied into the image: units, scripts, configs, hooks,  |

## How it works

- `build-unitotem.sh` checks `docker info`, registers binfmt, builds `unitotem-builder`.
- Several arches: one child per arch (`BUILD_CHILD=1`, output prefixed `[arch]`), in parallel.
- Per arch: package-lock gate (`package-lock.md`), then native or Docker path.
- arm64 native path (why: `mkinitramfs` runs `ldd` of the target and apt postinst/trigger scripts run arm64 code, which qemu-aarch64 emulates slowly): used when `PI_NATIVE_BUILD=1` (default), `sshpass` exists and the device answers within 5 s. A native failure falls back to Docker + qemu-aarch64.
  - rsyncs `unitotem/`, `ota-engine.sh`, `pkglock.py`, `build/extra-debs/` to the device, installs build deps, runs stage 0-3 in one SSH session, rsyncs `build/arm64` and `deploy/arm64` back, adopts the new lock. No stage caching.
- Docker path: one `docker run --rm --privileged` per stage.
  - arm64 on an amd64 build server (Docker + `qemu-aarch64` registered in `binfmt_misc`; check with `docker run --rm --platform linux/arm64 debian:trixie uname -m`): `FORCE_STAGE=1 ARCHES=arm64 ./build-unitotem.sh` with `PI_HOST` unset. Measured on a 144-core server building amd64 in parallel: stage 0 about 15 min, stage 1 about 50 min (package configuration under emulation), stages 2-3 about 15 min; about 65 min to the image, `verify-image` 190 checks, 0 failed. The resulting image booted on a Raspberry Pi 4 and passed the A/B update, so it is equivalent to a native build. The native path needs the test Pi for 1.5-2 h and blocks it; the server path does not.
  - Stage 0 and 1: run when the tarball is missing or stale.
  - Stage 1b (recovery initrd): runs when stage 1 ran or `build/<arch>/recovery/recovery.manifest` is missing.
  - `ONLY_RECOVERY=1 PKGLOCK=off PI_NATIVE_BUILD=0 ARCHES=<arch> ./build-unitotem.sh` rebuilds only the recovery kernel and initrd from the existing stage 1 tarball (minutes; output in `build/<arch>/recovery/`).
  - `NATIVE_INITRD=1 ONLY_RECOVERY=1 PKGLOCK=off PI_NATIVE_BUILD=0 ARCHES=<arch> ./build-unitotem.sh` runs the same rebuild with the native builder and no Docker at all (no daemon, no builder image, no binfmt).
  - Stage 1b installs `deploy/script/ota-engine.sh`, `unitotem/files/ota-hook` and `unitotem/files/ota-initrd.list` (at `/usr/share/unitotem-ota/`) after extracting `stage1.tar.gz` (as stage 2 does for the slot initramfs): the tarball can hold an older engine. Rebuild after a change of the engine alone, without redoing stage 1 (about an hour per architecture): on the build server set the mtime of `deploy/script/ota-engine.sh` before the stage 1 tarball (`touch -d`), delete `deploy/<arch>/recovery.manifest`, run with `FORCE_STAGE=2`; stage 1 is skipped, 1b, 2 and 3 run (about 25 minutes). A later full rebuild reads the real file.
  - Stage 2: runs when stale or when `AB_LAYOUT` differs from `build/<arch>/stage2.layout`.
  - Stage 3: always runs.
- Staleness: a tarball is rebuilt when `unitotem/stage<N>*.sh`, `unitotem/common.sh`, `Dockerfile.unitotem` or the previous tarball is newer. Stages 1 and 2 also depend on `unitotem/files/*` and `deploy/script/ota-engine.sh`. `FORCE_STAGE=N` deletes tarballs N and up.

### Stages

- Stage 0: debootstrap (arm64: `--foreign`; second stage under qemu-aarch64 in Docker, native on the device).
- Stage 1:
  - The manager apt key (`/etc/apt/trusted.gpg.d/unitotem-manager.asc`) and source list (`sources.list.d/unitotem-manager.list`) are fetched from the project's GitHub Pages apt repository on every build.
  - Apt sources from `RELEASE` (trixie): `trixie`, `trixie-updates`, `trixie-security`, `trixie-backports` (`main contrib non-free non-free-firmware`). arm64 adds the Raspberry Pi archive and keyring. amd64 adds NVIDIA's repository (below).
  - With a lock: snapshot.debian.org at the lock date for `trixie`, `trixie-updates` and `trixie-backports` (`archive/debian/<TS>/`), and `debian-security/<TS>/`; preferences pin every locked package (`Pin-Priority: 1001`); `dist-upgrade --allow-downgrades`. The Raspberry Pi archive and NVIDIA's repository have no snapshots and are read live ([package-lock](package-lock.md)).
  - Backports, both archs: `trixie-backports` is `NotAutomatic` (priority 100). `/etc/apt/preferences.d/97-unitotem-backports` (priority 990, selector `n=trixie-backports`: the Release file's Codename; the Suite is `stable-backports` and `a=` never matches) selects the packages taken from it. A pin, not `apt-get -t`: `-t` would pull every dependency that has a backports build. The file stays in the shipped image.
    - amd64: `linux-base`, `linux-image-*`, `linux-headers-*`, `linux-kbuild-*`, `linux-compiler-gcc-*`, `linux-support-*`, `firmware-*`, `mesa-*`, `libgl1-mesa-dri`, `libegl-mesa0`, `libglx-mesa0`, `libgbm1`, `libglapi-mesa`, PipeWire and WirePlumber packages. Kernel 7.2.x with headers and `linux-base`, all `firmware-*`, Mesa 26.1.
    - arm64: PipeWire and WirePlumber packages only. The kernel, firmware and Mesa come from the Raspberry Pi archive and stable.
    - Why PipeWire 1.6 and WirePlumber 0.5.12: newer WirePlumber and PipeWire create the HDMI audio sink when the display appears after boot.
  - amd64 kernel: exactly one kernel directory under `/lib/modules` is required (`rootfs_kver()` in `stage1-packages.sh` and `stage1-recovery-initrd.sh`, plus a `verify-image.sh` check). The 7.2 kernel package depends on `dracut | initramfs-tools`: apt installs dracut first, and installing initramfs-tools removes it again (`dracut-core` and `busybox` stay). The image uses initramfs-tools (the OTA hooks are initramfs-tools hooks).
  - amd64 NVIDIA driver (NVIDIA's repository, not Debian):
    - Why: Debian stops at branch 550, which does not compile against kernel 7.x (66 compile errors measured on 7.2.12). NVIDIA's repository serves branch 620 (kernel 7.2 builds). The stable kernel 6.12 with the 550 branch builds, but is not used.
    - Source: `https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/`, suite `/`, no components: `deb [signed-by=/usr/share/keyrings/unitotem-nvidia.gpg] <url> /`. The Debian 13 repository only: any `RELEASE` other than trixie stops the build.
    - Key: from `cuda-keyring_1.1-1_all.deb` (sha256 `d0d4ef986a44400f9db33c600ef33a985175e7cc63d805a10e1839c7a1e78f5f`, key file `usr/share/keyrings/cuda-archive-keyring.gpg`). The primary key fingerprint must be `02182E60104FCDC26EAE1B8597A5D4CB8793F200` (pinned in `stage1-packages.sh`); any other fingerprint stops the build. NVIDIA publishes no fingerprint page: the key ID `8793F200` is confirmed only by a forum thread. Trust on first fetch, pinned by fingerprint afterwards. Used through `signed-by` only (no `apt-key`, nothing in `trusted.gpg.d`).
    - Installed with `--no-install-recommends`, at `620.70.06-1` (`libnvidia-egl-gbm1` at its own version `1.1.4-2`): `nvidia-kernel-open-dkms`, `nvidia-kernel-support`, `firmware-nvidia-gsp`, `libnvidia-allocator1`, `libnvidia-egl-gbm1`, `libgles-nvidia1`, `libgles-nvidia2`, `libegl-nvidia0`, `libglx-nvidia0`, `nvidia-egl-icd`. Debian's `nvidia-driver`, `nvidia-kernel-dkms` and `firmware-nvidia-gsp` 550 are not installed.
    - Pins, `/etc/apt/preferences.d/96-unitotem-nvidia` (stage 1 only): NVIDIA-origin packages `nvidia-*`, `libnvidia-*`, `libgles-nvidia*`, `libegl-nvidia*`, `libglx-nvidia*`, `firmware-nvidia-gsp`, `xserver-xorg-video-nvidia`, `glx-alternative-nvidia` at priority 995 (above the backports 990, so NVIDIA's `firmware-nvidia-gsp` wins over Debian's `firmware-*` from backports). Every other package of that origin at -1, so NVIDIA's `dkms` 3.4.4 and `libegl1` never replace Debian's (`dkms` 3.2.2 is kept).
    - Supported GPUs: Turing and newer (the open kernel modules). Maxwell, Pascal and Volta run on nouveau with NVK and Mesa 26 and need `firmware-nvidia-graphics` (stable `/trixie`, installed before the compiler purge); NVIDIA's legacy branch for them is 580.
    - DKMS module: `nvidia/620.70.06` builds `nvidia`, `nvidia-modeset`, `nvidia-drm`, `nvidia-uvm` and `nvidia-peermem` into `/lib/modules/<kver>/updates/dkms/` as uncompressed `.ko` (measured). Vermagic `7.2.12+deb13-amd64`. Signed by the DKMS key generated in the build (signer `DKMS module signing key`); `/var/lib/dkms/mok.key` is removed, `mok.pub` kept. The build fails unless `nvidia.ko*` exists for the single kernel.
    - Replay measurements (`apt-get -s` of the stage-1 install order, Installed-Size sums before the purges; not image sizes):

      | Variant | Packages | Installed MiB |
      |---|---|---|
      | Before the change (stable suite, Debian `nvidia-driver` 550) | 903 | 2693.5 |
      | Backports, NVIDIA 550 from Debian | 914 | 2993.9 |
      | Final: backports, NVIDIA repository 620 | 878 | 3052.0 |

      Largest NVIDIA packages of the final replay (Installed-Size, KiB): `nvidia-kernel-open-dkms` 113043, `firmware-nvidia-gsp` 101345, `libnvidia-gpucomp` 126875, `libnvidia-glcore` 35105, `libnvidia-eglcore` 33212, `libnvidia-glvkspirv` 10546. 16 NVIDIA packages in the replay.
  - amd64 firmware and CPU microcode (added to the first install): `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-mediatek`, `firmware-brcm80211`, `firmware-intel-misc`, `intel-microcode`, `amd64-microcode`. Debian 13 `firmware-linux-nonfree` depends only on `firmware-misc-nonfree` and `firmware-amd-graphics`, so without these a PC has no Wi-Fi or Bluetooth firmware. Microcode is loaded early from the initramfs.
  - amd64: linux-image-amd64, linux-headers-amd64 (kept in the image: the NVIDIA DKMS build needs the headers), firmware (`firmware-linux`, `firmware-linux-nonfree`, `firmware-misc-nonfree`, `firmware-intel-graphics`), grub-efi-amd64, grub-pc-bin, efibootmgr, shim-signed, grub-efi-amd64-signed (staged only), mokutil, Mesa 26.1 (trixie-backports), Intel and AMD drivers, the NVIDIA set above.
  - arm64: linux-image-rpi-v8, raspi-firmware, firmware-brcm80211, v4l-utils, raspi-utils. No `firmware-linux*`/`firmware-misc-nonfree` (they bring `firmware-amd-graphics`, 90 MB, for GPUs a Pi does not have).
  - Stage-1-only apt pin `/etc/apt/preferences.d/98-unitotem-stage1-skip` (removed in the cleanup; the image keeps only `97-unitotem-backports`): `pocketsphinx-en-us`, `ghostscript`, `iso-codes`, `qt6-translations-l10n`, `network-manager-l10n`, `libglib2.0-data` are Recommends only. Never pin a package that is the first alternative of a Depends or Recommends (`libvulkan1` recommends `mesa-vulkan-drivers | vulkan-icd`: the pin made apt install the NVIDIA tesla Vulkan stack instead): purge such packages after the install.
  - Not installed: GStreamer (the viewer is CEF with its own ffmpeg, the VNC server is wayvnc), `tigervnc-scraping-server` (X11 scraper, pulls Perl), `nvidia-vaapi-driver` (Chromium does not use VA-API on NVIDIA).
  - Both: base set (`unitotem/stage1-packages.sh`, installed with Recommends): `locales`, `sudo`, `openssh-server`, `htop`, `btop`, `nano`, `less`, network and Python packages. `htop` is in the base set; `btop` adds `btop` and `libncursesw6`, and `libgpm2` through its Recommends.
  - Both: plymouth (no text plugin), `labwc wlr-randr wlopm wayvnc xwayland qt6-wayland kbd`, pipewire, ddcutil. `xwayland` is present only because labwc starts it lazily and logs an error without it; no X client runs.
  - Both: `libpam-pwquality` with `--no-install-recommends` (Recommends would add `cracklib-runtime`, `wamerican`, `file`). Pulls `libpam-pwquality`, `libpwquality1`, `libpwquality-common`, `libcrack2`. See [image-runtime](image-runtime.md#password-policy).
  - Manager .debs from `build/extra-debs/<arch>/` installed over the apt set; every unitotem package must be 3.x.
  - Purge: arm64 Chromium (apt); compilers (`dpkg --force-depends`, keeps DKMS modules: `build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 gcc-14-for-host cpp-14-for-host` and the `x86-64-linux-gnu` cross variants; the 7.2 headers depend on `gcc-14-for-host`/`cpp-14-for-host`); `mesa-vulkan-drivers` (apt; the viewer renders through ANGLE-GL, llvmpipe/radeonsi stay in `mesa-libgallium` + `libllvm19`); `libclang1-19` (`dpkg --force-depends`: `libshiboken6` declares it, no shared object loads it); amd64 X server packages. No NVIDIA library is purged: the NVIDIA set is installed with `--no-install-recommends` and pulls no CUDA, NVDEC or Vulkan library.
  - Asserts labwc, wlr-randr, wlopm, wayvnc, mesa-libgallium, libllvm19, libneatvnc and libavcodec61 survive and the NVIDIA module `nvidia.ko*` exists in the single kernel directory (amd64, after each purge). Removes `/var/lib/dkms/mok.key`.
  - Lock: verify (exact match) or freeze to `build/<arch>/<arch>.lock.new`.
- Stage 1b: copies kernel and initrd (`MODULES=most`, zstd), writes `recovery.manifest` with sha256 values. `UNITOTEM_RECOVERY_BUILD_DATE` is the set's level (14 digits, `boot.md#recovery-set`). With `NATIVE_INITRD=1` the native builder runs instead of `stage1-recovery-initrd.sh` (same inputs and outputs).
- Stage 2:
  - Hostname, root first-access state (`passwd -d`, login shell, marker group), sshd_config, packages `sudo` and `adduser`.
  - Locale (`UNITOTEM_LOCALE`): `<locale> UTF-8` is uncommented in `/etc/locale.gen` and `locale-gen` runs (`C.UTF-8` is built into libc-bin, always available). `LANG=<locale>` is written to `/etc/default/locale` and `/etc/locale.conf`. `unitotem/files/unitotem-locale.sh` is installed as `/etc/profile.d/unitotem-locale.sh` (mode 644).
  - Timezone (`UNITOTEM_TIMEZONE`): `/etc/localtime` links to `/usr/share/zoneinfo/<timezone>`, `/etc/timezone` gets the same name, then `dpkg-reconfigure tzdata` canonicalises `UTC` to `Etc/UTC` (the link ends as `/usr/share/zoneinfo/Etc/UTC`, `/etc/timezone` as `Etc/UTC`).
  - Password policy: installs `unitotem/files/unitotem-pwquality` to `/usr/share/pam-configs/`, then `chroot pam-auth-update --package --force` with `DEBIAN_FRONTEND=noninteractive`. Prints "Incompatible PAM profiles selected" (its `Conflicts: pwquality` removes the stock profile); exit 0, one `pam_pwquality` line remains.
  - amd64: `/etc/default/grub`, `10_unitotem_ab` (A/B) or `45_unitotem_ota`.
  - arm64: `config.txt`, `cmdline.txt` (`root=LABEL=ROOT_A unitotem.slot=a`).
  - fstab (A/B drops the `/` and BOOT lines), NetworkManager, firewall, Chromium accel flags, apt timers masked.
  - amd64 NVIDIA: `/etc/modules-load.d/unitotem-nvidia.conf` (`nvidia-drm`), `/etc/modprobe.d/unitotem-nvidia-drm.conf` (`options nvidia-drm modeset=1 fbdev=1`), `unitotem-nouveau-fallback.service` (script in `/usr/lib/unitotem/nouveau-fallback`, enabled by a `multi-user.target.wants` symlink). Reason: `nvidia-kernel-support` blacklists nouveau unconditionally, and the open modules do not drive Pascal and older GPUs ([image-runtime](image-runtime.md#nvidia-amd64)).
  - Services enabled, `update-initramfs -u -k all`, arm64 slim initramfs, `kernel8.img`, `initramfs8`, `bcm27*.dtb` copied to FIRMWARE.
  - Removes the build-time TLS certificate (each device generates its own).
- Boot tree (arm64, `unitotem/make-boot-tree.sh`, between stage 2 and stage 3, always rebuilt): input `stage2.tar.gz` (`boot/firmware`, overlays left out) and the recovery set of stage 1b. Output `build/arm64/boot-tree/`: `bootcode.bin`, `start*.elf`, `fixup*.dat`, top-level `*.dtb`, `LICENCE.broadcom` (the `_x` and `_db` variants left out), `recovery8.img`, `recovery-initrd.img` (the repository's `ota-engine.sh` appended as a second cpio entry only when the stage 1b initrd does not already hold an identical copy; otherwise the file is copied byte for byte), `config.txt` and `cmdline.txt` of the recovery boot (`kernel=recovery8.img`, `unitotem.ota=recover`), and `boot-tree.sha256` (level line, then sha256 per file). The tree is the FIRMWARE content shared by the full image and the preboot card, built once.
- Stage 3:
  - Legacy: `truncate` to `IMAGE_SIZE`. A/B: `truncate` to the layout, 1 MiB + boot partition + `ROOT_SLOT_SIZE` + 1 MiB (the backup GPT on amd64). Partition: GPT on amd64 (sgdisk), DOS primaries on arm64; A/B creates only the boot partition, ROOT_A (and the amd64 BIOS p5); ROOT_B and DATA are not created. `losetup --partscan`; `mkfs`; rsync rootfs into ROOT_A. A/B mounts no DATA: `/mnt/data` is an empty directory of ROOT_A.
  - arm64: the boot tree is checked against `boot-tree.sha256` and its files are copied onto FIRMWARE over the stage-2 copies (`config.txt` and `cmdline.txt` stay the full system's); each copy is compared byte for byte. The recovery kernel and initrd come from the tree.
  - Recovery kernel and initrd copied to the boot FAT under the names of `boot.md#recovery-set`, with `recovery.sha256` (level line, then sha256 per file). The level must be 14 digits or the build stops. arm64: the level must equal the tree's.
  - The same set goes to `usr/share/unitotem/recovery/` in the root (`vmlinuz`, `initrd.img`, `manifest`; arm64 also `dtb/*.dtb` copied from the top-level FIRMWARE dtbs). Written into the mounted root after the rootfs rsync and before the partitions are cut, so ROOT_A carries it.
  - arm64 A/B: kernel, initramfs, cmdline move to `slota/`; `config.txt` gets `os_prefix=slota/`; dtbs and overlays copied into `slota/`.
  - amd64: `grub-install` for EFI and BIOS (`--removable --no-uefi-secure-boot`), the signed Secure Boot chain installed in `EFI/BOOT` (shim as `BOOTX64.EFI`), `grub-mkconfig` (A/B: `grub.cfg` and `grubenv` in `unitotem-grub/` on the ESP).
  - A/B: `unitotem-layout` in the root of the boot FAT (`UNITOTEM_SLOT_SECTORS=<ROOT_SLOT_SIZE in sectors>`, 10485760 for 5G), written before the unmount.
  - Boot assertions (kernel magic, dtb parse, initramfs `/init`, `config.txt` references), release-version, change baseline, `verify-image.sh`, fsck of all partitions.
  - A/B: `unitotem/shrink-root-image.sh IMG` after `losetup -d`: `e2fsck -fy`, `resize2fs -M` repeated until the block count is stable, partition rewritten to filesystem size + 16 MiB (rounded up to 1 MiB) with the same start and type; file truncated 1 MiB after the partition. GPT: unique GUID, name and attributes kept, backup GPT moved to the end (`sgdisk -v` must be clean). DOS: no backup table. Idempotent. Refuses unless partition 2 is ROOT_A and the last data partition. Prints `ROOT_A fs <N> MiB, partition <M> MiB, image <K> MiB`. Measured on a 301 MB test tree in a 5 GiB ROOT_A: 4 resize passes, about 3 s, fs 647 MiB, partition 664 MiB; an empty ROOT_A shrinks to 86 MiB (the 64 MiB journal included). Checked with both layouts (arm64 and amd64): tree checksums, GUIDs and fsck unchanged; second run leaves the table and size unchanged.
  - Preboot card (arm64, after stage 3, `deploy/script/make-preboot-image.sh --tree build/arm64/boot-tree`, run in the builder container with `deploy/script` mounted read-only at `/deploy-script`; native: on the Pi): `deploy/arm64/unitotem-preboot-arm64.img` and `.img.xz`. The tree is checked against its manifest and copied to a FAT32 partition from 1 MiB (MBR type 0c). The same files as the image's FIRMWARE, so the card and the image cannot disagree.
  - `xz -T0` of the image; the raw `.img` file is removed.

### Native arm64 build

`NATIVE_BUILD=1` (arm64 only, default 0) builds the whole image on an amd64 PC with no binfmt handler and no qemu chroot: `FORCE_STAGE=0 NATIVE_BUILD=1 ARCHES=arm64 PI_HOST= ./build-unitotem.sh`. Stages 0-3 run in the `unitotem-nbuilder` image (`Dockerfile.nbuild`, Debian trixie: host dpkg 1.22, apt, mmdebstrap, adduser, ca-certificates, fontconfig, shared-mime-info, GLib/GTK tools, xfonts-utils, sgml-base, xml-core, openssh-client, partclone, kmod, qemu-user-static as a plain binary). The container runs `--privileged`, `--cpu-shares=8192`. The recovery initrd is the native builder ([Native recovery initrd](#native-recovery-initrd)) and the slot initramfs is the same builder with `--slot-out`.

Principle: packages are only downloaded, unpacked and configured, so the host `dpkg --root=ROOT --force-script-chrootless` does it; the maintainer scripts run on the host with `DPKG_ROOT=ROOT`. Only a target (arm64) binary that a script must run is emulated, alone, by `qemu-aarch64-static` inside a chroot of the tree (`unitotem/native/nb-shim`, `nb-finalize`): there is no nested exec, so such a program may not start another target program.

| Step | Was (qemu chroot) | Native replacement |
|---|---|---|
| Stage 0 `debootstrap --second-stage` | dpkg and scripts in qemu | `mmdebstrap --mode=chrootless --variant=important` (apt config `Dir ROOT`, `DPkg::Path` with the shim directory first); `ischroot` shim: the disposable container is the chroot mmdebstrap asks for |
| apt transactions of stage 1 (install, dist-upgrade, purge) | apt, dpkg, scripts in qemu | `unitotem/native/nb-install`: `apt-get -s` gives the order (Inst, Conf, Remv, Purg), apt downloads, the host dpkg replays unpack batches, configure batches, removals and pending triggers; `apt-mark auto/manual` writes what apt would |
| dpkg `--force-depends --purge`, `dpkg-query`, `dpkg-statoverride` | in the chroot | host tools with `--root` / `--admindir` (`rootfs_dpkg*` in `common.sh`) |
| scripts that are not DPKG_ROOT aware (they test and write absolute builder paths) | ran in the chroot | `unitotem/native/overrides/<package>.<script>` replaces the installed script after unpack, or `<package>.<script>.sed` patches it; a `%` in the name matches any text; checked against the reference rootfs |
| `ldconfig` (libc-bin trigger) | qemu | shim: target `ldconfig` alone under qemu (the host one ignores arm64 libraries) |
| `adduser`, `addgroup` | qemu | `nb-adduser` (groupadd/useradd `-P ROOT`, lowest free system id like adduser) |
| `py3compile`, `py3clean`, `python3.13 py_compile.py` | python under qemu | `nb-pycompile`: host Python 3.13 compiles the target files, `dfile` is the target path (byte code is architecture independent) |
| `linux-run-hooks`, `update-initramfs` in postinst | initramfs-tools in qemu | no-op shim and override; `nb_kernel_post` copies dtbs, overlays and `kernel8.img` to `/boot/firmware`; the slot initramfs is built in stage 2 |
| trigger caches: fontconfig, shared-mime-info, GSettings schemas, icon caches, CA certificates, udev hwdb, SysV `update-rc.d`, user units (`deb-systemd-helper --user`, guarded by DPKG_ROOT in the postinst), X11 font indexes | triggers in qemu | `nb-finalize`, once after the last transaction: host tools with a root argument (`fc-cache --sysroot`, `update-mime-database`, `glib-compile-schemas`, `gtk-update-icon-cache`, `update-ca-certificates --sysroot`, `systemd-hwdb --root`, `update-rc.d` with DPKG_ROOT), `unshare -m` with the target's data directories bound over the host's for the X11 font tools |
| GIO modules, GdkPixbuf loaders, GTK input method caches | qemu | target programs, one by one under qemu (they `dlopen` target modules): the documented exception |
| stage 2 `locale-gen` | qemu | host `localedef --prefix` on the target's locale sources |
| stage 2 `dpkg-reconfigure tzdata` | qemu | the two files it writes (`/etc/timezone`, `/etc/localtime`) |
| stage 2 `groupadd`, `passwd -d`, `usermod`, `addgroup` | qemu | host `groupadd -P`, `passwd -R`, `usermod -P` |
| stage 2 `pam-auth-update` | qemu | host script in `unshare -m` with the target's `/etc/pam.d`, `/usr/share/pam-configs`, `/var/lib/pam` bound over the host's |
| stage 2 `systemctl enable/mask` | qemu | `systemctl --root` (`SYSTEMCTL_SKIP_SYSV=1`: the SysV links are made by `nb-finalize`) |
| stage 2 `update-initramfs -u -k all` | mkinitramfs in qemu | `build-recovery-initrd.py --slot-out` (the native builder; the rootfs's own scripts and `initramfs.conf`), then `slim-initramfs.py` on the host |
| stage 3 | host tools | unchanged (no emulation: partitioning, mkfs, partclone, verify) |

Every qemu use left: `ldconfig` (stage 1 and `nb-finalize`), the GIO/GdkPixbuf/GTK cache programs. Diagnostics in the stage 1 log: `NB-SURVEY-FAILED` (only with `NB_SURVEY=1`, which continues after a failing script and writes the tarball anyway; lab use), `NB-HOST-TOUCHED` (builder-root files written by maintainer scripts: a script that is not DPKG_ROOT aware).

Measured on the development PC (20 cores, 2026-11-15, packages cached): stage 0 68 s, stage 1 3 min 20 s, stage 1b 24 s, stage 2 40 s, stage 3 2 min 30 s with the `.xz` (about 4 min 15 s from a cached stage 1 to the image; about 9 min from nothing) against about 65 min with qemu. `verify-image` 223 checks, 0 failed. The stage 1 package set equals the lock (`package lock verified: 801 pinned + 8 local packages, identical`).

Equivalence with the qemu-built stage 1 and stage 2 tarballs (`tools/nb-compare-rootfs.py`, 49556 entries): same paths, types, modes, owners and link targets except the following. Not reproduced: `/run/*` directories (runtime leftovers of the qemu chroot), `/var/log/*` and `/var/lib/dpkg/{available,cmethopt}`, `/etc/console-setup/cached_*` (written by `setupcon` on the first boot), `/var/lib/ucf/{cache,*.0}` and the ucf registry content, `/etc/ca-certificates.conf.dpkg-old`, two `!` lines of `ca-certificates.conf`, `initrd.img.old`. Different content: debconf databases and `extended_states` (the native run answers the configuration questions by overrides), dpkg status (`Status` order), `ld.so.cache` and `aux-cache` timestamps, fontconfig cache timestamps, `loaders.cache` (a few bytes), `hwdb.bin` (build timestamp), `argparse` and `functools` byte code (one marshal reference flag; the other 3165 `.pyc` files are identical), system user and group ids that depend on the order of creation (`polkitd`, `sshd`, `_ssh`, `netdev`), SSH host keys (generated in the builder, replaced on the first boot). The slot initramfs lacks `/etc/ld.so.cache` (the loader searches the default directories). The image carries an empty `/etc/machine-id`.

Limits of the method: `nb-install` replaces only the maintainer scripts installed by `--unpack`; a new package's `preinst` runs from the `.deb` unchanged. `DPkg::Pre-Install-Pkgs` is empty (no debconf preconfigure), so the configuration answers a package's `config` script would derive are set in its override. Every override is checked against the reference rootfs; a package update that changes a patched script stops the build (`did not change`).

Lab tools: `tools/nb-compare-rootfs.py REF.tar.gz NEW.tar.gz --out DIR` compares two rootfs tarballs (paths, type, mode, owner, link target, sha256).

### Native recovery initrd

`unitotem/build-recovery-initrd.sh` (wrapper: `python3 -I`) runs `unitotem/build-recovery-initrd.py`, which builds the resident fallback kernel and initrd from a stage 1 rootfs on any host with Python 3.11+. No chroot, Docker, binfmt or emulation. Logic is ported from Debian initramfs-tools 0.151 (mkinitramfs, hook-functions, stock hooks). Inspired by initramfs-tools (GPL-2+).

Input (`--arch arm64|amd64`, one of `--stage1 TARBALL` or `--rootfs DIR`): the rootfs is read only; a tarball is extracted under `--work`. Also `--engine` (`ota-engine.sh`, placed at `/usr/lib/unitotem/ota-engine.sh` of the initrd), `--list` (default `unitotem/files/ota-initrd.list`), `--out`, `--work`. A given `--work` is kept; otherwise a temporary folder in `--out` is removed.

Output in `--out`: `recovery-initrd-<arch>.img`, `recovery-vmlinuz-<arch>` (copy of `boot/vmlinuz-<kver>`), `recovery.manifest` (the keys of the Docker path). `UNITOTEM_RECOVERY_PARTCLONE_VERSION` comes from the rootfs dpkg database; `UNITOTEM_RECOVERY_BUILD_DATE` is the build time (UTC).

Host tools, all reading or writing foreign-arch files:

- `readelf` (binutils): NEEDED, RUNPATH, RPATH, interpreter. ELF headers only.
- `depmod -a -b DEST` (kmod): module index of the staging tree.
- `cpio` (newc, owner 0:0), `zstd` (level from the rootfs `conf.d/unitotem-compress`: 19).
- `fc-cache -s -y DEST` (fontconfig): caches of the plymouth fonts.
- `sh -n` (syntax check of initramfs scripts: parses only), `tar` (`--stage1`).
- Python: standard library. `.zst` modules need `compression.zstd` (Python 3.14); `.xz` and `.gz` use lzma and gzip.

No target binary and no target-derived shell text is executed. Initramfs scripts are checked with `sh -n` (parse only). The PREREQ order of each script is read statically from its `prereqs()` function (`_prereqs` in `assemble.py`): the variable echoed there, assigned as a literal.

Image structure (as mkinitramfs): an uncompressed cpio of the `*.xz` and `*.zst` files (kernel modules and firmware, already compressed), followed by a zstd cpio of all other files. The kernel reads both as one archive stream.

Library resolution (replaces `ldd`): NEEDED entries are followed recursively. Search order: DT_RUNPATH of the requesting object (else DT_RPATH; `$ORIGIN` is its directory), then `/lib/<triplet>`, `/usr/lib/<triplet>`, `/lib`, `/usr/lib`. `LD_LIBRARY_PATH` and `/etc/ld.so.conf` are not read. The interpreter (PT_INTERP) is copied. Symlink chains are copied as `copy_file` does. A NEEDED entry that is not found gives one warning and is skipped. `libpthread*` also copies `libgcc_s.so.1` (stock rule).

Module selection: `MODULES=most` is forced. The `auto_add_modules` table of hook-functions (base, net, ide, scsi, block, ata, dasd, firewire, mmc, usb_storage, fb) and the `module` directives follow dracut-install semantics: hard dependencies from `modules.dep`, softdeps (pre and post), `=dir` forms, `-s` symbol and `-P` path filters. Symbol filters read the module's undefined-symbol table with a Python ELF parser (no `nm`). Firmware named by the modinfo `firmware` values is searched in `/lib/firmware/updates/<kver>`, `/lib/firmware/updates`, `/lib/firmware/<kver>`, `/lib/firmware`, each as-is, then `.zst`, then `.xz`. Missing modules or firmware are skipped silently. Hidden dependencies (`hidden_dep_add_modules`) and builtin firmware (`modules.builtin.modinfo`) are added as mkinitramfs does.

Name list `unitotem/files/ota-initrd.list`: single source of truth for the names the fallback carries. Read by the native builder (`--list`) and by `ota-hook` at its installed path `/usr/share/unitotem-ota/ota-initrd.list`. `stage1-packages.sh` installs it there (image-owned, under `/usr/share`); `stage1-recovery-initrd.sh` refreshes it. One directive per line, fields separated by blanks, `#` starts a comment. An unknown directive stops both readers. The native builder also rejects malformed names and arguments (`lists.py`).

| Directive | Effect |
|---|---|
| `bin NAME...` | Command found with `command -v`, copied with its libraries; missing: warning |
| `real NAME...` | Real binary written over the BusyBox applet of that name (`mke2fs dd mount umount losetup mkfifo`) |
| `file SRC [DST]` | Plain file, absolute paths, `DST` defaults to `SRC` |
| `terminfo L/NAME...` | Entry copied to `/usr/share/terminfo/L/NAME` (source: `/usr/share/terminfo`, `/lib/terminfo`, `/usr/lib/terminfo`) |
| `module NAME...` | Kernel module forced into the initrd |
| `module-opt NAME...` | As `module`, only for names the kernel has |
| `x86-bin`, `x86-module`, `x86-dir` | Only when the target is not arm64 or `/usr/sbin/efibootmgr` exists |

Logic kept in code, not in the list: `/etc/group`, `/root/.ssh` (mode 700, no keys: generated at each fallback start), the `unitotem-ota-engine` symlink, the `nc` alternatives link, `reboot` (systemd binary, see [boot](boot.md#rules-and-gotchas)), `bash` (shell of the engine). The hook tests the x86 condition with `uname -m` of the build environment; the native builder uses `--arch`. Same result.

Known differences from the mkinitramfs output (Docker path):

- No `etc/ld.so.cache`: deliberate. `ldconfig -r` is not ported; every library is in `/lib/<triplet>` or `/lib`, which glibc searches by default.
- Fontconfig caches (4 files under `var/cache/fontconfig`): same names, written by the host `fc-cache`. Contents differ only in the directory mtimes, 6 bytes per cache at header offsets 48-63.
- `ota-engine.sh` differs in content: the native output carries the newer sources.
- Equal to the Docker output: file list (apart from the points above), symlinks, modes (setuid `mount` and `umount`), the five `scripts/*/ORDER` files, the module set (322) and the firmware set (164).
- Not run: `/etc/initramfs-tools/hooks/*` (the native `otahook.py` replaces `unitotem-ota`), `ldconfig`, `DSDT.aml` override (refused), `COMPRESS` other than zstd (refused).

## Interfaces

Commands:

- `./build-unitotem.sh`: all `ARCHES`.
- `ARCHES=arm64 ./build-unitotem.sh`: one arch.
- `FORCE_STAGE=2 ./build-unitotem.sh`: rebuild stage 2 and up.
- `PI_NATIVE_BUILD=0 ./build-unitotem.sh`: Docker path only.

Environment of `build-unitotem.sh`:

| Var | Default | Effect |
|---|---|---|
| `DOCKER` | `docker` | Docker command (e.g. `sudo docker`) |
| `ARCHES` | `amd64 arm64` | Architectures |
| `FORCE_STAGE` | empty | 0-3: rebuild from that stage |
| `PI_NATIVE_BUILD` | `1` | `0` disables the native arm64 path |
| `PI_HOST` | `user@host`, unset by default | Raspberry Pi for the native arm64 build; unset: Docker + qemu-aarch64 |
| `PI_BUILD_BASE` | path on the device | Build tree on the device |
| `PKGLOCK` | `on` | `off`: skip all lock logic |
| `PKGLOCK_KEEP` | `0` | `1`: keep the lock on security updates |
| `NATIVE_INITRD` | `0` | `1`: stage 1b (and `ONLY_RECOVERY`) uses the native builder, [Native recovery initrd](#native-recovery-initrd) |

Forwarded to the stages (Docker and native): `RELEASE`, `MIRROR`, `UNITOTEM_HOSTNAME`, `UNITOTEM_LOCALE`, `UNITOTEM_TIMEZONE`, `IMAGE_SIZE`, `AB_LAYOUT`, `ROOT_SLOT_SIZE`, `RELEASE_VERSION`, `IMG_DATE`, `EFI_SIZE`, `ROOT_SIZE`. `IMG_DATE` (default `date +%Y-%m-%d`) names the stage-3 image files. `BOOT_SIZE`, `FIRMWARE_SIZE` are read by the stages but not forwarded.

Defaults (`unitotem/common.sh`, env-overridable):

- `RELEASE` trixie; `MIRROR` https://deb.debian.org/debian.
- Root first-access state (stage 2, no variable): empty password field, login shell `/usr/sbin/unitotem-first-admin`, member of group `unitotem-first-admin`. See [image-runtime](image-runtime.md#root-and-first-access).
- `UNITOTEM_HOSTNAME` unitotem; `UNITOTEM_LOCALE` en_US.UTF-8; `UNITOTEM_TIMEZONE` UTC.
- `AB_LAYOUT` 1 (0 = single ROOT). `IMAGE_SIZE` 11G (legacy only; A/B takes the file size from the layout, and the ROOT_A shrink sets the final size). `ROOT_SLOT_SIZE` 5G; `ROOT_SIZE` 8G; `EFI_SIZE`, `FIRMWARE_SIZE` 512M; `BOOT_SIZE` 1G.
- `RELEASE_VERSION` default `date +%Y.%m.%d`; written to `/usr/share/unitotem/release-version`; must match `^[0-9]+(\.[0-9]+)+$`.
- `ROOTFS` /tmp/rootfs, `IMG_MNT` /mnt (both overridden on the native path).

Container mounts: `/dev`, `build` -> `/work`, `deploy` -> `/deploy`, `build/apt-cache` -> `/aptcache`, `unitotem/locks` -> `/unitotem/locks` (ro).

Outputs:

- `deploy/<arch>/unitotem-<date>-<arch>.img.xz` (build date, not `RELEASE_VERSION`): the image ([storage](storage-and-persistence.md#layout)).
- `build/<arch>/recovery/recovery-vmlinuz-<arch>`, `recovery-initrd-<arch>.img`, `recovery.manifest` (keys `UNITOTEM_RECOVERY_{ARCH,KERNEL_VERSION,VMLINUZ_SHA256,INITRD_SHA256,PARTCLONE_VERSION,BUILD_DATE}`). Deploys read the set from the parts set; these host files are the fallback only (`deploy-and-recovery.md`).
- `build/<arch>/`: `stage{0,1,2}.tar.gz`, `stage2.layout`, `<arch>.lock.new`, `recovery/` (the stage 1b kernel and initrd).
- `deploy/<arch>/`: what is ready to use, nothing intermediate: `unitotem-<date>-<arch>.img.xz`, preboot image, installer ISO and Windows installer; `deploy/script/`: the deploy tooling (`remote-deploy.sh`, `write-sd.sh`, `make-parts.sh`, ...).

Partition layouts:

| Layout | p1 | p2 | p3 | p4 | p5 |
|---|---|---|---|---|---|
| amd64 A/B | EFI (FAT32) | ROOT_A | ROOT_B | DATA | BIOS (ef02) |
| arm64 A/B | FIRMWARE (FAT32) | ROOT_A | ROOT_B | DATA | - |
| amd64 single | EFI | BOOT | ROOT | DATA | BIOS |
| arm64 single | FIRMWARE | ROOT | DATA | - | - |

The A/B table is the target layout. The image itself holds only p1, p2 and (amd64) p5: ROOT_B and DATA are created at deploy or first boot, and ROOT_A grows to the slot size there. The image is GPT on amd64 and DOS on arm64. Every Raspberry Pi table that the deploy writes is MBR, primaries only; the partition numbers are the same ([storage](storage-and-persistence.md#layout)).

Exit codes: `build-unitotem.sh` 1 if Docker is unavailable or any arch fails. Stage scripts `set -e`. `verify-image.sh` 1 on any FAIL. `pkglock.py check` (lock gate): 0 nothing newer and 10 updates without security fixes continue with the lock; 20 renews the lock; 2 warns and continues; any other code (crash, missing python3) stops that arch with exit 1.

## Rules and gotchas

- Stage 1 needs the full manager set in `build/extra-debs/<arch>/`: `unitotem`, `unitotem-manager`, `unitotem-node`, `unitotem-viewer`, `plymouth-theme-unitotem`, `python3-cefpython3` (for the arch), `python3-fastapi-login`, `python3-sdbus-networkmanager`.
- Native arm64: device root is read-only; the build remounts `/` and `/var/lib/dpkg` rw and restores ro in an EXIT trap. Stale chroot mounts under the build tree are unmounted first.
- Native arm64: `ROOTFS` and `IMG_MNT` live in the build tree (`/tmp` is nodev tmpfs, `/mnt` holds DATA). `qemu-aarch64-static` is copied by stage 0 unconditionally, so the package is required.
- Builder is bookworm, target is trixie. The deploy streams are written by the host's partclone and restored by the target's (trixie): measured compatible between 0.3.44 and 0.3.36 (`deploy-and-recovery.md`).
- Image content (enforced by `verify-image.sh`): no TLS key, no SSH host key, no DKMS signing key, no device identity. All are generated on the device.
- Secure Boot (amd64): the signed chain is the boot loader from the first boot (`EFI/BOOT`, stub `grub.cfg` also in `EFI/debian`). `--no-uefi-secure-boot --removable` keeps `grub-install` from placing a half chain; stage 3 then replaces the plain GRUB.
- arm64 A/B: dtbs and overlays are copied, not moved: the fallback (no `os_prefix`) reads `bcm2711-rpi-4-b.dtb` from the FAT top level.
- Recovery initrd needs `MODULES=most`: `dep` probes the root device, absent in a container.
- Console: arm64 `console=ttyS0,115200` needs `enable_uart=1`. ttyS0 follows the Raspberry Pi DTB alias `serial0=&uart1`.
- Stage 2 re-installs `ota-engine.sh` before `update-initramfs`.
- Change baseline (`/usr/lib/unitotem/baseline/`, written by stage 3): `packages`, `unowned.sha256`, `verify-expected` (`dpkg -V` deviations of a pristine image, scoped), `meta` (`format=1`, counts, `scan_dirs`). `verify-expected` is best effort: when the chroot cannot run (cross-arch) it is empty and nothing is subtracted. The baseline directory is excluded from the unowned scan on both sides, otherwise it would hash its own files.
- `release-version` is written before the baseline so the version is part of the pristine image; the baseline runs last, before `verify-image.sh` and the fsck pass.
- Stage 3 removes any same-day image before `truncate`.
- `AB_LAYOUT` changes invalidate stage 2 through `stage2.layout`, not timestamps.
- Container output is root-owned: remove it with `docker run --rm -v <parent>:/w <present image> rm -rf -- /w/<name>`, not sudo; creating it with `--user $(id -u):$(id -g)` avoids the problem.
- Editing a stage script or `Dockerfile.unitotem` while a build runs breaks that build; the newer mtime also makes the next run rebuild from stage 0.
- `purge_list` in stage 1 must end with `return 0` or `set -e` aborts the stage.
- Build priority (parent process, Docker and native): the build runs with nice -20 (needs root; otherwise a warning); the UniTotem units of `BUILD_PRIO_UNITS` (default `unitotem-manager unitotem-splash start-xorg`, loaded ones only) get `CPUWeight=1` at runtime. The EXIT trap restores the previous nice value and CPUWeight (`[not set]` is restored as a reset).
- Native arm64 ssh and rsync go through `deploy/script/lib.sh` (`OTA_AUTH` defaults to `key` here: BatchMode, publickey). The host key is checked as lib.sh's `SSH_OPTS` do: a reflashed Pi with a new host key fails the native path (warning, then Docker + qemu-aarch64) until its old entry is removed from `known_hosts`. A failed rsync fails the native path with a message.
- `docker-compose.yml` (apt-cacher-ng) is not used by the build; stage 1 uses the `/aptcache` mount.

## Image size

Installed size removed by the stage-1 reductions, from an `apt-get -s` replay of the stage-1 install order on Debian trixie (simulation). Measured on the built images (2026.11.51 -> 2026.11.52): The Raspberry Pi archive packages are not in the replay. "Deb" is the sum of the .deb sizes, an estimate of the compressed size.

| Step | amd64 installed MB (deb) | arm64 installed MB (deb) |
|---|---|---|
| GStreamer, `tigervnc-scraping-server`, `nvidia-vaapi-driver` removed; six Recommends-only packages pinned out (speech model, ghostscript and its fonts/data, iso-codes, translations) | 312.6 (90.9) | 306.1 (83.2) |
| `mesa-vulkan-drivers` purged | 79.2 (13.5) | 69.8 (10.8) |
| `libclang1-19` purged | 36.3 (7.3) | 35.3 (6.5) |
| amd64: NVIDIA CUDA, NVDEC and Vulkan libraries purged (Debian 550 stack; the NVIDIA repository set pulls none of them) | 139.2 (24.8) | - |
| arm64: `firmware-linux*`, `firmware-misc-nonfree` not installed | - | 102.7 (18.5) |
| Total | about 567 (137) | about 514 (119) |


| Measured | 2026.11.51 | 2026.11.52 |
|---|---|---|
| arm64 root asset (`root.ext4.pc.xz`) | 639 MB | 499 MB (-22 %) |
| amd64 root asset | 1059 MB | 913 MB (-14 %) |
| arm64 root used (Pi 4) | 2.5 GB | 1.9 GB |
| amd64 root used (PC) | 3.2 GB | 2.6 GB |
| amd64 `.img.xz` | 1152 MB | 1009 MB |

Kept because they are hard dependencies: `libavfilter10`/`libavcodec61` with `libflite1` and `libcodec2` (wayvnc -> libneatvnc -> ffmpeg), `libllvm19` + `libz3-4` (Mesa llvmpipe/radeonsi), `perl` (ddcutil -> i2c-tools), `firmware-nvidia-gsp`, `firmware-amd-graphics` (amd64).

## Tests

- `unitotem/verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]`: runs at the end of stage 3; `FAT_DIR` when the boot FAT is mounted separately. Section "Password policy": package installed, `cracklib-runtime` and `wamerican` absent, profile present, exactly one `pam_pwquality` line with the required options, `chpasswd` and `passwd` include `common-password`.
- `unitotem/verify-image.sh`, section "Backports stack" (both archs unless noted): the amd64 kernel package Version contains `bpo13`; `pipewire` and `wireplumber` Version contain `~bpo13`; `mesa-libgallium` Version starts with `26.`; `firmware-linux-nonfree` and `firmware-misc-nonfree` (when installed) start with `2026` (amd64); `nvidia-kernel-open-dkms` is `620.70.06-` (amd64); `nvidia.ko*`, `nvidia-drm.ko*`, `nvidia-modeset.ko*` exist in the single kernel directory (amd64); exactly one directory under `lib/modules`.
- `unitotem/verify-image.sh`, section "NVIDIA (amd64)": no Debian 550 NVIDIA package; `firmware-nvidia-gsp` at the `nvidia-kernel-open-dkms` version; `usr/lib/unitotem/nouveau-fallback` executable; `unitotem-nouveau-fallback.service` shipped and enabled by its `multi-user.target.wants` symlink; `nvidia-drm` in `modules-load.d/unitotem-nvidia.conf`; the `modprobe.d` options line; no NVIDIA apt source, keyring or pin file in the image. Section "Content removed": `gcc-14-for-host` and `cpp-14-for-host` absent.
- `unitotem/check-recovery-commands.sh ROOTFS INITRD ENGINE.sh`: lists the initrd with `initrd-scan.py`; run by `verify-image.sh`.
- `python3 tools/release/test_pkglock.py`: lock logic, offline.
- `tools/release/test_preboot_image.sh` (privileged container): `make-boot-tree.sh` (firmware and stage-2 inputs, manifest, engine appended or kept when identical in a zstd-plus-appended initrd, refusals), `make-preboot-image.sh --tree` and `--image` (byte-identical cards, refusals), `write-preboot.sh --tree`. Stage 3 seeding from the tree is not covered: it runs only in a build.
- No automated test boots an image or runs the stage scripts.
