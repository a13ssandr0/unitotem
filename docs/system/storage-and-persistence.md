# Storage: partitions, read-only root, DATA overlays

Paths: relative to the repository root.

Immutable Debian root on two A/B slots (ROOT_A, ROOT_B). Mutable state lives on DATA and is overlaid onto `/etc`, `/root`, `/var`. Update mechanics: `ab-updates.md`.

## Files

| Path | Role |
|---|---|
| `unitotem/common.sh` | `AB_LAYOUT`, `ROOT_SLOT_SIZE` 5G, `IMAGE_SIZE` 14G (single-root only), `EFI_SIZE`, `FIRMWARE_SIZE` 512M |
| `unitotem/stage3-image.sh` | Partition table (DOS on arm64, GPT on amd64), `mkfs`, baseline, final fsck, shrink, xz |
| `unitotem/shrink-root-image.sh` | ROOT_A shrunk to its minimum on both table types |
| `tools/release/test_grow_data.sh` | Container test of `grow_root`, `layout_complete` and `grow_data`, GPT and DOS, images without ROOT_B and DATA (privileged Docker) |
| `tools/release/test_first_boot_layout.sh` | QEMU test of a built image (UEFI and BIOS) |
| `unitotem/stage2-configure.sh` | fstab; A/B drops `LABEL=ROOT /` and `LABEL=BOOT`; installs overlay hook; cmdline `ro` |
| `unitotem/files/fstab-arm64`, `fstab-amd64` | Boot FAT `ro,nofail`; tmpfs `/tmp`, `/run`, `/var/cache`, `/var/tmp` |
| `unitotem/files/overlayfs-hook.sh` | initramfs local-premount `unitotem-layout` and init-bottom `setup-overlays` (same file): `grow_root`, `layout_complete` (GPT and DOS), DATA lookup, fsck, `grow_data`, mount, per-slot overlays, dpkg pin, volatile overlays without DATA |
| `unitotem/files/ota-preserve.list` | `/etc` whitelist carried across an update |
| `unitotem/files/unitotem_identity.py` | Local account merge (passwd, shadow, group, gshadow) |
| `unitotem/files/unitotem-update` | `prepare_overlays`, whitelist import, identity merge, state files |
| `unitotem/files/unitotem-persist-paths` (+ `.service`) | Binds DATA persist dirs over `/var` targets |
| `unitotem/files/unitotem-ssh-hostkey` (+ `.service`) | SSH host keys on DATA |
| `unitotem/files/unitotem-maintenance` (+ `-mode.service`) | Writable root for apt and manual changes |
| `unitotem/files/unitotem-ota-changes` | Baseline and diff of ROOT (scope `usr boot opt srv media mnt`) |
| `deploy/script/ota-engine.sh` | Fallback path: `data-op`, `migrate-etc-overlay`, `init-premount`, `local-bottom-verify` |
| `deploy/script/remote-deploy.sh` | DATA backup before disk replacement; preserve/format choice |

## Layout

A/B (`AB_LAYOUT=1`), layout on the target disk after a deploy or the first boot (the image itself holds only the boot partition, ROOT_A shrunk and, on amd64, BIOS; see Images):

| # | arm64 | amd64 |
|---|---|---|
| 1 | FIRMWARE FAT32 512 MiB | EFI FAT32 512 MiB |
| 2 | ROOT_A ext4 5 GiB | ROOT_A ext4 5 GiB |
| 3 | ROOT_B ext4 5 GiB | ROOT_B ext4 5 GiB |
| 4 | DATA ext4 (rest of the disk) | DATA ext4 (rest of the disk) |
| 5 | - | BIOS (ef02), sectors 34-2047, before partition 1 |

amd64 A/B has no BOOT partition: each slot carries its kernel and initrd in `/boot`; GRUB lives on the ESP. Single-root (`AB_LAYOUT=0`): arm64 FIRMWARE, ROOT, DATA; amd64 EFI, BOOT, ROOT, DATA, BIOS; overlay suffix empty. Slot size is fixed: changing it means repartitioning and moving DATA.

Partition table (by input and target):

| Input | Table on the disk |
|---|---|
| Image, amd64 (`write-sd.sh`, Imager, `dd`, installer ISO, Windows installer) | GPT, as built |
| Image, arm64 (same writers) | DOS, as built |
| Image, network deploy, Raspberry Pi target | DOS: a GPT source is converted by `remote-deploy.sh`; an arm64 source is used as is. Not written when DATA is kept (the disk keeps its table) |
| Image, amd64, network deploy, PC target | GPT, as built |

