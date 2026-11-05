# Storage: partitions, read-only root, DATA overlays

Paths: relative to the repository root.

Immutable Debian root on two A/B slots (ROOT_A, ROOT_B). Mutable state lives on DATA and is overlaid onto `/etc`, `/root`, `/var`. Update mechanics: `ab-updates.md`.

## Files

| Path | Role |
|---|---|
| `unitotem/common.sh` | `AB_LAYOUT`, `ROOT_SLOT_SIZE`, `IMAGE_SIZE`, `FIRMWARE_SIZE` |
| `unitotem/stage3-image.sh` | Partition table, `mkfs`, baseline, final fsck |
| `unitotem/stage2-configure.sh` | fstab; A/B drops `LABEL=ROOT /` and `LABEL=BOOT`; installs overlay hook; cmdline `ro` |
| `unitotem/files/fstab-arm64`, `fstab-amd64` | Boot FAT `ro,nofail`; tmpfs `/tmp`, `/run`, `/var/cache`, `/var/tmp` |
| `unitotem/files/overlayfs-hook.sh` | initramfs init-bottom: mounts DATA, fsck, per-slot overlays, dpkg pin |
| `unitotem/files/ota-preserve.list` | `/etc` whitelist carried across an update |
| `unitotem/files/unitotem_identity.py` | Local account merge (passwd, shadow, group, gshadow) |
| `unitotem/files/unitotem-update` | `prepare_overlays`, whitelist import, identity merge, state files |
| `unitotem/files/unitotem-persist-paths` (+ `.service`) | Binds DATA persist dirs over `/var` targets |
| `unitotem/files/unitotem-ssh-hostkey` (+ `.service`) | SSH host keys on DATA |
| `unitotem/files/unitotem-maintenance` (+ `-mode.service`) | Writable root for apt and manual changes |
| `unitotem/files/unitotem-ota-changes` | Baseline and diff of ROOT (scope `usr boot opt srv media mnt`) |
| `deploy/ota-engine.sh` | Fallback path: `data-op`, `migrate-etc-overlay`, `init-premount`, `local-bottom-verify` |
| `deploy/remote-deploy.sh` | DATA backup before disk replacement; preserve/format choice |

## Layout

A/B (`AB_LAYOUT=1`):

| # | arm64 | amd64 |
|---|---|---|
| 1 | FIRMWARE FAT32 1 GiB | EFI FAT32 1 GiB |
| 2 | ROOT_A ext4 6 GiB | ROOT_A ext4 6 GiB |
| 3 | ROOT_B ext4 6 GiB | ROOT_B ext4 6 GiB |
| 4 | DATA ext4 (rest) | DATA ext4 (rest) |
| 5 | - | BIOS (ef02) |

amd64 A/B has no BOOT partition: each slot carries its kernel and initrd in `/boot`; GRUB lives on the ESP. Single-root (`AB_LAYOUT=0`): arm64 FIRMWARE, ROOT, DATA; amd64 EFI, BOOT, ROOT, DATA, BIOS; overlay suffix empty. Slot size is fixed: changing it means repartitioning and moving DATA.

DATA tree (label `DATA`, mounted at `/mnt/data` by the initramfs):

```
upper/{etc,root,var}[.a|.b]    overlay upper, one per slot
work/{etc,root,var}[.a|.b]     overlay workdir
history/<UTC ts>/              uppers moved aside by the fallback OTA path
unitotem/persist/{uploaded,crontabs,browser}
unitotem/ssh-host-keys/
unitotem/update/               unitotem-update state
.unitotem-overlay-status       boot-time overlay record
```

## How it works

Boot:

- Bootloader passes `root=LABEL=ROOT_A|ROOT_B`, `unitotem.slot=a|b`, `ro`.
- init-premount (`ota-engine.sh init-premount`): validates the slot with a read-only fsck; on failure uses the other slot, else the OTA fallback. A/B images skip the boot counter.
- local-bottom (`local-bottom-verify`): `/sbin/init` must exist, else OTA fallback.
- init-bottom (`overlayfs-hook.sh`):
  1. Find DATA by label (10 tries, `udevadm settle`). Not found: warning, boot continues without overlays.
  2. Add a journal if absent; `e2fsck -p` (exit 0/1 ok; others logged, never fatal).
  3. Mount DATA `noatime,nodiratime` at `/mnt/data`.
  4. Stash ROOT's `/var/lib/dpkg`.
  5. Overlay `etc`, `root`, `var`: lower `ROOT/<d>`, upper `DATA/upper/<d><sfx>`, work `DATA/work/<d><sfx>`.
  6. Rebind dpkg over the `/var` overlay; drop the stash.
  7. Write `.unitotem-overlay-status`.
