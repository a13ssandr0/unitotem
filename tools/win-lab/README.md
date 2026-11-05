# Windows 11 + OVMF Secure Boot lab (libvirt)

Tools to try, without hardware, how to start from a running Windows 11 and boot the UniTotem OTA environment with Secure Boot
ON. Results and method: `docs/system/windows-install-research.md`. This folder contains only the helpers:
**no keys or passwords** (the SSH key `id_lab`, `lab-password.txt` and the `labtools.*` files stay in `work/win-lab/`, outside git).

## The lab

- libvirt domain `win11-lab` (`qemu:///system`) = full clone of an Italian Windows 11 Pro 24H2; the user's own `win11` is NEVER touched.
- UEFI with Secure Boot on and Microsoft keys (`OVMF_CODE_4M.ms.fd`), emulated TPM 2.0 (swtpm), 8 GB RAM, 4 vCPUs, e1000e NIC on the `default` network, 64 GB SATA disk.
- access: SSH as `lab` (administrator, key `work/win-lab/id_lab`, PowerShell 5.1).

## Files

| File | What it does |
|---|---|
| `lab.sh` | `start`, `wait`, `stop`, `revert [SNAP]` (default `base-nvram`), `snap NAME`, `list`, `ssh 'powershell command'`, `put LOCAL [REMOTE]`, `shot FILE.png` |
| `winkeys.py` | types into the VM console with `virsh send-key`: `text` (Italian layout, for Windows), `ustext` (US layout, for GRUB and firmware menus), `key`, `shot` |
| `gcmd.sh` | writes a command at the GRUB prompt (US layout), Enter, screenshot |
| `serialcap.sh` | captures the serial console (ttyS0) to a file: OVMF messages (`BdsDxe: loading Boot0005 ...`), which are not visible on screen, appear there |
| `probe-windows.ps1` | read-only Windows-side probe (UEFI/BIOS, Secure Boot, decoded db/KEK/PK, BitLocker, disks, ESP, NIC, RAM) |
| `nvram-var.ps1` | reads/writes raw UEFI variables from Windows and decodes `Boot####`/`BootOrder`/`BootNext` |
| `recover-driver.sh` | runs the real `run_ota_sequence()`/`populate_bootfs_step()` from `remote-deploy.sh` against the OTA environment started from Windows |

## Baseline and NVRAM: caveats

1. **Reverting a libvirt snapshot does NOT restore the UEFI NVRAM if it is a `raw` file** (libvirt default): boot entries, `BootOrder`
   and MOK variables stay as they were after the experiment (a `LabMarker` variable and a modified `BootOrder` survived the revert).
   The domain is therefore defined with `<nvram format='qcow2'>` on `work/win-lab/nvram/win11-lab_VARS.qcow2`, created with
   `qemu-img convert -f raw -O qcow2 /usr/share/OVMF/OVMF_VARS_4M.ms.fd ...` (libvirt 12 does not convert the template itself:
   "conversion of nvram template to another target format is not supported"). Internal snapshots then include the NVRAM too
   (marker absent and original `BootOrder` after the revert). Domain XML: `work/win-lab/lab-domain.xml`.
2. The baseline is the **`base-nvram`** snapshot (VM powered off). Before every experiment: `lab.sh stop; lab.sh revert base-nvram; lab.sh start`.
   `base-ssh` (the old baseline) does NOT include the NVRAM: do not use it.
3. **The swtpm (TPM) state is not part of the disk snapshots.** After a revert the disk goes back but the TPM does not: for BitLocker
   this means TPM protectors on disk (sealed under the SRK) stay valid as long as the SRK is the same, but any state in the TPM
   (NV indexes, anti-hammering counters) is the "current" one. For BitLocker experiments, snapshot with the VM powered off and remember that
   the TPM does not roll back.
4. Windows takes a few minutes to answer over SSH after a cold start: wait loops must have timeouts and run in the background.

## Tips

- `Rd` in PowerShell is an alias of `Remove-Item`: never define a function called `Rd`.
- Windows 11 24H2 BitLocker-encrypts (clear key, "protection off") even **newly created data partitions**: GRUB
  sees `-FVE-FS-` and "unknown filesystem". After creation run `manage-bde -off X:`.
- Partitions: Windows and GRUB number them differently (GRUB by position): use labels (`search --label`).
