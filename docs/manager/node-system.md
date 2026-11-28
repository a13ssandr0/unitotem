# Node plugin (unitotem-node)

Machine management of a UniTotem node: NetworkManager (Wi-Fi, hotspot, IP, hostname), audio, OS updates through `unitotem-update`, power, suspend and timers, time zone and network time, screen view (VNC), web terminal, viewer developer tools, backup parts. Package `unitotem-node`, needs the core, which loads it only through `PLUGIN` hooks. Screens and touch: [screens-and-touch.md](screens-and-touch.md).

Paths: relative to unitotem-manager/; `P` = `manager/plugins/unitotem_node/`.

## Files

| Path | Role |
|---|---|
| `P__init__.py` | `PLUGIN`: API classes, routers, backup parts, start-up / first-boot / shutdown hooks |
| `Papi/network.py` | `Settings/Network/*` |
| `Papi/audio.py` | `Settings/Audio/*` |
| `Papi/timers.py` | `Settings/Timers/*` |
| `Papi/date_time.py` | `Settings/DateTime/*` |
| `Papi/power.py` | `Power/*` |
| `Papi/updater.py` | `Settings/Update/*`, status polling |
| `Papi/firmware.py` | `Settings/Firmware/*`, status polling |
| `Papi/acpi_storms.py` | `Settings/AcpiStorms/list` |
| `Papi/vnc.py` | `Vnc/*` |
| `Papi/display*.py` | display API ([screens-and-touch.md](screens-and-touch.md)) |
| `Psystem/network/networkmanager.py` | NetworkManager over D-Bus: devices, connections, activation, Wi-Fi profiles |
| `Psystem/network/hotspot.py` | first-boot / fallback hotspot profile, Wi-Fi QR |
| `Psystem/network/wifi.py` | radio switch, scan, access points |
| `Psystem/network/netplan.py` | `/etc/netplan` files: no caller (no backup part, NetworkManager is the network) |
| `Psystem/dbus_system.py` | logind (power, suspend), hostnamed (hostname, `/etc/hosts`), timedated (time zone, NTP) |
| `Psystem/audio.py` | PulseAudio sinks (pulsectl) |
| `Psystem/updater.py` | client of `unitotem-update --json`, availability, notifications |
| `Psystem/update_progress.py` | inotify on `/run`, pushes `Settings/Update/status` and the bell progress bar, raises the `update.*` results |
| `Psystem/firmware.py` | client of `unitotem-firmware --json` (Raspberry Pi firmware card) |
| `Psystem/firmware_progress.py` | inotify on `/run` (helpers shared with the updater), pushes `Settings/Firmware/status` and the bell progress bar |
| `Psystem/acpi_storms.py` | parser and watch of `/var/lib/unitotem/acpi-storms` (written by `unitotem-acpi-storm-guard`), pushes `Settings/AcpiStorms/list`, raises `acpi.storm.*` |
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

