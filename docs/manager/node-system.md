# Node plugin (unitotem-node)

Machine management of a UniTotem node: NetworkManager (Wi-Fi, hotspot, IP, hostname), audio, OS updates through `unitotem-update`, power, suspend and timers, screen view (VNC), web terminal, viewer developer tools, backup parts. Package `unitotem-node`, needs the core, which loads it only through `PLUGIN` hooks. Screens and touch: [screens-and-touch.md](screens-and-touch.md).

Paths: relative to unitotem-manager/; `P` = `manager/plugins/unitotem_node/`.

## Files

| Path | Role |
|---|---|
| `P__init__.py` | `PLUGIN`: API classes, routers, backup parts, start-up / first-boot / shutdown hooks |
| `Papi/network.py` | `Settings/Network/*` |
| `Papi/audio.py` | `Settings/Audio/*` |
| `Papi/timers.py` | `Settings/Timers/*` |
| `Papi/power.py` | `Power/*` |
| `Papi/updater.py` | `Settings/Update/*`, status polling |
| `Papi/vnc.py` | `Vnc/*` |
| `Papi/display*.py` | display API ([screens-and-touch.md](screens-and-touch.md)) |
| `Psystem/network/networkmanager.py` | NetworkManager over D-Bus: devices, connections, activation, Wi-Fi profiles |
| `Psystem/network/hotspot.py` | first-boot / fallback hotspot profile, Wi-Fi QR |
| `Psystem/network/wifi.py` | radio switch, scan, access points |
| `Psystem/network/netplan.py` | `/etc/netplan` files, backup part only |
| `Psystem/dbus_system.py` | logind (power, suspend), hostnamed (hostname, `/etc/hosts`) |
| `Psystem/audio.py` | PulseAudio sinks (pulsectl) |
| `Psystem/updater.py` | client of `unitotem-update --json`, availability, notifications |
| `Psystem/update_progress.py` | inotify on `/run`, pushes progress and the bell progress bar |
| `Psystem/timer_actions.py` | timers loop, action execution, `MinuteClock` |
| `Psystem/suspend.py` | suspend with scheduled wake, logind sleep signals |
| `Psystem/wake.py` | wake-time computation (pure, croniter) |
| `Psystem/rtc.py` | `/sys/class/rtc` alarm, clock shift check |
| `Psystem/vnc.py` | `wayvnc` lifecycle, command line, stale session sweep |
| `Psystem/desktop_notifications.py` | `org.freedesktop.Notifications` server |
| `Pmodels/timers.py` | `Timer`, `TimerManager`, `timers.json`, crontab import |
| `Pterminal.py` | `/terminal` websocket (pty + `login -f`) |
| `Pvnc.py` | `/vnc` websocket bridge, `/vnc/token` |
| `Pdevtools.py` | `/devtools/*`: developer tools of a viewer window |
| `Pws_token.py` | one-time tokens and Origin check for the three websockets |
| `manager/utils/backup.py`, `manager/routers/backup.py` | backup engine and endpoints (core) |
| `debian/org.unitotem.Notifications.conf` | D-Bus policy: only root owns the notifications name |

## How it works

