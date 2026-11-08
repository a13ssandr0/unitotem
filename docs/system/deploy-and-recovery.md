# Deploy, OTA fallback and recovery

Paths: relative to the repository root.

Host-side tooling that installs UniTotem on a target (Raspberry Pi arm64 or amd64 PC) over the network and recovers a target that no longer boots. The target runs a resident OTA fallback (dropbear in a recovery initramfs); the host drives every step. The fallback is the only tool that works when both slots are broken, on a first deploy, when adopting a foreign OS and for host-driven installs.

## Files

| Path | Role |
|---|---|
| `deploy/remote-deploy.sh` | Orchestrator: `probe`, `changes`, `deploy`, `recover`, `disarm` |
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
  3. Arm. Installed UniTotem: `unitotem-ota-arm --port 2222 [--wipe-data] --authkey-file FILE` (`-` = stdin; the public key goes to `unitotem-ota.authorized_keys` on the boot partition), which reboots into the fallback. Other system: copy recovery kernel and initrd to the boot partition, one-shot boot with `unitotem.ota.authkey=<base64 of the key line>` on the kernel command line (Pi: `config.txt`/`cmdline.txt` swap, originals kept as `*.unitotem-bak`; x86: GRUB entry `UniTotem OTA` + `grub-reboot`), reboot. The per-target key is created here (see [Fallback authentication](#fallback-authentication)).
  4. `wait_ota_reachable`: polls `OTA_FALLBACK_USER@host:2222` (default `root`) up to 600 s; after 60 s without answer scans the local /24 for dropbear on 2222.
  5. `run_ota_sequence`.
  6. Polls `https://<ip>/login` on the new system up to 600 s, credential-free (see Rules).
- `recover HOST[:PORT]`: target already in the fallback. Engine `probe` picks the disk (holding DATA/ROOT/EFI labels, or the only disk). DATA is kept only if: no `--wipe-data`, DATA mounts, read-only `e2fsck -fn` passes, DATA partition number and start sector match the parts set, partition count matches. Otherwise the table is rewritten and DATA is lost (saved first if it mounts). The boot partition is reformatted if missing or failing `fsck.fat -n`. Secure Boot active forces `shim`. `HOST:PORT` (fullmatch, port 1-65535) sets the fallback SSH port; without `:PORT` it is `OTA_PORT`. Login: see [Fallback authentication](#fallback-authentication).
- `disarm`: restores `config.txt`/`cmdline.txt` from `*.unitotem-bak` (Pi) or removes `/etc/grub.d/99_unitotem_flash` (x86); removes recovery files.
- `changes [--json]`: runs `unitotem-ota-changes check` on the target.
  - UI sequence: `changes --json`; if `verdict` is `clean`, deploy; else show packages and unexplained files, keep `digest`, and after confirmation run `deploy --accept-changes DIGEST`. A digest mismatch means the system changed: restart from `changes`.
  - The check runs over `ssh_t` with no timeout of its own and is I/O bound: the first run after a boot is much slower than later ones, so callers allow generous time.
  - Exit 127 comes from the SSH wrapper when the target lacks the tool (image predates it): `changes` exits 3, the deploy gate only warns and continues.
- `probe` prints `Secure Boot : enabled (deploy will ask how to proceed) | disabled | cannot be detected` and `Earlier UniTotem (single root): <version|none>`. The state is read from the `SecureBoot` EFI variable on a UEFI boot only, never guessed.

Stage 1 (fallback installed; a power loss boots the fallback):

- `restore-table` (skipped when DATA and table are kept); marks the point of no return.
- `prepare-bootfs --fresh 1` (`--volid` from the image); `write-bootfile` for recovery kernel, initrd and `recovery.sha256` (source: the parts set, see Rules).
- `populate-bootfs --layout ab`, then `set-default-recovery --layout ab`.

Stage 2 (system image):

- Each block of `parts.manifest`: `restore`/`raw` -> `restore-part` (bulk over the data channel); `format` -> `format-part`; `data` -> `data-op` (`mkfs` if wiping or DATA absent, else `preserve`). `filecopy` partitions are covered by `populate-bootfs`.
- `mount-target`; `migrate-etc-overlay` and `apply-network` (non-fatal).
- `set-trial-boot --layout ab` (GRUB one-shot `slot-a`, or `tryboot.txt` on Pi), `umount-target`, reboot (Pi tryboot: `reboot -f '0 tryboot'`).
- The fallback stays default until the trial slot is confirmed by `unitotem-update --json boot-ok` (`saved_entry` / `config.txt` flip then).

The network deploy takes its layout from the FULL image (parts set, release assets); the flash image (`-flash.img.xz`) is for writing to a card or disk directly and is never an input of `make-parts.sh`. Full image, flash image, parts set: `storage-and-persistence.md#layout`.

Parts set (`deploy/<arch>/<name>.parts/`): `parts.manifest` (KEY=VALUE header, one block per partition), `layout.sfdisk`, `bootcode.bin` (440 bytes), `SHA256SUMS`, stream files (`*.xz`), `p1-FIRMWARE.bootfs.tar.*`.

- Layout 2 (A/B) is the only layout: a parts set without `UNITOTEM_LAYOUT=2` is refused. Supported targets: amd64 (UEFI and legacy BIOS) and Pi with tryboot; Pi 3/Zero 2 are refused. On legacy BIOS the MBR boot code (`bootcode.bin`, written by `restore-table`) and the `BIOS` partition (ef02, raw stream with GRUB's core.img) are restored from the parts set; GRUB then reads `unitotem-grub/` on the EFI partition exactly as under UEFI.
- `parts-lib.sh` recognises the BIOS partition by its GPT type GUID (21686148-6449-6E6F-744E-656564454649); without that stream a BIOS target would not boot. Actions by label (`parts_action_for_label`): `EFI`/`FIRMWARE` filecopy (fat); `DATA` data (never streamed); `BOOT`/`ROOT`/`ROOT_A` restore (partclone extfs); `ROOT_B` format (shipped empty); `BIOS` raw (the stream is the raw partition content, `xz` of `dd`; `partclone.dd` has no clone mode; restored with `dd of=PART conv=fsync`).

Preboot SD image: one FAT32 partition from 1 MiB (MBR type 0c) with Pi firmware, `recovery8.img`, `recovery-initrd.img`, `config.txt` (640x480), `cmdline.txt` with `unitotem.ota=recover`. Waits with no idle timeout; `recover` lays out the whole card.

## Interfaces

`deploy/remote-deploy.sh`:

| Command | Options |
|---|---|
| `probe user@host` | none |
| `changes user@host` | `--json` |
| `deploy user@host` | `--parts DIR`, `--disk NAME\|BYID`, `--port N` (data channel, default 9700), `--wipe-data`, `--backup-dir DIR`, `--no-backup`, `--fallback-only`, `--console STR`, `--yes`, `--accept-changes DIGEST`, `--secure-boot shim\|noshim\|abort`, `--fallback-user NAME` |
| `recover HOST[:PORT]` | `--disk`, `--wipe-data`, `--backup-dir`, `--no-backup`, `--yes`, `--fallback-user NAME` (`--parts` is not read by `recover`) |
| `disarm user@host` | none |

Environment: `OTA_PASSWORD` (login password of an adopted foreign system, default `unitotem`), `OTA_FALLBACK_KEY` (private key of the fallback login; default: the per-target key of the host), `OTA_FALLBACK_USER` (fallback login user, default `root`; `--fallback-user NAME`), `OTA_FALLBACK_PASSWORD` (password of that user; environment only, never on a command line; no default), `OTA_FALLBACK_OPEN=1` (open mode: empty password, see [Fallback authentication](#fallback-authentication)), `OTA_AUTH` (`password` by default; `key`: `BatchMode=yes`, `PreferredAuthentications=publickey`, no sshpass, for hosts with the dev PC's key installed: test devices and the native arm64 build host `PI_HOST`), `OTA_PORT` (fallback SSH port, 2222), `OTA_HOSTIP` (address the target uses to reach the host), `UNITOTEM_BACKUP_DIR` (default `backups/`), `UNITOTEM_OTA_DEBUG=1` (engine: emergency shell on failure).

Exit codes: `remote-deploy.sh` 0 success, 1 any error. `changes`: 0 no changes, 1 changes found, 2 check failed on the target (or unreachable), 3 target has no `unitotem-ota-changes`. `deploy` returns 0 with a warning if the new system is not reachable within 600 s. Engine: 0 / 1 via `fail()`; stdout carries only `UNITOTEM_*=value` lines, logs go to stderr and kmsg.

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

Boot signals: `unitotem.ota=1|recover`, `unitotem.slot=a|b`, `unitotem.ota.authkey=<base64 of one ssh-ed25519 line>` (fallback login key); boot-FAT files `unitotem-ota.request`, `unitotem-ota.authorized_keys` (fallback login key, kept by `populate-bootfs`), `unitotem-ota.conf` (`OTA_NET_LINK/MODE/IFACE/ADDR/GW`, `OTA_WIFI_SSID_B64`, `OTA_WIFI_PSK_B64`), `unitotem-ota.failover`, `unitotem-grub/grub/grubenv`, `tryboot.txt`, `cmdline-trial.txt`. Semantics: `boot.md`.

## Fallback authentication

The fallback dropbear (port 2222) has no fixed password. `fallback_auth_setup` (`deploy/ota-engine.sh`) writes `/etc/passwd`, `/etc/shadow` and `/root/.ssh/authorized_keys` into the initramfs tmpfs before dropbear starts. Sources, in order:

1. Armed public key:
   - kernel command line token `unitotem.ota.authkey=<base64 of one ssh-ed25519 line>` (foreign OS, `arm_rpi`/`arm_grub`);
   - file `unitotem-ota.authorized_keys` on the boot FAT (FIRMWARE or EFI), written by `unitotem-ota-arm --authkey-file FILE` (installed UniTotem). The engine mounts the boot FAT read-only itself when `/boot-ota` is not mounted.
2. DATA, mounted read-only on demand and unmounted after reading:
   - `upper/root.<slot>/.ssh/authorized_keys` (one slot: `unitotem.slot=` on the command line, else `saved_entry=slot-x` of the boot FAT `unitotem-grub/grub/grubenv` (GRUB entry `ota-recovery` carries no slot), else slot a; the other slot's accounts are never read);
   - for every member of group `sudo` in `upper/etc.<slot>/group`: the shadow hash (`upper/etc.<slot>/shadow`) and `unitotem/persist/home/<user>/.ssh/authorized_keys`.
3. Open mode, only when no key and no administrator was found at all: root with an empty password and dropbear `-B`. Logged. A configured device never falls back to open. A device whose administrator password is forgotten stays closed unless a key is armed or present in DATA. DATA that is absent or cannot be mounted counts as nothing found, so a device with a damaged DATA stays recoverable remotely; the price is that an intact device whose DATA fails to mount at that moment is open until the next boot.

Each administrator becomes a uid 0 account `<user>` (shell `/bin/sh`, home `/root`) in the initramfs. `ssh <admin>@<host> -p 2222` gives a root shell with that administrator's password or key. Root itself accepts keys only; open mode is the only case with an empty root password. Names fullmatch `[a-z_][a-z0-9_-]{0,31}`; hashes `!`, `*` or empty give no password. Key lines accept only `ssh-ed25519`, `ssh-rsa` and `ecdsa` types without options (the cmdline token: ed25519 only); max 64 keys, 2048 characters per line.

dropbear: `-F -E -p 2222 -r <host key> -T 3 -j -k` (3 auth tries, no local or remote forwarding); `-B` only in open mode.

Tool side (`deploy/lib.sh`, `ota_auth_for`):
- Selection order: `OTA_FALLBACK_KEY`, the per-target key, `OTA_FALLBACK_OPEN=1`, `OTA_FALLBACK_PASSWORD`. None set: error naming the variables.
- Per-target key: `${XDG_STATE_HOME:-$HOME/.local/state}/unitotem-deploy/<host>/id_ed25519` (directory 0700, key 0600). Created at arming; `recover` reuses it for that host from the same PC.
- Key auth: `BatchMode=yes`, `PreferredAuthentications=publickey`, `IdentitiesOnly=yes`. Password: `sshpass -e` (environment only).
- A recovery from another PC needs `OTA_FALLBACK_KEY`, an administrator account (`--fallback-user NAME` with `OTA_FALLBACK_PASSWORD`), or a key already in DATA.
- Every operation works remotely. No physical access is assumed.

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
- Limitation, host key not pinned: the fallback key is generated in the initramfs at each boot (`dropbearkey` in serve-fallback) and the tool keeps no copy, so nothing verifies it. Pinning needs the host to create the key at arming and deliver the private part the way the authorized key is delivered (boot FAT or cmdline), a change across `unitotem-ota-arm`, `remote-deploy.sh` and the initramfs. Effect: a man-in-the-middle on the LAN during the fallback session cannot log in with the key, but receives the password in password mode (`OTA_FALLBACK_PASSWORD`).
- The idle watchdog of serve-fallback stands down only when dropbear logs a successful login (`auth succeeded` in `/run/ota-dropbear.log`). A bare TCP connection does not stop it.
- Non-root login escalates with `sudo -n` or an askpass helper `/tmp/.unitotem-ota-askpass` (mode 700), removed by the EXIT trap.
- Post-deploy check is credential-free: the new system's `https://<ip>/login` must answer 200, or 302/303 to `/setup` (first access open). Plain HTTP redirects to HTTPS. Budget 600 s. No SSH login is used; see [image-runtime](image-runtime.md#root-and-first-access).
- `unitotem-ota-arm` reboots the target: its ssh exit status is a race; the verdict is `wait_ota_reachable`.
- ServerAlive options are mandatory: the trial reboot kills the session.
- Point of no return is set by `restore-table`; a later failure enters serve-fallback instead of rebooting into a half-written disk.
- Never print logs to stdout in functions captured with `$(...)`.
- Data channel is plain unauthenticated TCP: host serves with `socat FILE:... TCP-LISTEN` (`serve_file_once`), target pulls via `/dev/tcp`. The listener must be bound (`wait_port_bound`) before the target pulls; never probe the port with a throwaway connection.
- `restore-part` uses `partclone -C` only if used bytes + 20% + 256 MiB fit the partition; `e2fsck -fy` after restore (not after `dd`).
- `populate-bootfs` never overwrites `config.txt`, `cmdline.txt`, recovery files, `unitotem-ota.*`, `*.unitotem-bak`, `tryboot.txt`. Only `set-default-recovery` and `promote-default` write `config.txt`. `--layout ab` anchors tar excludes.
- Pi: `enable_uart=1` in every fallback and trial config. Pi without tryboot (3, Zero 2) is refused.
- Secure Boot (amd64 UEFI): non-interactive runs without `--secure-boot` refuse; unknown state is treated as off with a warning; `noshim` needs a firmware change on site.
- Secure Boot `shim` may need physical intervention: with an NVIDIA GPU the MOK key is enrolled from the console; firmware that does not trust the Microsoft UEFI CA rejects shim; a non-Debian running system may stop at the GRUB prompt (`bad shim signature`) on the first one-shot step. A target already UniTotem with Secure Boot active keeps the shim chain automatically (A/B parts set only).
- Backups of an installed UniTotem exclude the target's `unitotem-native-build` scratch tree (deploy backup and `recover` DATA save).
- `--accept-changes DIGEST` implies `--yes` and must equal the current digest. `--yes` overwrites changes without showing them.
- `changes` exits 0 clean, 1 changes found, 2 check failed, 3 tool missing (see Interfaces). A UI reads the `--json` `verdict` and must check the exit code before it.
- The fallback has no reverse tunnel: the host always connects to the target on `OTA_PORT`.
- Layout 2 installs leave ROOT_B formatted and empty.
- Legacy BIOS (amd64): `restore-table` writes `bootcode.bin` into the MBR area, the `BIOS` partition (ef02) is restored raw. Proven in a SeaBIOS q35 VM: empty disk -> `recover` -> reboot -> slot A trial -> automatic confirm; fetch + apply of a newer release; trial rollback to the other slot; power cuts after arming, in the trial boot and during the write of the other slot; `repair`; `ota-recovery` entry with key, administrator password and open mode.
- `make-parts.sh` input is the FULL image (`unitotem-*-<arch>.img.xz`: EFI, ROOT_A, ROOT_B, DATA, BIOS), never the flash image (its table lacks ROOT_B and DATA). `--out DIR` is honoured (the container writes below `/out`). Generation takes about 20 min on 20 cores, mostly the single-threaded `xz -d` of a 14 GiB sparse image (about 20 MB/s) and the xz compression of ROOT_A. The BIOS stream is the raw partition (1 MiB) as `xz` of `dd`: `partclone.dd -c` writes nothing and `partclone.restore` crashes on a raw stream; `restore-part` restores it with `dd of=PART conv=fsync`. `sfdisk --part-type` prints the GPT GUID `21686148-6449-6E6F-744E-656564454649`, not `ef02`.
- Resident fallback source of a deploy: `recovery_from_parts` takes the kernel, initrd and `recovery.sha256` from the boot tarball of the parts set (`UNITOTEM_PART_STREAM_FILE` of the EFI or FIRMWARE block; members `unitotem/recovery-vmlinuz`, `unitotem/recovery-initrd.img`, `unitotem/recovery.sha256` on amd64, `recovery8.img`, `recovery-initrd.img`, `recovery.sha256` on arm64, `./` prefix allowed). They are extracted to a temp dir before stage 1 touches the target. Kernel and initrd are checked against the tarball's `recovery.sha256`; a mismatch or unreadable tarball refuses the deploy with the target unchanged. `recovery.sha256` is sent to the target after the pair, so the target's boot partition carries the level of the set it was given.
- The host copies `deploy/<arch>/recovery-*` are a fallback only: used when the tarball lacks a member (warning on stderr, level 0 until the next confirmed boot). `push_recovery_kernel` (arming a non-UniTotem target, before any parts set is used) still reads them. Rebuild them with every release (`unitotem/stage1-recovery-initrd.sh`); an older initrd ships an older engine (an initrd from before open mode refused the empty password on a first-access device). `remote-deploy.sh recover` also runs the engine of the initrd it is connected to.
- `/boot/efi` is mounted read-only on the running system: remount it read-write before `grub-editenv ... next_entry=ota-recovery` and the like, and read-only again afterwards.
- Measured in a SeaBIOS q35 KVM VM (4 vCPU, 4 GiB): `recover` of a 3.7 GB system about 3 min; the restarted VM reaches `/setup` about 1 min after the reboot.
- `unitotem-update repair` on GRUB treats a slot as sound only with `vmlinuz` and `initrd.img` present (relative symlinks into `boot/`): the entries `slot-a`/`slot-b` load those paths.
- `/health` answers on loopback only (404 from outside): a host-side post-deploy check uses `/login` or `/setup`.
- Post-restore addressing uses `blkid -L` labels (`ROOT_A`, `ROOT_B`, `DATA`, `FIRMWARE`/`EFI`): two UniTotem disks in one machine make the lookup ambiguous; no duplicate-label check exists.
- `make-parts.sh`: arch from the `-amd64.img.xz`/`-arm64.img.xz` suffix or `--arch`; scratch `work/parts-scratch.<pid>` removed unless `--keep-scratch`.
- `make-preboot-image.sh`: default parts set is the newest `deploy/arm64/*.parts`; needs `recovery-*` and `p1-FIRMWARE.bootfs.tar.*`; output `deploy/arm64/unitotem-preboot-arm64.img` (+ `.xz`).
- The OTA environment has no fixed password. Logins are the armed public key, the administrators of the installed system, or open mode on a never-configured device (see [Fallback authentication](#fallback-authentication)). Open mode accepts any network peer: use it only on trusted networks.

## Tests

- `python3 tools/release/test_deploy_backup.py`: `backup_stream`, `backup_running_system`.
- `python3 tools/release/test_secure_boot_gate.py`: SecureBoot parsing, gate branches (a non-A/B parts set is refused in `load_parts`, before the gate).
- `python3 tools/release/test_deploy_bios.py`: BIOS parts set through `load_parts`, the manifest loop and the `restore-part` dd branch (no partclone).
- `tools/release/test_parts_bios.sh`: `make_parts` on a loop image with an ef02 partition (Docker, privileged): raw `dd` stream, sha256, byte identity.
- `python3 tools/release/test_fallback_auth_slot.py`: the slot the fallback reads for its logins.
- `python3 tools/release/test_deploy_recovery_source.py`: `recovery_from_parts` (tarball source, checksum refusal, host fallback, `./` members; 29 checks).
- `unitotem/check-recovery-commands.sh ROOTFS INITRD ENGINE.sh`.
- Loopback and QEMU harnesses: `testing.md`.
