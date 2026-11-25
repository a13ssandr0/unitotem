# Release tooling and signing keys

Paths: relative to the repository root.

Host-side tooling that creates and signs releases (A/B slot streams, manifest, key list) and backs up the signing keys. The device consumer is `unitotem/files/unitotem-update` (`ab-updates.md`).

## Versioning

One product version for the image and every `unitotem` package. The image is monthly; the version is date based.

Grammar (`fullmatch`): `[0-9]{4}\.[0-9]{2}(\.[0-9]+)?(~[a-z]+[0-9]+)?`

| Version | Meaning |
|---|---|
| `2026.12` | Monthly release |
| `2026.12.1` | Same-month fix |
| `2026.12~dev1`, `2026.12~rc1` | Pre-release of `2026.12`; sorts before it |

Ordering (dpkg `verrevcmp`; `~` sorts before everything, including the end of the string):

`2026.12~dev1` < `2026.12~rc1` < `2026.12` < `2026.12.1` < `2026.12.2` < `2026.12.10` < `2027.01`

`2026.11.66` < `2026.12`

Source of truth: the top entry of `unitotem-manager/debian/changelog` (source version of all `unitotem` packages; the metapackage `unitotem` carries it). `tools/set-release-version.sh` in the manager repository sets it.

Image build:

- `RELEASE_VERSION` unset: taken from the installed `unitotem` package.
- `RELEASE_VERSION` set and different from that package version: the build fails.
- Stage 1 requires every `unitotem` package to share that version. `python3-cefpython3` is excluded: it has its own third-party version.

Image files under `/usr/share/unitotem/`:

- `release-version`: the plain version, one line.
- `unitotem-release` (os-release format): `NAME="UniTotem"`, `ID=unitotem`, `ID_LIKE=debian`, `VERSION_ID`, `VERSION`, `PRETTY_NAME="UniTotem <version>"`, `BUILD_ID` (UTC build time, ISO 8601), `UNITOTEM_BASE` (`PRETTY_NAME` of the Debian `/etc/os-release`), `UNITOTEM_ARCH` (`amd64` or `arm64`).
- Debian's `/etc/os-release` is unchanged.
- `verify-image.sh` checks the grammar, that `unitotem-release` parses, that `VERSION_ID` = `release-version` = the `unitotem` package version, `PRETTY_NAME` and `UNITOTEM_ARCH`.
- Image file names use the build date (`IMG_DATE`), not the version.

Git tag: `v` + version, with `~` replaced by `-` (`v2026.12-rc1`), because `~` is not valid in a git ref name. The manifest and the image files keep the dpkg form. The conversion in both directions lives in `tools/release/version.py`.

Who reads the version:

- `unitotem-update`: `release-version` (installed version); manifest `version` compared in dpkg order; a version not newer is refused (`not-newer`).
- GRUB menu title: `grub-version`, written by stage 3.
- Deploy scripts: `release-version`.
- Manager (runtime): `unitotem-release` for the UI footer, kiosk viewer, web UI, `--version` and `/health`.
- GitHub `releases/latest` resolves to the newest non-prerelease release; the device uses it.

Retired: the `3.0.0~devNN` numbering, the `2.x` numbering, the `YYYY.MM.DD` default of `RELEASE_VERSION`, and the old apt repository line (`unitotem-manager.list`). Builds named `2026.11.NN` use the pre-contract daily numbering; they sort below `2026.12`.

- Devices running an updater from before this scheme (images up to 2026.11.x) cannot fetch a version with `~`: their `vkey()` compares an integer with a string and fails with `TypeError` before `--force` is read (observed on the test Pi 4, 2026-11-25). A normal release (`2026.12`, `2026.12.1`) compares fine. A pre-release reaches such a device only with the current `unitotem-update` run from `/run` (`fetch --foreground` with `UNITOTEM_UPDATE_BASE_URL`); after one update to a new image the device has it natively.

## Files

