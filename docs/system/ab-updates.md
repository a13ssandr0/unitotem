# A/B whole-image updates

Paths: relative to the repository root.

Whole-image OTA on two ROOT slots: fetch, arm, one-shot trial boot, health-gated confirm, rollback, self-repair, automatic policy. One CLI: `unitotem/files/unitotem-update` (Python 3, `--json`), installed as `/usr/sbin/unitotem-update`. Layout 2 (A/B) only.

## Files

| Path | Role |
|---|---|
| `unitotem/files/unitotem-update` | CLI and all A/B logic |
| `unitotem/files/unitotem-update-auto.service` | oneshot `unitotem-update --json auto`; `Nice=19`, idle IO, `TimeoutStartSec=2h` |
| `unitotem/files/unitotem-update-auto.timer` | 10 min after boot, then every 10 min |
| `unitotem/files/unitotem-boot-ok` (+ `.service`) | Runs `unitotem-update --json boot-ok` on every boot (A/B only: the single-root bootcount branch is removed) |
| `unitotem/files/grub-ab-entries` | `/etc/grub.d/10_unitotem_ab`: `slot-a`, `slot-b`, `slot-a-recover`, `slot-b-recover`, `ota-recovery`; `fallback` list |
| `unitotem/files/grub-default` | `/etc/default/grub`; A/B sets `GRUB_DEFAULT=saved`, `GRUB_SAVEDEFAULT=false` |
| `unitotem/files/grub-ota-entry` | Single-root recovery entry (`45_unitotem_ota`); not on A/B |
| `unitotem/files/unitotem_identity.py` | Account merge, `/usr/lib/unitotem/` |
| `unitotem/files/ota-preserve.list` | `/etc` whitelist |
| `unitotem/files/unitotem-boot-orientation` | Panel orientation on both slots |
| `unitotem/stage3-image.sh` | Ships `/usr/share/unitotem/esp-grub.cfg` and the recovery set `/usr/share/unitotem/recovery/` |
| `deploy/ota-engine.sh` `ab_failover()` | initramfs half of self-healing |
| `tools/release/unitotem-release` | Builds slot images and manifest (`release.md`) |

## How it works

`cur` = `unitotem.slot=` on the cmdline; `other` = the inactive slot. State: `slots.json`.

- **check**: fetch `keys.json`(+`.sig`), verify with `root.pub`; reject `seq` below stored `keys-seq.json`. Fetch `manifest.json`(+`.sig`), verify against any key in `keys.json`; reject `min_updater` > 1. Store the new seq last.
- **fetch** (detached unit `unitotem-update-fetch`; `--foreground` inline):
  1. Checks: layout 2, version newer (or `--force`), `root` part exists, slot found by PARTLABEL, not mounted.
  2. `cur` := valid+confirmed; `other` := invalid.
  3. Stream HTTPS -> `xz -dc` -> `partclone.restore -C -s - -o <dev>`; sha256 of the compressed stream must match.
  4. `e2fsck -fn`; `tune2fs -L ROOT_<X> -U random`; mount ro; `release-version` must equal the manifest version; `usr/lib/systemd/systemd` must exist.
  5. Raspberry: extract `bootfiles` into `<bootfs>/slot<other>/`; rewrite `cmdline.txt` (`root=LABEL=ROOT_<X>`, `unitotem.slot=<x>`).
  6. `prepare_overlays`: new uppers `etc/root/var.<other>`; whitelist import; copy `root.<cur>`; identity merge.
  7. `os.sync()`, then `other` := valid+prepared.
