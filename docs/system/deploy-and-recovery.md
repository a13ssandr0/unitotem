# Deploy, OTA fallback and recovery

Paths: relative to the repository root.

Host-side tooling that installs UniTotem on a target (Raspberry Pi arm64 or amd64 PC) over the network and recovers a target that no longer boots. The target runs a resident OTA fallback (dropbear in a recovery initramfs); the host drives every step. The fallback is the only tool that works when both slots are broken, on a first deploy, when adopting a foreign OS and for host-driven installs.

## Files

| Path | Role |
|---|---|
| `deploy/remote-deploy.sh` | Orchestrator: `probe`, `changes`, `deploy`, `recover`, `disarm`, `serve` |
| `deploy/ota-engine.sh` | Target engine, `/usr/sbin/unitotem-ota-engine`; one subcommand per step |
| `deploy/lib.sh` | SSH/SCP wrappers, sudo escalation, data channel, `backup_stream` |
| `deploy/make-parts.sh` | `.img.xz` -> parts set via container `unitotem-parts-builder` (`Dockerfile.parts`) |
| `deploy/make-parts-image.sh` | In the container: attaches the scratch image, calls `make_parts` |
| `deploy/parts-lib.sh` | `make_parts()`: manifest, table, streams, checksums |
| `deploy/make-preboot-image.sh` | Fallback-only SD image (default 128 MiB) |
| `unitotem/files/unitotem-ota-arm` | On-target arming of an installed UniTotem |
| `unitotem/files/unitotem-ota-changes` | On-target scan behind `changes` |
| `unitotem/files/ota-hook`, `ota-init-premount`, `ota-local-bottom-verify`, `ota-recovery-init-premount` | Initramfs integration |
| `unitotem/stage1-recovery-initrd.sh` | Builds `deploy/<arch>/recovery-*` |
| `unitotem/check-recovery-commands.sh` | Recovery initrd carries every engine command |

## How it works

- `probe`: one `ssh_t bash -s` round trip; prints `KEY: value` and `DISK:` lines. A 64-bit Pi model (3, 4, 5, Zero 2) gives arm64/`rpi`; else EFI gives amd64/`uefi`; else amd64/`bios`. Other Pi models are refused.
- Disk: `--disk` (kernel name or by-id path) or interactive. A disk without a stable by-id/by-path is refused.
- `deploy`, in order:
  1. `secure_boot_gate` (amd64 UEFI with Secure Boot active), `changes_gate` (installed UniTotem), confirmation `YES` unless `--yes` or `--accept-changes`.
  2. Backups before anything is armed (Backups).
  3. Arm. Installed UniTotem: `unitotem-ota-arm --port 2222 [--wipe-data]`, which reboots into the fallback. Other system: copy recovery kernel and initrd to the boot partition, one-shot boot (Pi: `config.txt`/`cmdline.txt` swap, originals kept as `*.unitotem-bak`; x86: GRUB entry `UniTotem OTA` + `grub-reboot`), reboot.
  4. `wait_ota_reachable`: polls `root@host:2222` up to 600 s; after 60 s without answer scans the local /24 for dropbear on 2222.
  5. `run_ota_sequence`.
  6. Polls `root@host` on the new system up to 600 s, then checks `/etc/unitotem/ota-preserve.list`.
- `recover HOST[:PORT]`: target already in the fallback. Engine `probe` picks the disk (holding DATA/ROOT/EFI labels, or the only disk). DATA is kept only if: no `--wipe-data`, DATA mounts, read-only `e2fsck -fn` passes, DATA partition number and start sector match the parts set, partition count matches. Otherwise the table is rewritten and DATA is lost (saved first if it mounts). The boot partition is reformatted if missing or failing `fsck.fat -n`. Secure Boot active forces `shim`. The `:PORT` part is ignored; the port is `OTA_PORT`.
- `disarm`: restores `config.txt`/`cmdline.txt` from `*.unitotem-bak` (Pi) or removes `/etc/grub.d/99_unitotem_flash` (x86); removes recovery files.
- `changes [--json]`: runs `unitotem-ota-changes check` on the target.
  - UI sequence: `changes --json`; if `verdict` is `clean`, deploy; else show packages and unexplained files, keep `digest`, and after confirmation run `deploy --accept-changes DIGEST`. A digest mismatch means the system changed: restart from `changes`.
  - The check runs over `ssh_t` with no timeout of its own and is I/O bound: the first run after a boot is much slower than later ones, so callers allow generous time.
  - Exit 127 comes from the SSH wrapper when the target lacks the tool (image predates it): `changes` dies, the deploy gate only warns and continues.
