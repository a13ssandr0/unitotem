# Raspberry Pi firmware and EEPROM

`unitotem-firmware` (`unitotem/files/unitotem-firmware`, python3, root, installed as `/usr/sbin/unitotem-firmware`) reads the state of the boot firmware and of the EEPROM, fetches the Raspberry Pi archive, and swaps the firmware files of the boot FAT and stages the EEPROM update. The manager card on the Updates page drives it: [manager/node-system.md](../manager/node-system.md). Raspberry Pi only: any other device reports `kind: none`.

## Reads

| Source | Used for |
|---|---|
| `/proc/device-tree/model` | model and family: `pi3`, `pi4`, `pi5` (other models: `kind: none`) |
| `vcgencmd get_throttled` | bit 0 (under-voltage now) is a blocker; unreadable is `no-power-info` |
| `vcgencmd bootloader_version`, `/proc/device-tree/chosen/bootloader/build-timestamp` | installed EEPROM build date (device tree first) |
| `/etc/default/rpi-eeprom-update` `FIRMWARE_RELEASE_STATUS` | EEPROM channel: `default` (or `critical`), `latest` (or `stable`); absent is `default` |
| `unitotem-update --json status` | `pending_confirm`: a blocker while an A/B update waits for its confirm |
| `/etc/os-release` `VERSION_CODENAME`, else `/etc/apt/sources.list.d/*raspi*` | Debian suite of the archive |
| `/boot/firmware` | pairs present, `bootcode.bin`, `*.bak`, `unitotem-firmware.json`, `pieeprom.upd`, `recovery.bin`, writability |
| `/var/lib/dpkg/status` (`UNITOTEM_FW_DPKG_STATUS`) | `raspi-firmware` version of the running root: its stanza is parsed (`Status` installed, `Version` fullmatched), no `dpkg` process |
| `/usr/lib/raspi-firmware` (`UNITOTEM_FW_PKGDIR`) | firmware files of that package, hashed against the FAT |

## Installed firmware version

`unitotem-firmware.json` on the FAT: `{"version": <raspi-firmware version, dpkg form>, "installed_at": <epoch>, "files": {<name>: <sha256>}}`. `files` covers every firmware file the FAT carries (`bootcode.bin`, `start*.elf`, `fixup*.dat`). The image build writes it; a swap rewrites it with the hashes of the FAT after the swap and the archive package version. A json without `files` (older tool) is ignored for matching.

`status` hashes the FAT firmware files (1 MiB blocks) and decides, in this order:
1. all equal the `files` recorded in the json: `installed` = json version, `custom` false (covers a running slot whose package is newer than the FAT, and a card swap from the archive).
2. the package is installed and all equal its `PKGDIR` files: `installed` = package version, `custom` false.
3. otherwise `installed` null, `custom` true. The UI shows `Custom (from <package>)` when `package` is set, `Custom` when it is null.

## Sources

- Only `https://archive.raspberrypi.com/debian` (`UNITOTEM_FW_BASE_URL`). Any other scheme is refused, also on a redirect (`insecure-url`).
- Packages: `raspi-firmware` (arm64 or all; ships `usr/lib/raspi-firmware/`) and `rpi-eeprom` (ships the EEPROM images and `usr/bin/rpi-eeprom-config`). Trixie ships `raspi-firmware`, not `raspberrypi-bootloader`.

## Verification chain

