# Manager core

FastAPI + websocket server of unitotem-manager: web UI host, websocket API, sessions, users, uploads, backup, notifications, plugin loader. Installed alone it is a server that touches nothing of its own machine.

Paths: relative to unitotem-manager/

## Files

Entry and app
- `manager/init.py`: entry (`/usr/sbin/unitotem-manager` runs it). Sets up logging, event loop, environment, migrations, imports `main`. Ends with SIGKILL of its own process.
- `manager/main.py`: `WWW` FastAPI app, routes, startup, asyncio thread, viewer hand-off, shutdown.
- `manager/api/commons.py`: `SHUTDOWN_EVENT`.
- `manager/api/notifications.py`: `Notifications/*` API; `push_all()` pushes lists per user.

Websocket API (`manager/api/ws/`)
- `endpoints.py`: `WebSocketAPI` registry, `WS` and `REMOTE_WS` managers, `handle_call`, plugin API registration.
- `wsmanager.py`: `WSManager` (connections, broadcast, multicast, signing), `WSAPIBase`, `Context`.
- `responses.py`: `WSResponse`, `WSBroadcast`, `WSMulticast`.
- `permissions.py`: permission check, `APIPermissionError`.

Routers (`manager/routers/`)
- `login.py`: `LOGMAN` session manager, `/auth/token`, `/login`, `/logout`, `/api/settings/set_passwd`, `require_perm()`.
- `setup.py`: first-access `/setup`.
- `backup.py`: `/backup` (GET, POST, DELETE), `/backup/parts`.
- `pairing.py`: `/remote/hello`, `/remote/adopt`, `/remote/pair-request` (public, rate limited).
- `scheduler.py`: `POST /api/scheduler/upload`; catch-all `GET /{path}` (web UI shell), must stay last.
- `websocket/web_ui.py`: `/ws`. `websocket/remote.py`: `/remote` (local viewer link).
- `error/`: HTTP error pages.

Templates and resources
- `manager/templates/__init__.py`: Jinja environment (autoescape on), Vite manifest helpers, public JS asset set.
- `manager/templates/base.html`: web UI shell. `first-boot.html.j2`, `no-assets.html.j2`: viewer pages. `errors/error.html.j2`: error page.

Utilities (`manager/utils/`)
- `plugins.py`: `Plugin` and `BackupPart` contracts, loader (`load`, `each`, `provides`).
- `constants.py`: version, `BOOT_ID`, default ports, paths.
- `models/command_line.py`: `cmdargs`. `environment.py`: `environ` (secrets). `migration/`: `advance()` steps run at every start (`v_3_0_0.py`).
- `models/user.py`: `UserPerms`, `UserData`, `User`, `user_manager`. `osusers.py`: system accounts, PAM. `passwords.py`: rules. `sessions.py`: logged-in websockets. See [security.md](security.md).
- `storage/uploadmanager.py`: uploads folder, watcher, `save`, `remove`. `storage/file_info.py`: duration, mime, pages, colour probe.
- `notifications.py`: notification center. `backup.py`: core backup parts, archive, legacy import. `changes.py`: content-change listeners. `ready.py`: `sd_notify READY=1`, once. `_logging.py`: Hypercorn log adapter for loguru.
- `system/`: read-only machine facts: `ip.py` (reachable address, netlink changes), `sysinfo.py`, `machine.py`, `cpu.py`, `sensors.py`, `procfs.py`, `lsblk.py` (filesystem usage cache), `gpu.py` (Chromium switches for the viewer).
- `browser.py` (User-Agent of the embedded browser), `labwc.py`, `outputs.py`, `units.py`, `extras.py`, `async_timer.py`.

## How it works

