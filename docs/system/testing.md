# Tests and harnesses

Paths: relative to the repository root.

Host unit tests, image rule checks and QEMU/loopback/hardware harnesses for update, deploy, image and boot code.

## Files

| Path | Role |
|---|---|
| `tools/release/test_auto.py` | `unitotem-update` automatic policy |
| `tools/release/test_boot_orientation.py` | `unitotem-boot-orientation`: Pi and GRUB backends |
| `tools/release/test_boot_recovery.py` | Boot recovery set sync (`sync_boot_recovery`, `unitotem-update`): [Recovery set refresh](ab-updates.md#recovery-set-refresh) |
| `tools/release/test_boot_guard.py` | `unitotem-update` boot health gate, boot counter, status fields, `slot_dev`: 42 checks |
| `tools/release/test_bootcount.sh` | Initramfs boot counter gate and fallback credentials without DATA (`ota-engine.sh`): 55 checks |
| `tools/release/test_first_boot_layout_dos.sh` | First-boot layout on DOS (MBR) disks (`layout_mbr`, power cuts, GPT unchanged), Docker `--privileged`: 46 checks |
| `tools/release/test_overlay_status.sh` | Overlay hook under dash, mocked tools: 38 checks |
| `tools/release/test_overlay_volatile.sh` | Volatile overlays without DATA (`volatile_overlays`), Docker `--privileged`: 47 checks |
| `tools/release/test_deploy_backup.py` | `backup_stream` (`deploy/lib.sh`), `backup_running_system` (`deploy/remote-deploy.sh`) |
| `tools/release/test_deploy_recovery_source.py` | `recovery_from_parts` (`deploy/remote-deploy.sh`): resident fallback source of a deploy, 29 checks |
| `tools/release/test_identity_merge.py` | `unitotem_identity.py` account merge |
| `tools/release/test_pkglock.py` | `tools/pkglock.py` freeze/verify/prefs/snapshot/classification, offline |
| `tools/release/test_repair.py` | Self-repair without block devices: boot-file clone, failover guard, repair decision |
| `tools/release/test_rpi_backend.py` | Raspberry backend end to end on a synthetic GPT image |
| `tools/release/test_secure_boot_gate.py` | `secure_boot_gate` and SecureBoot probe cut from `deploy/remote-deploy.sh` |
| `tools/release/test_wifi_roam.py` | `unitotem-wifi-roam` scan parsing and candidate choice |
| `tools/release/fake-github.py` | GitHub Releases stub over HTTP |
| `unitotem/verify-image.sh` | Rule checks on a mounted image; run by stage 3 |
| `work/loopback-test/run.sh`, `inside.sh` | Loopback deploy (fresh target, table recreate, DATA mkfs), amd64 |
| `work/loopback-test/run-ab.sh`, `inside-ab.sh` | Loopback A/B first deploy (layout 2, UEFI); leaves `scratch-ab/target.img` |
| `work/loopback-test/run-arm64.sh`, `inside-arm64.sh` | arm64 path (`populate-real-kernel`) |
| `work/loopback-test/run-bootcount.sh`, `inside-bootcount.sh` | Boot-counter fault injection |
| `work/loopback-test/run-real-sd.sh`, `inside-real-sd.sh` | Same sequence on a real SD card |
| `work/loopback-test/powercut-ab.sh` | QEMU power-cut scenarios and stress for A/B |
| `work/loopback-test/test-ota-lowres-amd64.sh` | QEMU screendump: OTA entries at low resolution |
| `work/loopback-test/test-frame.sh` | `ota_frame` layout on fake framebuffers, PNGs in `scratch-frame/` |
| `work/loopback-test/whiptail-geometry.py` | Reports whiptail gauge geometry in a pty |
| `tools/pi-sd-guard.sh` | SD write-rate guard for a real device |

## How it works

- Python tests load shipped scripts by path (`importlib`, `SourceFileLoader`); no install step.
- Shell functions are extracted from `deploy/*.sh` by regex/awk and run in a bash harness; renaming them breaks the tests on purpose.
- `test_rpi_backend.py`: synthetic GPT image (mtools FAT + mke2fs ext4, `sgdisk`, `dd`), `unitotem-release build-ab --arch arm64`, served by `fake-github.py`, updater driven with fake FAT dirs and a recorded reboot command.
- `inside*.sh`: root in a `--privileged` `debian:bookworm` container; a loop device (or real device) stands in for the disk. The `ota-engine.sh` subcommand order mirrors `run_ota_sequence`. Each step is a `check`; the run ends `ALL CHECKS PASSED` or `SOME CHECKS FAILED`.
- Fallback authentication (`fallback_auth_setup`, dropbear options): a scratch harness in a container, not in the repository. Covers the credential sources, key-line and name validation, and the `-F -E -p 2222 -r <host key> -T 3 -j -k` option set (`-B` in open mode). See [deploy-and-recovery](deploy-and-recovery.md#fallback-authentication).
- `powercut-ab.sh`: each scenario starts from a qcow2 overlay, sets `UPDATE_CRASHPOINT`, kills QEMU with SIGKILL on a marker, reboots the disk, checks that the system comes up and the update completes. Results in `work/powercut/`.
- `verify-image.sh`: runs every check, prints `PASS:`/`FAIL:`, exits 1 on any failure. Groups: English screen strings, packages removed/required, logo and frame blobs, Wayland session, Plymouth theme, Pi initramfs size and Wi-Fi module, device identity (no keys or passwords baked in), mount robustness, update machinery, A/B layout, Pi boot properties, amd64 GRUB entries.
- `pi-sd-guard.sh`: every 30 s reads `/sys/block/mmcblk0/stat` field 7 (x512 bytes) over SSH; a rate above the limit stops `pwr-writer` and every `*-testload.service`.

## Interfaces

Host tests: `python3 tools/release/test_<name>.py`; no arguments, no root, no device. Output `PASS: <check>` / `FAIL: <check> <detail>` and a summary. Exit 0 all pass, 1 any fail.

Image check: `unitotem/verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]`; boot FAT under `boot/efi` (amd64) or `boot/firmware` (arm64); `AB_LAYOUT` 1 for A/B (default 0); env `FAT_DIR`. Exit 0/1.

| Command | Input | Output |
|---|---|---|
| `run.sh PARTS_DIR` | `.parts` dir | `scratch/` |
| `run-ab.sh PARTS_DIR` | A/B `.parts`; env `ARCH` (amd64) | `scratch-ab/target.img` |
| `run-arm64.sh PARTS_DIR` | arm64 `.parts` | `scratch-arm64/` |
| `run-bootcount.sh` | none | `scratch-bootcount/results-bootcount.txt` |
| `run-real-sd.sh PARTS_DIR` | `.parts`; device set in the script | destroys the card content |
| `powercut-ab.sh prep BASE_RAW RELEASES_DIR` | base raw image | `base0.qcow2` |
| `powercut-ab.sh fetched` | after `prep` | `base1.qcow2` (completed fetch) |
| `powercut-ab.sh base2` | after `fetched` | `base2.qcow2` (for `par`) |
| `powercut-ab.sh run NAME... \| all` | scenarios | sequential |
| `powercut-ab.sh par N NAME... \| all` | parallel jobs | `work/powercut/job-*` |
| `powercut-ab.sh stress BASE CYCLES MIN MAX [CHECK_EVERY]` | base disk, counts, seconds | offline fs checks on copies |
| `test-ota-lowres-amd64.sh IMAGE.img.xz` | amd64 image | `work/lowres/` |
| `test-frame.sh` | none | `scratch-frame/*.png` |

Power-cut scenarios: `fetch_after_invalidate`, `fetch_mid_write`, `fetch_after_write`, `fetch_after_relabel`, `fetch_before_valid`, `fetch_after_valid`, `apply_start`, `apply_after_pending`, `apply_after_arm`, `boot_1`, `boot_3`, `boot_6`, `boot_10`, `boot_20`, `boot_40`, `bootok_health_wait`, `confirm_start`, `confirm_after_default`, `rollback_start`, `rollback_after_default`, `torn_grubenv`.

`tools/pi-sd-guard.sh SECONDS`: env `LIMIT_MIB_PER_MIN` (300), `PI_IP` (target address); heartbeat every 20 checks. Run detached next to any job that writes to the device: `(setsid nohup tools/pi-sd-guard.sh 21600 > /dev/null 2>&1 &)`. Stop events and heartbeats are logged as `SDGUARD` lines in `work/pi-test/STATE.md`.

## Rules and gotchas

- There is no single runner and no CI config; run each target by hand.
- `test_rpi_backend.py` does not prove firmware `os_prefix`/`tryboot.txt` behaviour (hardware only). `test_repair.py` does not prove the partclone copy.
- `powercut-ab.sh`: `kill -9` models loss of what the guest did not submit to the virtual disk; not a physical disk cache, write reordering or a cut inside one block write.
- `inside-real-sd.sh` takes and verifies a read-only backup of the card first and always takes the table-recreate path.
- Harness containers run `--privileged`; `run-real-sd.sh` scopes device-cgroup rules to one disk. `run-ab.sh` and `run-bootcount.sh` force `--platform linux/amd64`.
- Container-created scratch dirs are root-owned: remove with a disposable container.
- `verify-image.sh` runs in stage 3 before compression; a FAIL fails the build. The Pi console check expects `console=ttyS0`.
- Two-screen QEMU tests need `-device virtio-vga,max_outputs=2` (full command: [../manager/testing-vm.md](../manager/testing-vm.md)). The second connector (`Virtual-2`) starts disconnected; `echo on|off > /sys/kernel/debug/dri/0/Virtual-2/force` plugs and unplugs it. A proprietary NVIDIA driver removes DRM debugfs, so the trick is unavailable there.
- Hot-plug check: after login (`/auth/token`) the manager pushes `Viewers/list` over WebSocket `/ws`; the viewer plugin handles `screenAdded`/`screenRemoved`.
- `verify-image.sh` reads the mounted root only and checks labwc's `rc.xml` by grep for the `<labwc_config>` tags, not by parsing. Check on the board with `WAYLAND_DISPLAY=/run/unitotem/xdg/wayland-0 wlr-randr --json` and `wlopm`.
- `work/` is git-ignored except `work/loopback-test/*.sh`.
- Legacy BIOS test VM: `qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -smp 4 -m 4096` with no `-bios` (SeaBIOS), a 24 GiB sparse raw disk on virtio, user networking with `hostfwd` to guest ports 2222, 22, 443. A QEMU started with `-kernel/-initrd` boots that kernel again after every guest reboot: start the recovery VM with `-no-reboot` and boot the disk once the process exits. A power cut is `kill -9` of the QEMU process. Write the ESP of a stopped VM with `mcopy -i DISK@@1048576 ...` (mtools, first partition at sector 2048). First access state: `POST /setup` creates the administrator for `ssh` as that account. A newer release for the update tests is a copy of the image with `usr/share/unitotem/release-version` rewritten by `debugfs -w`, signed with the development key by `unitotem-release build-ab` and served by `tools/release/fake-github.py`; `UPDATE_BASE_URL` of the VM goes in `/etc/unitotem/update.conf`.
- Fallback authentication on hardware only: the initramfs libraries and the NSS and libcrypt lookups in the real initrd are confirmed on the first device test. Containers do not exercise them.
- Remote check of a device: `work/slot-tests/lib.sh` `VF` logs in as root with `~/.ssh/id_ed25519` (or `OTA_FALLBACK_KEY`, when that key is in DATA's root `authorized_keys`), or as `OTA_FALLBACK_USER` with `OTA_FALLBACK_PASSWORD` from the environment.
- `test-frame.sh` writes fixed paths under `scratch-frame/` and deletes nothing. `whiptail-geometry.py` reports, never asserts.

## Prerequisites

| Target | Needs |
|---|---|
| Python tests | python3 stdlib; `test_rpi_backend.py`: mtools, `mkfs.fat`, `mke2fs`, `sgdisk`, `dd`, `truncate`; deploy/secure-boot tests: bash, awk |
| Loopback, A/B, arm64, bootcount | docker, root-capable host, `debian:bookworm` |
| Volatile overlays, DOS layout | docker, `--privileged`, local `debian:trixie` image (`--pull never`) |
| Real SD card | docker, the card attached to the host |
| Power cut | qemu-system-x86_64 with KVM, qemu-img, OVMF, sgdisk, sshpass, `deploy/lib.sh` |
| Low-resolution OTA | qemu-system-x86_64, OVMF, mtools, sfdisk, xz |
| Frame layout | python3, PIL optional |

## Recovery set sync on the test Pi
`work/agents/agent-M/pi-recovery-sync-test.sh before|after|recovery-entry` (host side, `deploy/lib.sh` helpers only).
- `before`: read-only snapshot of the FIRMWARE FAT (sha of recovery files, `config.txt`, slot `cmdline.txt`, `start4.elf`, `fixup4.dat`, dtbs), level, `boot_recovery`, SD write counter.
- Ship a release whose root carries a newer recovery set (`unitotem-update fetch`, `apply --reboot`; about 3 GB of SD writes: ask first), then `NEW_VERSION=<v> ... after`: files equal the image manifest, level raised, `sha256sum -c recovery.sha256` passes, no `*.new`, firmware blobs and top-level `cmdline.txt` unchanged, `config.txt` equal except `os_prefix`.
- `recovery-entry`: `unitotem-ota.request` (no data wipe), reboot, dropbear on 2222 answers (key or administrator login), return to the normal slot.
- The SD counter includes the whole update; the sync's own writes are a few MB.

## Recovery set sync in a VM (UEFI and SeaBIOS)
Installed full image whose ESP holds an older recovery set (level 0), ROOT_A without `/usr/share/unitotem/recovery` (debugfs); a signed test release (`unitotem-release build-ab`) whose root carries the new updater and a newer set (level `20261108000000`, initrd with a marker file), served by `tools/release/fake-github.py` (`UPDATE_BASE_URL=http://10.0.2.2:PORT/<owner>/<repo>`). `fetch`, `apply --reboot`, confirmed boot: `boot_recovery` is `ok 0 -> level`, ESP `recovery-initrd.img` equals the new file, `sha256sum -c recovery.sha256` passes, no `*.new`, `grub.cfg` unchanged, a further boot is `noop` and writes nothing; `next_entry=ota-recovery` boots the new initrd (marker present, dropbear 2222). Measured: passes on both firmwares.

