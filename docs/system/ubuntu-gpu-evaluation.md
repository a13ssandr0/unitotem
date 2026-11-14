# Ubuntu base and GPU driver extensions (evaluation)

Paths: relative to the repository root. Scripts: `tools/ubuntu-proto/` (build-server paths inside). Measured 2026-11-14.

## Result
- Ubuntu 26.04 chain (shim 15.8, GRUB 2.14, kernel 7.0.0-43) boots under OVMF Secure Boot with the Microsoft keys: `SecureBoot` 1, lockdown `[integrity]`.
- NVIDIA kernel modules come precompiled and signed by `Canonical Ltd. Kernel Module Signing`; the kernel accepts them under lockdown, no MOK.
- A driver can ship as a systemd-sysext image over a base without any NVIDIA file.
- Verified on a GTX 1060 3GB (Pascal), passed through to a Secure Boot VM, driver 580.178.04 (proprietary modules): `nvidia-smi`, `nvidia-drm` modeset with `fb0`, labwc (headless backend, GLES2) rendering with `GL renderer: NVIDIA GeForce GTX 1060 3GB/PCIe/SSE2`.
- Not verified: 595 open modules on a Turing or newer GPU (only the signature check and module load in QEMU: `NVRM: No NVIDIA GPU found`); a connected monitor; video decode; real firmware with Secure Boot (venus); Ubuntu loader on A/B with the OTA fallback.

## Versions (archive indexes of the build host)
| | Ubuntu 26.04 | image now |
|---|---|---|
| kernel | 7.0.0-43 | 7.2.12 |
| Mesa | 26.0.8 | 26.1 |
| PipeWire / WirePlumber | 1.6.2 / 0.5.13 | 1.6.9 / 0.5.12 |
| NVIDIA | 595 (open modules, Turing+), 580 (proprietary, Pascal and older) | 620 open |
| labwc | 0.9.3 (universe) | |

## Findings
- Signed GRUB's prefix is `(ESP)/boot/grub`: the stub `grub.cfg` (search label, `configfile`) goes at `/boot/grub/grub.cfg` of the ESP; `EFI/BOOT/grub.cfg` is not read.
- The signed modules are assembled by the packages' postinst into `/lib/modules/<kver>/kernel/nvidia-<branch>/`; no package owns them: the extension build copies that directory.
- The extension carries the regenerated `modules.*` indexes: the merged `/usr` then resolves the NVIDIA modules without `depmod`.
- The GBM backend (`nvidia-drm_gbm.so`, `libnvidia-allocator`) is in `libnvidia-extra-<branch>`, not in `libnvidia-gl`.
- `libnvidia-gl-580` conflicts with `libnvidia-egl-gbm1` and depends on `libnvidia-compute-580` (333 MB).
- The image name must equal the name in `usr/lib/extension-release.d/extension-release.<name>`.
- Merging before `systemd-udevd` deadlocks the boot (sysext waits for `local-fs.target`, which needs the EFI device, which needs udev). Working order: default sysext order, `nouveau` blacklisted in the base, then `udevadm trigger --action=add --subsystem-match=pci` after the merge (4 s boot, driver bound).
- dpkg cannot run while the extension is merged (`/usr` read-only): unmerge first.
- The repository's initramfs hook (`unitotem/files/ota-hook`, engine, partclone, dropbear, whiptail) builds on Ubuntu's initramfs-tools (125 MB initrd) and the system boots with it.

## Sizes
| item | installed | squashfs (zstd 19) |
|---|---|---|
| extension 580 (gl 532 MB, compute 333 MB, modules 195 MB, rest) | 1.7 GB | 814 MB |
| extension 595 open | 1.0 GB | 469 MB |
| base root (kernel, `linux-firmware` 688 MB, modules 173 MB, Mesa, tools) | 3.2 GB with 1.1 GB apt cache | |
