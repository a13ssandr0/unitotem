# Changelog

## Unreleased

### unitotem-system (since 2022-11-01)

#### Image and build
- Ubuntu 26.04 base and NVIDIA 580/595 driver extensions evaluated under Secure Boot (`docs/system/ubuntu-gpu-evaluation.md`, `tools/ubuntu-proto/`).
- GRUB slot titles `UniTotem <version> (Slot A|B)` (version read from each slot's `grub-version`); `unitotem-boot-entry` names the firmware entry that booted the system `UniTotem` (loader entries only).
- The recovery initrd gets the current `ota-engine.sh` (stage 1b refreshes it from the repository, not the stage 1 tarball); verify-image compares the engine copy of the recovery initrd and of the slot initramfs with the repository's.
- Kiosk image on Debian 13 (trixie), amd64 and arm64, built with Docker or natively on the Pi.
- arm64 uses the Raspberry Pi kernel, raspi-firmware boot files and a slimmed initramfs.
- amd64 boots on BIOS and UEFI; Intel, AMD and NVIDIA GPUs supported, vendor picked at runtime.
- Wayland-only image (labwc); X11 session removed.
- Project renamed from kiosk to unitotem in image, build, tool and unit names.
- Image installs manager packages via apt (metapackage, node, viewer, CEF, theme); no venv or pip.
- Reproducible builds: package versions locked from a Debian snapshot; security updates renew the lock.
- Pre-build update check reports urgency from pocket and changelog.
- Local .deb overrides, parallel prefetch with aria2, persistent apt cache, pigz stage tarballs.
- Stages rebuild when the previous stage changes; interrupted builds clean leftover mounts.
- verify-image checks project rules on the finished image (AppArmor needs auditd, CEF helper exec bit).
- Chromium, compilers, haproxy and DKMS signing private key removed from the image.
- Loopback and power-cut test harnesses for the A/B update path.
- Legacy installer ISO removed (it installed a broken single-root system and asked for a root password); a new A/B installer is planned.
- Neutral defaults: locale en_US.UTF-8 and time zone UTC; SSH sessions get the locale (`/etc/profile.d/unitotem-locale.sh`, sshd `SetEnv LANG`); `btop` added to `htop`; verify-image checks them.
- README: disk size recommendations (Raspberry Pi 32 GB, PC 64 GB, minimum 16 GB); first-login text matches the sudo/users accounts.
- Minimal flash image (`unitotem-<date>-<arch>-flash.img.xz`, boot 512 MiB + slot A, ~5.6 GiB): the first boot creates slot B and DATA to the end of the disk and the existing auto-repair fills slot B; DATA grows to the disk end on raw-written images. Full image, parts and releases are unchanged. Slots 5 GiB, boot partition 512 MiB; fits 16 GB cards.
- Smaller root: GStreamer, `tigervnc-scraping-server`, `nvidia-vaapi-driver`, Mesa Vulkan drivers, `libclang1-19`, NVIDIA CUDA/NVDEC/Vulkan libraries and (arm64) the `firmware-linux*` packages are no longer installed (root asset 639 -> 499 MB arm64, 1059 -> 913 MB amd64); verify-image checks them.
- A power cut inside the first-boot resize of DATA resumes by itself: one `e2fsck -fy`, only while the growth is pending, then the resize continues (reproduced and tested in containers: 163 checks).
- Kernel 7.2, firmware 2026, Mesa 26, PipeWire 1.6 and WirePlumber 0.5.12 from trixie-backports (pinned by file); NVIDIA 620 with the open kernel modules from NVIDIA's repository (Turing and newer); kernel module built by DKMS and signed; `nouveau` fallback unit for older GPUs, with `firmware-nvidia-graphics` shipped (Pascal verified on a GTX 1060 in a passthrough VM).
- amd64 firmware set widened (Intel, Realtek, Atheros, MediaTek, Broadcom Wi-Fi/Bluetooth, microcode); `initramfs-tools` installed before the kernel; unused Chromium flags removed.
- Image root carries the recovery set (`/usr/share/unitotem/recovery`, with a level); verify-image checks it, the NVIDIA stack and the firmware blobs.

#### A/B updates
- A/B root layout is the only layout: ROOT_A/ROOT_B slots, 6 GiB each, 16 GiB image.
- unitotem-update: status, check, fetch, apply, confirm, boot-ok, rollback, cancel, signed manifests.
- Same backend for amd64 GRUB and Raspberry Pi tryboot with os_prefix.
- Trial boot promoted only after unitotem-boot-ok; boot counter and four fallback guarantees.
- Rollback target recorded at fetch; /etc edits and local accounts carried to the new slot.
- Interrupted updates recover: durable state, slot re-verification, forensic events.log.
- Power-cut hardening: read-only FAT, emergency reboot, idle watchdog, journaled DATA with fsck.
- Automatic updates with policy: off, download, stage, reboot or scheduled; staged with backoff.
- Failed slot repair rebuilds the damaged copy from the running slot; runs after plain boot.
- ESP GRUB config follows the image, refreshed after confirmed boot, never downgraded.
- GRUB fallback list uses numeric entries; fallback waits 6 h for a host.
- Persistent on DATA: SSH host key, uploads, TLS key, browser profile, crontabs.
- Update root public key embedded in image; release tooling for keys, assembly, encrypted backup.
- An update leaves the manager and SSH responsive on an SD card: `bfq` and capped dirty pages while the image is written, `xz` on one thread, everything restored afterwards (no web timeouts in 127 probes on a Pi 4).
- After a confirmed boot the boot partition (ESP or Raspberry FIRMWARE) is refreshed with the image's recovery kernel, initrd and dtbs when its level is higher (never on a trial boot); deploy takes the recovery set from the parts set.
- `slot_sound` requires a kernel and initrd on GRUB; update lock no longer unlinked on release; health check verifies TLS against a CA file; `unitotem-maintenance` stops when `update-grub` fails.

#### Deploy and recovery
- `recover` of a node armed with a fixed address installs the system with the same address and gateway (`--net-dns` for the resolvers).
- The deploy checks that the target can open the data connection to the host and, when it cannot (a node behind a VPN), pushes the data through the OTA session into an `nc` on the target's loopback.
- A target that had a fixed wired address reaches the OTA fallback at it: the address and gateway travel on the kernel command line (a node on a routed network has no DHCP server and the earlier system leaves no boot FAT to read them from).
- Deploy through a non-root login user: the escalation message no longer lands inside the backup stream (the archive of a password-sudo target was corrupt).
- Deploy of a Raspberry Pi 4/5 whose firmware has no tryboot: the script first saves the old firmware files, upgrades `raspberrypi-bootloader`, restarts the board and probes again (refused while under-voltage is reported; `--no-firmware-update` skips).
- Deploy probe: dhcp or static is read from the default route protocol, so a stale lease file no longer turns a static node into a DHCP one.
- `remote-deploy.sh deploy` migrates the settings of a 2.x node from its own backup archive (`--admin-user`, `--admin-password-file`, `--timezone`): first administrator, playlist assigned to the windows, media, hostname, time zone, power/reboot timers from the crontab.
- Remote deploy over SSH reflashes existing devices without physical access.
- Two-stage OTA: RAM-resident fallback restores ROOT and BOOT, DATA preserved.
- Adopts stock Raspberry Pi OS and earlier single-root UniTotem devices; network settings carried over.
- Backs up device data with verified checksum before overwrite; stops on failure.
- Pre-OTA check lists local changes the update would destroy; --accept-changes confirms digest.
- Secure Boot detected: shim, no shim or abort; signed shim and GRUB chain staged.
- Non-root SSH targets via sudo; fallback discovery on subnet; --fallback-only option.
- Minimal Raspberry Pi SD image carrying only the OTA fallback.
- Recovery keeps DATA when a read-only fsck passes.
- OTA screen: logo, phase and progress gauge, English text, adapts to any resolution.
- Fallback: DHCP on every wired interface, low-resolution GRUB entries, brcmfmac Wi-Fi modules.
- Deploy post-check probes the web interface instead of logging in as root; `OTA_AUTH=key` mode in `deploy/lib.sh` for hosts with an installed key (the fallback no longer has a fixed password, see below).
- `deploy/lib.sh`: `OTA_FALLBACK_USER`, `OTA_FALLBACK_KEY`, `OTA_FALLBACK_PASSWORD` (environment only), `OTA_FALLBACK_OPEN`; per-target keys under `~/.local/state/unitotem-deploy/`; `recover --fallback-user`; `unitotem-ota-arm --authkey-file`.
- Legacy BIOS amd64 PCs are deployed and recovered like UEFI ones (BIOS-boot partition captured and restored raw); proven in a SeaBIOS VM: deploy, first boot, update with trial, fallback, power cuts, repair, recovery entry.
- Single-root deploy branches removed (A/B only); fallback watchdog stands down only on an authenticated session; `remote-deploy.sh` `changes` exits 0/1/2/3; `make-parts.sh --out` honoured.
- No DATA partition: `/etc`, `/root` and `/var` are tmpfs overlays (state lost on reboot) instead of a read-only root; the status shows `volatile:*`.
- First boot on an MBR disk creates ROOT_B and DATA (pending types 0xda/0xdb); the Raspberry 3 boots a DOS table (`work/pi3-mbr` scripts convert a GPT card in place).
- Boot counter on the boot FAT: after 3 boots without a healthy manager the initramfs enters the OTA fallback (SSH on 2222: boot-FAT key, admin password from DATA, or open mode on a never-configured device); `unitotem-boot-ok` clears it once `/health` answers.
- First-admin script stops with one line when `/etc` is read-only and prints one line when settings are volatile.
- The fallback waits up to 30 s for a USB Ethernet adapter, gives the links 12 s and keeps retrying the network for ~35 min when it has no address (Raspberry Pi 3); `work/pi3-mbr/rewrite-sd-via-fallback.sh` rewrites a whole card remotely through the fallback (proven on a Pi 4: image, read-back hash, first boot creates ROOT_B and DATA on an MBR disk).
- `/home` is a size-capped tmpfs when there is no DATA, so the first administrator can be created.

#### Boot and display
- Secure Boot: the image's boot loader is the Debian-signed shim chain from the first boot (`EFI/BOOT`: shim as `BOOTX64.EFI`, MokManager, signed GRUB, stubs in `EFI/BOOT` and `EFI/debian`), no alternative version of the loader on the ESP; it boots with Secure Boot on or off, so nothing is activated or chosen at deploy: `--secure-boot`, `secure_boot_gate` and the engine's activation step are gone; the ISO, Windows payload and installer follow.
- Secure Boot chain (shim, signed GRUB, signed kernel) booted again under QEMU/OVMF with the Microsoft keys on build 2026.11.66, kernel locked down; the plain image is refused.
- Plymouth UniTotem theme starts before the OTA check; held until the compositor starts.
- Black gap at boot cut to about 0.5 s on Raspberry Pi 4.
- Boot orientation set per display connector on Raspberry Pi and PC.
- Display setup left to KMS; KMS on Pi 3; arm_boost on Pi 4.
- Screen-control tools in image: ddcutil, i2c-tools, cec-ctl; python3-libgpiod.
- Viewer uses CEF's own windowing; PipeWire user units and session D-Bus available from boot.
- /var is an overlay: logs, journal and package state survive reboots; apt works on device.

#### Network and security
- Last-resort wired NetworkManager profile with IPv6 link-local; firewall covers IPv6.
- Net watchdog reboots into OTA mode after sustained missing address; configurable in /etc/unitotem/net-watchdog.conf.
- Wi-Fi profiles retry without limit; roaming helper; radio power save off; performance CPU governor.
- Port 4443/tcp open for paired nodes (mutual TLS).
- VNC on demand via tigervnc; Debian wayvnc services masked.
- TLS certificate generated on first boot; no shared key, user or claim code in the image.
- journald stores INFO messages.
- Root starts without a password and with `unitotem-first-admin` as login shell (SSH, console, su): the first login creates the first administrator; afterwards root accepts SSH keys only (sshd `Match` on the marker group `unitotem-first-admin`).
- No fixed root password in the image (`ROOT_PASSWORD` removed); `/home` persists on DATA; identity merge keeps root's shell and marker membership across A/B updates; verify-image checks the first-access state.
- Password quality enforced by PAM (`pam_pwquality`, profile `unitotem-pwquality`, no dictionary) for `passwd`, `sudo passwd`, `chpasswd`; verify-image checks the profile and the package set.
- OTA fallback has no fixed password: a key armed by the deploy tool (per-target key, kernel command line or boot partition), or the administrators' accounts, passwords and root keys read from DATA; a never-configured device stays open like first access; dropbear runs with `-T 3 -j -k`.

### unitotem-manager (since 2.3.0)

#### Backend and API
- FastAPI and hypercorn with WebSocket API; permission-checked handlers; Pydantic v2 validation.
- Core runs alone on a server; plugins (node, viewer) added on nodes. The service runs as root.
- API schema exported at /api/schema with generated TypeScript declarations.
- Loopback /health readiness probe; per-component subscriptions.
- Uploads in /var/lib/unitotem; manager starts on a read-only root.
- Names, times, codes and file names validated before reaching commands or files.
- Review defects fixed: scheduled enable/disable, upload retries, ticker source removal, remote retries with backoff, network/Wi-Fi/hotspot input validation, timers, backup parts for screens and touch, terminal session limit, devtools paths, VNC cleanup on cancel, audio range, `--version`, bind failure exit status.
- Display outputs API (`Settings/Display/Outputs`: modes, set_mode with 15 s revert, confirm, reset) and screen identify.
- Test isolation: `conftest.py` redirects every import-time path; tests run on a test machine, never on the dev PC.

#### Web UI
- Vuetify interface with dark theme, remember-me login and permission-based menus.
- Floating windows with taskbar; floating preview for images, video, audio, PDF and web assets.
- Notification center per user, freedesktop-compliant, with bell, pop-ups and actions.
- Admin-only web terminal in a floating window; console opens with one-time token.
- Info page with model, uptime, CPU, RAM, temperature and GPU status.
- Snackbar for server errors; reloads itself when the manager restarts.
- Hostname, Wi-Fi, network, audio, backup/restore and updates pages.

#### Accounts and security
- Accounts are system accounts (PAM, group unitotem); users included in backup.
- Multi-user with group permissions; default admin/admin credentials removed.
- One password policy, always on, enforced by PAM and mirrored by the manager (8 bytes, 2 character classes, at most 3 repeated characters, not the user name); the opt-in switch is removed; the setup page and the user dialogs show a live checklist of the rules; refusals show the reason from the system.
- Uploads need authentication; backup restricted to administrators; debug API removed.
- Error pages show no version, OS, IP or hostname.
- First access shows welcome screen with hotspot credentials until an administrator exists.
- Login hardening: rate-limited login and user list (list can be hidden), redirect target restricted to local paths, password in request body, no traceback to clients, user list pushed to administrators only, first-access setup applies the password policy, login shows wrong-password errors.
- Admin = member of the group `sudo`, web access = group `users`; group `unitotem` removed; admins are normal accounts (adduser, home, bash), other users stay web-only (nologin).
- Root never logs in to the web; empty passwords refused.
- First administrator created by `/setup` or by the `unitotem-first-admin` script through one function under one lock; both close root's first-access state; the manager reconciles it at start-up and on `/etc/group` changes.
- Users page: the user list and the replies of add, delete and change of users work again (websocket multicast no longer fails when the message has a `users` field).

#### Playlists and scheduler
- Multiple playlists: rename, default, copy and move assets, drag-and-drop reorder and upload.
- Assets enabled by date and time schedule; per-playlist default duration, per-asset volume and zoom.
- Multi-page PDF upload with page count and per-page rotation.
- PDF pages render with pdf.js standard font data and character maps (non-embedded fonts).
- Per-window playlist assignment, keyed by output name, kept across reboot and screen off.
- Per-window audio output and language passed to pages.
- Internal timers with croniter replace the system crontab; legacy lines imported once.
- Suspend timer wakes the node through the RTC; manual suspend in Power menu.
- Screen timers with screen actions.

#### Layouts and ticker
- Window layout editor: area with margins, split panes, per-pane playlists.
- Per-window orientation and flip kept per screen, with portrait presets.
- RSS ticker: merged feeds, per-source error reporting, compositor-driven crawl.
- Ticker settings per window with live preview, presets and sources manager.
- Scheduled or idle page refresh for web pages, per window.
- Screensaver: home page after idle, playlist plays over it until touch.

#### Viewer and CEF
- Qt6 and CEF viewer replaces Electron; one window per screen, follows mode and rotation changes.
- Mouse pointer hidden from the start of every document and shown only after the first mouse movement, for 10 s (the hiding style was mounted before the document had a root and threw).
- A cookie written by a page in a frame without SameSite gets `SameSite=None; Secure` (a site keeping its language in such a cookie reloaded itself every 3.5 s).
- Wayland-only kiosk under labwc; output names follow the compositor (HDMI-A-1).
- Splash service shows the Plymouth wordmark and spinner until each window's first frame.
- Public-kiosk lockdown: no context menu, downloads, popups, printing or browser shortcuts.
- Crashed or reloaded pages restored automatically; pointer hidden unless a mouse moves.
- H.264 and AAC playback; video-decode switches chosen per GPU; Pi 4 runs at 60 fps.
- Camera and microphone granted without prompts; password manager and autofill off.
- Developer tools in the administrator's browser behind a one-time token.
- Pages that forbid framing shown via allow-framing switch.
- Lean Wayland-only CEF build with en-US locale only; browser profile kept, HTTP cache in RAM.

#### Screens and touch
- Screen power: DPMS first; DDC/CI, CEC, serial, Wake-on-LAN or GPIO line as fallback.
- Operator-off outputs stay off when the monitor reconnects.
- CEC: adapter matched to its HDMI connector (Pi 4 has two), real physical address, OSD name UniTotem, adapter choice in the UI; a TV left in standby wakes at start.
- Settings under an old X11 output name are merged into the compositor name.
- Screen turn and mirror applied by the compositor, also before the boot splash.
- Hot-plugged monitors update the viewers list live; manager runs with zero screens.
- Guided touch calibration (four quarters or five points, trial, keep).
- Touch devices mapped by libinput name; manual orientation via calibration matrix.
- Touch ignored on idle, boot and welcome pages.

#### On-screen keyboard
- On by default; opens next to the touched field, content slides up; can dock partly off screen.
- Layouts, long-press keys and symbols pages from AOSP LatinIME (Apache-2.0): 76 languages, 84 layouts, language and variant picker.
- Number row, shift, caps lock, arrow keys, digit pad, symbol pages, key variants by sliding, key preview.
- Smooth compositor-driven drag; focus watcher sees shadow roots and cross-origin frames.

#### Updates
- Updates page for A/B updates: row per slot, stateful download, install and confirm button.
- Copy button replaces the other slot with a copy of the running one.
- Live progress bar and persistent notification; daily background check.
- Automatic update policy card with mode and scheduled restart time.
- Base compositor configuration in /usr/share/unitotem so updates reach boards.

#### Remote control
- Nodes pair over mutual TLS with pinned certificates; remote websocket on 443 is loopback-only.
- Clients discovered over mDNS; adoption needs fingerprint confirmation.
- Adoption moves playlists, windows, layouts and uploaded files to the server; unpairing returns them.
- Remote page: server and client roles, client list, pairing requests, manual pairing.
- Browser VNC to a window output: admin only, view-only by default, ends on idle or window close.

#### Network
- One Wi-Fi row per network with optional lock; profiles not tied to one access point.
- Static address and DNS saved and applied correctly; ARP answered only on owning interface.
- Hotspot, Wi-Fi on/off and welcome page address follow the default route.
- Stopping the manager no longer disconnects the real Wi-Fi.
- Settings > Date and time: time zone selector and NTP switch/status through systemd-timedated (D-Bus); timers and schedules follow the zone without a restart.

#### Packaging
- Packages: unitotem-manager, unitotem-viewer, python3-cefpython3, plymouth-theme-unitotem.
- Install on Debian 13 system Python without virtualenv; PySide6-Essentials saves about 420 MB.
- python3-cefpython3 built for any architecture, including arm64 cross build.
- Lintian-clean source packages for libraries missing from Debian.
- Container build script and Vite development loop with backend proxy.
- Storage: filesystem usage read from superblocks and tracked on mount events.
