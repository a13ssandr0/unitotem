# Boot system

Paths: relative to the repository root.

Boot chain of UniTotem devices: bootloader (GRUB on PC, Raspberry Pi firmware on Pi), A/B slot choice, trial boot and promotion, initramfs OTA entry and slot failover, OTA fallback entry, splash, screen orientation, Secure Boot chain (amd64).

## Files

| Path | Role |
|---|---|
| `unitotem/files/grub-default` | `/etc/default/grub`; `GRUB_DEFAULT=saved` in A/B |
| `unitotem/files/grub-ab-entries` | `/etc/grub.d/10_unitotem_ab`: slot, recover and `ota-recovery` entries, boot picture drawing, `fallback` list |
| `unitotem/files/grub-ota-entry` | `/etc/grub.d/45_unitotem_ota`: single-root recovery entry |
| `unitotem/files/config.txt` | Pi firmware config (`[all]`, `[pi3]`, `[pi4]`, `[pi5]`) |
| `unitotem/files/config-extra.txt` | dtoverlay/dtparam/framebuffer lines; `/etc/unitotem/config-extra.txt`, appended to Pi trial and fallback configs |
| `unitotem/files/plymouthd.conf` | `Theme=unitotem`, `ShowDelay=0`, `DeviceTimeout=8` |
| `unitotem/files/unitotem-boot-orientation` | `/usr/sbin/unitotem-boot-orientation`: `video=` orientation tokens |
| `unitotem/files/ota-init-premount` | initramfs init-premount `zz-unitotem-ota` |
| `unitotem/files/ota-recovery-init-premount` | init-premount of the resident fallback initrd (always OTA) |
| `unitotem/files/ota-local-bottom-verify` | local-bottom `zz-unitotem-verify` |
| `unitotem/files/ota-hook` | initramfs-tools hook: copies the names of `ota-initrd.list`, plus the code-only cases (`/etc/group`, engine symlink, `nc`, `reboot`); no OTA password (logins are generated at run time, see [Fallback authentication](deploy-and-recovery.md#fallback-authentication)) |
| `unitotem/files/ota-initrd.list` | Names the fallback initrd carries, one directive per line; installed as `/usr/share/unitotem-ota/ota-initrd.list`, read by `ota-hook` and the native builder ([build](build.md#native-recovery-initrd)) |
| `unitotem/files/overlayfs-hook.sh` | local-premount `unitotem-layout` (grow ROOT_A, create ROOT_B and DATA before the root mount) and init-bottom `setup-overlays` (`storage-and-persistence.md`) |
| `unitotem/files/unitotem-boot-ok` | Boot confirmation (`ab-updates.md`) |
| `unitotem/files/unitotem-ota-arm` | Writes `unitotem-ota.request` on the boot FAT and reboots into OTA |
| `unitotem/files/unitotem-update` | Slot switching, backends (grub/rpi), trial, confirm, rollback, ESP `grub.cfg` sync and boot pictures (`sync_esp_assets`, `record_boot_mode`), boot recovery set sync (`sync_boot_recovery`, [Recovery set](#recovery-set)) |
| `unitotem/grub-boot-assets.py` | Build-time generator of the GRUB boot pictures (`logo`, `slot`; [Boot picture](#boot-picture-amd64)) |
| `deploy/script/ota-engine.sh` | All boot-partition writes, init-premount, serve-fallback, `ab_failover` |
| `unitotem/stage3-image.sh` | A/B boot layout: `slota/`, `os_prefix`, `grub-install`, `saved_entry=slot-a`, Secure Boot staging, `esp-grub.cfg`, per-slot boot pictures, recovery set and its manifest |
| `unitotem/slim-initramfs.py` | Pi initramfs reduction |
| `unitotem/verify-image.sh` | Boot-file assertions |

## How it works

### Raspberry Pi (arm64, `backend=rpi`)

- Partition table: MBR (DOS) on every Raspberry Pi model, primaries only: FIRMWARE (type `c`) is partition 1, ROOT_A 2, ROOT_B 3, DATA 4 ([storage](storage-and-persistence.md#layout)).
- FIRMWARE (FAT): `config.txt`, shared firmware, `slota/` and `slotb/` (`kernel8.img`, `initramfs8`, `cmdline.txt`, dtbs, overlays), resident fallback `recovery8.img`, `recovery-initrd.img`, top-level `*.dtb`, `recovery.sha256`, `unitotem-ota.*`. Built from the boot tree (`build/arm64/boot-tree/`, [Recovery set](#recovery-set)); the preboot card carries the same files.
- Default: `config.txt` `os_prefix=slota/` (or `slotb/`).
- Trial: `tryboot.txt` holds the other slot's `os_prefix`; read by the firmware only on a reboot with `systemctl reboot --reboot-argument="0 tryboot"`. A plain reboot or power cut returns to the `config.txt` slot.
- Promotion: `config.txt` rewritten from `tryboot.txt` with the new `os_prefix`; `tryboot.txt` removed.
- Resident fallback: `config.txt` without `os_prefix` loads `recovery8.img` with `unitotem.ota=1`.
- Requires the EEPROM bootloader (`/proc/device-tree/chosen/bootloader`); else the slot-switch commands exit `backend-unsupported`. Pi 3 and Zero 2 have no EEPROM bootloader: their disk has the A/B layout (image, first boot), but `unitotem-update` refuses every slot-switch command, so no update runs on them. Their trial reboot (`0 tryboot`) is not honoured by their firmware; see [deploy-and-recovery](deploy-and-recovery.md).

### PC (amd64, UEFI or BIOS, `backend=grub`)

- BIOS: the MBR boot code loads `core.img` from the `BIOS` partition (ef02, p5), which reads `unitotem-grub/` on the EFI partition as under UEFI. Run time: `/boot/efi` is mounted read-only; remount read-write for `grub-editenv`.

- ESP: `unitotem-grub/grub/grub.cfg`, `unitotem-grub/grub/grubenv`, `EFI/BOOT/` (the signed chain: `BOOTX64.EFI` = shim, `grubx64.efi`, `mmx64.efi`, stub `grub.cfg`), `EFI/debian/grub.cfg` (same stub), `unitotem/` (fallback kernel, initrd and `recovery.sha256`).
- Slot kernel and initrd: `/vmlinuz`, `/initrd.img` in each ROOT slot, found by `search --label ROOT_A|ROOT_B`.
- grubenv keys: `saved_entry`, `next_entry` (one-shot, cleared by GRUB), `unitotem_video`, `unitotem_gfx`.
- Entries: 0 `slot-a`, 1 `slot-b`, 2 `slot-a-recover`, 3 `slot-b-recover`, 4 `ota-recovery`.
- Titles: `UniTotem <version> (Slot A|B)` for the two slots, `UniTotem (Slot X, OTA recovery)` for the recover entries. The version comes from `/usr/share/unitotem/grub-version` (`set unitotem_ver="..."`, written by stage 3 beside `release-version`), sourced from each slot's filesystem by `unitotem_slot_title` while the config loads; an empty slot shows `UniTotem (Slot X)`. Ids are unchanged. `unitotem-grub-level` is 6.
- Firmware entry: `unitotem-boot-entry` (service, UEFI only, every boot) renames the `BootCurrent` entry to `UniTotem` when its file path is `\EFI\BOOT\BOOTX64.EFI` or `\EFI\debian\shimx64.efi`; only the description changes (one write after `chattr -i`), entries are never created, deleted or reordered, foreign entries are left alone. Test: `tools/release/test_boot_entry.py`.
- Failover order: `slot-a` -> `fallback="1 4"`; `slot-b` -> `"0 4"`; else `"4"`.
- Slot kernel line: `root=LABEL=ROOT_x ro quiet splash ... unitotem.slot=x ${unitotem_video} vt.global_cursor_default=0`.

### Boot picture (amd64)

- Menu hidden, 1 s timeout. GRUB draws the logo as soon as `grub.cfg` starts, before the slot-title search (about 1.6 s in QEMU/OVMF).
- The slot entry draws the same picture plus the line `Booting slot X: UniTotem <version>`, centred below the wordmark. The picture stays while kernel and initrd load, until the kernel starts (about 3.6 s in QEMU/OVMF).
- Slot entries set `gfxpayload=keep` before `linux` (Debian's GRUB disables it by default).
- Display size: GRUB cannot read the screen size and `background_image -m stretch` fills the whole screen, so each picture has the exact display size WxH. `gfxmode` stays `auto` (EDID mode, no second mode switch).
- Mode source: grubenv `unitotem_gfx` (WxH). `unitotem-update` `record_boot_mode` writes it on every confirmed boot and on `confirm`, only when it changes, from the first mode of the eDP connector when connected, else of the first connected connector in sorted name order (the preferred mode, which `auto` selects; see Several connectors).
- Logo pictures: ESP `unitotem-grub/grub/logo/<W>x<H>.png`, 17 modes, 634 KB in total. Generated at build, shipped in the image at `/usr/share/unitotem/esp-grub-assets/logo/`. `sync_esp_assets` copies them with `grub.cfg` when `unitotem-grub-level` rises, pictures first.
- Slot pictures: `/usr/share/unitotem/grub-boot/boot-<a|b>-<W>x<H>.png`, generated by stage 3 with the slot's version (one set about 810 KB).
- Generator `unitotem/grub-boot-assets.py` (`logo` and `slot` subcommands). Layout as in the Plymouth theme: wordmark width 0.601*W, centred; ring centre at 0.5179 of the wordmark width and 0.5734 of its height; text size 0.0225*W, top 0.04*W below the wordmark. Constants shared with the Plymouth theme and the Qt splash.
- Degradation: no `unitotem_gfx`, a mode without a picture, BIOS boot, or a missing file gives no picture (console as before). A missing slot picture keeps the logo only.
- Fast path: the 17-mode table (ESP logo and slot pictures above). For any other recorded mode, and when a table file is missing or damaged, `unitotem-update` generates the ESP logo and the running slot's text picture after each confirmed boot (`boot-ok` and `confirm`, after `record_boot_mode`; see Generation). The other slot's picture is generated by that slot's own image at its confirmed boot.
- Generation: kit `/usr/share/unitotem/grub-boot-tool` (`grub-boot-assets.py`, `theme/` PNGs, `NotoSans.ttf`), run with `python3 -I`. Mode validated by `boot_mode` (fullmatch, 320..7680 x 200..7680, w*h <= 8192x4320). Generation runs detached: `boot-ok` and `confirm` only check the need (`boot_pictures_needed`, no generation) and start unit `unitotem-boot-pictures` (`systemd-run`, Nice 19, idle I/O, RuntimeMaxSec 90) running `unitotem-update boot-pictures`, which takes the operation lock. While another operation holds the lock the start is skipped and the next confirmed boot retries; `boot-ok` never waits. Timeout 60 s per generator run (`UPDATE_BOOT_TOOL_TIMEOUT`). The output is checked as a complete PNG of the mode, then written through `.new` and renamed (atomic). Root is remounted rw only for the slot picture (`mount_rw`) and back to ro after; the ESP uses `bootfs_rw`.
- Failures are logged as events and never fail boot-ok.
- Deploy: `set-trial-boot --gfx` writes `unitotem_gfx` into the target grubenv, other keys kept. The value is the probe of the old running system: first connected connector, eDP preferred, valid mode only. Empty when unknown (e.g. the nomodeset fallback): an existing `unitotem_gfx` is kept, none is written.
- ISO install writes nothing (nomodeset, no modes). First boot after an ISO install has no picture; the first confirmed boot records the mode and the picture shows from the second boot.
- First boot after a deploy with a readable display has the record before the first boot, so the picture shows from the first boot. Not measured on hardware.
- Several connectors: `drm_mode` and the deploy probe prefer a connector named `eDP*`, else the first connected in sorted name order. Which output GRUB's GOP uses is not established (unverified): with different preferred modes the picture may be wrong for a boot. the amd64 test PC (DP-2 + HDMI-A-2) records DP-2's mode.
- Empty slot: the search error is drawn black on black (`color_normal=black/black` while the titles are built).
- Esc or Shift opens the menu over the picture.
- OTA entries drop the picture (`terminal_output console`, `background_image`) before `unitotem_lowres`.
- Cursor: `vt.global_cursor_default=0` hides the fbcon cursor.
- Not added: `fbcon=nodefer` (takes the framebuffer at once, the opposite of keeping it); `consoleblank` (0 by default in this kernel); `video=` and `i915.fastboot` (no handover benefit; `i915.fastboot` does not exist in 6.12).
- Slot titles: `unitotem_slot_title` clears `unitotem_ver` at each call and the titles are copied right after each call, so each slot shows its own version.
- Measured in QEMU/OVMF with virtio-gpu EDID modes, image 2026.11.69: logo visible at about 1.6 s (before: nothing drawn), text frame at about 2.6 s after the hidden 1 s timeout, picture shown until the kernel starts (about 3.6 s). The kernel and initramfs phase then blanks the framebuffer for about 2 s until Plymouth fades in; this is the efifb/fbcon handover, not GRUB.

### Boot decision (initramfs, both backends)

1. `init-premount` runs `ota-engine init-premount`:
   - cmdline `unitotem.ota=1`: serve-fallback, idle 1800 s; `unitotem.ota=recover`: serve-fallback, no idle timeout.
   - `unitotem-ota.request` on FIRMWARE (Pi) or EFI (PC): read, deleted, serve-fallback (update, idle 1800 s).
   - Root from `root=LABEL=`, resolved by `slot_pick` (5 retries, `udevadm settle`): one match: that device; two on one disk: ROOT_A the lowest partition, ROOT_B the highest; matches on several disks: the first sorted. With two or more matches the other copies on the picked disk are relabelled `ROOT_STALE` (`e2label`, never a mounted device) and `ROOT='/dev/...'` is appended to `/conf/param.conf`, so mountroot uses exactly the picked device. Normal boots change nothing. Then checked by `check_root_readonly` (`e2fsck -fn`, `-fp` only if it fails).
   - Check fails or root missing: `ab_failover` (A/B), else serve-fallback (recovery, idle 21600 s).
   - Boot counter (every layout, see [Boot counter](#boot-counter)): `unitotem-ota.bootcount` incremented once the root checks pass; 3 or more gives the OTA fallback.
2. `ab_failover`: the other slot (found by `slot_pick`) must pass `e2fsck -fn` and contain `/etc/unitotem/ota-preserve.list`. Writes guard `unitotem-ota.failover` (`cur->other`), switches the default (Pi: `os_prefix`, removes `tryboot.txt`; PC: `saved_entry`), `reboot -f`. Refused when the guard exists.
3. mountroot, then local-bottom verify: `/sbin/init` and `/etc/unitotem/ota-preserve.list` must exist, else serve-fallback.
4. init-bottom: `layout_complete` (retries what local-premount left; the first boot already grew ROOT_A and created ROOT_B and DATA in local-premount), DATA `e2fsck -p`, `grow_data` (DATA grown to the disk end), overlays on `/etc`, `/root`, `/var`, dpkg pinned to ROOT. Details: `storage-and-persistence.md`.
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
- x86 recovery entry (`UniTotem OTA`): `linux /unitotem/recovery-vmlinuz nomodeset loglevel=3 unitotem.ota=1 console=tty0 console=ttyS0,115200`. Stable id `ota-recovery`, always entry 4, last of `10_unitotem_ab`; `30_uefi-firmware` adds `uefi-firmware` after it inside an `if` (entry 5), so the numeric `fallback` lists stay valid.
- Resolution and font: every OTA entry sets `gfxmode` 640x480 first (`unitotem_lowres` in `grub-ab-entries`, `grub-ota-entry`, `99_unitotem_flash` of `remote-deploy.sh`) with `gfxpayload=keep` and `nomodeset`. No `fbcon=` option is set on any entry: the kernel's default 8x16 font gives an 80x30 console. Pi fallback: `config.txt` `hdmi_group=2 hdmi_mode=4` (DMT 640x480), no font option. The Windows templates (`grub.cfg.template`, `menu.lst.template`) set no `gfxmode`.
- Deploy: `set-default-recovery` makes the fallback default; `set-trial-boot` arms the real system; `promote-default` runs after confirmation (single-root path).

| | Default | Trial (one-shot) | Promote | Failover |
|---|---|---|---|---|
| GRUB | `saved_entry` | `next_entry` | `saved_entry=X`, unset `next_entry` | `saved_entry` = other slot |
| Pi | `config.txt` `os_prefix` | `tryboot.txt`, tryboot reboot only | `config.txt` <- trial file, delete `tryboot.txt` | `config.txt` `os_prefix` |

### Recovery set

The resident fallback on the boot partition (`recovery-vmlinuz` or `recovery8.img`, `recovery-initrd.img`, `recovery.sha256`, arm64 top-level `*.dtb`) is refreshed from the running image after a confirmed boot. Sync steps, power-cut analysis and the downgrade rule: [ab-updates](ab-updates.md#recovery-set-refresh).

arm64 source: the boot tree (`build/arm64/boot-tree/`, `unitotem/make-boot-tree.sh`). Stage 3 copies `recovery8.img` and `recovery-initrd.img` from it, so the FIRMWARE set and the preboot card carry the same bytes. The tree's initrd carries the build's `ota-engine.sh`: stage 1b already puts it there, else it is appended (a second cpio entry); `recovery.sha256` and the image set hash that file.

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

- Level: the 14 digits of `UNITOTEM_RECOVERY_BUILD_DATE` (UTC, `build/<arch>/recovery/recovery.manifest`): `2026-10-19T05:56:32Z` -> `20261019055632`. The level changes when the recovery initrd is rebuilt (`stage1-recovery-initrd.sh`); images that carry the same set have the same level.
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

Not synced, arm64 firmware: `start*.elf`, `fixup*.dat`, `bootcode.bin` and `overlays/` are read by every boot, including the normal slot, and `start4.elf` and `fixup4.dat` must match each other. A FAT cannot swap two files atomically, so a power cut between the renames could leave a Pi that does not start at all. Firmware reaches a device only through deploy. The Pi EEPROM is a separate update path and is not touched. The firmware card of the Updates page swaps them in place: [firmware.md](firmware.md).

Not synced, `config.txt`: the runtime rewrites it whole (`set-default-recovery`, `set-trial-boot`, `promote-default`: `os_prefix`, trial state). A marked section edited by the sync would race those rewrites. Image changes to `config.txt` reach only the built `.img` and fresh deploys; device options go in `config-extra.txt` (`dtoverlay`, `dtparam`).

Readers: GRUB reads the recovery kernel and initrd only for the `ota-recovery` entry. The Pi firmware reads `recovery8.img` and the top-level dtbs only when `config.txt` has no `os_prefix`. The normal slot never opens them, so an incomplete or mixed set cannot block the normal boot.

### Recovery initrd size (amd64)

The amd64 recovery initrd must stay at or under 100 MiB (104857600 bytes). GRUB 2.06 (Debian 11 legacy and Secure Boot PCs) loads the initrd into a bounded memory area: a 225 MB initrd gave `error: out of memory` on a 3.5 GB node, then the kernel panicked with `unable to mount root fs on unknown-block(0,0)` (field node, 2026-11). The kernel itself unpacked the file fine; only the bootloader failed.

- Cause: the stock plymouth hook adds every DRM module (`kernel/drivers/gpu/drm`) and their firmware (`nvidia` 153 MB, `amdgpu` 88 MB, `i915`, `xe`, `radeon`).
- Fix: the amd64 fallback runs without the plymouth hook (`assemble.py` skips it; `stage1-recovery-initrd.sh` removes it in its throwaway chroot). The fallback has no splash. Its console is the firmware framebuffer (`CONFIG_FB_EFI`, `CONFIG_FB_VESA`, `CONFIG_FRAMEBUFFER_CONSOLE` are built in; `CONFIG_DRM_SIMPLEDRM` is off) or VGA text on BIOS, which is what `nomodeset` gives anyway. arm64 keeps the hook (its console is vc4 DRM).
- Kept: network (`igc`, `e1000e`, `e1000`, `igb`, `ixgbe`, `r8169`, `tg3`, `bnx2x`, `atlantic`, USB `r8152`, `asix`, `ax88179_178a`, `cdc_ether`, `cdc_ncm`, `rndis_host`, `smsc95xx`, `lan78xx` with their firmware), storage (`ahci`, `nvme`, `usb-storage`, `sdhci`, `mmc_block`, `virtio_*`, `dm-mod`), `ext4`, `vfat`, `overlay`, USB HID. `brcmfmac` with its firmware (`brcm`, `cypress`, 18 MB) comes from `ota-initrd.list` for the Pi and stays on amd64.
- Measured (kernel 7.2.12): before 225.6 MB on disk, 420 MB unpacked; after 83.2 MB and 147 MB (Docker path, with the early CPU microcode of the stock hook) or 68.4 MB and 133 MB (native builder, no microcode).
- Guard: `build-recovery-initrd.py` and `stage1-recovery-initrd.sh` fail the build, and `verify-image.sh` fails the image, when the amd64 initrd exceeds the limit (`error: ... out of memory` named in the message). Test: `tools/release/test_native_initrd_assemble.sh`.
- The slot initramfs (`/initrd.img` of each ROOT slot) keeps the plymouth hook for the boot splash and is read by the same GRUB: see the size note under [Plymouth and orientation](#plymouth-and-orientation).

### Plymouth and orientation

- Splash: plymouthd in the initramfs, `Theme=unitotem` (package `plymouth-theme-unitotem`, see [packaging](../manager/packaging.md)). Without `Theme=` plymouth uses `text`.
- Splash text: two lines under the wordmark, Noto Sans Regular, drawn by Plymouth with `Image.Text` (plymouth-label, freetype plugin) and by the Qt splashes with PIL from the same font. Point size `PT = round(W/90)`, W the smallest screen width (1280 -> 14, 1920 -> 21, 2560 -> 28, 3840 -> 43). Pixels per em `PX = PT*96/72` (measured: label-freetype size N draws N*96/72 px per em). Line 1 (white, alpha 0.8) top = wordmark bottom + `round(1.2*PX)`. Line 2 (alpha 0.5) top = line 1 top + `round(2.0*PX)` in the theme; the Qt splash uses `1.82*PX` (calibrated: measured line-2 ink top 571 px in the Plymouth frame and 574 px in the Qt frame at 1280x800 with step 2.0; line 1 ink rows 537-550 identical in both). 48 characters maximum. Contents: see [Boot continuity](#boot-continuity-plymouth-to-viewer).
- Initramfs font and plugin: only `label-freetype.so` and its four libraries (libfreetype, libbz2, libbrotlidec, libbrotlicommon, about 1.2 MB) are carried (`plymouth-plugin` directive of `ota-initrd.list`). `label-pango` (pango, cairo, X11 libraries, about 11.7 MB uncompressed) is diverted by stage 1 (`dpkg-divert` to `label-pango.so.disabled`), so no hook copies it. The font is `NotoSans-subset.ttf` (static Regular instance, U+0020-007E, 12.6 KB, written by `plymouth/generate-assets.py --font-only` with fontTools), installed as `/usr/share/fonts/Plymouth.ttf` (the path label-freetype loads) by the `replace` directive.
- Initramfs size (zstd -19 of the main cpio, amd64 slot initramfs; baseline 159,791,298 bytes): freetype plugin with the subset font 160,387,271 (+0.6 MB, kept); pango plugin with the full variable NotoSans.ttf (2 MB) 165,224,347 (+5.4 MB, rejected). Pi (arm64), estimated from the packages, not from a built initramfs: pango variant +5.18 MB compressed; freetype variant with the full font +1.46 MB, with the 12.6 KB font about +0.5 MB. At about 5 MB/s firmware read: about +0.1 s (freetype) versus +1.0 s (pango). fontconfig needs no change.
- DRM modules in the slot initramfs: 37 DRM modules (amdgpu, i915, xe, nouveau, radeon, bochs, virtio-gpu, qxl, vmwgfx, ast, mgag200, cirrus-qemu, hyperv_drm, drm_kms_helper, ttm and others), 13.4 MB as xz, are in the uncompressed early cpio segment of the amd64 slot initrd (shipped 2026-11-17; bytes 14,774,272 to 70,418,244, after the 14.7 MB microcode segment; the zstd main segment starts at 70,418,432). The stock plymouth hook copies `kernel/drivers/gpu/drm` when `MODULES=most`, and mkinitramfs stores `*.ko.xz` files in an uncompressed cpio. Listing only the zstd segment does not show them. Not verified: which driver Plymouth uses on real GPUs (udev loads the modules by modalias; Plymouth has frame-buffer and drm renderers).
- Orientation: `video=<CONNECTOR>:panel_orientation=<value>`; `right_side_up` (right), `left_side_up` (left), `upside_down` (inverted); `normal` removes it. Pi: written to `slota/cmdline.txt` and `slotb/cmdline.txt`. PC: grubenv `unitotem_video`, appended to both slot entries.

### Boot continuity (Plymouth to viewer)

- Line 1 (slot and version): `unitotem-splash-label`, an initramfs init-premount script (`PREREQ plymouth`, listed before `zz-unitotem-ota`; source `unitotem/files/splash-label-premount`), runs `plymouth message` with `Slot A: UniTotem <version>` (`UniTotem <version>` without a slot). The slot comes from `unitotem.slot=` on `/proc/cmdline`, the version from `/usr/share/unitotem/boot-version`. That file is baked into the initramfs by the list directive `package-version unitotem /usr/share/unitotem/boot-version` (installed version of the `unitotem` package, the same source stage 3 uses for `release-version`); `verify-image.sh` compares them. The theme shows it through `Plymouth.SetDisplayMessageFunction`. Measured (VM, 250 ms sampling): the line appears in the same frame as the first wordmark frame.
- Line 2 (unit status): systemd sends the unit id (`U\x02<id>`) to Plymouth when a service, mount or swap becomes active, whatever `systemd.show_status` says (the console stays silent). `Plymouth.SetUpdateStatusFunction` strips a trailing `.service` and shows one line, replaced by each update. A status beginning `Starting ` is final: later updates are ignored (unit ids never contain a space).
- Compositor handover (`unitotem-compositor.service`): `ExecStartPre` runs `plymouth update --status="Starting compositor"`, waits 0.2 s (the theme paints on its next 50 Hz refresh), then `plymouth deactivate`. Measured in VM: the retained last frame shows "Starting compositor" (frames 22.9-23.1 s).
- `ExecStartPost` writes nothing to `/dev/fb0` or tty1: it waits for the socket, runs `output_transform.py` and runs `plymouth quit --retain-splash` (gdm and sddm do the same: the splash stays and the VT stays in graphics mode). The retained frame stays until labwc and the Qt splash paint. Measured on the amd64 test PC (Intel Iris Xe, HDMI capture, 2026-11-26): last Plymouth frame, black 0.6 s (labwc's first frame comes about 1.2 s after its process starts; its log shows `eglQueryDevicesEXT` errors), Qt splash with the pointer at the top-left, then the page.
- Qt splash (`bootsplash.py`, then `splash.py` in the viewer): same logo and caption layout; line 1 from `/proc/cmdline` and `/usr/share/unitotem/release-version`, line 2 `Starting viewer`. Constants: `CAPTION_*` in `bootsplash.py`; font `static/NotoSans.ttf` of the viewer.
- Text burst: a burst of console text (kernel errors in cyan, systemd "[ OK ] Started ..." lines) was shown for 0.4 s at the hand-over, on the amd64 test PC and in a VM. Cause: Debian's `plymouth-quit.service` runs a plain `plymouth quit` about a second after Plymouth starts, before the compositor exists; the VT goes back to text mode and the console repaints. `systemd.show_status` was already `false`. Debian's own answer for a service that takes over the screen is in gdm3 (`gdm.service.in`) and lightdm: `Conflicts=plymouth-quit.service` (and `plymouth-quit-wait.service`), `OnFailure=plymouth-quit.service`, and the service quits Plymouth itself. `unitotem-compositor.service` does the same. Measured on the amd64 test PC: with the Conflicts alone the burst is gone (no fbcon parameter, no mask); `quit --retain-splash` instead of `pkill` gives the same picture and a clean exit of plymouthd.
- `fbcon=map:99` and masking `plymouth-quit` hid the burst but are not what Debian does and cost a visible console: not used.
- Plymouth Script: `String.SubString(start, end)` takes an exclusive end index, not a length (`SubString(14, 8)` returns null; measured).

### Secure Boot (amd64)

- Active from the first boot (decision of the user, 2026-11-14: a machine is ready for Secure Boot with no step): `EFI/BOOT/BOOTX64.EFI` is the Debian-signed shim, beside it `mmx64.efi` (MokManager) and `grubx64.efi` (Debian-signed GRUB), and the stub `grub.cfg` (`search --label EFI`, `configfile` of `unitotem-grub/grub/grub.cfg`) in `EFI/BOOT` and `EFI/debian` (the signed GRUB has a fixed prefix). The loader has no alternative version on the ESP: no staged copy, no plain GRUB (the `core.efi` and `grub.efi` that `grub-install` leaves in `unitotem-grub/grub/x86_64-efi/` are removed). The rule is about the loader, not about every `.efi`: another EFI program (the capsule updater of fwupd, for instance) is a different thing and is not excluded. The chain boots with and without Secure Boot.
- Stage 3: `grub-install --no-uefi-secure-boot --removable` fills `unitotem-grub/`, then the signed chain replaces the plain GRUB it wrote in `EFI/BOOT` (everything first, shim last through a temporary name); `verify-image` compares the three binaries with the signed ones of the rootfs and requires that the build's ESP holds no other loader (the `.efi` files of the build are exactly these three).
- The staged `shim-signed` is dual-signed with the Microsoft UEFI CA 2011 and 2023.
- Kernel (amd64): from trixie-backports, `linux-image-7.2.12+deb13-amd64` (version `7.2.12-1~bpo13+1` in the index of 2026-11-08). Its source package is `linux-signed-amd64`: the Debian-signed `linux-binary` image is what GRUB loads. The staging names no kernel version: GRUB loads `/vmlinuz` and `/initrd.img`, which are symlinks in each ROOT slot.
- NVIDIA module (amd64): signed by the DKMS key generated in the image build (signer `DKMS module signing key`). The private key is removed from the image; `mok.pub` stays. `mokutil` in the image is for MOK enrolment of that public key, which is the physical-intervention path.
- Nothing to activate: the deploy copies the ESP content as it is. `secure_boot_note` (`deploy/script/remote-deploy.sh`) only reports a target with Secure Boot on.
- Measured on build 2026.11.66 (amd64 image, QEMU/KVM, OVMF `secboot` with the Microsoft keys, 2026-11-13): as shipped by build 66 (`BOOTX64.EFI` plain GRUB, the chain only staged) the firmware refuses it; from the next build the chain is the shipped loader (see above) and the measurements below were made with the chain activated from the staged files (`BdsDxe: failed to load Boot0002 ... Access Denied -- rejected probably by Secure Boot`, no network answer). With the chain activated from the files staged on the ESP (same copy order as the engine, shim renamed last) it boots: signers `Microsoft Windows UEFI Driver Publisher` / `Microsoft Corporation UEFI CA 2011` (shim), `Debian Secure Boot Signer 2022 - grub2` (GRUB) and `... - shim` (MokManager); `/login` answers after about 30 s, `/setup` creates the administrator, the guest reports `Kernel is locked down from EFI Secure Boot`, `secureboot: Secure boot enabled`, `/sys/kernel/security/lockdown` = `[integrity]`, SecureBoot efivar 1, manager active, kernel 7.2.12+deb13-amd64. Not measured: real firmware, NVIDIA (needs the MOK enrolment of the DKMS key), firmware without the Microsoft CA. Log: `work/sb-test/b66-result.log`.
- No NVIDIA hardware, Secure Boot enforcing, 24 GB disk (the image is 5.9 GB; DATA and ROOT_B are laid out in the free space at the first boot), 100 s after the start: `systemctl is-system-running` = `running`, no failed unit, `unitotem-ssh-hostkey` finished with DATA on `vda4`. The NVIDIA module is refused (`systemd-modules-load: Failed to insert module 'nvidia_drm': Key was rejected by service`, a log line only: the unit stays active), `nvidia-persistenced` is inactive, `unitotem-nouveau-fallback` finishes. On a disk exactly the size of the image there is no DATA, `/mnt/data` is a directory of the read-only root and `unitotem-ssh-hostkey` fails (`mkdir: cannot create directory '/mnt/data/unitotem': Read-only file system`), state `degraded`. Log: `work/sb-test/b66-nogpu-units.log`.
- Boot through an existing NVRAM entry, no `EFI/BOOT/BOOTX64.EFI` (QEMU/OVMF `secboot`, Microsoft keys, build 66, 2026-11-14): ESP partition GUID `A6FC35F6-2F6F-414C-B790-87E1A4DB499D` (the GUID, start 2048 and size 1048576 sectors of the ESP of the field node that boots `\EFI\DEBIAN\SHIMX64.EFI`), signed chain and the stub `grub.cfg` in `EFI/debian/`; the entry created in the guest with `efibootmgr -c -d /dev/vda -p 1 -L debian -l '\EFI\debian\shimx64.efi'` reads `HD(1,GPT,a6fc35f6-2f6f-414c-b790-87e1a4db499d,0x800,0x100000)/File(\EFI\debian\shimx64.efi)`, the form the node has today. With the removable path deleted the guest boots through that entry (`BootCurrent: 0007`), kernel locked down, SecureBoot 1, state `running`, no failed unit. The engine's `restore-table` keeps the `uuid=` of the dump (`sfdisk --force`, `last-lba` stripped, tail size recomputed): measured on a scratch 111 GB image, p1 keeps GUID, start and size. Not measured: a firmware that matches the whole device path of a short-form entry after a size change. Log: `work/sb-test/n8-rehearsal.log`. Repeated on the shipped image of build 2026.11.67 (chain in `EFI/BOOT`, copied to `EFI/debian` for the entry, `EFI/BOOT/BOOTX64.EFI` then removed): same result, `BootCurrent: 0007`, `running`, no failed unit (`work/sb-test/n8-rehearsal-b67.log`).
- The shipped image (build 2026.11.67, file `unitotem-2026-11-14-amd64-flash.img.xz`, the name before the single-file model), nothing changed between the image and the first boot, 24 GB disk, QEMU/OVMF (2026-11-14): the ESP holds exactly three `.efi` files, `EFI/BOOT/BOOTX64.EFI` (signer `Microsoft Windows UEFI Driver Publisher`), `grubx64.efi` and `mmx64.efi` (`Debian Secure Boot Signer 2022`). With Secure Boot enforcing (Microsoft keys): SecureBoot 1, lockdown `[integrity]`, `running`, no failed unit. With Secure Boot off: lockdown `[none]`, `running`, no failed unit. Log: `work/sb-test/default-chain.log`.
- Real firmware (the the amd64 test PC: American Megatrends International 1.0S, 05/11/2024, board AHBNB, UEFI, NVMe, ESP 1 GiB; Microsoft keys in db and KEK; image 2026.11.53 with the chain installed by hand from its staged copies, 2026-11-14): Secure Boot on in Standard mode with the factory keys boots through `EFI/BOOT/BOOTX64.EFI` (hash equal to the signed shim), kernel 7.2.12 locked down (`[integrity]`), `running`, no failed unit, no NVIDIA device. An NVRAM entry `HD(1,GPT,<ESP GUID>,0x800,0x200000)/File(\EFI\debian\shimx64.efi)` created with `efibootmgr -c` boots under Secure Boot (`BootCurrent` = the entry, with `BootNext`; without it the firmware moved the new entry behind `UEFI OS` in `BootOrder` and rewrote its path in 8.3 capitals). The same entry with the size field of the HD node halved (`0x100000`) also boots: this firmware matches the partition by GUID, the size is not compared. The firmware also created by itself an entry `debian` for `EFI/debian/shimx64.efi` as soon as the file existed on the ESP (removed again with the test files). Not measured: the text of the firmware's "security violation" screen, other firmware (the .8 is an Intel NUC), NVIDIA.

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

`deploy/script/ota-engine.sh` boot subcommands: `init-premount`, `serve-fallback --reason R --kind update|recovery --idle-timeout S`, `local-bottom-verify --rootmnt P`, `set-default-recovery`, `set-trial-boot`, `promote-default` (single-root only, refused on A/B), `populate-bootfs [--secure-boot shim]`, `prepare-bootfs` (options: `deploy-and-recovery.md`). Stdout markers: `UNITOTEM_TRIAL_ARMED=1`, `UNITOTEM_PROMOTED=1`, `UNITOTEM_DEFAULT_RECOVERY=1`, `UNITOTEM_SECURE_BOOT=shim`. `UNITOTEM_OTA_DEBUG=1`: failures drop to an emergency shell.

Kernel command line: `root=LABEL=ROOT_A|ROOT_B` (A/B) or `ROOT`, `rootfstype=ext4 rootwait ro`, `unitotem.slot=a|b`, `unitotem.ota=1|recover`, `video=...`, `plymouth.ignore-serial-consoles`.

Early splash (amd64): the slot entries and `GRUB_CMDLINE_LINUX_DEFAULT` carry `plymouth.ignore-serial-consoles`. With `console=ttyS0` on the command line Plymouth otherwise forces the text (details) plugin and the unitotem theme is not drawn; measured in QEMU (bochs-drm, direct kernel boot, 16 GB disk): text on screen 3.9-6.2 s and wordmark at 7.3 s without the option, wordmark from 3.1 s with it. `console=ttyS0` stays last so the serial console keeps the kernel log. GRUB level 5 delivers the change to devices. Not verifiable without the hardware: the efifb to i915 handoff on a real panel. Initramfs size (firmware included, about 225 MB zstd) delays the first frame because GRUB reads it before the kernel starts. The slot initramfs is not reduced like the recovery one and may exceed what GRUB 2.06 loads on old PCs ([Recovery initrd size](#recovery-initrd-size-amd64)). Splash text and the Plymouth-to-viewer handover: [Plymouth and orientation](#plymouth-and-orientation), [Boot continuity](#boot-continuity-plymouth-to-viewer). Recommended, not applied: `fbcon=map:99` on the slot entries and the Pi slot `cmdline.txt` (measured, see Boot continuity).

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
- Initramfs carries: `bcm2835_wdt`, `nls_ascii`, `brcmfmac` plus the vendor modules `brcmfmac_cyw|wcc|bca` when present (from kernel 6.18 brcmfmac is split by chip vendor; the Pi 3B+/4/400/5 chip needs `cyw`, else no `wlan0`), systemd `reboot` (BusyBox cannot pass `0 tryboot`), real `dd`, `mke2fs`, `mount`, `umount`, `losetup`, `mkfifo` (the `ota-initrd.list` directives `real` and `module`, see [build](build.md#native-recovery-initrd); `check-recovery-commands.sh`). Built by `ota-hook` (`NATIVE_INITRD=0`, Docker) or by the native builder (`NATIVE_INITRD=1`): same names, different image bytes.
- Pi initramfs stays under 32 MB (firmware reads ~5 MB/s).
- Pi `cmdline.txt` changes go to both slot files; `populate-bootfs` excludes `config.txt` and `cmdline.txt`.
- `unitotem-boot-orientation set` rewrites only `panel_orientation`, keeps the mode.
- `unitotem_video` is a contract with `${unitotem_video}` in `grub-ab-entries`.
- Secure Boot: keep `BOOTX64.EFI` plain GRUB unless shim is active; copy the chain first, rename shim last.
- `ota-hook` carries no password or hash. `/etc/passwd`, `/etc/shadow` and `/root/.ssh/authorized_keys` are generated in the initramfs tmpfs at each fallback start. The fallback is independent of the image's root first-access state.
- Fallback colours: whiptail needs a terminfo entry; Debian 13 keeps it in `/usr/share/terminfo`, so the `terminfo` directive of `ota-initrd.list` copies `l/linux`, `v/vt220`, `v/vt100` from there (older releases: `/lib/terminfo`) to `/usr/share/terminfo` of the initramfs and the engine runs whiptail with `TERMINFO=/usr/share/terminfo`. Without the entry the screen was mono with `+---+` borders (found 2026-11-15: the hook looked only in `/lib/terminfo`). `verify-image.sh` checks the entry in the recovery initrd.
- Fallback progress screen: the whiptail gauge starts before the network (`ota_ui_start` at the top of `serve-fallback`; no separate splash). The header lives in `/run/unitotem-ota.header` (title, reason, address; `ota_header_address` fills the address in once known); the phase line and the gauge follow the bring-up through `ota_phase TEXT [PERCENT]`: Starting the network, Waiting for a network device (Ns), Waiting for the cable on IFACE (Ns), Bringing up IFACE, Joining the Wi-Fi network SSID, Requesting an address on IFACE (DHCP), Setting the address ADDR on IFACE, No address on IFACE trying the next interface, then `Waiting for commands over SSH...`. All of it works from `$(...)` subshells because the state is in files under `/run`.
- OTA name art: `ota_art` (ota-engine.sh) writes the ASCII name UniTotem (figlet 'standard', plain ASCII, here-doc in the engine) on the console text layer 2 s after whiptail starts, above the dialog. No pixels, no blobs. Bold white on blue (`1;37;44`), cursor saved and restored. Newt centres the 72x14 dialog: top row (0-based) = (rows - 14) / 2; the art is drawn only if its 5 rows plus one blank row fit above that row and its width fits the columns, centred horizontally and vertically in the free rows. Smaller consoles get no art. Persistence (QEMU, recovery kernel, 640x480 and 1280x800): the art stays while the gauge runs 0 to 100 and the header is rewritten, because newt repaints only when whiptail starts. whiptail draws its own frame (box-drawing characters).
- The image sets no `hdmi_enable_4kp60`: 4Kp60 on a Pi 4 needs it in `[pi4]` of `config.txt` (HDMI0 only, more heat and power).
- `promote-default` (rpi) refuses a device whose `config.txt` has `os_prefix` (A/B): it fails before writing anything. A/B promotion is `unitotem-update confirm`.
- On deployed Pi devices `config.txt` is rewritten at runtime by `ota-engine.sh` (`set-default-recovery`, `set-trial-boot`, `promote-default`); the shipped `config.txt` applies only to the built `.img`. Dtoverlay/dtparam changes go in `config-extra.txt`.
- `plymouth-theme-unitotem` (manager repository) postinst: `update-alternatives` for `default.plymouth` (priority 100), `plymouth-set-default-theme unitotem`, `update-initramfs -u`, errors ignored. An image that pins another theme by hand puts the alternative in manual mode.
- Stage 2 appends `FRAMEBUFFER=y` to `initramfs.conf`: the splash in the initramfs needs it.
- Duplicate slot labels: `slot_pick` picks the device; `ROOT=` in `/conf/param.conf` pins it only when the label exists more than once. Normal boots write nothing.
- Boot picture files are keyed by exact display size: a new size needs an entry in `MODES` of `grub-boot-assets.py` and a `unitotem-grub-level` bump, else its devices get no picture.
- amd64 GRUB `search --label ROOT_A|ROOT_B` (`grub-ab-entries`) takes the first match and is not changed by `slot_pick`. A legacy duplicate ROOT_B, created while slot B ran under the old updater, can load the kernel from the stale copy. The current updater cannot create one.

## Tests

- `python3 tools/release/test_boot_orientation.py`, `test_rpi_backend.py`, `test_repair.py`, `test_secure_boot_gate.py`, `test_boot_recovery.py`.
- `dash tools/release/test_overlay_status.sh`: overlay hook under dash with mocked mount, blkid, e2fsck (status states, log prefix, one-line file).
- `python3 tools/release/test_boot_guard.py`, `bash tools/release/test_bootcount.sh`: boot health gate and boot counter (fixtures in tmp, no device).
- `bash tools/release/test_slot_pick.sh`: `slot_pick`, `heal_dup_label`, `pin_root_dev` and the duplicate handling of `cmd_init_premount` (44 checks). `bash tools/release/test_slot_dup.sh`: privileged Docker, 548 checks, duplicate labels and interrupted repair writes ([ab-updates](ab-updates.md#slot-devices-and-repair-writes)).
- `bash unitotem/check-recovery-commands.sh ROOTFS INITRD deploy/script/ota-engine.sh`.
- `unitotem/verify-image.sh`: GRUB entries, fallback numbering, Secure Boot staging, Pi slot dirs, initramfs contents.
- Firmware behaviour (`os_prefix`, tryboot) is verified on hardware only.
- In the OTA fallback shell `reboot` is a link to `systemctl` that does not exist there: use `reboot -f`.
