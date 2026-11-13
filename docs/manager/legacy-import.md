# Import of a 2.x node

`tools/import-unitotem2.py` (Python 3, stdlib only) copies the settings of a UniTotem 2.x node into a running 3.x manager through its web API. Test: `tools/release/test_import_unitotem2.py` (fake manager over HTTPS and websocket; run in a `python:3` container).

Paths: relative to the repository root.

## Source

A directory holding the 2.x files:
- `unitotem.conf`: JSON `{urls: [{url, duration, enabled}], default_duration, users}`. A `file:NAME` url is a picture in `uploaded/`.
- `uploaded/`: the media files. `SHA256SUMS` (optional): checked against the files.
- `hostname`, `timezone` (optional one-line files; `--hostname`, `--timezone` override).
- `--crontab FILE`: root crontab of the 2.x node. Lines with the mark `unitotem:-)` that run `/usr/sbin/poweroff` or `/usr/sbin/reboot` become the timers `pwr` and `reb` (same table as the manager's own crontab import); a commented line becomes a disabled timer; other commands are logged as WARNING.

Unknown keys in the file or in an item are logged as WARNING and ignored.

## Run

```
UNITOTEM_URL=https://HOST UNITOTEM_USER=ADMIN UNITOTEM_PASSWORD_FILE=/path/pw \
  tools/import-unitotem2.py --source DIR [--fingerprint SHA256] [--playlist NAME] [--crontab FILE] [--screen-schedule HH:MM-HH:MM [--screen-days DOW] [--screen-mechanism M]] [--dry-run]
```

- The user is an administrator (system account) of the 3.x device. Without `UNITOTEM_PASSWORD_FILE` the password is the first line of stdin. It is never an argument and never logged.
- The device certificate is pinned by `--fingerprint` (SHA-256 of the DER certificate, hex). Without it the fingerprint seen is logged and trusted for the run.
- `--dry-run` reads the device and logs the plan (`PLAN ...` lines); nothing changes.
- Exit status: 0 done and verified, 1 failure or mismatch, 2 bad input.

## What is migrated

- Media: every file of `uploaded/` (also files no item uses). Matched by name and SHA-256; a device file of the same name with other content is replaced.
- Playlist (default name `PianoTerra`, option `--playlist`): found by name; else the only playlist when it is empty is renamed; else created. It becomes the default playlist (uploads go to the default playlist). Items keep the 2.x order, duration and enabled flag. Items are matched by url; an item of the playlist that is not in the 2.x list is removed; URL items are added as web pages (media type 0, no probe).
- Default duration of the playlist.
- Hostname (Settings > Network, effective at once, no reboot) and time zone (Settings > Date and time, timedated).
- Assignment: the playlist is assigned to every window of every viewer (a window without a playlist shows the idle page).
- Timers from `--crontab`, added when the device has no timer with the same action, schedule and output; the enabled state is set as in the crontab.
- `--screen-schedule` (opt-in, never used by the deploy): `scr_on` at the first time and `scr_off` at the second on every output, days `--screen-days` (default `1-5`), mechanism `--screen-mechanism` (default `output`, the video output; `cec` switches the TV). The format is validated before the device is touched (exit 2).

Re-running updates in place without duplicates. The end of every run reads the playlist back and compares url, name, duration, enabled and order per item, the media checksums (downloaded through `/uploaded/`), default duration, hostname and time zone.

## What is not migrated

- The 2.x web password and `users`: administrators are the system accounts of the new device.
- 2.x screen schedules (not present in the 2.x format) and other unknown keys: logged as WARNING.
- Other playlists, scheduling dates, fit, zoom, volume of 3.x assets are left as they are.

## Notes

- The websocket API answers a call that returns nothing with no message; the script follows each call with a read of an unrelated state (hostname or time zone status), whose answer proves the call is done.
- The migration `manager/utils/migration/v_3_0_0.py` converts `/etc/unitotem/unitotem.conf` only when that file sits on the device; it does not copy the media nor set names, hostname or time zone.

## Migration by the deploy

`deploy/remote-deploy.sh deploy` writes the archive `unitotem-legacy-<host>-<version>-<time>.tar.zst` before the disk is replaced (settings, uploaded media, root crontab, netplan, hostname, time zone). With `--admin-user NAME --admin-password-file FILE [--timezone ZONE]` it then runs `tools/migrate-legacy.py` on the new system:

- extracts only `etc/unitotem/unitotem.conf`, `etc/hostname`, `etc/timezone`, the uploaded media and root's crontab from the archive, into a temporary directory;
- creates the first administrator through `POST /setup` when `/login` redirects to `/setup`; an existing administrator is left alone (the same password file must then log in);
- runs the importer with the playlist named after the hostname, the certificate fingerprint of the device pinned, and `--crontab`;
- changes nothing it was not given: no screen schedule, the settings as they were. `--timezone` replaces the archived zone.

Without the options the deploy reports the archive path and migrates nothing. Test: `tools/release/test_migrate_legacy.py`.
