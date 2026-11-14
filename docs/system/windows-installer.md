# Windows installer (UniTotem from a running Windows PC)

On the Windows machine press Win+R, type `powershell`, press Enter, type `irm http://<host-ip>:8000|iex` and press Enter (the server prints this instruction with one `irm` line per local IPv4 address). A PowerShell that is not elevated starts the same command in an elevated PowerShell by itself (`Start-Process powershell.exe -Verb RunAs -ArgumentList -NoProfile -NoExit -Command "$env:UNITOTEM_ELEVATED=1; irm http://<host-ip>:8000|iex"`, built from the validated server address): one UAC prompt (none when UAC is off; Safe Mode can show it too), the first window logs `not elevated, elevated process started` and ends, the elevated window stays open (`-NoExit`). A refused or failed elevation ends with exit code 3 and `changes=none`; the `UNITOTEM_ELEVATED` marker prevents a second relaunch.

Paths: relative to the repository root. Lab findings behind the UEFI method: [windows-install-research.md](windows-install-research.md).

## Remote flow (`irm | iex`)

1. Host: `tools/build-windows-installer.sh` (once per image), then `tools/win-install-server.py [--authorized-key FILE] [--advertise IP] [--port 8000] [--timeout-minutes 60]`. Python 3 stdlib, no root. The OTA login key is **per PC**, never a personal key: at the PC's first inventory the server creates an ed25519 pair (`ssh-keygen -t ed25519 -N ''`, comment `unitotem-deploy`) at `${XDG_STATE_HOME:-~/.local/state}/unitotem-deploy/<client-ip>/id_ed25519` (directory 0700, key 0600), the same layout as `ota_key_path` in `deploy/lib.sh`; `remote-deploy.sh recover <ip>` finds it by that address (the OTA environment gets the PC's Windows address from the same DHCP lease) and `OTA_FALLBACK_KEY` names it explicitly for any other address. Only the public line leaves the host, through `GET /key?machine=ID` after the approval (it is not in the payload zip, whose hash is fixed). `--authorized-key FILE` is an explicit public key shared by all PCs; nothing is read from `~/.ssh`. Open mode exists only for the local script without `-AuthorizedKey`.
2. Windows: paste the line. The bootstrap is text run in memory (`irm`, not `iwr`: `iwr` in PowerShell 5.1 needs the IE engine); no script file is written and the execution policy is not changed. It checks it is elevated (otherwise prints `Run as administrator`, exit code 3, changes nothing, no relaunch), then makes a **read-only inventory** and POSTs it: disks (model, size, serial, UniqueId, number, partitions), UEFI/BIOS, Secure Boot, free space of the ESP / active partition (the ESP is mounted on a free letter for a moment), BitLocker per volume, computer name, IPs, machine id (`MachineGuid`).
3. Host terminal shows the PC and its disks, then asks in yellow `(<host>) disk=N model=... size=...GB serial=...: Erase this disk and install UniTotem? (y/n)`. The operator answers `y` (or `Y`); the server asks again `Last chance: erase this disk? (y/n)`; a second `y` approves. `n` cancels and nothing is changed. Any other answer prints `Invalid answer, type y or n` and the same question is asked again. The answers apply to the PC that reported last. From another terminal: `tools/win-install-server.py -y` (alias `--yes`) approves the PC that reported last without the two questions, `-y --machine ID` a specific one; it leaves a file in `~/.local/state/unitotem-winserver/approvals/` that the running server takes within 1 s and checks like the questions (known PC, plan not `none`, approval bound to its machine id, disk number and serial). Invalid arguments exit 2. Answers come only from the server's stdin and that directory, never from HTTP. The approval is bound to machine id + disk number + disk serial; the PC checks all three against itself and refuses a mismatch. A new inventory from the PC revokes an earlier approval.