- Start-up: stale VNC sessions swept; tasks for screens (wake, probe), touch mapping, timers loop, sleep watch, hostname watch, date and time watch (`datetime_watch`), update progress watch, firmware progress watch, ACPI storm watch, daily update check (first after 180 s, then every 24 h), desktop notifications.
- First boot: with no default IPv4 route the hotspot starts. `first_boot_context` returns SSID, password and QR while it is active.
- Hotspot: NM profile id `UniTotem first boot hotspot`, mode `ap`, IPv4 `shared`. Its UUID is `hotspot_uuid` in `/etc/unitotem/unitotem.env` (generated once). Default SSID = `unitotem-<SUFFIX>` (the suffix `unitotem-hostname` writes to `/etc/unitotem/device-suffix` on the first boot, see `docs/system/image-runtime.md`; the hostname cut to 32 bytes when the file is missing); default password = last 8 hex digits of the Wi-Fi MAC, uppercase. Recreated when the requested SSID/password differ from the stored ones. SSID 1-32 bytes, passphrase 8-63 characters; an out-of-range value raises `ValueError` before anything is read or written.
- Hotspot stop: after a successful `activate_connection` or `connect_wifi` when the hotspot is active and IPv4 is up, and at manager shutdown. The Wi-Fi device is disconnected only if the hotspot is its active connection; then the profile is deleted.
- Network changes go through NM D-Bus only (no nmcli, no netplan writes). A Wi-Fi profile is identified by UUID; `connect_wifi` updates it if the UUID exists.
- Wi-Fi list: one row per network name, the strongest shown with the access-point count. `connect_wifi` sends a `bssid` only when the visitor switches on "Only use this access point". A profile tied to a BSSID never roams to a stronger AP (symptom: packet loss growing with packet size); `edit_connection(unlock_bssid=true)` drops the tie, and the editor shows it as a switch. An SSID that is not UTF-8 is listed with replacement characters; it does not fail the list.
- `connect_wifi` and `edit_connection` check the SSID (1-32 bytes) and passphrase (8-63 characters, or 64 hex digits as a raw key; an empty passphrase means open) and the BSSID (six hex octets). Any invalid value answers `{error: 'Invalid Wi-Fi settings', extra}` and nothing is written to NetworkManager.
- Every mutating call answers with broadcasts of the state it changed (devices, active connections, connections, hostname).
- Audio: a missing sound server gives `available: false` and an empty list, not an error. Volume is a 0.0-1.0 level: values outside are clamped; NaN, infinity and non-numbers are refused (`ValueError`) and nothing is sent to Pulse.
- Updates: the manager never downloads or writes images. It runs `unitotem-update --json <cmd>` (timeout 180 s). `fetch`, `apply`, `repair` detach and return at once. `Settings/Update/status` is pushed by the progress watch and once after each command (`fetch`, `cancel`, `apply`, `confirm`, `rollback`, `copy_to_other`). No polling.
- Update progress: inotify on `/run` for `unitotem-update.progress` (trailing throttle 1 s). Whether an operation runs is decided by `status.op`, not by the file: it stays after the end and a killed updater leaves a "running" one. The updater releases its lock after its last write, so a final state (`done`, `failed`, `cancelled`) is read once more 1 s later (late refresh). Slot names in every text are capitals (A, B).
- Update notifications:
  - `update.progress`: one per operation, level `error` (the highest level: a slot write must not go unnoticed), persistent (not dismissable while it runs), progress bar. It covers the download (`fetch`) and every slot copy: manual copy, self-healing rebuild, first-boot clone of ROOT_B. Raised again only when its title, level or operation changes; otherwise moved with `set_progress`.
  - Title of a copy (`copy_from` set, or a repair whose cause is `first-boot`, `unprepared` or none): `Copying slot A to slot B`. Title of a rebuild: `Rebuilding slot B after damage` (cause `label`, `fsck`, `mount`, `bootfile:<name>`), `Rebuilding slot B (incomplete system)` (cause `empty`).
  - Text: the phase (`Checking`, `Downloading`, `Verifying`, `Preparing the restart`, `Restarting`); `NN / NN MB` while writing when both sizes are sane; `about N s left`. A copy write shows no phase word.
  - End of an operation: the bar is removed and the result is told once: `update.fetched` (info, `Update downloaded`), `update.repaired` (info, `Slot B copied` / `Slot B rebuilt`), `update.failed` (error, `Update failed`, `Copying the slot failed`, `Rebuilding the slot failed`; text is the updater's `error`). A successful result resolves `update.failed`.
  - After a manager restart with a bar still up: the bar is removed and the result is taken from `status.last_result` only when its `op` is `fetch` or `repair` and its `at` (UTC) is not older than the bar. Without a bar nothing is told.
  - `update.progress` and the `update.*` results are for admins only (`audience: admin`).
- Firmware: `unitotem-firmware --json <cmd>` (`status`, `check`, `apply --files --eeprom`); the manager only starts it and reads its answers. Exit codes 0 ok, 10 nothing to do, 12 busy, 14 blocked (`blockers`), 2 failed, 127 absent (`supported: false`). `apply` returns at once; `Settings/Firmware/status` is pushed every 2 s while `status.op` is set, on each progress file change, and after each `check`. Progress: `/run/unitotem-firmware.progress`, same inotify watch as the updater.
- Availability: a successful check stores `{available, version, checked_at}` and raises or resolves `update.available`. A failed check keeps the previous value.
- Timers: the loop wakes at each minute boundary or on resume. Actions: `pwr` logind PowerOff, `reb` logind Reboot, `sus` suspend with wake, `scr_on` / `scr_off` screen power (`system/screens/control.set_power`).
- Suspend is refused when the clock has no wake-up alarm (`wakealarm` absent): a machine without RTC, such as the Raspberry Pi 4, cannot suspend with wake.
- Suspend: every refusal is checked before anything changes (logind CanSuspend, RTC usable, wake time sane). Alarm written via sysfs, then logind `Suspend`. A failed suspend clears the alarm. On `PrepareForSleep(false)`: alarm cleared, `resumed` event set, screens woken.
- `Power/reboot` with `status.staged` runs `unitotem-update reboot` instead of logind reboot.
- VNC: `POST /vnc/token`, then `WS /vnc`. `wayvnc` starts on a UNIX socket in `/run/unitotem-vnc/<token>/` and stops on socket close, server exit, shutdown or idle timeout. Its directory is removed even when the stop itself is cancelled (`stop()` cleans up in a `finally`).
- Terminal: `POST /terminal/token`, then `WS /terminal`. Starts `setsid -c /bin/login -f <account>` on a pty.
- Backup parts of the plugin: `hostname`, `audio`, `timers`, `touch` (mapping, orientation, calibration), `screens` (output configuration, not the probe results). Core parts are in [backend.md](backend.md).

## Interfaces

### Websocket API (`Class/function`)

- `Settings/Network/` (admin unless noted): `hostname()` (any user); `set_hostname(hostname)`; `default_wlan_device()`; `has_wireless()`; `wireless_enabled()`; `set_wireless_enabled(enabled)`; `wireless_networks()` (scans, enables radio if off); `devices()`; `connections()`; `active_connections()`; `connection_details(path)`; `activate_connection(conn_path, dev_path)`; `deactivate_connection(active_path)`; `connect_wifi(ssid, device, password?, bssid?, ip_method='auto', ip_address?, prefix_len=24, gateway?, dns?)` returns `connected_uuid`; `edit_connection(conn_path, conn_id?, autoconnect?, ip_method, ip_address?, prefix_len, gateway?, dns?, ssid?, password?, unlock_bssid=false)`; `delete_connection(conn_path)`.
- `ip_method`: `auto` (DHCP), `manual` (static, needs `ip_address`), `link-local`, `disabled`. `prefix_len` 1-32, `ip_address`/`gateway`/each `dns` entry dotted IPv4. Any invalid value answers `{error: 'Invalid IP settings', extra}` and nothing is written to NetworkManager.
- `Settings/Audio/` (audio or admin): `devices()` returns `devices[{name, description, muted, volume}]`, `default`, `available`; `set_default_device(device)`; `set_volume(volume, device?)`; `set_mute(mute, device?)`. No `device` = default sink.
- `Settings/DateTime/` (admin): `status()` returns `timezone`, `timezones`, `ntp`, `can_ntp`, `synchronized`, `local_time` (ISO 8601 with offset), `utc_offset` (seconds); `set_timezone(timezone)`; `set_ntp(enabled)`. Both answer with the status. The status is also broadcast to all pages (`Settings/DateTime/status`) when timedated emits `PropertiesChanged`.
- `Settings/Timers/` (admin): `jobs()` returns `jobs`, `actions`; `add_job(command, minute, hour, day_of_month, month, day_of_week, output?, mechanism='auto', wake?)`; `edit_job(uuid, ...)`; `set_job_enabled(uuid, state)`; `delete_job(uuid)` (malformed id: `Invalid job`; unknown: `Not found`). `edit_job`: an omitted `output`/`wake` is kept, an empty string clears it (the manager then validates the result, e.g. a screen timer keeps its output).
- Job fields: `uuid, command, minute, hour, day_of_month, month, day_of_week, enabled, output, mechanism, wake`; for `sus` also `next_suspend, next_wake, wake_problem`. Commands: `pwr`, `reb`, `sus`, `scr_on`, `scr_off`.
- `Power/`: `reboot()` (power or admin); `poweroff()`; `suspend_support()` returns `available, reason, rtc, rtc_local, min_sleep, max_sleep, last_refusal`; `suspend(wake_at)` with `YYYY-MM-DDTHH:MM` in node local time.
- `Settings/Firmware/` (admin): `status()`, `check()` (reply key `check`), `apply(files=True, eeprom=True, restart=False)` (reply key `result`; both false answers `nothing-selected`; a non-boolean `restart` answers `bad-argument`). `restart=true` is remembered only when the helper started; when the run ends without error and with `reboot_required`, the manager restarts the device through the same path as `Power/reboot` (`system/restart.py`: armed update -> updater restart, else logind), so closing the browser does not matter. The API is admin-only and admin holds `power`, so no further check is needed; the web UI sends `restart` only for a user who may call `Power/reboot`. A refused restart leaves the Restart button and the "Restart the device" text. Event: `Settings/Firmware/status`. Helper contract: [system/firmware.md](../system/firmware.md).
- `Settings/AcpiStorms/` (any logged in user): `list()` returns `storms`. Event: `Settings/AcpiStorms/list` (`storms`), pushed at start and when the record changes. Entry: see [ACPI storms](#acpi-storms-unitotem-acpi-storm-guard).
- `Settings/Update/` (admin; `availability` any user): `status()`, `check()`, `fetch(force=False)`, `apply(reboot=True)`, `confirm()`, `rollback(reboot=True)`, `cancel()`, `copy_to_other()`, `set_policy(mode, time='04:00')` (mode: `off`, `download`, `stage`, `reboot`, `scheduled`), `availability()`. Events: `Settings/Update/status`, `Settings/Update/availability`.
- `Vnc/outputs()` (admin) returns `outputs[{name, width, height, x, y}]` (active outputs) and `available` (`wayvnc` installed).
- Errors: `WSResponse(error=..., extra=...)`, e.g. `Invalid timer`, `Not found`, `Unknown action`, `Cannot suspend`, `Cannot use this suspend timer`.

### Firmware status (`unitotem-firmware`)

- Keys used: `supported`, `kind`, `family`, `op` (`check`|`apply`|null), `phase`, `percent`, `error`, `reboot_required`, `blockers`, `files` (`installed`, `custom`, `package`, `update`, `available`), `eeprom`, `returncode`; the manager adds `restart_pending` (an automatic restart was requested and started, false after any end without it). Helper output: [system/firmware.md](../system/firmware.md).
- Notification keys: `firmware.progress` (persistent bar), `firmware.failed` (error), `firmware.done` (info; "The device restarts now." when the restart is automatic, "Restart the device to start the new firmware." when `reboot_required` without it, else "The firmware is up to date.").

### ACPI storms (`unitotem-acpi-storm-guard`)

- Record: `/var/lib/unitotem/acpi-storms`, written atomically by the guard, one line per masked event: `gpeNN <first_seen> <last_seen> <rate> <boots> <boot_id> <masked>`.
- Read: at most 4096 bytes, at most 64 lines; an oversized, NUL, non-UTF-8, symlinked or non-regular file, or one with more lines, reads as empty. A line that does not match is skipped; of two lines for one event the first counts. Numbers: epoch 0..4102444800, rate 0..10^9, boots 0..10^6.
- Entry: `name`, `first_seen`, `last_seen`, `rate`, `boots`, `masked_now` (masked in the current boot), `seen_now` (last seen in the current boot). Sorted by `name`.
- Watch: inotify on `/var/lib/unitotem` (nothing is created), throttled 1 s. Without it a warning is logged once and the record is read at start and on each `Settings/AcpiStorms/list` call.
- Push `Settings/AcpiStorms/list` `{storms}` only when the list differs from the last one pushed.
- Notification per entry with `seen_now`: key `acpi.storm.<name>.<boots>`, warning, audience `admin`, link `/info`, source `acpi-storm-guard`. Text: masked (`ACPI event <name> was firing <rate> times a second and has been masked`; title `ACPI event <name> masked`) or not (`... fires <rate> times a second and cannot be masked`; title `ACPI event <name> cannot be masked`). One per event per boot: a new boot count is a new notification. Entries of earlier boots are not notified.
- No acknowledge: the record stays while the file exists.

### Updater status (`unitotem-update`; slot names are capitals)

- Keys used: `supported`, `slot`, `other_slot`, `default_slot`, `op` (null or `{progress: {op, phase, percent, eta_s, cause}}`), `staged`, `auto`, `last_result {op, result, slot, cause, error}`, `error`, `error_code`, `returncode`; the manager adds `copy_from`.
- `error_code` set by the manager: `bad-output`, `failed`, `timeout`.
- Phases: `check`, `download`, `write`, `verify`, `arm`, `reboot`. Causes: `label`, `fsck`, `mount`, `empty`, `bootfile:<name>`.
- Exit codes: 0 ok; 2 failed; 10 nothing to do; 12 busy; 13 no rollback; 127 absent (`supported: false`).
- The updater contract is in [ab-updates.md](../system/ab-updates.md).

### HTTP and websocket

- `POST /vnc/token`, `POST /terminal/token` (409 if the account has no shell), `POST /devtools/open {window_id}` returns `{path}` (404 no page, 503 viewer not running), `GET /devtools/<file>` (relative plain path: no leading or empty or `.` segment, no `..`; `page`, `browser`, `ws`, `json` are never files).
- `WS /vnc?output=NAME&control=1`: first text frame `{"token"}`; binary frames RFB; text `{"activity": 1}` keeps the session alive.
- `WS /terminal`: first frame `{"token"}`; binary frames pty data; text `{"resize": [cols, rows]}`.
- `WS /devtools/ws/<token>/<page>`: token in the path.
- Close codes: 1008 not authenticated / forbidden / bad token; 1011 cannot start (VNC: `wayvnc` missing); 1013 session limit; 1000 normal end with reason text.

### Files, environment, system interfaces

- `/etc/unitotem/timers.json`: `{"timers": [Timer...]}`, atomic write (`.tmp`, fsync), directory = dirname of `--assets_file`.
- Crontab import (once, when `timers.json` is missing): root crontab lines marked `unitotem:-)` and `screen_control.json`. The crontab is not modified.
- `/etc/unitotem/unitotem.env`: `hotspot_uuid`.
- `UNITOTEM_VNC_IDLE_TIMEOUT`: seconds, default 0 (never).
- Read/written: `/sys/class/rtc/rtcN/wakealarm`, `/sys/class/rtc/rtcN/device/power/wakeup`, `/etc/adjtime` (line 3 `UTC`|`LOCAL`), `/etc/hosts`, `/run/unitotem-update.progress`, `/run/unitotem-firmware.progress`, `/run/unitotem-vnc/`, `/usr/sbin/unitotem-update`, `/usr/sbin/unitotem-firmware`, `/usr/bin/wayvnc`.
- D-Bus (system bus): `org.freedesktop.NetworkManager`; `org.freedesktop.login1.Manager` (Reboot, PowerOff, Suspend, CanSuspend, PrepareForSleep); `org.freedesktop.hostname1`; `org.freedesktop.timedate1` (ListTimezones, SetTimezone, SetNTP; properties Timezone, NTP, CanNTP, NTPSynchronized).
- Serves `org.freedesktop.Notifications` on the user bus and the system bus, each only if the name is free. Capabilities: `actions`, `body`, `persistence`. This is the server for other applications: the manager's own notifications are not sent to D-Bus.
- Notification keys: `update.available` (info), `update.progress` (error level, persistent bar), `update.fetched` (info), `update.repaired` (info), `update.failed` (error), `suspend.problem` (warning, link `/settings/timers`). Details: "Update notifications" under How it works.

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
- Backup: `timers` restore replaces all timers; `audio` restore only for archives whose `version` is 3.0.0 or later (`release.version_at_least`, dpkg-style: `~` pre-releases sort before the release; an unparsable version counts as older). `touch` and `screens` restore replace their section after every entry passed the model's validators (nothing stored on a refused entry), written atomically; `touch` restore applies the mapping at once. `screens` keeps this machine's probe results (DDC bus, identity, inputs) per output name. Archives with netplan files: the key is ignored. Reset: `touch` clears the three sections, `screens` keeps the probe results and the default configuration.
- VNC: no TCP listener, no VNC password (the 0700 root-owned directory under `/run` is the guard). View-only is enforced by the server (`--disable-input`). `--disable-resizing`, 20 fps, max 2 sessions, one output per session. `sweep_stale` signals only a pid whose command line names its own socket.
- Terminal: never `fork` (multi-threaded process): `setsid -c` through the subprocess machinery. `login -f`: the web account is already authenticated. Administrators (members of `sudo`) have `/bin/bash`; `sudo` asks their own password. Accounts with shell `nologin` or `false` (non-admin accounts) are refused. Environment limited to `TERM` and `PATH`. Max 4 terminals; closed after 15 min without input.. The limit is checked and its slot reserved after the token read, in one step, so concurrent sockets cannot exceed it. Account names are validated (`osusers.valid_name`) before `login`.
- Tokens: 30 s, single use, bound to account and session id (and page for devtools). The socket must be same-origin (Origin = Host).
- Desktop notifications: markup stripped from the body; `body-markup` not advertised; 20 per application per 60 s; critical never expires; ids never 0.
- Time zone: validated by `fullmatch` and by membership in timedated's list (fallback: `tzdata.zi`, else `zone1970.tab`) before any bus call. Other values never reach D-Bus.
- Zone change: `time.tzset()` runs after each change and on `PropertiesChanged`, and the `TZ` variable is dropped. Timers (naive local `datetime.now()`) follow the new zone with no restart (proved by test).
- No manual clock setting: timedated keeps the time; NTP is the only time source switched from the node.
- `set_ntp` is refused when `can_ntp` is false.
- The status carries the whole zone list; every push sends it.
- Image defaults: time zone UTC, locale `en_US.UTF-8`.

## Tests

- `.venv/bin/python -m pytest <files>` from the repository root.
- `manager/tests/`: `test_network_details.py` (IP validation, API error), `test_wifi_scan.py` (scan list, SSID/passphrase checks), `test_hotspot_start.py` (hotspot profile, SSID/passphrase checks), `test_audio.py` (volume range, sinks), `test_hotspot_stop.py` (first-boot log), `test_timers.py` (delete/edit API), `test_suspend.py`, `test_vnc.py`, `test_hosts_file.py`, `test_update_progress.py`, `test_updater.py`, `test_desktop_notifications.py`, `test_datetime.py`.
- Live checks: `tools/ui-terminal.py`, `tools/ui-vnc.py`.