- systemd: `unitotem-ssh-hostkey`, `unitotem-persist-paths`, `unitotem-boot-ok`.

Persist paths (`name -> target (mode group)`): `uploaded -> /var/lib/unitotem/uploaded` (755 root); `crontabs -> /var/spool/cron/crontabs` (1730 crontab); `browser -> /var/lib/unitotem/browser` (700 root); `home -> /home` (755 root, administrators' home directories; ROOT is read-only, so `/home` cannot live there). Absent DATA dir: created and seeded from the target. Owner and mode always set. Bound if not already a mountpoint.

Update into slot X from running slot C:

- `prepare_overlays` (fetch): clears `upper`/`work` of X; `etc.X` = whitelisted paths from `etc.C`; `root.X` = copy of `root.C`; `var.X` empty.
- `merge_identity_into`: `etc.X/{passwd,shadow,group,gshadow}` = image files + local accounts.
- `apply`: repeats whitelist import and identity merge, then arms the trial.
- C's uppers are never touched: rollback returns to C's state.

Fallback OTA (`ota-engine.sh`):

- `data-op preserve|mkfs`: `mkfs` runs `mkfs.ext4 -L DATA`.
- `migrate-etc-overlay --slot S`: removes the other slot's upper and work; moves `etc` and `var` uppers to `history/<ts>/`; restores whitelisted `etc` paths; removes `pending.json`, `slots.json`, `last-result.json`. `root.<slot>` is left as is.
- DATA is kept only if a read-only `e2fsck -fn` passes.

## Interfaces

`/etc/unitotem/update.conf` (env `UNITOTEM_<KEY>` overrides; `UNITOTEM_UPDATE_CONF` = other file): `UPDATE_DATA` (`/mnt/data`), `UPDATE_STATE_DIR` (`/mnt/data/unitotem/update`), `UPDATE_ETC_CURRENT` (`/etc`), `UPDATE_CMDLINE` (`/proc/cmdline`), `UPDATE_CRASHPOINT` (test hook). Full list in `ab-updates.md`.

Kernel command line: `root=LABEL=ROOT_A|ROOT_B`, `unitotem.slot=a|b`, `ro`, `unitotem.maintenance=1`, `unitotem.ota=1|recover`.

State in `DATA/unitotem/update/`: `slots.json` (`{slot: {version, valid, prepared, confirmed}}`), `pending.json`, `last-result.json`, `identity-merge.json`, `preserve.list`, `identity-base/`, `events.log` (rotated to `.old` at 64 KB).

`ota-preserve.list`: one glob per line relative to `/etc`; `#` comments; lines with `=` ignored; matched directories copied recursively.

`unitotem-ota-changes`: `baseline --root DIR --out DIR` (build), `check [--json]` (device). Exit 0 clean, 1 not clean, 2 error. Verdicts `clean`, `packages-only`, `mixed`. JSON: `verdict`, `digest`, `packages{added,removed,changed}`, `files{unexplained,package_files_modified,unowned_added,unowned_removed,unowned_modified}`.

`.unitotem-overlay-status` keys: `boot-marker`, `overlay-slot-suffix`, `initramfs-{etc,root,var}` (`overlay-mounted|NOT-MOUNTED`), `initramfs-{etc,root,var}-writable` (`yes|no`), `initramfs-dpkg-pinned-to-root` (`skip|stashed|yes|FAILED`).

## Rules and gotchas

- Uppers are per slot; never delete the other slot's upper (rollback depends on it).
- An upper file shadows the image file at the same path: a whitelisted file overrides the new image's version.
- `**` is not recursive (Python `glob` without `recursive`, bash without globstar).
- Never whitelist structural files (fstab, units, initramfs-tools config, PAM).
- `passwd`, `shadow`, `group`, `gshadow` are not whitelisted; they go through the identity merge: root's shadow entry and accounts with 1000 <= uid < 65534 (plus their groups, `sudo` and `users` included) are carried; image wins on name or uid clash; output validated then renamed, old file kept as `*.pre-update`. Root's login shell and its membership of `unitotem-first-admin` come from the current slot (a closed device never gets the image's open root back); the image's values apply only when the current system has no such group or entry. On failure the new slot uses the image's files and root returns to the image's first-access state (empty password, first-administrator shell). See [image-runtime](image-runtime.md#root-and-first-access).
- `/var/lib/dpkg` is pinned to ROOT: DATA drift is discarded.
- `/var/cache` and `/var/tmp` are tmpfs.
- Mount table: `/tmp` tmpfs 256M, `/run` tmpfs 0755, `/var/cache` tmpfs 512M, `/var/tmp` tmpfs 64M, all `nosuid,nodev,noatime`. Boot FAT: `vfat ro,nofail,x-systemd.device-timeout=15s,iocharset=iso8859-1`.
- Keep `iocharset=iso8859-1`: the default `ascii` needs `nls_ascii` loaded on demand; if that fails `boot-firmware.mount` fails and boot drops to the emergency shell.
- Installing a kernel or DKMS driver regenerates the initramfs, and `mkinitramfs` stages in `${TMPDIR:-/var/tmp}`: with the 64M tmpfs it fails with `No space left on device` and leaves dpkg wedged. In maintenance mode set `TMPDIR` to a directory on DATA before `dpkg --configure -a`.
- DATA has a journal; a missing one is added at boot.
- `persist/` and shared configs stay backward compatible by one version.
- Persist binds are whole directories (crontab replaces its file by rename). Seeding happens only when the DATA dir is absent.
- Nothing image-owned goes under `/etc/unitotem`: the update imports `unitotem*/**` from the previous slot, so such a file stays at its first-install version. `/etc/unitotem` is device state; image files go under `/usr/share/unitotem` (base labwc config: `/usr/share/unitotem/xdg/labwc/rc.xml`).
- Identity merge validates with `pwck -r` and `grpck -r` (`LC_ALL=C`, messages matched in English); it fails only on problems the image's own files do not already have.
- Deploy recognises a UniTotem root by `etc/unitotem/ota-preserve.list`; every image ships it.
- ROOT is writable only in maintenance mode; changes are lost at the next OTA; `unitotem-ota-changes` reports them.
- `unitotem-ota-changes` scans `SCAN_DIRS` = `usr boot opt srv media mnt` with `find -xdev` (DATA under `/mnt` and `/boot/firmware` are not walked). `/home` is not scanned: it is the DATA bind mount (`persist home`). `/etc`, `/var`, `/root` are left out on purpose: they are DATA overlays with their own rules, and `/var` is a plain directory at build but an overlay at runtime, so including it would flag every file.
- `unexplained` = changed paths minus files listed in `/var/lib/dpkg/info/<pkg>.list` of added/removed/changed packages and the side effects `/boot/initrd.img*`, `/boot/vmlinuz*`, `/usr/lib/modules/*`. `digest` = sha256 of the concatenated `pkg.added`, `pkg.removed`, `pkg.changed` and `unexplained` lists, so it covers exactly what the operator sees.
- `check` exits 2 when the baseline directory is missing (image built without it). A non-empty `OTA_CHANGES_PROGRESS` makes the tool write the phase text to `/run/unitotem-ota-changes.progress` (status bar only, not for parsing).
- DATA is empty in the image; only `data-op mkfs` or a full disk deploy formats it.
- State files are fsynced. Block-level power cuts and disk cache reordering are not covered by tests.

## Tests

- `python3 tools/release/test_identity_merge.py`: identity merge, no target.
- `unitotem/verify-image.sh <rootfs> <arch> <ab>`: fstab, persist list, overlay hook; run by stage 3.
- `work/loopback-test/run-ab.sh <parts dir>` (env `ARCH`): A/B deploy in a privileged container.
- `work/loopback-test/powercut-ab.sh`: QEMU power cuts at crashpoints (`testing.md`).
