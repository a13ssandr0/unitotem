# Storage: partitions, read-only root, DATA overlays

Paths: relative to the repository root.

Immutable Debian root on two A/B slots (ROOT_A, ROOT_B). Mutable state lives on DATA and is overlaid onto `/etc`, `/root`, `/var`. Update mechanics: `ab-updates.md`.

## Files

| Path | Role |
|---|---|
| `unitotem/common.sh` | `AB_LAYOUT`, `ROOT_SLOT_SIZE` 5G, `IMAGE_SIZE` 14G, `EFI_SIZE`, `FIRMWARE_SIZE` 512M |
| `unitotem/stage3-image.sh` | Partition table, `mkfs`, baseline, final fsck, flash image |
| `unitotem/make-flash-image.sh` | Full image -> flash image (boot partition(s) + ROOT_A only) |
| `tools/release/test_grow_data.sh` | Container test of `layout_complete` and `grow_data` (privileged Docker) |
| `tools/release/test_first_boot_layout.sh` | QEMU test of a built flash image (UEFI and BIOS) |
| `unitotem/stage2-configure.sh` | fstab; A/B drops `LABEL=ROOT /` and `LABEL=BOOT`; installs overlay hook; cmdline `ro` |
| `unitotem/files/fstab-arm64`, `fstab-amd64` | Boot FAT `ro,nofail`; tmpfs `/tmp`, `/run`, `/var/cache`, `/var/tmp` |
| `unitotem/files/overlayfs-hook.sh` | initramfs init-bottom: `layout_complete` (GPT and DOS), DATA lookup, fsck, `grow_data`, mount, per-slot overlays, dpkg pin, volatile overlays without DATA |
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
| 1 | FIRMWARE FAT32 512 MiB | EFI FAT32 512 MiB |
| 2 | ROOT_A ext4 5 GiB | ROOT_A ext4 5 GiB |
| 3 | ROOT_B ext4 5 GiB | ROOT_B ext4 5 GiB |
| 4 | DATA ext4 (rest of the image, 3 GiB at `IMAGE_SIZE` 14G) | DATA ext4 (rest of the image) |
| 5 | - | BIOS (ef02), sectors 34-2047, before partition 1 |

amd64 A/B has no BOOT partition: each slot carries its kernel and initrd in `/boot`; GRUB lives on the ESP. Single-root (`AB_LAYOUT=0`): arm64 FIRMWARE, ROOT, DATA; amd64 EFI, BOOT, ROOT, DATA, BIOS; overlay suffix empty. Slot size is fixed: changing it means repartitioning and moving DATA.

Images:

- Full image (`unitotem-<date>-<arch>.img.xz`, 14 GiB): the layout above. Source of the parts set (network deploy), the release assets and `build-ab`.
- Flash image (`unitotem-<date>-<arch>-flash.img.xz`, A/B only, ~5.6 GiB): written to a card or disk with Imager or `dd`. `unitotem/make-flash-image.sh` builds it from the full image: fresh GPT (same disk GUID) with every partition except ROOT_B and DATA (same numbers, GUIDs, names, attributes, start sectors; bytes copied unchanged; on amd64 the MBR boot code too), then 1 MiB. Checked at build: `sgdisk -v`, sha256 of every kept partition, fsck of boot and ROOT_A.
- The BIOS-boot partition (amd64) sits at sectors 34-2047, before partition 1, so it is part of the flash image and never in the way of the space that is cut off.

First boot of a flash image and of any image on a larger disk (initramfs init-bottom, `overlayfs-hook.sh`, before and after the DATA lookup; the OTA fallback and the resident recovery initrd do not carry the hook). Each decision is derived from the disk on every boot, no flag file; any failure logs one line and the boot continues.

