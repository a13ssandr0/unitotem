# TODO (open items only; done items are in CHANGELOG.md)

## Waiting for the user (decisions)
- [manager] utils/async_timer.py is adapted from a CC BY-SA 3.0 answer (not one-way compatible with GPL-3): keep with attribution, or rewrite it.
- [system] Wi-Fi roaming: keep `unitotem-wifi-roam` if stable (flapping/dropped links); a strong AP sometimes times out in auth (router side).
- [manager/viewer] Long press on a real panel must show no context menu (needs a finger).
- [manager/touch] Guided touch setup on a real panel (Display -> "Touch doesn't match? Fix it"); needs a person.
- [system] H.264/AAC licensing: belongs to whoever distributes the image, a business decision.
- [system] Release signing: the 2.3.0 signing key was lost with a damaged disk. Before the first publication the user creates the new key and stores it safely (backup-keys.sh, 3 copies); confirm key model (release key + offline root) and custody. Intermediate development debs and images are never published.
- [system] Real GitHub release test (redirects, API limits, 2 GiB asset limit, publish workflow) and whether images may be public once checked for secrets.
- [system] Legacy pi-gen tree at the repo root (build.sh, stage0-2/, export-image/, Dockerfile...): remove or keep.
- [system] Windows-source installer: build (8-12 days MVP, docs/system/windows-install-research.md) or delete the research.
- [system] Secure Boot: always ship the shim chain? QEMU proof pending; real firmware "Security Violation" text unverified.
- [system] Pi 4K60 (hdmi_enable_4kp60) undecided; pin ~60 Raspberry packages and backports (kernel, Mesa, firmware) undecided.
- [manager] Upstream CEF/cefpython issues and PRs are not opened (patches and docs/manager/cef/pr-*.md ready); user decides.
- [manager] Lean CEF build (docs/manager/cef/lean-build.md section 6): decision open.
- [manager] Deleting a user keeps `/home/<name>` (deluser default; an account created again reuses it): remove the home when UniTotem deletes an account it created, or keep it? A later account with the same uid would inherit the files.
- [system] Test Pi has an account `ale` (uid 1001, nologin, entry in users.json, not created by these tests): keep or remove?

## To build
- [system+manager] Always-on password policy (PAM pam_pwquality: min 8, 2 classes, max 3 repeats, no dictionary; `passwd`, `sudo passwd`, `chpasswd`; switch removed) with a live checklist in the web UI and the first-admin script. Plan: ~/.claude/plans/la-creazione-dell-account-al-reflective-stonebraker.md.
- [system] OTA fallback without a fixed password: key sent by the deploy tool when armed from a running system; admin account + password and root keys read from DATA in automatic recovery; a never-configured device stays open like first access (everything must work remotely). Deploy tool: per-target key, `OTA_FALLBACK_USER`/`OTA_FALLBACK_KEY`/`OTA_FALLBACK_PASSWORD`.
- [system] Fallback idle watchdog stands down on any TCP connection, even unauthenticated; dead reverse tunnel code (`OTA_HOST`, `dbclient -R`); the ephemeral fallback host key cannot be pinned by the tool.
- [system] No UniTotem 3.0.0 device is deployed yet: account/identity changes need no migration of older devices.
- [system] unitotem-update-auto.service has Documentation=file:///usr/share/doc/unitotem/ab-updates.md, which the image does not install.
- [system] Regenerate the preboot SD image after the latest build.
- [system] Remove `/etc/chromium.d/50-unitotem-accel` (stage2-configure.sh:291; browser not installed) and the unshipped wifi-roam.conf mention or ship a default file.
- [system] Remove single-root code branches (AB_LAYOUT=0) in stage2/3, remote-deploy, verify-image, unitotem-boot-ok.
- [manager] docs/ apt repository stops at 2.3.0, README.md describes the old single-package install (no unitotem-node/-viewer, unitotem, python3-cefpython3, plymouth-theme-unitotem); docs/update-pkgs.sh uses `dpkg-buildpackage -A` and copies the core deb only.
- [manager] Pin versions in manager/requirements.txt (fastapi, jinja2, psutil... unpinned); frozen_requirements.txt is referenced by nothing.
- [manager] plymouth/generate-assets.py:11,32 font path `manager/webview/static/NotoSans.ttf` is stale (now plugins/unitotem_viewer/static/).
- [manager] Delete unreferenced tools/ticker/control/ticker-raf.js (older bar implementation); tools/unitotem-ab.xml is referenced by no procedure; tools/cef-server/probe-gn-args.sh:9 reads /tmp/args.base.gn, created by no script; 0007 CEF patch has a placeholder `From` line.
- [manager] CEF vendor: .gitmodules `branch = cefpython147-qt` is 19 commits behind the pinned commit (on `wayland-views`); wheels in vendor/cefpython-wheels are cp313 only while build-cef-wheels.sh builds 3.10-3.14 and debian/rules/python3-cefpython3 pin 3.13.
- [system] Local tools `work/pi-test/{reflash-clean,resume-ab,redeploy-ab}.sh` call `ota_ssh`: they need `OTA_FALLBACK_KEY`/`OTA_FALLBACK_USER` in the environment, and `reflash-clean.sh` runs `unitotem-ota-arm --port 2222 --wipe-data` without `--authkey-file`.


