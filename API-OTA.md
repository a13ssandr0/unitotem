# OTA API — change detection and deploy confirmation

Document for whoever implements the frontend in the `unitotem-manager` project. It contains only the **backend
contract**: commands, data formats, exit codes and the sequence to follow. No interface choices are imposed.

## The problem it solves

An OTA replaces the **entire ROOT partition**. Everything that was installed or modified on the running
system is destroyed. Without a report, an update and the loss of someone else's work are indistinguishable.

The backend answers two separate questions:

1. *what changed compared with the installed image?* → `unitotem-ota-changes`
2. *did the operator see and accept exactly those changes?* → `--accept-changes <digest>`

## Scope: what is considered

| Path | Backing | Survives the OTA? | In the report? |
|---|---|---|---|
| `/usr` `/boot` `/opt` `/srv` `/home` `/media` `/mnt` | ROOT | **No** | **Yes** |
| `/etc` | overlay on DATA | Only the `ota-preserve.list` whitelist | No |
| `/var` | overlay on DATA | No, reset | No |
| `/root` | overlay on DATA | Yes | No |
| `/var/lib/dpkg` | ROOT (anchored) | No | Yes, as a database |

`/etc`, `/var` and `/root` are excluded on purpose: they are overlays with their own rules at deploy time.
Including them would only produce noise — at build time `/var` is a plain directory, at runtime it is an overlay,
so every file under it would appear missing on every device.

## Command on the device

```
/usr/sbin/unitotem-ota-changes check [--json]
```

**Exit codes** — always tell them apart, `1` is not an error:

| Code | Meaning |
|---|---|
| `0` | no changes |
| `1` | changes detected (normal outcome, not an error) |
| `2` | the check itself failed (missing baseline, wrong arguments) |
| `127` | command missing: image older than this feature |

**Cost**: it depends on the filesystem cache, and the difference is large enough that timeouts must be sized for the
worst case. Measured on a Raspberry Pi 4: **~1m20s on the first run after a reboot**
(cold cache, reads 87 MB from the SD and walks 44,000 files), **~11 s on later runs**. The
time is almost all I/O: CPU use stays under 30 s in both cases. Do not assume the warm case: the first call after
the device boots is exactly the one an interface makes first.

**Progress**: with `OTA_CHANGES_PROGRESS=1` in the environment, the current phase is written as a single
line of text to `/run/unitotem-ota-changes.progress`. It is meant for a status bar, not for parsing.

### JSON schema

```json
{
  "verdict": "clean | packages-only | mixed",
  "digest": "<sha256>",
  "packages": {
    "added":   ["sl", "libgpm2"],
    "removed": ["old-package"],
    "changed": [{"name": "curl", "from": "7.88.1-10", "to": "7.88.1-11"}]
  },
  "files": {
    "unexplained":            ["/usr/bin/gzip", "/opt/mio/file"],
    "package_files_modified": ["/usr/bin/gzip"],
    "unowned_added":          ["/opt/mio/file"],
    "unowned_removed":        [],
    "unowned_modified":       []
  }
}
```

**`verdict`** is what the interface should be based on:

- `clean` — nothing changed, the update can proceed without asking anything
- `packages-only` — only package installs/removals/upgrades. Show `packages`; there is no need to list files:
  they are all explained by the package operations
- `mixed` — there is something else too. Show `files.unexplained`: these are the changes that **no** package
  operation accounts for, so they are the most likely to be intentional and the easiest to lose unnoticed

**`files.unexplained` is already filtered.** A file belonging to an installed or upgraded package does not
appear: it is a consequence of that operation, not a change in itself. The same goes for known side effects
(regenerated `/boot/initrd.img-*`, kernel modules). The other `files` fields are detail,
useful for an advanced view; for the normal flow `unexplained` is enough.

**`digest`** covers exactly what is shown (packages + unexplained files). It is used in the confirmation step.

## Deploy confirmation

On the host side (whoever orchestrates the deploy):

```
./deploy/remote-deploy.sh changes root@host [--json]
./deploy/remote-deploy.sh deploy  root@host --parts DIR --accept-changes <digest>
```

`--accept-changes` proceeds **only if** the digest still matches the changes present on the
device. If someone installed a package between the moment the operator saw the list and the moment they
confirmed, the deploy stops. This is the property that makes a confirmation from a web interface as safe as a
terminal prompt: one set of changes cannot be approved while another is destroyed.

`--accept-changes` also implies **non-interactive** execution: it suppresses the disk choice and the final
confirmation, which would otherwise wait on a terminal that a web interface does not have. The
digest is still verified before any write — it is a stricter confirmation than the keyboard one, not a
shortcut around it.