- `probe` prints `Secure Boot : enabled (deploy will ask how to proceed) | disabled | cannot be detected` and `Earlier UniTotem (single root): <version|none>`. The state is read from the `SecureBoot` EFI variable on a UEFI boot only, never guessed.

Stage 1 (fallback installed; a power loss boots the fallback):

- `restore-table` (skipped when DATA and table are kept); marks the point of no return.
- `prepare-bootfs --fresh 1` (`--volid` from the image); `write-bootfile` for recovery kernel and initrd.
- A/B: `populate-bootfs`, then `set-default-recovery --layout ab`. Otherwise `set-default-recovery`.

Stage 2 (system image):

- Non-A/B: `populate-bootfs`.
- Each block of `parts.manifest`: `restore`/`raw` -> `restore-part` (bulk over the data channel); `format` -> `format-part`; `data` -> `data-op` (`mkfs` if wiping or DATA absent, else `preserve`). `filecopy` partitions are covered by `populate-bootfs`.
- `mount-target`; arm64 non-A/B: `populate-real-kernel`; `migrate-etc-overlay` and `apply-network` (non-fatal).
- `set-trial-boot` (GRUB `UniTotem (trial)`, `tryboot.txt`, or config swap), `umount-target`, reboot (Pi tryboot: `reboot -f '0 tryboot'`).
- The fallback stays default until `unitotem-boot-ok` runs `promote-default` (single-root path).

Parts set (`deploy/<arch>/<name>.parts/`): `parts.manifest` (KEY=VALUE header, one block per partition), `layout.sfdisk`, `bootcode.bin` (440 bytes), `SHA256SUMS`, stream files (`*.xz`), `p1-FIRMWARE.bootfs.tar.*`.

- Layout 1: single ROOT. Layout 2: A/B. A/B is supported only on amd64 UEFI and on Pi with tryboot; legacy BIOS and Pi 3/Zero 2 are refused.
- Actions by label (`parts_action_for_label`): `EFI`/`FIRMWARE` filecopy (fat); `DATA` data (never streamed); `BOOT`/`ROOT`/`ROOT_A` restore (partclone extfs); `ROOT_B` format (shipped empty); `BIOS` raw (dd).

Preboot SD image: one FAT32 partition from 1 MiB (MBR type 0c) with Pi firmware, `recovery8.img`, `recovery-initrd.img`, `config.txt` (640x480), `cmdline.txt` with `unitotem.ota=recover`. Waits with no idle timeout; `recover` lays out the whole card.

## Interfaces

`deploy/remote-deploy.sh`:

| Command | Options |
|---|---|
| `probe user@host` | none |
| `changes user@host` | `--json` |
| `deploy user@host` | `--parts DIR`, `--disk NAME\|BYID`, `--port N` (data channel, default 9700), `--wipe-data`, `--backup-dir DIR`, `--no-backup`, `--fallback-only`, `--console STR`, `--yes`, `--accept-changes DIGEST`, `--secure-boot shim\|noshim\|abort` |
| `recover HOST[:PORT]` | `--parts DIR`, `--disk`, `--wipe-data`, `--backup-dir`, `--no-backup`, `--yes` |
| `disarm user@host` | none |
| `serve` | idle loop (`sleep 3600`) |

Environment: `OTA_PASSWORD` (login password of the adopted system, default `unitotem`), `OTA_FALLBACK_PASSWORD` (root password of the fallback and installed image, default `unitotem`; `ota_ssh` and `ota_ssh_send` log in as `root@host` with it), `ROOT_PASSWORD` (image build, default `unitotem`; the fallback initrd bakes its hash, so the three defaults stay in sync), `OTA_PORT` (fallback SSH port, 2222), `OTA_HOSTIP` (address the target uses to reach the host), `UNITOTEM_BACKUP_DIR` (default `backups/`), `UNITOTEM_OTA_DEBUG=1` (engine: emergency shell on failure).

Exit codes: `remote-deploy.sh` 0 success, 1 any error. `deploy` returns 0 with a warning if the new system is not reachable within 600 s; 1 if reachable but `ota-preserve.list` is missing. Engine: 0 / 1 via `fail()`; stdout carries only `UNITOTEM_*=value` lines, logs go to stderr and kmsg.

Engine subcommands (`--name value`; `--disk` on disk operations):

