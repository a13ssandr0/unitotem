# Boot system

Paths: relative to the repository root.

Boot chain of UniTotem devices: bootloader (GRUB on PC, Raspberry Pi firmware on Pi), A/B slot choice, trial boot and promotion, initramfs OTA entry and slot failover, OTA fallback entry, splash, screen orientation, Secure Boot chain (amd64).

## Files

| Path | Role |
|---|---|
| `unitotem/files/grub-default` | `/etc/default/grub`; `GRUB_DEFAULT=saved` in A/B |
| `unitotem/files/grub-ab-entries` | `/etc/grub.d/10_unitotem_ab`: slot, recover and `ota-recovery` entries, `fallback` list |
| `unitotem/files/grub-ota-entry` | `/etc/grub.d/45_unitotem_ota`: single-root recovery entry |
| `unitotem/files/config.txt` | Pi firmware config (`[all]`, `[pi3]`, `[pi4]`, `[pi5]`) |
| `unitotem/files/config-extra.txt` | dtoverlay/dtparam/framebuffer lines; `/etc/unitotem/config-extra.txt`, appended to Pi trial and fallback configs |
| `unitotem/files/plymouthd.conf` | `Theme=unitotem`, `ShowDelay=0`, `DeviceTimeout=8` |
| `unitotem/files/unitotem-boot-orientation` | `/usr/sbin/unitotem-boot-orientation`: `video=` orientation tokens |
| `unitotem/files/ota-init-premount` | initramfs init-premount `zz-unitotem-ota` |
| `unitotem/files/ota-recovery-init-premount` | init-premount of the resident fallback initrd (always OTA) |
| `unitotem/files/ota-local-bottom-verify` | local-bottom `zz-unitotem-verify` |
| `unitotem/files/ota-hook` | initramfs-tools hook: bash, dropbear, partclone, real mount/dd/mke2fs, modules; no OTA password (logins are generated at run time, see [Fallback authentication](deploy-and-recovery.md#fallback-authentication)) |
| `unitotem/files/overlayfs-hook.sh` | init-bottom `setup-overlays` (`storage-and-persistence.md`) |
| `unitotem/files/unitotem-boot-ok` | Boot confirmation (`ab-updates.md`) |
| `unitotem/files/unitotem-ota-arm` | Writes `unitotem-ota.request` on the boot FAT and reboots into OTA |
| `unitotem/files/unitotem-update` | Slot switching, backends (grub/rpi), trial, confirm, rollback, ESP `grub.cfg` sync |
| `deploy/ota-engine.sh` | All boot-partition writes, init-premount, serve-fallback, `ab_failover` |
| `unitotem/stage3-image.sh` | A/B boot layout: `slota/`, `os_prefix`, `grub-install`, `saved_entry=slot-a`, Secure Boot staging, `esp-grub.cfg` |
| `unitotem/slim-initramfs.py` | Pi initramfs reduction |
| `unitotem/verify-image.sh` | Boot-file assertions |

## How it works

### Raspberry Pi (arm64, `backend=rpi`)

- FIRMWARE (FAT): `config.txt`, shared firmware, `slota/` and `slotb/` (`kernel8.img`, `initramfs8`, `cmdline.txt`, dtbs, overlays), `recovery8.img`, `recovery-initrd.img`, `unitotem-ota.*`.
- Default: `config.txt` `os_prefix=slota/` (or `slotb/`).
- Trial: `tryboot.txt` holds the other slot's `os_prefix`; read by the firmware only on a reboot with `systemctl reboot --reboot-argument="0 tryboot"`. A plain reboot or power cut returns to the `config.txt` slot.
- Promotion: `config.txt` rewritten from `tryboot.txt` with the new `os_prefix`; `tryboot.txt` removed.
- Resident fallback: `config.txt` without `os_prefix` loads `recovery8.img` with `unitotem.ota=1`.
- Requires the EEPROM bootloader (`/proc/device-tree/chosen/bootloader`); else `backend-unsupported`. Pi 3 and Zero 2 get no A/B.

### PC (amd64, UEFI or BIOS, `backend=grub`)

- BIOS: the MBR boot code loads `core.img` from the `BIOS` partition (ef02, p5), which reads `unitotem-grub/` on the EFI partition as under UEFI. Run time: `/boot/efi` is mounted read-only; remount read-write for `grub-editenv`.

- ESP: `unitotem-grub/grub/grub.cfg`, `unitotem-grub/grub/grubenv`, `EFI/BOOT/BOOTX64.EFI` (plain GRUB), `EFI/unitotem-sb/` (staged Secure Boot chain), `unitotem/` (fallback kernel and initrd).
- Slot kernel and initrd: `/vmlinuz`, `/initrd.img` in each ROOT slot, found by `search --label ROOT_A|ROOT_B`.
- grubenv keys: `saved_entry`, `next_entry` (one-shot, cleared by GRUB), `unitotem_video`.
- Entries: 0 `slot-a`, 1 `slot-b`, 2 `slot-a-recover`, 3 `slot-b-recover`, 4 `ota-recovery`.
- Failover order: `slot-a` -> `fallback="1 4"`; `slot-b` -> `"0 4"`; else `"4"`.
- Slot kernel line: `root=LABEL=ROOT_x ro quiet splash ... unitotem.slot=x ${unitotem_video}`.

### Boot decision (initramfs, both backends)

1. `init-premount` runs `ota-engine init-premount`:
   - cmdline `unitotem.ota=1`: serve-fallback, idle 1800 s; `unitotem.ota=recover`: serve-fallback, no idle timeout.
   - `unitotem-ota.request` on FIRMWARE (Pi) or EFI (PC): read, deleted, serve-fallback (update, idle 1800 s).
   - Root from `root=LABEL=` found by blkid (5 retries), checked by `check_root_readonly` (`e2fsck -fn`, `-fp` only if it fails).
   - Check fails or root missing: `ab_failover` (A/B), else serve-fallback (recovery, idle 21600 s).
   - Single-root only: `unitotem-ota.bootcount` incremented; 3 or more gives recovery.
2. `ab_failover`: the other slot must pass `e2fsck -fn` and contain `/etc/unitotem/ota-preserve.list`. Writes guard `unitotem-ota.failover` (`cur->other`), switches the default (Pi: `os_prefix`, removes `tryboot.txt`; PC: `saved_entry`), `reboot -f`. Refused when the guard exists.
3. mountroot, then local-bottom verify: `/sbin/init` and `/etc/unitotem/ota-preserve.list` must exist, else serve-fallback.
4. init-bottom: `layout_complete` (flash image: ROOT_B and DATA created), DATA `e2fsck -p`, `grow_data` (DATA grown to the disk end), overlays on `/etc`, `/root`, `/var`, dpkg pinned to ROOT. Details: `storage-and-persistence.md`.
   - Overlay outcome: `/run/unitotem-overlay.status` (initramfs, one line): `ok`, `no-data` (no DATA: boot with no overlays, intended on an 8 GB card), `failed:data-mount`, `failed:overlay-etc|overlay-root|overlay-var`, `failed:dpkg-pin`. Log lines carry the prefix `overlay: status <state>`. The same state is the `overlay-status=` key of `/mnt/data/.unitotem-overlay-status`.
   - Not verified on hardware: fstab mounts a tmpfs on `/run` after switch_root (`fstab-amd64`, `fstab-arm64`), which may hide the initramfs file. Consumers must not rely on `/run/unitotem-overlay.status` after boot until checked; the DATA record is the post-boot source.
5. multi-user: `unitotem-boot-ok`.
   - Plain A/B boot: slot confirmed, guard removed, ESP `grub.cfg` synced, auto-repair started.
   - Trial boot: waits for `UPDATE_HEALTH_URL` (180 s), then `confirm_now`. Timeout: `rolled-back`, plain reboot.
   - Slot mismatch: `rolled-back`, `pending.json` removed.

### OTA fallback entry

- `serve-fallback`: framebuffer progress UI, `fallback_auth_setup` (writes the login accounts and keys to the initramfs tmpfs; sources in [Fallback authentication](deploy-and-recovery.md#fallback-authentication), kernel token `unitotem.ota.authkey=`), dropbear `-p 2222` (`-T 3 -j -k`, `-B` in open mode only), idle watchdog (stands down on a successful dropbear login, see [Fallback authentication](deploy-and-recovery.md#fallback-authentication)).
- x86 recovery entry (`UniTotem OTA`): `linux /unitotem/recovery-vmlinuz unitotem.ota=1 console=tty0`.
- Deploy: `set-default-recovery` makes the fallback default; `set-trial-boot` arms the real system; `promote-default` runs after confirmation (single-root path).

| | Default | Trial (one-shot) | Promote | Failover |
|---|---|---|---|---|
| GRUB | `saved_entry` | `next_entry` | `saved_entry=X`, unset `next_entry` | `saved_entry` = other slot |
| Pi | `config.txt` `os_prefix` | `tryboot.txt`, tryboot reboot only | `config.txt` <- trial file, delete `tryboot.txt` | `config.txt` `os_prefix` |

### Plymouth and orientation

- Splash: plymouthd in the initramfs, `Theme=unitotem` (package `plymouth-theme-unitotem`, see [packaging](../manager/packaging.md)). Without `Theme=` plymouth uses `text`.
- Orientation: `video=<CONNECTOR>:panel_orientation=<value>`; `right_side_up` (right), `left_side_up` (left), `upside_down` (inverted); `normal` removes it. Pi: written to `slota/cmdline.txt` and `slotb/cmdline.txt`. PC: grubenv `unitotem_video`, appended to both slot entries.

### Secure Boot (amd64)

- Staged in `EFI/unitotem-sb/`: `shimx64.efi`, `mmx64.efi`, `grubx64.efi` (Debian-signed), `grub-unsigned.efi`, `grub.cfg` stub (`search --label EFI`, `configfile` of `unitotem-grub/grub/grub.cfg`).
- `BOOTX64.EFI` stays plain GRUB until activation; `grub-install --no-uefi-secure-boot`.
- The staged `shim-signed` is dual-signed with the Microsoft UEFI CA 2011 and 2023.
- Kernel (amd64): from trixie-backports, `linux-image-7.2.12+deb13-amd64` (version `7.2.12-1~bpo13+1` in the index of 2026-11-08). Its source package is `linux-signed-amd64`: the Debian-signed `linux-binary` image is what GRUB loads. The staging names no kernel version: GRUB loads `/vmlinuz` and `/initrd.img`, which are symlinks in each ROOT slot.
- NVIDIA module (amd64): signed by the DKMS key generated in the image build (signer `DKMS module signing key`). The private key is removed from the image; `mok.pub` stays. `mokutil` in the image is for MOK enrolment of that public key, which is the physical-intervention path.
- Activation: `ota-engine populate-bootfs --secure-boot shim` copies signed GRUB, MokManager and `grub.cfg` into `EFI/BOOT` (and `EFI/debian/grub.cfg`), renames shim over `BOOTX64.EFI` last, writes `EFI/unitotem-sb/active`, prints `UNITOTEM_SECURE_BOOT=shim`.
- The choice `shim|noshim|abort` is made in `deploy/remote-deploy.sh` (`secure_boot_gate`).

## Interfaces

`unitotem-update` boot commands: `status`, `apply [--reboot] [--stage]`, `confirm`, `boot-ok`, `rollback [--reboot]`, `reboot`, `repair`, `cancel`. Exit and error codes: `ab-updates.md`.

`unitotem-boot-orientation`: `get [CONNECTOR]`, `set CONNECTOR normal|left|right|inverted`; JSON output; exit 0 ok, 1 failure, 2 bad arguments; error codes `no-backend`, `write-failed`. Env `UNITOTEM_BOOTFS` (`/boot/firmware`), `UNITOTEM_ESP` (`/boot/efi`), `UNITOTEM_GRUBENV`.

`deploy/ota-engine.sh` boot subcommands: `init-premount`, `serve-fallback --reason R --kind update|recovery --idle-timeout S`, `local-bottom-verify --rootmnt P`, `set-default-recovery`, `set-trial-boot`, `promote-default` (single-root only, refused on A/B), `populate-bootfs [--secure-boot shim]`, `prepare-bootfs` (options: `deploy-and-recovery.md`). Stdout markers: `UNITOTEM_TRIAL_ARMED=1`, `UNITOTEM_PROMOTED=1`, `UNITOTEM_DEFAULT_RECOVERY=1`, `UNITOTEM_SECURE_BOOT=shim`. `UNITOTEM_OTA_DEBUG=1`: failures drop to an emergency shell.

Kernel command line: `root=LABEL=ROOT_A|ROOT_B` (A/B) or `ROOT`, `rootfstype=ext4 rootwait ro`, `unitotem.slot=a|b`, `unitotem.ota=1|recover`, `video=...`, `plymouth.ignore-serial-consoles`.

Boot-partition files: `unitotem-ota.request` (`UNITOTEM_OTA_WIPE_DATA=0|1`, self-clearing), `unitotem-ota.authorized_keys` (one `ssh-ed25519` line, fallback login key written by `unitotem-ota-arm --authkey-file`; kept by `populate-bootfs`), `unitotem-ota.conf` (`OTA_HOST`, `OTA_CTRL_PORT`, whitelisted `UNITOTEM_*`/`OTA_*`), `unitotem-ota.failover` (guard), `tryboot.txt`, `cmdline.txt`, `config.txt`, `slota/`, `slotb/`. `grubenv` is a 1024-byte block written by `grubenv_write`. ESP `esp-grub.cfg` carries `# unitotem-grub-level: N`.

Runtime: `/run/ota-serve.log`, `/run/ota-dropbear.log`, `/run/unitotem-ota-point-of-no-return`; dropbear on 2222.

## Rules and gotchas

- GRUB `fallback` accepts entry numbers only; names are dropped. Keep entry order in step with `set fallback`; `verify-image.sh` checks `ota-recovery` is last.
- `ota-recovery` stays last: a torn grubenv makes GRUB boot entry 0.
- ESP `grub.cfg` is synced only after a confirmed boot and only when the shipped level is higher.
- Pi tryboot needs the `0 tryboot` reboot argument; a staged Pi update starts only with `unitotem-update reboot`.
- Pi dtb and overlays are copied into `slota/`, not moved: the fallback `config.txt` loads `bcm2711-rpi-4-b.dtb` from the top level.
- Pi console `ttyS0` (mini-UART) with `enable_uart=1`: Raspberry Pi DTBs alias `serial0=&uart1`. Never `serial0` (PL011, Bluetooth pins).
- A/B images do not use the boot counter; safety net is one-shot trial plus health gate.
- `/boot-ota` must be unmounted before `switch_root`, else `boot-firmware.mount` fails with EBUSY.
- After the partition table is written `fail()` never reboots: it enters serve-fallback.
- Initramfs carries: `bcm2835_wdt`, `nls_ascii`, `brcmfmac` plus the vendor modules `brcmfmac_cyw|wcc|bca` when present (from kernel 6.18 brcmfmac is split by chip vendor; the Pi 3B+/4/400/5 chip needs `cyw`, else no `wlan0`), systemd `reboot` (BusyBox cannot pass `0 tryboot`), real `dd`, `mke2fs`, `mount`, `umount`, `losetup`, `mkfifo` (`ota-hook`, `check-recovery-commands.sh`).
- Pi initramfs stays under 32 MB (firmware reads ~5 MB/s).
- Pi `cmdline.txt` changes go to both slot files; `populate-bootfs` excludes `config.txt` and `cmdline.txt`.
- `unitotem-boot-orientation set` rewrites only `panel_orientation`, keeps the mode.
- `unitotem_video` is a contract with `${unitotem_video}` in `grub-ab-entries`.
- Secure Boot: keep `BOOTX64.EFI` plain GRUB unless shim is active; copy the chain first, rename shim last.
- `ota-hook` carries no password or hash. `/etc/passwd`, `/etc/shadow` and `/root/.ssh/authorized_keys` are generated in the initramfs tmpfs at each fallback start. The fallback is independent of the image's root first-access state.
- OTA frame: drawn for 16 bpp RGB565 (Pi fallback framebuffer) and 32 bpp (KMS); geometry from `fb0` `virtual_size` and `bits_per_pixel`. `NEWT_COLORS` cannot hide the whiptail border: `ota_frame` paints the ring cells black.
- The image sets no `hdmi_enable_4kp60`: 4Kp60 on a Pi 4 needs it in `[pi4]` of `config.txt` (HDMI0 only, more heat and power).
- `promote-default` (rpi) refuses a device whose `config.txt` has `os_prefix` (A/B): it fails before writing anything. A/B promotion is `unitotem-update confirm`.
- On deployed Pi devices `config.txt` is rewritten at runtime by `ota-engine.sh` (`set-default-recovery`, `set-trial-boot`, `promote-default`); the shipped `config.txt` applies only to the built `.img`. Dtoverlay/dtparam changes go in `config-extra.txt`.
- `plymouth-theme-unitotem` (manager repository) postinst: `update-alternatives` for `default.plymouth` (priority 100), `plymouth-set-default-theme unitotem`, `update-initramfs -u`, errors ignored. An image that pins another theme by hand puts the alternative in manual mode.
- Stage 2 appends `FRAMEBUFFER=y` to `initramfs.conf`: the splash in the initramfs needs it.

## Tests

- `python3 tools/release/test_boot_orientation.py`, `test_rpi_backend.py`, `test_repair.py`, `test_secure_boot_gate.py`.
- `dash tools/release/test_overlay_status.sh`: overlay hook under dash with mocked mount, blkid, e2fsck (status states, log prefix, one-line file).
- `bash unitotem/check-recovery-commands.sh ROOTFS INITRD deploy/ota-engine.sh`.
- `unitotem/verify-image.sh`: GRUB entries, fallback numbering, Secure Boot staging, Pi slot dirs, initramfs contents.
- Firmware behaviour (`os_prefix`, tryboot) is verified on hardware only.