On a terminal the question is the prompt: a log line that arrives while it waits is printed above it (the prompt line is erased first) and the prompt is drawn again below with what the operator had typed (Backspace and Ctrl-U edit; input is read in cbreak mode). Without a terminal the question is a plain log line and input is read line by line.
4. The PC polls every 5 s (`waiting for approval minutes_left=N` on its console at the start and then every 5 minutes) (`-TimeoutMinutes`, default 60). Without approval it exits with code 8 having changed nothing. After approval it downloads `/payload.zip`, verifies size and SHA-256 (both embedded in the bootstrap), extracts it to `%ProgramData%\UniTotem-install`, prepares the boot files and the one-shot boot entry (sections below), and restarts (`shutdown /r /t 10`). Every step is posted to the server and printed live as `[HOSTNAME] text`.
5. Host: the server prints the full command after the approval: `OTA_FALLBACK_KEY=<per-PC key> deploy/remote-deploy.sh recover <ip> --parts DIR --yes`; run it once the environment answers (see After the restart).

Authenticity: HTTP on the local network, no TLS. The bootstrap carries the payload hash, but the bootstrap itself is not authenticated: anyone able to spoof the host's address on the LAN could serve a different script. Run the server on a trusted network. Inventories from other machines are only shown; nothing runs without the operator's word.

Inventory: UEFI/BIOS, Secure Boot (`n/a` on BIOS), machine model, CPU (name, cores, threads) and RAM (GB, modules) from the classic CIM classes (`unknown` per field when unavailable), drive letters from `Win32_LogicalDiskToPartition` (the Storage module shows none in Safe Mode), free space per lettered volume and of the boot partition (`Win32_Volume` `SystemVolume` when it has no letter), MBR partition types read from the first sector of the disk (`MBR 0x07`, `0x27` = Recovery, active flag), the boot mode (`boot_mode=safe|normal`), the planned destination with a short reason token, and the facts behind it as log lines. Safe Mode is detected with `SAFEBOOT_OPTION` / `SystemInformation.BootMode` (unverified on Windows). Nothing starts a service or edits the SafeBoot keys.

Outages and restarts (both directions):
- Server state: `<state-dir>/machines/<machine-id>.json` per PC (inventory and address, atomic write, mode 0600, directory 0700; no private key, no payload). A restarted server reloads them, shows `restored N PC(s) ... approvals must be given again` and asks the first question again for the PC that reported last. Approvals are not restored unless the server runs with `--keep-approvals` (then they come back only if disk number and serial still match). The per-PC key pair is reused from `unitotem-deploy/<ip>/`.
- A machine id the server does not know gets `{"state":"unknown"}` from `/approval`; the PC then sends its inventory again. The same inventory sent again changes nothing (no new question, approval kept); a changed one revokes the approval.
- The PC never ends because the host is silent: the first inventory is retried with backoff (5, 10, 20, 30 s) until `-TimeoutMinutes`; the approval poll ignores connection errors; only the deadline ends the wait, with exit code 8 and nothing changed.
- Status lines go through a local queue (200 lines at most, oldest dropped and logged), sent best-effort with the same backoff; a failed post is only logged.
- Payload download resumes with `Range` from the bytes already on disk (a host that ignores Range restarts it), retries with backoff for `-DownloadTimeoutMinutes` (default 10), always checks size and SHA-256 and downloads again on a mismatch. The OTA key is fetched with the same retry. Both happen before anything on the PC is changed.
- After that the host is not needed: file copies, `bcdedit` and the restart run from local data; status lines are sent when the host answers (a last flush before the restart).

Text transport is UTF-8 (client sends UTF-8 bytes with `charset=utf-8`; the server decodes UTF-8 and prints UTF-8). Log text keeps Unicode, loses control characters (C0, DEL, C1, bidirectional overrides) and is cut only beyond 4000 characters, always with a visible `…[truncated N]` marker. The local log file is UTF-8 with BOM.

