# Package lock

Paths: relative to the repository root.

Pins every archive package of the image to an exact version, installs them from a Debian snapshot, and checks the archives before each build. Tool: `tools/pkglock.py`.

## Files

- `tools/pkglock.py`: lock tool.
- `tools/release/test_pkglock.py`: offline tests.
- `unitotem/locks/amd64.lock`, `unitotem/locks/arm64.lock`: committed locks.
- `build-unitotem.sh`: update gate, `adopt_lock()`.
- `unitotem/stage1-packages.sh`: snapshot sources, preferences, `dist-upgrade`, verify-or-freeze.
- `Dockerfile.unitotem`: copies `pkglock.py` to `/unitotem/pkglock.py`.

## How it works

The repository stores only package versions and the apt snapshot date; the `.deb` files are downloaded at build time.

Lock format: `# key: value` header lines, then `name==version` (archive package, pinned) and `local name==version` (own packages, recorded, never pinned). Header keys: `arch`, `release`, `apt-snapshot` (`YYYY-MM-DDTHH:MM:SSZ`), `generated`, `packages`.

Per-arch build flow:

1. Gate (skipped with `PKGLOCK=off`), lock present: `pkglock.py check`.
   - exit 20 (security) and `PKGLOCK_KEEP` != 1: `pkglock.py upgrade <arch>` retires the lock to `<arch>.lock.prev`; build restarts at stage 1 (`FORCE_STAGE=1`) and freezes a new lock.
   - exit 2: warning, build continues with the locked versions.
   - exit 10: updates reported only.
2. Stage 1 with lock: apt sources become `snapshot.debian.org/archive/debian/<ts>/` (`trixie`, `trixie-updates`, `trixie-backports`) and `debian-security/<ts>/`, `Check-Valid-Until` false; `pkglock.py prefs` writes `/etc/apt/preferences.d/99-unitotem-lock` (`Pin-Priority: 1001`); `apt-get dist-upgrade --allow-downgrades`. The NVIDIA repository (amd64) is not snapshotted: it stays live, also with a lock.
3. Stage 1 end with lock: `pkglock.py verify` must pass; the lock pins and snapshot sources are removed; `sources.list` is rewritten to live `deb.debian.org` / `security.debian.org` (with `trixie-backports`). The Raspberry Pi archive stays live in `sources.list.d/raspi.list`. The NVIDIA source, keyring and `96-unitotem-nvidia` pin are removed in every build. `97-unitotem-backports` stays.
4. Stage 1 end without lock: `pkglock.py freeze` writes `work/<arch>/<arch>.lock.new`; `adopt_lock()` moves it to `unitotem/locks/<arch>.lock` only when that file does not exist.
5. `check` (read-only): `apt-get update` on live archives, `apt-cache policy` per pinned package, classify updates:
   - SECURITY when the origin contains `-security` or the changelog between locked and new version cites a CVE.
   - Urgency from the changelog `urgency=` (highest in range); `n/a` for the Raspberry Pi archive and NVIDIA's repository (no changelog).
   - Backports: a package locked at a `~bpo` build is compared with the newest `trixie-backports` version and reported as an update from `trixie-backports`. apt's own candidate is the stable version (priority 500 beats backports 100), so it would hide that update.
   - Newer backports of watched packages (kernel, mesa, firmware, pipewire, systemd, network-manager, ...) for packages locked at stable are listed, never used.
   - NVIDIA: the repository's versions are candidates only for packages locked at an NVIDIA version (`drop_nvidia_candidates()`). A Debian-locked package gets no NVIDIA candidate, and NVIDIA's `dkms` 3.4.4 is not an update of Debian's 3.2.2.
6. Devices ship without lock pins or snapshot sources, with the `97-unitotem-backports` pin file, and use live Debian archives (`trixie`, `-updates`, `-security`, `-backports`).

## Interfaces

`tools/pkglock.py`:

| Command | Arguments | Behaviour |
|---|---|---|
| `freeze` | `ROOTFS\|stageN.tar.gz --arch A [--release trixie] [--out FILE] [--snapshot ISO]` | Writes lock; default out `unitotem/locks/<arch>.lock` |
| `prefs` | `LOCK` | Apt preferences to stdout |
| `snapshot` | `LOCK` | Prints `YYYYMMDDTHHMMSSZ`; exit 1 if header missing |
| `verify` | `LOCK ROOTFS\|tarball` | Exit 1 with list (`missing`, `different`, `not locked`) |
| `snapcheck` | `LOCK` | 0 repeatable; 1 locked versions missing; 2 snapshot or live repository unreachable. The live repository is the Raspberry Pi archive (arm64) or NVIDIA's repository (amd64) |
| `check` | `LOCK [--json]` | 0 nothing newer; 10 updates, none security; 20 security; 2 `apt-get update` failed |
| `upgrade` | `ARCH` | Moves `<arch>.lock` to `<arch>.lock.prev`; exit 1 if none |

`check --json`: `lock`, `arch`, `locked_snapshot`, `packages_locked`, `updates[]` (`package`, `locked`, `new`, `security_pocket`, `origins[]`, `urgency`, `cves[]`, `security`), `security`, `backports_available[]`.

Environment: `PKGLOCK` (`on`/`off`), `PKGLOCK_KEEP` (`0`/`1`), `PKGLOCK_FROZEN_AT` (set by stage 1, used as `--snapshot`). Docker mount: `unitotem/locks` at `/unitotem/locks`, read-only.

Build errors:

- `the lock records no Debian snapshot`: `apt-snapshot` header missing or malformed.
- `the image does not match the package lock`: verify failed. If the package change is intended, `tools/pkglock.py upgrade <arch>` and rebuild; otherwise revert it.

## Rules and gotchas

- The lock is exact: any package not in the lock fails verify. Adding or removing a package in stage 1 requires `upgrade`.
- `libpam-pwquality` is installed with `--no-install-recommends`; its locked set is `libpam-pwquality`, `libpwquality1`, `libpwquality-common`, `libcrack2`. The first build after adding it needs one `upgrade` per arch.
- Local packages are recognised by version (`~devN`, `unitotem`, `+rptN-local`); recorded, never pinned. An archive package with such a version is treated as local.
- A security renewal discards the lock and reinstalls everything at current versions; commit the new lock.
- Build output never overwrites an existing lock.
- Live repositories (no snapshots): the Raspberry Pi archive (arm64) and NVIDIA's CUDA repository (amd64). A locked version that either one withdraws stops the build (apt cannot install it); `snapcheck` reports it; renew the lock with `upgrade`.
- The Raspberry Pi archive keeps no old versions (`snapcheck` says so). NVIDIA keeps older branches in its index: on 2026-11-08 it listed 590.x, 595.x, 610.x and 615.x next to 620.70.06 (`libnvidia-allocator1`). A locked NVIDIA version therefore stays installable while NVIDIA keeps that branch.
- Backports in the lock: a backports build has the `~bpo13` suffix in its version. The snapshot sources include `trixie-backports` (`http://snapshot.debian.org/archive/debian/<TS>/ trixie-backports`). A backports version has priority 1001 through its exact lock pin, which beats the 990 pin of `97-unitotem-backports`.
- Moving a backports package: `tools/pkglock.py upgrade <arch>` retires the lock; the next stage-1 build resolves fresh (the newest `trixie-backports` version the 990 pin selects) and freezes a new lock. `check` reports the newer backports version of a `~bpo` lock as an update (see step 5).
- Urgency alone never blocks.
- `PKGLOCK=off` builds use live archives and write no lock.
- `unitotem/locks/<arch>.lock.prev` is a local artefact; do not commit it.
- Native arm64 build: lock files travel with the tree; the freeze runs on the device and is fetched back with `work/arm64/` after success.

## Tests

- `python3 tools/release/test_pkglock.py`: freeze, verify, prefs, policy parsing, classification; offline.
- Not covered: `check` exit codes, `snapcheck`, `upgrade`, changelog fetch (network).
- Manual: `python3 tools/pkglock.py check unitotem/locks/<arch>.lock`; `snapcheck` on the same lock.