`--yes` accepts everything without looking. It is for scripts, not for the interface.

### Recommended sequence

1. `changes --json` → if `verdict` is `clean`, go ahead with the deploy
2. otherwise show packages and unexplained files, and keep `digest`
3. the user confirms → `deploy --accept-changes <digest>`
4. if the deploy stops because the digest does not match, go back to step 1: the system has changed

## Secure Boot (amd64/UEFI targets)

`remote-deploy.sh probe` prints a line `Secure Boot : enabled | disabled | cannot be detected` (read from the EFI variable
`SecureBoot`, never guessed). If it is **active**, `deploy` does not proceed on its own: the firmware rejects UniTotem's unsigned GRUB and
there are two ways forward, both possibly needing physical intervention. The choice is explicit:

```
./deploy/remote-deploy.sh deploy root@host --parts DIR --secure-boot shim|noshim|abort
```

| value | what it does | physical intervention |
|---|---|---|
| `shim` | enables the signed chain already present in the image (`EFI/unitotem-sb/`): Microsoft-signed shim → Debian-signed GRUB and kernel | only with an NVIDIA GPU (unsigned module: enroll the MOK key from the console) or firmware that does not trust the Microsoft UEFI CA; if the source system is not Debian the first step may fail ("bad shim signature") |
| `noshim` | just installs | **always**: at reboot "Security Violation", Secure Boot must be disabled in the firmware |
| `abort` | touches nothing | disable Secure Boot and run again |

Without `--secure-boot` an interactive deploy shows the three choices; a non-interactive one (`--yes`, `--accept-changes`) **refuses**
to start (exit ≠ 0, message listing the values). A target that is already UniTotem and boots with Secure Boot active keeps `shim`.
`shim` requires an A/B parts set (the chain is staged only there). A UI must therefore: read the state from the probe, show the three
choices with the warnings above, and pass the choice with `--secure-boot`.

## Installing packages on the device

Root is read-only. The way in is:

```
unitotem-maintenance enter                     # stops the kiosk and remounts / read-write
apt-get update && apt-get install ...
unitotem-maintenance exit [--initramfs]        # remounts read-only and REBOOTS the device
```

Three things the interface must know:

- **`unitotem-maintenance exit` reboots**, always, after 5 seconds. It is not optional.
- `enter` stops `unitotem-manager.service` and `start-xorg.service`, so the screen turns off and the manager
  stops responding until the device restarts. If the interface runs **on** the device, it will lose its own
  connection: the operation must be commanded so that it survives its own execution.
- `--initramfs` is needed only if the kernel or modules were updated.

Automatic background updates are disabled on purpose (`apt-daily.timer` and
`apt-daily-upgrade.timer` are masked): on this image updates go through the OTA, and a
timer that modifies packages on its own would make this report noisy with changes nobody
made.

## Where the baseline comes from

Generated at build time in `/usr/lib/unitotem/baseline/` (`unitotem/stage3-image.sh`), as the last operation
on the image: `packages`, `unowned.sha256`, `verify-expected`, `meta`.

If it is missing, `check` exits with `2`. An image built before this feature has no baseline
and the device answers `127` to the command: in both cases the interface should say that detection
is not available on that device, not that there are no changes.

## Backup before a deploy

When `remote-deploy.sh deploy` finds that the target already runs UniTotem, it saves the target's DATA content (media, settings, accounts, update state; not the build scratch tree `unitotem-native-build`)
on the machine that runs the script before anything is armed or written. The archive is `unitotem-data-<host>-<version>-<timestamp>.tar.zst` (`.tar.xz` without zstd) with a `.sha256` beside it, in
`backups/` of the repository or the directory given by `--backup-dir DIR` / the environment variable `UNITOTEM_BACKUP_DIR`. The archive is read back before the deploy goes on; a failed backup (or too little
free space) stops the deploy with nothing changed on the target. `--no-backup` skips it; `--fallback-only` never takes one because nothing is written.
Targets that run an earlier UniTotem (1.x or 2.x, the `unitotem-manager` package on an ordinary single-root Debian/Raspberry Pi OS, detected through the package version and reported by `probe` as `Earlier UniTotem (single root)`) get the same backup, of what that version keeps on the root filesystem: `/etc/unitotem`, the uploaded media of the package, root's crontab, `/etc/netplan`, hostname, hosts, the TLS certificate, `asound.conf` and the kiosk launch file. The archive is `unitotem-legacy-<host>-<version>-<timestamp>.tar.zst`.
`remote-deploy.sh recover` saves DATA the same way, from the fallback environment, when DATA is about to be rewritten (`--wipe-data`, or a partition table that does not match) and it still mounts.