1. `layout_complete`: acts when ROOT_A is the last partition, the GPT has neither ROOT_B nor DATA and at least 5 GiB + 256 MiB are free after ROOT_A.
   - `sgdisk -e` (backup GPT to the disk end), first MiB of both new areas zeroed (stale signatures of a reused card), then one `sgdisk` table write adds p3 ROOT_B (5 GiB, 1 MiB aligned right after ROOT_A) and p4 DATA (to the last usable sector), type 8300, both flagged pending (GPT attribute bit 48); `sgdisk -v` must be clean.
   - `partx -a --nr 3` and `--nr 4` tell the kernel about the two new partitions only; the mounted ROOT_A is not touched.
   - Every partition flagged pending is formatted (`mke2fs -t ext4 -L ROOT_B|DATA`, same defaults as stage3's `mkfs.ext4 -L`) and its flag cleared. ROOT_B is left as an empty labelled slot: `unitotem-update` `slot_sound` reports it `empty` and the auto-repair (`UPDATE_AUTOREPAIR=1`, started after the first confirmed boot) copies the running slot into it.
   - Crash safety: before the table write nothing changed; after it the pending flags are the state, and the next boot formats what is still flagged. Only flagged partitions are ever formatted, so a damaged filesystem is never reformatted. ROOT_A and the boot partition are never written.
   - DOS (MBR) disks (`layout_mbr`, primaries only, same first-boot rule):
     - Needs ROOT_A the last partition, partitions 1 to ROOT_A all present, no extended partition, ROOT_A in partition 1-3 and a disk of 2 TiB or less. ROOT_A in partition 4: one warning, no change. An extended partition: one warning, no change.
     - ROOT_B (size of ROOT_A) and DATA (to the disk end) are added in one `sfdisk --append` write when ROOT_A is partition 1 or 2 and at least ROOT_A + 256 MiB is free. DATA alone, as the next primary, when ROOT_A is partition 1-3 and at least 256 MiB is free. Less free space: one warning, no change.
     - Pending flags are the MBR types `da` (ROOT_B) and `db` (DATA). `--append` and `--no-reread` keep the disk label-id and the kernel away from the mounted root.
     - Formatting: DATA first, then ROOT_B (`mke2fs -t ext4 -L <label>`), each followed by its type change to `83`.
     - Power cuts: before the table write nothing changed. After it, the next boot finds `da`/`db` and formats them. A cut after `mke2fs` and before the type change leaves a flagged, empty filesystem that the next boot formats again. Known residual: if the type change fails after DATA was formatted and used, the next boot formats DATA again.
     - Slot devices on MBR are found by filesystem label: `slot_dev` in `unitotem-update`, rules in [ab-updates](ab-updates.md#slot-devices-and-repair-writes).
     - Still GPT-only: `grow_data` (logs one line and skips DOS), `tools/release/unitotem-release` (`sgdisk -i`), GRUB `part_gpt` in `grub-ab-entries` and `grub-ota-entry`. Full A/B on a DOS disk (Pi 3) also needs a one-shot trial without tryboot, a release build for MBR, and DATA growth on DOS.
2. `grow_data` (DATA found, `e2fsck -p` done, not mounted): acts when the disk is GPT, DATA is ext4 and the last partition by start sector, and at least 64 MiB are free after it.
   - `sgdisk -e`; `sfdisk -N 4` (`--wipe never --wipe-partitions never`: sfdisk otherwise wipes the filesystem signature of the resized partition) rewrites only the DATA entry (type, GUID, name, attributes kept) in one table write; `sgdisk -v` must be clean; `partx -u --nr 4` updates the kernel size of DATA only.
   - Then, if the filesystem is at least 32 MiB smaller than the partition: (a) `e2fsck -fp`. Exit 0 or 1: go to (b). Exit >1 (a cut inside `resize2fs` can leave "Resize inode not valid": reproduced by SIGKILL between 0.085 and 0.105 s of the ~0.18 s offline `resize2fs` on a 400 GB disk, hit in 38 of 55 runs in that window; exit 4 "UNEXPECTED INCONSISTENCY", dumpe2fs state "clean with errors") while the filesystem is smaller than its partition (a growth is pending; never when it already fills the partition): ONE `e2fsck -fy` runs, logs "grow: repaired DATA after an interrupted resize", and must return <=1 (measured: exit 1, then `-fn` clean, second `-fy` exit 0, file checksums unchanged, `resize2fs` completes, 12 of 12 copies); then (b). Any other case: one warning, the boot continues with the filesystem unchanged. (b) Offline `resize2fs`. A cut after the table write is finished by the next boot (the filesystem is smaller than its partition).
   - Skipped with one log line: not ext4, not GPT, DATA not last. Skipped silently: less than 64 MiB free (also the case of an image on a disk of its own size), nothing to grow.
   - Measured (privileged container, sparse loop disk, ROOT_A mounted from the same disk): 400 GB disk, DATA 3 GiB -> ~400 GB: whole `grow_data` 1.2 s offline (`resize2fs` alone online 0.18 s, so offline costs nothing noticeable; offline also has no reserved-GDT limit); `layout_complete` on 400 GB (ROOT_B 5 GiB + DATA ~395 GB, lazy inode tables) 4.3 s; on 20 GB 4.2 s.
   - The kernel accepts the changes with the root partition of the same disk mounted: `partx -u/-a` use the BLKPG calls for the named partition only.
   - Minimum disk for the layout: flash image (~5.6 GiB) + 5.25 GiB. Below that `layout_complete` logs one line and nothing is created.
   - The network deploy grows DATA itself (`ota-engine.sh`, `resize2fs` after `restore-part --grow`); the hook then finds nothing to do.

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
- init-premount (`ota-engine.sh init-premount`): validates the slot with a read-only fsck; on failure uses the other slot, else the OTA fallback. The root label is resolved by `slot_pick`; two copies on one disk are healed (the other one relabelled `ROOT_STALE`, `ROOT=` pinned; [boot.md](boot.md#boot-decision-initramfs-both-backends)). Then the boot counter gate, every layout ([Boot counter](boot.md#boot-counter)).
- local-bottom (`local-bottom-verify`): `/sbin/init` must exist, else OTA fallback.
- init-bottom (`overlayfs-hook.sh`):
  0. `layout_complete` (see Images above).
  1. Find DATA by label (10 tries, `udevadm settle`). Not found: volatile overlays (below), status in `/run/unitotem-overlay.status` (see `boot.md`).
  2. Add a journal if absent; `e2fsck -p` (exit 0/1 ok; others logged, never fatal).
  3. `grow_data`; mount DATA `noatime,nodiratime` at `/mnt/data`. A failed mount: volatile overlays (below).
  4. Stash ROOT's `/var/lib/dpkg`.
  5. Overlay `etc`, `root`, `var`: lower `ROOT/<d>`, upper `DATA/upper/<d><sfx>`, work `DATA/work/<d><sfx>`.
  6. Rebind dpkg over the `/var` overlay; drop the stash.
  7. Write `.unitotem-overlay-status` on DATA (not in volatile mode).
- Volatile overlays (`volatile_overlays`, no usable DATA: status `volatile:no-data` or `volatile:data-mount`):
  - A tmpfs at `/volatile` is the upper and work layer of `etc`, `root` and `var`. Size MemTotal / 8, clamped to 32..128 MiB; 64 MiB when `/proc/meminfo` is unreadable. dpkg is pinned to ROOT as on DATA. The tmpfs mount point is released once the overlays hold it.
  - Everything written in this boot is lost at reboot. No DATA record is written.
  - The tmpfs or an overlay fails: `failed:volatile`, the boot continues.
  - `unitotem-first-admin` reports the volatile state (see [Root and first access](image-runtime.md#root-and-first-access)).
- systemd: `unitotem-ssh-hostkey`, `unitotem-persist-paths`, `unitotem-boot-ok`.

Without DATA `unitotem-persist-paths` mounts a 32 MiB tmpfs on `/home` (volatile, like the other overlays) so the first administrator can be created; test `tools/release/test_persist_volatile.sh`.

Persist paths (`name -> target (mode group)`): `uploaded -> /var/lib/unitotem/uploaded` (755 root); `crontabs -> /var/spool/cron/crontabs` (1730 crontab); `browser -> /var/lib/unitotem/browser` (700 root); `home -> /home` (755 root, administrators' home directories; ROOT is read-only, so `/home` cannot live there). Absent DATA dir: created and seeded from the target. Owner and mode always set. Bound if not already a mountpoint.

Update into slot X from running slot C:

- `prepare_overlays` (fetch): clears `upper`/`work` of X; `etc.X` = whitelisted paths from `etc.C`; `root.X` = copy of `root.C`; `var.X` empty.
- `merge_identity_into`: `etc.X/{passwd,shadow,group,gshadow}` = image files + local accounts.
- `apply`: repeats whitelist import and identity merge, then arms the trial.
- C's uppers are never touched: rollback returns to C's state.

Fallback OTA (`ota-engine.sh`):

- `data-op preserve|mkfs`: `mkfs` runs `mkfs.ext4 -L DATA`.
- `migrate-etc-overlay --slot S`: removes the other slot's upper and work; moves `etc` and `var` uppers to `history/<ts>/`; restores whitelisted `etc` paths; removes `pending.json`, `slots.json`, `last-result.json`. `root.<slot>` is left as is. Then keeps the newest 10 `history/` entries (`HISTORY_KEEP`, `prune_history`) and deletes the rest; only `YYYYMMDDTHHMMSSZ` names are candidates.
- `/root` is carried across every update: `unitotem-update` copies `root.<old>` to `root.<new>` at fetch, and the fallback keeps `root.<slot>` in place (its administrator keys are read from there). Both paths keep the same `/root` content.
- DATA is kept only if a read-only `e2fsck -fn` passes.

## Interfaces

`/etc/unitotem/update.conf` (env `UNITOTEM_<KEY>` overrides; `UNITOTEM_UPDATE_CONF` = other file): `UPDATE_DATA` (`/mnt/data`), `UPDATE_STATE_DIR` (`/mnt/data/unitotem/update`), `UPDATE_ETC_CURRENT` (`/etc`), `UPDATE_CMDLINE` (`/proc/cmdline`), `UPDATE_CRASHPOINT` (test hook). Full list in `ab-updates.md`.

Kernel command line: `root=LABEL=ROOT_A|ROOT_B`, `unitotem.slot=a|b`, `ro`, `unitotem.maintenance=1`, `unitotem.ota=1|recover`.

State in `DATA/unitotem/update/`: `slots.json` (`{slot: {version, valid, prepared, confirmed}}`), `pending.json`, `last-result.json`, `identity-merge.json`, `preserve.list`, `identity-base/`, `events.log` (rotated to `.old` at 64 KB).

`ota-preserve.list`: one glob per line relative to `/etc`; `#` comments; lines with `=` ignored; matched directories copied recursively.

`unitotem-ota-changes`: `baseline --root DIR --out DIR` (build), `check [--json]` (device). Exit 0 clean, 1 not clean, 2 error. Verdicts `clean`, `packages-only`, `mixed`. JSON: `verdict`, `digest`, `packages{added,removed,changed}`, `files{unexplained,package_files_modified,unowned_added,unowned_removed,unowned_modified}`.

`.unitotem-overlay-status` keys: `boot-marker`, `overlay-slot-suffix`, `overlay-status` (`ok|failed:<reason>`, see `boot.md`; not written in volatile mode), `initramfs-{etc,root,var}` (`overlay-mounted|NOT-MOUNTED`), `initramfs-{etc,root,var}-writable` (`yes|no`), `initramfs-dpkg-pinned-to-root` (`skip|stashed|yes|FAILED`).

## Rules and gotchas

- Uppers are per slot; never delete the other slot's upper (rollback depends on it).
- ROOT_A or ROOT_B on two partitions of one disk is a repair interrupted by a reboot, not a second slot. Boot resolves it; a repair never labels the target with the source's label ([ab-updates](ab-updates.md#slot-devices-and-repair-writes)).
- DOS first boot changes the table with `sfdisk --append` only: no rewrite, label-id kept.
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
- DATA is empty in the image; only `data-op mkfs`, a full disk deploy or `layout_complete` (flash image, partition flagged pending) formats it. Everything that seeds DATA (`mkdir -p` in the hook, `unitotem-persist-paths`, `unitotem-ssh-hostkey`) assumes an empty, freshly formatted DATA.
- State files are fsynced. Block-level power cuts and disk cache reordering are not covered by tests.

## Tests

- `python3 tools/release/test_identity_merge.py`: identity merge, no target.
- `unitotem/verify-image.sh <rootfs> <arch> <ab>`: fstab, persist list, overlay hook; run by stage 3.
- `work/loopback-test/run-ab.sh <parts dir>` (env `ARCH`): A/B deploy in a privileged container.
- `work/loopback-test/powercut-ab.sh`: QEMU power cuts at crashpoints (`testing.md`).
- `tools/release/test_grow_data.sh [--big]` (privileged Docker, loop devices inside the container only): builds the stage3 layouts of both architectures, writes them to larger disks and runs `layout_complete` and `grow_data` under `dash` with the root partition mounted; also flash-image creation, no-op and interruption cases (including the `resize2fs` kill with `e2fsck -fy` repair), `--big` adds the 400 GB timings.
- `tools/release/test_first_boot_layout.sh FLASH_IMG [uefi|bios|both]`: boots a built flash image in QEMU on a 20 GiB disk and checks ROOT_B, DATA, the mount and the repair over ssh.
