# Tests and test tools

Unit tests (pytest, no hardware) and the browser and API tools that check a running node. The VM and board lab is in [testing-vm.md](testing-vm.md).

Paths: relative to `unitotem-manager/`

## Files

| Path | Role |
|---|---|
| `manager/tests/conftest.py` | Strips `sys.argv`, creates the event loop, redirects notifications to `tmp_path` (autouse); helpers `read_text`, `read_bytes`, fixture `fixtures` |
| `manager/tests/fixtures/` | Static inputs: `ddcutil_detect_brief_{220,225}.txt`, `ddcutil_capabilities_lg_{220,225}.txt`, `ddcutil_220_stdout_noise.txt` (2.2.0 stdout noise, verbatim), EDIDs `edid_dp1_xrandr.bin`, `edid_host_dp.bin`, `edid_host_hdmi.bin` |
| `manager/tests/test_*.py` | 56 modules; areas under Tests |
| `manager/tests/password_vectors.json` | Shared password spec: 128 PAM-observed vectors (`policy`, `vectors[{password, username, ok, failed, pam}]`), read by pytest and by `npm test`. Not edited by hand |
| `pyproject.toml` | `[tool.pytest.ini_options]`: `pythonpath = ["manager", "manager/plugins"]`, `testpaths = ["manager/tests"]` |
| `manager/requirements-dev.txt` | `pytest` (dev only) |
| `tools/ui-smoke.py` | Every page in headless Chrome: console errors, exceptions, visible text; `--compare` diffs two runs; holds the `Cdp` helper the other UI tools import |
| `tools/ui-layout.py` | Floating button position at several widths; WoL and serial fields shown only for matching mechanisms |
| `tools/ui-panes.py` | `boot-screen.html` logic (panes, zoom, refresh, screensaver); local, no node |
| `tools/ui-notifications.py` | Notification centre: badge, menu, dismiss, clear all, live push, admin-only items |
| `tools/ui-playlists.py` | Scheduler: create, add, copy, rename playlists; removes what it created |
| `tools/ui-reorder.py` | Scheduler drag and drop with a real mouse (CDP drag interception) |
| `tools/ui-preview.py` | Asset preview is a floating window; two at once; close |
| `tools/ui-stale-chunk.py` | A tab left open across an update recovers from a 404 on a page chunk |
| `tools/ui-terminal.py` | Web terminal: open, run, close; refusals (no session, no admin, bad or used token, foreign origin) |
| `tools/ui-ticker.py` | `webui/src/ticker.js` against `tools/ticker/testpage.html`; local, no node |
| `tools/ui-touch-setup.py` | Touch-fix dialog on the Display page with a virtual touch panel; uses SSH |
| `tools/ui-vnc.py` | Screen in browser: RFB stream, view-only vs control, teardown, admin only |
| `tools/ui-devtools.py` | Window developer-tools button opens a connected front end |
| `tools/devtools-access.py` | Developer tools: admin only, tokens single-use, origin- and page-bound; creates and removes its own account |
| `tools/terminal-login-keepalive.py` | Terminal stays open after login times out or fails |
| `tools/ws-probe.py` | CLI for `/ws`: send commands, watch pushed frames |
| `tools/gen-api-types.py` | Writes `webui/src/api.d.ts` from the API registry (`manager/api/ws/endpoints.py`) |
| `tools/gfx-bench/` | On-target graphics benchmarks; see [testing-vm.md](testing-vm.md) |
| `tools/ticker/testpage.html` and the API client module in `tools/ticker/` | Fixture page for `ui-ticker.py`; API client imported by `ui-reorder.py` |
| `tools/ticker/deploy-board.sh HOST [PASSWORD]` | Puts this checkout's manager code on an image board without building a deb: changed directories are copied under `/var/lib/unitotem/ticker-test` and bind-mounted over `/usr/share/unitotem-manager`; `feedparser` from a volatile drop-in; nothing survives a reboot; build the web UI first (`cd webui && npx vite build`) |
| `tools/ticker/board-run.py` | Drives the real ticker through the WebSocket API and takes real page pixels (`--host`, `--feeds`, `--out`, `--only`; item `trace` runs `board-trace.py`); needs `board-cdp.py` and `board-cpu.py` copied to `/var/lib/unitotem/ticker-test` on the board (`deploy-board.sh` does not) and `feedserver.py` running |
| `tools/ticker/board-cpu.py SECONDS LABEL`, `board-trace.py SECONDS LABEL [block] [WINDOW]`, `knobs.py HOST FEEDS_URL 'label={json}'` | CPU of the manager process tree as percent of one core; frames drawn, gaps and main-thread work; CPU per bar setting |

