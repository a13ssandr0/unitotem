# Image build pipeline

Paths: relative to the repository root.

Builds UniTotem disk images for amd64 and arm64: `deploy/<arch>/unitotem-<YYYY-MM-DD>-<arch>.img.xz` (full) and, for A/B, `unitotem-<YYYY-MM-DD>-<arch>-flash.img.xz` (boot partition(s) + ROOT_A, for Imager or `dd`). Stages 0-3 run in the `unitotem-builder` Docker image, or natively on an arm64 device when one is reachable.

## Files

| Path | Role |
|---|---|
| `build-unitotem.sh` | Entry point: builder image, binfmt, per-arch loop, package-lock gate, stage caching, native arm64 path, Docker path |
| `Dockerfile.unitotem` | Builder image (debian:bookworm): debootstrap, qemu-user-static, aria2, zstd, partclone, initramfs-tools-core, python3. Copies `unitotem/`, `deploy/ota-engine.sh`, `deploy/parts-lib.sh`, `tools/pkglock.py` to `/unitotem/` |
| `Dockerfile.parts` | Parts-set image (bookworm, partclone), used by `deploy/make-parts.sh` |
| `unitotem/common.sh` | Defaults, A/B sizes, chroot mount helpers, `apt_install` (aria2 prefetch, then apt) |
| `unitotem/stage0-bootstrap.sh` | debootstrap base to `work/<arch>/stage0.tar.gz` |
| `unitotem/stage1-packages.sh` | Apt sources, package lock, kernel, firmware, bootloader, GPU, Wayland, manager .debs, purge, lock verify/freeze -> `stage1.tar.gz` |
| `unitotem/stage1-recovery-initrd.sh` | Resident OTA fallback kernel+initrd and `recovery.manifest` |
| `unitotem/stage2-configure.sh` | Hostname, locale, timezone, root first-access state, boot config, fstab, NetworkManager, services, initramfs, arm64 FIRMWARE files -> `stage2.tar.gz` |
| `unitotem/stage3-image.sh` | Partition, format, populate, bootloader, boot assertions, baseline, verify, fsck, optional parts set, flash image, xz |
| `unitotem/make-flash-image.sh` | Flash image from the full image |
| `unitotem/verify-image.sh` | Static rule checks on the mounted image (PASS/FAIL) |
| `unitotem/check-recovery-commands.sh` | Every external command of `ota-engine.sh` exists in the recovery initrd |
| `unitotem/check-engine-copy.sh` | The `ota-engine.sh` inside an initramfs is the repository's (verify-image: recovery initrd and slot initramfs) |
| `unitotem/slim-initramfs.py` | arm64 initramfs reduction: no `hwdb.bin`, Raspberry Pi Wi-Fi firmware only |
| `unitotem/locks/<arch>.lock` | Pinned package set (see `package-lock.md`) |
| `unitotem/files/` | Payload copied into the image: units, scripts, configs, hooks, pre-rendered OTA frame and logo blobs |
| `tools/gen-frame.py`, `tools/gen-logo.py` | Generate the OTA frame and logo blobs in `unitotem/files/` |

## How it works

- `build-unitotem.sh` checks `docker info`, registers binfmt, builds `unitotem-builder`.
- Several arches: one child per arch (`BUILD_CHILD=1`, output prefixed `[arch]`), in parallel.
- Per arch: package-lock gate (`package-lock.md`), then native or Docker path.
- arm64 native path (why: `mkinitramfs` runs `ldd` of the target and apt postinst/trigger scripts run arm64 code, which qemu-aarch64 emulates slowly): used when `PI_NATIVE_BUILD=1` (default), `sshpass` exists and the device answers within 5 s. A native failure falls back to Docker + qemu-aarch64.
  - rsyncs `unitotem/`, `ota-engine.sh`, `parts-lib.sh`, `pkglock.py`, `work/extra-debs/` to the device, installs build deps, runs stage 0-3 in one SSH session, rsyncs `work/arm64` and `deploy/arm64` back, adopts the new lock. No stage caching.
- Docker path: one `docker run --rm --privileged` per stage.
  - arm64 on an amd64 build server (Docker + `qemu-aarch64` registered in `binfmt_misc`; check with `docker run --rm --platform linux/arm64 debian:trixie uname -m`): `FORCE_STAGE=1 ARCHES=arm64 ./build-unitotem.sh` with `PI_HOST` unset. Measured on a 144-core server building amd64 in parallel: stage 0 about 15 min, stage 1 about 50 min (package configuration under emulation), stages 2-3 about 15 min; about 65 min to the image, `verify-image` 190 checks, 0 failed. The resulting image booted on a Raspberry Pi 4 and passed the A/B update, so it is equivalent to a native build. The native path needs the test Pi for 1.5-2 h and blocks it; the server path does not.
  - Stage 0 and 1: run when the tarball is missing or stale.
  - Stage 1b (recovery initrd): runs when stage 1 ran or `recovery.manifest` is missing.
  - Stage 1b installs `deploy/ota-engine.sh` into its rootfs after extracting `stage1.tar.gz` (as stage 2 does for the slot initramfs): the tarball can hold an older engine. Rebuild after a change of the engine alone, without redoing stage 1 (about an hour per architecture): on the build server set the mtime of `deploy/ota-engine.sh` before the stage 1 tarball (`touch -d`), delete `deploy/<arch>/recovery.manifest`, run with `FORCE_STAGE=2`; stage 1 is skipped, 1b, 2 and 3 run (about 25 minutes). A later full rebuild reads the real file.
  - Stage 2: runs when stale or when `AB_LAYOUT` differs from `work/<arch>/stage2.layout`.
  - Stage 3: always runs.
