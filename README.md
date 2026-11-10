# UniTotem

UniTotem is a managed kiosk system for digital signage. It runs on an immutable Debian image and plays playlists of web pages, images, videos, PDFs and RSS tickers on one or more screens, controlled from a web UI.

## Features

- Playlists with per-asset duration, fit mode, background colour, enable and disable dates
- Per-screen viewer windows, with split layouts (panes) and per-window playlist assignment
- Local files (uploads) and content URLs
- Per-asset and per-window volume, per-device audio output
- Pairing of nodes (server and client roles) with certificate-pinned mutual TLS
- Built-in timers: reboot, shutdown, suspend and screen on/off, with cron schedules
- Network management (Wi-Fi, hotspot, hostname), display orientation and flip, touch calibration
- Users and capabilities (scheduler, audio, power, admin)
- Live system info (CPU, memory, temperatures, fans, storage)
- Backup, restore and reset of selectable parts
- Whole-image A/B updates with automatic rollback

## Supported hardware

| Target | Image |
|---|---|
| PC, 64-bit Intel or AMD (UEFI or BIOS) | amd64 disk image |
| Raspberry Pi 4 and Raspberry Pi 5 | arm64 disk image |

A display connected to the HDMI or DisplayPort output is required.

## Disk size

The image written to the card is about 5.6 GiB (boot partition 512 MiB and root slot A of 5 GiB, of which 2.5-3.2 GB are used). At the first boot the system creates root slot B (5 GiB) and the data partition (the rest of the disk: uploaded media, configuration, browser profile), and copies slot A to slot B. The system is therefore about 11 GiB; a smaller disk cannot run it.

| Target | Recommended | Minimum |
|---|---|---|
| Raspberry Pi | 32 GB card (about 20 GB for content); 64 GB or a USB SSD with many videos | 16 GB card (about 3.5 GB for content) |
| PC | 64 GB SSD; 128-256 GB with long videos | 16 GB |

- Content is the only part that grows: size the disk for the media to be uploaded.
- Each update writes about 3 GB to the inactive slot: use a high-endurance or A2 card of a known brand on a Raspberry Pi.

## Install

Disk images are built from this repository (see Build from source): `unitotem-<date>-arm64-flash.img.xz` and `unitotem-<date>-amd64-flash.img.xz` are the images to write to a card or disk. GitHub Releases carry the signed update streams that installed nodes fetch, not disk images.

**Raspberry Pi**

1. Write the arm64 image to a microSD card (see Disk size) with Raspberry Pi Imager ("Use custom") or any image writer.
2. Insert the card and power on.

**PC**

1. Write `unitotem-installer-<date>-amd64.iso` to a USB stick (`dd` or Rufus in DD mode), boot the PC from it and follow the screen. It asks which disk and a typed confirmation before it writes, works offline and with Secure Boot on. See [docs/system/installer-iso.md](docs/system/installer-iso.md).
   Alternative: write the amd64 flash image to the target disk with any image writer and boot from that disk.

**Network deploy**

`deploy/remote-deploy.sh` installs or recovers a node over the network from a host, through the resident OTA fallback. See [docs/system/deploy-and-recovery.md](docs/system/deploy-and-recovery.md).

## First login

- The welcome screen shows the hostname and IP address.
- Without a network connection, the node starts a hotspot. Its name is the hostname; its password is shown on screen with a QR code.
- Open `https://<hostname or IP>/` from a browser. Port 80 redirects to HTTPS.
- The certificate is self-signed: the browser shows a warning to accept once.
- On a new node, `/setup` creates the first administrator. Later, log in with a system account: administrators are the members of the group `sudo`, other web users the members of `users`. Root does not log in to the web.

## Updates

- The system is replaced as a whole image on two root slots (A/B). Packages are never upgraded at runtime.
- Images come from GitHub Releases and are checked against signed keys and manifests.
- The new slot boots on trial. It becomes the default only after the manager answers `GET /health`. Otherwise the node rolls back to the previous slot.
- User data (configuration, certificates, uploads) is kept across updates.
- Automatic policy (Settings, Updates): `off` (default), `download`, `stage`, `reboot`, or `scheduled` (daily reboot in a one-hour window, default 04:00).
- Check, apply, confirm and rollback are also available manually.

## Build from source

The scripts in the repository build the amd64 and arm64 disk images from the package sets pinned in `unitotem/locks/`. See [docs/system/build.md](docs/system/build.md).

## Documentation

Full documentation is in [docs/README.md](docs/README.md).

## License

GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE). Third-party code, data and libraries are listed in [THIRD-PARTY.md](THIRD-PARTY.md).
