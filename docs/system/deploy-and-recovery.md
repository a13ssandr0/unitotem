# Deploy, OTA fallback and recovery

Paths: relative to the repository root.

Host-side tooling that installs UniTotem on a target (Raspberry Pi arm64 or amd64 PC) over the network and recovers a target that no longer boots. The target runs a resident OTA fallback (dropbear in a recovery initramfs); the host drives every step. The fallback is the only tool that works when both slots are broken, on a first deploy, when adopting a foreign OS and for host-driven installs.

## Files

| Path | Role |
|---|---|
| `deploy/script/remote-deploy.sh` | Orchestrator: `deploy`, `probe`, `changes`, `disarm` |
| `deploy/script/ota-engine.sh` | Target engine, `/usr/sbin/unitotem-ota-engine`; one subcommand per step |
| `deploy/script/lib.sh` | SSH/SCP wrappers, sudo escalation, data channel, `backup_stream` |
| `deploy/script/write-sd.sh` | Image -> SD card or disk: partition table, partitions, `partclone` per partition, `pv` progress |
| `deploy/script/image-lib.sh` | Reads a disk image in place: tmpfs-only expansion, read-only loop device, descriptor, per-partition streams |
| `deploy/script/make-preboot-image.sh` | Fallback-only SD image (default 128 MiB) |
| `unitotem/files/unitotem-ota-arm` | On-target arming of an installed UniTotem |
| `unitotem/files/unitotem-ota-changes` | On-target scan behind `changes` |
| `unitotem/files/ota-hook`, `ota-init-premount`, `ota-local-bottom-verify`, `ota-recovery-init-premount` | Initramfs integration |
| `unitotem/stage1-recovery-initrd.sh` | Builds `build/<arch>/recovery/recovery-*` |
| `unitotem/check-recovery-commands.sh` | Recovery initrd carries every engine command |

## How it works