1. `dists/<suite>/InRelease` (at most 1 MiB) is checked by `gpgv --homedir <private dir> --keyring <keyring> --status-fd 1`. The run needs exit 0 and a `GOODSIG` line (`bad-signature`). The keyring is `UNITOTEM_FW_KEYRING`, else the first existing of `/etc/apt/trusted.gpg.d/raspberrypi.gpg` and `/usr/share/keyrings/raspberrypi-archive-keyring.gpg` (`no-keyring`). `gpgv` is in `unitotem/locks/arm64.lock` and `amd64.lock`.
2. The `SHA256:` section of the signed text gives size and SHA-256 of each index. `main/binary-arm64/Packages.xz` is preferred over `.gz`. Index: at most 8 MiB as downloaded, length and SHA-256 must match (`hash-mismatch`).
3. Index decompressed at most 32 MiB. Stanzas: the package must exist once for `all` or `arm64` (`package-missing`, `package-ambiguous`). `Filename` must start with `pool/`, no `..`, no leading `/`. `Version` and `SHA256` (64 hex) are fullmatched.
4. Each `.deb`: length and SHA-256 must match `Packages` (`size-mismatch`, `hash-mismatch`). Caps: `raspi-firmware` 64 MiB, `rpi-eeprom` 32 MiB.
5. `ar` members: `debian-binary` must be `2.0\n`; `data.tar.gz` or `data.tar.xz`; data tar at most 256 MiB decompressed.

Member rules: paths with absolute start, `..`, backslash or NUL are refused (`unsafe-member`). Device nodes are refused anywhere. A link where a wanted file is expected is refused. Only the named members are extracted, each at most 16 MiB, into a private `0700` directory, `O_EXCL | O_NOFOLLOW`, mode `0600`.

Wanted members:
- `usr/lib/raspi-firmware/`: `bootcode.bin` and the eight pairs `start.elf+fixup.dat`, `start_cd+fixup_cd`, `start_db+fixup_db`, `start_x+fixup_x`, `start4+fixup4`, `start4cd+fixup4cd`, `start4db+fixup4db`, `start4x+fixup4x`.
- `usr/lib/firmware/raspberrypi/bootloader-2711|2712/<channel>/`: newest `pieeprom-YYYY-MM-DD.bin` of exact size (pi4 524288 bytes, pi5 2097152 bytes), `recovery.bin`, and on pi4 the newest `vl805-<hex>.bin`.
- `usr/bin/rpi-eeprom-config`.

Not verified: the signed InRelease has no `Valid-Until` check. An old, validly signed InRelease can be replayed; its hashes still bind the old index and packages, so the result is an older version, not forged content.

## Files swap (`apply --files`)

Plan: a pair is swapped only when both its files exist on the FAT and one of them differs from the package. `bootcode.bin` is last. Pairs absent from the FAT are never added.

1. Stale `<name>.new` of the staged names are removed.
2. Each planned file is written as `<name>.new`, fsynced, the directory fsynced.
3. Each `<name>.new` is read back and its SHA-256 compared (`verify-failed`).
4. Power blockers are checked again (`blocked`).
5. Each old file is copied to `<name>.bak` (`replace_file`, so a `.bak` exists before its name is changed).
6. Each `<name>.new` is renamed over `<name>` with `os.replace`, directory fsync after each. A name is never absent.
7. `unitotem-firmware.json` on the FAT is written (`version`, `installed_at`, `files`). The cached check gets `update: false`.

Failure in steps 5-6 (`swap-failed`): the replaced names are restored from their `.bak` in reverse order (`rolled_back` in the error). The `.bak` files created by this run are removed when every restore succeeded.

Risk window: the two files of one pair can differ for a few milliseconds (`start4.elf` new, `fixup4.dat` old). A power cut in that window leaves a mismatched pair, and the Pi may not start. A power cut never triggers the rollback in code, because the rollback only runs on a Python exception. Recovery is by a repeated apply (it works from the FAT as it is) or by copying `<name>.bak` back by hand. The `.bak` set is one generation: the next swap overwrites it.

## Refusals and blockers

`blockers` in status and `blocked` (exit 14 at start, exit 2 with `error_code: blocked` when a blocker appears during the run):
- `under-voltage`: `get_throttled` bit 0 set.
- `no-power-info`: `get_throttled` unreadable.
- `pending-confirm`: an A/B update waits for its confirm.
- `not-writable`: `/boot/firmware` is neither a mount point nor writable. The image mounts the FAT read-only (fstab): `apply` remounts it read-write for the swap and the EEPROM staging, then `sync` and read-only again (`bootfs_rw`, as `unitotem-update`); a failed remount is `not-writable`.
- `busy`: an operation holds the lock.

