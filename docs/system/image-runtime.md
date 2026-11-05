# Image runtime configuration

Paths: relative to the repository root.

What runs on a deployed UniTotem image (Debian trixie, arm64 Raspberry Pi and amd64): services, timers, network, Wi-Fi, CPU, SSH, firewall, Wayland session, audio, maintenance mode, persistence. Built by `unitotem/stage2-configure.sh` from `unitotem/files/`; packages from `unitotem/stage1-packages.sh`.

## Files

| Path | Role |
|---|---|
| `unitotem/stage2-configure.sh` | Installs the files below, enables/masks units, sysctl, initramfs |
| `unitotem/files/sshd_config` | sshd policy |
| `unitotem/files/iptables-firewall.sh`, `.service` | IPv4/IPv6 firewall |
| `unitotem/files/nm-fallback.nmconnection` | Last-resort wired profile (mode 600, root) |
| `unitotem/files/nm-wifi-reconnect.conf` | NM conf.d: retry Wi-Fi forever, power save off |
| `unitotem/files/unitotem-net-watchdog` (+ `.service`, `.timer`), `net-watchdog.conf` | Reboots into OTA when cabled with no usable address |
| `unitotem/files/unitotem-wifi-roam` (+ `.service`, `.timer`) | Roams to a stronger AP of the same SSID |
| `unitotem/files/unitotem-cpu-performance.service` | CPU governor `performance` |
| `unitotem/files/unitotem-maintenance`, `unitotem-maintenance-mode.service` | Maintenance mode |
| `unitotem/files/unitotem-manager-wayland.conf` | Drop-in: manager waits for the Wayland socket |
| `unitotem/files/unitotem-ssh-hostkey` (+ `.service`) | Per-device SSH host keys on DATA |
| `unitotem/files/unitotem-first-boot-cert` (+ `.service`) | Per-device TLS certificate |
| `unitotem/files/unitotem-persist-paths` (+ `.service`) | Bind-mounts user data from DATA |
| `unitotem/files/unitotem-boot-ok` (+ `.service`), `unitotem-update-auto.*` | See `ab-updates.md` |
| `unitotem/files/journald.conf` | Journal limits |
| `unitotem/files/scheduler.rules` | udev: `mq-deadline` on non-rotational disks |
| `unitotem/files/emergency-dropin.conf` | emergency/rescue shells time out after 120 s, then reboot |
| `unitotem/files/plymouthd.conf` | `Theme=unitotem`, `ShowDelay=0`, `DeviceTimeout=8` |
| `unitotem/files/chromium-accel` | `/etc/chromium.d/50-unitotem-accel` (decode flags) |
| `unitotem/files/ota-preserve.list` | `/etc` paths kept across OTA |
| `tools/release/test_wifi_roam.py` | Roam logic test |

## How it works

- Units are enabled with `systemctl enable` in stage 2. Apt timers are masked.
- Order: `unitotem-first-boot-cert` and `unitotem-persist-paths` before the manager; `unitotem-ssh-hostkey` before `ssh`; `unitotem-boot-ok` after `multi-user.target`.
- Network: NetworkManager is the only renderer (`/etc/netplan/00-default.yaml`, `renderer: NetworkManager`).
- Fallback profile `unitotem-fallback` (autoconnect-priority -999): every wired link gets IPv4 DHCP (may-fail) and an IPv6 link-local address. User profiles win by priority.
- Net watchdog (timer: 5 min after boot, then every 1 min):
  - reconnects a disconnected Wi-Fi (`nmcli device connect`);
  - re-enables IPv6 and raises links with carrier;
  - carrier but no global address for `THRESHOLD_MIN` (15) consecutive minutes: `unitotem-ota-arm --port 2222`. An unplugged unit is never touched.