- Start-up: stale VNC sessions swept; tasks for screens (wake, probe), touch mapping, timers loop, sleep watch, hostname watch, update progress watch, daily update check (first after 180 s, then every 24 h), desktop notifications.
- First boot: with no default IPv4 route the hotspot starts. `first_boot_context` returns SSID, password and QR while it is active.
- Hotspot: NM profile id `UniTotem first boot hotspot`, mode `ap`, IPv4 `shared`. Its UUID is `hotspot_uuid` in `/etc/unitotem/unitotem.env` (generated once). Default SSID = hostname; default password = last 8 hex digits of the Wi-Fi MAC, uppercase. Recreated when the requested SSID/password differ from the stored ones.
- Hotspot stop: after a successful `activate_connection` or `connect_wifi` when the hotspot is active and IPv4 is up, and at manager shutdown. The Wi-Fi device is disconnected only if the hotspot is its active connection; then the profile is deleted.
- Network changes go through NM D-Bus only (no nmcli, no netplan writes). A Wi-Fi profile is identified by UUID; `connect_wifi` updates it if the UUID exists.
- Wi-Fi list: one row per network name, the strongest shown with the access-point count. `connect_wifi` sends a `bssid` only when the visitor switches on "Only use this access point". A profile tied to a BSSID never roams to a stronger AP (symptom: packet loss growing with packet size); `edit_connection(unlock_bssid=true)` drops the tie, and the editor shows it as a switch.
- Every mutating call answers with broadcasts of the state it changed (devices, active connections, connections, hostname).
- Audio: a missing sound server gives `available: false` and an empty list, not an error.
- Updates: the manager never downloads or writes images. It runs `unitotem-update --json <cmd>` (timeout 180 s). `fetch`, `apply`, `repair` detach and return at once; `Settings/Update/status` is pushed every 2 s while `status.op` is set.
- Update progress: inotify on `/run` for `unitotem-update.progress` (trailing throttle 1 s). Whether an operation runs is decided by `status.op`, not by the file: it stays after the end and a killed updater leaves a "running" one. Slot names in every text are capitals (A, B).
- Availability: a successful check stores `{available, version, checked_at}` and raises or resolves `update.available`. A failed check keeps the previous value.
- Timers: the loop wakes at each minute boundary or on resume. Actions: `pwr` logind PowerOff, `reb` logind Reboot, `sus` suspend with wake, `scr_on` / `scr_off` screen power (`system/screens/control.set_power`).
- Suspend is refused when the clock has no wake-up alarm (`wakealarm` absent): a machine without RTC, such as the Raspberry Pi 4, cannot suspend with wake.
- Suspend: every refusal is checked before anything changes (logind CanSuspend, RTC usable, wake time sane). Alarm written via sysfs, then logind `Suspend`. A failed suspend clears the alarm. On `PrepareForSleep(false)`: alarm cleared, `resumed` event set, screens woken.
- `Power/reboot` with `status.staged` runs `unitotem-update reboot` instead of logind reboot.
- VNC: `POST /vnc/token`, then `WS /vnc`. `wayvnc` starts on a UNIX socket in `/run/unitotem-vnc/<token>/` and stops on socket close, server exit, shutdown or idle timeout.
- Terminal: `POST /terminal/token`, then `WS /terminal`. Starts `setsid -c /bin/login -f <account>` on a pty.
- Backup parts of the plugin: `hostname`, `audio`, `netplan`, `timers`, `touch`. Core parts are in [backend.md](backend.md).

## Interfaces

### Websocket API (`Class/function`)

- `Settings/Network/` (admin unless noted): `hostname()` (any user); `set_hostname(hostname)`; `default_wlan_device()`; `has_wireless()`; `wireless_enabled()`; `set_wireless_enabled(enabled)`; `wireless_networks()` (scans, enables radio if off); `devices()`; `connections()`; `active_connections()`; `connection_details(path)`; `activate_connection(conn_path, dev_path)`; `deactivate_connection(active_path)`; `connect_wifi(ssid, device, password?, bssid?, ip_method='auto', ip_address?, prefix_len=24, gateway?, dns?)` returns `connected_uuid`; `edit_connection(conn_path, conn_id?, autoconnect?, ip_method, ip_address?, prefix_len, gateway?, dns?, ssid?, password?, unlock_bssid=false)`; `delete_connection(conn_path)`.
- `ip_method`: `auto` (DHCP) or `manual` (needs `ip_address`). `dns`: list of dotted IPv4.
- `Settings/Audio/` (audio or admin): `devices()` returns `devices[{name, description, muted, volume}]`, `default`, `available`; `set_default_device(device)`; `set_volume(volume, device?)`; `set_mute(mute, device?)`. No `device` = default sink.
- `Settings/Timers/` (admin): `jobs()` returns `jobs`, `actions`; `add_job(command, minute, hour, day_of_month, month, day_of_week, output?, mechanism='auto', wake?)`; `edit_job(uuid, ...)`; `set_job_enabled(uuid, state)`; `delete_job(uuid)`.
- Job fields: `uuid, command, minute, hour, day_of_month, month, day_of_week, enabled, output, mechanism, wake`; for `sus` also `next_suspend, next_wake, wake_problem`. Commands: `pwr`, `reb`, `sus`, `scr_on`, `scr_off`.
- `Power/`: `reboot()` (power or admin); `poweroff()`; `suspend_support()` returns `available, reason, rtc, rtc_local, min_sleep, max_sleep, last_refusal`; `suspend(wake_at)` with `YYYY-MM-DDTHH:MM` in node local time.
- `Settings/Update/` (admin; `availability` any user): `status()`, `check()`, `fetch(force=False)`, `apply(reboot=True)`, `confirm()`, `rollback(reboot=True)`, `cancel()`, `copy_to_other()`, `set_policy(mode, time='04:00')` (mode: `off`, `download`, `stage`, `reboot`, `scheduled`), `availability()`. Events: `Settings/Update/status`, `Settings/Update/availability`.
- `Vnc/outputs()` (admin) returns `outputs[{name, width, height, x, y}]` (active outputs) and `available` (`wayvnc` installed).
- Errors: `WSResponse(error=..., extra=...)`, e.g. `Invalid timer`, `Not found`, `Unknown action`, `Cannot suspend`, `Cannot use this suspend timer`.