Other refusals: `no-eeprom` (Pi 3 has no EEPROM), `unsupported` (not a Pi), `nothing-to-do` (cached check shows no update), `busy` (exit 12).

## EEPROM (`apply --eeprom`, pi4 and pi5)

Native steps, inspired by rpi-eeprom (`rpi-eeprom-update`):
1. `rpi-eeprom-config --out running.conf` (run from the package with `python3 -I`, list arguments) reads the current configuration. A configuration of 3 lines or more is embedded in the new image; shorter ones are not.
2. If `pieeprom.upd`, `pieeprom.sig`, `recovery.bin` already hold this build (timestamp, SHA-256 of recovery, signature, and the embedded configuration), nothing is written.
3. `rpi-eeprom-config --config running.conf --timestamp <now> --out pieeprom-new.upd <pieeprom>`. The result must have the exact image size and the package build timestamp (`bad-package`).
4. Written in this order, each with `.new`, fsync and rename: `pieeprom.sig` (`<sha256>`, `ts:`, `target-soc:`), `pieeprom.upd`, `recovery.bin`.
5. A marker `/run/systemd/sleep.conf.d/40-unitotem-firmware-pending.conf` (`AllowSuspend=no`) is written while the update waits. `/run` is cleared at reboot.

Nothing is flashed by the helper. The bootloader flashes `pieeprom.upd` at the next reboot through `recovery.bin`, keeps the configuration embedded in the image, and `eeprom.installed` changes after that reboot. `eeprom.pending` is true only while `pieeprom.upd` and `recovery.bin` are on the FAT and the build timestamp inside `pieeprom.upd` is newer than the installed build. After a flash the bootloader renames `recovery.bin` to `RECOVERY.000` and leaves `pieeprom.upd` and `pieeprom.sig`; `rpi-eeprom-update` removes such leftovers later. `reboot_required` is false when nothing is pending. Not verified on hardware: the bootloader's rename and leftovers.

`cleanup` (CLI subcommand, ported from the removal of previous updates in `rpi-eeprom-update`) removes `pieeprom.upd`, `pieeprom.sig`, `recovery.bin`, `RECOVERY.NNN` and the suspend marker when the installed build is not older than the staged one or the staged image is unreadable; a pending update is left alone. It uses `bootfs_rw` and `fsync` of the directory, prints `{"cleaned": [...], "pending": bool}`. `status` never writes: the boot unit (`unitotem-eeprom-update run`) calls `cleanup` after `rpi-eeprom-update`.

Why `rpi-eeprom-update` is not called: as reported by the author of the helper's design (not re-checked here), it mounts, runs `blkid` and `rm` on its own boot directory, prompts on `/dev/tty`, and with `-d` would replace the configuration. The helper repeats the steps with every path redirectable and every check explicit. The package `rpi-eeprom` stays in the image for `rpi-eeprom-config`.

The `vl805` file (pi4) is extracted and checked but not staged on the FAT.

## JSON contract

Every answer is one JSON object on the last line of stdout. Errors: `{"error": text, "error_code": slug}`. `--json` is accepted and always on.

Exit codes: `0` ok or update available; `10` nothing to do; `12` operation already running; `14` blocked (apply start); `2` failed; `127` absent (shell).

`status` (no network): `kind` (`pi` or `none`), `supported`, `model`, `family` (`pi3|pi4|pi5`), `op` (`check|apply|null`), `phase`, `percent`, `error`, `throttled` (`0x..`), `under_voltage`, `files` (`installed`, `custom`, `package`, `available`, `update`, `pairs`, `bak`), `eeprom` (`installed`, `available`, `update`, `pending`, `channel`; `null` on pi3 and on `kind: none`), `blockers`, `checked_at`, `reboot_required`. `kind: none` answers only `kind`, `supported: false`.

`check` (network, at most 120 s): `{"checked": true, "files": {...}, "eeprom": {...}|null, "checked_at": N}`, exit 0 when an update exists, 10 when none.