| Subcommand | Options | Stdout |
|---|---|---|
| `probe` | `--disk` | `UNITOTEM_ARCH_HOST`, `_EFI`, `_SECUREBOOT`, `_TRYBOOT`, `_DISK`, `_HAVE_ROOT`, `_HAVE_UNITOTEM`, `_HAVE_DATA`, `_DATA_PARTN`, `_DATA_START`, `_DATA_FSCK`, `_NPARTS`, `_HAVE_BOOTFS`, `_BOOTFS_FSCK` |
| `restore-table` | `--table-b64 --tail-part [--bootcode-b64]` | `UNITOTEM_TABLE_RESTORED` |
| `restore-part` | `--part --cloner --comp xz\|zstd --used-bytes --data-host --data-port [--fstype --grow]` | `UNITOTEM_PART_RESTORED` |
| `format-part` | `--part --label` | `UNITOTEM_PART_FORMATTED` |
| `data-op` | `--part --op preserve\|mkfs` | `UNITOTEM_DATA_OP_DONE` |
| `prepare-bootfs` | `--bootfs-part --fstype --fresh 1 --label [--volid]` | `UNITOTEM_BOOTFS_READY` |
| `write-bootfile` | `--bootfs-part --name [--subdir]`, stdin | `UNITOTEM_BOOTFILE_SHA256` |
| `populate-bootfs` | `--bootfs-part --data-host --data-port [--layout ab] [--secure-boot shim]` | `UNITOTEM_BOOTFS_POPULATED` |
| `set-default-recovery` | `--firmware rpi\|uefi\|bios --bootfs-part [--layout ab]` | `UNITOTEM_DEFAULT_RECOVERY` |
| `set-trial-boot` | `--firmware rpi-tryboot\|rpi-legacy\|uefi\|bios --target DIR [--disk --bootfs-part --layout ab]` | `UNITOTEM_TRIAL_ARMED` |
| `promote-default` | `--firmware [--disk --bootfs-part]` | `UNITOTEM_PROMOTED` |
| `mount-target` / `umount-target` | `--root-part --boot-part --bootfs-part --data-part --arch` | `UNITOTEM_MOUNTED` / `_UNMOUNTED` |
| `populate-real-kernel` | none | `UNITOTEM_KERNEL_POPULATED` |
| `migrate-etc-overlay` | `--root-mnt --data-mnt [--slot a\|b]` | `UNITOTEM_ETC_MIGRATED` |
| `apply-network` | `--data-mnt [--slot --link wired\|wifi --mode dhcp\|static --addr --gw --dns --ssid-b64 --psk-b64]` | `UNITOTEM_NET_APPLIED=1\|skip-existing\|not-needed` |
| `serve-fallback` | `[--reason --kind update\|recovery --idle-timeout S]` | blocks |

Boot signals: `unitotem.ota=1|recover`, `unitotem.slot=a|b`, `unitotem.ota.bootcount=1`; boot-FAT files `unitotem-ota.request`, `unitotem-ota.conf` (`OTA_HOST`, `OTA_CTRL_PORT`, `OTA_NET_LINK/MODE/IFACE/ADDR/GW`, `OTA_WIFI_SSID_B64`, `OTA_WIFI_PSK_B64`), `unitotem-ota.bootcount`, `unitotem-ota.failover`, `unitotem-grub/grub/grubenv`, `tryboot.txt`, `cmdline-trial.txt`. Semantics: `boot.md`.

## Backups

| Source | Archive | Content |
|---|---|---|
| Installed UniTotem | `unitotem-data-<host>-<ver>-<ts>.tar.zst` | `/mnt/data` |
| Single-root UniTotem 1.x/2.x | `unitotem-legacy-<host>-<ver>-<ts>.tar.zst` | `/etc/unitotem`, uploaded media, root crontab, `/etc/netplan`, hostname, hosts, TLS cert, `asound.conf`, kiosk `xinitrc` |
| `recover`, DATA about to be rewritten | `unitotem-data-<host>-recovery-<ts>.tar.zst` | DATA, read-only mount |

- Each archive has a `.sha256` sidecar and is read back before the deploy continues; `.tar.xz` when zstd is missing.
- Free space must exceed the used size. A failed backup stops the deploy with the target unchanged.
- `--no-backup` skips; `--fallback-only` never backs up.

## Rules and gotchas