- Wi-Fi roam (timer: 2 min after boot, then every 30 s): when RSSI is below `GOOD_DBM`, scans and asks the supplicant (`wpa_cli roam`) to move to a same-SSID BSSID at least `MARGIN_DB` stronger. A roam that does not take effect puts that BSSID on an ignore list for `IGNORE_S`. No-op without a wireless interface; always exits 0.
- CPU: `unitotem-cpu-performance` writes `performance` to every `cpufreq/policy*` that offers it.
- Firewall: policy DROP for INPUT/FORWARD, OUTPUT ACCEPT.
- Display: Wayland only. `unitotem-compositor.service` (labwc, from the `unitotem-viewer` package) is enabled; `getty@tty1` is masked. X server packages are purged; `xwayland` stays.
- Manager start: drop-in `20-unitotem-wayland.conf` orders it after the compositor and `user@0.service` and waits up to 60 s for `/run/unitotem/xdg/wayland-0`.
- Audio: PipeWire, pipewire-pulse, wireplumber run as root user units (`ConditionUser=` cleared by `/etc/systemd/user/*.d/10-root.conf`; without it no audio stream appears). Root has linger so `/run/user/0` exists from boot; the manager runs with `XDG_RUNTIME_DIR=/run/user/0` so pulsectl/libpulse find the socket.
- Maintenance: `enter` stops manager and compositor (aborts if still active), remounts `/` and `/var/lib/dpkg` rw, `/var/cache` size=1G, `apt-get update`. `exit [--initramfs]` optionally rebuilds initramfs and GRUB, remounts ro, reboots after 5 s.
- Persistence: `unitotem-persist-paths` binds `/mnt/data/unitotem/persist/{uploaded,crontabs,browser}` onto `/var/lib/unitotem/uploaded`, `/var/spool/cron/crontabs`, `/var/lib/unitotem/browser`; seeded from the target on first boot.
- SSH host keys: `/mnt/data/unitotem/ssh-host-keys` is restored into `/etc/ssh` if present; otherwise keys are generated and copied there.
- TLS: `/etc/ssl/unitotem.pem` generated once (RSA 2048, self-signed, 365000 days); absent from the image; listed in `ota-preserve.list`.
- Sysctl (appended to `/etc/sysctl.conf`): `vm.dirty_writeback_centisecs=3000`, `vm.dirty_expire_centisecs=3000`, `vm.dirty_ratio=5`, `vm.dirty_background_ratio=2`.
- Boot-time fsck repairs without asking (`FSCKFIX=yes` in `/etc/default/rcS`).
- Journal (`/etc/systemd/journald.conf.d/unitotem.conf`): `Storage=persistent`, `Compress=yes`, `SystemMaxUse=512M`, `RuntimeMaxUse=64M`, `SyncIntervalSec=5min`, `MaxLevelStore=info` (the manager logs at INFO).
- Block scheduler: `mq-deadline` on whole non-rotational disks matching `sd[a-z]`, `nvme[0-9]n[0-9]`, `mmcblk[0-9]`.
- Pi: `vc4` and `v3d` are both listed in `modules-load.d/rpi-gpu.conf` and the initramfs modules; the device tree selects the one it needs.
- Pi hardware decode is V4L2 mem2mem, not VAAPI: `/dev/video10` H.264 (all models), `/dev/video19` HEVC (Pi 4 and later). arm64 has no VAAPI driver.
- sshd reads `.ssh/authorized_keys`: root keys go in `/root/.ssh/authorized_keys` (`/root` is an overlay). `PermitEmptyPasswords no`.
- Device apt sources: `deb.debian.org` and `security.debian.org` (suite, `-updates`, `-security`; `main contrib non-free non-free-firmware`); arm64 also `archive.raspberrypi.org`. `maintenance enter` runs `apt-get update`.
- `/etc/netplan/00-default.yaml` is mode 600.
- `i2c-dev` is loaded at boot (`modules-load.d/unitotem-i2c.conf`); without it DDC/CI and CEC report unavailable.
- Headless: with no reachable display the viewer logs a warning, signals ready and polls every 5 s until a Wayland display appears; a node with no monitor is a supported state.

## Interfaces

Enabled units: `systemd-timesyncd`, `NetworkManager`, `dbus`, `ssh`, `iptables-firewall`, `unitotem-maintenance-mode`, `unitotem-compositor`, `unitotem-boot-ok`, `unitotem-ssh-hostkey`, `unitotem-persist-paths`, `unitotem-first-boot-cert`, `unitotem-net-watchdog.timer`, `unitotem-wifi-roam.timer`, `unitotem-cpu-performance`, `unitotem-update-auto.timer`.

Masked: `apt-daily(-upgrade).timer/.service`, `getty@tty1`, `wayvnc`, `wayvnc-control`, `wayvnc-generate-keys`.