`apply [--files] [--eeprom]`: no flag means both that apply (EEPROM not on pi3). Returns at once: `{"started": true, "op": "apply", "files": bool, "eeprom": bool}`, or exit 14 `blocked` with `blockers`, 12 `busy`, 10 `nothing-to-do`. The run is detached: `systemd-run --unit unitotem-firmware-apply --collect --quiet -p Nice=19 -p IOSchedulingClass=idle`, at most 900 s. It never reboots.

Progress file `/run/unitotem-firmware.progress`, one JSON line replaced atomically: `{"op", "phase", "percent", "state": running|done|failed, "error", "reboot_required"}`. Phases and percents of the fetch and verify part (check and apply): `fetch` 10, `verify` 40, `fetch` 60, `stage` 75. Apply then: `stage` 80, `verify` 85, `swap` 90, `eeprom` 95, `done` 100 (check ends at `done` 100 after the fetch part). Status reads `op` only while the lock is held.

Error codes: `insecure-url`, `network`, `timeout`, `too-large`, `verify-failed`, `bad-signature`, `bad-release`, `hash-mismatch`, `no-suite`, `no-keyring`, `package-missing`, `package-ambiguous`, `unsafe-filename`, `bad-version`, `bad-package`, `size-mismatch`, `unsupported-package`, `unsafe-member`, `blocked`, `swap-failed` (`rolled_back`), `eeprom-config`, `start-failed`, `busy`, `nothing-to-do`, `unsupported`, `no-eeprom`, `io`.

Caps and budgets:

| Item | Value |
|---|---|
| InRelease | 1 MiB |
| Packages index as downloaded | 8 MiB |
| Packages decompressed | 32 MiB |
| `raspi-firmware` / `rpi-eeprom` `.deb` | 64 MiB / 32 MiB |
| data tar decompressed | 256 MiB |
| one extracted member | 16 MiB |
| one request | 60 s |
| check, whole | 120 s |
| apply, whole | 900 s |
| `gpgv`, config tool | 60 s, 180 s |

## Manager API

Permission section `Settings/Firmware` (admin, plugin `unitotem_node`, class `Firmware`):
- `Settings/Firmware/status()`: `{status}`.
- `Settings/Firmware/check()`: reply key `check` (the `check` output); pushes `Settings/Firmware/status`.
- `Settings/Firmware/apply(files=True, eeprom=True)`: reply key `result` (the `apply` output). Both false: `nothing-selected` (manager side). Polls status every 2 s while `op` is set.
- Event `Settings/Firmware/status` (`status=<dict>`), also on each progress file change (inotify on `/run`).
- Notifications: `firmware.progress` (persistent bar while an operation runs), `firmware.failed` (error), `firmware.done` (info; restart text when `reboot_required`).
- Manager-side error codes: `timeout` (150 s subprocess), `bad-output`, `bad-argument`, `nothing-selected`.

## Tests

`python3 tools/release/test_firmware.py`: 171 passed, 0 failed (2026-11-28). A fake archive with a real gpg key, clearsigned InRelease, gzip and xz indexes and ar `.deb` files; `http_get` replaced by a fake. Every path redirected through the variables below; the test checks that `/etc/unitotem/users.json` and the real `/run` and `/boot` firmware files are unchanged.