Failures name the step, the error id and the failing statement and reach the server whole (language independent: `FullyQualifiedErrorId`, never a localized text comparison). The inventory also carries the UI language and the state of the `vds`, `StorSvc` and `smphost` services.

Disk and partition lookup never uses `Get-Partition -DriveLetter`: on a Windows 10 Pro laptop in Safe Mode with networking it failed at once with `No MSFT_Partition objects found with property 'DriveLetter' equal to 'C'` (BitLocker off on that machine; the cause inside the Storage provider is not established: an empty `DriveLetter` property with the letter only in `AccessPaths`, or a provider blind to the letter). The system partition is found through `Win32_LogicalDisk` -> `Win32_LogicalDiskToPartition` -> `Win32_DiskPartition` (disk index, start offset), then matched by offset among the partitions of that disk; if the Storage module returns no disks or partitions, disk and partition objects are built from `Win32_DiskDrive`/`Win32_DiskPartition`. Resize, format and letters use disk and partition numbers. Changing partitions still needs the Storage module (Virtual Disk service); there is no diskpart fallback, and the SafeBoot registry keys of these services were not checked, so they are not edited.

Safe Mode with networking works for `bcdedit`, `mountvol`, `manage-bde`; the storage cmdlets need the Storage/Virtual Disk services (if unavailable the script stops with a message asking for a normal boot; unverified on real Windows).

WinRE (the recovery command prompt) has no PowerShell, no `curl` and normally no network drivers: the bootstrap does not work from there and is not supported.

## Local flow (USB stick)

`tools/windows-installer/Install-UniTotem.ps1` prepares a Windows 10/11 PC so that it starts the UniTotem OTA environment once. The host then runs the normal network recovery (`deploy/remote-deploy.sh recover`), which **erases the whole system disk**: Windows is not kept. The script itself destroys nothing; it adds boot files and one boot entry, and `-Undo` removes them.

## Files

| Path | Role |
|---|---|
| `tools/windows-installer/Install-UniTotem.ps1` | The installer (PowerShell 5.1, ASCII only, no modules) |
| `tools/windows-installer/grub.cfg.template`, `menu.lst.template` | UEFI GRUB configuration and BIOS GRUB4DOS menu written at install time (`@AUTHKEY@`, `@DIR@`) |
| `tools/windows-installer/Install-UniTotem.Tests.ps1` | Pester tests of the pure functions and of a mocked dry run |
| `tools/windows-installer/bootstrap.ps1.tmpl` | Bootstrap served by the server (the installer is embedded in it) |
| `tools/win-install-server.py`, `tools/release/test_win_install_server.py` | Host server and its tests |
| `tools/build-windows-installer.sh` | Builds `work/windows-installer/unitotem-windows-installer.zip` + `SHA256SUMS` from the newest amd64 flash image (`--image`, `--initrd`, `--out`) |

Server output: the start prints `On the Windows machine press Win+R, type powershell, press Enter, type one of the following commands and press Enter` and one `irm http://<ip>:8000|iex` line per local IPv4 address, then `listening on ...` in green. The two questions are bold yellow. Log lines show `(hostname)` in a colour picked at random from a 10-colour 256-colour palette (blues, purples, reds, orange; no black, white, green or yellow) and kept per host name in memory only; no colour when stdout is not a terminal or `NO_COLOR` is set. Partition types are shown as `label (raw)`:

| Raw | Label |
|---|---|
| `IFS`, `Installable File System` | NTFS/exFAT (IFS): MBR type 0x07, the file systems Windows installs through its IFS drivers, in practice NTFS |
| `Basic` | Basic data |
| `System` | EFI System |
| `Reserved` | Microsoft reserved |
| `Recovery` | Recovery |
| `Unknown` | Unknown |

Other values are shown unchanged.

Both build scripts (`build-windows-installer.sh`, `build-installer-iso.sh`) fail when a text file of the payload holds an SSH public key line (`ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp* <base64>`; no exceptions).

