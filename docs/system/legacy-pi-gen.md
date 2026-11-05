# Legacy pi-gen tree

Paths: relative to the repository root.

Root-level pi-gen build (Raspberry Pi OS bullseye, armhf, X11 session) of the 2022 UniTotem image. Not part of the current pipeline (`build-unitotem.sh`, `unitotem/`).

## Status

- No script of the current build references `build.sh`, `stage0-2/`, `export-image/`, `scripts/`, `config` or `depends`.
- `README.md` (Building section) still describes this tree.
- Last change 2022-10-31 (`d2e1bbe`).
- `config` is git-ignored (local file); `IMG_NAME=pigen-speedtest` in it overrides the default `UniTotem`.

## Files

| Path | Role |
|---|---|
| `build.sh` | pi-gen driver: stages, export-image, postrun. Root only |
| `build-docker.sh` | Runs `build.sh` in a privileged container, copies `deploy/` out |
| `Dockerfile` | Build container (`BASE_IMAGE`, default `debian:bullseye`) |
| `config` | Build config (`IMG_NAME`, `RELEASE`, `STAGE_LIST`) |
| `depends` | Host tools checked before build (`tool[:package]`) |
| `imagetool.sh` | Mount/umount/cleanup of qcow2 images via qemu-nbd |
| `scripts/` | `common` (debootstrap armhf, `on_chroot`), `dependencies_check`, `qcow2_handling`, `remove-comments.sed` |
| `stage0/` | Base system, apt sources, Raspberry Pi keyring, firmware, kernel |
| `stage1/` | Boot files, users, fstab, net tweaks |
| `stage2/` | Packages, ssh, NetworkManager, timezone, `04-unitotem` (X session, firewall, manager apt repo) |
| `export-image/` | Partitioning, rsync, cleanup, archive |
| `images/*.png` | README screenshots |

## How it works

- `build.sh` requires root and a path without spaces, sources `config` (and `-c <file>`), validates variables and tools, runs each dir of `STAGE_LIST` (default `stage0 stage1 stage2`).
- Per stage: `prerun.sh`, then sub-stages `00-..99-`. Per sub-stage files: `*-debconf`, `*-packages-nr` (no recommends), `*-packages`, `*-patches` (quilt), `*-run.sh` (host), `*-run-chroot.sh` (chroot).
- A stage with an `EXPORT_IMAGE` marker (stage2) triggers `export-image` after all stages.
- Output: `deploy/image_<DATE>-<IMG_NAME><IMG_SUFFIX>.<ext>` and a `.info` package list.
- Layout: msdos table, FAT32 boot 256 MiB, ext4 root = rootfs + 20% + 200 MiB.
- `USE_QCOW2=1`: per-stage qcow2 layers in `work/<IMG_NAME>/`; default plain directories.

## Interfaces

`build.sh [-c <config>]` (root). Exit 1 on: not root, path with spaces, missing tool, bad `FIRST_USER_NAME`, `DISABLE_FIRST_BOOT_USER_RENAME=1` with empty `FIRST_USER_PASS`, unreachable `APT_PROXY`, `WPA_PASSWORD` not 8-63 chars, `PUBKEY_ONLY_SSH=1` without `PUBKEY_SSH_FIRST_USER`.

| Variable | Default | Effect |
|---|---|---|
| `IMG_NAME` | `UniTotem` | Image and deploy name |
| `RELEASE` | `bullseye` | apt suite |
| `STAGE_LIST` | `stage*` | Stages to run |
| `FIRST_USER_NAME` / `FIRST_USER_PASS` | `pi` / `unitotem` | First user |
| `DISABLE_FIRST_BOOT_USER_RENAME` | `1` | `0`: rename-user on first boot |
| `TARGET_HOSTNAME` | `unitotem` | Hostname |
| `LOCALE_DEFAULT`, `TIMEZONE_DEFAULT` | `en_GB.UTF-8`, `Europe/London` | Locale, timezone |
| `KEYBOARD_KEYMAP` / `KEYBOARD_LAYOUT` | `gb` / `English (UK)` | Keyboard |
| `ENABLE_SSH`, `PUBKEY_ONLY_SSH`, `PUBKEY_SSH_FIRST_USER` | `1`, `0`, empty | SSH |
| `WPA_ESSID`, `WPA_PASSWORD`, `WPA_COUNTRY` | empty | Wi-Fi |
| `APT_PROXY` | empty | apt proxy URL |
| `USE_QEMU`, `USE_QCOW2` | `0` | qemu-user build, qcow2 layers |
| `BASE_QCOW2_SIZE` | `12G` | qcow2 size |
| `DEPLOY_COMPRESSION`, `COMPRESSION_LEVEL` | `zip`, `6` | Archive |
| `CLEAN` | unset | `1`: remove stage rootfs first |

- `build-docker.sh [-c <config>]`: env `CONTAINER_NAME` (`pigen_work`), `CONTINUE`, `PRESERVE_CONTAINER`, `PIGEN_DOCKER_OPTS`, `DOCKER`. Config must set `IMG_NAME`.
- `imagetool.sh` (root): `-m -i <qcow2> -p <dir>`, `-u -p <dir>`, `-c`. Env `NBD_DEV` (`/dev/nbd1`).

Image runtime:

- Units: `start-xorg.service` (user `unitotem`, tty8, `xinitrc`), `iptables-firewall.service`. Enabled: `ssh`, `start-xorg`, `iptables-firewall`, `resize2fs_once`, `regenerate_ssh_host_keys`.
- Firewall: input DROP; accepts lo, ESTABLISHED/RELATED, ICMP, tcp 22/80/443, udp 5353.
- Kiosk: `chromium-browser --kiosk` on the manager boot screen, remote debugging port 9222.
- Manager: package `unitotem-manager` from the public apt repository.

## Rules and gotchas

- Root login is locked at the end of stage 2 (`usermod --pass='*' root`).
- Non-armhf hosts need `qemu-arm-static`.
- `ld.so.preload` is moved aside during the build and restored in `export-image/05-finalise`.
- Quilt patches: `stage1/01-sys-tweaks/01-patches`, `stage2/01-sys-tweaks/00-patches`; edit via `series`.
- `build.sh` runs `git rev-parse HEAD`: build inside a git checkout.
- Defaults ship a known first-user password (`unitotem`).
- The Raspberry Pi mirror in `stage0/prerun.sh` is plain http.
- Interrupted builds can leave mounts.

## Tests

- `bash -n build.sh build-docker.sh imagetool.sh`.
- Functional check: full `sudo ./build.sh` and boot on hardware. No automated test.
