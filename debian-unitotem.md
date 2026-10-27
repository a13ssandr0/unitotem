# UniTotem Debian image — reference (amd64 / arm64, Raspberry Pi 4/5)

Debian 13 (trixie). The image is built by `build-unitotem.sh` through the stages in `unitotem/` (`stage0-bootstrap.sh`,
`stage1-packages.sh`, `stage2-configure.sh`, `stage3-image.sh`). This document describes what the resulting system contains
and why. The slot layout and the update mechanism are described in `AB-DESIGN.md`.

---

## 1. Disk layout

| | amd64 (UEFI) | arm64 (Raspberry Pi 4/5) |
|---|---|---|
| boot | `EFI` (FAT32), `BOOT` (ext4, recovery) | `FIRMWARE` (FAT32 1 GiB; shared firmware, `slota/`, `slotb/`, `recovery*`) |
| system | `ROOT_A`, `ROOT_B` (ext4, 6 GiB each) | `ROOT_A`, `ROOT_B` (ext4, 6 GiB each) |
| data | `DATA` (ext4, rest of disk) | `DATA` (ext4, rest of disk) |
| other | `BIOS` (ef02) | |

The running root is passed by the bootloader as `root=` (there is no `/` line in `fstab`). `DATA` is not in `fstab`: the initramfs
hook mounts it and it survives `switch_root`. `DATA` has an ext4 journal; the initramfs runs `e2fsck -p` on it before mounting.

## 2. Base system

- Hostname, locale, time zone and the root password are set at build time. There is no autologin: the X session is started by `start-xorg.service`.
- SSH (`unitotem/files/sshd_config`): password and public-key authentication, root login allowed, `PermitEmptyPasswords no`, `MaxAuthTries 5`,
  `LoginGraceTime 30`, `ClientAliveInterval 300`, `X11Forwarding no`, `AllowTcpForwarding no`. Public keys go in `/root/.ssh/authorized_keys`.
  SSH host keys are kept in `DATA/ssh-host-keys/` so they are shared by both slots (`unitotem-ssh-hostkey`).
- APT sources: Debian `main contrib non-free non-free-firmware` (release, updates, security); on arm64 also `archive.raspberrypi.org`.
  Packages are installed only at build time (see section 14); `apt` is diverted in the final image.
- Network: NetworkManager with netplan (`/etc/netplan/00-default.yaml`, `renderer: NetworkManager`, mode 600).

Base packages (stage 1): `sudo curl wget ca-certificates gnupg2 iproute2 iputils-ping net-tools htop nano less util-linux e2fsprogs
lsb-release initramfs-tools apt-utils dbus dbus-user-session libpam-systemd systemd-timesyncd python3 python3-dbus python3-gi python3-pyudev gir1.2-glib-2.0`.

## 3. Kernel and bootloader

**amd64**: `linux-image-amd64`, `firmware-linux`, `firmware-linux-nonfree`, `firmware-misc-nonfree`, `grub-efi-amd64`, `efibootmgr`;
GRUB is installed for `x86_64-efi` with bootloader id `debian`. Kernel command line: `quiet splash loglevel=3 rd.systemd.show_status=false rd.udev.log_level=3`, `GRUB_TIMEOUT=0`.

**arm64**: `linux-image-rpi-v8`, `firmware-brcm80211`, `firmware-linux`, `firmware-linux-nonfree`, `raspi-firmware` (which ships
`bootcode.bin`/`start*.elf`/`fixup*.dat` and installs them into `/boot/firmware/` from its postinst; see `unitotem/stage1-packages.sh`).
`config.txt` is a single file for both models, using the native `[pi4]`/`[pi5]`/`[all]` filters:

```ini
[all]
arm_64bit=1
max_framebuffers=2
disable_splash=1
boot_delay=0

[pi4]
dtoverlay=vc4-kms-v3d
dtparam=audio=on

[pi5]
dtoverlay=vc4-kms-v3d-pi5
dtparam=audio=on

[all]
```

Kernel command line: `console=tty1 root=PARTLABEL=ROOT_x rootfstype=ext4 rootwait ro quiet splash loglevel=3 rd.systemd.show_status=false plymouth.ignore-serial-consoles`.

