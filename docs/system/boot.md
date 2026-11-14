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
| `unitotem/files/unitotem-update` | Slot switching, backends (grub/rpi), trial, confirm, rollback, ESP `grub.cfg` sync, boot recovery set sync (`sync_boot_recovery`, [Recovery set](#recovery-set)) |
| `deploy/ota-engine.sh` | All boot-partition writes, init-premount, serve-fallback, `ab_failover` |
| `unitotem/stage3-image.sh` | A/B boot layout: `slota/`, `os_prefix`, `grub-install`, `saved_entry=slot-a`, Secure Boot staging, `esp-grub.cfg`, recovery set and its manifest |
| `unitotem/slim-initramfs.py` | Pi initramfs reduction |
| `unitotem/verify-image.sh` | Boot-file assertions |

## How it works

### Raspberry Pi (arm64, `backend=rpi`)

- FIRMWARE (FAT): `config.txt`, shared firmware, `slota/` and `slotb/` (`kernel8.img`, `initramfs8`, `cmdline.txt`, dtbs, overlays), resident fallback `recovery8.img`, `recovery-initrd.img`, top-level `*.dtb`, `recovery.sha256`, `unitotem-ota.*`.
- Default: `config.txt` `os_prefix=slota/` (or `slotb/`).
- Trial: `tryboot.txt` holds the other slot's `os_prefix`; read by the firmware only on a reboot with `systemctl reboot --reboot-argument="0 tryboot"`. A plain reboot or power cut returns to the `config.txt` slot.
- Promotion: `config.txt` rewritten from `tryboot.txt` with the new `os_prefix`; `tryboot.txt` removed.
- Resident fallback: `config.txt` without `os_prefix` loads `recovery8.img` with `unitotem.ota=1`.
- Requires the EEPROM bootloader (`/proc/device-tree/chosen/bootloader`); else `backend-unsupported`. Pi 3 and Zero 2 get no A/B.

### PC (amd64, UEFI or BIOS, `backend=grub`)

- BIOS: the MBR boot code loads `core.img` from the `BIOS` partition (ef02, p5), which reads `unitotem-grub/` on the EFI partition as under UEFI. Run time: `/boot/efi` is mounted read-only; remount read-write for `grub-editenv`.

- ESP: `unitotem-grub/grub/grub.cfg`, `unitotem-grub/grub/grubenv`, `EFI/BOOT/` (the signed chain: `BOOTX64.EFI` = shim, `grubx64.efi`, `mmx64.efi`, stub `grub.cfg`), `EFI/debian/grub.cfg` (same stub), `unitotem/` (fallback kernel, initrd and `recovery.sha256`).
- Slot kernel and initrd: `/vmlinuz`, `/initrd.img` in each ROOT slot, found by `search --label ROOT_A|ROOT_B`.
- grubenv keys: `saved_entry`, `next_entry` (one-shot, cleared by GRUB), `unitotem_video`.
- Entries: 0 `slot-a`, 1 `slot-b`, 2 `slot-a-recover`, 3 `slot-b-recover`, 4 `ota-recovery`.
- Failover order: `slot-a` -> `fallback="1 4"`; `slot-b` -> `"0 4"`; else `"4"`.
- Slot kernel line: `root=LABEL=ROOT_x ro quiet splash ... unitotem.slot=x ${unitotem_video}`.

### Boot decision (initramfs, both backends)

1. `init-premount` runs `ota-engine init-premount`:
   - cmdline `unitotem.ota=1`: serve-fallback, idle 1800 s; `unitotem.ota=recover`: serve-fallback, no idle timeout.
   - `unitotem-ota.request` on FIRMWARE (Pi) or EFI (PC): read, deleted, serve-fallback (update, idle 1800 s).
   - Root from `root=LABEL=`, resolved by `slot_pick` (5 retries, `udevadm settle`): one match: that device; two on one disk: ROOT_A the lowest partition, ROOT_B the highest; matches on several disks: the first sorted. With two or more matches the other copies on the picked disk are relabelled `ROOT_STALE` (`e2label`, never a mounted device) and `ROOT='/dev/...'` is appended to `/conf/param.conf`, so mountroot uses exactly the picked device. Normal boots change nothing. Then checked by `check_root_readonly` (`e2fsck -fn`, `-fp` only if it fails).
   - Check fails or root missing: `ab_failover` (A/B), else serve-fallback (recovery, idle 21600 s).
   - Boot counter (every layout, see [Boot counter](#boot-counter)): `unitotem-ota.bootcount` incremented once the root checks pass; 3 or more gives the OTA fallback.
2. `ab_failover`: the other slot (found by `slot_pick`) must pass `e2fsck -fn` and contain `/etc/unitotem/ota-preserve.list`. Writes guard `unitotem-ota.failover` (`cur->other`), switches the default (Pi: `os_prefix`, removes `tryboot.txt`; PC: `saved_entry`), `reboot -f`. Refused when the guard exists.
3. mountroot, then local-bottom verify: `/sbin/init` and `/etc/unitotem/ota-preserve.list` must exist, else serve-fallback.
4. init-bottom: `layout_complete` (flash image: ROOT_B and DATA created), DATA `e2fsck -p`, `grow_data` (DATA grown to the disk end), overlays on `/etc`, `/root`, `/var`, dpkg pinned to ROOT. Details: `storage-and-persistence.md`.
   - Overlay outcome: `/run/unitotem-overlay.status` (initramfs, one line): `ok`; `volatile:no-data` (no DATA partition) or `volatile:data-mount` (DATA present, mount failed): `/etc`, `/root`, `/var` overlay a tmpfs, state lost at reboot, no DATA record written (see [Volatile overlays](storage-and-persistence.md#how-it-works)); `failed:overlay-etc|overlay-root|overlay-var`, `failed:dpkg-pin`, `failed:volatile` (the tmpfs or one of its overlays failed). Log lines carry the prefix `overlay: status <state>`. The DATA record is the `overlay-status=` key of `/mnt/data/.unitotem-overlay-status`, written only when DATA is used. An 8 GB card has no DATA: it runs volatile by design.
   - Not verified on hardware: fstab mounts a tmpfs on `/run` after switch_root (`fstab-amd64`, `fstab-arm64`), which may hide the initramfs file. Consumers must not rely on `/run/unitotem-overlay.status` after boot until checked; the DATA record is the post-boot source.
5. multi-user: `unitotem-boot-ok` (every boot, `TimeoutStartSec=infinity`).
   - Health gate first, on every boot except the trial of the pending slot: waits up to `UPDATE_HEALTH_TIMEOUT` (180 s) for `UPDATE_HEALTH_URL`. Healthy: boot counter cleared. Unhealthy with a counter of 1 or more, not `unitotem.maintenance=1`: reboot. Unhealthy with counter 0 or no counter file: no reboot, exit 2.
   - Plain A/B boot: slot confirmed, guard removed, ESP `grub.cfg` synced, auto-repair started.
   - Trial boot: waits for `UPDATE_HEALTH_URL` (180 s), then `confirm_now` and the counter is cleared. Timeout: `rolled-back`, plain reboot.
   - Slot mismatch: `rolled-back`, `pending.json` removed.

### OTA fallback entry

- `serve-fallback`: framebuffer progress UI, `fallback_auth_setup` (writes the login accounts and keys to the initramfs tmpfs; sources in [Fallback authentication](deploy-and-recovery.md#fallback-authentication), kernel token `unitotem.ota.authkey=`), dropbear `-p 2222` (`-T 3 -j -k`, `-B` in open mode only), idle watchdog (stands down on a successful dropbear login, see [Fallback authentication](deploy-and-recovery.md#fallback-authentication)).
- Fallback network (`configure_networking_ota`): waits up to 30 s for a physical Ethernet device (a USB adapter on Raspberry Pi 3/3B+ can appear after the engine starts), then up to 12 s for carrier, then DHCP per interface with carrier first. Without an address dropbear still starts and a background loop repeats the whole procedure every 5 s for about 35 minutes, so an adapter that appears later is configured. Measured in QEMU raspi3b (NIC driver unbound at init-premount, bound again after N s, boot counter preset to 3): the engine of image 55 (5 s wait) with N = 25 s never gets an address; the 30 s wait gets one with N = 25 s (address 27 s after init-premount) and none with N = 60 s; with the retry loop N = 60 s gets an address 2 s after the adapter appears.
- x86 recovery entry (`UniTotem OTA`): `linux /unitotem/recovery-vmlinuz unitotem.ota=1 console=tty0`.
- Deploy: `set-default-recovery` makes the fallback default; `set-trial-boot` arms the real system; `promote-default` runs after confirmation (single-root path).

| | Default | Trial (one-shot) | Promote | Failover |
|---|---|---|---|---|
| GRUB | `saved_entry` | `next_entry` | `saved_entry=X`, unset `next_entry` | `saved_entry` = other slot |
| Pi | `config.txt` `os_prefix` | `tryboot.txt`, tryboot reboot only | `config.txt` <- trial file, delete `tryboot.txt` | `config.txt` `os_prefix` |

### Recovery set

The resident fallback on the boot partition (`recovery-vmlinuz` or `recovery8.img`, `recovery-initrd.img`, `recovery.sha256`, arm64 top-level `*.dtb`) is refreshed from the running image after a confirmed boot. Sync steps, power-cut analysis and the downgrade rule: [ab-updates](ab-updates.md#recovery-set-refresh).

Image root, `/usr/share/unitotem/recovery/` (written by `stage3-image.sh`):

| File | Content |
|---|---|
| `vmlinuz` | Fallback kernel of the build |
| `initrd.img` | Fallback initramfs of the build |
| `dtb/NAME.dtb` | arm64 only: the top-level FIRMWARE dtbs |
| `manifest` | Level and sha256 of every file above |

Manifest format (exact):

```
# unitotem-recovery-level: 20261019055632
<sha256>  vmlinuz
<sha256>  initrd.img
<sha256>  dtb/bcm2711-rpi-4-b.dtb
```

- Level: the 14 digits of `UNITOTEM_RECOVERY_BUILD_DATE` (UTC, `deploy/<arch>/recovery.manifest`): `2026-10-19T05:56:32Z` -> `20261019055632`. The level changes when the recovery initrd is rebuilt (`stage1-recovery-initrd.sh`); images that carry the same set have the same level.
- Parsed only when the level line, `vmlinuz` and `initrd.img` are present, every set path is `vmlinuz`, `initrd.img` or `dtb/NAME.dtb` (fullmatch), and no path repeats. Otherwise the image has no recovery set and the sync does nothing.
- Boot partition `recovery.sha256`: the same level line, then `<sha256>  <name>` per file, names relative to the boot directory (amd64 `unitotem/`, arm64 FIRMWARE). A missing file or level line is level 0. GNU `sha256sum -c` accepts the level line as a comment.

Ownership of boot partition files:

| File | Owner | Handling |
|---|---|---|
| amd64 `unitotem/recovery-vmlinuz`, `unitotem/recovery-initrd.img`, `unitotem/recovery.sha256`; arm64 `recovery8.img`, `recovery-initrd.img`, `recovery.sha256`, top-level `*.dtb` | image | Synced after a confirmed boot when the image level is higher; `recovery.sha256` last |
| `config.txt` | device | Never synced (see below) |
| `cmdline.txt`, `tryboot.txt`, `slota/`, `slotb/` | device | Never synced. Slot directories are written by fetch, repair and apply |
| `unitotem-ota.*`, `os_prefix` (`config.txt` key) | device | Never synced |
| arm64 `start*.elf`, `fixup*.dat`, `bootcode.bin`, `overlays/` | image, via deploy | Never synced (see below) |
| amd64 `EFI/`, ESP `unitotem-grub/` | image, via deploy | Not written by the recovery sync. ESP `grub.cfg` has its own sync (`ab-updates.md`) |

Not synced, arm64 firmware: `start*.elf`, `fixup*.dat`, `bootcode.bin` and `overlays/` are read by every boot, including the normal slot, and `start4.elf` and `fixup4.dat` must match each other. A FAT cannot swap two files atomically, so a power cut between the renames could leave a Pi that does not start at all. Firmware reaches a device only through deploy. The Pi EEPROM is a separate update path and is not touched.

Not synced, `config.txt`: the runtime rewrites it whole (`set-default-recovery`, `set-trial-boot`, `promote-default`: `os_prefix`, trial state). A marked section edited by the sync would race those rewrites. Image changes to `config.txt` reach only the built `.img` and fresh deploys; device options go in `config-extra.txt` (`dtoverlay`, `dtparam`).

Readers: GRUB reads the recovery kernel and initrd only for the `ota-recovery` entry. The Pi firmware reads `recovery8.img` and the top-level dtbs only when `config.txt` has no `os_prefix`. The normal slot never opens them, so an incomplete or mixed set cannot block the normal boot.

### Plymouth and orientation

- Splash: plymouthd in the initramfs, `Theme=unitotem` (package `plymouth-theme-unitotem`, see [packaging](../manager/packaging.md)). Without `Theme=` plymouth uses `text`.
- Orientation: `video=<CONNECTOR>:panel_orientation=<value>`; `right_side_up` (right), `left_side_up` (left), `upside_down` (inverted); `normal` removes it. Pi: written to `slota/cmdline.txt` and `slotb/cmdline.txt`. PC: grubenv `unitotem_video`, appended to both slot entries.

### Secure Boot (amd64)

- Active from the first boot (decision of the user, 2026-11-14: a machine is ready for Secure Boot with no step): `EFI/BOOT/BOOTX64.EFI` is the Debian-signed shim, beside it `mmx64.efi` (MokManager) and `grubx64.efi` (Debian-signed GRUB), and the stub `grub.cfg` (`search --label EFI`, `configfile` of `unitotem-grub/grub/grub.cfg`) in `EFI/BOOT` and `EFI/debian` (the signed GRUB has a fixed prefix). No other `.efi` file is shipped: no staged copy, no plain GRUB (the `core.efi` and `grub.efi` that `grub-install` leaves in `unitotem-grub/grub/x86_64-efi/` are removed). The chain boots with and without Secure Boot.
- Stage 3: `grub-install --no-uefi-secure-boot --removable` fills `unitotem-grub/`, then the signed chain replaces the plain GRUB it wrote in `EFI/BOOT` (everything first, shim last through a temporary name); `verify-image` compares the three binaries with the signed ones of the rootfs and requires no other `.efi` on the ESP.
- The staged `shim-signed` is dual-signed with the Microsoft UEFI CA 2011 and 2023.
- Kernel (amd64): from trixie-backports, `linux-image-7.2.12+deb13-amd64` (version `7.2.12-1~bpo13+1` in the index of 2026-11-08). Its source package is `linux-signed-amd64`: the Debian-signed `linux-binary` image is what GRUB loads. The staging names no kernel version: GRUB loads `/vmlinuz` and `/initrd.img`, which are symlinks in each ROOT slot.
- NVIDIA module (amd64): signed by the DKMS key generated in the image build (signer `DKMS module signing key`). The private key is removed from the image; `mok.pub` stays. `mokutil` in the image is for MOK enrolment of that public key, which is the physical-intervention path.
- Nothing to activate: the deploy copies the ESP content as it is. `secure_boot_note` (`deploy/remote-deploy.sh`) only reports a target with Secure Boot on.
- Measured on build 2026.11.66 (amd64 flash image, QEMU/KVM, OVMF `secboot` with the Microsoft keys, 2026-11-13): as shipped by build 66 (`BOOTX64.EFI` plain GRUB, the chain only staged) the firmware refuses it; from the next build the chain is the shipped loader (see above) and the measurements below were made with the chain activated from the staged files (`BdsDxe: failed to load Boot0002 ... Access Denied -- rejected probably by Secure Boot`, no network answer). With the chain activated from the files staged on the ESP (same copy order as the engine, shim renamed last) it boots: signers `Microsoft Windows UEFI Driver Publisher` / `Microsoft Corporation UEFI CA 2011` (shim), `Debian Secure Boot Signer 2022 - grub2` (GRUB) and `... - shim` (MokManager); `/login` answers after about 30 s, `/setup` creates the administrator, the guest reports `Kernel is locked down from EFI Secure Boot`, `secureboot: Secure boot enabled`, `/sys/kernel/security/lockdown` = `[integrity]`, SecureBoot efivar 1, manager active, kernel 7.2.12+deb13-amd64. Not measured: real firmware, NVIDIA (needs the MOK enrolment of the DKMS key), firmware without the Microsoft CA. Log: `work/sb-test/b66-result.log`.
- No NVIDIA hardware, Secure Boot enforcing, 24 GB disk (the flash image is 5.9 GB; DATA and ROOT_B are laid out in the free space at the first boot), 100 s after the start: `systemctl is-system-running` = `running`, no failed unit, `unitotem-ssh-hostkey` finished with DATA on `vda4`. The NVIDIA module is refused (`systemd-modules-load: Failed to insert module 'nvidia_drm': Key was rejected by service`, a log line only: the unit stays active), `nvidia-persistenced` is inactive, `unitotem-nouveau-fallback` finishes. On a disk exactly the size of the image there is no DATA, `/mnt/data` is a directory of the read-only root and `unitotem-ssh-hostkey` fails (`mkdir: cannot create directory '/mnt/data/unitotem': Read-only file system`), state `degraded`. Log: `work/sb-test/b66-nogpu-units.log`.
- Boot through an existing NVRAM entry, no `EFI/BOOT/BOOTX64.EFI` (QEMU/OVMF `secboot`, Microsoft keys, build 66, 2026-11-14): ESP partition GUID `A6FC35F6-2F6F-414C-B790-87E1A4DB499D` (the GUID, start 2048 and size 1048576 sectors of the ESP of the field node that boots `\EFI\DEBIAN\SHIMX64.EFI`), signed chain and the stub `grub.cfg` in `EFI/debian/`; the entry created in the guest with `efibootmgr -c -d /dev/vda -p 1 -L debian -l '\EFI\debian\shimx64.efi'` reads `HD(1,GPT,a6fc35f6-2f6f-414c-b790-87e1a4db499d,0x800,0x100000)/File(\EFI\debian\shimx64.efi)`, the form the node has today. With the removable path deleted the guest boots through that entry (`BootCurrent: 0007`), kernel locked down, SecureBoot 1, state `running`, no failed unit. The engine's `restore-table` keeps the `uuid=` of the dump (`sfdisk --force`, `last-lba` stripped, tail size recomputed): measured on a scratch 111 GB image, p1 keeps GUID, start and size. Not measured: a firmware that matches the whole device path of a short-form entry after a size change. Log: `work/sb-test/n8-rehearsal.log`.
- The shipped image (build 2026.11.67, `unitotem-2026-11-14-amd64-flash.img.xz`), nothing changed between the flash image and the first boot, 24 GB disk, QEMU/OVMF (2026-11-14): the ESP holds exactly three `.efi` files, `EFI/BOOT/BOOTX64.EFI` (signer `Microsoft Windows UEFI Driver Publisher`), `grubx64.efi` and `mmx64.efi` (`Debian Secure Boot Signer 2022`). With Secure Boot enforcing (Microsoft keys): SecureBoot 1, lockdown `[integrity]`, `running`, no failed unit. With Secure Boot off: lockdown `[none]`, `running`, no failed unit. Log: `work/sb-test/default-chain.log`.

## Boot counter

File `unitotem-ota.bootcount` on the boot FAT (FIRMWARE on Pi, EFI on amd64), content `N\n`, N 0-9; any other content counts as 0. Rewritten in place (2 bytes, no allocation change). Every layout, Pi 3 included: no tryboot, GRUB or `config.txt` is involved.

- Initramfs gate (`bootcount_gate` in `ota-engine.sh`, `init-premount`, after the root checks): adds 1 per boot. At 3 or more it writes 2 and enters `serve-fallback --kind recovery --idle-timeout 21600` with reason `three consecutive boots without a healthy manager`. The legacy cmdline token `unitotem.ota.bootcount=N` starts the count from 0 on that boot.
- Health gate (`unitotem-boot-ok`, step 5 above): a healthy boot clears the counter.
- Recovery session: the fallback reboots after 6 h without a login. The count is set to 2 on entry, so exactly one normal attempt follows: if it fails, the count reaches 3 and the fallback returns.
- Login in the fallback: see [Fallback authentication](deploy-and-recovery.md#fallback-authentication).
- Power cut during the counter write: the file holds the old value, the new value or garbage. Garbage counts as 0, so recovery is delayed by at most three boots.
- Power cut during a boot counts as an unhealthy boot: three consecutive cuts before a healthy manager start the fallback.
- Not measured on hardware: `/run` (tmpfs after switch_root) may hide the overlay status file; the in-place write on a real vfat; `dd` in the initramfs.

## Interfaces

`unitotem-update` boot commands: `status`, `apply [--reboot] [--stage]`, `confirm`, `boot-ok`, `rollback [--reboot]`, `reboot`, `repair`, `cancel`. Exit and error codes: `ab-updates.md`.

`unitotem-boot-orientation`: `get [CONNECTOR]`, `set CONNECTOR normal|left|right|inverted`; JSON output; exit 0 ok, 1 failure, 2 bad arguments; error codes `no-backend`, `write-failed`. Env `UNITOTEM_BOOTFS` (`/boot/firmware`), `UNITOTEM_ESP` (`/boot/efi`), `UNITOTEM_GRUBENV`.

`deploy/ota-engine.sh` boot subcommands: `init-premount`, `serve-fallback --reason R --kind update|recovery --idle-timeout S`, `local-bottom-verify --rootmnt P`, `set-default-recovery`, `set-trial-boot`, `promote-default` (single-root only, refused on A/B), `populate-bootfs [--secure-boot shim]`, `prepare-bootfs` (options: `deploy-and-recovery.md`). Stdout markers: `UNITOTEM_TRIAL_ARMED=1`, `UNITOTEM_PROMOTED=1`, `UNITOTEM_DEFAULT_RECOVERY=1`, `UNITOTEM_SECURE_BOOT=shim`. `UNITOTEM_OTA_DEBUG=1`: failures drop to an emergency shell.

Kernel command line: `root=LABEL=ROOT_A|ROOT_B` (A/B) or `ROOT`, `rootfstype=ext4 rootwait ro`, `unitotem.slot=a|b`, `unitotem.ota=1|recover`, `video=...`, `plymouth.ignore-serial-consoles`.

Boot-partition files: `unitotem-ota.request` (`UNITOTEM_OTA_WIPE_DATA=0|1`, self-clearing), `unitotem-ota.authorized_keys` (one `ssh-ed25519` line, fallback login key written by `unitotem-ota-arm --authkey-file`; kept by `populate-bootfs`), `unitotem-ota.conf` (`OTA_HOST`, `OTA_CTRL_PORT`, whitelisted `UNITOTEM_*`/`OTA_*`), `unitotem-ota.failover` (guard), `unitotem-ota.bootcount` (`N\n`, see [Boot counter](#boot-counter)), `tryboot.txt`, `cmdline.txt`, `config.txt`, `slota/`, `slotb/`, recovery set (`recovery-vmlinuz`/`recovery8.img`, `recovery-initrd.img`, `recovery.sha256`, Pi `*.dtb`; see [Recovery set](#recovery-set)). `grubenv` is a 1024-byte block written by `grubenv_write`. ESP `esp-grub.cfg` carries `# unitotem-grub-level: N`.

Runtime: `/run/ota-serve.log`, `/run/ota-dropbear.log`, `/run/unitotem-ota-point-of-no-return`; dropbear on 2222.

## Rules and gotchas

- GRUB `fallback` accepts entry numbers only; names are dropped. Keep entry order in step with `set fallback`; `verify-image.sh` checks `ota-recovery` is last.
- `ota-recovery` stays last: a torn grubenv makes GRUB boot entry 0.
- ESP `grub.cfg` is synced only after a confirmed boot and only when the shipped level is higher.
- Boot partition recovery files follow the same rule (level compared before any read or write). Firmware and `config.txt` are never written by the sync.
- Pi tryboot needs the `0 tryboot` reboot argument; a staged Pi update starts only with `unitotem-update reboot`.
- Pi dtb and overlays are copied into `slota/`, not moved: the fallback `config.txt` loads `bcm2711-rpi-4-b.dtb` from the top level.
- Pi console `ttyS0` (mini-UART) with `enable_uart=1`: Raspberry Pi DTBs alias `serial0=&uart1`. Never `serial0` (PL011, Bluetooth pins).
- Boot counter and health gate run on every layout; on A/B the one-shot trial also guards a new slot.
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
- Duplicate slot labels: `slot_pick` picks the device; `ROOT=` in `/conf/param.conf` pins it only when the label exists more than once. Normal boots write nothing.
- amd64 GRUB `search --label ROOT_A|ROOT_B` (`grub-ab-entries`) takes the first match and is not changed by `slot_pick`. A legacy duplicate ROOT_B, created while slot B ran under the old updater, can load the kernel from the stale copy. The current updater cannot create one.

## Tests

- `python3 tools/release/test_boot_orientation.py`, `test_rpi_backend.py`, `test_repair.py`, `test_secure_boot_gate.py`, `test_boot_recovery.py`.
- `dash tools/release/test_overlay_status.sh`: overlay hook under dash with mocked mount, blkid, e2fsck (status states, log prefix, one-line file).
- `python3 tools/release/test_boot_guard.py`, `bash tools/release/test_bootcount.sh`: boot health gate and boot counter (fixtures in tmp, no device).
- `bash tools/release/test_slot_pick.sh`: `slot_pick`, `heal_dup_label`, `pin_root_dev` and the duplicate handling of `cmd_init_premount` (44 checks). `bash tools/release/test_slot_dup.sh`: privileged Docker, 548 checks, duplicate labels and interrupted repair writes ([ab-updates](ab-updates.md#slot-devices-and-repair-writes)).
- `bash unitotem/check-recovery-commands.sh ROOTFS INITRD deploy/ota-engine.sh`.
- `unitotem/verify-image.sh`: GRUB entries, fallback numbering, Secure Boot staging, Pi slot dirs, initramfs contents.
- Firmware behaviour (`os_prefix`, tryboot) is verified on hardware only.
- In the OTA fallback shell `reboot` is a link to `systemctl` that does not exist there: use `reboot -f`.