## To verify on hardware
- [system] After a fallback the boot partition keeps `unitotem-ota.authorized_keys` and `unitotem-ota.conf` (only the request file is removed): the armed public key stays valid for a later automatic fallback, so the same PC can recover the device remotely. Decide whether that is wanted, or whether the key expires after the next successful boot.
- [system] Fallback authentication verified on the test Pi (flag-file path) and on venus (amd64, GRUB, EFI partition): key from the boot partition, DATA slot read, root key and administrator password accepted, root password and empty password refused, DATA unmounted afterwards. Not run: open mode (never-configured device), the deploy tool's armed path with its per-target key and `discover_fallback`, automatic recovery with both slots broken, the `unitotem-ota.conf` / `unitotem-ota.authorized_keys` left on the boot partition.
- [system] The fallback takes a new DHCP address (the Pi got .174 while its system uses .173): the tool finds it with `discover_fallback`; `work/pi-test/fallback-test-v48.sh` and docs assume the system address. Check what the deploy tool prints for the address.
- [system] On venus a read during the end of a test showed `root:!*` in /etc/shadow and no `admin` once (not reproduced, five later reads normal): watch `close_first_access` / `userdel` ordering and the `!*` value (root `*` expected).
- [system] Defaults en_US.UTF-8 / UTC, `/etc/profile.d/unitotem-locale.sh`, `AcceptEnv LANG LC_*`, htop and btop: in the code and checked on fake trees and in a container, not yet in a built image (stage 2 locale-gen and tzdata, `btop` in a fresh SSH session, `ssh -t host btop`).
- [manager] Settings > Date and time never run against the real manager and timedated on a device (needs the build that ships it): zone change, NTP switch, a timer following the new zone, error shown by the snackbar, the page with the control waiting 5 s.
- [manager/screens] VNC on venus (Intel Iris Xe, DP-2, image 2026.11.47): `wayvnc` delivers a uniform grey (96,96,96) frame while the viewer shows the black no-assets page (DevTools lists iframe `/unitotem-no-assets`); cause unknown (capture of the CEF surface?). Check on another PC and on a Pi with a display.
- [manager/testing] `tools/ui-terminal.py` title and minimise checks fail on venus for an administrator with a real `.bashrc`; probable cause (not re-run): its PS1 rewrites the terminal title the probe sets.
- [system] `systemd-sulogin-shell` (emergency/rescue) with root's empty or `*` password: emergency-dropin.conf says no shell for `*`, unverified (needs a rescue boot).
- [manager/webui] Settings -> Updates with the previous version in the other slot: checked only through `unitotem-update --json status` (UI needs a login); error reply shape of `Settings/Update/*` (updates.vue:324-330) assumed.
- [system] Auto-update policy modes (download/stage/reboot/scheduled) never exercised live on devices.
- [system] Deploy backup of an earlier single-root UniTotem (1.x/2.x) tested on a fake root only; a full deploy with backup on a real disk never run.
- [system] Wi-Fi: `unitotem-wifi-roam` never seen completing a roam on a real two-AP site; AP off/on test of autoconnect-retries=0 not run.
- [system] Identity merge at OTA (`migrate-etc-overlay`): accounts, root password and browser profile across a real A/B cycle.
- [system] Mixed versions (old viewer + new manager and reverse) and rollback with a turned screen: reasoned, never run; GRUB fallback/recover on real amd64 end to end.
- [system] Session bus for root, `unitotem-boot-orientation` on boards, new `rc.xml` (Alt+F4) on boards.
- [manager/screens] GPIO display power on a real line and against python3-libgpiod 2.x on a board.
- [manager/screens] CEC: TV on another input switched back by active source; what the TV remote's keys do in the viewer (they arrive as keyboard keys); adapter choice in the web UI never clicked. Serial power (no port), Wake-on-LAN of a monitor, DDC writes on monitors other than LG and Realtek board.
- [manager/remote] Two real nodes: client viewer pixels, approval click path, 4443 behind a firewall, multi-GB transfers, adoption/unpair with window settings and layouts, file push to a client.
- [manager] Camera and microphone capture never seen (boards have neither).
- [manager/webui] Network page (Wi-Fi grouped by SSID, AP lock, strongest AP), Scheduler/Audio/Viewers controls never clicked in a browser; routes `DELETE /backup` and `POST /pdf-view/failed` unchecked.
- [manager/viewer] PDF "canvas blank -> redraw smaller + notification" path never forced on a board; playlist drag handle (scheduler.vue:30-36) shows only on row hover, touch needs a first tap.
- [manager/touch] Automatic touch mapping on two monitors; touch panel vanishing 4 s after boot on a board unexplained.
- [manager] Real playback checks left in the test-procedure doc section 7; per-asset volume/audio output not checked on a remote viewer.
- [manager/updates] Forced copy, cancel, armed trial, staged reboot on the Updates page against a real updater.
- [manager/cef] Unverified: `wayland-views-pr` branch against pr-cefpython.md; vendor wheels vs pinned commit; whether the `.ready` cache check in cef-wheels-inner.sh survives a patch change that keeps libcef.so timestamps.
- [manager] Test-procedure doc: section 4 uses `cpumeas.py`/`cdp.py` not in the repository; section 9 rsync path (/var/opt/rsync/) differs from the `VM_RSYNC_PATH` default; procedure not re-run in review.
- [manager/viewer] ticker.py:160 `set_settings` calls `push.tell_window` with no `_supports_layout` check (controller.py:428): effect on a viewer without layout support unverified.