Environment variables (defaults in brackets): `UNITOTEM_FW_BOOT` [/boot/firmware], `UNITOTEM_FW_RUN` [/run], `UNITOTEM_FW_STATE` [/var/lib/unitotem-firmware, reserved, unused], `UNITOTEM_FW_DT` [/proc/device-tree], `UNITOTEM_FW_DPKG_STATUS` [/var/lib/dpkg/status], `UNITOTEM_FW_PKGDIR` [/usr/lib/raspi-firmware], `UNITOTEM_FW_KEYRING` [first existing keyring], `UNITOTEM_FW_VCGENCMD` [/usr/bin/vcgencmd], `UNITOTEM_FW_UPDATE` [/usr/sbin/unitotem-update], `UNITOTEM_FW_EEPROM_CONF` [/etc/default/rpi-eeprom-update], `UNITOTEM_FW_OS_RELEASE` [/etc/os-release], `UNITOTEM_FW_APT_SOURCES` [/etc/apt/sources.list.d], `UNITOTEM_FW_BASE_URL` [https://archive.raspberrypi.com/debian].

## Not covered

- VL805 (pi4): extracted and checked, not staged.
- `FREEZE_VERSION`: not implemented.
- Pi 5 A/B EEPROM path (`rpieepromab`): not used.
- Replay of an old signed InRelease (no `Valid-Until`).
- Power cut between the two files of a pair, on hardware.
- The bootloader's flash on a real Pi 4 and Pi 5, and the removal of `pieeprom.upd` after it.
- Real archive access: tests use the fake archive only.

## Automatic EEPROM staging (arm64 image)

Raspberry Pi OS's package `rpi-eeprom` ships `rpi-eeprom-update.service` (oneshot, `rpi-eeprom-update -s -a`, enabled by the package preset). The image adds the drop-in `/usr/lib/systemd/system/rpi-eeprom-update.service.d/10-unitotem.conf` and the helper `/usr/lib/unitotem/eeprom-update` (`unitotem/files/`, installed by stage 2 on arm64 only; amd64 has no `rpi-eeprom`).

- Order: `After=multi-user.target network-online.target time-sync.target` (after the target, so the unit never delays `unitotem-boot-ok`, which follows `multi-user.target`), `Wants=network-online.target`, no `Requires=`. Nothing pulls `time-sync.target` in (`systemd-time-wait-sync` is disabled and waits forever), so `check` itself waits at most 60 s for `timedatectl` `NTPSynchronized=yes` (poll every 2 s). `TimeoutStartSec=150`, `Nice=19`, idle IO.
- `ConditionPathExists=/proc/device-tree/chosen/bootloader/build-timestamp`: boards without an EEPROM bootloader (Pi 3) skip the unit.
- `ExecCondition=... check` (exit 1 = skip, not a failure, logged at notice): clock not synchronized, `get_throttled` bits 0-3 set now (under-voltage, frequency cap, throttled, soft temperature limit) or unreadable, `mount -o remount,rw /boot/firmware` failed, or the FAT not writable. A successful check leaves the FAT read-write.
- `ExecStart=... run` calls `rpi-eeprom-update -s -a`, `sync`, maps exit 0 and 3 (version frozen) to success, and logs any other status at warning (the journal keeps warnings and above only; the tool's own stderr is info and would be lost). `run` first lets `rpi-eeprom-update` stage, then calls `/usr/sbin/unitotem-firmware --json cleanup` (`UNITOTEM_EEPROM_FWTOOL`; failure is a warning). A staged `pieeprom.upd` or `recovery.bin` is logged at warning: `EEPROM update staged, applied at the next restart`.
- `ExecStartPost=... ro` remounts the FAT read-only when the run succeeds (the unit is a oneshot with `RemainAfterExit=yes`: it stays active, so `ExecStopPost` would not run until it stops); `ExecStopPost=... ro` does it after a skip or a failure. Observed on a Pi 4 test board: without `ExecStartPost` the FAT stayed mounted read-write after a successful boot run.
- Why the stock unit failed (exit 2 = `EXIT_FAILED`, any `die`): the FAT is mounted read-only, and with a bootloader older than `BOOTLOADER_AUTO_UPDATE_MIN_VERSION` (May 2025 build) `-s` does not skip; `removePreviousUpdates` (`rm -f` of a staged `pieeprom.upd`/`recovery.bin`) or the `cp` to `${BOOTFS}` then fails. A bootloader at or above the minimum exits 0 after "Skipping automatic bootloader upgrade". Measured on a Pi 4 with the May 2026 bootloader: the unit ends `active (exited)`, status 0, package image Oct 30 2026 not staged.
- Visibility: a staged `pieeprom.upd` with `recovery.bin` and a newer build is `eeprom.pending` and `reboot_required` in `unitotem-firmware status`, so the Updates page card shows the restart need ([node-system](../manager/node-system.md)).
- The bootloader applies the image at the next restart. Risk: a power cut during that flash (SPI) can leave the board unbootable; the under-voltage guard reduces, not removes, this.
- Test: `tools/release/test_eeprom_unit.sh`.