## How it works
- Unit tests: pytest puts `manager/` and `manager/plugins/` on `sys.path`; `conftest.py` runs first. No node, network or root needed (about 20 s).
- Isolation: an autouse fixture points `notifications.path` at `tmp_path` and resets state per test.
- UI tools: each starts `google-chrome --headless=new --remote-debugging-port=<port> --ignore-certificate-errors --user-data-dir=<tempdir>`, polls `http://127.0.0.1:<port>/json/list`, drives the page over CDP (`websockets`).
- Login: `POST /auth/token` (form `username`, `password`) returns 200 or 303 and a cookie; the cookie authenticates the `/ws` handshake.
- UI tools load `ui-smoke.py` with importlib; keep its import free of side effects.
- Terminal and VNC checks need a one-time token (`POST /terminal/token`, `POST /vnc/token`; 30 s, bound to account and session). The first text frame of `/terminal` and `/vnc` is `{"token": ...}`; nothing starts before it is valid.
- Push checks: `ws-probe.py --watch <target>`, cause the change, expect a frame within about 1 s.
- Dev run (no board): use `.venv` (Python 3.14) and run `manager/init.py`, never `main.py` (init creates the asyncio loop before importing main). Headless: `init.py --no_gui=true --port 8080 --port_secure 8443` with `--assets_file`, `--users_file`, `--remote_file`, `--envfile`, `--certfile`, `--keyfile` pointing into a scratch directory.
- CDP check of a kiosk page without a browser: use the viewer's DevTools endpoint on loopback port 9223 (open a target with `/json/new?url`, then `Runtime.evaluate` over its WebSocket). A tab left open across a deploy needs a reload before concluding anything is broken.
- Decoder: confirm which video decoder ran only with the CDP Media domain (`kVideoDecoderName`, `kIsPlatformVideoDecoder`, `tools/gfx-bench/vdec.py`); never infer it from CPU cost. The `videoDecoding` array and the `video_decode` feature stat do not prove offload.
- CPU measurement: `/proc/<pid>/stat` utime+stime deltas over a wall-clock window, summed over the process tree (CEF runs in subprocesses). `ps pcpu` is a lifetime average; do not use it.

## Interfaces
- pytest: `.venv/bin/python -m pytest` (all), `-k <name>`, or a file path.
- Common UI flags: `--host` (required in most), `--user` (default `admin`), `--password` (default `admin`).

| Tool | Extra flags |
|---|---|
| `ui-smoke.py` | `--out FILE`, `--compare FILE`, `--wait SEC` (4) |
| `ui-notifications.py` | `--push CMD` (command run on the node to raise a notification) |
| `ui-preview.py` | `--file NAME` (required, uploaded image) |
| `ui-devtools.py` | `--out-dir DIR` (`/tmp/devtools-shots`), `--wait SEC` (25) |
| `ui-touch-setup.py` | `--out-dir DIR` (`/tmp/touch-ui`) |
| `ui-ticker.py` | `--shots DIR` |
| `terminal-login-keepalive.py` | `--skip-timeout` |
| `ws-probe.py` | `--send TARGET` (repeatable), `--args JSON`, `--watch TARGET` (repeatable), `--timeout SEC` (10), `--count N` (0 = no limit) |
| `ui-layout`, `ui-panes`, `gen-api-types` | none |

- Chrome DevTools ports (fixed; run one tool at a time): smoke 9333, playlists 9334, preview 9335, terminal 9336, notifications 9337, vnc 9338, layout 9339, stale-chunk 9341, ticker 9344, devtools 9345, touch-setup 9347, reorder 9348, panes 9446.
- Exit codes: 0 all checks pass; 1 any FAIL or login failure (`ui-smoke.py --compare` also 1 on differences). `ws-probe.py` 1 on login or send failure.
- Env: `UNITOTEM_VNC_IDLE_TIMEOUT` (node; `0` = off; `ui-vnc.py` needs `20`). VM settings (`VM_*`): [testing-vm.md](testing-vm.md).
- Endpoints used: `POST /auth/token`, `GET /api/schema`, `wss /ws` (targets such as `Viewers/list`, `Scheduler/add_file`), `wss /terminal`, `wss /vnc`.