## Defects found in review
- [manager] utils/models/assets.py:80,88 `__enable`/`__disable` call `self.enable()`/`self.disable()`, defined nowhere: scheduled enable/disable dates never take effect.
- [manager] debian/control:89 depends on python3-pampy but osusers.py imports `pam` (python-pam); also in unitotem/locks/*.lock.
- [manager] main.py:353-361 bind failure leaves exit status 0, systemd does not restart; main.py:208 argparse never parsed (`--version` dead).
- [manager] api/scheduler.py:53,59 media probe with `verify=False`; :246 `edit_asset` probes on the event loop (up to ~10 s).
- [manager] utils/storage/uploadmanager.py:123 FileNotFoundError retry re-reads a half-consumed stream.
- [manager] utils/ticker/service.py:144,148-151 source deleted/replaced during an in-flight fetch: `record_success`/`record_failure` raise KeyError, `_failed` raises again and escapes run(); ticker scheduler dies until restart. Skip ids no longer in the store.
- [manager] utils/remote/link.py:113 and discovery.py:119 listener/announcer failure not retried until apply_role; service.py:503 ImportError escapes after cache sent.
- [manager] plugins/unitotem_node/api/network.py:136,170 ip method/address/gateway/dns not validated; networkmanager.py:300 invalid DNS silently dropped.
- [manager] plugins/unitotem_node/api/timers.py:67 delete_job does not check uuid; :91 edit_job cannot clear output/wake.
- [manager] plugins/unitotem_node/__init__.py:122 logs "started fallback hotspot" when start_hotspot() returned nothing.
- [manager] plugins/unitotem_viewer/__init__.py:37 + app.py:154 missing cefpython3 raises ImportError out of run_gui instead of the fallback.
- [manager] plugins/unitotem_viewer/cdp.py:287 and :365 `_window_of` defined twice; the second wins, the first is dead.
- [manager] webui network.vue:733 editor never closes / pendingAddr never runs, :632 wifiConnecting spinner stuck on error; updates.vue:314 spinner stuck; base.vue:291 swallows errors so `data.error` branches (network.vue:576,601, remote.vue:311) are dead.
- [manager] webui scheduler.vue:557 upload errors only logged, :535 Reload button only animates; users.vue:36 deletes account without confirmation, :164 hard-coded permission list (keep in step with `UserPerms`); display.vue:9 label promises a missing click action, orientation/flip always send `window_id: 0`.
- [manager] webui polish: native `confirm()` (scheduler.vue:528,603, timers.vue:277); viewers.vue:340-349 `pending` set and cleared in one tick, `assignments`/`connected` never read; base.vue:103,115 Vuetify 2 colour names (`red darken-1`); info.vue:59-60 temperatures above 300 greyed, purpose unclear.
- [manager] Crowded UI: viewers.vue matrix (move keyboard, screensaver, refresh, language to a per-window dialog), Add URL dialog (~12 fields, needs Advanced), settings/display.vue (7 blocks).
- [manager] Backup gaps: screen_control.json and touch orientation/calibration not in any backup part; netplan part still exported though never written.
- [system] build-unitotem.sh: no nice/CPUWeight save-restore with EXIT trap (docs/system/build.md); own ssh helpers instead of deploy/lib.sh (no BatchMode, host key check off).
- [system] build-unitotem.sh: MAKE_PARTS/EFI_SIZE/ROOT_SIZE not forwarded.
- [system] build-unitotem.sh:166 lock gate handles exit 20 and 2 only, any other failure continues with locked versions; rsync failure silenced with `|| true`.
- [system] deploy/ota-engine.sh promote-default rpi branch (~724) writes config.txt/cmdline.txt without os_prefix/slot: breaks A/B if run; :846 DATA/history never pruned.
- [system] /root handling differs: unitotem-update:418 copies root.<old>, ota-engine migrate-etc-overlay leaves it.
- [system] deploy/remote-deploy.sh: `--debug` unread, `--host` not passed (OTA_HOST dead), cmd_serve has no tunnel, changes check failure (2/127) exits 1 like "changes found", recover strips :PORT.
- [system] unitotem-update:378 Lock unlinks before close; :782 health_ok disables TLS verification; unitotem-maintenance ignores update-grub failure and reboots anyway.
- [system] overlayfs-hook.sh: DATA not found warns and continues with no overlays and no failure status.
- [system] tools/pkglock.py: LOCAL_RE treats any `~devN` archive version as local; `.lock.prev` left untracked; tests missing for check/snapcheck/upgrade.
- [system] tools/release/unitotem-release: `build` has no caller/test, build-ab has no split for roots over 2 GiB, no publish script or workflow.
- [system] Stale files: flash-*/flash.manifest, `.gitignore:3` deploy/flasher/, tools/assets/ unreferenced, docker-compose.yml unreferenced.
- [system] Product text names developer items: stage1-packages.sh:143 "the Pi 4 test unit", manager rtc.py:151 "the test VM", gpu.py:213 and screens/identity.py/mechanism.py name test machines.
- [manager] tools/ui-touch-setup.py raw sshpass/ssh (violates helper-only SSH rule); tools/vm-deploy has no lock; tools/gen-api-types.py monkeypatches `pathlib.Path.mkdir` and `shutil.disk_usage` globally (fragile); tools/ui-vnc.py docstring cites a runner script not in the repository, its token checks not re-run since the X11 era.
- [manager] tools/cef-server build-all.sh/cef-rebuild.sh skip apply-patches.sh.
- [manager] Test warnings: `Asset.__del__` (assets.py:181) reads `self.uuid` on a partly built object (7 PytestUnraisableExceptionWarning in test_asset_zoom.py); user.py:89 pydantic serializer warning (permissions as list); never-awaited `Timer._job` coroutine (test_playlists.py copy/move test, touch_calibration.py:103).
- [manager] No unit tests for terminal.py, ws_token.py, devtools.py, /vnc path, node backup parts, audio.py, Wi-Fi scan, hotspot start, scheduled enable/disable firing.
- [manager] Legacy users.json (werkzeug hashes) cannot migrate: first access asked again after upgrade, rollback cannot log in.