- Process: the main thread runs the local viewer (plugin `run_gui`) when installed and not `--no_gui`; otherwise it joins the asyncio thread. The asyncio thread runs Hypercorn: HTTPS on `port_secure`, plain HTTP on `port` only redirects to HTTPS.
- Startup: environment, migrations; playlists (a missing file runs plugin `on_first_boot` hooks); users; node identity if `remote.json` is absent; upload watcher and scan; filesystem usage cache; viewer assignments; remote service; sysinfo loop; RSA key generation (executor); notification push binding; plugin `on_startup(loop)`; serve; READY.
- READY: with a local viewer, the viewer sends it on its first frame; otherwise `main.py` sends it once `port_secure` accepts connections.
- Shutdown: SIGTERM or SIGINT runs `_shutdown`: set `SHUTDOWN_EVENT`, stop remote service (5 s limit), plugin `on_shutdown`, stop loop. Without a viewer-initiated shutdown it also calls plugin `request_quit`. Then the file observer stops and the process exits.
- HTTP auth: `Depends(LOGMAN)` reads the session cookie. Unauthenticated requests redirect to `/login`, or to `/setup` when no administrator exists. `require_perm(name)` answers 403.
- Session cookie: JWT with `sub`, `cre`, `sid`, `at`. HttpOnly, SameSite strict, Secure. 7 days with "remember me", else browser session. Revoked when `invalid_before` is newer than `at` (except `keep_sid`).
- Login: PAM check in a thread; the account must be root or in group `unitotem`.
- Websocket `/ws`: cookie checked once at accept. Each message is one call: `{target, ...args}` goes through `handle_call`, permission check, pydantic validation, then the function.
- Plugins: `utils/plugins.load()` runs when `api/ws/endpoints.py` is imported, before routers are included. A plugin adds API classes, routers (factory), backup parts, hooks. A failing plugin is logged, raises admin notification `plugin.<name>` and is skipped.
- Notifications: in memory under one lock, persisted to `/var/lib/unitotem/notifications.json`. Each change pushes `Notifications/list` to every open page, once per user.
- Sysinfo: `Settings/info` is broadcast every 3 s, only while a websocket is connected.
- Uploads: `UploadManager.save` writes the file and appends it to the default playlist. Name collisions get `_N` suffixes.
- First boot: no `users.json` runs plugin `on_first_boot`; `first_boot_context` hooks feed the welcome page, served to loopback only.

## Interfaces

CLI (`utils/models/command_line.py`, pydantic-settings, parsed at import; names use underscores):

| Flag | Default | Meaning |
|---|---|---|
| `--no_gui` | false | backend only, no local windows |
| `--bind`, `--port` | 0.0.0.0, 80 | HTTP (redirects to HTTPS) |
| `--bind_secure`, `--port_secure` | 0.0.0.0, 443 | HTTPS web UI and API |
| `--bind_link`, `--port_link` | 0.0.0.0, 4443 | mutual-TLS node link |
| `--assets_file` | /etc/unitotem/assets.json | playlists and assets (directory of all state files) |
| `--users_file` | /etc/unitotem/users.json | users |
| `--remote_file` | /etc/unitotem/remote.json | remote control |
| `--envfile` | /etc/unitotem/unitotem.env | secrets |
| `--certfile`, `--keyfile` | /etc/ssl/unitotem.pem | TLS certificate and key (one file) |
| `--uploads_folder` | /var/lib/unitotem/uploaded | uploads |

Files:
- `/etc/unitotem/unitotem.env`: `AUTH_TOKEN` (JWT secret), `INSTANCE_ID`, `HOTSPOT_UUID`. Generated when missing.
- `/etc/unitotem/users.json` (0600): `{name: {permissions, invalid_before, keep_sid}}`. Permissions: `scheduler`, `power`, `audio`, `admin` (`admin` implies all). No password stored.
- `/etc/unitotem/unitotem.conf`: legacy, migrated to `assets.json` and `users.json`, renamed `.conf.old`.
- `/var/lib/unitotem/notifications.json`: `version` 1 and items. Not in backup.
- `/etc/pam.d/unitotem-manager`: PAM service (falls back to `login`).

Systemd (`debian/unitotem-manager.service`): `Type=notify`, `NotifyAccess=main`, `TimeoutStartSec=300`, `Restart=on-failure`, `RestartSec=10`, `KillMode=process`, `StateDirectory=unitotem`, `WorkingDirectory=/usr/share/unitotem-manager`.

Environment: `UNITOTEM_LABWC_RUN` (compositor config dir, default `/run/unitotem/labwc`), `LABWC_PID`.

