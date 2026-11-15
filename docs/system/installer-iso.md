# Installer ISO (amd64)

Paths: relative to the repository root.

`unitotem-installer-<date>-amd64.iso`: hybrid ISO (BIOS El Torito, UEFI El Torito, raw-writable to a USB stick) that writes the amd64 flash image to a disk of the machine it boots on. Offline: the image is on the ISO.

## Files

| Path | Role |
|---|---|
| `tools/build-installer-iso.sh` | Builds the ISO from a flash image (docker `debian:trixie`; installs xorriso, grub-pc-bin, mtools, dosfstools, gdisk, cpio, initramfs-tools-core, zstd, kmod, binutils, python3) |
| `tools/slim-installer-initrd.py` | Reduces the unpacked recovery initramfs |
| `unitotem/files/unitotem-installer` | Installed as `/usr/bin/install` in the initramfs: the installation flow |
| `unitotem/files/unitotem-installer-start` | init-premount entry: network, ssh, console screen |
| `unitotem/files/unitotem-ssh` | `start` / `stop` of dropbear in open mode |
| `tools/release/test_installer_iso.py` | QEMU tests (BIOS, UEFI on USB, three disks, Secure Boot, too-small disks, screenshots) |

## How it works

Build: `tools/build-installer-iso.sh --flash deploy/amd64/unitotem-<date>-amd64-flash.img.xz [--out DIR] [--kernel F --initrd F]`. About 90 s, output `DIR/unitotem-installer-<date>-amd64.iso` + `.sha256`. Default `DIR`: `deploy/amd64`.

ISO layout (volume label `UNITOTEM_ISO`):

| Path | Content |
|---|---|
| `boot/unitotem/vmlinuz` | `unitotem/recovery-vmlinuz` of the flash image's EFI partition, checked against its `recovery.sha256` |
| `boot/unitotem/initrd.img` | The recovery initramfs of that image, reduced and repacked (one xz cpio) |
| `unitotem/<flash image>.xz`, `payload.info` | Payload and `image`, `xz_sha256`, `xz_bytes`, `raw_sha256`, `raw_bytes`, `min_disk_bytes` (read as data, every value fullmatch-validated) |
| `boot/grub/` | `grub.cfg`, BIOS modules, `eltorito.img` (cdboot + core image with iso9660, part_gpt, normal, linux, search) |
| `EFI/BOOT/` (also in the appended 24 MiB EFI partition) | `BOOTX64.EFI` = Debian-signed shim, `mmx64.efi`, `grubx64.efi` (Debian-signed GRUB), `grub.cfg` stub (`search --file /boot/grub/unitotem-iso`, `configfile /boot/grub/grub.cfg`); shim, MokManager and GRUB are the files of the image's `EFI/BOOT/` (`BOOTX64.EFI` there) |

`min_disk_bytes` = start and size of the ESP + two slots (`UNITOTEM_SLOT_SECTORS` of `unitotem-layout`) + 256 MiB. For the current image: 11,543,773,184 B (10.75 GiB, rounded). The image is 5.09 GiB raw (5,467,275,264 B); the installed system needs the `min_disk_bytes` disk, the first boot grows ROOT_A into the rest.

An ISO built before `min_disk_bytes` existed has no such key: the installer does not accept its payload and ends with `media not found changes=none` (exit 6) after about 90 s. Rebuild the ISO.

GRUB entries: `Install UniTotem` (tty1), `Install UniTotem (serial console)` (`unitotem.installer.tty=ttyS0`, 115200), `Install UniTotem (safe graphics)` (`nomodeset`); timeout 5 s. When the machine has a first serial port the menu is also shown there.

Initramfs reduction (`slim-installer-initrd.py`), measured on the build of 2026-11-10:

| Step | Size unpacked |
|---|---|
| recovery initramfs (compressed 225.6 MB) | 420.3 MB |
| firmware: only rtl_nic, tigon, e100, 3com, tehuti, kaweth, regulatory.db | 122.2 MB |
| modules: boot media, disks, USB, HID, wired NICs, Hyper-V/virtio, ext4/vfat/iso9660 and their dependencies (487 of 892), indexes rebuilt with depmod | 91.7 MB |
| programs: no partclone, parted, wpa_supplicant, plymouth, grub-install, mke2fs, e2fsck, resize2fs, dmsetup, efibootmgr, nc | 70.1 MB |
| libraries: closure of DT_NEEDED plus the ones loaded by name (libkmod, libblkid, libmount, libpam, libnss_files, libgcc_s, ...) | 79.2 MB with `hwdb.bin` (12 MB, kept) |
| installer initramfs, xz | 38.6 MB |

