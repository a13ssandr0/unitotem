# Image build pipeline

Paths: relative to the repository root.

Builds UniTotem disk images for amd64 and arm64: `deploy/<arch>/unitotem-<YYYY-MM-DD>-<arch>.img.xz`. Stages 0-3 run in the `unitotem-builder` Docker image, or natively on an arm64 device when one is reachable.

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
| `unitotem/stage3-image.sh` | Partition, format, populate, bootloader, boot assertions, baseline, verify, fsck, optional parts set, xz |
| `unitotem/verify-image.sh` | Static rule checks on the mounted image (PASS/FAIL) |
| `unitotem/check-recovery-commands.sh` | Every external command of `ota-engine.sh` exists in the recovery initrd |
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
  - Stage 0 and 1: run when the tarball is missing or stale.
  - Stage 1b (recovery initrd): runs when stage 1 ran or `recovery.manifest` is missing.
  - Stage 2: runs when stale or when `AB_LAYOUT` differs from `work/<arch>/stage2.layout`.
  - Stage 3: always runs.
- Staleness: a tarball is rebuilt when `unitotem/stage<N>*.sh`, `unitotem/common.sh`, `Dockerfile.unitotem` or the previous tarball is newer. Stages 1 and 2 also depend on `unitotem/files/*` and `deploy/ota-engine.sh`. `FORCE_STAGE=N` deletes tarballs N and up.

### Stages

