# Manager: functional specification

Paths: relative to `unitotem-manager/`

UniTotem Manager controls kiosk screens from a web UI. It has three parts:

- **Scheduler**: plays playlists of assets on the viewer windows.
- **Management UI and API**: HTTPS web UI backed by a websocket API.
- **Viewer**: one fullscreen window per connected screen.

Technical documentation: [scheduler.md](scheduler.md), [webui.md](webui.md), [viewer.md](viewer.md), [remote.md](remote.md), [security.md](security.md), [node-system.md](node-system.md).

## Pages

| Route | Page | Content |
|---|---|---|
| `/` | Scheduler | Playlist selector, asset table (reorder, quick controls, edit), uploads |
| `/viewers` | Viewers | Playlist per window, window layouts (panes), RSS sources |
| `/info` | Info | Uptime, CPU per core, memory, temperatures, fans, storage |
| `/settings/audio` | Audio | Default output, per-device volume and mute |
| `/settings/display` | Display | Layout overview, orientation and flip, touch, screen control |
| `/settings/remote` | Remote | Role, clients, pairing, leave or forget |
| `/settings/users` | Users | Accounts, capabilities, password change with the rules checklist |
| `/settings/timers` | Timers | Scheduled reboot, shutdown, suspend, screen on/off |
| `/settings/datetime` | Date and time | Time zone, network time (NTP) |
| `/settings/network` | Network | Hostname, devices, connections, Wi-Fi |
| `/settings/updates` | Updates | Installed version, check, fetch, apply, confirm, rollback, policy |
| `/settings/backup` | Backup | Backup, restore and reset of selected parts |
| `/login`, `/setup` | Login, first administrator | Login with system account; `/setup` (name, password with the rules checklist) only while no administrator exists |

Header: hostname, theme (light, dark, auto), notification bell, reboot, suspend, power off, user menu. Admin only: terminal and screen view (view-only by default).

Login page: hostname, IP address and version. Login can be remembered for 7 days.

Settings tabs are shown only when the user holds the matching capability. A user without access to a route is redirected to the first allowed page.

## Roles

Accounts are system accounts (PAM). Web login is allowed for members of group `users`; root never logs in to the web. Administrators are members of group `sudo`. Each account has capabilities:

| Capability | Allows |
|---|---|
| `scheduler` | Playlists, assets, uploads, per-asset volume, viewer assignments |
| `audio` | Window and device volume and output device |
| `power` | Reboot, suspend, power off |
| `admin` | All capabilities, plus every settings page, remote control, updates, backup, timers, terminal, screen view |

Rules:

- Admin status is membership of `sudo`; the administrator also has a shell and a home directory. Demotion keeps the home directory.
- The last user cannot be deleted; a user cannot delete itself.
- An admin cannot remove its own admin role.
- Changing a password or removing an account ends that user's sessions.
- Passwords are stored only in the system (`/etc/shadow`), never by UniTotem.
- Password policy is always on and enforced by PAM (`pam_pwquality`) for every password change: at least 8 characters (UTF-8 bytes), at least 2 of lowercase, uppercase, digits, symbols, no run of more than 3 identical characters, and no username (or its reverse) when it has 4 or more characters. Maximum 128 characters. The manager and the web UI show the same rules before submitting. Details: [security.md](security.md).

## Scheduler

### Playlists

- Each playlist is an ordered list of assets with its own default duration (default 30 s).
- One playlist is the default: it receives uploads and is the target of calls without a playlist.
- A playlist cannot be deleted when it is the default or the last one.
- Assets are not shared between playlists. Copy and move between playlists create new asset identities.

### Assets

| Kind | Source | Duration |
|---|---|---|
| Web page | `http`/`https` URL | Playlist default |
| Image | Upload or URL | Playlist default |
| PDF | Upload | One page per duration |
| Video, audio | Upload or URL | Length of the media (uploads) |

Asset properties:

- **Fit**: contain (default), cover, fill.
- **Background colour**: behind the asset.
- **Enabled**: disabled assets are skipped.
- **Enable and disable dates**: switch the asset on or off automatically. Past dates on creation apply at once; edited dates must be in the future.
- **Volume and mute**: only for assets with audio. Independent of system volume.
- **Zoom and pinch zoom**: web pages.

### Playback