- All SSH/SCP to targets goes through `deploy/lib.sh`: `ssh_t`, `scp_t`, `scp_root`, `ota_ssh`, `ota_ssh_send`, `_sshpass`. They set `SSH_ASKPASS_REQUIRE=never` and unset `DISPLAY`/`SSH_ASKPASS`; a raw `ssh`/`scp` makes OpenSSH try a graphical askpass when no password is ready, then fail with repeated `Permission denied` and no clear error. Check: `grep -n '\bssh \|\bscp \b' deploy/*.sh | grep -v '_sshpass\|ssh_t\|ota_ssh\|scp_t\|command -v\|ssh-keyscan'`.
- `ota_ssh` keeps `-n` (loops read `parts.manifest` on fd 9); `ota_ssh_send` keeps stdin.
- Fallback host key changes every boot: `StrictHostKeyChecking=accept-new`, `UserKnownHostsFile=/dev/null`.
- Non-root login escalates with `sudo -n` or a temporary askpass helper `/tmp/.unitotem-ota-askpass` (mode 700), removed by the EXIT trap. After the deploy, checks use `root@`.
- `unitotem-ota-arm` reboots the target: its ssh exit status is a race; the verdict is `wait_ota_reachable`.
- ServerAlive options are mandatory: the trial reboot kills the session.
- Point of no return is set by `restore-table`; a later failure enters serve-fallback instead of rebooting into a half-written disk.
- Never print logs to stdout in functions captured with `$(...)`.
- Data channel is plain unauthenticated TCP: host serves with `socat FILE:... TCP-LISTEN` (`serve_file_once`), target pulls via `/dev/tcp`. The listener must be bound (`wait_port_bound`) before the target pulls; never probe the port with a throwaway connection.
- `restore-part` uses `partclone -C` only if used bytes + 20% + 256 MiB fit the partition; `e2fsck -fy` after restore (not after `dd`).
- `populate-bootfs` never overwrites `config.txt`, `cmdline.txt`, recovery files, `unitotem-ota.*`, `*.unitotem-bak`, `tryboot.txt`. Only `set-default-recovery` and `promote-default` write `config.txt`. `--layout ab` anchors tar excludes.
- Pi: `enable_uart=1` in every fallback and trial config. Pi without tryboot (3, Zero 2): `rpi-legacy`, config swap guarded by the boot counter.
- Secure Boot (amd64 UEFI): `shim` requires layout 2; non-interactive runs without `--secure-boot` refuse; unknown state is treated as off with a warning; `noshim` needs a firmware change on site.
- Secure Boot `shim` may need physical intervention: with an NVIDIA GPU the MOK key is enrolled from the console; firmware that does not trust the Microsoft UEFI CA rejects shim; a non-Debian running system may stop at the GRUB prompt (`bad shim signature`) on the first one-shot step. A target already UniTotem with Secure Boot active keeps the shim chain automatically (A/B parts set only).
- Backups of an installed UniTotem exclude the target's `unitotem-native-build` scratch tree (deploy backup and `recover` DATA save).
- `--accept-changes DIGEST` implies `--yes` and must equal the current digest. `--yes` overwrites changes without showing them.
- `changes` exits 0 clean, 1 changes found; check failure and missing tool also exit 1 via `die`. A UI reads the `--json` `verdict`.
- `cmd_serve` starts no tunnel; `OTA_HOST` is unset in the deploy path.
- Layout 2 installs leave ROOT_B formatted and empty.
- Post-restore addressing uses `blkid -L` labels (`ROOT_A`, `ROOT_B`, `DATA`, `FIRMWARE`/`EFI`): two UniTotem disks in one machine make the lookup ambiguous; no duplicate-label check exists.
- `make-parts.sh`: arch from the `-amd64.img.xz`/`-arm64.img.xz` suffix or `--arch`; scratch `work/parts-scratch.<pid>` removed unless `--keep-scratch`.
- `make-preboot-image.sh`: default parts set is the newest `deploy/arm64/*.parts`; needs `recovery-*` and `p1-FIRMWARE.bootfs.tar.*`; output `deploy/arm64/unitotem-preboot-arm64.img` (+ `.xz`).
- The OTA environment accepts SSH with the default password while armed: trusted networks only.

## Tests

- `python3 tools/release/test_deploy_backup.py`: `backup_stream`, `backup_running_system`.
- `python3 tools/release/test_secure_boot_gate.py`: SecureBoot parsing, gate branches.
- `unitotem/check-recovery-commands.sh ROOTFS INITRD ENGINE.sh`.
- Loopback and QEMU harnesses: `testing.md`.
