# Booting the UniTotem OTA environment from a running Windows 11

Lab findings (Windows 11 under OVMF, 2026-10); measurements of an older recovery build.
Lab: Windows 11 Pro 24H2 under OVMF with Secure Boot and Microsoft keys, swtpm TPM 2.0, 100 MB ESP. Scripts: `tools/win-lab/README.md`.
OVMF is not an OEM firmware: everything below holds for standard UEFI behaviour only and says nothing about specific vendors' firmware.
The shipped Windows path and its current procedure: [windows-installer.md](windows-installer.md). The deploy into the OTA environment: [deploy-and-recovery.md](deploy-and-recovery.md).

## Boot entry created from Windows

Run from an elevated prompt:

```
mountvol S: /S                                   :: mounts the ESP
(copy the signed shimx64.efi, mmx64.efi, grubx64.efi + grub.cfg to S:\EFI\unitotem\)
bcdedit /copy {bootmgr} /d "UniTotem OTA"        :: -> {GUID}
bcdedit /set {GUID} device partition=S:
bcdedit /set {GUID} path \EFI\unitotem\shimx64.efi
bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst     :: persistent
bcdedit /set {fwbootmgr} bootsequence {GUID}               :: one-shot
```

- `bcdedit /copy {bootmgr}` creates a real `Boot####` variable in NVRAM; `bootsequence` writes `BootNext`; `displayorder {GUID} /remove` removes the entry from `BootOrder` but leaves it in NVRAM.
- `BootNext` is one-shot: after use it disappears and Windows boots by itself again (also after a kernel panic + reset).
- With Secure Boot on, firmware starts shim -> Debian-signed GRUB -> kernel (`Kernel is locked down from EFI Secure Boot`).
- The signed GRUB reads `grub.cfg` from its own folder (`\EFI\unitotem\`); `EFI/debian` is not needed. The image's stub (`search --label EFI`) does not apply on Windows, where the ESP has no such label: use a dedicated `grub.cfg` with `search --no-floppy --file|--label`.
- The shim shipped in the image carries both Microsoft signatures (UEFI CA 2011 and 2023). An unsigned GRUB is rejected by the firmware (`Access Denied -- rejected probably by Secure Boot`) and the firmware moves on to the next entry (Windows). If `db` lacks the Microsoft UEFI CA (3rd party), shim is rejected too.
- From Windows, `Set-SecureBootUEFI -Name db` with an unsigned payload is refused (`0xC0000022`): `db` cannot be extended without the firmware setup.
- Windows must not be given writes to `db` by any UniTotem script.

## Where to put kernel and initrd (about 101.5 MiB)

- The recovery kernel + initrd weigh 106.4 MB (kernel 12.2 MB, initrd 94.3 MB already compressed) plus about 4.6 MB of signed chain. A 100 MB ESP with 61.6 MiB free is not enough.
- The signed GRUB cannot read NTFS (`ls` answers `unknown filesystem` even though the `ntfs` module is loaded), and C: is BitLocker-encrypted anyway.
- Shrinking C: and creating a FAT32 partition works: `Resize-Partition -DriveLetter C -Size ...` online, `New-Partition`, `Format-Volume -FileSystem FAT32`; the signed GRUB reads it and `search --label` finds it.
- Windows 11 24H2 BitLocker-encrypts the newly created partition (`-FVE-FS-` in the first sector, GRUB sees `unknown filesystem`): run `manage-bde -off X:` before copying files. GRUB numbers partitions by position, Windows by creation order: use labels.
- An unsigned GRUB module loaded from the ESP is refused: `error: prohibited by secure boot policy`.

## OTA environment started from Windows

- Kernel + initrd from the FAT32 partition (`linux ($root)/vmlinuz unitotem.ota=1 nomodeset console=tty0 console=ttyS0,115200`, `initrd ($root)/initrd.img`) (the deploy tool appends `unitotem.ota.authkey=<base64 public key>` to that command line: the fallback has no fixed password) through the signed chain with Secure Boot on: the OTA environment starts, gets an address by DHCP (same IP and MAC as Windows), shows `OTA update mode ... Port: 2222`, and answers `ota_ssh`; `unitotem-ota-engine probe` works.
- The `unitotem.ota=1` path uses DHCP on the first interface; it does not read `unitotem-ota.conf`, and the recovery initrd has no Wi-Fi driver or firmware (only the Pi's `brcmfmac`). Wired Ethernet is required.
- The full install from the OTA environment is the deploy of [deploy-and-recovery.md](deploy-and-recovery.md). An install that was run from the lab left the orphan `Boot#### "UniTotem OTA"` entry in NVRAM.

## Windows-side facts

- Secure Boot state: `Confirm-SecureBootUEFI`; `db` subjects are decoded from the EFI_SIGNATURE_LISTs (`tools/win-lab/probe-windows.ps1`).
- UEFI vs BIOS: the `PEFirmwareType` registry value exists only in WinPE; use the `winload.efi` path in `bcdedit /enum {current}` (language independent).
- On Windows 11 24H2 the system volume is `FullyEncrypted` with protection off (clear key) even with a local account: BitLocker is the norm. The ESP is never encrypted, so files copied to it are readable by the firmware.
- A BitLocker-protected machine whose Secure Boot configuration is changed in the firmware setup asks for the recovery key unless BitLocker was suspended first (`Suspend-BitLocker -MountPoint C: -RebootCount 0`, then `Resume-BitLocker`).
- `shutdown /r` is a full restart (no Fast Startup); `shutdown /r /fw` opens the firmware setup.
- `Rd` is a PowerShell alias of `Remove-Item`; `bcdedit` output is localized, so prefer cmdlets or WMI/CIM.

## Limits

- Wi-Fi-only PCs and Windows on ARM are not covered by the OTA environment. These findings cover the UEFI method only; the legacy BIOS route (GRUB4DOS) is in [windows-installer.md](windows-installer.md).
- The OTA environment listens on SSH port 2222 while armed, with no fixed password: the armed key (`unitotem.ota.authkey=` token or boot-FAT file) or the administrator accounts of the installed system; see [fallback authentication](deploy-and-recovery.md#fallback-authentication). It can erase the disk: use it only on trusted networks.
- Once disk writes begin, Windows is destroyed and there is no way back.
- Firmware that ignores `BootNext` simply starts Windows again, with nothing destroyed.

## Lab scripts

The scripts that drive the libvirt lab (`lab.sh`, `winkeys.py`, `gcmd.sh`, `serialcap.sh`) and the Windows probes (`probe-windows.ps1`, `nvram-var.ps1`) are described in `tools/win-lab/README.md`. They need a Windows 11 ISO to build the lab VM.