`config.txt` is the only one of the three configuration places with conditional syntax. In `modprobe.d`/`modules-load.d` and in the initramfs
module list both GPU drivers are listed (`vc4`, `v3d`): the kernel only binds the one matching the device tree.

## 4. Plymouth boot screen

Packages: `plymouth plymouth-themes plymouth-label libplymouth5` (`plymouth-label` is needed by the status line of the theme).
The `unitotem` theme belongs to the `unitotem-manager` package, not to this image: it matches pixel by pixel the viewer's boot screen
(`manager/webview/static/boot-screen.html`) and uses pre-rendered PNGs (`plymouth/generate-assets.py`).

The manager's `debian/postinst` activates it with two calls, both needed:

```bash
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
    default.plymouth /usr/share/plymouth/themes/unitotem/unitotem.plymouth 100
plymouth-set-default-theme unitotem
update-initramfs -u
```

Plymouth reads the `Theme=` key of `/etc/plymouth/plymouthd.conf` first and only falls back to the `default.plymouth` alternative when it is
missing; `plymouth-set-default-theme` is what writes that key. `/etc/plymouth/plymouthd.conf` in the image contains `ShowDelay=0` and `DeviceTimeout=8`
and no `Theme=` key. `FRAMEBUFFER=y` is set in `/etc/initramfs-tools/initramfs.conf`.

Services can show messages on the splash:

```bash
plymouth message --text="Loading network configuration..."
plymouth update  --status="Starting main service"
```

## 5. Mounts

`fstab` (`unitotem/files/fstab-amd64`, `fstab-arm64`): the system root is mounted `ro`; the FAT boot partition (`EFI` / `FIRMWARE`) is mounted
`ro,nofail` (tools that must write it remount it read-write for the moment they need); `/tmp` (256M), `/run`, `/var/cache` (512M) and
`/var/tmp` (64M) are tmpfs.

> **`/var/tmp` is a 64 MiB tmpfs, and that breaks `mkinitramfs`.** Any operation that regenerates the initramfs — installing or reconfiguring a
> `linux-image-*` package, installing a DKMS driver — builds its staging tree under `/var/tmp` and dies part-way through with
> `No space left on device`, naming only the file it was copying and never the tmpfs. The kernel package is then left unconfigured and `dpkg`
> stays wedged until it is retried. Point `TMPDIR` at the DATA partition first:
>
> ```bash
> mkdir -p /mnt/data/tmp
> export TMPDIR=/mnt/data/tmp
> dpkg --configure -a
> ```
>
> `/var/tmp` is empty after every reboot, so nothing meant to survive one belongs there.

## 6. DATA overlays

`unitotem/files/overlayfs-hook.sh` (initramfs `init-bottom`) mounts `DATA` on `/mnt/data` and overlays `/etc`, `/root` and `/var` with the
per-slot upper directories under `DATA/upper/` (see `AB-DESIGN.md`). If `DATA` is missing or cannot be mounted, the system boots with the root's
own `/etc`. The `overlay` module is in the initramfs module list. The dpkg database is anchored to ROOT, so it travels with the image.

Resetting the persistent state of a slot means removing its upper and work directories on `DATA` while the system is not running.

## 7. GPU drivers and firmware

| Hardware | Packages |
|---|---|
| Intel (Gen 8+) | `intel-media-va-driver-non-free i965-va-driver-shaders libva2 libva-drm2 libva-utils mesa-vulkan-drivers mesa-utils libgl1-mesa-dri` |
| AMD / Radeon | `firmware-amd-graphics mesa-va-drivers mesa-vulkan-drivers libdrm-amdgpu1 libva2 libva-drm2 libva-utils libgl1-mesa-dri` |
| Nvidia | `nvidia-driver nvidia-vaapi-driver libva2 libva-drm2 libva-utils`, plus `options nvidia-drm modeset=1` in `/etc/modprobe.d/nvidia-drm.conf` and `nvidia-drm` in `/etc/modules-load.d/nvidia.conf` |
| Raspberry Pi 4/5 | `mesa-utils libgl1-mesa-dri libgles2-mesa libva2 libva-drm2 libva-utils v4l-utils libv4l-dev libv4l2rds0` |
| all | `libglvnd0 libglx0 libgles2 vulkan-tools libvulkan1` |