Exit codes: 0 normal stop; 1 when the viewer raises (systemd restarts).

HTTP:

| Method and path | Access | Purpose |
|---|---|---|
| GET `/health` | loopback | `{status, version}` |
| GET `/unitotem-first-boot`, `/unitotem-no-assets` | loopback, else 404 | viewer pages |
| GET `/unitotem-first-boot/address` | loopback | SSE: address changes |
| GET `/pdf-view`, POST `/pdf-view/failed` | loopback | PDF page; failure raises `pdf.render.<file>` |
| GET `/api/schema` | session | API schema |
| GET `/login`, `/login/users`, POST `/auth/token`, GET `/logout` | none | login (form: `username`, `password`, `src`, `remember_me`) |
| POST `/api/settings/set_passwd?password=` | session | own password; other sessions revoked |
| GET, POST `/setup` | none, only with no admin | first administrator (404 afterwards) |
| GET, POST, DELETE `/backup`, GET `/backup/parts` | admin | archive (POST and DELETE answer 204) |
| POST `/api/scheduler/upload` | scheduler | multipart `files`, 201 |
| WS `/ws` | session | API |
| WS `/remote` | loopback, header `instance_id` | viewer of this node |
| GET `/remote/hello`, POST `/remote/adopt`, `/remote/pair-request` | none | pairing (see [remote.md](remote.md)) |
| GET `/{path}` | session | web UI shell (catch-all) |

Websocket protocol:
- Client to server: `{"target": "Class/Sub/method", ...args}`. No correlation ids.
- Server to client: `{"target": ..., ...fields}`. On connect: `{"target": "connected", "boot": BOOT_ID}`.
- Errors: `target: "error"` with `error` and `extra`: `Invalid command` (also the answer to any `KeyError` raised inside a call), `Permission error: not allowed to execute <target>`, `Exception` (`extra` holds the traceback).
- Return values: dict or `WSResponse` to the caller; `WSBroadcast` to all sockets; `WSMulticast(users)` to the sockets of the named users.
- Names: `Class/method`; nested classes add a prefix (`Settings/Remote/...`). Names containing `/_` are private.
- Permissions: `@UserPerms.requires.<scheduler|power|audio|admin>` (stacked = OR); `requires.none` = any logged-in user; no decorator = admin.
- Arguments: pydantic `validate_call`. A `ctx: Context` parameter (`username`, `sid`) is injected and not in the schema.
- Schema: `GET /api/schema` returns `{path: {doc, permissions (null = any user), params (JSON schema)}}`.
- Signed channel (`REMOTE_WS`): `base64(json) + "." + base64(RSA-PSS/SHA-256 signature)`; the last message per target is replayed to new connections.

Notifications:
- API: `Notifications/list`, `mark_read(ids)`, `dismiss(ids)`, `dismiss_all()`, `invoke(id, action="default")`. `ids` at most 200.
- Dedupe: `notify` with the same key and same content does nothing (a dismissed one stays dismissed); changed content updates it, unread again for everybody. Read and dismiss are per user (`read_by`, `dismissed_by`): one user's dismissal keeps it for the others; it is hidden for good, and its sender told, once every user who can see it has dismissed it. Legacy `read`/`dismissed` flags mean everybody.
- Producer: `notifications.notify(key, level, title, text, *, source, audience, link, progress, persistent, timeout, actions, resident)` returns id or None; also `resolve(key)`, `set_progress`, `expire`, `listen_action`, `listen_closed`, `bind`.
- Levels: `info`, `warning`, `error`. Audience: `scheduler`, `audio`, `power`, `admin`, or None (everyone).
- Limits: 100 items; title 120, text 1000, key 120 characters; 6 actions. Pop-up timeouts 6000, 9000, 12000 ms by level.

Plugin contract (`utils/plugins.py`):
- `Plugin`: `name`; `api` (module, class, prefix)*; `routers` (factory); `backup` (BackupPart*); `on_startup(loop)`; `on_first_boot()`; `first_boot_context()` returns dict; `on_shutdown()`; `run_gui(schedule_shutdown)` (at most one); `request_quit()`; `audio_outputs()` returns `[{name, description}]`.
- `BackupPart`: `key`, `label`, `export()`, `restore(data, version)`, `reset()`, `export_files(zip)`, `restore_files(zip)`, `optional_in_backup`.

