# Installer ISO and Windows-source research

Paths: relative to the repository root.

Hybrid (BIOS + UEFI) live ISO that installs UniTotem on amd64 PCs through a text TUI, plus research on booting the OTA environment from a running Windows 11.

## Files

- `build-iso.sh`: host entry point; builds the builder image, runs it, output in `deploy/`.
- `Dockerfile.iso`: builder (`debian:bookworm`); copies `iso/` to `/iso-src/` and `unitotem/files/` to `/iso-src/unitotem-files/`; `VOLUME /deploy`.
- `iso/build-live.sh`: inside the builder; live root, squashfs, ISOLINUX and GRUB menus, hybrid ISO.
- `iso/installer.sh`: TUI installer, shipped as `/usr/local/bin/unitotem-installer.sh`.
- [windows-install-research.md](windows-install-research.md): Windows-source install research.
- `tools/win-lab/`: Windows VM lab (`README.md`, `lab.sh`, `winkeys.py`, `gcmd.sh`, `serialcap.sh`, `probe-windows.ps1`, `nvram-var.ps1`, `recover-driver.sh`).

## How it works

### ISO build

- `build-iso.sh` needs Docker (`${DOCKER:-docker} info`), builds `unitotem-iso-builder` (context = repo root), runs it `--rm --privileged` with `deploy/` at `/deploy`.
- Output `deploy/unitotem-installer-YYYY-MM-DD-amd64.iso`, volume label `UNITOTEM_INSTALLER`.

### Live system (`iso/build-live.sh`)

1. `debootstrap` bookworm amd64 into `/tmp/live-root` (systemd, live-boot, initramfs-tools).
2. chroot install: `linux-image-amd64`, live-config, whiptail, parted, gdisk, mkfs tools, curl, iw, wpasupplicant, dhcpcd5, kbd. `policy-rc.d` returns 101 during install.
3. Live config: root autologin on tty1; `unitotem-installer.service` (oneshot, tty1); `unitotem/files/` at `/usr/local/share/unitotem/files/`; hostname `unitotem-installer`.
4. `mksquashfs` (xz, x86 BCJ) to `live/filesystem.squashfs`; `live/vmlinuz`, `live/initrd.img`.
5. BIOS: ISOLINUX + `menu.c32`; labels `install` and `install-debug`.
6. UEFI: `grub-mkstandalone -O x86_64-efi` with an embedded stub (`search --no-floppy --file /live/vmlinuz`, then `boot/grub/grub.cfg`); FAT image `boot/grub/efiboot.img` as El Torito alt boot; same binary at `EFI/boot/bootx64.efi`.
7. `xorriso -as mkisofs` hybrid image, MBR from `isohdpfx.bin`.

### Installer (`iso/installer.sh`)

- Boot mode from `/sys/firmware/efi`.
- Questions (whiptail; cancel exits 0): language (12 locales), keyboard (12 layouts, `loadkeys` at once), timezone (23 zones), network (interface; wired DHCP or static; Wi-Fi scan with `iw`, WPA via `wpa_supplicant` + `dhcpcd`; loops until `ping 8.8.8.8` works), target disk (`lsblk -d`, loop/sr/fd/ram excluded, destructive warning), hostname (default `unitotem`), root password (twice), summary.
- Installation: partition (`wipefs`, `sgdisk`), format, mount at `/mnt`, `debootstrap` bookworm, APT sources and UniTotem Manager repository, kernel/firmware/GRUB, base packages, Xorg/PipeWire/Chromium/ffmpeg, `unitotem-manager` from apt, configuration (hostname, locale, keymap, timezone, sshd, fstab, netplan, plymouth, GRUB, kiosk flags, maintenance tool, `start-xorg` unit, overlay hook, firewall, journald, scheduler rules, sysctl, services, `update-initramfs -u -k all`), bootloader.
- Bootloader: UEFI `grub-install --target=x86_64-efi --removable --no-nvram --bootloader-id=unitotem`; BIOS `grub-install --target=i386-pc DISK`; `update-grub`.
- `cleanup` trap unmounts `/mnt`. End: remove media, ENTER runs `reboot`.

Disk layout (single-root, not A/B):

| # | UEFI | BIOS |
|---|---|---|
| 1 | EFI 512M FAT32 (ef00) | BIOS_BOOT 1M (ef02) |
| 2 | BOOT 1G ext4 | BOOT 1G ext4 |
| 3 | ROOT 10G ext4 | ROOT 10G ext4 |
| 4 | DATA rest, ext4 no journal | DATA rest, ext4 no journal |

`nvme` and `mmcblk` disks take a `p` before the partition number. UEFI fstab: `unitotem/files/fstab-amd64`; BIOS fstab is inline.

## Interfaces

