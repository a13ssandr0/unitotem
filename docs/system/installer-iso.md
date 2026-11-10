# Installer ISO (amd64)

Paths: relative to the repository root.

`unitotem-installer-<date>-amd64.iso`: hybrid ISO (BIOS El Torito, UEFI El Torito, raw-writable to a USB stick) that writes the amd64 flash image to a disk of the machine it boots on. Offline: the image is on the ISO.

## Files

| Path | Role |
|---|---|
| `tools/build-installer-iso.sh` | Builds the ISO from a flash image (docker `debian:trixie`; installs xorriso, grub-pc-bin, mtools, dosfstools, gdisk, cpio) |
| `unitotem/files/unitotem-installer` | The installer; runs in the recovery initramfs (bash, whiptail, pv, xz, dd, sgdisk, blkid from `ota-hook`) |
| `tools/release/test_installer_iso.py` | QEMU tests (BIOS, UEFI, two disks, Secure Boot, screenshot) |

## How it works

Build: `tools/build-installer-iso.sh --flash work/flash-images/unitotem-<date>-amd64-flash.img.xz [--out DIR] [--kernel F --initrd F]`. About 35 s, output `DIR/unitotem-installer-<date>-amd64.iso` + `.sha256` (default `work/installer-iso`).

ISO layout (volume label `UNITOTEM_ISO`):

| Path | Content |
|---|---|
| `boot/unitotem/vmlinuz`, `initrd.img` | `unitotem/recovery-vmlinuz` and `recovery-initrd.img` of the flash image's EFI partition, checked against its `recovery.sha256` |
| `boot/unitotem/installer.img` | Second initramfs (gzip cpio) loaded after `initrd.img`: `usr/lib/unitotem/unitotem-installer` and a replacement of `scripts/init-premount/zz-unitotem-ota` that executes the installer instead of the OTA fallback |
| `unitotem/<flash image>.xz`, `payload.info` | Payload and `image`, `xz_sha256`, `xz_bytes`, `raw_sha256`, `raw_bytes` (read as data, every value fullmatch-validated) |
| `boot/grub/` | `grub.cfg`, BIOS modules, `eltorito.img` (cdboot + core image with iso9660, part_gpt, normal, linux, search) |
| `EFI/BOOT/` (also in the appended 24 MiB EFI partition) | `BOOTX64.EFI` = Debian-signed shim, `mmx64.efi`, `grubx64.efi` (Debian-signed GRUB), `grub.cfg` stub (`search --file /boot/grub/unitotem-iso`, `configfile /boot/grub/grub.cfg`); shim, MokManager and GRUB are the files of the image's `EFI/unitotem-sb/` |

GRUB entries: `Install UniTotem` (tty1), `Install UniTotem (serial console)` (`unitotem.installer.tty=ttyS0`, 115200), `Install UniTotem (safe graphics)` (`nomodeset`); timeout 5 s. When the machine has a first serial port the menu is also shown there.

Installer flow (`unitotem-installer`):

1. Waits up to 90 s for a `UNITOTEM_ISO` iso9660 device carrying `payload.info` (USB enumeration), mounts it read-only.
2. Candidate disks: `sd*`, `hd*`, `vd*`, `xvd*`, `nvme*n*`, `mmcblk*` whole disks, not read-only, not the disk of the media. One candidate goes straight to the confirmation; several give a menu (model, size; `(too small)` when smaller than the image: selecting it shows a message).
3. Confirmation: target, model, size and the partitions it holds (name, size, filesystem, label); the word `ERASE` must be typed exactly. Anything else: `Nothing was written`, back to step 2. No other path writes.
4. `Checking media`: sha256 of the xz file against `xz_sha256`.
5. `Writing`: the last 1 MiB of the disk and 16 MiB after the image are zeroed (stale backup GPT and signatures), then `xz -dc | dd bs=4M conv=fsync`; `vm.dirty_bytes` is 256 MiB so the gauge follows the disk.
6. `Verifying`: read-back of `raw_bytes` (cache dropped), sha256 against `raw_sha256`.
7. Secure Boot on (`SecureBoot` efivar, `efivarfs` mounted by the installer): the staged chain is activated on the new EFI partition with the steps of `ota-engine populate-bootfs --secure-boot shim` (chain copied first, shim renamed over `BOOTX64.EFI` last, `EFI/unitotem-sb/active`), else the installed system would not boot. Off: nothing is changed, the written bytes stay identical to the image.
8. `Installation complete`, `Remove the installation media`, restart (`reboot -f`). Failures offer start over, restart, power off.

The first boot of the installed disk creates ROOT_B and DATA and grows DATA (`storage-and-persistence.md#layout`); the disk must hold at least the image (5.5 GiB), the A/B layout needs image + 5.25 GiB.

Log: `/run/unitotem-installer.log` in the initramfs, debug lines in the kernel log (`dmesg`).

## Use

- USB stick: `dd if=unitotem-installer-<date>-amd64.iso of=/dev/sdX bs=4M conv=fsync status=progress` (check the device name), or Rufus in "DD Image mode". The stick is overwritten completely.
- Optical disc: the ISO is 2 GB: a DVD.
- Boot the PC from the media (UEFI or legacy), keep the default entry.

## Rules and gotchas

- GRUB takes `prefix` from the CD device, not from the appended EFI partition: the `EFI/` tree must also be on the ISO filesystem (without it UEFI stops at a `grub>` prompt).
- The recovery initrd is replaced at one point only (`zz-unitotem-ota`); every other script, module (MODULES=most: isofs, sr_mod, usb-storage, uas, ahci, nvme, virtio_blk, xhci/ehci) and tool comes from the recovery build. An initramfs is a sequence of cpio archives: later entries overwrite earlier ones, so the build never unpacks or repacks the 225 MB recovery initrd (it is incompressible: firmware and modules are already xz).
- `PIPESTATUS` of the verify pipeline has four entries (dd, pv, sha256sum, cut), the other two stages three.
- No initrd tool for ejecting: the person removes the media; a machine restarted with the media in boots the installer again, which asks before writing.
- Kernel and initrd of the ISO are those of the flash image: a later recovery build changes `--kernel`/`--initrd` only.
- No `wc`, `seq`, `sort` in the initrd: the script uses bash builtins.
- Not verified: real hardware (firmware quirks, USB sticks, NVMe, 4Kn disks), real optical media, Secure Boot on a physical machine (QEMU OVMF with Microsoft keys only), NVIDIA module under Secure Boot (needs MOK enrolment, see `boot.md`), HiDPI console font.

## Tests

`python3 tools/release/test_installer_iso.py ISO FLASH.img.xz [--scenarios bios,uefi,multi,sb,screen]`: user-mode QEMU, KVM, no root. Per scenario: wrong word leaves every disk byte-identical (hash of the first MiB and of a spot at 1 GiB), right word installs, the written bytes equal `xz -dc` of the image chunk by chunk, 16 MiB after the image and the last MiB are zero, the installed disk boots alone (web interface answers on a forwarded port), first boot created ROOT_B and DATA. `multi`: two disks (virtio, NVMe), the second entry of the picker. `sb`: OVMF `secboot` with Microsoft keys, ESP excluded from the compare, `EFI/unitotem-sb/active` is `shim`. Measured (image 2026-11-08, 24 GiB sparse disks on the dev PC with KVM): ISO 2.08 GB, GRUB menu 2-3 s, installer screen 7-9 s, check 4 s, write 11 s, verify 13 s, total 33-37 s, installed system web 15-25 s after boot; real media is slower (USB 2.0: about 30 MB/s, 2 reads of 1.8 GB).