ISO: 1,898,881,024 bytes against 2,085,875,712 with the unreduced initramfs. The build fails when a program the installer runs is missing or one that it must not carry is present (list in the script).

Boot and screen (`unitotem-installer-start`, replaces `scripts/init-premount/zz-unitotem-ota`):

1. Network: `configure_networking_ota` of `deploy/script/ota-engine.sh` (sourced; DHCP on wired interfaces, retried for 5 minutes in the background).
2. ssh: dropbear in open mode (root without password, `-B`, port 22), as the open mode of the OTA fallback (`deploy-and-recovery.md#fallback-authentication`); `/etc/profile` prints `UniTotem installer` / `To install UniTotem run: install` for login shells.
3. Console (tty1, or the serial port with `unitotem.installer.tty=`): the OTA recovery logo (`ota_logo`, drawn by `draw_frame`, transparent spans), text `Remote install: ssh root@<ip>` per address (at most two) or `Remote install: waiting for network`, and a 72x14 whiptail dialog with the menu `Install UniTotem`, `Restart`, `Power off`. The dialog box is whiptail's own. The screen is redrawn when an address appears or the installation state changes.
4. Security: media for installation. Anyone on the network reaches a root shell without a password while the ISO runs; writing a disk still needs an explicit `y` at the confirmation, or `install --disk DEV -y`.

`install` (same flow from the menu and over ssh):

| Call | Behaviour |
|---|---|
| `install` | picker when several disks, one confirmation; needs a terminal (`ssh -t`); without one: `ERROR a terminal is required, use ssh -t changes=none`, exit 3 |
| `install --disk DEV` | no picker, confirmation kept |
| `install --disk DEV -y` | no confirmation; prints `target=<disk> model=<model> size=<GiB>`; refuses the boot media, a mounted disk, a disk smaller than `min_disk_bytes` (`ERROR disk=<disk> too small min=<bytes> changes=none`, exit 4) or not a disk (exit 4); does not restart (`reboot` follows) |
| `install --console` | what the menu runs: closes ssh first |

Exit codes: 0 done, 1 failed, 2 usage, 3 no terminal, 4 refused disk, 5 cancelled, 6 media not found, 7 installation in progress.

Flow:

1. `flock` on `/run/unitotem-installer.lock`: a second installation exits 7 (`ERROR installation in progress changes=none`). `/run/unitotem-installer.state` holds `console` or `remote`; while it is `remote` the console shows `Installation in progress (remote)` instead of the menu.
2. Started from the console menu: dropbear and every open ssh session (shells included) are ended, `INFO ssh closed reason=local install`, before any question. After `n`, an error or a cancelled picker the screen returns and ssh is started again (`INFO ssh reopened reason=install ended`).
3. Waits up to 90 s for a `UNITOTEM_ISO` iso9660 device carrying a valid `payload.info`, mounts it read-only.
4. Candidate disks: `sd*`, `hd*`, `vd*`, `xvd*`, `nvme*n*`, `mmcblk*` whole disks, not read-only, not the disk of the media. One candidate goes straight to the confirmation; several give a numbered picker (`Select the disk (1-N, q to quit)`; `(too small)` when smaller than `min_disk_bytes`; choosing such a disk prints `WARNING disk=<disk> too small min=<bytes>` and asks again).
5. Confirmation in plain console text: `target=<disk> model=<model> size=<GiB>` INFO line, the partitions the disk holds, and, in yellow, `Erase <disk> and install UniTotem? (y/n)`. Accepted: `y`, `yes`, `n`, `no`, in any case, then Enter. Anything else prints `Invalid answer, type y or n` and asks again. `n` (or end of input) prints `INFO cancelled disk=<disk> changes=none` (exit 5). The picker's `q` prints `INFO cancelled changes=none`.
6. Checking: sha256 of the xz file against `xz_sha256`. Writing: the last 1 MiB of the disk and 16 MiB after the image are zeroed (stale backup GPT and signatures), then `xz -dc | dd bs=4M conv=fsync` (`vm.dirty_bytes` 256 MiB, so `pv` follows the disk). Verifying: read-back of `raw_bytes` (cache dropped), sha256 against `raw_sha256`.
7. Nothing is activated: the image's ESP already carries the signed chain, so the written bytes are identical to the image with Secure Boot on or off.
8. `INFO install ok disk=<disk>`, `Remove the installation media, then press Enter to restart`, `reboot -f`.