- Staleness: a tarball is rebuilt when `unitotem/stage<N>*.sh`, `unitotem/common.sh`, `Dockerfile.unitotem` or the previous tarball is newer. Stages 1 and 2 also depend on `unitotem/files/*` and `deploy/ota-engine.sh`. `FORCE_STAGE=N` deletes tarballs N and up.

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
  - Manager .debs from `work/extra-debs/<arch>/` installed over the apt set; every unitotem package must be 3.x.
  - Purge: arm64 Chromium (apt); compilers (`dpkg --force-depends`, keeps DKMS modules: `build-essential gcc g++ cpp gcc-14 g++-14 cpp-14 gcc-14-for-host cpp-14-for-host` and the `x86-64-linux-gnu` cross variants; the 7.2 headers depend on `gcc-14-for-host`/`cpp-14-for-host`); `mesa-vulkan-drivers` (apt; the viewer renders through ANGLE-GL, llvmpipe/radeonsi stay in `mesa-libgallium` + `libllvm19`); `libclang1-19` (`dpkg --force-depends`: `libshiboken6` declares it, no shared object loads it); amd64 X server packages. No NVIDIA library is purged: the NVIDIA set is installed with `--no-install-recommends` and pulls no CUDA, NVDEC or Vulkan library.
  - Asserts labwc, wlr-randr, wlopm, wayvnc, mesa-libgallium, libllvm19, libneatvnc and libavcodec61 survive and the NVIDIA module `nvidia.ko*` exists in the single kernel directory (amd64, after each purge). Removes `/var/lib/dkms/mok.key`.
  - Lock: verify (exact match) or freeze to `work/<arch>/<arch>.lock.new`.
- Stage 1b: copies kernel and initrd (`MODULES=most`, zstd), writes `recovery.manifest` with sha256 values. `UNITOTEM_RECOVERY_BUILD_DATE` is the set's level (14 digits, `boot.md#recovery-set`).
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
- Stage 3:
  - `truncate` to `IMAGE_SIZE`; partition (sgdisk amd64, parted arm64); `losetup --partscan`; `mkfs`; rsync rootfs into ROOT_A.
  - Recovery kernel and initrd copied to the boot FAT under the names of `boot.md#recovery-set`, with `recovery.sha256` (level line, then sha256 per file). The level must be 14 digits or the build stops.
  - The same set goes to `usr/share/unitotem/recovery/` in the root (`vmlinuz`, `initrd.img`, `manifest`; arm64 also `dtb/*.dtb` copied from the top-level FIRMWARE dtbs). Written into the mounted root after the rootfs rsync and before the partitions are cut, so ROOT_A carries it.
  - arm64 A/B: kernel, initramfs, cmdline move to `slota/`; `config.txt` gets `os_prefix=slota/`; dtbs and overlays copied into `slota/`.
  - amd64: `grub-install` for EFI and BIOS (`--removable --no-uefi-secure-boot`), Secure Boot chain staged in `EFI/unitotem-sb/`, `grub-mkconfig` (A/B: `grub.cfg` and `grubenv` in `unitotem-grub/` on the ESP).
  - Boot assertions (kernel magic, dtb parse, initramfs `/init`, `config.txt` references), release-version, change baseline, `verify-image.sh`, fsck of all partitions.
  - Optional parts set (`MAKE_PARTS=1`).
  - A/B: `unitotem/make-flash-image.sh` writes the flash image from the full one (fresh GPT, partitions except ROOT_B and DATA copied unchanged, sgdisk/sha256/fsck verification), `xz -T0`; then `xz -T0` of the full image. The raw `.img` files are removed.

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

Forwarded to the stages (Docker and native): `RELEASE`, `MIRROR`, `UNITOTEM_HOSTNAME`, `UNITOTEM_LOCALE`, `UNITOTEM_TIMEZONE`, `IMAGE_SIZE`, `AB_LAYOUT`, `ROOT_SLOT_SIZE`, `RELEASE_VERSION`, `MAKE_PARTS`, `EFI_SIZE`, `ROOT_SIZE`. `BOOT_SIZE`, `FIRMWARE_SIZE` are read by the stages but not forwarded.

Defaults (`unitotem/common.sh`, env-overridable):

