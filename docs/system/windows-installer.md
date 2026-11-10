# Windows installer (UniTotem from a running Windows PC)

Paste in an elevated PowerShell on the Windows PC (the host prints the right address when `tools/win-install-server.py` starts): `irm http://<host-ip>:8000|iex`. Win+R form, confirmed with Ctrl+Shift+Enter: `powershell -NoProfile -Command "irm http://<host-ip>:8000|iex"` (the pipe is inside the quotes and passed to PowerShell as part of its argument; Run hands the line to ShellExecute, not to cmd: inference, not tested; the Run field takes 259 characters, the line is about 70).

Paths: relative to the repository root. Lab findings behind the UEFI method: [windows-install-research.md](windows-install-research.md).

## Remote flow (`irm | iex`)

1. Host: `tools/build-windows-installer.sh` (once per image), then `tools/win-install-server.py [--authorized-key FILE] [--advertise IP] [--port 8000] [--timeout-minutes 60]`. Python 3 stdlib, no root. The key defaults to `~/.ssh/id_ed25519.pub` (one `ssh-ed25519` line); without a key file the OTA environment starts in open mode (warning printed).
2. Windows: paste the line. The bootstrap is text run in memory (`irm`, not `iwr`: `iwr` in PowerShell 5.1 needs the IE engine); no script file is written and the execution policy is not changed. It checks it is elevated (otherwise prints `Run as administrator`, exit code 3, changes nothing, no relaunch), then makes a **read-only inventory** and POSTs it: disks (model, size, serial, UniqueId, number, partitions), UEFI/BIOS, Secure Boot, free space of the ESP / active partition (the ESP is mounted on a free letter for a moment), BitLocker per volume, computer name, IPs, machine id (`MachineGuid`).
3. Host terminal shows the PC and its disks and the confirmation word of the system disk: `WIPE-<HOST>-DISK<N>-<SERIAL8>`. The operator types it at the server prompt, or runs `tools/win-install-server.py --approve WORD` from another terminal (file in `~/.local/state/unitotem-winserver/approvals/`, taken by the running server within 1 s). Approvals come only from the server's stdin and that directory, never from HTTP; an approval is bound to machine id + disk, and the PC recomputes the word itself and refuses a mismatch.
4. The PC polls every 5 s (`-TimeoutMinutes`, default 60). Without approval it exits with code 8 having changed nothing. After approval it downloads `/payload.zip`, verifies size and SHA-256 (both embedded in the bootstrap), extracts it to `%ProgramData%\UniTotem-install`, prepares the boot files and the one-shot boot entry (sections below), and restarts (`shutdown /r /t 10`). Every step is posted to the server and printed live as `[HOSTNAME] text`.
5. Host: `OTA_FALLBACK_KEY=<private key> deploy/remote-deploy.sh recover <ip> --parts DIR --yes` once the environment answers (see After the restart).

Authenticity: HTTP on the local network, no TLS. The bootstrap carries the payload hash, but the bootstrap itself is not authenticated: anyone able to spoof the host's address on the LAN could serve a different script. Run the server on a trusted network. Inventories from other machines are only shown; nothing runs without the operator's word.

Safe Mode with networking works for `bcdedit`, `mountvol`, `manage-bde`; the storage cmdlets need the Storage/Virtual Disk services (if unavailable the script stops with a message asking for a normal boot; unverified on real Windows).

WinRE (the recovery command prompt) has no PowerShell, no `curl` and normally no network drivers: the bootstrap does not work from there and is not supported.

## Local flow (USB stick)

`tools/windows-installer/Install-UniTotem.ps1` prepares a Windows 10/11 PC so that it starts the UniTotem OTA environment once. The host then runs the normal network recovery (`deploy/remote-deploy.sh recover`), which **erases the whole system disk**: Windows is not kept. The script itself destroys nothing; it adds boot files and one boot entry, and `-Undo` removes them.

## Files