## To build (Viewers and Display pages)
- [manager/webui] Viewers: compact playlist x window matrix (checkboxes only) plus a per-window detail panel with sections (Audio, Interaction: keyboard, interactive screen, page language; Maintenance: refresh, developer tools; Layout and panes); RSS sources in their own section. Drop dead state (viewers.vue:340-349).
- [manager/webui] Display redesigned after KDE's display settings: screen selector (real `window_id`), per screen: identify, resolution, refresh rate, orientation/flip, power and inputs (ScreenControl), touch (TouchMapping). Certificates move to Security, GPU status to Info. No scale control.
- [manager/screens] Backend: `Settings/Display/outputs` (modes as width, height, refresh_mhz), `set_mode` with 15 s revert and `confirm_mode`, `reset_output`, viewer `identify`; mode persisted in `viewer_settings.json` and replayed by `output_transform.py`. Works on labwc 0.20 (arm64) and 0.8.3 (amd64).
- [manager/viewer] Screen id under the IP on the no-assets and welcome pages, only when more than one screen is connected (welcome page look otherwise unchanged).
- [manager/webui] Settings > Users: new "show user list on login page" switch and the login error display never run in a browser.

## Best effort, at the very end (only after everything else is finished)
- [manager/screens] Colour: ICC profile and colour precision/HDR per screen. Findings: labwc 0.20 (arm64) has the colour-management protocol, no ICC config key found, Pi 4 renderer support untested, vc4 `max bpc` 8 and not settable through the compositor; labwc 0.8.3 (amd64) has no colour protocol. Start with a read-only line (max bpc, colour space) and a Pi test on labwc 0.20.

## Later (only when the user says)
- [system] Installer ISO as an automatic A/B installer: the live image writes the A/B image with the deploy engine, the person only selects the disk when there is more than one; first-access state, all other settings after installation, no password prompt. (The old single-root bookworm/X11 ISO is removed.)
- [system/viewer] Boot gap of ~7 s between Plymouth and the first boot-splash frame with kernel text on screen. Try by hand on a Pi: tty1 KD_GRAPHICS at labwc start, `plymouth quit --retain-splash` instead of `pkill plymouthd` + `cat /dev/zero > /dev/fb0`, paint splash background at once. Kernel logs stay.
- [manager] Backlog: custom scripts, custom image background, offline service worker, tidy up the web UI, separate modal for screen splitting.
