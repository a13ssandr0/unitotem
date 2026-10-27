# Immutable Debian image with A/B updates

## Principles

- The system is Debian. There is no `apt` at runtime; `dpkg` stays (verification, inventory, `unitotem-ota-changes`).
- **Whole images** are distributed: the device downloads the image, writes it to the inactive slot and reboots
  into it; user data is never touched.
- The running system writes the inactive slot while it keeps working, then switches slot with a trial reboot.
  The old slot stays intact until the new one is confirmed.
- The RAM fallback (OTA fallback) is the rescue path (both slots broken, first deploy, adoption of a foreign OS)
  and the host-driven path. It is the only tool that works when A/B is not enough.

## Layout

arm64:

| # | label | fs | notes |
|---|---|---|---|
| 1 | `FIRMWARE` | FAT32 1 GiB | shared Pi firmware + `slota/` `slotb/` + `recovery*` |
| 2 | `ROOT_A` | ext4 6 GiB | |
| 3 | `ROOT_B` | ext4 6 GiB | |
| 4 | `DATA` | ext4 rest | |

amd64: `EFI`, `BOOT` (kept for recovery), `ROOT_A`, `ROOT_B`, `DATA`, `BIOS` (ef02).

Slot size is 6 GiB. **It is the only truly rigid constraint of the system**: resizing it later means repartitioning and
moving DATA, and a device with 5 GiB slots cannot receive a 6 GiB image without repartitioning. The whole image is
about 11 GiB (`IMAGE_SIZE` ~14 GiB).

### Slot selection

**arm64**: `os_prefix=slota/` (or `slotb/`) in `config.txt` makes the firmware look for kernel, initramfs, dtb,
overlays and `cmdline.txt` in the slot's subdirectory. The shared parts (`start4.elf`, `fixup4.dat`, `bootcode.bin`)
stay in the root. Each slot's `cmdline.txt` declares `root=PARTLABEL=ROOT_x` (or LABEL). The trial uses `tryboot`
(`tryboot.txt`): it holds the other slot's `os_prefix=` and is **one-shot at firmware level** (a power cut during the
trial returns to the old slot by itself, without software). `os_prefix` and `tryboot` are verified on a Raspberry Pi 4.
Models without tryboot (Pi 3, Zero 2) use the `rpi-legacy` path plus the boot counter.

**amd64**: kernel and initramfs live inside each slot's ROOT (`/boot`), GRUB reads ext4;
`grub-reboot <slot>` = one-shot trial, `grub-set-default` = promotion. `grubenv` is on the ESP.

`fstab` has no `/` line (the root comes from `root=` in the command line); the initramfs and `ota-local-bottom-verify`
use the root passed by the bootloader, not `blkid -L ROOT`.

### DATA and the overlays: one state per slot

`/etc`, `/root`, `/var` are overlays on `DATA/upper/*`, and **the upper is per slot** (`upper/etc.a`, `upper/etc.b`, ...):
otherwise an update would destroy the state the old slot needs for a clean rollback. On apply, the new slot starts
from an empty upper plus the whitelist (`ota-preserve.list`) imported from the current slot's upper. The old slot keeps
its upper intact.

Data that must be **shared** between slots lives outside the overlays, in `DATA/unitotem/persist/`
(see `unitotem-persist-paths`: `uploaded/`, `crontabs/`) and `ssh-host-keys/`.

**Constraint on the manager**: if a new manager migrates `/etc/unitotem/*` to a format the old one cannot read,
a rollback lands on a slot that does not understand the shared data. Rule: files in `persist/` and shared
configs must stay **backward compatible by one version**, or the manager must take a snapshot before migrating.

## No apt at runtime, dpkg yes

In the final stage of the build: `dpkg-divert` of `/usr/bin/apt*` and its helpers (not `dpkg --purge`,
which with `--force-depends` leaves the database inconsistent), and removal of `/etc/apt/sources.list*` and
`/var/lib/apt/lists`. The dpkg database is anchored to ROOT (`overlayfs-hook.sh`), so it travels with the image.
`unitotem-ota-changes` reports what was modified in the active slot and will be lost at the next update.