Hardware video acceleration is configured at driver level. On the Raspberry Pi there is no VAAPI: decoding goes through the V4L2 mem2mem devices
(`/dev/video10` H.264 on all models, `/dev/video19` HEVC from Pi 4 onwards); see the comments in `unitotem/stage1-packages.sh`.

## 8. Graphical session: X11 without a window manager

The session is a plain Xorg server with **no window manager**. The Qt6+CEF viewer of `unitotem-manager` (in process, see `manager/webview/`) sets the
fullscreen geometry, rotation and flip of every per-screen window itself, and CEF can only embed X11 windows (`CefWindowInfo.SetAsChild` reparents a native
X11 window into the Qt window, which Wayland does not allow).

Packages:

```bash
apt-get install -y \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth
```

PipeWire, pipewire-pulse and wireplumber are enabled as root user units (symlinks in `/root/.config/systemd/user/default.target.wants/`).
No standalone browser and no virtual keyboard are installed: assets are rendered inside the `unitotem-manager` process. The cursor is hidden by the X server's `-nocursor` flag.

**Start-up**: X runs as a systemd service independent of any login session, on a dedicated VT (tty8, so it does not contend for tty1).

`/etc/systemd/system/start-xorg.service`:
```ini
[Unit]
Description=X11 session (kiosk)
After=multi-user.target

[Service]
TTYPath=/dev/tty8
StandardInput=tty
StandardOutput=journal
UnsetEnvironment=TERM
# startx/xinit fall back to $HOME/.Xauthority only when $XAUTHORITY is not set, and
# $HOME/.Xauthority is not writable on this image's read-only root: xinit would retry the
# connection forever with a cookie that is never valid and never launch xinitrc. Pointing
# XAUTHORITY at a fixed tmpfs path makes xinit populate it directly; unitotem-manager.service
# reads the same path through its own Environment=XAUTHORITY=, so no copy is needed.
Environment=XAUTHORITY=/run/unitotem-x11.auth

ExecStartPre=/usr/bin/chvt 8
ExecStart=/usr/bin/startx /etc/unitotem/xinitrc -- vt8 -keeptty -nocursor -verbose 3 -logfile /dev/null
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

`/etc/unitotem/xinitrc`:
```sh
#!/bin/sh
# No window manager: the viewer sets its own fullscreen windows. Only X server tuning here.
xset -dpms
xset s off
xset s noblank
xsetroot -solid black
exec sleep infinity
```

`unitotem-manager.service` sets:
```ini
Environment=DISPLAY=:0
Environment=XAUTHORITY=/run/unitotem-x11.auth
```

`WebviewApp.display_available()` (`manager/webview/app.py`) checks both `$DISPLAY` and the existence of the `/tmp/.X11-unix/X{num}` socket *before* touching
Qt/CEF, because building them without a usable display aborts the whole process natively (SIGABRT). `manager/main.py` polls every 5 s until a display is
available; a node with no monitor attached is a supported, possibly permanent, situation.

## 9. Crash resistance and I/O

- `/etc/sysctl.conf`: `vm.dirty_writeback_centisecs = 3000`, `vm.dirty_expire_centisecs = 3000`, `vm.dirty_ratio = 5`, `vm.dirty_background_ratio = 2`.
- journald (`unitotem/files/journald.conf`): `Storage=persistent`, `Compress=yes`, `SystemMaxUse=512M`, `RuntimeMaxUse=64M`, `SyncIntervalSec=5min`,
  `MaxLevelStore=info` (the manager logs everything at INFO, so a stricter level would drop all of its output).
- udev (`unitotem/files/scheduler.rules`): `mq-deadline` on non-rotational `sd*`, `nvme*n*`, `mmcblk*` disks.
- `FSCKFIX=yes` in `/etc/default/rcS`.

## 10. Maintenance mode

The root is read-only. `/etc`, `/root` and `/var` are overlays on DATA and are always writable; remounting `/` is only needed to write to `/usr`, `/lib`, `/bin`.

```
unitotem-maintenance enter                 # stops unitotem-manager.service and start-xorg.service, verifies they are stopped,
                                           # remounts / read-write and /var/cache with size=1G
unitotem-maintenance exit [--initramfs]    # optionally runs update-initramfs -u -k all, update-grub (amd64), sync,
                                           # remounts / read-only and reboots after 5 seconds
