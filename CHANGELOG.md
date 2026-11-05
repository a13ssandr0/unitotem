# Changelog

## Unreleased

### unitotem-system (since 2022-11-01)

#### Image and build
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

#### Deploy and recovery
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

#### Boot and display
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

### unitotem-manager (since 2.3.0)

#### Backend and API
- FastAPI and hypercorn with WebSocket API; permission-checked handlers; Pydantic v2 validation.
- Core runs alone on a server; plugins (node, viewer) added on nodes. The service runs as root.
- API schema exported at /api/schema with generated TypeScript declarations.
- Loopback /health readiness probe; per-component subscriptions.
- Uploads in /var/lib/unitotem; manager starts on a read-only root.
- Names, times, codes and file names validated before reaching commands or files.

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
- Password rules follow passwd/useradd; strict policy opt-in.
- Uploads need authentication; backup restricted to administrators; debug API removed.
- Error pages show no version, OS, IP or hostname.
- First access shows welcome screen with hotspot credentials until an administrator exists.

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
- Screen turn and mirror applied by the compositor, also before the boot splash.
- Hot-plugged monitors update the viewers list live; manager runs with zero screens.
- Guided touch calibration (four quarters or five points, trial, keep).
- Touch devices mapped by libinput name; manual orientation via calibration matrix.
- Touch ignored on idle, boot and welcome pages.

#### On-screen keyboard
- On by default; opens next to the touched field, content slides up; can dock partly off screen.
- Android-style layouts for 739 languages with language and variant picker.
- Number row, shift, caps, symbol pages, key variants by sliding, key preview.
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

#### Packaging
- Packages: unitotem-manager, unitotem-viewer, python3-cefpython3, plymouth-theme-unitotem.
- Install on Debian 13 system Python without virtualenv; PySide6-Essentials saves about 420 MB.
- python3-cefpython3 built for any architecture, including arm64 cross build.
- Lintian-clean source packages for libraries missing from Debian.
- Container build script and Vite development loop with backend proxy.
- Storage: filesystem usage read from superblocks and tracked on mount events.