## Image delivery

Each release has a signed manifest:

```json
{ "schema": 1, "version": "2026.10.1", "arch": "arm64", "layout": 2,
  "min_updater": 1, "channel": "stable",
  "parts": [ {"label":"ROOT","fstype":"ext4","used_bytes":..,"url":"..","sha256":"..","stream_sha256":".."},
             {"label":"BOOTFILES","kind":"tar","url":"..","sha256":".."} ],
  "notes_url": "..", "signature": "<ed25519 over everything else>" }
```

- The **public key** is in the image (`/usr/share/unitotem/update-key.pub`); the signature is verified
  **before** anything is written. A hash without a signature protects against corruption, not against a compromised server.
- ROOT is a partclone+xz stream; DATA is **never** in the image.
- The download streams straight into the inactive slot (`curl | xz -d | partclone.restore`), with no staging
  on DATA. There is no mid-stream resume: if it drops, it starts over (the inactive slot is marked invalid
  at the start, so no reboot can land in it).
- Checks after writing: `fsck`, label, stream sha256, `/sbin/init` present.

While writing, **there is no rollback** (the rollback slot is the one being written). The operator is shown this.

## Contract for the manager (Updates page)

A single command on the device, `/usr/sbin/unitotem-update`, everything with `--json`. Long operations run in a
transient systemd unit (`systemd-run`), so they survive a manager restart. The manager **starts** and **queries**;
it does not stay attached.

| Subcommand | Does |
|---|---|
| `status` | active/inactive slot, version of each, `trial` (are we in a trial?), `pending_confirm`, `boot_count`, `last_result`, `rollback_available`, current `op` |
| `check [--manifest-url U]` | downloads and verifies the manifest; `available`, `version`, `size`, `needs_layout_migration`, `changes` |
| `fetch [--accept-changes DIGEST]` | verifies the signature, writes the inactive slot, verifies; does **not** change boot |
| `apply [--reboot]` | arms the trial (tryboot / grub-reboot) and reboots |
| `confirm` | promotes the trial slot to default (normally boot-ok does it by itself) |
| `rollback [--reboot]` | sets the previous slot as default again (if `rollback_available`) |
| `cancel` | interrupts `fetch` and marks the inactive slot invalid |

Further subcommands: `repair`, `policy`, `auto`, `reboot` (see "Automatic updates" below).

Exit codes: `0` ok · `10` nothing to do · `11` confirmation of changes required (`--accept-changes`) ·
`12` operation already running · `13` no rollback available · `2` failed · `127` missing (old image).
As with `unitotem-ota-changes`: every code has a meaning, none is a generic error.

**Progress**: `/run/unitotem-update.progress`, **one JSON line** rewritten atomically (tmp+rename):

```json
{"op":"fetch","phase":"write","percent":42,"bytes":1234567890,"total":2937000000,"eta_s":95,"state":"running"}
```

`phase ∈ check | download | verify | write | arm | reboot`; `state ∈ running | done | failed | cancelled`;
on error, `error` and `error_code`. A reboot clears `/run`: after the reboot the truth is in `status`
(`last_result`, persisted on DATA), not in the progress file.

**Confirmation**: `unitotem-boot-ok` waits for `unitotem-manager` to answer its healthcheck, otherwise a release with a
broken manager would be "confirmed" anyway and the automatic rollback would not fire. Three unconfirmed trials →
automatic return to the old slot (counter in `cmd_init_premount`).

## Release distribution and signing keys

**Distribution**
- One GitHub Release per version (`v2026.10.1`); `prerelease` = `beta` channel, the rest = `stable`. Assets:
  `manifest.json`, `manifest.json.sig`, the partition streams, `SHA256SUMS`.
- The device downloads from `https://github.com/<repo>/releases/latest/download/manifest.json` and the download
  URLs: **not** from `api.github.com`, which without a token allows 60 requests/hour per IP, and several kiosks behind
  the same NAT would exhaust it.
