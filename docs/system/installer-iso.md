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
| `tools/release/test_installer_iso.py` | QEMU tests (BIOS, UEFI on USB, two disks, Secure Boot, screenshots) |

## How it works

Build: `tools/build-installer-iso.sh --flash work/flash-images/unitotem-<date>-amd64-flash.img.xz [--out DIR] [--kernel F --initrd F]`. About 90 s, output `DIR/unitotem-installer-<date>-amd64.iso` + `.sha256` (default `work/installer-iso`).

ISO layout (volume label `UNITOTEM_ISO`):

| Path | Content |
|---|---|
| `boot/unitotem/vmlinuz` | `unitotem/recovery-vmlinuz` of the flash image's EFI partition, checked against its `recovery.sha256` |
| `boot/unitotem/initrd.img` | The recovery initramfs of that image, reduced and repacked (one xz cpio) |
| `unitotem/<flash image>.xz`, `payload.info` | Payload and `image`, `xz_sha256`, `xz_bytes`, `raw_sha256`, `raw_bytes` (read as data, every value fullmatch-validated) |
| `boot/grub/` | `grub.cfg`, BIOS modules, `eltorito.img` (cdboot + core image with iso9660, part_gpt, normal, linux, search) |
| `EFI/BOOT/` (also in the appended 24 MiB EFI partition) | `BOOTX64.EFI` = Debian-signed shim, `mmx64.efi`, `grubx64.efi` (Debian-signed GRUB), `grub.cfg` stub (`search --file /boot/grub/unitotem-iso`, `configfile /boot/grub/grub.cfg`); shim, MokManager and GRUB are the files of the image's `EFI/unitotem-sb/` |

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

1. Network: `configure_networking_ota` of `deploy/ota-engine.sh` (sourced; DHCP on wired interfaces, retried for 5 minutes in the background).
2. ssh: dropbear in open mode (root without password, `-B`, port 22), as the open mode of the OTA fallback (`deploy-and-recovery.md#fallback-authentication`); `/etc/profile` prints `UniTotem installer` / `To install UniTotem run: install` for login shells.
3. Console (tty1, or the serial port with `unitotem.installer.tty=`): the OTA recovery look (logo, rounded frame, 72x14 whiptail dialog), text `Remote install: ssh root@<ip>` per address (at most two) or `Remote install: waiting for network`, menu `Install UniTotem`, `Restart`, `Power off`. The screen is redrawn when an address appears or the installation state changes.
4. Security: media for installation. Anyone on the network reaches a root shell without a password while the ISO runs; writing a disk still needs both answers `y` or an explicit `install --disk DEV -y`.

`install` (same flow from the menu and over ssh):

| Call | Behaviour |
|---|---|
| `install` | picker when several disks, two questions; needs a terminal (`ssh -t`); without one: `ERROR a terminal is required, use ssh -t changes=none`, exit 3 |
| `install --disk DEV` | no picker, questions kept |
| `install --disk DEV -y` | no questions; prints `target=<disk> model=<model> size=<GiB>`; refuses the boot media, a mounted disk, a disk that is too small or not a disk (exit 4); does not restart (`reboot` follows) |
| `install --console` | what the menu runs: closes ssh first |

Exit codes: 0 done, 1 failed, 2 usage, 3 no terminal, 4 refused disk, 5 cancelled, 6 media not found, 7 installation in progress.

Flow:

1. `flock` on `/run/unitotem-installer.lock`: a second installation exits 7 (`ERROR installation in progress changes=none`). `/run/unitotem-installer.state` holds `console` or `remote`; while it is `remote` the console shows `Installation in progress (remote)` instead of the menu.
2. Started from the console menu: dropbear and every open ssh session (shells included) are ended, `INFO ssh closed reason=local install`, before any question. After `n`, an error or a cancelled picker the screen returns and ssh is started again (`INFO ssh reopened reason=install ended`).
3. Waits up to 90 s for a `UNITOTEM_ISO` iso9660 device carrying `payload.info`, mounts it read-only.
4. Candidate disks: `sd*`, `hd*`, `vd*`, `xvd*`, `nvme*n*`, `mmcblk*` whole disks, not read-only, not the disk of the media. One candidate goes straight to the questions; several give a numbered picker (`Select the disk (1-N, q to quit)`; `(too small)` when smaller than the image).
5. Questions in plain console text: `target=<disk> model=<model> size=<GiB>` INFO line, the partitions the disk holds, `Erase <disk> and install UniTotem? (y/n)` and, in yellow, `Last chance: erase this disk? (y/n)`. Only `y` or `n` plus Enter; anything else prints `Invalid answer, type y or n` and asks again. `n` (or end of input) prints `INFO cancelled disk=<disk> changes=none`.
6. Checking: sha256 of the xz file against `xz_sha256`. Writing: the last 1 MiB of the disk and 16 MiB after the image are zeroed (stale backup GPT and signatures), then `xz -dc | dd bs=4M conv=fsync` (`vm.dirty_bytes` 256 MiB, so `pv` follows the disk). Verifying: read-back of `raw_bytes` (cache dropped), sha256 against `raw_sha256`.
7. Secure Boot on (`SecureBoot` efivar, `efivarfs` mounted by the installer): the staged chain is activated on the new EFI partition with the steps of `ota-engine populate-bootfs --secure-boot shim` (chain first, shim renamed over `BOOTX64.EFI` last, `EFI/unitotem-sb/active`), else the installed system would not boot. Off: the written bytes stay identical to the image.
8. `INFO install ok disk=<disk>`, `Remove the installation media, then press Enter to restart`, `reboot -f`.

The first boot of the installed disk creates ROOT_B and DATA and grows DATA (`storage-and-persistence.md#layout`); the disk must hold at least the image (5.5 GiB), the A/B layout needs image + 5.25 GiB.

Log: `/run/unitotem-installer.log` (initramfs), the same lines in the kernel log at debug level. Format `INFO|WARNING|ERROR text`, key=value fields (`disk=`, `bytes=`, `changes=none`). Lines: `media <dev> disk=<disk> payload=<file> raw=<bytes>`, `writing disk=<disk> bytes=<n>`, `install ok disk=<disk>`, `ERROR media check failed|write failed|verify failed|secure boot activation failed|media not found|no disk found|installation in progress`, `WARNING disk=<disk> too small`.

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
- `flock` is copied from the build container; the other programs come from the recovery build. `wc`, `seq`, `sort` are not in the initramfs: the scripts use bash builtins.
- The PIPESTATUS of the verify pipeline has four entries (dd, pv, sha256sum, cut), the other two stages three.
- No initramfs tool ejects the media: the person removes it; a machine restarted with the media in boots the installer again, which asks before writing.
- Kernel and initramfs of the ISO are those of the flash image: a later recovery build needs a new ISO (`--kernel`/`--initrd` override them).
- Not verified: real hardware (firmware quirks, USB sticks, NVMe, 4Kn disks), real optical media, Secure Boot on a physical machine (QEMU OVMF with Microsoft keys only), NVIDIA module under Secure Boot (needs MOK enrolment, see `boot.md`), HiDPI console font, the logo and frame on a real framebuffer (QEMU VGA only).

## Tests

`python3 tools/release/test_installer_iso.py ISO FLASH.img.xz [--scenarios bios,uefi,multi,sb,screen] [--boot-timeout S]`: user-mode QEMU, KVM, no root. `bios` (serial-console entry): address on the screen, ssh without password, exact welcome message, manual start closes ssh and ends the open session, `n` reopens ssh, start from ssh replaces the menu, a concurrent `install` exits 7, `y`,`y` installs. `uefi` (ISO on a USB stick, default entry, ssh only): boot media refused, no terminal refused, `ssh -t install` with `x`, `Y`, `yes`, `n`, then `y`,`y`. `multi` (virtio + NVMe): picker over ssh, `install --disk /dev/vda -y`, the other disk untouched. `sb` (OVMF secboot, Microsoft keys): console install, `EFI/unitotem-sb/active` is `shim`. `screen`: screenshots of tty1. Every installing scenario compares the written bytes with `xz -dc` of the image chunk by chunk, checks the zeroed regions, boots the disk alone and checks ROOT_B and DATA. Hashes of the first MiB and of a spot at 1 GiB prove that `n` writes nothing.