- The build writes the table of each architecture itself: GPT on amd64, DOS on arm64 (primaries only). `write-sd.sh` copies the table of the image with its GUIDs and label-id.
- The release assets and the `unitotem-release` input keep the source table: `unitotem-release` reads the partitions through `sfdisk` on both tables and identifies ROOT_A by filesystem label; the payload is partition bytes only, valid on any table.
- GRUB `part_gpt` (`grub-ab-entries`, `grub-ota-entry`) is amd64 only; the updater finds slots by PARTLABEL on GPT and by filesystem label on MBR ([ab-updates](ab-updates.md#slot-devices-and-repair-writes)).

Images:

- Image (`unitotem-<date>-<arch>.img.xz`, one file per architecture; 2026.11.57 arm64: 3.7 GiB expanded, 597 MiB xz; amd64: 5.1 GiB expanded, 1.68 GiB xz):
  - amd64: GPT with EFI, ROOT_A and BIOS.
  - arm64: DOS table, primaries only: FIRMWARE (type `c`, bootable) as partition 1, ROOT_A (type `83`) as partition 2. Written by stage 3 at build time.
  - ROOT_A shrunk to its minimum on both tables (`e2fsck -f`, `resize2fs -M`, partition = filesystem + 16 MiB, `unitotem/shrink-root-image.sh`).
  - ROOT_B and DATA are not in the image: the FAT root file `unitotem-layout` (`UNITOTEM_SLOT_SECTORS=10485760`) describes the target layout, which `image_describe` synthesizes for the network deploy and `write-sd.sh` ([deploy-and-recovery](deploy-and-recovery.md)). The first boot creates them: ROOT_A grows to 5 GiB (`grow_root`, offline, in the initramfs before the root is mounted), ROOT_B is created blank, DATA is created and formatted.
  - The same file serves the network deploy (`remote-deploy.sh` reads it in place), `write-sd.sh`, Raspberry Pi Imager and `dd`, the installer ISO, the Windows installer, the release assets and `build-ab` (which grows ROOT_A to the slot size in its temp copy, [ab-updates](ab-updates.md)).
  - Checked at build: boot assertions, `verify-image.sh`, fsck of every partition ([build](build.md)).
- The BIOS-boot partition (amd64) sits at sectors 34-2047, before partition 1, so it is part of the image and never in the way of the space that is cut off.

Runs at every boot (initramfs local-premount `unitotem-layout`, then init-bottom `setup-overlays`, `overlayfs-hook.sh`; the premount run comes before the root is mounted; the OTA fallback and the resident recovery initrd do not carry the hook). Each decision is derived from the disk on every boot, no flag file; any failure logs one line and the boot continues.

0. `grow_root` (first thing in `layout_complete`, root not mounted; skipped when ROOT_A is mounted): (a) when ROOT_A is the last partition and smaller than 5 GiB, and 5 GiB + 256 MiB are free after the grown slot, the partition is set to 5 GiB (GPT: `sgdisk -e`, then `sfdisk -N` for ROOT_A only, `sgdisk -v`, `partx -u`; the kernel size is checked before the filesystem is touched); (b) when the filesystem is at least 32 MiB smaller than its partition, `e2fsck -fp` (exit >1: one `e2fsck -fy`), then `resize2fs`. Log: `grow: ROOT_A grown to 5120 MiB`. Less free space: one warning, nothing changed. The kernel not showing the new size: one warning, `layout_complete` stops.
1. `layout_complete`: acts when ROOT_A is the last partition, ROOT_A is 5 GiB, the GPT has neither ROOT_B nor DATA and at least 5 GiB + 256 MiB are free after ROOT_A. ROOT_A below 5 GiB: nothing created (the table never places ROOT_B after a small ROOT_A).
   - `sgdisk -e` (backup GPT to the disk end), first MiB of both new areas zeroed (stale signatures of a reused card), then one `sgdisk` table write adds p3 ROOT_B (5 GiB, 1 MiB aligned right after ROOT_A, type 8300, name ROOT_B, no pending flag) and p4 DATA (to the last usable sector), type 8300, flagged pending (GPT attribute bit 48); `sgdisk -v` must be clean.
   - ROOT_B is blank: no filesystem, no label. Nothing is formatted at this step. `partx -a --nr 3` tells the kernel about it, and `partx -a --nr 4` about DATA; the mounted ROOT_A is not touched.
   - Every partition flagged pending is formatted (DATA: `mke2fs -t ext4 -L DATA`, same defaults as stage3's `mkfs.ext4 -L`) and its flag cleared. A ROOT_B flagged by an older image is formatted and cleared the same way.
   - ROOT_B stays blank until the first confirmed boot: `unitotem-update` `slot_sound` reports `first-boot` (no label and no filesystem signature), and the auto-repair (`UPDATE_AUTOREPAIR=1`) clones the running slot into it ([ab-updates](ab-updates.md#repair)).
   - Crash safety: before the table write nothing changed. After it ROOT_B is blank, which needs nothing, and DATA's flag is the state: the next boot formats DATA and clears the flag. Only flagged partitions are ever formatted, so a damaged filesystem is never reformatted. ROOT_A and the boot partition are never written.
   - DOS (MBR) disks (`layout_mbr`, primaries only, same first-boot rule):
     - Needs ROOT_A the last partition, partitions 1 to ROOT_A all present, no extended partition, ROOT_A in partition 1-3 and a disk of 2 TiB or less. ROOT_A in partition 4: one warning, no change. An extended partition: one warning, no change.
     - ROOT_B (size of ROOT_A) and DATA (to the disk end) are added in one `sfdisk --append` write when ROOT_A is partition 1 or 2 and at least ROOT_A + 256 MiB is free. DATA alone, as the next primary, when ROOT_A is partition 1-3 and at least 256 MiB is free. Less free space: one warning, no change.
     - ROOT_B is type `83` from the table write and blank (no filesystem). DATA is type `db` (pending). `--append` and `--no-reread` keep the disk label-id and the kernel away from the mounted root.
     - Formatting: DATA only (`mke2fs -t ext4 -L DATA`), then its type change to `83`. A ROOT_B of type `da` from an older image is formatted and set to `83` the same way.
     - Power cuts: before the table write nothing changed. After it, the next boot finds `db` and formats DATA. A cut after `mke2fs` and before the type change leaves a flagged, empty filesystem that the next boot formats again. Known residual: if the type change fails after DATA was formatted and used, the next boot formats DATA again.
     - Slot devices on MBR are found by position and label: a blank ROOT_B is the partition next to ROOT_A (`slot_dev` in `unitotem-update`), rules in [ab-updates](ab-updates.md#slot-devices-and-repair-writes).
2. `grow_data` (DATA found, `e2fsck -p` done, not mounted): acts when the disk is GPT or DOS, DATA is ext4 and the last partition by start sector, and at least 64 MiB are free after it. DOS: DATA is a primary (1-4); the free space is the disk size minus the end of DATA (no backup table); `sgdisk` is not called.
   - GPT: `sgdisk -e`. `sfdisk -N 4` (`--wipe never --wipe-partitions never`: sfdisk otherwise wipes the filesystem signature of the resized partition) rewrites only the DATA entry (type, GUID or label-id, name or flags kept) in one table write; GPT: `sgdisk -v` must be clean; `partx -u --nr 4` updates the kernel size of DATA only.
   - Then, if the filesystem is at least 32 MiB smaller than the partition: (a) `e2fsck -fp`. Exit 0 or 1: go to (b). Exit >1 (a cut inside `resize2fs` can leave "Resize inode not valid": reproduced by SIGKILL between 0.085 and 0.105 s of the ~0.18 s offline `resize2fs` on a 400 GB disk, hit in 38 of 55 runs in that window; exit 4 "UNEXPECTED INCONSISTENCY", dumpe2fs state "clean with errors") while the filesystem is smaller than its partition (a growth is pending; never when it already fills the partition): ONE `e2fsck -fy` runs, logs "grow: repaired DATA after an interrupted resize", and must return <=1 (measured: exit 1, then `-fn` clean, second `-fy` exit 0, file checksums unchanged, `resize2fs` completes, 12 of 12 copies); then (b). Any other case: one warning, the boot continues with the filesystem unchanged. (b) Offline `resize2fs`. A cut after the table write is finished by the next boot (the filesystem is smaller than its partition).
   - Skipped with one log line: not ext4, neither GPT nor DOS, DATA not last, logical DATA (DOS partition 5 or above). Skipped silently: less than 64 MiB free (also the case of an image on a disk of its own size), nothing to grow.
   - Measured (privileged container, loop on the work dir): ROOT_A ~2.5 GiB -> 5 GiB (image without ROOT_B and DATA), `grow_root` alone 1.18 s; `layout_complete` + `grow_data` of the same image on a 20 GB disk 5.4 s.
   - Measured (privileged container, sparse loop disk, ROOT_A mounted from the same disk): 400 GB disk, DATA 3 GiB -> ~400 GB: whole `grow_data` 1.2 s offline (`resize2fs` alone online 0.18 s, so offline costs nothing noticeable; offline also has no reserved-GDT limit); `layout_complete` on 400 GB (ROOT_B 5 GiB + DATA ~395 GB, lazy inode tables) 4.3 s; on 20 GB 4.2 s.
   - The kernel accepts the changes with the root partition of the same disk mounted: `partx -u/-a` use the BLKPG calls for the named partition only.
   - Minimum disk for the layout: 10.75 GiB: boot partition and 1 MiB (513 MiB), ROOT_A 5 GiB, ROOT_B 5 GiB, 256 MiB for DATA. Below that `grow_root` logs one line and nothing is created.
   - Measured on the arm64 2026.11.57 image (ROOT_A fs 3241 MiB, 3.7 GiB image, 597 MiB xz): expansion into `/dev/shm` 3.2 s; `partclone.extfs -c | xz -1` of ROOT_A 16 s (628 MB); restore of that stream into a 5 GiB loop device on tmpfs 6.8 s; offline `e2fsck -fy` and `resize2fs` to 5 GiB 0.1 s each on tmpfs; afterwards `e2fsck -fn` clean and the sha256 of every file equals the source.
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
- `migrate-etc-overlay --slot S` (the deploy passes `--slot a`): the live slot is the one whose DATA state is migrated (`auth_live_slot`: `unitotem.slot=` on the command line, else the saved slot; with `guess`, migrate only, the slot whose newest account file is newer, a tie keeps a). Uppers and works of the other slot are archived, never deleted, under `history/<ts>/<name>.<slot>`. When the live slot is not S, S's own leftovers are archived the same way first, and the live `root` upper moves to `root.S` (the administrator keys follow the live system). The live `etc` and `var` uppers go to `history/<ts>/`; S gets empty `etc` and `var`; `ota-preserve.list` matches are copied from the archived `etc` into `upper/etc.S`. The archived `etc` name is printed as `UNITOTEM_ETC_HISTORY=<ts>` (input of the account carry). Removes `pending.json`, `slots.json`, `last-result.json`. Then keeps the newest 10 `history/` entries (`HISTORY_KEEP`, `prune_history`) and deletes the rest; only `YYYYMMDDTHHMMSSZ` names are candidates.
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
- A fallback deploy that keeps DATA carries accounts by the same rules: the archived `etc` upper (`UNITOTEM_ETC_HISTORY`) is merged on the deploy host (`deploy-identity.py`, `unitotem_identity.py`; the recovery initrd has no Python), then `install-identity` writes the four files into `upper/etc.a` (shadow files 640, group `shadow` from the merged group file; staged under umask 077 and removed after). A refused merge (exit 1) or a failed carry leaves the image's accounts and a warning (first access). Fresh DATA has no accounts. Details: [deploy-and-recovery](deploy-and-recovery.md#how-it-works).
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
- DATA is empty in the image; only `data-op mkfs`, a full disk deploy or `layout_complete` (first boot of an image, partition flagged pending) formats it. Everything that seeds DATA (`mkdir -p` in the hook, `unitotem-persist-paths`, `unitotem-ssh-hostkey`) assumes an empty, freshly formatted DATA.
- State files are fsynced. Block-level power cuts and disk cache reordering are not covered by tests.

## Write budget

Measured 2026-11-16 (`/sys/block/*/stat` sectors written, 60 s samples; idle kiosk, image 2026.11.53-66). DATA (`/mnt/data`, ext4 `noatime,nodiratime`, no `commit=`) is the only partition written; ROOT slots, boot FAT and the other slot stay at 0.

| Host | Media | DATA KiB/min | journald | manager (CEF) |
|---|---|---|---|---|
| Pi 4 | SD | 480-1000 | 250-750 | 90-250 |
| Pi 3 | SD | 430-1000 | 230-400 | 75-190 |
| HP 250 G5 | SATA SSD | 1800-3400 | 1300-2550 | 440-580 |
| amd64 test PC (Iris Xe) | NVMe | 5400-11600 | 3200-5500 | 430-4100 |
| Field Pi 4 / Pi 3 | SD | 480-1640 | 220-880 | 115-570 |
| Field amd64 (eMMC) | eMMC | 8200-13000 | 5800-8800 | 1590-1700 |

- journald writes 40-600 times the text it stores: the journal is an mmap file of 8-32 MiB whose dirty pages are flushed by `journal-offline` (ext4 `writepages` trace: `system.journal` and `user-1000.journal` only). `SyncIntervalSec=5min` does not bound it.
- `Storage=volatile` (runtime drop-in, 5 min each, reverted): Pi 4 DATA 700 -> 150-230 KiB/min, HP 250 G5 3000 -> 380-710 KiB/min. A drop-in under `/run/systemd/journald.conf.d/` must sort after `unitotem.conf` (`zz-`), else `Storage=persistent` wins.
- Browser profile (`/var/lib/unitotem/browser`, DATA): the shader and GPU caches (`GPUCache`, `Dawn*Cache`, `GrShaderCache`, `ShaderCache`, `GraphiteDawnCache`, `data_1` 270 KiB each) are rewritten every few minutes; `BrowserMetrics-*.pma` (4 MiB mmap, unlinked) was the 4096 KiB/min writer of the amd64 test PC manager (ext4 `writepages` inode trace); `chrome_debug.log` (WARNING level) grew to 122 MB in two days on the field amd64 node.
- `serial-getty@ttyS0` restart loop (no UART): 18101 restarts in two days on the field amd64 node, one `wtmp` record and several journal lines each (`/var/log/wtmp` 6.9 MB). Fixed in the image by the `ExecCondition` drop-in.
- Applied (2026.11.67): `MaxLevelStore=warning` (journal drop-in `zz-` in `/run`, 5 x 60 s before and after, reverted): HP 250 G5 3370 -> 750 KiB/min, Pi 4 720 -> 210 KiB/min. The manager's lines carry sd-daemon priorities (`utils/_logging.py`), so its warnings and errors stay in the journal. Nothing reads the persistent INFO lines (health gate, boot-ok, OTA hooks and the manager do not call `journalctl`).
- Applied: `link_ram_caches()` (`viewer.md`) puts `BrowserMetrics`, the shader and GPU caches and the metrics file in `/var/cache/unitotem-cef/profile` (tmpfs); the browser removes the `BrowserMetrics` link when it exits but not the files behind it, so the directory is emptied at every start. the amd64 test PC (code bind-mounted from `/run`, reverted, 4 x 60 s per phase): journal in warning mode only 1380 KiB/min, with the caches 1800 KiB/min; journal at info 7500 vs 7250 KiB/min: the rate of one NVMe DATA partition varies by +-3000 KiB/min between samples, the effect of the caches is below that. Verified: the browser opens its files under `/var/cache/unitotem-cef`, one page, GPU process alive, no restart, `chrome_debug.log` in RAM.
- Not applied: `commit=60` on DATA.
- CEF log: errors only, file in `/var/cache/unitotem-cef` (RAM).

## Tests

- `python3 tools/release/test_identity_merge.py`: identity merge, no target.
- `unitotem/verify-image.sh <rootfs> <arch> <ab>`: fstab, persist list, overlay hook; run by stage 3.
- `work/loopback-test/run-ab.sh <parts dir>` (env `ARCH`): A/B deploy in a privileged container.
- `work/loopback-test/powercut-ab.sh`: QEMU power cuts at crashpoints (`testing.md`).
- `tools/release/test_grow_data.sh [--big]` (privileged Docker, loop devices inside the container only; 280 checks): images without ROOT_B and DATA (`grow_root`: mounted, tight disk, cut after the table write, SIGKILL in `resize2fs`, premount dispatch), plus builds the stage3 layouts of both architectures, writes them to larger disks and runs `layout_complete` and `grow_data` under `dash` with the root partition mounted; also flash-image creation, no-op and interruption cases (including the `resize2fs` kill with `e2fsck -fy` repair), DOS cases (32 GB and 15 GB grow, image size, less than 64 MiB free, vfat DATA, partition after DATA, logical DATA), `--big` adds the 400 GB timings.
- `tools/release/test_make_flash_image.sh` (privileged Docker, loop devices inside the container only; 77 checks): arm64 image is DOS (type, label-id, start, size, bootable, bytes), `layout_mbr` completes it to four primaries, amd64 stays GPT: 30 checks.
- `tools/release/test_first_boot_layout_dos.sh` (privileged Docker, 50 checks): DOS layout, power cuts, legacy `da`/`db` types, GPT path.
- `tools/release/test_first_boot_layout.sh IMG [uefi|bios|both]`: boots a built image in QEMU on a 20 GiB disk and checks ROOT_B (blank, then cloned with cause `first-boot`), DATA, the mount and `slot_sound` (`repair` finds the other slot sound) over ssh.