- GitHub Releases limit assets to 2 GiB. If a ROOT exceeded it, the manifest declares several `parts` for the same label
  and the device concatenates them.
- The repo is public, so every image is public: an image must not contain secrets (default test SSH password,
  certificates, tokens).

**Keys**

A single Ed25519 key would mean that losing it leaves every installed device unable to accept a signed update
(they trust only that key). So the design does not depend on a single secret:

1. Two public keys in the image (`/usr/share/unitotem/update-keys/`):
   - **release key**: used by CI, kept as a secret of the GitHub Environment. If lost or compromised, it is replaced.
   - **recovery root key**: offline, never touched by CI. It authorizes a new key list (a `keys.json` signed by
     the root, downloaded together with the manifest), so the release key can be **rotated** across the fleet without reflashing.
2. Losing only the release key is therefore recoverable. Losing the root **and** the release key is not,
   so the root must be backed up well.
3. Backups of the root (and of the release key): each copy encrypted with a passphrase (`age -p`), never in
   clear, never in clear in the repo. At least three places independent of the PC: password manager,
   offline stick/disk in another location, paper printout with the passphrase kept separately.
4. GitHub secrets are writable but **not readable**: they are a place of use, not a backup.
5. A restore should be tested at least once: from a copy, sign a test manifest and have the VM accept it.

## Automatic updates (device policy)

`unitotem-update-auto.timer` (every 10 minutes, 10 after boot) runs `unitotem-update --json auto` at lowest priority (Nice=19, idle I/O).
The policy lives in `<state>/auto.json` and is read/set with `unitotem-update --json policy [--set-mode MODE] [--time HH:MM]`
(the manager's settings page calls it); the state of the last run is in `status` (`auto.policy`, `auto.state`, `staged`).

| mode | what it does when it finds a newer release |
|---|---|
| `off` (default) | nothing |
| `download` | downloads into the inactive slot and stops |
| `stage` | downloads and arms the trial boot **without rebooting**: the new system starts at the next reboot |
| `reboot` | downloads, arms and reboots immediately |
| `scheduled` | downloads and arms; reboots only in the one-hour window starting at `time` (local time), at most once a day |

Rules: never while another operation or a boot trial is running, never in the first 10 minutes after boot, asks the server at most every 6 hours,
exponential backoff (1 h … 24 h) after a network or download error, never automatic if the release requires a layout migration.
An armed ("staged") update redoes the merge of accounts and /etc every 10 minutes, so changes made while waiting reach the new slot.

Difference between the two backends for `stage`/`scheduled`: **GRUB** (PC) starts the new system at the next reboot of any kind (next_entry is
one-shot). **Raspberry**: the firmware reads `tryboot.txt` only if the reboot is requested with the tryboot flag, so the armed update starts only with
`unitotem-update reboot` (used by the `reboot`/`scheduled` policy and by anyone who calls it, e.g. the manager's Reboot button); a normal reboot
or a power cut starts the old slot and the update stays armed (`staged`), without being mistaken for a failed trial.

## Verified behavior and limits

- Power-cut tests (QEMU `kill -9` at every critical point of fetch/apply/trial/confirm/rollback, during boot of the new slot and with a corrupted grubenv) pass on amd64/UEFI; the
  real Raspberry Pi 4 completes A->B update and manual rollback. After any interruption the operation is REPEATED (idempotent)
  instead of trusting a flag: `apply` redoes a read-only fsck and checks the slot label before arming.
- A slot being written carries the neutral label `ROOT_NEW` and takes its final label only when the write is verified;
  the slot is found by GPT partition name; state files on DATA are fsynced (file and directory); DATA keeps its ext4 journal and
  the initramfs runs `e2fsck -p` before mounting it.
- `--accept-changes` is accepted and ignored: the current slot is not destroyed by an update.
- A power cut inside a single block write, volatile disk caches and write reordering are outside what the tests simulate.