- Enabled assets play in order and repeat. The next asset starts when the duration ends.
- Changes (add, edit, move, delete, enable) apply at once.
- With no enabled asset, or with a window that has no playlist, the window shows the idle page: the welcome page until the first administrator exists, then the "no assets" page.

### Uploads

- Files go to the uploads folder and are added to the default playlist as disabled.
- Names are sanitised; duplicate names get a numeric suffix.
- The uploads list shows name, size, duration (media), the playlists using each file, and disk usage.
- Multiple selection: delete, download, add to a playlist.
- Deleting a file removes every asset that references it.

### Routing

- Each viewer window has a main pane. Its playlist is the window assignment.
- One playlist can drive any number of windows.
- A window can be split into up to 8 panes (binary layout, depth up to 4). Each pane plays its own playlist.
- A window has an area (percent rectangle) and a margin colour.
- Closing the main pane promotes the next pane.
- Deleting a playlist unassigns its windows.

## Viewers

- One viewer window per connected screen. Windows are added and removed as screens are connected and disconnected.
- A window of a newly connected screen has a unique identity and shows the idle page until a playlist is assigned.
- With zero screens the manager, scheduler and API keep working.
- Window state changes reach the web UI as pushed events. Pages do not poll.
- Per-window settings: playlist, sound output and volume, language, on-screen keyboard, interactive screen, refresh, screensaver, developer tools.
- RSS ticker: global feeds, per-window bar (position and colours). Admin only.

## Remote control

### Roles

- **Server** (default). A standalone node is a server with no clients.
- **Client**. A client shows playlists assigned by its server.

### Pairing

- A server lists known clients: paired but offline, or connected. It can temporarily enable or disable a client, unpair it, or open its configuration.
- An unpaired client announces itself on the local network. Servers show discovered clients and propose adoption.
- Manual pairing: enter the other node's IP address and optionally its port, on either side.
- Adoption checks the fingerprint of the other node's certificate, confirmed by the administrator.
- A client's request to join must be approved by the server's administrator. Requests expire after 10 minutes.

### Content on adoption

- The client's playlists and uploads move to the server.

### Content on unpair and leave

- Unpair moves to the client the playlists and uploads that only that client uses. Content shared with other nodes stays on the server.
- Offline unpair is refused, unless forced. A forced unpair forgets the client without moving content.
- Leave: a client asks its server to unpair it, and becomes a standalone node with its local content.

### Security

- Connections use TLS 1.3 with certificates exchanged at pairing. Certificates are pinned: no certificate authority, and no hostname check.
- A connection with an unknown or disabled certificate is rejected at once.
- Pairing and certificates are a part of the backup.
- Content is sent as checked, resumable file transfers. The receiving node applies a transfer all or nothing.
- A client keeps local copies of the files its windows play.

## Settings areas

| Area | Functions |
|---|---|
| Audio | Default output device, volume and mute per device |
| Display | Layout overview (position, rotation); per-window content orientation and flip; touch mapping and calibration; screen power, input, volume (DDC/CI, CEC, Wake-on-LAN, serial, GPIO); GPU status |
| Remote | Role, pairing, clients, approval, leave, forget |
| Users | Accounts, capabilities, password change (rules checklist) |
| Timers | Cron-style jobs for reboot, shutdown, suspend, screen on/off. Run by the manager; no system cron |
| Date and time | Time zone (searchable list), network time (NTP) on or off |
| Network | Hostname (also updates `/etc/hosts`), devices, saved connections, Wi-Fi scan and connect, Wi-Fi roaming, hotspot |
| Updates | Version, check, download, install, confirm, rollback, automatic policy |
| Backup | Backup, restore and reset of selected parts: playlists, window layouts, users, security settings, pairing and certificates, RSS sources, uploads (optional in a backup), hostname, default audio device, network (netplan), timers, touch mapping |

## Updates

- The manager never downloads or writes images itself. It runs the system update tool and shows the result.
- Checks run daily in the background. A hint appears in the navbar when a new version is available.
- Install is confirmed by the user. After a reboot the new version is confirmed only if its health endpoint answers. Otherwise the previous version is restored.
- Shared configuration stays compatible with the previous version for one release, so rollback is safe.

## Info

- Uptime, CPU usage per core, memory, disk partitions and usage, temperatures, fans, batteries where available.
- Pushed to every logged-in user every 3 seconds.

## Notifications

- Bell in the navbar with list, badge and pop-ups.
- Notifications can carry an action and a link.
- Used for updates, remote pairing requests and client status.