```

The services are stopped with `systemctl stop` (not `pkill`): `start-xorg.service` is `Restart=always`.

A boot can also start in maintenance mode: `unitotem-maintenance-mode.service` is conditional on `unitotem.maintenance=1` on the kernel command line,
remounts `/` read-write and enlarges `/var/cache`, so a management system can add the parameter via SSH and reboot to update without console access.

Typical flow: connect via SSH, `unitotem-maintenance enter`, `apt-get update && apt-get upgrade`, then `unitotem-maintenance exit --initramfs` (kernel or initramfs updated) or `unitotem-maintenance exit`.

## 11. Checks after installation

```bash
vainfo; ffmpeg -hwaccels        # video acceleration (Pi: v4l2-ctl --list-devices)
systemctl status start-xorg
ls /tmp/.X11-unix/              # the X0 socket must exist
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth xrandr
```

The cursor must never appear, neither on touch nor on mouse movement (`-nocursor`).

Plymouth test without rebooting:
```bash
plymouthd --no-daemon --debug &
sleep 1 && plymouth --show-splash
plymouth update --status="Test boot service..."
sleep 3 && plymouth --quit
```

## 12. Multi-monitor hot-plug test in a VM (QEMU)

`unitotem-manager` detects the number of connected screens (`QApplication.screenAdded`/`screenRemoved` in `manager/webview/app.py`) and notifies the
server over WebSocket (`WebviewInfo`), which rebroadcasts `Viewers/list` to every connected client; the Viewers and Settings/Display pages update
without a reload. Hot-plug and hot-unplug are verified end to end without restarting `unitotem-manager`.

Two screens in QEMU only need `max_outputs=2`:
```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -device virtio-vga,max_outputs=2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=overlay.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:443 \
  -device virtio-net-pci,netdev=net0 \
  -vnc :1 -monitor unix:monitor.sock,server,nowait -daemonize -pidfile qemu.pid
```

The second virtio-gpu connector (`Virtual-2`) starts **disconnected**. The kernel DRM connector is the source of truth, and as root it is driven through
debugfs (`force` is a generic DRM core file); SPICE, `xrandr --auto`, `xrandr --setmonitor` and QMP do not flip the `Connected` bit Qt filters on.

```bash
ls /sys/kernel/debug/dri/0/                 # Virtual-1  Virtual-2  crtc-0  crtc-1  ...

# plug: force the connector to connected, which raises a DRM/udev hotplug event
echo on > /sys/kernel/debug/dri/0/Virtual-2/force
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth xrandr --query
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth \
  xrandr --output Virtual-2 --mode 3840x2160 --right-of Virtual-1

# unplug: the CRTC must also be turned off, otherwise it stays active
echo off > /sys/kernel/debug/dri/0/Virtual-2/force
DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth xrandr --output Virtual-2 --off
```

`/sys/class/drm/card0-Virtual-2/status` may keep showing `disconnected` after a successful force: it is the raw EDID probe, not what Xorg/RandR use.
The reliable signal is `xrandr --query`.

Verification: with `max_outputs=2` the manager starts with 1 screen / 1 window; after plug, `Viewers/list` (WebSocket `/ws`, login via `/auth/token`) shows
2 screens / 2 windows within ~1 s with the geometry of the assigned mode; after unplug it returns to 1/1; `window_id` is always incremental and never reused.

## 13. Remote deploy: two-stage OTA over the network

The image (`unitotem-<date>-<arch>.img.xz`) is deployed entirely over the network, without removing the SD/disk from the target or mounting its root while it runs.

Every image carries a minimal **resident fallback** kernel+initrd (generated by `unitotem/stage1-recovery-initrd.sh`; no UniTotem rootfs, only what is
needed to speak SSH and receive an OTA) on the boot partition next to the real system's kernel. The deploy has two stages:

1. **Stage 1** installs/updates the fallback on the boot partition and makes it **the boot default**: from then on any power loss returns the machine to
   receiving mode, never to a half-written disk.
2. **Stage 2** restores ROOT (and BOOT on amd64) partition by partition with `partclone`, keeps DATA by default, repopulates the real system's
   kernel/initrd/dtb, arms a **trial boot** (never the default until confirmed) and reboots. Only after `unitotem-boot-ok.service` confirms the boot does
   the real system become the default.

Two independent network channels: **control = SSH** (`dropbear` in the fallback, fixed password `root`/`unitotem`, ephemeral host key regenerated at every boot, never shared between devices) and
**data = plain netcat** (one dedicated connection per partition). The gain over a whole-disk `dd` is in **bytes written**: only the space actually used (~3 GiB typical), not the whole image (12 GiB).

Four independent levels keep the fallback reachable after a failure during or after the deploy: boot default, pre-mount and post-mount validation in the real
system's initramfs, and a boot counter (three consecutive unconfirmed boots → automatic fallback).

```bash
./deploy/make-parts.sh --arch arm64 --image deploy/arm64/unitotem-<date>-arm64.img.xz   # builds the parts set