| Path | Role |
|---|---|
| `tools/release/unitotem-release` | CLI: `keygen`, `sign-keys`, `build-ab` (layout 2), `build` (layout 1) |
| `tools/release/version.py` | Version grammar, dpkg ordering, version to git tag and back ([Versioning](#versioning)) |
| `tools/release/backup-keys.sh` | Encrypted backup, verify, restore of the signing keys |
| `tools/release/fake-github.py` | Offline stand-in for GitHub Releases URLs (tests) |
| `tools/release/test_rpi_backend.py` | End-to-end: `build-ab` on a synthetic arm64 image served by fake-github |
| `tools/release/test_release_build.py` | `build` and `build-ab` on synthetic images, throwaway keys, manifest/signature/hash/restore checks |
| `unitotem/files/update-root.pub` | Root public key; installed as `/usr/share/unitotem/update-keys/root.pub` |

## How it works

Keys:

- `root`: offline; signs `keys.json`; public key ships in the image.
- `release`: signs `manifest.json`; public key listed in `keys.json`.
- `keygen`: Ed25519 (`openssl genpkey`), umask 077, refuses to overwrite. Key id = first 16 hex of sha256(DER public key).
- `sign-keys`: writes `keys.json` (`seq` set by the operator) and the detached root signature `.sig`.

`build-ab` (A/B image):

1. `sfdisk -d` reads the partition table (GPT or DOS); ROOT_A is the partition whose filesystem label is `ROOT_A`.
2. `dd` extracts ROOT_A to a raw file in a temp dir inside `--out`.
3. `debugfs` reads `/usr/share/unitotem/release-version`; must equal `--version` ([Versioning](#versioning)).
4. `e2fsck -fp` (exit > 1 aborts). A filesystem smaller than the slot (the image's shrunk ROOT_A) is grown in the temp copy to `--slot-bytes` (default 5 GiB, a multiple of 1 MiB): `truncate`, `resize2fs`, clean `e2fsck -fn`. A filesystem larger than the slot is refused.
5. `tune2fs -L ROOT_NEW -U <new uuid>`.
6. `partclone.extfs -c | xz -T0 -6` -> `root.ext4.pc.xz` (role `root`): a full-size slot filesystem, so `unitotem-update` needs no grow step.
7. `--arch arm64`: FAT partition 1 `::slota` copied with `mcopy`, tarred (owner 0) and xz'd to `bootfiles.tar.xz` (role `bootfiles`).
7. `manifest.json` written, signed with the release key to `manifest.json.sig`.
8. `keys.json`, `keys.json.sig` copied in. Non-stable channel: empty `PRERELEASE` file.

Output `<out>/<tag>/`; it is published as GitHub release tag `<tag>` (`v` + version, `~` as `-`: [Versioning](#versioning)).

`build` (layout 1, from a directory of parts files):

- Every file of `--parts DIR` is copied as a part, sorted by name, except `SHA256SUMS`. Parts-set files such as `parts.manifest` are shipped too.
- Part entries are `{file, size, sha256}` (no `role`). `--arch` is read from `UNITOTEM_ARCH` in `parts.manifest`.
- Signed and laid out like `build-ab`; `--layout` defaults to 1.

Device side (`fetch_trusted`):

- URL: `UPDATE_BASE_URL` + `/releases/latest/download/` (GitHub resolves "latest" to the newest non-prerelease).
- `keys.json` + `.sig` verified with `root.pub`; refused if `seq` < stored `keys-seq.json`; new seq stored after success.
- `manifest.json` + `.sig` verified against any key in `keys.json`.
- Refused if `min_updater` > updater version or the device channel is not `stable`.
- `needs_layout_migration` = manifest `layout` differs from the current slot layout.

## Interfaces

`tools/release/unitotem-release`:

| Command | Options | Writes |
|---|---|---|
| `keygen` | `--dir D --name N` | `D/N.key` (0600), `D/N.pub`; prints id |
| `sign-keys` | `--root-key K --pub P` (repeatable) `--seq N --out F` | `F`, `F.sig` |
| `build-ab` | `--image IMG --version V --release-key K --keys-json F --out DIR [--channel stable\|beta] [--arch amd64\|arm64] [--slot-bytes N]` | `DIR/<tag>/` |
| `build` | `--parts DIR --version V --release-key K --keys-json F --out DIR [--channel] [--layout 1]` | `DIR/<tag>/` (layout 1, from a parts set) |

`--version` must fullmatch the grammar in [Versioning](#versioning); any other value is refused.

Exit 0 success; 1 on error or failed subprocess. Host tools: `openssl`, `sfdisk`, `dd`, `debugfs`, `e2fsck`, `resize2fs`, `tune2fs`, `partclone.extfs`, `xz`, `tar`, `mcopy` (arm64).

Release directory `<tag>/`: `manifest.json`, `manifest.json.sig` (detached Ed25519 over raw bytes), `root.ext4.pc.xz`, `bootfiles.tar.xz` (arm64), `keys.json`, `keys.json.sig`, `PRERELEASE` (beta).

`manifest.json`: `schema` (1), `version` (dpkg form, [Versioning](#versioning)), `channel`, `arch`, `layout` (2 for `build-ab`, 1 for `build`), `min_updater` (1), `built` (UTC ISO 8601), `parts[]` of `{file, role: root|bootfiles, size, sha256}` (`build` omits `role`).

`keys.json`: `schema` (1), `seq`, `keys[]` of `{id, pub}` (`pub` = PEM text; only `pub` is read by the device).

`backup-keys.sh` (env `UNITOTEM_KEYDIR`, default `$HOME/.config/unitotem-release`):

- `backup OUT.enc`: tar of `root.key root.pub release.key release.pub keys.json keys.json.sig`, `openssl enc` AES-256-CBC, PBKDF2, 600000 iterations, typed passphrase; refuses an existing OUT.
- `verify IN.enc`: decrypts to a temp dir; sign/verify probe with both keys; private/public match; compares `root.pub` with `unitotem/files/update-root.pub` (warning only).
- `restore IN.enc DIR`: refuses an existing DIR; creates it mode 700.

`fake-github.py --root DIR [--bind ADDR] [--port 8080]` (plain HTTP): `/<owner>/<repo>/releases/latest/download/<asset>` (302 to newest non-PRERELEASE tag), `/<owner>/<repo>/releases/download/<tag>/<asset>` (302 to `/objects/`), `/objects/<tag>/<asset>` (Range supported).

## Rules and gotchas

- `bootfiles.tar.xz` holds only `slota/` (arm64). The resident fallback set does not travel in the bootfiles part: it is `usr/share/unitotem/recovery/` in the root, and the device writes it to the boot partition after a confirmed boot (`ab-updates.md#recovery-set-refresh`).
- `seq` must increase on every key list; devices refuse a lower value even if the keys are unchanged.
- Key rotation takes effect only through a non-prerelease release: devices read `keys.json` from "latest".
- Only `stable` is installable; `beta` has no device consumer.
- `build-ab` needs an A/B image (partition 2 = `ROOT_A`) whose `release-version` equals `--version`. Build the image from the same `unitotem` package version.
- The raw ROOT_A copy (full partition size) is written inside `--out`: ensure free space.
- `ROOT_NEW` is deliberate: a half-written copy must never match `root=LABEL=ROOT_A` or GRUB `search --label`. The device renames it after a verified write.
- Sign on the operator workstation; the root key stays offline. The release key never lives on a build host.
- Devices make no GitHub API calls (unauthenticated limit 60 requests per hour); `releases/latest/download/` URLs redirect with 302 to another host.
- Release images must not contain secrets (passwords, certificates, tokens).
- GitHub asset limit is 2 GiB. `build-ab` writes one `role=root` part and does not split. The device reads only the first one: `unitotem-update` `do_fetch` picks it (line 687), streams that asset (717) and checks one sha256 (739). Multi-part roots are not implemented. Needed: every `role=root` part in order (an order field, or list order), one sha256 each, all streamed into one `xz -dc` in order, and `min_updater: 2` so older updaters refuse with `updater-too-old` (`fetch_trusted`, line 177) instead of failing mid-write. That changes the manifest format: a product decision.
- `build` (layout 1) skips a file named `SHA256SUMS`; nothing produces it.
- Keep three independent encrypted backups; the passphrase is never stored. Run `verify` after each backup.
- Losing the root key is unrecoverable: devices trust only the root chain. Keep its backups in three places independent of the workstation, with the passphrase stored apart. CI secrets are write-only, so they are not a backup.

## Tests

- `python3 tools/release/test_rpi_backend.py`: keygen, sign-keys, `build-ab` (arm64) on a synthetic image, then the Raspberry backend of `unitotem-update` against fake-github. Needs mtools and e2fsprogs; no root. Does not prove firmware `os_prefix`/`tryboot.txt` behaviour.
- `python3 tools/release/test_release_build.py`: keygen (refuses overwrite, 0600), sign-keys, `build-ab` amd64/arm64/beta and refusals (version mismatch, partition not ROOT_A), `build` layout 1. Checks manifest fields, sizes and sha256, signatures (release key verifies, root key does not, tampered manifest fails), and that the root part restores with its release-version, label `ROOT_NEW` and a fresh UUID. Throwaway keys in a temp dir; no root.
- `tools/release/backup-keys.sh verify IN.enc`: restore check.
- Not covered: multi-part roots (not implemented), upload, the layout 1 device side (no updater consumer).

Partclone findings (tests and tools): without root, `partclone.restore` and `partclone.extfs` need `-L /dev/null` (default log is `/var/log/partclone.log`). A regular-file target needs `partclone.restore -O FILE` (`-o` refuses an existing file).