Commands:

- `unitotem-maintenance enter | exit [--initramfs]`; other args print usage, exit 1; `enter` exits 1 if a kiosk unit stays active.
- `iptables-firewall.sh start|restart|stop`.
- `unitotem-net-watchdog`, `unitotem-wifi-roam`: no arguments.

Config:

- `/etc/unitotem/net-watchdog.conf`: `ENABLED` (0 disables), `THRESHOLD_MIN` (15).
- `/etc/unitotem/wifi-roam.conf` (optional, `KEY=VALUE` integers): `ENABLED=1`, `GOOD_DBM=-55`, `MARGIN_DB=10`, `MIN_INTERVAL_S=300`, `IGNORE_S=900`. Env: `UNITOTEM_WIFI_ROAM_CONF`, `UNITOTEM_WIFI_ROAM_STATE`. Not shipped; defaults apply.
- `/etc/unitotem/update.conf`: `UPDATE_HEALTH_URL=` (empty) when the image has no manager with `/health`.
- `/etc/NetworkManager/conf.d/60-unitotem-wifi-reconnect.conf`: `connection.autoconnect-retries=0`, `wifi.powersave=2`.
- `/etc/ssh/sshd_config`: `Port 22`, `PermitRootLogin yes`, `PasswordAuthentication yes`, `PubkeyAuthentication yes`, `MaxAuthTries 5`, `LoginGraceTime 30`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `X11Forwarding no`, `AllowTcpForwarding no`.

Runtime state: `/run/unitotem-net-watchdog.count`, `/run/unitotem-wifi-roam.json`, `/run/unitotem/xdg/wayland-0`, `/run/user/0`.

Kernel command line: `unitotem.maintenance=1` (SSH-only maintenance boot), `unitotem.slot=a|b`, `unitotem.ota.bootcount=1`.

Firewall (IPv4 and IPv6): accepts tcp 22, 80, 443, 4443 (paired-node mutual TLS), udp 5353, ICMP/ICMPv6, loopback, ESTABLISHED/RELATED.

Logs: syslog tags `unitotem-net-watchdog`, `unitotem-wifi-roam`; journald keeps level info (`MaxLevelStore=info`), 512M persistent.

## Rules and gotchas

- Apt timers are masked, not disabled: package updates would re-enable them. They also could not take the dpkg lock (`/var/lib/dpkg` is pinned to the read-only ROOT), and background package changes would show up in `unitotem-ota-changes`. Updates go through OTA.
- `unitotem-maintenance enter` stops the manager: a UI on the device loses its own connection, so start the operation detached.
- Maintenance uses `systemctl stop`: the compositor is `Restart=always`, `pkill` would be undone.
- `/var/lib/dpkg` is a separate bind mount: remount it separately from `/`.
- Persist binds are whole directories: crontab replaces its file by rename, which fails on a bind-mounted file.
- NetworkManager keyfiles must be mode 600 and root-owned.
- An interface without an active connection gets `disable_ipv6=1`; the watchdog re-enables it. ICMPv6 stays open for ND/RA/DAD.
- Roaming exists because brcmfmac refuses RSSI notifications and its firmware roaming is off.
- Wi-Fi power save is off: the kiosk is mains-powered.
- No login prompt on VT1; emergency/rescue shells reboot after 120 s.
- The first-boot certificate must not exist in the image; `verify-image.sh` fails the build otherwise.
- SSH host keys live on DATA: they survive OTA and reset only with `--wipe-data`.
- `nvidia-persistenced` and `systemd-modules-load` are patched so non-NVIDIA PCs are not "degraded".
- VAAPI decode flags are amd64 only. Chromium is purged on arm64 images, where `chromium-accel` is inert.
- The compositor unit, labwc config and Wayland environment come from the `unitotem-viewer`/`unitotem-node` packages ([viewer](../manager/viewer.md), [packaging](../manager/packaging.md)).

## Tests

- `unitotem/verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]`: Wi-Fi NM conf, roam, CPU governor, labwc, PipeWire root units, manager drop-in, firewall 4443, no certificate, no blanking in labwc config.
- `python3 tools/release/test_wifi_roam.py`.
- Network and firewall on hardware: `nmcli`, `iptables -S`, `ip6tables -S`.