Backup archive (zip):
- `config.json`: `{"version", "parts": {key: data}}`; file parts under `uploaded/`.
- Core parts: `playlists`, `layouts`, `users`, `security`, `remote`, `ticker`, `uploads` (optional, off by default). Plugin parts are listed in [node-system.md](node-system.md).
- `GET /backup?parts=...`: default every non-optional part. `POST /backup` (multipart `backup_file`, form `parts`) restores only the listed parts; legacy archives (`CONFIG`) are converted. `DELETE /backup?parts=...`: reset to factory (default: parts that have a reset).

Password rules: see [security.md](security.md).

## Rules and gotchas

- Core runs on a plain Debian server: no subprocess, DBus, sysfs writes or systemctl in core. Machine control belongs to the node plugin. `utils/system/` only reads.
- Core never imports plugins; plugins may import core.
- Notification producers import `utils.notifications` only. Text is plain (never markup). Sender text is truncated.
- Specific routes before `GET /{path}`, which requires a session.
- Plugin `routers` is a factory because routers import `login`, which needs the API built first.
- Pages loaded before login must be in the import closure of the `login` or `setup` entry (`templates.public_asset_files`). Other JS chunks need a session (loopback excepted).
- Loopback-only pages answer 404, not 403.
- Error pages show no version, OS, address or host name.
- Password change, user deletion, backup restore or reset close websockets with code 1008 `Not Authenticated` (`utils/sessions.py`).
- PAM and `useradd` run in a thread. RSA-4096 key generation runs in an executor (minutes on a Raspberry Pi).
- The backup `users` part contains `/etc/shadow` hashes: the archive is as sensitive as the private keys.
- Names are data: validate with `fullmatch` (a regex ending in `$` accepts a trailing newline), never a shell, `--` before values, `secure_filename` for uploads, JSON via `json.dumps`, Jinja autoescape on.
- A sync API function runs on the event loop: blocking work (HTTP probes, up to 10 s) freezes every websocket. Make the function `async` and run the blocking part in a thread (`add_url_assets`).
- Server-to-client fields must not be named `target`: it collides with the message target (`WSResponse` got multiple values, the call timed out silently). Touch setup uses `spot`.
- `WSManager.disconnect(websocket, user)` needs the user: without it the socket stays in `active_users`.
- A `@dataclass` with default `eq=True` is unhashable: use `eq=False` or `frozen=True` for instances placed in sets (a set member gave a 500 on websocket upgrade).
- Read system facts through libraries and `/proc` (`psutil`, `/proc/net/route` in `utils/system/ip.py`), not CLI output: a minimal Debian has no `ip`.
- Serve proxied files with `iter_chunked`: aiohttp `content.read(n)` returns only the bytes that arrived (truncated JavaScript modules in `devtools.py`).
- Hostname: `socket.gethostname()` (`platform.node()` is cached).
- The websocket API has no ids: every state change is answered with the event the page listens to.
- After changing an API function run `tools/gen-api-types.py`.
- Runtime state lives under `/var/lib/unitotem` and `/etc/unitotem`, never under the code directory (`/usr` is read-only).
- Migrations (`utils/migration/*.py`) run at every start; each `advance()` is idempotent. Order is `pkgutil` order, not sorted.
- Unknown fields in `notifications.json` are ignored on read and dropped on write (`FILE_VERSION` 1).
- Failing plugin hooks are logged, never fatal. The welcome page renders even when the hotspot cannot be queried.

## Tests

- `pytest` from the repository root (`pyproject.toml`: `testpaths = manager/tests`, `pythonpath = manager, manager/plugins`).
- `manager/tests/conftest.py` clears `sys.argv` (the CLI parses on import) and sets an event loop.
- Modules: `test_plugins.py`, `test_notifications.py`, `test_osusers.py`, `test_password_policy.py`, `test_templates_escape.py`, `test_webui_entries.py`, `test_machine.py`.
- Live checks against a running manager: `tools/ui-smoke.py`, `tools/ui-notifications.py`.
