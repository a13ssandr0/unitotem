# Image runtime configuration

Paths: relative to the repository root.

What runs on a deployed UniTotem image (Debian trixie, arm64 Raspberry Pi and amd64): services, timers, network, Wi-Fi, CPU, SSH, firewall, Wayland session, audio, maintenance mode, persistence. Built by `unitotem/stage2-configure.sh` from `unitotem/files/`; packages from `unitotem/stage1-packages.sh`.

## Files

| Path | Role |
|---|---|
| `unitotem/stage2-configure.sh` | Installs the files below, enables/masks units, sysctl, initramfs |
| `unitotem/files/sshd_config` | sshd policy, `SetEnv` locale, root first-access `Match` block |
| `unitotem/files/unitotem-locale.sh` | `/etc/profile.d/unitotem-locale.sh`: login shells source `/etc/default/locale` (see [Locale of sessions](#locale-of-sessions)) |
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
| `unitotem/files/unitotem-hostname` (+ `.service`) | First boot: device suffix and default host name `unitotem-<suffix>` |
| `unitotem/files/unitotem-persist-paths` (+ `.service`) | Bind-mounts user data from DATA |
| `unitotem/files/unitotem-boot-ok` (+ `.service`), `unitotem-update-auto.*` | See `ab-updates.md` |
| `unitotem/files/journald.conf` | Journal limits |
| `unitotem/files/scheduler.rules` | udev: `mq-deadline` on non-rotational disks |
| `unitotem/files/emergency-dropin.conf` | emergency/rescue shells time out after 120 s, then reboot |
| `unitotem/files/plymouthd.conf` | `Theme=unitotem`, `ShowDelay=0`, `DeviceTimeout=8` |
| `unitotem/files/unitotem-nouveau-fallback.sh` | `/usr/lib/unitotem/nouveau-fallback` (amd64): loads nouveau for an NVIDIA display device with no driver ([NVIDIA](#nvidia-amd64)) |
| `unitotem/files/unitotem-nouveau-fallback.service` | `/usr/lib/systemd/system/unitotem-nouveau-fallback.service`, enabled by a `multi-user.target.wants` symlink |
| `unitotem/files/unitotem-eeprom-update`, `rpi-eeprom-update.service.d-unitotem.conf` | arm64: `/usr/lib/unitotem/eeprom-update` and drop-in `10-unitotem.conf` of the package unit `rpi-eeprom-update.service` ([firmware](firmware.md#automatic-eeprom-staging)) |
| `unitotem/files/ota-preserve.list` | `/etc` paths kept across OTA |
| `unitotem/files/unitotem-pwquality` | PAM profile for the password policy (see [Password policy](#password-policy)) |
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
- Maintenance: `enter` stops manager and compositor (aborts if still active), remounts `/` and `/var/lib/dpkg` rw, `/var/cache` size=1G, `apt-get update`. `exit [--initramfs]` optionally rebuilds initramfs and GRUB, remounts ro, reboots after 5 s; a failed `update-grub` exits 1 without rebooting.
- Persistence: `unitotem-persist-paths` binds `/mnt/data/unitotem/persist/{uploaded,crontabs,browser,home}` onto `/var/lib/unitotem/uploaded`, `/var/spool/cron/crontabs`, `/var/lib/unitotem/browser`, `/home`; seeded from the target on first boot. `/home` is ordered before `ssh.service` and `systemd-user-sessions.service`.
- SSH host keys: `/mnt/data/unitotem/ssh-host-keys` is restored into `/etc/ssh` if present; otherwise keys are generated and copied there.
- TLS: `/etc/ssl/unitotem.pem` generated once (RSA 2048, self-signed, 365000 days); absent from the image; listed in `ota-preserve.list`.
- Sysctl (appended to `/etc/sysctl.conf`): `vm.dirty_writeback_centisecs=3000`, `vm.dirty_expire_centisecs=3000`, `vm.dirty_ratio=5`, `vm.dirty_background_ratio=2`.
- Boot-time fsck repairs without asking (`FSCKFIX=yes` in `/etc/default/rcS`).
- Journal (`/etc/systemd/journald.conf.d/unitotem.conf`): `Storage=persistent`, `Compress=yes`, `SystemMaxUse=512M`, `RuntimeMaxUse=64M`, `SyncIntervalSec=5min`, `MaxLevelStore=warning` (write budget: [storage-and-persistence.md](storage-and-persistence.md)). The manager marks every stderr line with its sd-daemon priority (`<N>` prefix, `utils/_logging.py`, only under `JOURNAL_STREAM`), so its warnings and errors are stored and its INFO lines are not.
- Block scheduler: `mq-deadline` on whole non-rotational disks matching `sd[a-z]`, `nvme[0-9]n[0-9]`, `mmcblk[0-9]`.
- Pi: `vc4` and `v3d` are both listed in `modules-load.d/rpi-gpu.conf` and the initramfs modules; the device tree selects the one it needs.
- Pi hardware decode is V4L2 mem2mem, not VAAPI: `/dev/video10` H.264 (all models), `/dev/video19` HEVC (Pi 4 and later). arm64 has no VAAPI driver.
- sshd reads `.ssh/authorized_keys`: root keys go in `/root/.ssh/authorized_keys` (`/root` is an overlay). Before the first administrator exists, root keys reach the first-administrator script (see [Root and first access](#root-and-first-access)); afterwards root accepts keys only.
- Device apt sources: `deb.debian.org` and `security.debian.org` (suite, `-updates`, `-security`, `-backports`; `main contrib non-free non-free-firmware`); arm64 also `archive.raspberrypi.org`. amd64 has no NVIDIA source: stage 1 removes it. `maintenance enter` runs `apt-get update`.
- Device pins: `97-unitotem-backports` only (priority 990 for the backports packages, see [build](build.md#stages)).
- `/etc/netplan/00-default.yaml` is mode 600.
- `i2c-dev` is loaded at boot (`modules-load.d/unitotem-i2c.conf`); without it DDC/CI and CEC report unavailable.
- Headless: with no reachable display the viewer logs a warning, signals ready and polls every 5 s until a Wayland display appears; a node with no monitor is a supported state.

## ACPI event storm

`unitotem-acpi-storm-guard` (timer: 20 s after boot, then every 30 s, `Nice=19`) samples the counters `gpeNN` of `/sys/firmware/acpi/interrupts` for one second and writes `mask` to every event above 2000 per second, logging `masked ACPI event gpeNN: <rate> events per second` (journal, tag `unitotem-acpi-storm-guard`). A storm that cannot be masked is logged as `cannot be masked`. The mask lasts until the next boot and the check repeats, so a storm that starts later is caught too. The mask is written before, and independently of, the record below. No event number is fixed in the image: it is specific to a firmware. Measured on an HP 250 G5: GPE 03 fired about 10000 times a second, `irq/9-acpi` and `kacpid` took more than a CPU; after the mask the interrupt rate was 0 and the CPU 99.6 % idle. A masked event stops its own notifications (on that laptop: nothing a kiosk needs; battery, lid and hotkeys were not checked).

Record: every storm found, masked or not, is written to `/var/lib/unitotem/acpi-storms` (override: `UNITOTEM_ACPI_STATE`). It is device state on the DATA `/var` overlay, so it survives reboots and A/B updates like `/var/lib/unitotem/notifications.json`; no image-owned file is there. A machine with no storm writes nothing: neither file nor directory. The file is replaced atomically. One line per event:

`gpeNN <first> <last> <rate> <boots> <boot_id> <masked>`

- `first`, `last`: epoch seconds as the device clock said them; the clock can be wrong early in boot.
- `rate`: highest events per second seen.
- `boots`: boots in which the event was masked, counted once per boot.
- `boot_id`: `/proc/sys/kernel/random/boot_id` of the last counted boot.
- `masked`: 1 if the mask was written in that boot, else 0.

Lines that do not match this format are ignored; at most 64 lines are read; a corrupt file counts as empty. A record that cannot be written is logged as a warning; the masking is not affected. The manager shows the record on the Info page and raises a notification (`docs/manager/node-system.md`). Test: `tools/release/test_acpi_storm_guard.sh` (fake interrupts directory and state file).

HP 250 G5 cause (decompiled DSDT, `work/g5-dsdt/DSDT.dsl`): `_GPE._L03` writes BIOS debug code 3, drives GPIO 0x44 high (`WTGP(0x44,1)`) and sends `Notify(\_SB.PCI0.SAT0, 0x81)` (SATA controller information change: the kernel rechecks the SATA ports, for example for an optical drive). The event is level-triggered and stays asserted, hence the storm. With the mask: 0 events per second, nothing new in dmesg after 22 minutes; the disk is unaffected (its own AHCI interrupt).

Prior art: masking a GPE is the usual workaround (kernel parameter `acpi_mask_gpe=`; HP Omen support advice). Kernel bugzilla 219393 (HP Victus): masking did not stop the storm. The only documented side effect: a Framework laptop does not wake from the lid with gpe10 masked. A deferred handler can re-enable a masked GPE; the 30 s repeat covers that.

## Device suffix and host name

`unitotem-hostname` runs once on the first boot (before NetworkManager, avahi and the manager; skipped when `/etc/unitotem/device-suffix` exists). The suffix is the last three bytes of `/etc/machine-id`, six capital hex digits. The image ships an empty `/etc/machine-id` (an empty file, not `uninitialized`: that would start systemd's interactive first-boot setup) and `/var/lib/dbus/machine-id` as a link to it; systemd generates the id on the first boot and the `/etc` overlay keeps it in DATA (`/mnt/data/upper/etc.<slot>/machine-id`, measured on a Pi 4: unchanged across reboots; `machine-id` is in `ota-preserve.list`, so an update carries it to the other slot). A DATA that is wiped is a new identity: new id, new suffix, new name. The script writes the suffix to `/etc/unitotem/device-suffix` and, when the host name is still the default `unitotem` (or empty), sets `unitotem-<suffix>` in lower case (`/etc/hostname`, the `127.0.1.1` line of `/etc/hosts`); a host name chosen by the owner is never replaced. The first-boot hotspot SSID is `unitotem-<SUFFIX>` from the same file (`docs/manager/node-system.md`). Example: id `0123456789abcdef0123456789abcdef` gives `ABCDEF`, host `unitotem-abcdef`.

## NVIDIA (amd64)

- Driver: NVIDIA 620.70.06 with the open kernel modules, for Turing and newer GPUs. Maxwell, Pascal and Volta run on nouveau (NVK, Mesa 26) with `firmware-nvidia-graphics` from stable (63 MiB installed; without it labwc dies at `nvc0_screen_create` and the kiosk never starts); NVIDIA's legacy branch for them is 580 and does not build on kernel 7.2. Build and package set: [build](build.md#stages).
- `nvidia-kernel-support` 620 ships `/etc/modprobe.d/nvidia.conf` with `blacklist nouveau` and `blacklist nova-core`, unconditionally. It ships no `modules-load.d` file and no `nvidia-drm` options, so the image adds:
  - `/etc/modules-load.d/unitotem-nvidia.conf`: `nvidia-drm`;
  - `/etc/modprobe.d/unitotem-nvidia-drm.conf`: `options nvidia-drm modeset=1 fbdev=1`.
- The open modules bind by PCI alias to any NVIDIA device and fail at init on a GPU they do not support. On a Pascal or older GPU nothing would then drive the display. `unitotem-nouveau-fallback.service` covers that case:
  - Unit: `Type=oneshot`, `RemainAfterExit=yes`, `After=systemd-modules-load.service systemd-udev-trigger.service`, `Before=unitotem-compositor.service`, `ConditionPathExists=/sys/bus/pci/devices`, `WantedBy=multi-user.target`.
  - Script `/usr/lib/unitotem/nouveau-fallback`: `udevadm settle --timeout=20`; for every PCI device with vendor `0x10de` and class `0x03xxxx` (display) that has no `driver` symlink, `modprobe nouveau`. An explicit `modprobe` ignores the blacklist. Logs to syslog tag `unitotem-nouveau-fallback`. Exits 0 in every case; no NVIDIA display device means no action.

## Interfaces

Enabled units: `systemd-timesyncd`, `NetworkManager`, `dbus`, `ssh`, `iptables-firewall`, `unitotem-maintenance-mode`, `unitotem-compositor`, `unitotem-boot-ok`, `unitotem-ssh-hostkey`, `unitotem-persist-paths`, `unitotem-first-boot-cert`, `unitotem-net-watchdog.timer`, `unitotem-wifi-roam.timer`, `unitotem-cpu-performance`, `unitotem-update-auto.timer`, `unitotem-nouveau-fallback` (amd64, by symlink, not `systemctl enable`).

Masked: `apt-daily(-upgrade).timer/.service`, `getty@tty1`, `wayvnc`, `wayvnc-control`, `wayvnc-generate-keys`.

- `serial-getty@.service.d/10-unitotem-real-uart.conf` (`unitotem/files/serial-getty-real-uart.conf`): `ExecCondition` skips a serial getty whose `/sys/class/tty/<port>/type` is 0 (no UART behind the port; the kernel line carries `console=ttyS0`). Without it a laptop restarted agetty 199 times in 34 minutes. A port with type != 0 (Pi UART, PC COM) and an unreadable type keep their getty. Checked with a fake sysfs: type 0 skips, 4, 16 and 8250 run, a missing file runs.

Commands:

- `unitotem-maintenance enter | exit [--initramfs]`; other args print usage, exit 1; `enter` exits 1 if a kiosk unit stays active.
- `iptables-firewall.sh start|restart|stop`.
- `unitotem-net-watchdog`, `unitotem-wifi-roam`: no arguments.

Config:

- `/etc/unitotem/net-watchdog.conf`: `ENABLED` (0 disables), `THRESHOLD_MIN` (15).
- `/etc/unitotem/wifi-roam.conf` (optional, `KEY=VALUE` integers): `ENABLED=1`, `GOOD_DBM=-55`, `MARGIN_DB=10`, `MIN_INTERVAL_S=300`, `IGNORE_S=900`. Env: `UNITOTEM_WIFI_ROAM_CONF`, `UNITOTEM_WIFI_ROAM_STATE`. Not shipped; defaults apply.
- `/etc/unitotem/update.conf`: `UPDATE_HEALTH_URL=` (empty) when the image has no manager with `/health`.
- `/etc/NetworkManager/conf.d/60-unitotem-wifi-reconnect.conf`: `[main] autoconnect-retries-default=0` (0 = forever; the default is 4 failed activations, blocked for 300 s), `[connection] wifi.powersave=2`. `connection.autoconnect-retries` is a per-profile property: in `conf.d` NetworkManager 1.52 rejects it ("unknown key") and the limit stayed 4. Verified on a Pi 4: the new key loads without a warning; "forever" read from the 1.52.1 source, not exercised against an access point.
- `/etc/ssh/sshd_config`: `Port 22`, `PermitRootLogin prohibit-password`, `PermitEmptyPasswords no`, `PasswordAuthentication yes`, `PubkeyAuthentication yes`, `MaxAuthTries 5`, `LoginGraceTime 30`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `X11Forwarding no`, `AllowTcpForwarding no`, `SetEnv LANG=<default locale>`, and the final block `Match User root Group unitotem-first-admin` (see [Root and first access](#root-and-first-access)).

Runtime state: `/run/unitotem-net-watchdog.count`, `/run/unitotem-wifi-roam.json`, `/run/unitotem/xdg/wayland-0`, `/run/user/0`.

Kernel command line: `unitotem.maintenance=1` (SSH-only maintenance boot), `unitotem.slot=a|b`, `unitotem.ota.bootcount=1` (legacy token: the boot counter starts from 0 on that boot, see [Boot counter](boot.md#boot-counter)).

Firewall (IPv4 and IPv6): accepts tcp 22, 80, 443, 4443 (paired-node mutual TLS), udp 5353, ICMP/ICMPv6, loopback, ESTABLISHED/RELATED.

Logs: syslog tags `unitotem-net-watchdog`, `unitotem-wifi-roam`; journald keeps warnings and above (`MaxLevelStore=warning`), 512M persistent.

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
- No login prompt on VT1; emergency/rescue shells reboot after 120 s. Root with `*` or an empty password gets no shell from sulogin (`SYSTEMD_SULOGIN_FORCE` is not set).
- The first-boot certificate must not exist in the image; `verify-image.sh` fails the build otherwise.
- SSH host keys live on DATA: they survive OTA and reset only with `--wipe-data`.
- `nvidia-persistenced` and `systemd-modules-load` are patched so non-NVIDIA PCs are not "degraded".
- `nvidia-kernel-support` blacklists nouveau and nova-core unconditionally. On an NVIDIA GPU the open modules do not drive, only the fallback loads nouveau ([NVIDIA](#nvidia-amd64)).
- The compositor unit, labwc config and Wayland environment come from the `unitotem-viewer`/`unitotem-node` packages ([viewer](../manager/viewer.md), [packaging](../manager/packaging.md)).

## Locale of sessions

- Image locale en_US.UTF-8, timezone UTC (`UNITOTEM_LOCALE`, `UNITOTEM_TIMEZONE`, see [build](build.md)).
- sshd runs without PAM, so `pam_env` does not read `/etc/default/locale`: a session starts with `LANG` empty, and btop refuses to start without UTF-8.
- `/etc/profile.d/unitotem-locale.sh` sources `/etc/default/locale` in login shells when `LANG` is unset.
- `sshd_config` has `SetEnv LANG=<default locale>` (set by stage 2 from `UNITOTEM_LOCALE`): every SSH session, with or without a login shell, gets the image locale whatever the client sends. A client locale the image does not have (an Italian client) would only produce `setlocale` warnings, so `AcceptEnv` is not used.

## Root and first access

Stage 2 ships root in the first-access state:

- System group `unitotem-first-admin` (sshd marker).
- Root's shadow field is empty (`passwd -d`); root's login shell is `/usr/sbin/unitotem-first-admin` (manager deb); root is a member of the marker group.
- `unitotem-first-admin` reads the overlay status (`/run/unitotem-overlay.status`, see [Volatile overlays](storage-and-persistence.md#how-it-works)). A volatile boot prints `No data partition: settings are lost on reboot.` and continues. When `/etc` is read-only it prints `Storage is read-only. Account creation is not possible.` and exits 1 before any prompt.
- Every login path runs that shell: sshd (interactive, command, sftp subsystem), console getty and `su` (PAM `pam_unix nullok`, from Debian trixie's `unix` profile in `common-auth`). The script ignores argv and environment and never runs a shell, pager or editor.
- sshd runs with `UsePAM` unset, so sshd checks the empty password and the `*` field itself. The `Match User root Group unitotem-first-admin` block sets `PermitRootLogin yes`, `PermitEmptyPasswords yes`, `ForceCommand /usr/sbin/unitotem-first-admin`, `DisableForwarding yes`, `PermitTunnel no`, `PermitUserRC no`.
- While the window is open, root's `none` authentication is accepted and the forced command is the only protection: no key or password is evaluated, and no shell, sftp, forwarding, tunnel or user rc file is reachable (container test with OpenSSH 10.0 of trixie: command, `/bin/sh`, `-tt bash`, sftp, scp, `-L`, `-D` all end in the script or a refusal). With an administrator present and root still open, a login only prints "Root accepts SSH keys only" until the start-up reconcile closes root. OpenSSH's penalty for repeated failed logins drops key logins too for about 3 minutes.
- sshd matches user or group only, so the marker group is needed: without it a later `passwd root` or `passwd -d root` would reopen root over SSH.
- Membership is read at each connection: no sshd reload.

Closing: after the first administrator exists, the manager runs `close_first_access()`:

1. `gpasswd -d root unitotem-first-admin` (marker removed first).
2. `usermod -p '*' root`: `*`, not `!`. OpenSSH treats `!` as locked and would refuse keys too with `UsePAM` unset.
3. `usermod -s /bin/bash root`.

Root then accepts SSH keys only, from `/root/.ssh/authorized_keys`. The function is idempotent; the manager runs it again at start when an administrator exists and root is still open.

Admins are members of `sudo` (Debian's `%sudo` rule, password required). Web users are members of `users`. Root never logs in to the web.

Emergency and rescue: root `*` or empty gives sulogin no shell; the 120 s timeout then reboot applies.

Identity merge at an A/B update (`unitotem_identity.py`): root's login shell and root's membership of `unitotem-first-admin` come from the current slot, so a closed device never gets the image's open root back. Root's shadow hash is carried as for every account. If the current system has no such group or entry, the image's values apply. Carried accounts keep their `sudo` and `users` memberships. On failure root returns to the image's first-access state (empty password, first-administrator shell).

Re-opening first access on a test device (root over SSH works only with the key until the last step): set root's shell first (`usermod -s /usr/sbin/unitotem-first-admin root`), then `passwd -d root`, remove the administrators, and add root to `unitotem-first-admin` last: from then on every root login runs the script, so a later `usermod` over SSH is refused.

`/home` is bind-mounted from DATA (`persist/home`, 755 root). It is not in the `unitotem-ota-changes` scan.

The OTA fallback and recovery dropbear has no fixed password, independent of the image: its logins are the armed key and the administrators of the installed system (see [fallback authentication](deploy-and-recovery.md#fallback-authentication)).

## Password policy

Always on. PAM is the authority for every path that changes a password: `passwd`, `sudo passwd`, `chpasswd` (manager user changes, first-administrator script). `/etc/pam.d/passwd` and `/etc/pam.d/chpasswd` both `@include common-password`.

`/etc/pam.d/common-password` has exactly one `pam_pwquality` line:

```
password requisite pam_pwquality.so retry=1 enforce_for_root minlen=8 minclass=2 maxrepeat=3 usercheck=1 dictcheck=0
```

- Profile `unitotem-pwquality` (`/usr/share/pam-configs/`, `Conflicts: pwquality`) replaces Debian's stock profile (`retry=3`), which would add a second line. Built in stage 2 (see [build](build.md#stages)).
- Options sit on the PAM line, not in a `pwquality.conf.d` drop-in: a drop-in with a syntax error fails open.
- `dictcheck=0`: no dictionary is installed; `dictcheck=1` refuses every password.
- `enforce_for_root`: without it root gets only a warning; `chpasswd` runs as root.
- `retry=1`: `chpasswd` has no prompt; `passwd` exits 10 after one refusal.
- The image locale is en_US.UTF-8; callers that parse messages set `LANG=C.UTF-8` (messages are English under it).

Refusal messages (stderr; only the first failing check is reported):

- `BAD PASSWORD: The password is shorter than 8 characters`
- `BAD PASSWORD: The password contains less than 2 character classes`
- `BAD PASSWORD: The password contains more than 3 same characters consecutively`
- `BAD PASSWORD: The password contains the user name in some form`

A refused `chpasswd` exits 1 and adds `chpasswd: (user X) pam_chauthtok() failed, error:`, `Authentication token manipulation error`, `chpasswd: (line 1, user X) password not changed`.

Rules observed (pam_pwquality 1.4.5, trixie; `work/pam-matrix/RESULTS.md`):

- Length counts UTF-8 bytes, no credits: 8 bytes with 2 classes pass; 7 are refused whatever the classes.
- Classes: lower, upper, digit, other. Any non-ASCII byte counts as other.
- `maxrepeat=3`: `aaa` passes, `aaaa` is refused anywhere in the password.
- Check order: length, classes, repeat, username.
- `usercheck`: case-insensitive substring of the user name, also reversed. Checked for names of 4+ characters; observed: 3-character names are not checked (differs from pwquality.conf(5)).
- No sequence, GECOS or dictionary check. Spaces and symbols accepted.
- PAM buffer: 511 bytes accepted; 512 gives `Authentication token manipulation error` (no pwquality message); 513+ gives `You must choose a shorter password.`. The manager's 128-character limit is not a PAM rule.
- Non-root `passwd` also refuses the old password (`BAD PASSWORD: The password is the same as the old one`); root `chpasswd` does not check it.
- Accept/refuse results: `unitotem-manager/manager/tests/password_vectors.json` (128 observed results).

Bypasses (PAM not consulted, root only): `usermod -p`, `chpasswd --encrypted` (backup restore), `passwd -d`, direct `/etc/shadow` edits.

On an A/B update the new image's PAM files replace the old ones; no `ota-preserve.list` entry is needed.

## Tests

- `unitotem/verify-image.sh ROOT_MOUNT ARCH [AB_LAYOUT]`: Wi-Fi NM conf, roam, CPU governor, labwc, PipeWire root units, manager drop-in, firewall 4443, no certificate, no blanking in labwc config, root first-access state (empty shadow field, login shell, marker group), sshd root policy and `Match` block, persist `home` entry, password policy (see [Password policy](#password-policy)).
- `python3 tools/release/test_wifi_roam.py`.
- `tools/release/test_eeprom_unit.sh`: EEPROM staging helper and drop-in directives with fake tools (no device).
- Verified on a GTX 1060 (Pascal) passed through to a VM, image 2026.11.53: nvidia.ko fails at GSP init, the fallback loads nouveau, KMS works, and the kiosk runs only with `firmware-nvidia-graphics` installed (1080p60: canvas 60 fps, WebGL2 59.9 fps, H.264/VP9 1080p30 in software, 30 min soak without drops or restarts; 4K60: canvas 42 fps, heavy WebGL2 15.8 fps, no reclocking). Not verified: Secure Boot with the DKMS module, GPU clocks on nouveau, other NVIDIA generations, real hardware outside passthrough.

### Locale and tools

`verify-image.sh` checks:

- `htop` and `btop` installed.
- `/etc/profile.d/unitotem-locale.sh` identical to `unitotem/files/unitotem-locale.sh`.
- `LANG` set in `/etc/default/locale`; `en_US.utf8` generated.
- `SetEnv LANG=<default locale>` in `sshd_config`, before the `Match` block, no `AcceptEnv`.
- `/etc/localtime` links to `/usr/share/zoneinfo/Etc/UTC`.
- Network and firewall on hardware: `nmcli`, `iptables -S`, `ip6tables -S`.