The first boot of the installed disk grows ROOT_A and creates ROOT_B and DATA (`local-premount` hook `unitotem-layout`, `storage-and-persistence.md#layout`). The image carries the first-access state (no administrator yet, setup page) and an empty `/etc/machine-id`; the per-device machine id and hostname suffix are generated on that first boot.

Log: `/run/unitotem-installer.log` (initramfs), the same lines in the kernel log at debug level. Format `INFO|WARNING|ERROR text`, key=value fields (`disk=`, `bytes=`, `min=`, `changes=none`). Lines: `media <dev> disk=<disk> payload=<file> raw=<bytes>`, `writing disk=<disk> bytes=<n>`, `install ok disk=<disk>`, `ERROR media check failed|write failed|verify failed|secure boot activation failed|media not found|no disk found|installation in progress`, `WARNING disk=<disk> too small min=<bytes>`, `ERROR disk=<disk> too small min=<bytes> changes=none`.

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
- No initramfs tool ejects the media: the person removes it; a machine restarted with the media in boots the installer again, which asks before writing.
- Kernel and initramfs of the ISO are those of the flash image: a later recovery build needs a new ISO (`--kernel`/`--initrd` override them).
- Not verified: real hardware (firmware quirks, USB sticks, NVMe, 4Kn disks, disk sizes near `min_disk_bytes`), real optical media, Secure Boot on a physical machine (QEMU OVMF with Microsoft keys only), NVIDIA module under Secure Boot (needs MOK enrolment, see `boot.md`), HiDPI console font, the logo and frame on a real framebuffer (QEMU VGA only), the presence of `sort` in the built initramfs.

## Tests

`python3 tools/release/test_installer_iso.py ISO FLASH.img.xz [--scenarios bios,uefi,multi,sb,screen,small] [--work DIR] [--boot-timeout S]`: user-mode QEMU, KVM, no root. Default: all scenarios.

| Scenario | Disks | Checks |
|---|---|---|
| `bios` (serial-console entry) | one | address on the screen, ssh without password, exact welcome message, manual start closes ssh and ends the open session, `n` reopens ssh, start from ssh replaces the menu, a concurrent `install` exits 7, invalid `q` then `n` (nothing written), then `y` installs |
| `uefi` (ISO on a USB stick, default entry) | one | ssh only; boot media refused; no terminal refused; `ssh -t install` with `x` (invalid), `n` (cancel, nothing written), then `YES` accepted |
| `multi` (OVMF) | 24 GiB virtio (`/dev/vda`), 24 GiB NVMe, 8 GiB virtio (`/dev/vdb`, below the minimum) | picker lists `(too small)` for `vdb` and refuses it; `install --disk /dev/vdb -y` refused (exit 4, `too small min=`, `changes=none`); picker over ssh; `install --disk /dev/vda -y`; the other two disks untouched |
| `sb` (OVMF, Secure Boot enforcing) | one | console install; the written image boots through its own signed chain (`EFI/unitotem-sb/active` is `shim`) |
| `screen` (BIOS, default entry on tty1) | one | screenshots of the screen to `DIR/screen-*.png` |
| `small` (OVMF, USB) | one 8 GiB virtio disk | `install --disk /dev/vda -y` refused (exit 4, `too small min=`, `changes=none`); picker refuses the only disk without a question and prints `cancelled changes=none`; first MiB and sample unchanged |

Confirmation sequence checked by `bios`, `uefi`, `multi` and `sb`: an invalid answer (`x`, `q`) asks again with `Invalid answer, type y or n`; `n` cancels with `changes=none`; the question text contains no `Last chance`; `y` and `YES` start the write. The tests do not send `yes`, `no` or other cases: the accepted forms (`y`, `yes`, `n`, `no`, any case) are the code of `ask_yn`, not a tested path. Every installing scenario compares the written bytes with `xz -dc` of the image chunk by chunk, checks the zeroed regions, boots the disk alone and checks ROOT_B and DATA. Hashes of the first MiB and of a spot at 1 GiB show that refused and cancelled runs write nothing.

Disk images: `--work DIR` (sparse, removed at exit). With `ISOWIN_TMP=1` they go to `work/iso-win/isowin-iso-tmp` (named `isowin-*`, removed at exit, the folder too when empty):

```
ISOWIN_TMP=1 python3 tools/release/test_installer_iso.py <ISO> <FLASH.img.xz> --work work/iso-win/<name>
```

Sessions are logged to `DIR/serial-<scenario>-<phase>.log`.