- `probe`: one `ssh_t bash -s` round trip; prints `KEY: value` and `DISK:` lines. A 64-bit Pi model (3, 4, 5, Zero 2) gives arm64/`rpi`; else EFI gives amd64/`uefi`; else amd64/`bios`. Other Pi models are refused.
- Disk: `--disk` (kernel name or by-id path) or interactive. A disk without a stable by-id/by-path is refused.
- `deploy`, in order:
  0. `ensure_tryboot_firmware` (Pi 4/5 with the earlier system, `tryboot: 0`): refused while `vcgencmd get_throttled` shows under-voltage now (bit 0); `YES` unless `--yes`; the old `start*.elf`, `fixup*.dat` and `bootcode.bin` of `/boot` (or `/boot/firmware`) are saved as `unitotem-firmware-<host>-<ts>.tar.zst` and read back; `apt-get install --only-upgrade raspberrypi-bootloader` after `apt-get update` (nothing else is upgraded); the target restarts, is waited for (6 minutes) and probed again; no tryboot after that stops the deploy with the saved files named. A target without the package, or without network to its apt repository, stops before anything is written or at the update with the apt error.
  1. `secure_boot_note` (amd64 UEFI: reports Secure Boot on, nothing to choose), `changes_gate` (installed UniTotem), confirmation `YES` unless `--yes` or `--accept-changes`.
  2. Backups before anything is armed (Backups).
  3. Arm. Installed UniTotem: `unitotem-ota-arm --port 2222 [--wipe-data] --authkey-file FILE` (`-` = stdin; the public key goes to `unitotem-ota.authorized_keys` on the boot partition), which reboots into the fallback. Other system: copy recovery kernel and initrd to the boot partition, one-shot boot with `unitotem.ota.authkey=<base64 of the key line>` on the kernel command line (Pi: `config.txt`/`cmdline.txt` swap, originals kept as `*.unitotem-bak`; x86: GRUB entry `UniTotem OTA` + `grub-reboot`), reboot. The per-target key is created here (see [Fallback authentication](#fallback-authentication)).
  4. `wait_ota_reachable`: polls the fallback (`root@host:2222`) up to 600 s; after 60 s without answer scans the local /24 for dropbear on 2222.
  5. `run_ota_sequence`.
     - `data_path_setup` first: the target opens the data connection (restore-part, populate-bootfs) towards the host, so a throw-away listener checks it with `/dev/tcp`. A node on a routed network (VPN) answers SSH but has no route back (measured: `No route to host` after the table was rewritten, from the build server and from the dev PC alike). The fallback's dropbear runs with `-j -k` (no port forwarding, `ssh -R` is refused), so the host then pipes each file through the OTA session into an `ip link set lo up; nc -l -p PORT -s 127.0.0.1 -q 2` on the target (the fallback's loopback is down; it has no `timeout` and no `ls`, so the host bounds the checks with `run_bounded` and the remote side uses `/bin/bash`) (`serve_data`, `data_push_start`; a few bytes are checked first, `data_push_ok`) and the engine is told `--data-host 127.0.0.1`. No way found: the sequence stops before anything is written. `data_wait` waits for the previous server before the next file takes the port.
  6. Polls `https://<ip>/login` on the new system up to 600 s, credential-free (see Rules).
- Deploy on a fallback (what a node in the OTA fallback, a preboot card or a PC started from the installer is): `deploy` finds it by itself, a dropbear banner on `HOST:PORT` (port 2222, or the `:PORT` of the target). Nothing is armed. Engine `probe` picks the disk (holding DATA/ROOT/EFI labels, or the only disk). DATA is kept only if: no `--wipe-data`, DATA mounts, read-only `e2fsck -fn` passes, DATA partition number and start sector match the image, partition count matches. Otherwise the table is rewritten and DATA is lost (saved first if it mounts). The boot partition is reformatted if missing or failing `fsck.fat -n`. Secure Boot active forces `shim`. Login: see [Fallback authentication](#fallback-authentication). A fallback armed with `unitotem.ota.addr/gw` (a node with a fixed address) hands that address and gateway to the installed system (`recover_net_from_cmdline`); `--net-dns "A;B;C"` adds its DNS servers (a fallback has no running system to read them from).
- `disarm`: restores `config.txt`/`cmdline.txt` from `*.unitotem-bak` (Pi) or removes `/etc/grub.d/99_unitotem_flash` (x86); removes recovery files.
- `changes [--json]`: runs `unitotem-ota-changes check` on the target.
  - UI sequence: `changes --json`; if `verdict` is `clean`, deploy; else show packages and unexplained files, keep `digest`, and after confirmation run `deploy --accept-changes DIGEST`. A digest mismatch means the system changed: restart from `changes`.
  - The check runs over `ssh_t` with no timeout of its own and is I/O bound: the first run after a boot is much slower than later ones, so callers allow generous time.
  - Exit 127 comes from the SSH wrapper when the target lacks the tool (image predates it): `changes` exits 3, the deploy gate only warns and continues.
- The probe takes dhcp or static from the protocol of the default route of the link (`proto dhcp`, `proto static`); lease files and `nmcli` decide only when the route names none (a lease file left from an earlier DHCP setup made a static node look DHCP).
- `tryboot` comes from the `tryboot` node the running VideoCore firmware publishes under `/proc/device-tree/chosen/bootloader`: a Pi 4 whose `/boot` firmware is older (measured: `start4.elf` of March 2022 has no node, October 2022 has it, with the same EEPROM and the same `capabilities` word `0x1f`) reads `tryboot: 0`. `deploy` brings such a target up to date first (below); `--no-firmware-update` skips that and the A/B check then refuses the target.
- `probe` prints `Secure Boot : enabled (deploy will ask how to proceed) | disabled | cannot be detected` and `Earlier UniTotem (single root): <version|none>`. The state is read from the `SecureBoot` EFI variable on a UEFI boot only, never guessed.

Stage 1 (fallback installed; a power loss boots the fallback):

- `restore-table` (skipped when DATA and table are kept); marks the point of no return.
- `prepare-bootfs --fresh 1` (`--volid` from the image); `write-bootfile` for recovery kernel, initrd and `recovery.sha256` (source: the image, see Rules).
- `populate-bootfs --layout ab`, then `set-default-recovery --layout ab`.

Stage 2 (system image):

- Each block of the descriptor (`parts.manifest` that `image_describe` writes in tmpfs): `restore`/`raw` -> `restore-part` (bulk over the data channel); `format` -> `format-part`; `data` -> `data-op` (`mkfs` if wiping or DATA absent, else `preserve`). `filecopy` partitions are covered by `populate-bootfs`.
- `mount-target`; `migrate-etc-overlay` and `apply-network` (non-fatal).
- `set-trial-boot --layout ab` (GRUB one-shot `slot-a`, or `tryboot.txt` on Pi), `umount-target`, reboot (Pi tryboot: `reboot -f '0 tryboot'`).
- The fallback stays default until the trial slot is confirmed by `unitotem-update --json boot-ok` (`saved_entry` / `config.txt` flip then).

The network deploy reads the FULL image (`deploy/<arch>/unitotem-<date>-<arch>.img.xz`, also the source of the release assets); the flash image (`-flash.img.xz`) is for writing to a card or disk directly and is refused by `deploy` and `recover` (it has no DATA). Full image and flash image: `storage-and-persistence.md#layout`.

No parts files. `deploy` opens the image (`image_open`): an `.xz` is expanded once, sparse, into tmpfs (`/dev/shm`, or `$UNITOTEM_TMPFS`; refused when the directory is not tmpfs or the data in use does not fit there) and a plain `.img` is used where it is; both through a read-only loop device. `image_describe` writes, in a tmpfs directory of a few KiB, `parts.manifest` (KEY=VALUE header, one block per partition: label, filesystem, cloner, action, start, sectors, used bytes, FAT serial), `layout.sfdisk`, `bootcode.bin` (440 bytes) and the file-level tar of the boot partition (`p1-EFI.bootfs.tar.xz` or `p1-FIRMWARE.bootfs.tar.xz`). Every other partition is read while the target pulls it: `image_stream N` writes `partclone.<fs> -c` (or a raw copy of the BIOS partition) through `xz -T0 -1` into a FIFO that the data channel serves; nothing is stored. The host's partclone (0.3.44 measured) and the target's (trixie 0.3.36) agree on the stream (a ROOT_A written by the first restored and checked by the second). The script runs as root for `deploy` and `recover`: started as a user it runs again through `sudo env` with `HOME`, `OTA_*`, `UNITOTEM_*`, `XDG_STATE_HOME`, `SSH_AUTH_SOCK`, `SSHPASS`, `TERM`, `LANG`, `LC_*`, `TMPDIR` (sudo-rs ignores `-E`) and the same working directory; `ssh` then runs with `-F /dev/null` (it refuses a user's `~/.ssh/config` as root) and the state and backup directories are given back to the user at the end. `--help`, `probe`, `changes` and `disarm` need no root.

- Layout 2 (A/B) is the only layout: an image without ROOT_A, or without DATA, is refused. Supported targets: amd64 (UEFI and legacy BIOS) and Pi with tryboot; Pi 3/Zero 2 are refused. On legacy BIOS the MBR boot code (`bootcode.bin`, written by `restore-table`) and the `BIOS` partition (ef02, raw stream with GRUB's core.img) are restored from the image; GRUB then reads `unitotem-grub/` on the EFI partition exactly as under UEFI.
- `image-lib.sh` recognises the BIOS partition by its GPT type GUID (21686148-6449-6E6F-744E-656564454649); without that stream a BIOS target would not boot. Actions by label (`_img_action`): `EFI`/`FIRMWARE` filecopy (fat); `DATA` data (never streamed); `BOOT`/`ROOT`/`ROOT_A` restore (partclone extfs); `ROOT_B` format (shipped empty); `BIOS` raw (the stream is the raw partition content, `xz` of `dd`; `partclone.dd` has no clone mode; restored with `dd of=PART conv=fsync`).

Preboot SD image: one FAT32 partition from 1 MiB (MBR type 0c) with Pi firmware, `recovery8.img`, `recovery-initrd.img`, `config.txt` (640x480), `cmdline.txt` with `unitotem.ota=recover`. Waits with no idle timeout; `deploy` lays out the whole card. `deploy/script/write-preboot.sh [--yes] [--image FILE] [--out FILE] [DEVICE]` builds it and writes the card in one step (root; the only removable disk with a medium when no DEVICE is given). The card has no password, key or DATA, so the fallback is in open mode: `OTA_FALLBACK_OPEN=1 remote-deploy.sh recover <address> --image <full image> --yes`. The firmware files come from the FIRMWARE partition of any arm64 image (the flash image too; Pi 3 and Pi 4 files are both required); the engine in the initrd is the repository's (`--engine FILE`; a second cpio archive with that one file is appended to the recovery initrd, so no build is needed for a new engine). Test: `tools/release/test_preboot_image.sh`; emulated boot of a Pi 3 with the card's initrd: open login after 14 s (`work/preboot-qemu`, QEMU `raspi3b`).

## Writing a card or disk from an image

`deploy/script/write-sd.sh [--yes] [--no-eject] IMAGE DEVICE` (root; IMAGE is a full, flash or Raspberry Pi `.img` or `.img.xz` of `deploy/<arch>/`; DEVICE a whole disk). It reads the table of the image (`sfdisk -d` without `last-lba`: same disk GUID, partition GUIDs, names and start sectors, backup table at the real disk end), copies the first 440 bytes (MBR boot code), creates the partitions, then clones each one: ext2/3/4 with `partclone.extfs`, FAT with `partclone.fat` (both through a pipe `clone | pv | restore`, progress against the used bytes), anything else with `pv | dd`. Only the used blocks are read and written, so a 14 GiB image with a few GiB of data takes the time of that data. An `.xz` is expanded once, sparse, into tmpfs only (`/dev/shm`, or `$UNITOTEM_TMPFS`; refused when that is not tmpfs or the data in use does not fit there) and removed at the end.
- Checks: root, tools, whole disk, nothing mounted on it, not the disk of `/`, `/boot`, `/boot/efi`, the device at least as large as the end of the last partition; without `--yes` the device is listed and `(y/n)` is asked.
- At the end a removable device (`lsblk` RM 1) is synced and ejected (`eject`; a warning when that fails); `--no-eject` leaves it attached. Loop and fixed disks are never ejected.
- After the copy every partition keeps label and UUID (compared with the image) and `e2fsck -fn` / `fsck.fat -n` must be clean.
- The last partition is not grown: DATA grows at the first boot ([storage](storage-and-persistence.md)); a flash image gets ROOT_B and DATA laid out in the free space at the first boot.
- Test: `tools/release/test_write_sd.sh` (privileged container, loop devices): table, GUIDs, labels, UUIDs, files by md5, raw partition, MBR boot code, allocation of the target (only used blocks), `.img` and `.img.xz`, refusals.

## Interfaces

`deploy/script/remote-deploy.sh`:

| Command | Options |
|---|---|
| `probe user@host` | none |
| `changes user@host` | `--json` |
| `deploy [USER@]HOST[:PORT]` | `--image FILE` (required), `--disk NAME\|BYID`, `--yes`, `--wipe-data`, `--no-backup`, `--backup-dir DIR` (default `~/.local/state/unitotem-deploy/backups`), `--port N` (data channel, 9700), `--timezone ZONE`, `--net-dns "A;B;C"`, `--console STR`, `--no-firmware-update`, `--fallback-only`, `--accept-changes DIGEST`; `PORT` is the ssh port of the fallback |
| `disarm user@host` | none |

Environment: `OTA_PASSWORD` (login password of an adopted foreign system, default `unitotem`), `OTA_FALLBACK_KEY` (private key tried first at the fallback login, default `~/.ssh/id_ed25519`; see [Fallback authentication](#fallback-authentication)), `OTA_AUTH` (`password` by default; `key`: `BatchMode=yes`, `PreferredAuthentications=publickey`, no sshpass, for hosts with the dev PC's key installed: test devices and the native arm64 build host `PI_HOST`), `OTA_PORT` (fallback SSH port, 2222), `OTA_HOSTIP` (address the target uses to reach the host), `UNITOTEM_BACKUP_DIR` (default `backups/`), `UNITOTEM_OTA_DEBUG=1` (engine: emergency shell on failure).

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
| `populate-bootfs` | `--bootfs-part --data-host --data-port [--layout ab]` | `UNITOTEM_BOOTFS_POPULATED` |
| `set-default-recovery` | `--firmware rpi\|uefi\|bios --bootfs-part [--layout ab]` | `UNITOTEM_DEFAULT_RECOVERY` |
| `set-trial-boot` | `--firmware rpi-tryboot\|rpi-legacy\|uefi\|bios --target DIR [--disk --bootfs-part --layout ab]` | `UNITOTEM_TRIAL_ARMED` |
| `promote-default` | `--firmware [--disk --bootfs-part]` | `UNITOTEM_PROMOTED` |
| `mount-target` / `umount-target` | `--root-part --boot-part --bootfs-part --data-part --arch` | `UNITOTEM_MOUNTED` / `_UNMOUNTED` |
| `populate-real-kernel` | none | `UNITOTEM_KERNEL_POPULATED` |
| `migrate-etc-overlay` | `--root-mnt --data-mnt [--slot a\|b]` | `UNITOTEM_ETC_MIGRATED` |
| `apply-network` | `--data-mnt [--slot --link wired\|wifi --mode dhcp\|static --addr --gw --dns --ssid-b64 --psk-b64]` | `UNITOTEM_NET_APPLIED=1\|skip-existing\|not-needed` |
| `serve-fallback` | `[--reason --kind update\|recovery --idle-timeout S]` | blocks |

Boot signals: `unitotem.ota=1|recover`, `unitotem.slot=a|b`, `unitotem.ota.authkey=<base64 of one ssh-ed25519 line>` (fallback login key); `unitotem.ota.addr=A.B.C.D/N` and `unitotem.ota.gw=A.B.C.D` (a fixed address for the fallback, armed from the probe of a target whose earlier system used one on a wired link; strict IPv4, anything else is ignored, the command line wins over `unitotem-ota.conf`; without them the fallback asks DHCP); boot-FAT files `unitotem-ota.request`, `unitotem-ota.authorized_keys` (fallback login key, kept by `populate-bootfs`), `unitotem-ota.conf` (`OTA_NET_LINK/MODE/IFACE/ADDR/GW`, `OTA_WIFI_SSID_B64`, `OTA_WIFI_PSK_B64`), `unitotem-ota.failover`, `unitotem-grub/grub/grubenv`, `tryboot.txt`, `cmdline-trial.txt`. Semantics: `boot.md`.

## Fallback authentication

Entered on a failed boot (root checks, or the boot counter: three boots without a healthy manager, see [Boot counter](boot.md#boot-counter)), or on an update request.

The fallback dropbear (port 2222) has no fixed password. `fallback_auth_setup` (`deploy/script/ota-engine.sh`) writes `/etc/passwd`, `/etc/shadow` and `/root/.ssh/authorized_keys` into the initramfs tmpfs before dropbear starts. Sources, in order:

1. Armed public key:
   - kernel command line token `unitotem.ota.authkey=<base64 of one ssh-ed25519 line>` (foreign OS, `arm_rpi`/`arm_grub`);
   - file `unitotem-ota.authorized_keys` on the boot FAT (FIRMWARE or EFI), written by `unitotem-ota-arm --authkey-file FILE` (installed UniTotem). The engine mounts the boot FAT read-only itself when `/boot-ota` is not mounted.
2. DATA, mounted read-only on demand and unmounted after reading:
   - `upper/root.<slot>/.ssh/authorized_keys` (one slot: `unitotem.slot=` on the command line, else `saved_entry=slot-x` of the boot FAT `unitotem-grub/grub/grubenv` (GRUB entry `ota-recovery` carries no slot), else slot a; the other slot's accounts are never read);
   - for every member of group `sudo` in `upper/etc.<slot>/group`: the shadow hash (`upper/etc.<slot>/shadow`) and `unitotem/persist/home/<user>/.ssh/authorized_keys`.
3. Open mode, only when no key and no administrator was found at all: root with an empty password and dropbear `-B`. Logged. A configured device never falls back to open. A device whose administrator password is forgotten stays closed unless a key is armed or present in DATA. DATA that is absent or cannot be mounted counts as nothing found, so a device with a damaged DATA stays recoverable remotely; the price is that an intact device whose DATA fails to mount at that moment is open until the next boot.

Each administrator becomes a uid 0 account `<user>` (shell `/bin/sh`, home `/root`) in the initramfs. `ssh <admin>@<host> -p 2222` gives a root shell with that administrator's password or key. Root itself accepts keys only; open mode is the only case with an empty root password. Names fullmatch `[a-z_][a-z0-9_-]{0,31}`; hashes `!`, `*` or empty give no password. Key lines accept only `ssh-ed25519`, `ssh-rsa` and `ecdsa` types without options (the cmdline token: ed25519 only); max 64 keys, 2048 characters per line.

dropbear: `-F -E -p 2222 -r <host key> -T 3 -j -k` (3 auth tries, no local or remote forwarding); `-B` only in open mode.

Tool side (`deploy/script/lib.sh`, `ota_auth_resolve`, called by `deploy` on a fallback; nothing to set):
- Order, like ssh: a key (`OTA_FALLBACK_KEY`, then `~/.ssh/id_ed25519`, the only key made or used; then the ssh agent), then the open fallback (an empty password, root only), then a password for USER typed on the terminal, not echoed, up to three tries; the login is asked when no `USER@` was given (Enter = `root`, which may accept a password too).
- Without a terminal nothing is asked: the login fails with a message.
- Key auth: `BatchMode=yes`, `PreferredAuthentications=publickey`, `IdentitiesOnly=yes` (agent: no `-i`). Password: `sshpass -e`, the password only in a shell variable of the script, never in the environment of a child or a command line.
- `ota_auth_for` (the older selection by `OTA_FALLBACK_KEY`/`OTA_FALLBACK_USER`/`OTA_FALLBACK_PASSWORD`/`OTA_FALLBACK_OPEN=1`) stays for other tools (`tools/win-lab/recover-driver.sh`).
- Every operation works remotely. No physical access is assumed.

## Backups

| Source | Archive | Content |
|---|---|---|
| Installed UniTotem | `unitotem-data-<host>-<ver>-<ts>.tar.zst` | `/mnt/data` |
| Single-root UniTotem 1.x/2.x | `unitotem-legacy-<host>-<ver>-<ts>.tar.zst` | `/etc/unitotem`, uploaded media, root crontab, `/etc/netplan`, hostname, hosts, TLS cert, `asound.conf`, kiosk `xinitrc` |
| `deploy` on a fallback, DATA about to be rewritten | `unitotem-data-<host>-recovery-<ts>.tar.zst` | DATA, read-only mount |

- Each archive has a `.sha256` sidecar and is read back before the deploy continues; `.tar.xz` when zstd is missing.
- Free space must exceed the used size. A failed backup stops the deploy with the target unchanged.
- `--no-backup` skips; `--fallback-only` never backs up.
- Single-root archives also hold `etc/timezone`. After the deploy the script migrates the archive onto the new system with `migrate-legacy.py` (`deploy/script/`): the first administrator is `USER` of `USER@HOST` (`admin` without one), its password typed on the terminal twice (nothing is migrated without a terminal; `--timezone` overrides the zone) ([legacy-import.md](../manager/legacy-import.md)); the backup is always made by the script itself, before anything is armed.

## Rules and gotchas

- All SSH/SCP to targets goes through `deploy/script/lib.sh`: `ssh_t`, `scp_t`, `scp_root`, `ota_ssh`, `ota_ssh_send`, `_sshpass`. They set `SSH_ASKPASS_REQUIRE=never` and unset `DISPLAY`/`SSH_ASKPASS`; a raw `ssh`/`scp` makes OpenSSH try a graphical askpass when no password is ready, then fail with repeated `Permission denied` and no clear error. Check: `grep -n '\bssh \|\bscp \b' deploy/script/*.sh | grep -v '_sshpass\|ssh_t\|ota_ssh\|scp_t\|command -v\|ssh-keyscan'`.
- `ota_ssh` keeps `-n` (loops read the descriptor on fd 9); `ota_ssh_send` keeps stdin.
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
- Secure Boot (amd64 UEFI): the image's loader is the signed chain, which boots with it on or off: no option, no question; an unknown state only warns.
- Secure Boot `shim` may need physical intervention: with an NVIDIA GPU the MOK key is enrolled from the console; firmware that does not trust the Microsoft UEFI CA rejects shim; a non-Debian running system may stop at the GRUB prompt (`bad shim signature`) on the first one-shot step. A target already UniTotem with Secure Boot active keeps the shim chain automatically (A/B parts set only).
- Backups of an installed UniTotem exclude the target's `unitotem-native-build` scratch tree (deploy backup and the DATA save of a fallback deploy).
- `--accept-changes DIGEST` implies `--yes` and must equal the current digest. `--yes` overwrites changes without showing them.
- `changes` exits 0 clean, 1 changes found, 2 check failed, 3 tool missing (see Interfaces). A UI reads the `--json` `verdict` and must check the exit code before it.
- The fallback has no reverse tunnel: the host always connects to the target on `OTA_PORT`.
- Layout 2 installs leave ROOT_B formatted and empty.
- Legacy BIOS (amd64): `restore-table` writes `bootcode.bin` into the MBR area, the `BIOS` partition (ef02) is restored raw. Proven in a SeaBIOS q35 VM: empty disk -> `deploy` -> reboot -> slot A trial -> automatic confirm; fetch + apply of a newer release; trial rollback to the other slot; power cuts after arming, in the trial boot and during the write of the other slot; `repair`; `ota-recovery` entry with key, administrator password and open mode.
- The input is the FULL image (`unitotem-*-<arch>.img.xz`: EFI, ROOT_A, ROOT_B, DATA, BIOS), never the flash image (its table lacks ROOT_B and DATA). The expansion of a 14 GiB sparse image is `xz -dc -T0 | dd bs=4M iflag=fullblock conv=sparse` (measured 11.6 s on 20 cores, 4.3 GiB really stored; `xz -T0` alone does 2.4 GiB/s). `iflag=fullblock` is required: a pipe delivers short reads and `dd conv=sparse` without it ran at about 20 MB/s (10 minutes). The BIOS stream is the raw partition (1 MiB) as `xz` of `dd`: `partclone.dd -c` writes nothing and `partclone.restore` crashes on a raw stream; `restore-part` restores it with `dd of=PART conv=fsync`. `sfdisk --part-type` prints the GPT GUID `21686148-6449-6E6F-744E-656564454649`, not `ef02`.
- Resident fallback source of a deploy: `recovery_from_image` takes the kernel, initrd and `recovery.sha256` from the boot tarball of the image (`UNITOTEM_PART_STREAM_FILE` of the EFI or FIRMWARE block; members `unitotem/recovery-vmlinuz`, `unitotem/recovery-initrd.img`, `unitotem/recovery.sha256` on amd64, `recovery8.img`, `recovery-initrd.img`, `recovery.sha256` on arm64, `./` prefix allowed). They are extracted to a temp dir before stage 1 touches the target. Kernel and initrd are checked against the tarball's `recovery.sha256`; a mismatch or unreadable tarball refuses the deploy with the target unchanged. `recovery.sha256` is sent to the target after the pair, so the target's boot partition carries the level of the set it was given.
- The fallback kernel and initrd written to the target are the ones on the image's own boot partition, checked against its `recovery.sha256`; an image without them is refused with the target unchanged. Nothing is read from the development tree: the scripts use only files beside them, and the image is always given with `--image`.
- `/boot/efi` is mounted read-only on the running system: remount it read-write before `grub-editenv ... next_entry=ota-recovery` and the like, and read-only again afterwards.
- Measured in a SeaBIOS q35 KVM VM (4 vCPU, 4 GiB): a deploy of a 3.7 GB system about 3 min; the restarted VM reaches `/setup` about 1 min after the reboot.
- `unitotem-update repair` on GRUB treats a slot as sound only with `vmlinuz` and `initrd.img` present (relative symlinks into `boot/`): the entries `slot-a`/`slot-b` load those paths.
- `/health` answers on loopback only (404 from outside): a host-side post-deploy check uses `/login` or `/setup`.
- Post-restore addressing uses `blkid -L` labels (`ROOT_A`, `ROOT_B`, `DATA`, `FIRMWARE`/`EFI`): two UniTotem disks in one machine make the lookup ambiguous; no duplicate-label check exists.
- `make-preboot-image.sh --image FILE` (root, re-runs itself through sudo): firmware, device trees, `recovery8.img` and `recovery-initrd.img` all come from the FIRMWARE partition of that arm64 image; output `./unitotem-preboot-arm64.img` (+ `.xz`) unless `--out`. `write-preboot.sh --image FILE [DEVICE]` makes it in tmpfs and writes the card.
- The OTA environment has no fixed password. Logins are the armed public key, the administrators of the installed system, or open mode on a never-configured device (see [Fallback authentication](#fallback-authentication)). Open mode accepts any network peer: use it only on trusted networks.

## Tests

- `python3 tools/release/test_deploy_backup.py`: `backup_stream`, `backup_running_system`.
- `tools/release/test_ssh_t_stdout.sh`: the sudo set-up of `ssh_t` writes nothing to stdout (its messages go to stderr: a backup stream is the stdout of an `ssh_t` pipeline).
- `python3 tools/release/test_data_path.py`: the data path choice with fake ota_ssh, socat and ssh (direct way, push through the session, neither, `serve_data`, `data_wait`, `run_bounded`; 9 checks).
- `tools/release/test_check_engine_copy.sh`: `check-engine-copy.sh` on small cpio archives (identical, stale, absent, unreadable).
- `python3 tools/release/test_ota_net_cmdline.py`: the static address on the kernel command line, both sides and a deploy from a fallback (23 checks: validation, precedence, command line length).
- `python3 tools/release/test_tryboot_firmware.py`: `ensure_tryboot_firmware` with fake ssh, backup and probe (15 checks: no-ops, refusals, order, apt failure, confirmation).
- `python3 tools/release/test_secure_boot_gate.py`: SecureBoot parsing, `secure_boot_note` branches and the absence of the old option and mode (15 checks).
- `python3 tools/release/test_deploy_bios.py`: the `restore-part` dd branch of the engine (no partclone).
- `tools/release/test_image_lib.sh` (Docker, privileged): `image-lib.sh` on a small A/B image: tmpfs-only expansion and refusals, descriptor (labels, actions, used bytes, BIOS by GPT type, FAT serial, boot tar), ROOT_A and BIOS streams restored the way the engine does.
- `tools/release/test_deploy_e2e.sh [uefi|bios] [IMAGE]` (Docker, KVM, OVMF; about 6 min): an amd64 PC in QEMU boots the recovery kernel and initrd into the fallback (open access), `remote-deploy.sh deploy --image` finds the fallback, logs in with no password and writes the full image from a privileged container, the disk then boots (UEFI or legacy BIOS) and the web UI must show `/setup`. Measured 2026-11-15 with the 2026-11-14 image: both firmwares pass; the Pi 3 (emulated `raspi3b`, TCG, 46 MB/min) reaches the ROOT_A restore with the MBR table and the fallback files written.
- `tools/release/test_preboot_image.sh` (Docker, privileged): `make-preboot-image.sh` and `write-preboot.sh` on a fake arm64 image: MBR with one FAT partition, firmware of Pi 3 and Pi 4, recovery kernel, the repository's engine appended to the initrd, no key or password on the card.
- `tools/release/test_remote_deploy_root.sh`: `--help`, `probe`, `changes`, `disarm` need no root; `deploy` goes through `sudo env` with the right variables (a stub `sudo`).
- `python3 tools/release/test_fallback_auth_slot.py`: the slot the fallback reads for its logins.
- `python3 tools/release/test_deploy_recovery_source.py`: `recovery_from_parts` (tarball source, checksum refusal, host fallback, `./` members; 29 checks).
- `unitotem/check-recovery-commands.sh ROOTFS INITRD ENGINE.sh`.
- Loopback and QEMU harnesses: `testing.md`.
- `tools/release/test_ota_auth.sh` (Docker): `ota_auth_resolve` against a dropbear started like the fallback: your key `~/.ssh/id_ed25519` (another key is not tried), `OTA_FALLBACK_KEY` first, the open fallback, a password typed on a terminal (with and without a given user), three wrong passwords, no terminal, `root@` with a wrong password.

## Administrator and ssh key
Options: `--admin NAME`, `--admin-password-file FILE` (or `UNITOTEM_ADMIN_PASSWORD`; never on the command line), `--copy-key`: nothing is asked then (without `--admin-password-file` and without a terminal the run stops). `~/.ssh/id_ed25519` is created without a passphrase when missing, also for arming. Without options `deploy` asks on the terminal (nothing without one): the administrator name (Enter: create it on the setup page), the password twice, and whether to copy `~/.ssh/id_ed25519.pub` to that account. The fallback is armed with that same key; When the new system answers on HTTPS, `migrate-legacy.py` (without `--archive`: only the administrator) creates the account, imports the settings of an earlier system when an archive exists, and the key goes to `~/.ssh/authorized_keys` of the administrator. A system that already has an administrator is left alone.