- `RELEASE` trixie; `MIRROR` https://deb.debian.org/debian.
- Root first-access state (stage 2, no variable): empty password field, login shell `/usr/sbin/unitotem-first-admin`, member of group `unitotem-first-admin`. See [image-runtime](image-runtime.md#root-and-first-access).
- `UNITOTEM_HOSTNAME` unitotem; `UNITOTEM_LOCALE` en_US.UTF-8; `UNITOTEM_TIMEZONE` UTC.
- `AB_LAYOUT` 1 (0 = single ROOT). `IMAGE_SIZE` 14G (A/B; DATA 3 GiB in the image, fits 16 GB cards) or 11G. `ROOT_SLOT_SIZE` 5G; `ROOT_SIZE` 8G; `EFI_SIZE`, `FIRMWARE_SIZE` 512M; `BOOT_SIZE` 1G.
- `RELEASE_VERSION` default `date +%Y.%m.%d`; written to `/usr/share/unitotem/release-version`; must match `^[0-9]+(\.[0-9]+)+$`.
- `ROOTFS` /tmp/rootfs, `IMG_MNT` /mnt (both overridden on the native path).

Container mounts: `/dev`, `work` -> `/work`, `deploy` -> `/deploy`, `work/apt-cache` -> `/aptcache`, `unitotem/locks` -> `/unitotem/locks` (ro).

Outputs:

- `deploy/<arch>/unitotem-<date>-<arch>.img.xz` (build date, not `RELEASE_VERSION`): full image.
- `deploy/<arch>/unitotem-<date>-<arch>-flash.img.xz` (A/B): flash image, `storage-and-persistence.md#layout`.
- `deploy/<arch>/recovery-vmlinuz-<arch>`, `recovery-initrd-<arch>.img`, `recovery.manifest` (keys `UNITOTEM_RECOVERY_{ARCH,KERNEL_VERSION,VMLINUZ_SHA256,INITRD_SHA256,PARTCLONE_VERSION,BUILD_DATE}`). Deploys read the set from the parts set; these host files are the fallback only (`deploy-and-recovery.md`).
- Optional `deploy/<arch>/unitotem-<date>-<arch>.parts`.
- `work/<arch>/`: `stage{0,1,2}.tar.gz`, `stage2.layout`, `<arch>.lock.new`.

Partition layouts:

| Layout | p1 | p2 | p3 | p4 | p5 |
|---|---|---|---|---|---|
| amd64 A/B | EFI (FAT32) | ROOT_A | ROOT_B | DATA | BIOS (ef02) |
| arm64 A/B | FIRMWARE (FAT32) | ROOT_A | ROOT_B | DATA | - |
| amd64 single | EFI | BOOT | ROOT | DATA | BIOS |
| arm64 single | FIRMWARE | ROOT | DATA | - | - |

Exit codes: `build-unitotem.sh` 1 if Docker is unavailable or any arch fails. Stage scripts `set -e`. `verify-image.sh` 1 on any FAIL. `pkglock.py check` (lock gate): 0 nothing newer and 10 updates without security fixes continue with the lock; 20 renews the lock; 2 warns and continues; any other code (crash, missing python3) stops that arch with exit 1.

## Rules and gotchas

- Stage 1 needs the full manager set in `work/extra-debs/<arch>/`: `unitotem`, `unitotem-manager`, `unitotem-node`, `unitotem-viewer`, `plymouth-theme-unitotem`, `python3-cefpython3` (for the arch), `python3-fastapi-login`, `python3-sdbus-networkmanager`.
- Native arm64: device root is read-only; the build remounts `/` and `/var/lib/dpkg` rw and restores ro in an EXIT trap. Stale chroot mounts under the build tree are unmounted first.
- Native arm64: `ROOTFS` and `IMG_MNT` live in the build tree (`/tmp` is nodev tmpfs, `/mnt` holds DATA). `qemu-aarch64-static` is copied by stage 0 unconditionally, so the package is required.
- Builder is bookworm, target is trixie. partclone in `Dockerfile.parts` must match the version `ota-engine.sh` restores with.
- Image content (enforced by `verify-image.sh`): no TLS key, no SSH host key, no DKMS signing key, no device identity. All are generated on the device.
- Secure Boot (amd64): chain staged in `EFI/unitotem-sb/`; `EFI/BOOT/BOOTX64.EFI` stays plain GRUB; activation happens at deploy. `--no-uefi-secure-boot --removable` is required, otherwise shim lands at `BOOTX64.EFI`.
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
- Native arm64 ssh and rsync go through `deploy/lib.sh` (`OTA_AUTH` defaults to `key` here: BatchMode, publickey). The host key is checked as lib.sh's `SSH_OPTS` do: a reflashed Pi with a new host key fails the native path (warning, then Docker + qemu-aarch64) until its old entry is removed from `known_hosts`. A failed rsync fails the native path with a message.
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
- `unitotem/check-recovery-commands.sh ROOTFS INITRD ENGINE.sh`: needs `lsinitramfs`; run by `verify-image.sh`.
- `python3 tools/release/test_pkglock.py`: lock logic, offline.
- No automated test boots an image or runs the stage scripts.