./deploy/remote-deploy.sh probe   root@totem-01
./deploy/remote-deploy.sh deploy  root@totem-01                    # target already UniTotem: arms remotely
./deploy/remote-deploy.sh deploy  root@totem-01 --wipe-data        # same, but reformats DATA
./deploy/remote-deploy.sh disarm  root@totem-01                    # cancels an arming that has not started yet
```

From a running UniTotem system the arming can also start locally: `/usr/sbin/unitotem-ota-arm --host <host-ip> [--port N] [--wipe-data]`.

Facts to know:
- Supported targets: Raspberry Pi (arm64) and amd64 (UEFI or BIOS); the target firmware is detected automatically (`/sys/firmware/efi`, `/proc/device-tree/model`).
- Post-restore addressing uses labels (`blkid -L ROOT/DATA`): with several UniTotem disks attached to the same machine the result is ambiguous (`probe` scans all disks and warns about duplicate labels).
- `deploy/remote-deploy.sh recover`/`serve` (recovery path for a target already in fallback with an unknown host) is an advanced path.

## 14. Repeatable builds: package lock (`unitotem/locks/<arch>.lock`)

A build does not depend on what the archives offer today. The lock lists every archive package with its exact version (`name==version`, like a requirements.txt)
and the moment (`apt-snapshot`) of the apt index it was installed from; our own packages (`unitotem-*`, the CEF wheel, the repackaged Python libraries) are recorded as
`local` but not pinned: they are the product, not a dependency.

- **Stage 1 with a lock:** Debian archives are read from `snapshot.debian.org` at the lock's date, every package is pinned to its version (apt preference 1001),
  and at the end of the stage the installed set must match the lock EXACTLY (`pkglock.py verify`): any difference stops the build.
- **Without a lock** (first build or after `upgrade`): the live archives are used and at the end of stage 1 `work/<arch>/<arch>.lock.new` is written;
  copy it to `unitotem/locks/<arch>.lock` and commit it.
- **Check before every build** (`build-unitotem.sh`, also for later stages): `tools/pkglock.py check` queries the archives and prints what is newer than the lock. It changes nothing by itself.
  - **SECURITY** = the update comes from the `trixie-security` pocket, or the Debian changelog between the pinned and the new version cites CVEs.
    **The build renews the lock by itself**: it retires the old lock (`pkglock.py upgrade <arch>`), reinstalls every package from stage 1 at the current
    versions and freezes a new lock, which `build-unitotem.sh` stores in `unitotem/locks/<arch>.lock` (commit it). `PKGLOCK_KEEP=1` keeps the old lock whatever the check finds.
  - Other updates are only reported.
  - **Urgency:** apt does not expose it in its metadata. The pocket and the `urgency=` field (with CVEs) of the Debian changelog for each entry between the two versions are used;
    archives that publish no changelog (Raspberry Pi) show `urgency n/a` (only the pocket is known). Urgency alone does not block.
  - **Backports:** a separate section lists newer versions available in `trixie-backports` for kernel, Mesa, NVIDIA, firmware, PipeWire... (not used: they are decisions, not updates).
- Packages are always downloaded from the online repositories; only version numbers are stored in the repository. The Raspberry Pi archive (arm64) has no snapshot: if it
  drops a pinned version the build stops with the list and the lock must be renewed (`upgrade`).
- `tools/pkglock.py snapcheck <lock>` checks that the pinned versions are still online; `PKGLOCK=off` skips everything.