- `build-iso.sh`: no arguments; env `DOCKER`; exit 1 without Docker.
- `build-live.sh`: runs only in the builder; `set -euo pipefail`.
- `installer.sh`: no arguments, interactive on tty1; exit 0 on cancel, 1 when no disk is found.
- `unitotem-installer.service` (live): `Type=oneshot`, `TTYPath=/dev/tty1`, `Restart=on-failure`, `RestartSec=3`, `RemainAfterExit=yes`.
- `/etc/live/config/unitotem.conf`: `LIVE_HOSTNAME=unitotem-installer`, `LIVE_USERNAME=""`.
- Kernel command line: `boot=live components quiet splash`.
- Target services: `systemd-timesyncd NetworkManager dbus ssh iptables-firewall unitotem-maintenance-mode start-xorg`.
- Target files: `/etc/hostname`, `/etc/hosts`, `/etc/locale.conf`, `/etc/vconsole.conf`, `/etc/X11/xorg.conf.d/00-keyboard.conf`, `/etc/localtime`, `/etc/fstab`, `/etc/netplan/00-default.yaml`, `/etc/default/grub`, `/etc/unitotem/chromium-flags`, `/usr/local/bin/chromium-unitotem`, `/usr/local/bin/unitotem-maintenance`, `/etc/systemd/system/start-xorg.service`, `/etc/systemd/journald.conf.d/unitotem.conf`, `/etc/udev/rules.d/60-scheduler.rules`, `/etc/sysctl.conf`, `/etc/default/rcS`.
- Windows boot entry (research): `bcdedit /copy {bootmgr}`, `device partition=<ESP>`, `path \EFI\unitotem\shimx64.efi`; `{fwbootmgr} displayorder {GUID} /addfirst` (persistent) or `bootsequence {GUID}` (one-shot `BootNext`). OTA environment: `unitotem.ota=1`, SSH 2222, DHCP, `OTA_PASSWORD`.

## Rules and gotchas

- Builder needs `--privileged` (loop mount of `efiboot.img`).
- `deploy/` output is root-owned: delete with a disposable container.
- `mksquashfs` stderr goes to `/dev/null`: failures show only in the exit status.
- The installer produces the single-root X11 variant (`start-xorg`); the shipped images are A/B Wayland (`build.md`). Updates come from OTA, not apt on the device.
- `installer.sh` installs `unitotem/files/chromium-flags-amd64` and `unitotem/files/start-xorg.service`, which are absent from `unitotem/files/`: step 9 aborts under `set -e`.
- The disk list does not exclude the boot medium.
- The root password is spliced into a `bash -c` string: a single quote breaks `chpasswd`.
- Wi-Fi credentials exist only in the live session; the target netplan has no Wi-Fi profile.
- `build-live.sh` lists `linuxefi` among the GRUB modules.
- `getty@tty1` autologin and `unitotem-installer.service` both use tty1.
- UEFI install uses `--removable --no-nvram`: firmware boots the fallback path.
- Secure Boot with shim: shim must carry Microsoft signatures; an unsigned GRUB is rejected (`Access Denied`). If `db` lacks the Microsoft UEFI CA, shim is rejected too. No script may write `db` from Windows (`Set-SecureBootUEFI -Name db` fails with `0xC0000022`).
- `BootNext` is one-shot. `displayorder {GUID} /remove` leaves the `Boot####` variable.
- Signed GRUB cannot read NTFS. Windows 11 24H2 BitLocker-encrypts new data partitions: run `manage-bde -off <drive>` before copying files. Reference partitions by label.
- Changing Secure Boot on a BitLocker machine asks for the recovery key unless `Suspend-BitLocker -MountPoint C: -RebootCount 0` ran first.
- `shutdown /r` is a full restart; `shutdown /r /fw` opens firmware setup.
- `bcdedit` output is localized: match the `winload.efi` path. `Rd` aliases `Remove-Item`: never define a function `Rd`.
- Lab: libvirt does not revert raw NVRAM on snapshot revert; NVRAM must be qcow2. TPM state is outside disk snapshots.
- `tools/win-lab/recover-driver.sh` hardcodes an absolute repository path in `DIR`.

## Windows-source install: research

- Research only: no Windows-side installer code; not a deploy path.
- Verified on OVMF (Secure Boot, Microsoft keys) with swtpm TPM 2.0, Windows 11 Pro 24H2, 100 MB ESP: boot entry from Windows, signed chain, OTA environment, DHCP, SSH 2222, `unitotem-ota-engine probe`; full install via `run_ota_sequence()` with `SB_MODE=shim` (rewrites GPT, restores ESP/ROOT_A/ROOT_B/DATA, boots UniTotem with Secure Boot on). The `Boot#### "UniTotem OTA"` entry stays in NVRAM.
- Limits:
  - ESP space: recovery kernel 12.2 MB + initrd 94.3 MB + ~4.6 MB chain do not fit the 61.6 MiB free on a 100 MB ESP; workaround: shrink C: and create a labelled FAT32 partition.
  - Wi-Fi: the recovery initrd has only the brcmfmac driver; wired Ethernet required.
  - BitLocker on new partitions.
  - Not covered: Wi-Fi-only PCs, legacy BIOS/MBR, Windows on ARM.
- Results come from OVMF, not OEM firmware.
- Point of no return: once disk writes start Windows is destroyed. Firmware ignoring `BootNext` starts Windows with nothing destroyed.

## Tests

- No automated test covers the ISO or installer. Manual: `./build-iso.sh`, boot in a UEFI VM and a BIOS VM, run the installer on a virtual disk, boot the result.
- Lab: `tools/win-lab/lab.sh start|wait|stop|revert [SNAP]|snap NAME|list|ssh CMD|put LOCAL [REMOTE]|shot FILE.png`; `winkeys.py text|ustext|key|shot`; `gcmd.sh 'cmd' [shot]`; `serialcap.sh LOG SECONDS`; `recover-driver.sh HOST DISK_BYID PARTS_DIR`.
- Windows probes (Administrator): `probe-windows.ps1 [-MountEsp]`, `nvram-var.ps1 -Boot`. Restore the NVRAM-inclusive baseline snapshot before each experiment.