- **apply [--reboot|--stage]**: needs `other` valid+prepared; re-check label and read-only fsck; write `pending.json`; re-import whitelist and identity; arm one-shot trial (GRUB `next_entry=slot-<other>`; Pi `tryboot.txt` with `os_prefix=slot<other>/`). `--reboot`: `systemctl reboot` (Pi: `--reboot-argument=0 tryboot`). Pi without `--reboot`/`--stage`: `needs-reboot`.
- **boot-ok** (every A/B boot):
  - No pending: mark `cur` confirmed; a manual rollback armed for `cur` becomes `ok`; clear the failover guard; sync ESP `grub.cfg` and the recovery set ([below](#recovery-set-refresh)); if `UPDATE_AUTOREPAIR=1` start `repair` detached.
  - Pending for `cur` (trial): poll `UPDATE_HEALTH_URL` every 3 s until HTTP 200 or `UPDATE_HEALTH_TIMEOUT` s (monotonic). OK: `confirm_now` (saved default = `cur`, confirmed, pending removed, result ok), sync ESP `grub.cfg` and the recovery set. Timeout: `rolled-back/health-timeout`, plain reboot, exit 2.
  - Pending for the other slot (trial never returned): `rolled-back/trial-did-not-confirm`.
  - Staged pending on the other slot, no trial requested: no-op.
- **confirm**: `confirm_now` without the health wait, then the same ESP `grub.cfg` and recovery set syncs as `boot-ok`.
- **rollback [--reboot]**: needs `other` valid; default := other; pending removed; result `armed`; the next boot of the old slot turns it into `ok`.
- **repair**: if `other` fails `slot_sound` (label, `e2fsck -fn`, mount, `release-version`, `systemd`, on GRUB `vmlinuz` and `initrd.img`, Pi boot files), copy `cur` over it (`partclone.extfs -c -F | partclone.restore`), new UUID and label, `e2fsck -fy`, version check, Pi boot files cloned, overlays prepared. Under the lock, `RuntimeMaxSec=3600`. The ROOT_B that the first boot of a flash image creates is a formatted, labelled, empty slot: `slot_sound` returns `empty`, so the first confirmed boot fills it (`storage-and-persistence.md#layout`).
- **failover** (initramfs): chosen root missing or failing the read-only check and the other slot sound: write guard `/boot-ota/unitotem-ota.failover` (`cur->other`), switch default (`saved_entry` / `os_prefix`), `reboot -f`. Refused while the guard exists. Cleared by the next plain boot.
- **Lock**: `/run/unitotem-update.lock` (flock); busy exits 12. The file is never unlinked: release closes the descriptor, so no waiter can lock a stale inode. Progress: `/run/unitotem-update.progress` (one JSON line, atomic rename).

### Recovery set refresh

`sync_boot_recovery` copies the running image's resident fallback set (`UPDATE_RECOVERY_DIR`, format and ownership in [boot.md](boot.md#recovery-set)) to the boot partition: `UPDATE_ESP_MOUNT/unitotem` on GRUB, `UPDATE_BOOTFS` on the Pi.

- **When**: after a confirmed boot only: plain `boot-ok`, `confirm`, and trial `boot-ok` after `confirm_now`. Never during the unconfirmed trial run. Both backends. Each call is wrapped: an error is logged (`boot recovery sync failed`) and never fails the confirm or the boot.
- **Level first**: the image level (manifest) against the level of the boot partition's `recovery.sha256` (0 when absent). Image level not higher: `noop`. Nothing is hashed or written (SD wear).
- **Verify the source**: every image file must match its manifest sha256; a mismatch gives `refused`, nothing is written.
- **Skip what is current**: boot partition files that already match the manifest are not copied. An interrupted run is therefore finished by the next confirmed boot.
- **Space**: bytes to copy plus 1 MiB must be free on the boot partition (`statvfs`), else `refused` (`boot partition needs N bytes free`). Old files are untouched.
- **Write** (under read-write remount): stray `*.new` files are removed; each file to copy goes to `<name>.new`, is fsynced, read back and verified; renames follow in the order kernel, initrd, dtbs; `os.sync()`; `recovery.sha256.new` is written, verified and renamed last. Any error removes the `.new` files and gives `failed`; old files stay.
- **Record**: `recovery-sync.json` in `UPDATE_STATE_DIR`, `{result, from, to, detail, time}`. `result` is `ok`, `noop`, `refused` or `failed`; `from` is the boot partition level, `to` the image level. An unchanged `noop` is not rewritten (SD wear); every written record logs `boot recovery <result> F->T: <detail>`.
- **Status**: `unitotem-update --json status` carries the record as `boot_recovery` (`null` before the first run).

Power cut and downgrade:

- Cut before the first rename: the old set is intact; the next run removes the stray `.new` files.
- Cut between two renames (milliseconds apart): kernel and initrd of different builds on the boot partition. `recovery.sha256` still holds the old level, so the next confirmed boot repeats the run, skips the file already equal, and finishes.
- Residual window: a fallback entered inside that window boots a kernel with the initrd of another build (modules may not match; the network driver may fail to load) until the next confirmed boot. A FAT cannot rename two files atomically, and the fallback does not repair the set itself.
- The normal slot never reads these files, so no normal boot is blocked (see [boot.md](boot.md#recovery-set)).
- Downgrade and rollback: the level is compared with the running image only. An older image has an equal or lower level, so a rollback never lowers the boot partition's set.

### Automatic policy (`auto`)

- Modes: `off` (default), `download`, `stage`, `reboot`, `scheduled` (reboots once a day inside `AUTO_WINDOW_S` = 3600 s after `time`, default 04:00).
- Never during an operation or a running trial; 10 min settle after boot; asks the server at most every 6 h; backoff 1 h to 24 h on errors; layout migration never automatic. An armed update re-merges `/etc` and accounts on every tick.

## Interfaces

`unitotem-update [--json] COMMAND`:

| Command | Options | Effect |
|---|---|---|
| `status` | | State, slots, trial, rollback, op, last result, auto |
| `check` | | `available`, `version`, `size`, `needs_layout_migration` |
| `fetch` | `--foreground`, `--force`, `--accept-changes` (ignored) | Write the inactive slot |
| `apply` | `--reboot`, `--stage` | Arm trial |
| `confirm` | | Promote running trial |
| `boot-ok` | | Called by the boot-ok service |
| `rollback` | `--reboot` | Default := other slot |
| `repair` | `--foreground`, `--auto`, `--force` | Rebuild other slot from running one |
| `cancel` | | SIGTERM to the lock holder; other slot invalidated |
| `policy` | `--set-mode off\|download\|stage\|reboot\|scheduled`, `--time HH:MM` | Read/set `auto.json` |
| `auto` | `--now` | One policy tick |
| `reboot` | | Reboot; into the staged update if any |

Exit codes: 0 ok / update available; 10 nothing to do; 12 operation running; 13 no rollback; 2 failed (incl. cancelled, health-timeout); 127 command missing. 11 is reserved, never returned.

Config `/etc/unitotem/update.conf` (`key=value`; env `UNITOTEM_<KEY>` overrides; `UNITOTEM_UPDATE_CONF` = other file):

| Key | Default |
|---|---|
| `UPDATE_BASE_URL` | project GitHub repository |
| `UPDATE_CHANNEL` | `stable` (only value accepted) |
| `UPDATE_KEYS_DIR` | `/usr/share/unitotem/update-keys` |
| `UPDATE_STATE_DIR` | `/mnt/data/unitotem/update` |
| `UPDATE_VERSION_FILE` | `/usr/share/unitotem/release-version` |
| `UPDATE_GRUBENV` | `/boot/efi/unitotem-grub/grub/grubenv` |
| `UPDATE_ESP_MOUNT` / `UPDATE_BOOTFS` | `/boot/efi` / `/boot/firmware` |
| `UPDATE_BACKEND` | empty = detect (`grub`/`rpi`) |
| `UPDATE_DT_BOOTLOADER` | `/proc/device-tree/chosen/bootloader` |
| `UPDATE_HEALTH_URL` | `https://localhost/health` (empty = no gate) |
| `UPDATE_HEALTH_CA` | `/etc/ssl/unitotem.pem` (the manager's certificate, the health check's only trust anchor) |
| `UPDATE_HEALTH_TIMEOUT` | `180` |
| `UPDATE_AUTOREPAIR` | `1` |
| `UPDATE_ESP_GRUBCFG` | `/usr/share/unitotem/esp-grub.cfg` |
| `UPDATE_RECOVERY_DIR` | `/usr/share/unitotem/recovery` (image's fallback set; [Recovery set refresh](#recovery-set-refresh)) |
| `UPDATE_DATA` | `/mnt/data` |
| `UPDATE_CRASHPOINT`, `UPDATE_REBOOT_CMD` | test hooks |

State files (`UPDATE_STATE_DIR`): `slots.json`, `pending.json` (`slot, from, from_version, version, armed_at, staged?, trial_requested?`), `last-result.json` (`op, result, error_code, at`), `recovery-sync.json` (`result, from, to, detail, time`), `auto.json`, `auto-state.json`, `keys-seq.json`, `preserve.list`, `identity-base/`, `identity-merge.json`, `events.log`.

Status JSON: `layout, ab, current_version, slot, other_slot, other_version, trial, pending_confirm, rollback_available, op{pid,progress}, last_result, armed, staged, auto{policy,state}, identity_merge, default_slot, base_url, boot_recovery`.

Progress JSON: `op` (fetch|repair), `phase` (check|write|verify|arm), `state` (running|done|failed|cancelled), `percent`, `bytes`, `total`, `eta_s`, `error`, `error_code`.

Error codes: `not-ab`, `backend-unsupported`, `busy`, `network`, `command-failed`, `channel-unsupported`, `no-root-key`, `bad-keys-signature`, `keys-rollback`, `bad-manifest-signature`, `updater-too-old`, `layout-mismatch`, `not-newer`, `no-root-part`, `no-slot-device`, `slot-mounted`, `write-failed`, `bad-checksum`, `version-mismatch`, `bad-image`, `slot-not-verified`, `nothing-fetched`, `needs-reboot`, `nothing-to-confirm`, `no-rollback`, `health-timeout`, `cancelled`, `bootfs-rw`, `bootfiles-failed`, `bad-bootfiles`, `no-bootfiles-part`, `no-cmdline`, `bad-copy`, `bad-mode`, `bad-time`. Auto states: `check-failed`, `fetch-failed`, `needs-manual`.

Release artifacts (`<base>/releases/latest/download/`): `keys.json`(+`.sig`) signed by the root key; `manifest.json`(+`.sig`) signed by a key in `keys.json` (Ed25519, `openssl pkeyutl -verify -rawin`). Manifest: `{schema:1, version, channel, arch, layout:2, min_updater, built, parts:[{file, role: root|bootfiles, size, sha256}]}`; root part `root.ext4.pc.xz`; Pi `bootfiles.tar.xz`; `sha256` covers the compressed file. Details: `release.md`.

Boot interfaces:

- Cmdline: `root=LABEL=ROOT_A|ROOT_B unitotem.slot=a|b`; recovery `unitotem.ota=recover|1`.
- GRUB ids: `slot-a` (0), `slot-b` (1), `slot-a-recover` (2), `slot-b-recover` (3), `ota-recovery` (4). grubenv: `saved_entry`, `next_entry` (one-shot), `unitotem_video`.
- Pi: `config.txt` `os_prefix=slota/|slotb/`; `tryboot.txt`; `<bootfs>/slot{a,b}/` (`kernel8.img`, `initramfs8`, `cmdline.txt`).
- Transient units: `unitotem-update-fetch`, `unitotem-update-repair` (Nice=19, idle IO).

## Rules and gotchas

- Slots are found by GPT PARTLABEL, never by filesystem label: a half-written slot has a stale label.
- Never write a mounted slot.
- Flags are written only after `os.sync()`; `apply` re-runs fsck and label check. Interrupted operations are repeated, not resumed.
- The running slot is always the rollback target; `repair` copies it over the other slot.
- Overlay uppers are per slot; never delete the other slot's upper.
- `DATA/unitotem/persist/` is shared by both slots: keep it backward compatible by one version.
- GRUB `next_entry` is one-shot: a crash during trial lands on `saved_entry`. Confirm writes `saved_entry`.
- GRUB clears `next_entry` on any boot: a staged update starts at the next reboot of any kind. On Pi it starts only through `unitotem-update reboot` (tryboot flag).
- The health gate in `boot-ok` is what makes rollback work: without it a release with a broken manager would be confirmed.
- State writes fsync the file, then the state directory, before any flag is written. Progress lives in `/run` and is gone after a reboot: read the outcome from `status` / `last-result.json`.
- The device uses only `<base>/releases/latest/download/`, never `api.github.com`. Key and manifest signatures are verified before anything is written to a slot (a bare hash only detects corruption).
- GRUB `fallback` lists entry numbers only. Reordering entries requires updating `set fallback` in `grub-ab-entries`.
- ESP `grub.cfg` is replaced only from a confirmed boot, only when the image's `# unitotem-grub-level` is higher, and only if it contains `--id slot-a`, `--id slot-b`, `--id ota-recovery`. Raise the level to push a bootloader change.
- Pi: tryboot is honoured only on a reboot with the tryboot flag; a plain reboot or power cut boots the old slot and a staged update stays armed. Boards without the EEPROM bootloader: `backend-unsupported`.
- Pi has no RTC: deadlines use the monotonic clock.
- `UPDATE_HEALTH_URL` is verified against `UPDATE_HEALTH_CA` (the manager's own self-signed certificate, `/etc/ssl/unitotem.pem`); no hostname check. A missing CA file counts as unhealthy. Images without a 3.x manager set the URL empty.
- Failover runs at most once per failure.
- An update changes only the slot directory, the ESP `grub.cfg` and the boot partition's recovery set (the last two after a confirmed boot, when the shipped level is higher); Pi EEPROM/firmware and PC shim/GRUB binaries are never touched.
- `fetch --accept-changes` is accepted and ignored.
- Manager restarts do not interrupt fetch or repair (transient units).
- Power-cut model: `kill -9` drops un-submitted guest writes only.

## Load during an update

`fetch` (and `repair`) write the image to the inactive slot through `xz -dc | partclone.restore`, as a transient unit with `Nice=19` and the idle I/O class. `Nice` and the I/O class do not reach the kernel's write-back of the page cache, so on a slow disk the writes alone fill the card and the manager's reads wait. Measured on a Raspberry Pi 4 (8 GB, SD card, `fetch --force` of a 580 MB asset, 175-195 s, sampled every second with a web and an SSH probe from another host every 2 s; `tools/update-load-test.sh`, `tools/update-load-analyze.py`):

| Run | Web probes timing out (15 s) | Web worst / p90 | SSH worst | Dirty pages |
|---|---|---|---|---|
| Unchanged (`mq-deadline`, ratios 10/20) | 5 of 54 | 15 s | 0.23 s | up to 830 MB |
| Dirty pages capped (16/64 MiB) | 6 of 31 | 15 s | 0.22 s | below 65 MB |
| `bfq` and capped dirty pages | 0 of 138 | 6.6 s / 0.21 s | 0.26 s | below 65 MB |
| The same set by the updater, `xz -T1` | 0 of 127 | 2.6 s / 0.42 s | 0.23 s | below 65 MB |

- CPU is not the cause: `xz -dc` alone, at `Nice=19` on all four cores for 33 s, left the web at 0.07 s worst.
- The SD card is: writes at 15-22 MB/s keep it busy (`iowait` 25-50 %), and a direct 4 KiB read took up to 6 s during the unchanged run.
- `io_friendly` (`unitotem-update`) applies, for the time of the write: the I/O scheduler `bfq` on the disk, `vm.dirty_bytes` 64 MiB and `vm.dirty_background_bytes` 16 MiB; `xz` runs with one thread. Only disks named `mmcblk*` and `sd*` are touched; NVMe and virtual disks keep their settings. The duration of the update does not change.
- The values to restore are kept in `/run/unitotem-update-io.json`; the next run puts back what a killed run left, and a reboot resets everything.
- The kernel keeps either a ratio or a byte value per limit: writing one form zeroes the other, and `dirty_bytes` cannot be written back to 0 while the ratios are 0 (`EINVAL`). The form that was active is restored (`dirty_ratio` before `dirty_background_ratio`). A first version restored the bytes and left the Pi capped: only the run on the real kernel showed it.
- A failure to tune is logged (`update I/O tuning skipped`) and never stops the update. Events: `update I/O: <disk> scheduler bfq, dirty pages capped at 64 MiB` and `settings restored`.

## Tests

Host (repo root, no device): `python3 tools/release/test_auto.py`, `test_repair.py`, `test_identity_merge.py`, `test_boot_orientation.py`, `test_io_friendly.py`, `test_rpi_backend.py` (needs mtools, e2fsprogs; served by `tools/release/fake-github.py`).

Image: `unitotem/verify-image.sh` (boot-ok, auto timer, failover, grub.cfg). QEMU power-cut and loopback harnesses: `testing.md`.