Zip content: `Install-UniTotem.ps1`, `README.txt`, `payload/` (`vmlinuz`, `initrd.img`, `shimx64.efi`, `mmx64.efi`, `grubx64.efi` taken from the image's ESP `unitotem/recovery-*` and `EFI/BOOT/` (`BOOTX64.EFI` is the shim); `grldr`, `grldr.mbr`, `COPYING-grub4dos`; the templates; `SHA256SUMS`). The script verifies every payload file against `payload/SHA256SUMS` before use and again after copying.

## Prerequisites

- Windows 10/11, elevated PowerShell (Safe Mode works for `bcdedit`, `mountvol`, `manage-bde`; the storage cmdlets need the Storage/Virtual Disk services: if they are unavailable the script stops and asks for a normal boot).
- Wired Ethernet with DHCP (the recovery environment has no Wi-Fi driver).
- UEFI: GPT system disk, standard firmware that honours `BootNext`. Legacy BIOS: MBR system disk with an active boot partition.
- Secure Boot may stay on (UEFI): the chain is Microsoft-signed shim -> Debian-signed GRUB -> kernel. Firmware without the Microsoft UEFI CA rejects shim and starts Windows again; nothing is destroyed.

## What it does

1. Checks Administrator, firmware type (`winload.efi` vs `winload.exe` in `bcdedit /enum {current}`, locale independent), Secure Boot state, system disk (the disk holding the system drive).
2. Verifies the payload and the key file (`-AuthorizedKey FILE`: exactly one `ssh-ed25519` line; the OTA login is then that key, passed as `unitotem.ota.authkey=<base64>` on the kernel command line. Without a key the environment is in open mode: empty root password, see [fallback authentication](deploy-and-recovery.md#fallback-authentication)).
3. Shows disk model, size, serial and every partition, then the plan. Confirmation: type `WIPE-<HOST>-DISK<N>-<first 8 alphanumerics of the disk serial>` (local script only; computer name, disk number and serial are in the word, so a pasted command cannot hit another disk or PC).
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

Boot method `grub4dos` (GRUB4DOS 0.4.6a, build 2020-08-09, GPL-2.0, https://github.com/chenall/grub4dos; archive pinned by SHA-256 in `tools/build-windows-installer.sh`, the build fails on a mismatch; license text in the zip as `payload/COPYING-grub4dos`; listed in `THIRD-PARTY.md`). `bootmgr` cannot load a Linux kernel; it can load a boot-sector file, and `grldr.mbr` is the GRUB4DOS file made for that. BCD entry:

```
bcdedit /create /d "UniTotem OTA" /application bootsector   :: -> {id}
bcdedit /set {id} device partition=<boot partition letter>:
bcdedit /set {id} path \grldr.mbr
bcdedit /displayorder {id} /addlast
bcdedit /bootsequence {id}
```

Files at the root of that partition: `grldr.mbr` (boot sector), `grldr` (second stage found in the root), `menu.lst` (`default 0`, `timeout 0`, `title UniTotem OTA`, `find --set-root /unitotem/vmlinuz`, `kernel /unitotem/vmlinuz ... unitotem.ota=1 ... [unitotem.ota.authkey=<token>]`, `initrd /unitotem/initrd.img`, `boot`). Kernel and initrd: `<partition>\unitotem\`. A file with one of these names that already exists and differs is never overwritten (`file exists and is not ours`, exit 4). GRUB4DOS reads NTFS and FAT32; no Secure Boot. Destination, in order: (1) the active partition (System Reserved) when it has a drive letter and room; (2) `C:` when it is NTFS, not BitLocker-encrypted and has room, with no Storage module involved (works in Safe Mode where `vds`/`StorSvc`/`smphost` are stopped); (3) a new FAT32 partition from a shrunk `C:`, only in normal mode and with a free primary slot. If none applies the inventory says why (`cannot install reason=...`, `ERROR`) and the host is not asked. The Windows boot sector and MBR are not modified. The inventory reports `boot-method=grub4dos`.

Proof (emulated, not on Windows; QEMU/SeaBIOS with TCG): disk with a bootmgr stand-in (446 bytes, reads the whole `grldr.mbr` to 0000:7C00 and jumps), an NTFS partition (`mkntfs -p 2048 -H 255 -S 63`) holding `grldr`, `menu.lst`, the 14.3 MB kernel and the 225.6 MB initrd. Result: `Command line: nomodeset loglevel=7 unitotem.ota=1 console=tty0 console=ttyS0,115200 unitotem.ota.authkey=QUJD`, `Freeing initrd memory: 220352K`, `Run /init as init process`, `Begin: Running /scripts/init-premount`. With only the first 512 bytes of `grldr.mbr` loaded the boot stops at `Missing helper.`: the whole 8 KB file must be loaded, as the canonical recipe assumes. Whether the real `bootmgr` loads the whole file is not proven here. The alternative of GRUB4DOS loading GRUB 2 (`kernel /unitotem/lnxboot.img`, `initrd /unitotem/core.img`) was not needed and not tested.

## Lessons

- 2026-11-10, Windows 10 Pro, legacy BIOS, MBR, `C:` NTFS: the first BIOS build registered `lnxboot.img` + `core.img` (147 KB, GRUB 2) as the BCD boot-sector file `\unitotem-g2.img`. At the restart the Windows Boot Manager showed error 0xc000007b (STATUS_INVALID_IMAGE_FORMAT): it read the file and did not accept it. Cause: a BCD `bootsector` entry needs a real boot sector that loads its second stage from the file system by itself; `lnxboot.img` is a stub made to be loaded as a "kernel" by GRUB Legacy/NTLDR-style loaders. The QEMU proof of that build used a stand-in loader of ours, which did not behave like `bootmgr`. Fix: the GRUB4DOS recipe above (`\grldr.mbr`); `-Undo` / `/undo` removes the broken entry and its files.


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

Before the host starts the install, from the PC that ran the installer: `irm http://<host-ip>:8000/undo|iex` (the server prints `To undo: irm http://<ip>:8000/undo|iex` at start; the local script has `-Undo`). The bootstrap in undo mode needs no inventory and no approval; it elevates itself like the install and logs every step.
- BCD: the entry from the state file (`%ProgramData%\UniTotem-install\Install-UniTotem.state.json`) and every entry whose block in `bcdedit /enum all` contains the description `UniTotem OTA` (the GUID is read by pattern, no localized label is compared) is taken out of the display order, the one-shot value is deleted, then the entry is deleted. `default` is never changed by the install, so nothing else needs restoring.
- Files (BIOS): only the files recorded in the state with their SHA-256 (`grldr.mbr`, `grldr`, `menu.lst`, `unitotem\vmlinuz`, `unitotem\initrd.img`); a file whose hash changed is kept and logged (`kept path=... reason=not_ours_hash_differs`), and so is any other file; the `unitotem` folder goes when empty. State of an earlier version (loader image `unitotem-g2.img`) removes that file and its folder. Without a state file only the BCD entries are removed (`files kept reason=no_state`).
- UEFI: the ESP folder `EFI\unitotem`, the `UNITOTEMOTA` partition, and `C:` is extended again.

After the install has started there is no way back.

## Tests

- `docker run --rm -v "$PWD/tools/windows-installer:/t:ro" mcr.microsoft.com/powershell:lts-ubuntu-22.04 pwsh -c 'Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck; Invoke-Pester /t/Install-UniTotem.Tests.ps1'`: parse check, validators, size math, plan building, token/grub rendering, a mocked unattended dry run. No Windows cmdlet runs.
- `python3 -I tools/release/test_win_install_server.py`: 71 tests of the server (bootstrap, payload hash and ranges, inventory validation, y/n questions, `-y`, approval binding, state persistence and restart, Unicode log transport, prompt redraw on a pseudo-terminal, status rate limit). Protocol run with the real zip: bootstrap parsed by PowerShell 7.4 (0 errors), `Send-Json`, `Wait-Approval`, `Get-RemotePayload` (240 MB, hash verified, extracted, key included) against the live server from a container.
- Not verified on Windows: every real call (`bcdedit`, `mountvol`, Storage cmdlets, `manage-bde`, BitLocker CIM), Safe Mode behaviour, firmware behaviour of `BootNext`, bootmgr loading `g2.img`.

## Single PC per session

The server follows one PC at a time. The machine that sent an inventory is active until it finishes (status level `done`), fails (`error`), is cancelled (`n`), is reset or its session is older than `--timeout-minutes`. Any request carrying another machine id (inventory, approval poll, key, status) gets HTTP 409 `{"error":"busy","message":"server busy: another PC is being installed"}`; the client logs `server busy: another PC is being installed changes=none` and ends with exit code 10. The server logs the refusal as a `WARNING` line (`rejected machine=... client=... reason=busy`), at most once a minute per machine id. `tools/win-install-server.py --reset` (file taken by the running server) frees the session. A restarted server makes the newest restored PC active only if its state file is younger than `--timeout-minutes`. The payload download is not tied to a machine id.

## Log format

Server (Python `logging`, logger `winserver`) and client use `YYYY-MM-DD HH:MM:SS LEVEL (host) message` with the level names `INFO`, `WARNING`, `ERROR`, `DEBUG`; messages are short facts in English with `key=value` data (`disk=0 serial=... changes=none`). The server handler is a `logging.StreamHandler` subclass that prints under the prompt lock; the host name is a record field, coloured per host on a terminal; `--log-file FILE` adds a UTF-8 `FileHandler` (no colour). The PC summary printed after an inventory is a `key: value` list indented by two spaces (disks and partitions two more), without timestamp or level, so it stands apart from the log lines in column 0. The client prints the same format with `HH:MM:SS` on its console and with the full date in its log file (UTF-8 with BOM); its `Say` lines also go to the server as status (`INFO` -> info, `WARNING` -> warn, `ERROR` -> error, the final line -> done). Plan and destination are log lines, e.g. `C: fs=NTFS bitlocker=off free=232000MB` and `destination selected: cdrive reason=c_ntfs_not_encrypted_has_room`.

## Server robustness

- A PC that resets or drops a connection (restart, `ConnectionResetError`, `BrokenPipeError`, timeout) gives one `INFO (server) client disconnected addr=... reason=...` line; any other request error is logged with its traceback in the standard format (`ERROR (server) request failed ...`). `Server.handle_error` replaces socketserver's raw dump, so nothing goes to stderr.
- The prompt switches the terminal to cbreak; the saved attributes are restored with `TCSAFLUSH` on every exit path: `finally` around the input loop, `atexit`, and handlers for SIGINT, SIGTERM, SIGHUP and SIGQUIT that restore and end the process through `SystemExit` (exit code 128 + signal), then a new line is printed. Nothing is touched when stdin is not a terminal. Tested on a pty with each signal and with a crash in the prompt thread (ECHO, ICANON, ISIG, ICRNL equal to the initial values).
- State files that cannot be used are deleted with a reason: `state file discarded name=... reason=corrupt|schema|stale` (`stale`: older than 7 days; `schema`: not valid for this version).
- The command printed after an approval names the newest `deploy/amd64/*.parts` (for a BIOS PC one that holds `p5-BIOS.*`); without one it prints `--parts <parts>` and `WARNING no parts set found under deploy/amd64`.
- The client writes numbers with the invariant culture (decimal point under any Windows language) and the same partition type labels as the server; facts are printed once, in the inventory (the plan after the approval holds only the new steps).