## Rules and gotchas
- The `sys.argv` strip in `conftest.py` stays first: importing `utils.models.command_line` parses argv (pydantic-settings CLI) and pytest's argv aborts the run.
- The event loop is set in `conftest.py`: models with timers need a loop at import (Python 3.14 creates none).
- Plugin modules load under two names, `unitotem_node.*` (via `manager/plugins`) and `plugins.unitotem_node.*` (via `manager/`): two module objects. Patch the name the code under test uses.
- Test modules import each other (`test_remote_filecache` from `test_remote_transfer`; `test_viewer_lockdown` from `test_layout_controller`). Keep shared helpers in the source module.
- Never run two UI tools at once: fixed ports, garbage results.
- `ui-terminal.py` runs its checks in `env -i ... bash --norc --noprofile` (exec): the administrator's PS1 or PROMPT_COMMAND can rewrite the window title and break the title and minimise checks.
- `ui-touch-setup.py` reaches the board as root through `sshpass -e`; the board password is `UI_SSH_PASSWORD` (default `unitotem`), never on the command line.
- Tests that import `utils.backup` or `utils.remote.bundle` need a writable `/var/lib/unitotem` (the upload manager builds there): on a dev host they skip (`pytest.skip` on `OSError`) and run in autopkgtest as root. `tools/gen-api-types.py` patches `Path.mkdir` and `shutil.disk_usage` only during its import of the API and restores both.
- Never measure performance on a board while it builds or compresses an image (an `xz` at 350 % CPU made imports take minutes and 1080p VP8 lose half its frames). Then check behaviour (Show counts, element identity, `currentTime`), not speed.
- Ticker CPU or frame measurements need a quiet page: the first-boot welcome page repaints every frame (about 85 % of a core on a Pi 4, caps at 40 fps). `tools/ticker/board-static-page.py HOST FEEDS_URL on|off` puts a static page on the first window and removes it.
- A volatile deploy that fails to restart the unit leaves the OLD manager holding 80/443/4443; the new one dies with `Address already in use` and systemd restarts it in a loop, each death running `stop_hotspot`. Check `NRestarts` and `ss -ltnp | grep :443` after every deploy.
- `POST /auth/token` answers 303: read the session cookie with `allow_redirects=False` (a followed redirect loses it).
- Pinch: `Input.synthesizePinchGesture` bypasses `touch-action` and gives a false result; use `Input.dispatchTouchEvent`. `visualViewport.scale` survives `Page.reload`; reset it with `Emulation.setPageScaleFactor`. Real touch tests use a uinput multitouch device (`struct input_event` is `qqHHi` on 64-bit).
- D-Bus code: the PyPI `sdbus` cannot open the user bus here (`sd_bus_open_user` error 123): test against the Debian `python3-sdbus` under `dbus-run-session`, and run `notify-send` and other subprocesses asynchronously so a blocking call does not starve the D-Bus server under test.

## Tests
Unit (`manager/tests/`), `.venv/bin/python -m pytest`:
- Layout and viewer: `test_layout*`, `test_viewer_*`, `test_asset_zoom`, `test_remote_windows`.
- Playlists and ticker: `test_playlists`, `test_ticker_*`.
- Remote: `test_remote_*`.
- Screens, touch, identity: `test_screens_*`, `test_touch*`, `test_ddc_parsers`, `test_gpu_profiles`, `test_output_transform`, `test_mechanism_resolution`, `test_identity`.
- System: `test_suspend`, `test_timers`, `test_hotspot_stop`, `test_network_details`, `test_hosts_file`, `test_machine`, `test_updater`, `test_update_progress`, `test_plugins`, `test_datetime` (time zone and NTP through a fake timedate1, never the real bus).
- Backup and uploads: `test_backup_users`, `test_backup_node_parts`, `test_upload_manager`, `test_plugins` (legacy archives).
- Users and security: `test_osusers`, `test_password_policy`, `test_security_api`, `test_security_model`, `test_first_admin_script`, `test_setup_first_access`, `test_backup_users`, `test_login_hardening`, `test_templates_escape`, `test_webui_entries`.
- Password policy (one policy, PAM and manager; see [security.md](security.md)):
  - `test_password_policy.py`: every vector of `password_vectors.json` (first failed rule, messages empty iff accepted; vectors above 128 characters are expected `max_length`, the one known difference from PAM), control characters, non-text, lone surrogates, username and reverse, `rules_spec()`.
  - `test_security_api.py` and `test_setup_first_access.py`: refusals before any change, 422 `detail` lists.
  - `test_osusers.py`: `create_user` validates before `adduser`; `chpasswd` environment and `BAD PASSWORD:` reasons.
  - `test_first_admin_script.py`: rules printed, 3 attempts.
  - Web UI: `webui/tests/password-rules.test.mjs` (`npm test`) checks `password-rules.js` against the same vectors.
  - Run: `.venv/bin/python -m pytest -q manager/tests/test_password_policy.py` (any file or `-k password`); `cd webui && npm test`.
  - Rule: tests never touch real files. Every path (`users.json`, `security.json`, env file, lock file, passwd, group, shadow) goes to `tmp_path`, and the system tools (`adduser`, `chpasswd`, `gpasswd`, PAM) are mocked. Never run them for real in a test.
- Notifications and VNC: `test_notifications`, `test_desktop_notifications`, `test_vnc`.
- Front end: `cd webui && npm test`.

UI (`tools/ui-*.py`): needs `google-chrome`, `websockets`, `httpx` (repo `.venv`) and, except `ui-panes.py` and `ui-ticker.py`, `--host` of a running node. Run `ui-smoke.py --out before.json`, change, run `--compare before.json`, then the feature tools.