### Updater status (`unitotem-update`; slot names are capitals)

- Keys used: `supported`, `slot`, `other_slot`, `default_slot`, `op` (null or `{progress: {op, phase, percent, eta_s, cause}}`), `staged`, `auto`, `last_result {op, result, slot, cause, error}`, `error`, `error_code`, `returncode`; the manager adds `copy_from`.
- `error_code` set by the manager: `bad-output`, `failed`, `timeout`.
- Phases: `check`, `download`, `write`, `verify`, `arm`, `reboot`. Causes: `label`, `fsck`, `mount`, `empty`, `bootfile:<name>`.
- Exit codes: 0 ok; 2 failed; 10 nothing to do; 12 busy; 13 no rollback; 127 absent (`supported: false`).
- The updater contract is in [ab-updates.md](../system/ab-updates.md).

### HTTP and websocket

- `POST /vnc/token`, `POST /terminal/token` (409 if the account has no shell), `POST /devtools/open {window_id}` returns `{path}` (404 no page, 503 viewer not running), `GET /devtools/<file>`.
- `WS /vnc?output=NAME&control=1`: first text frame `{"token"}`; binary frames RFB; text `{"activity": 1}` keeps the session alive.
- `WS /terminal`: first frame `{"token"}`; binary frames pty data; text `{"resize": [cols, rows]}`.
- `WS /devtools/ws/<token>/<page>`: token in the path.
- Close codes: 1008 not authenticated / forbidden / bad token; 1011 cannot start (VNC: `wayvnc` missing); 1013 session limit; 1000 normal end with reason text.

### Files, environment, system interfaces

- `/etc/unitotem/timers.json`: `{"timers": [Timer...]}`, atomic write (`.tmp`, fsync), directory = dirname of `--assets_file`.
- Crontab import (once, when `timers.json` is missing): root crontab lines marked `unitotem:-)` and `screen_control.json`. The crontab is not modified.
- `/etc/unitotem/unitotem.env`: `hotspot_uuid`.
- `UNITOTEM_VNC_IDLE_TIMEOUT`: seconds, default 0 (never).
- Read/written: `/sys/class/rtc/rtcN/wakealarm`, `/sys/class/rtc/rtcN/device/power/wakeup`, `/etc/adjtime` (line 3 `UTC`|`LOCAL`), `/etc/hosts`, `/run/unitotem-update.progress`, `/run/unitotem-vnc/`, `/usr/sbin/unitotem-update`, `/usr/bin/wayvnc`.
- D-Bus (system bus): `org.freedesktop.NetworkManager`; `org.freedesktop.login1.Manager` (Reboot, PowerOff, Suspend, CanSuspend, PrepareForSleep); `org.freedesktop.hostname1`.
- Serves `org.freedesktop.Notifications` on the user bus and the system bus, each only if the name is free. Capabilities: `actions`, `body`, `persistence`.
- Notification keys: `update.available` (info), `update.progress` (persistent bar), `update.failed` (error), `update.repaired` (info), `suspend.problem` (warning, link `/settings/timers`).

### Permissions