| Path | Role |
|---|---|
| `tools/windows-installer/Install-UniTotem.ps1` | The installer (PowerShell 5.1, ASCII only, no modules) |
| `tools/windows-installer/grub.cfg.template`, `grub-bios.cfg.template` | GRUB configuration written at install time (`@AUTHKEY@`, `@DIR@`) |
| `tools/windows-installer/Install-UniTotem.Tests.ps1` | Pester tests of the pure functions and of a mocked dry run |
| `tools/windows-installer/bootstrap.ps1.tmpl` | Bootstrap served by the server (the installer is embedded in it) |
| `tools/win-install-server.py`, `tools/release/test_win_install_server.py` | Host server and its tests |
| `tools/build-windows-installer.sh` | Builds `work/windows-installer/unitotem-windows-installer.zip` + `SHA256SUMS` from the newest amd64 flash image (`--image`, `--initrd`, `--out`) |

Zip content: `Install-UniTotem.ps1`, `README.txt`, `payload/` (`vmlinuz`, `initrd.img`, `shimx64.efi`, `mmx64.efi`, `grubx64.efi` taken from the image's ESP `unitotem/recovery-*` and `EFI/unitotem-sb/`; `g2.img`; the templates; `SHA256SUMS`). The script verifies every payload file against `payload/SHA256SUMS` before use and again after copying.

## Prerequisites

- Windows 10/11, elevated PowerShell (Safe Mode works for `bcdedit`, `mountvol`, `manage-bde`; the storage cmdlets need the Storage/Virtual Disk services: if they are unavailable the script stops and asks for a normal boot).
- Wired Ethernet with DHCP (the recovery environment has no Wi-Fi driver).
- UEFI: GPT system disk, standard firmware that honours `BootNext`. Legacy BIOS: MBR system disk with an active boot partition.
- Secure Boot may stay on (UEFI): the chain is Microsoft-signed shim -> Debian-signed GRUB -> kernel. Firmware without the Microsoft UEFI CA rejects shim and starts Windows again; nothing is destroyed.

## What it does

1. Checks Administrator, firmware type (`winload.efi` vs `winload.exe` in `bcdedit /enum {current}`, locale independent), Secure Boot state, system disk (the disk holding the system drive).
2. Verifies the payload and the key file (`-AuthorizedKey FILE`: exactly one `ssh-ed25519` line; the OTA login is then that key, passed as `unitotem.ota.authkey=<base64>` on the kernel command line. Without a key the environment is in open mode: empty root password, see [fallback authentication](deploy-and-recovery.md#fallback-authentication)).
3. Shows disk model, size, serial and every partition, then the plan. Confirmation: type `WIPE-<HOST>-DISK<N>-<first 8 alphanumerics of the disk serial>` (computer name, disk number and serial are in the word, so a pasted command cannot hit another disk or PC).
4. Places the boot files (below), creates the boot entry, sets the one-shot boot (`BootNext` / `bootsequence`), offers a restart.
5. Writes `Install-UniTotem.log`, `Install-UniTotem.state.json` (what `-Undo` needs) and `Install-UniTotem.status.json` next to the script.

`-WhatIf` prints the plan and changes nothing (UEFI: the ESP is mounted on a free letter briefly to read its free space). Re-running is idempotent: an existing `UNITOTEMOTA` partition and an existing folder on the boot partition are reused.

### Where the boot files go

The bootloader needs kernel + initrd readable by GRUB, so not on the BitLocker-encrypted `C:`. Decision from the free space of the **unencrypted boot partition** (ESP / active partition): it is used when payload + 16 MiB margin fit; BitLocker, `C:` and the partition table are then not touched. Otherwise `C:` is shrunk online (`Resize-Partition`, works with BitLocker on), a FAT32 partition labelled `UNITOTEMOTA` is created and BitLocker is turned off **on that new empty partition only** (`manage-bde -off`, fallback `Disable-BitLocker`; Windows 11 24H2 encrypts new partitions by itself). `C:` is never decrypted. Recovery keys are never read, printed or saved. Decryption waits are bounded (`-DecryptTimeoutMinutes`, default 240) and resumable by running the script again.

Measured (current image, 2026-11-08 build): kernel 14.3 MB + initrd 225.6 MB + signed chain 4.6 MB. The initrd is the limit: a typical 100 MB ESP (61.6 MiB free in the lab) does not fit, so the new-partition path is the usual outcome; a 260-512 MB ESP or System Reserved with 250 MB free uses the boot partition. New partition size: payload + 64 MiB rounded up to 16 MiB (320 MiB for the current payload).

Initrd size (measured by unpacking the image's recovery initrd: 435.6 MB unpacked, 892 modules 55.6 MB, firmware 291 MiB of which nvidia 155, amdgpu 88, brcm 11, i915 10): an initrd without GPU, Wi-Fi/Bluetooth and sensor-hub firmware repacks to about 88 MB (zstd) and fits most ESPs; also without unused modules, hwdb and fonts about 67 MB. `tools/build-windows-installer.sh --initrd FILE` ships such a variant; producing it is a change to `unitotem/stage1-recovery-initrd.sh`. The same measurement found wired-NIC firmware missing from the image (bnx2/bnx2x, qed, netronome, rtl8157/8159 USB NICs, xhci-pci-renesas).

### UEFI

Signed chain to `S:\EFI\unitotem\` (`shimx64.efi`, `mmx64.efi`, `grubx64.efi`, `grub.cfg`), kernel/initrd as `unitotem-vmlinuz`/`unitotem-initrd.img` in the same folder or at the root of the new partition. Boot entry as in the research: `bcdedit /copy {bootmgr} /d "UniTotem OTA"`, `device partition=<ESP letter>:`, `path \EFI\unitotem\shimx64.efi`, `{fwbootmgr} displayorder {id} /addfirst`, `{fwbootmgr} bootsequence {id}`. `BootNext` is one-shot: after one boot Windows starts again by itself. `grub.cfg` finds the files with `search --file`, never by partition number.

### Legacy BIOS

`bootmgr` cannot load a Linux kernel, but it can load a boot-sector image. Method (source: help-grub thread "Format option for chainloading GRUB from BOOTMGR", 2013): `grub-mkimage -O i386-pc` core image with the needed modules built in, `cat lnxboot.img core.img > g2.img`, registered as a BCD `bootsector` application:

```
bcdedit /create /d "UniTotem OTA" /application bootsector   :: -> {id}
bcdedit /set {id} device partition=<boot partition letter>:
bcdedit /set {id} path \unitotem-g2.img
bcdedit /displayorder {id} /addlast
bcdedit /bootsequence {id}
```

`g2.img` sits on the active (boot) partition; its embedded configuration searches `/unitotem/recovery-vmlinuz` and runs `/unitotem/grub.cfg` (written by the script, carries the key token). No Secure Boot. GRUB reads NTFS and FAT32, so kernel and initrd go to `<boot partition>\unitotem\` when they fit, else to the new FAT32 partition. The Windows boot sector and MBR are not modified. Needs a free primary slot when a new partition is required.

Proof (emulated, not on Windows): a Debian `grub-mkimage` core image with a two-line embedded configuration (`search --file /unitotem/recovery-vmlinuz`, `configfile /unitotem/grub.cfg`) prefixed with `lnxboot.img` (2.06-13+deb12u2: 1 KiB + 147 KB), placed in raw sectors and started by a 446-byte test loader that copies the whole file to `0000:7C00` and jumps (emulating the behaviour reported in the thread), booted the recovery kernel and initrd from an NTFS partition in QEMU (TCG): `Command line: BOOT_IMAGE=/unitotem/recovery-vmlinuz ... unitotem.ota=1 ... unitotem.ota.authkey=QUJD`, initrd unpacked, `Run /init`. Whether bootmgr loads the image like the test loader is not proven; the OTA splash was not observed on the serial console.

## After the restart

1. The environment starts, takes an address by DHCP (first wired port with a cable) and shows `OTA update mode ... Address: <ip> Port: 2222`. The address is also visible in the router's client list; `discover_fallback` in `deploy/remote-deploy.sh` scans the local /24 for dropbear on 2222.
2. From the host (key mode; open mode: `OTA_FALLBACK_OPEN=1`):

```
OTA_FALLBACK_KEY=<private key> deploy/remote-deploy.sh recover <ip> --parts deploy/amd64/unitotem-<version>-amd64.parts --disk <by-id or name>
```

`--disk` selects the disk to erase (by-id contains the model and serial shown by the script). Details, backups and options: [deploy-and-recovery.md](deploy-and-recovery.md). Add `--yes` for an unattended run.

## Unattended

```
Install-UniTotem.ps1 -Unattended -Disk <N> -ConfirmToken WIPE-<HOST>-DISK<N>-<SERIAL8> [-AuthorizedKey FILE] [-Reboot]
Install-UniTotem.ps1 -Unattended -Disk <N> -WhatIf      # status file carries ExpectedToken
Install-UniTotem.ps1 -Unattended -Undo
```

No prompt, no window; runs from PowerShell Remoting, ssh, PsExec or a scheduled task as SYSTEM. `-Disk` must equal the system disk and `-ConfirmToken` the word computed for it, else exit 5 and nothing changes. `-Reboot` restarts into the environment (`shutdown /r /t 10`).

Exit codes: 0 ok (also dry run, cancelled), 1 failed, 2 usage, 3 not elevated, 4 unsupported system or no room, 5 confirmation mismatch, 6 payload missing or corrupt, 7 BitLocker wait timed out, 8 no approval from the host, 9 host unreachable. `Install-UniTotem.status.json`: `Result` (`dry-run`, `prepared`, `undone`, `stopped`, `failed`), `Code`, `Message`, `Mode` (`uefi`/`bios`), `Where` (`boot`/`new`), `Partition`, `BootEntry`, `DiskNumber`, `DiskSerial`, `DiskModel`, `ExpectedToken`, `Time`.

Flow: (1) the user runs the script once, or the host runs it remotely if Windows is reachable; (2) one restart into the OTA environment; (3) the host finds the environment (`discover_fallback` or the address from the router) and runs `recover <ip> --parts ... --yes`; the install finishes by itself.

Not unattended: firmware that ignores `BootNext` (Windows starts again), a firmware setup password, Secure Boot without the Microsoft UEFI CA, a PC without wired DHCP. Static addressing for the environment is not available: `unitotem.ota=1` does not read `unitotem-ota.conf` (the boot-FAT lookup is by the label `EFI`/`FIRMWARE`).

## Undo

`Install-UniTotem.ps1 -Undo` (before the host starts the install): removes the BCD entry and one-shot value, the ESP folder or the `unitotem` folder and `unitotem-g2.img`, the `UNITOTEMOTA` partition, and extends `C:` again. After the install has started there is no way back.

## Tests

- `docker run --rm -v "$PWD/tools/windows-installer:/t:ro" mcr.microsoft.com/powershell:lts-ubuntu-22.04 pwsh -c 'Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck; Invoke-Pester /t/Install-UniTotem.Tests.ps1'`: parse check, validators, size math, plan building, token/grub rendering, a mocked unattended dry run. No Windows cmdlet runs.
- `python3 -I tools/release/test_win_install_server.py`: 33 tests of the server (bootstrap, payload hash and ranges, inventory validation, approval binding, status rate limit, `--approve`). Protocol run with the real zip: bootstrap parsed by PowerShell 7.4 (0 errors), `Send-Json`, `Wait-Approval`, `Get-RemotePayload` (240 MB, hash verified, extracted, key included) against the live server from a container, and the confirmation word identical in PowerShell and Python.
- Not verified on Windows: every real call (`bcdedit`, `mountvol`, Storage cmdlets, `manage-bde`, BitLocker CIM), Safe Mode behaviour, firmware behaviour of `BootNext`, bootmgr loading `g2.img`.