- Stage 0: debootstrap (arm64: `--foreign`; second stage under qemu-aarch64 in Docker, native on the device).
- Stage 1:
  - The manager apt key (`/etc/apt/trusted.gpg.d/unitotem-manager.asc`) and source list (`sources.list.d/unitotem-manager.list`) are fetched from the project's GitHub Pages apt repository on every build.
  - Apt sources from `RELEASE` (trixie). arm64 adds the Raspberry Pi archive and keyring.
  - With a lock: snapshot.debian.org at the lock date, preferences pin every locked package, `dist-upgrade`.
  - amd64: linux-image-amd64, firmware, grub-efi-amd64, grub-pc-bin, efibootmgr, shim-signed, grub-efi-amd64-signed (staged only), mokutil, mesa, Intel/AMD/NVIDIA drivers (NVIDIA via DKMS).
  - arm64: linux-image-rpi-v8, raspi-firmware, firmware-brcm80211, v4l-utils, raspi-utils.
  - Both: base set (`unitotem/stage1-packages.sh`, installed with Recommends): `locales`, `sudo`, `openssh-server`, `htop`, `btop`, `nano`, `less`, network and Python packages. `htop` is in the base set; `btop` adds `btop` and `libncursesw6`, and `libgpm2` through its Recommends.
  - Both: plymouth (no text plugin), `labwc wlr-randr wlopm wayvnc xwayland qt6-wayland kbd`, pipewire, ddcutil. `xwayland` is present only because labwc starts it lazily and logs an error without it; no X client runs.
  - Both: `libpam-pwquality` with `--no-install-recommends` (Recommends would add `cracklib-runtime`, `wamerican`, `file`). Pulls `libpam-pwquality`, `libpwquality1`, `libpwquality-common`, `libcrack2`. See [image-runtime](image-runtime.md#password-policy).
  - Manager .debs from `work/extra-debs/<arch>/` installed over the apt set; every unitotem package must be 3.x.
  - Purge: arm64 Chromium (apt); compilers (`dpkg --force-depends`, keeps DKMS modules); amd64 X server packages.
  - Asserts labwc, wlr-randr, wlopm, wayvnc survive and the NVIDIA module exists (amd64). Removes `/var/lib/dkms/mok.key`.
  - Lock: verify (exact match) or freeze to `work/<arch>/<arch>.lock.new`.
- Stage 1b: copies kernel and initrd (`MODULES=most`, zstd), writes `recovery.manifest` with sha256 values.
- Stage 2:
  - Hostname, root first-access state (`passwd -d`, login shell, marker group), sshd_config, packages `sudo` and `adduser`.
  - Locale (`UNITOTEM_LOCALE`): `<locale> UTF-8` is uncommented in `/etc/locale.gen` and `locale-gen` runs (`C.UTF-8` is built into libc-bin, always available). `LANG=<locale>` is written to `/etc/default/locale` and `/etc/locale.conf`. `unitotem/files/unitotem-locale.sh` is installed as `/etc/profile.d/unitotem-locale.sh` (mode 644).
  - Timezone (`UNITOTEM_TIMEZONE`): `/etc/localtime` links to `/usr/share/zoneinfo/<timezone>`, `/etc/timezone` gets the same name, then `dpkg-reconfigure tzdata` canonicalises `UTC` to `Etc/UTC` (the link ends as `/usr/share/zoneinfo/Etc/UTC`, `/etc/timezone` as `Etc/UTC`).
  - Password policy: installs `unitotem/files/unitotem-pwquality` to `/usr/share/pam-configs/`, then `chroot pam-auth-update --package --force` with `DEBIAN_FRONTEND=noninteractive`. Prints "Incompatible PAM profiles selected" (its `Conflicts: pwquality` removes the stock profile); exit 0, one `pam_pwquality` line remains.
  - amd64: `/etc/default/grub`, `10_unitotem_ab` (A/B) or `45_unitotem_ota`.
  - arm64: `config.txt`, `cmdline.txt` (`root=LABEL=ROOT_A unitotem.slot=a`).
  - fstab (A/B drops the `/` and BOOT lines), NetworkManager, firewall, Chromium accel flags, apt timers masked.
  - Services enabled, `update-initramfs -u -k all`, arm64 slim initramfs, `kernel8.img`, `initramfs8`, `bcm27*.dtb` copied to FIRMWARE.
  - Removes the build-time TLS certificate (each device generates its own).
- Stage 3:
  - `truncate` to `IMAGE_SIZE`; partition (sgdisk amd64, parted arm64); `losetup --partscan`; `mkfs`; rsync rootfs into ROOT_A.
  - Recovery kernel and initrd copied to the boot FAT.
  - arm64 A/B: kernel, initramfs, cmdline move to `slota/`; `config.txt` gets `os_prefix=slota/`; dtbs and overlays copied into `slota/`.
  - amd64: `grub-install` for EFI and BIOS (`--removable --no-uefi-secure-boot`), Secure Boot chain staged in `EFI/unitotem-sb/`, `grub-mkconfig` (A/B: `grub.cfg` and `grubenv` in `unitotem-grub/` on the ESP).
  - Boot assertions (kernel magic, dtb parse, initramfs `/init`, `config.txt` references), release-version, change baseline, `verify-image.sh`, fsck of all partitions.
  - Optional parts set (`MAKE_PARTS=1`), `xz -T0`; the raw `.img` is removed.

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

Forwarded to the stages: `RELEASE`, `MIRROR`, `UNITOTEM_HOSTNAME`, `UNITOTEM_LOCALE`, `UNITOTEM_TIMEZONE`, `IMAGE_SIZE`, `AB_LAYOUT`, `ROOT_SLOT_SIZE`, `RELEASE_VERSION`. `MAKE_PARTS`, `EFI_SIZE`, `BOOT_SIZE`, `ROOT_SIZE`, `FIRMWARE_SIZE` are read by the stages but not forwarded.

Defaults (`unitotem/common.sh`, env-overridable):

- `RELEASE` trixie; `MIRROR` https://deb.debian.org/debian.
- Root first-access state (stage 2, no variable): empty password field, login shell `/usr/sbin/unitotem-first-admin`, member of group `unitotem-first-admin`. See [image-runtime](image-runtime.md#root-and-first-access).
- `UNITOTEM_HOSTNAME` unitotem; `UNITOTEM_LOCALE` en_US.UTF-8; `UNITOTEM_TIMEZONE` UTC.
- `AB_LAYOUT` 1 (0 = single ROOT). `IMAGE_SIZE` 16G (A/B) or 11G. `ROOT_SLOT_SIZE` 6G; `ROOT_SIZE` 8G; `EFI_SIZE`, `BOOT_SIZE`, `FIRMWARE_SIZE` 1G.
- `RELEASE_VERSION` default `date +%Y.%m.%d`; written to `/usr/share/unitotem/release-version`; must match `^[0-9]+(\.[0-9]+)+$`.
- `ROOTFS` /tmp/rootfs, `IMG_MNT` /mnt (both overridden on the native path).

Container mounts: `/dev`, `work` -> `/work`, `deploy` -> `/deploy`, `work/apt-cache` -> `/aptcache`, `unitotem/locks` -> `/unitotem/locks` (ro).

Outputs:

- `deploy/<arch>/unitotem-<date>-<arch>.img.xz` (build date, not `RELEASE_VERSION`).
- `deploy/<arch>/recovery-vmlinuz-<arch>`, `recovery-initrd-<arch>.img`, `recovery.manifest` (keys `UNITOTEM_RECOVERY_{ARCH,KERNEL_VERSION,VMLINUZ_SHA256,INITRD_SHA256,PARTCLONE_VERSION,BUILD_DATE}`).
- Optional `deploy/<arch>/unitotem-<date>-<arch>.parts`.
- `work/<arch>/`: `stage{0,1,2}.tar.gz`, `stage2.layout`, `<arch>.lock.new`.

Partition layouts:

| Layout | p1 | p2 | p3 | p4 | p5 |
|---|---|---|---|---|---|
| amd64 A/B | EFI (FAT32) | ROOT_A | ROOT_B | DATA | BIOS (ef02) |
| arm64 A/B | FIRMWARE (FAT32) | ROOT_A | ROOT_B | DATA | - |
| amd64 single | EFI | BOOT | ROOT | DATA | BIOS |
| arm64 single | FIRMWARE | ROOT | DATA | - | - |

Exit codes: `build-unitotem.sh` 1 if Docker is unavailable or any arch fails. Stage scripts `set -e`. `verify-image.sh` 1 on any FAIL. `pkglock.py check` 0/10/20/2.

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
- Builds are not prioritised against running services by the script; priority handling is an operator task.
- `docker-compose.yml` (apt-cacher-ng) is not used by the build; stage 1 uses the `/aptcache` mount.

## Tests

- `unitotem/verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]`: runs at the end of stage 3; `FAT_DIR` when the boot FAT is mounted separately. Section "Password policy": package installed, `cracklib-runtime` and `wamerican` absent, profile present, exactly one `pam_pwquality` line with the required options, `chpasswd` and `passwd` include `common-password`.
- `unitotem/check-recovery-commands.sh ROOTFS INITRD ENGINE.sh`: needs `lsinitramfs`; run by `verify-image.sh`.
- `python3 tools/release/test_pkglock.py`: lock logic, offline.
- No automated test boots an image or runs the stage scripts.
