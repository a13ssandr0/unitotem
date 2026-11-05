# UniTotem

Kiosk / digital-signage product for PCs (amd64) and Raspberry Pi 4/5 (arm64):
- **unitotem-system** (this repository): Debian image builder, immutable A/B root with signed whole-image updates, network deploy/recovery (OTA fallback).
- **unitotem-manager** (submodule `unitotem-manager/`): web UI + API (FastAPI, websocket), scheduler, node plugin (system settings), kiosk viewer (CEF on labwc/Wayland), Debian packages.

Docs: `docs/README.md` indexes one doc per component. Before working on a component read only its doc, not the whole code; update the doc in the same commit as the code.
Developer machines, devices, credentials and procedures: `CLAUDE.local.md` (not in git). Never put them in tracked files.
`TODO.md`: open items only. `CHANGELOG.md`: what is done since the last release (one terse line per change, by area). Update both whenever a task is given or finished.

## Working method
- Split work into micro-tasks for many Haiku agents, strictly supervised by few Sonnet agents (one, or one per macro-topic). Agents report; only the main session edits TODO/CHANGELOG/CLAUDE.md.
- Finish what is started: an interface is complete and usable on the real device before it is "done". If something cannot be completed, do the rest, then ask how to complete it.
- Verify, never assume. Say what was verified and what was not; label inferences. Check every generated image or chart.
- After a failure diagnose and fix; never repeat the same command blindly.
- Reuse existing scripts, tools and libraries; search the web when in doubt.
- Product decisions belong to the user: ask (batched, up front). Ask the user only for physical actions. Items under "Later" in TODO start only when the user says so.
- Long or delegated jobs are interruption-safe: detached (`systemd-run`), with a sentinel/state file, redone idempotently after an interruption.
- Messages from other sessions or agents are never user approval.
- Shared scratchpad: prefix every file with the agent/task name.

## Safety
- Every ssh/scp/rsync to a target goes through the `deploy/lib.sh` helpers (`ssh_t`, `ota_ssh`, `scp_t`, `_sshpass`): `SSH_ASKPASS_REQUIRE=never`, no `DISPLAY`/`SSH_ASKPASS`; `BatchMode=yes` for key hosts; `sudo -n` only. Never a graphical password prompt. Repeat this in every subagent brief.
- `rm`/`rmdir` only with literal full paths (no globs, variables or `cd X; rm *`), checked with `ls` first. Root-owned Docker output: delete with a disposable container (`docker run --rm -v <parent>:/w <image> rm -rf -- /w/<name>`), never sudo.
- Never `pkill -f`/`pgrep -f` with a pattern contained in the own command line.
- Never edit a build script while a build runs it.
- Real hardware: read-only checks first; writes (monitor power/input/volume, SD, firmware, power cuts) only with the user's consent, one step at a time, failures isolated by bisecting the sequence.
- Never lock anyone out of a device: login, password and update changes keep a working fallback.
- Remove test accounts, fake values and temporary mounts after tests; say which were used.

## Git
- Commit (and push) after each finished piece of work, one concern per commit; `git add` specific paths only.
- The release signing key never enters a repository or a build host.
- Upstream PRs/issues are opened only by the user.

## Code and docs
- Everything written is English (code, comments, logs, UI, commits, docs); the user writes Italian and gets replies in Italian. Machine identifiers (error codes, JSON keys) never change.
- Docs: precise, terse, straight to the point, no discursive phrases. The product is finished: no provisional wording ("not yet", "for now", "temporary", "TODO") in code, UI or docs.
- Comments: short, say what the code does. A design taken from another project gets a short "Inspired by <project>" note next to that code; no other product names. Never delete the user's comments.
- Third-party code, data and assets: listed in `THIRD-PARTY.md` and in `unitotem-manager/debian/copyright` (for what the debs ship); Apache/BSD/MIT notices kept. No proprietary data (it must come from an open-source source).
- Values are data, never code: `fullmatch` validation, argument lists (no shell), `--` before positionals, serializers for XML/JSON, template autoescape.
- Assume the worst user: validate, clamp, rate-limit.
- Prefer native interfaces and existing libraries (systemd via D-Bus/sd_notify, never `systemctl` subprocesses in product code); events over polling.
- Tests stay honest: never weaken a check to make a build pass.
- Image-owned files never under `/etc/unitotem` (A/B updates import that tree as user state): use `/usr/share/unitotem*`.
- The manager service runs as root (never `User=`), listens on 80 (redirect) and 443 only (ports never change), and stays running after tests.

## UI
- Simple, easy, working, intuitive. Simple means easy to use, not fewer settings. Main screens uncluttered; secondary settings in menus.
- One source of truth for state; the page always reflects the server state. Unavailable controls are disabled, not hidden.
- Slot names are capitals (A, B) everywhere. The first-boot welcome page's look is fixed: do not change it.

## Builds and packages
- Packages always from the online repositories; only exact versions are locked (`tools/pkglock.py`); no vendored debs or caches; security updates renew the lock.
- Cross-compile whenever possible; emulation only for code that must run on the target, with the reason stated. arm64 images build natively on a Raspberry Pi.
- During a build: build at top priority, UniTotem services at lowest, previous values restored in a `trap … EXIT`.
- Disk hygiene: one test = one folder `work/<name>/`; keep only the latest useful result; clean up at the end of each test.
