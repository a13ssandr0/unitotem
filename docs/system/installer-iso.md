# Installer ISO (amd64)

Paths: relative to the repository root.

`unitotem-installer-<date>-amd64.iso`: hybrid ISO (BIOS El Torito, UEFI El Torito, raw-writable to a USB stick) that writes the amd64 flash image to a disk of the machine it boots on. Offline: the image is on the ISO.

## Files

| Path | Role |
|---|---|
| `tools/build-installer-iso.sh` | Builds the ISO from a flash image (docker `debian:trixie`; installs xorriso, grub-pc-bin, mtools, dosfstools, gdisk, cpio, initramfs-tools-core, zstd, kmod, binutils, python3) |
| `tools/slim-installer-initrd.py` | Reduces the unpacked recovery initramfs |
| `unitotem/files/unitotem-installer` | Installed as `/usr/bin/install` in the initramfs: the installation flow, whiptail screens (UI mode) or text prompts (plain path) |
| `unitotem/files/unitotem-installer-start` | init-premount entry: network, ssh, console screen |
| `unitotem/files/unitotem-ssh` | `start` / `stop` of dropbear in open mode |
| `deploy/script/ota-engine.sh` | Copied into the initramfs as `/usr/lib/unitotem/ota-engine.sh`: `configure_networking_ota`, `ota_art` (the console art) |
| `unitotem/files/unitotem-boot-entry` | Installed system: names the firmware entry of the running system `UniTotem` (see [Boot entry](#boot-entry-uefi)) |
| `tools/release/test_installer_iso.py` | QEMU tests (BIOS, UEFI on USB, three disks, Secure Boot, too-small disks, screenshots) |

## Writing the stick

`sudo deploy/script/write-iso.sh [--yes] [--no-eject] ISO DEVICE` copies the whole hybrid ISO to a whole disk, reads it back and compares, then ejects a removable device. It refuses a device with mounted partitions, the disk holding `/` or `/boot`, a medium of size 0 and a device smaller than the ISO; the confirmation is `(y/n)`.

## How it works

Build: `tools/build-installer-iso.sh --flash deploy/amd64/unitotem-<date>-amd64-flash.img.xz [--out DIR] [--kernel F --initrd F]`. About 90 s, output `DIR/unitotem-installer-<date>-amd64.iso` + `.sha256`. Default `DIR`: `deploy/amd64`.

ISO layout (volume label `UNITOTEM_ISO`):

| Path | Content |
|---|---|
| `boot/unitotem/vmlinuz` | `unitotem/recovery-vmlinuz` of the flash image's EFI partition, checked against its `recovery.sha256`; Debian-signed (Secure Boot, see below) |
| `boot/unitotem/initrd.img` | The recovery initramfs of that image, reduced and repacked (one xz cpio); unsigned |
| `unitotem/<flash image>.xz`, `payload.info` | Payload and `image`, `xz_sha256`, `xz_bytes`, `raw_sha256`, `raw_bytes`, `min_disk_bytes` (read as data, every value fullmatch-validated) |
| `boot/grub/` | `grub.cfg`, `fonts/unicode.pf2`, BIOS modules, `eltorito.img` (cdboot + core image with iso9660, part_gpt, normal, linux, search) |
| `EFI/BOOT/` (also in the appended 24 MiB EFI partition) | `BOOTX64.EFI` = Microsoft-signed shim, `mmx64.efi` = MokManager, `grubx64.efi` = Debian-signed GRUB, `grub.cfg` stub (`search --file /boot/grub/unitotem-iso`, `configfile /boot/grub/grub.cfg`). The three `.efi` files are copied from the flash image's `EFI/BOOT/` |

`min_disk_bytes` = start and size of the ESP + two slots (`UNITOTEM_SLOT_SECTORS` of `unitotem-layout`) + 256 MiB. For the current image: 11,543,773,184 B (10.75 GiB, rounded). The image is 5.09 GiB raw (5,467,275,264 B); the installed system needs the `min_disk_bytes` disk, the first boot grows ROOT_A into the rest.

An ISO built before `min_disk_bytes` existed has no such key: the installer does not accept its payload and ends with `media not found changes=none` (exit 6) after about 90 s. Rebuild the ISO.

### Secure Boot of the media

The media boots with Secure Boot enforcing without any enrolment:

| File | Signature | Role |
|---|---|---|
| `EFI/BOOT/BOOTX64.EFI` | Microsoft-signed shim: signatures chain to Microsoft Corporation UEFI CA 2011 and Microsoft UEFI CA 2023 | first loader, trusted by the firmware |
| `EFI/BOOT/grubx64.efi` | Debian Secure Boot Signer 2022 - grub2 (monolithic GRUB; verifies its modules and kernel through `shim_lock`) | second loader |
| `EFI/BOOT/mmx64.efi` | Debian Secure Boot Signer 2022 - shim (MokManager) | key enrolment, not used at install time |
| `boot/unitotem/vmlinuz` | Debian Secure Boot Signer 2022 - linux | kernel, locks down under Secure Boot |
| `boot/unitotem/initrd.img` | none | loaded by the signed kernel under the `shim_lock` policy |

The three EFI files are byte-identical to the flash image's `EFI/BOOT/` (`cmp`, checked on the 2026-11-16 artifacts). The `grub.cfg` stub is specific to the ISO and differs from the image's. The image has no `EFI/unitotem-sb/` path: `verify-image.sh` asserts that it is absent. Nothing is enrolled at install time; the NVIDIA module under Secure Boot needs MOK enrolment from the console at first boot (see [boot.md#secure-boot-amd64](boot.md#secure-boot-amd64)).

Expected on a Secure Boot machine: the `SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c` variable reads value 1 (`od`: `6 0 0 0 1`); the kernel log says `Secure boot enabled` and `Kernel is locked down from EFI Secure Boot`; the lockdown mode is `[integrity]`. The `sb` scenario (OVMF with Secure Boot enforcing, Microsoft keys) asserts the variable on the live ISO and on the installed disk, and the lockdown on the installed disk; on the live ISO it asserts a kernel log line naming Secure Boot or the lockdown and prints the lockdown mode.

### GRUB entries and console screen

GRUB entries: `Install UniTotem` (tty1), `Install UniTotem (serial console)` (`unitotem.installer.tty=ttyS0`, 115200), `Install UniTotem (safe graphics)` (`nomodeset`, text mode); timeout 5 s. When the machine has a first serial port the menu is also shown there.

The two install entries call `unitotem_lowres` before the kernel line: 640x480x32 framebuffer first, then 800x600, 1024x768, auto (`gfxmode`), `gfxpayload=keep`, `unicode.pf2` loaded from `/boot/grub/fonts`. The kernel runs with `nomodeset` and the default 8x16 console font: 80x30 cells. The recipe is the one of the OTA entries (`unitotem/files/grub-ab-entries`). The serial entry appends the serial output to the menu. The safe graphics entry stays in text mode.

The console screen (`unitotem-installer-start`, tty1 only, or the serial port with `unitotem.installer.tty=`):

1. Network: `configure_networking_ota` of `deploy/script/ota-engine.sh` (sourced; DHCP on wired interfaces, retried for 5 minutes in the background).
2. ssh: dropbear in open mode (root without password, `-B`, port 22), as the open mode of the OTA fallback (`deploy-and-recovery.md#fallback-authentication`); `/etc/profile` prints `UniTotem installer` / `To install UniTotem run: install` for login shells.
3. Console: the text `Remote install: ssh root@<ip>` per address (at most two) or `Remote install: waiting for network`, and a 14-row by 72-column whiptail dialog with the menu `Install UniTotem`, `Restart`, `Power off`. The dialog box is whiptail's own. The screen is redrawn when an address appears or the installation state changes. `Install UniTotem` runs `install --console`; its dialogs are listed under `install`.
4. Art: `paint_art ROWS COLS` runs before each whiptail start (the menu and every dialog of `install`). On tty1 it starts `ota_art ROWS COLS DIALOG_ROWS DIALOG_COLS` (`deploy/script/ota-engine.sh`) in the background 0.3 s later, so whiptail has painted first. `ota_art` writes plain ASCII rows of the UniTotem name on the console text layer above the dialog. It draws only when its height plus one blank row fits above the dialog and its width fits the columns; otherwise it draws nothing. The build copies the repository's `ota-engine.sh` into the initramfs (the recovery initramfs may predate `ota_art`) and fails without `ota_art` in it.
5. Security: media for installation. Anyone on the network reaches a root shell without a password while the ISO runs; writing a disk still needs an explicit `y` at the confirmation, or `install --disk DEV -y`.

`install` (same flow from the menu and over ssh):

| Call | Behaviour |
|---|---|
| `install` | picker when several disks, one confirmation; needs a terminal (whiptail on the console, text over `ssh -t`); without one: `ERROR a terminal is required, use ssh -t changes=none`, exit 3 |
| `install --disk DEV` | no picker, confirmation kept |
| `install --disk DEV -y` | no confirmation; prints `target=<disk> model=<model> size=<GiB>`; refuses the boot media, a mounted disk, a disk smaller than `min_disk_bytes` (`ERROR disk=<disk> too small min=<bytes> changes=none`, exit 4) or not a disk (exit 4); does not restart (`reboot` follows) |
| `install --console` | what the menu runs: closes ssh first |
| `install --plain` | text screens even where the whiptail screens would run |

UI mode (whiptail screens) runs when all hold: no `-y`, no `--plain`, stdin and stdout are terminals, `TERM` is `linux`, `vt100` or `vt220`, and `whiptail` exists. The console menu meets them: tty1 (`TERM=linux`) and the serial console (`vt220`). The plain path is used otherwise: `ssh -t` (TERM `xterm`), pipes, `--plain`, `-y`.

UI mode dialogs, in order (`--backtitle 'UniTotem installer'`, width 72; the art of [Console screen](#grub-entries-and-console-screen) is drawn behind each one on tty1):

| # | Dialog | When | Answer and result |
|---|---|---|---|
| 1 | `--infobox` `Searching the installation media` | while the media is searched (up to 90 s) | none |
| 2 | `--menu` `Select the disk` | several candidate disks only; items `/dev/X` and `<size> GiB  <model>`, `(too small)` below `min_disk_bytes` | Enter picks; Cancel or Esc: `INFO cancelled changes=none`, exit 5 |
| 2a | `--msgbox` `Disk /dev/X is too small.` + `Minimum: N GiB` | a `(too small)` entry is chosen; or the only disk is too small | OK returns to the menu; with one disk the run ends, exit 5, `changes=none` |
| 3 | `--yesno` `Erase /dev/X and install UniTotem?` | every run with a target, except `-y` | default No. Yes continues; No or Esc: `INFO cancelled disk=/dev/X changes=none`, exit 5. Body: blank line, `Disk: /dev/X <size> GiB <model>`, up to four partition lines from `lsblk` (`no partitions` when there are none) |
| 4 | `--gauge`, one dialog | check, write and verify, after the confirmation | see below |
| 5 | `--msgbox` `UniTotem is installed on /dev/X.` + `Remove the installation media.` | success | OK |
| 6 | `--menu` `Installation finished` | after 5; default `Restart`, no Cancel | `Restart`: `sync`, unmount the media, `reboot -f`. `Power off`: `poweroff -f`. Shown again until one is chosen |
| 7 | `--msgbox` `Installation failed: <reason>` | check, write or verify failed | OK; exit 1, the console menu returns |

Refused before any question: `Installation media not found.` (exit 6), `No disk found.` (exit 5).

The gauge is one `--gauge` from the confirmation to the end of verify: line 1 is the stage, line 2 the target disk. Ranges from `pv -n` percentages: `Checking the media` 0-10, `Writing` 10-55, `Verifying` 55-100. It is a bash coproc (`ui_gauge_start`); its input is written as `XXX` blocks; the percentages of the write and verify pipes reach it through a second coproc. No FIFO, no `mkfifo`. It closes at the end of every run, failures included, and the console is cleared.

Plain path (text prompts):

- Picker: numbered list, `Select the disk (1-N, q to quit)`. `q` prints `INFO cancelled changes=none`, exit 5. A `(too small)` choice prints `WARNING disk=/dev/X too small min=<bytes>` and asks again.
- Confirmation: `target=<disk> model=<model> size=<GiB>` INFO line, the partitions, and, in yellow, `Erase <disk> and install UniTotem? (y/n)`. Accepted: `y`, `yes`, `n`, `no`, in any case, then Enter. Anything else prints `Invalid answer, type y or n` and asks again. `n` or end of input: `INFO cancelled disk=<disk> changes=none`, exit 5.
- Progress: `pv -pterb` when stderr is a terminal, `pv -q` otherwise. The stage lines `INFO checking the media`, `INFO writing disk=<disk>`, `INFO verifying disk=<disk>` go to stdout.
- End: `Remove the installation media, then press Enter to restart`, `reboot -f`. With `-y`: `remove the installation media, then run: reboot`, exit 0.

Exit codes: 0 done, 1 failed, 2 usage, 3 no terminal, 4 refused disk, 5 cancelled, 6 media not found, 7 installation in progress.

Flow:

1. `flock` on `/run/unitotem-installer.lock`: a second installation exits 7 (`ERROR installation in progress changes=none`). `/run/unitotem-installer.state` holds `console` or `remote`; while it is `remote` the console shows `Installation in progress (remote)` instead of the menu.
2. Started from the console menu: dropbear and every open ssh session (shells included) are ended, `INFO ssh closed reason=local install`, before any question. After `n`, an error or a cancelled picker the screen returns and ssh is started again (`INFO ssh reopened reason=install ended`).
3. Waits up to 90 s for a `UNITOTEM_ISO` iso9660 device carrying a valid `payload.info`, mounts it read-only.
4. Candidate disks: `sd*`, `hd*`, `vd*`, `xvd*`, `nvme*n*`, `mmcblk*` whole disks, not read-only, not the disk of the media. One candidate goes straight to the confirmation; several give the picker (UI mode: dialog 2; plain: numbered list). A disk below `min_disk_bytes` is marked `(too small)` and refused.
5. Confirmation: UI mode dialog 3 (default No); plain path `(y/n)` prompt. Both show the target, its size, model and partitions. Answer No or `n`: exit 5 with `changes=none`.
6. Checking: sha256 of the xz file against `xz_sha256`. Writing: the last 1 MiB of the disk and 16 MiB after the image are zeroed (stale backup GPT and signatures), then `xz -dc | dd bs=4M conv=fsync` (`vm.dirty_bytes` 256 MiB, so `pv` follows the disk). Verifying: read-back of `raw_bytes` (cache dropped), sha256 against `raw_sha256`. Progress: the gauge (UI mode) or `pv` (plain).
7. Boot entry (UEFI only, see [Boot entry](#boot-entry-uefi)). A failure here is a warning; the install succeeds.
8. `INFO install ok disk=<disk>`. UI mode: dialog 5, then the finish menu (dialog 6). Plain path: `Remove the installation media, then press Enter to restart`, `reboot -f`.

The image's ESP already carries the signed chain, so the written bytes are identical to the image with Secure Boot on or off. Nothing else is activated.

The first boot of the installed disk grows ROOT_A and creates ROOT_B and DATA (`local-premount` hook `unitotem-layout`, `storage-and-persistence.md#layout`). The image carries the first-access state (no administrator yet, setup page) and an empty `/etc/machine-id`; the per-device machine id and hostname suffix are generated on that first boot.

### Boot entry (UEFI)

`register_boot_entry` runs after the write is verified, on a UEFI machine (`/sys/firmware/efi` exists):

1. `modprobe efivarfs`, mount `efivarfs` on `/sys/firmware/efi/efivars` when not mounted.
2. `blockdev --rereadpt DISK`, `udevadm settle`: the kernel sees the table just written.
3. Deletes the firmware entries whose label is exactly `UniTotem` (`efibootmgr -B`). Other entries are never touched.
4. `efibootmgr -c -d DISK -p 1 -L UniTotem -l '\EFI\BOOT\BOOTX64.EFI'`: the entry is first in BootOrder.
5. Verifies that an entry labelled `UniTotem` exists.

The installed system's `unitotem-boot-entry` (run at boot, `boot.md`) finds this entry: same label and same loader path. It keeps the entry and changes nothing (`named`). The label is therefore one name in both places.

BIOS (no `/sys/firmware/efi`): nothing is registered, `INFO boot entry skipped reason=bios`.

Any failure in steps 1-5 logs `WARNING boot entry not created reason=efivarfs|efibootmgr|delete|create|verify` and the install still succeeds: the removable path `EFI/BOOT/BOOTX64.EFI` on the disk boots the installed system without a firmware entry.

### Installer tools in the initramfs

`efibootmgr` stays in the installer initramfs (`slim-installer-initrd.py` no longer removes it), with its libraries `libefivar.so.1` and `libefiboot.so.1`. The build checks the program and both libraries and fails without them.

Initramfs reduction (`slim-installer-initrd.py`), measured on the build of 2026-11-10:

| Step | Size unpacked |
|---|---|
| recovery initramfs (compressed 225.6 MB) | 420.3 MB |
| firmware: only rtl_nic, tigon, e100, 3com, tehuti, kaweth, regulatory.db | 122.2 MB |
| modules: boot media, disks, USB, HID, wired NICs, Hyper-V/virtio, ext4/vfat/iso9660 and their dependencies (487 of 892), indexes rebuilt with depmod | 91.7 MB |
| programs: no partclone, parted, wpa_supplicant, plymouth, grub-install, mke2fs, e2fsck, resize2fs, dmsetup, nc (efibootmgr is kept, see [Installer tools](#installer-tools-in-the-initramfs)) | 70.1 MB |
| libraries: closure of DT_NEEDED plus the ones loaded by name (libkmod, libblkid, libmount, libpam, libnss_files, libgcc_s, ...) | 79.2 MB with `hwdb.bin` (12 MB, kept) |
| installer initramfs, xz | 38.6 MB |

ISO: 1,898,881,024 bytes against 2,085,875,712 with the unreduced initramfs. The build fails when a program the installer runs is missing or one that it must not carry is present (list in the script).

Log: `/run/unitotem-installer.log` (initramfs), the same lines in the kernel log at debug level. Format `INFO|WARNING|ERROR text`, key=value fields (`disk=`, `bytes=`, `min=`, `changes=none`). Lines: `media <dev> disk=<disk> payload=<file> raw=<bytes>`, `writing disk=<disk> bytes=<n>`, `install ok disk=<disk>`, `WARNING boot entry not created reason=efivarfs|efibootmgr|delete|create|verify`, `INFO boot entry created label=UniTotem disk=<disk>`, `INFO boot entry skipped reason=bios`, `ERROR media check failed|write failed|verify failed|media not found|no disk found|installation in progress`, `WARNING disk=<disk> too small min=<bytes>`, `ERROR disk=<disk> too small min=<bytes> changes=none`.

## Design: why the ISO writes the image with dd and not the deploy engine

The installer writes the flash image with `xz -dc | dd` and reads it back. It does not use the deploy engine (`deploy/script/remote-deploy.sh`, `ota-engine.sh`), because the engine route would need:

- the image expanded into tmpfs: about 4.2 GiB of RAM (ROOT_A 3.96 GiB used + ESP 0.23 GiB), on a machine whose RAM the installer does not know;
- partclone re-encoding of ROOT_A (the engine restores partitions as partclone streams);
- about 3 MB of tools that the slim initramfs removes (partclone, e2fsck, mke2fs, resize2fs, dumpe2fs, tune2fs, parted, base64, mkfifo), plus the engine's calls to findmnt, df, mktemp and date.

The installed layout is produced by the code that any deploy and any first boot uses: the first boot creates ROOT_B and DATA and grows ROOT_A from `unitotem-layout` (`local-premount` hook in the initramfs; `storage-and-persistence.md#layout`). The ISO therefore writes only the bytes of the flash image, and nothing about the layout is decided by the installer.

## Use

- USB stick: `dd if=unitotem-installer-<date>-amd64.iso of=/dev/sdX bs=4M conv=fsync status=progress` (check the device name), or Rufus in "DD Image mode". The stick is overwritten completely.
- Optical disc: the ISO is 2 GB: a DVD.
- Boot the PC from the media (UEFI or legacy), keep the default entry.

## Rules and gotchas

- GRUB takes `prefix` from the CD device, not from the appended EFI partition: the `EFI/` tree must also be on the ISO filesystem (without it UEFI stops at a `grub>` prompt).
- `systemd-udevd` loads `libkmod` (and `libblkid`, ...) by name: a library closure from DT_NEEDED alone removes it and no module is loaded at coldplug (no disk, no CD). The keep list is in `slim-installer-initrd.py`.
- ssh sessions with a terminal need `devpts` on `/dev/pts` (mounted by `unitotem-installer-start`); dropbear accepts authentication `none` in open mode.
- Programs started from `install` close fd 9 (the lock) when they outlive it (`unitotem-ssh start 9>&-`), else dropbear keeps the lock after the run.
- `install` in the initramfs: the recovery initramfs has no coreutils `install`; the build fails if it gains one.
- `flock` is copied from the build container; the other programs come from the recovery build. `wc` and `seq` are not in the initramfs: the scripts use bash builtins. `sort` is not removed by the slim step; `ota-engine.sh` uses it only when `command -v sort` succeeds.
- The PIPESTATUS of the verify pipeline has four entries (dd, pv, sha256sum, cut), the other two stages three.
- UI mode: `pv -n` (integer percentages on stderr) drives the gauge; the stage functions keep the same pipelines and PIPESTATUS checks in both modes. whiptail reads the console through `< /dev/tty`; its choice goes to a file under `/run/unitotem-installer/`.
- The installer's `paint_art` reads the terminal size with `stty size` and runs `ota_art` detached with fd 8 closed (the gauge pipe is never inherited).
- `efibootmgr` needs `efivarfs` mounted; without it the installer warns `reason=efivarfs` and the entry is not created.
- No initramfs tool ejects the media: the person removes it; a machine restarted with the media in boots the installer again, which asks before writing.
- Kernel and initramfs of the ISO are those of the flash image: a later recovery build needs a new ISO (`--kernel`/`--initrd` override them).
- Not verified: real hardware (firmware quirks, USB sticks, NVMe, 4Kn disks, disk sizes near `min_disk_bytes`), real optical media, Secure Boot on a physical machine (QEMU OVMF with Microsoft keys only), NVIDIA module under Secure Boot (needs MOK enrolment, see `boot.md`), firmware NVRAM of real machines for the boot entry (QEMU OVMF only), the console art and the 640x480 framebuffer on a real screen (QEMU VGA only), HiDPI console font, the presence of `sort` in the built initramfs.

## Tests

`python3 tools/release/test_installer_iso.py ISO FLASH.img.xz [--scenarios bios,uefi,multi,sb,screen,small] [--work DIR] [--boot-timeout S]`: user-mode QEMU, KVM, no root. Default: all scenarios.

| Scenario | Disks | Checks |
|---|---|---|
| `bios` (serial-console entry, whiptail on ttyS0) | one | address on the screen, ssh without password, exact welcome message, manual start closes ssh and ends the open session, Esc on the confirmation reopens ssh, start from ssh replaces the menu, a concurrent `install` exits 7, Enter (default No) cancels with nothing written, then Tab and Enter install; log: `boot entry skipped reason=bios` |
| `uefi` (ISO on a USB stick, default entry) | one | ssh only; boot media refused; no terminal refused; `ssh -t install` with `x` (invalid), `n` (cancel, nothing written), then `YES` accepted; log: `boot entry created label=UniTotem`; installed disk: `efibootmgr -v` lists UniTotem on HD(1,GPT) with `\EFI\BOOT\BOOTX64.EFI`, first in BootOrder; BootCurrent is the NVRAM entry the disk booted through |
| `multi` (OVMF) | 24 GiB virtio (`/dev/vda`), 24 GiB NVMe, 8 GiB virtio (`/dev/vdb`, below the minimum) | picker lists `(too small)` for `vdb` and refuses it; `install --disk /dev/vdb -y` refused (exit 4, `too small min=`, `changes=none`); picker over ssh; `install --disk /dev/vda -y`; the other two disks untouched |
| `sb` (OVMF, Secure Boot enforcing, Microsoft keys) | one | live ISO: SecureBoot variable is 1, kernel log names Secure Boot or the lockdown (lockdown mode printed); console install by keystrokes (whiptail); log: `boot entry created label=UniTotem`; installed disk: SecureBoot variable 1, lockdown `[integrity]`, `efibootmgr -v` entry and BootCurrent as in `uefi`; the written image boots through its own signed chain |
| `screen` (BIOS, default entry on tty1) | several, one below the minimum | a screenshot per dialog through the QEMU monitor (`screendump`), to `DIR/screen-<dialog>.png`: menu, disk menu, too-small msgbox, confirm, gauge check, gauge write, result, finish; each shot checked for the blue root and the grey dialog |
| `small` (OVMF, USB) | one 8 GiB virtio disk | `install --disk /dev/vda -y` refused (exit 4, `too small min=`, `changes=none`); picker refuses the only disk without a question and prints `cancelled changes=none`; first MiB and sample unchanged |

Console scenarios (`bios`, `sb`, `screen`) drive the whiptail screens with keystrokes: Enter, Tab, arrow keys, Esc. The confirmation is a Yes/No box with default No: Enter or Esc cancels with `changes=none`; Tab then Enter selects Yes and starts the write.

ssh scenarios (`uefi`, `multi`, `small`) use the plain path. Confirmation sequence there: an invalid answer (`x`) asks again with `Invalid answer, type y or n`; `n` cancels with `changes=none`; `YES` starts the write. The tests do not send `yes`, `no` or other cases: the accepted forms (`y`, `yes`, `n`, `no`, any case) are the code of `ask_yn`, not a tested path. Every installing scenario compares the written bytes with `xz -dc` of the image chunk by chunk, checks the zeroed regions, boots the disk alone and checks ROOT_B and DATA. Hashes of the first MiB and of a spot at 1 GiB show that refused and cancelled runs write nothing.

NVRAM: the UEFI scenarios (`uefi`, `sb`, `multi`, `small`) keep the variables of each scenario in `DIR/vars-<scenario>.fd`. The first start creates the file from the OVMF template (`OVMF_VARS_4M.fd`, or `.ms.fd` for `sb`); later starts reuse it. The installed disk boots with the NVRAM that the install wrote, so the boot entry of the install is what the disk boots through. The file is removed when the scenario's last boot is checked (its label count is logged first).

Disk images: `--work DIR` (sparse, removed at exit). With `ISOWIN_TMP=1` they go to `work/iso-win/isowin-iso-tmp` (named `isowin-*`, removed at exit, the folder too when empty):

```
ISOWIN_TMP=1 python3 tools/release/test_installer_iso.py <ISO> <FLASH.img.xz> --work work/iso-win/<name>
```

Sessions are logged to `DIR/serial-<scenario>-<phase>.log`.