Default admin. `Power/*`: power or admin. `Settings/Audio/*`: audio or admin. No permission: `Settings/Network/hostname`, `Settings/Update/availability`.

## Rules and gotchas

- Timers never run a command line: actions are the fixed names above.
- Schedules are evaluated on naive local datetimes: croniter gives a wrong first occurrence after a DST change with tz-aware datetimes.
- `MinuteClock`: same minute or clock set back: nothing. Forward jump while awake: current minute only. After resume: up to 5 missed minutes, oldest first, except `sus`: a late suspend never runs; `suspend.problem` is raised instead. A timer never runs twice because the clock went back.
- Suspend: wake-up at least 120 s and at most 7 days away. The RTC offset (RTC minus system clock) must match `/etc/adjtime` within 300 s or the RTC is refused. Local-time RTCs get the measured shift added to the alarm. Saving a suspend timer simulates 8 days of runs (`wake.check_pair`).
- No inhibitor lock: nothing before sleep may depend on running.
- Hotspot stop runs on every manager stop and must touch nothing but the hotspot (`_hotspot_is_active` compares `ActiveConnection.connection` with the settings path).
- NM DNS entries are uint32 in little-endian order. SSID, BSSID, MAC are byte arrays (lists in JSON).
- `/etc/hosts`: exactly one `127.0.1.1` line for the hostname; the old name is removed from loopback aliases; written atomically with the same owner and mode. Hostname: 1-64 characters from `[A-Za-z0-9.-]`, no `..`.
- `copy_to_other` copies the running slot to the other one only.
- RTC alarm: `wakealarm` takes UTC epoch seconds. A pending alarm cannot be overwritten (EBUSY): clear first, `clear_quietly` after a failed write. An alarm in the past is accepted without effect: read it back. Many RTCs cannot hold an alarm 24 h or more ahead. asyncio sleeps use the monotonic clock, which stops during suspend: a wall-clock loop needs the wake-up on resume.
- Desktop notifications: `expire_timeout` -1 = level default, 0 = until clicked, >0 = that long; critical never expires. `NotificationClosed` reason 1 expired (the id is invalid, the bell keeps the entry), 2 dismissed or action on a non-resident notification, 3 `CloseNotification`; `ActionInvoked` `default` is a click; `CloseNotification` of an unknown id is a D-Bus error. Test a negative timeout with `busctl -- -1`.
- `except ImportError` around a name that does not exist fails silently (`NetworkManager*` fallback `None` shows no address on any device): check real names with `dir(module)` on the target (sdbus-networkmanager: `ActiveConnection`, `IPv4Config`) and log the fallback as an error.
- `Power/reboot` with a staged update uses the updater restart: on a Raspberry Pi only that restart starts an armed update.
- Backup: `timers` restore replaces all timers; `audio` restore only for archives from 3.0.0 or later; `netplan` restore runs `netplan apply`. Reset empties each part.
- VNC: no TCP listener, no VNC password (the 0700 root-owned directory under `/run` is the guard). View-only is enforced by the server (`--disable-input`). `--disable-resizing`, 20 fps, max 2 sessions, one output per session. `sweep_stale` signals only a pid whose command line names its own socket.
- Terminal: never `fork` (multi-threaded process): `setsid -c` through the subprocess machinery. `login -f`: the web account is already authenticated. Accounts with shell `nologin` or `false` are refused. Environment limited to `TERM` and `PATH`. Max 4 terminals; closed after 15 min without input. Account names are validated (`osusers.valid_name`) before `login`.
- Tokens: 30 s, single use, bound to account and session id (and page for devtools). The socket must be same-origin (Origin = Host).
- Desktop notifications: markup stripped from the body; `body-markup` not advertised; 20 per application per 60 s; critical never expires; ids never 0.

## Tests

- `.venv/bin/python -m pytest <files>` from the repository root.
- `manager/tests/`: `test_network_details.py`, `test_hotspot_stop.py`, `test_timers.py`, `test_suspend.py`, `test_vnc.py`, `test_hosts_file.py`, `test_update_progress.py`, `test_updater.py`, `test_desktop_notifications.py`.
- Live checks: `tools/ui-terminal.py`, `tools/ui-vnc.py`.
