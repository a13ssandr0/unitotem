# Web UI

Vue 3 + Vuetify single-page management UI served by the manager. Source `webui/`. Build output `manager/static/` (untracked, produced by `debian/rules`). One websocket (`/ws`) plus a few HTTP endpoints.

Paths: relative to `unitotem-manager/`

## Files
Core (`webui/src/`):
- `main.js`: app, Vuetify (theme `system`, primary `#2962FF`), router (history mode), chunk-reload guard.
- `App.vue`: root `v-app` with `router-view`.
- `routes.js`: route table. `/` and `/settings/*` nest under `base.vue`; `/login`, `/setup` are standalone.
- `base.vue`: shell of every `/` page: app bar, drawer, outlet, taskbar, terminal and VNC windows, power dialogs, reconnect overlay. Owns the websocket.
- `api.js`: websocket client: `api` proxy, `useApiState`, `onApi`, `onOpen`, `canCall`, schema loader. `api.d.ts` is generated (`tools/gen-api-types.py`), do not edit.
- `windows.js`: registry of open floating windows (taskbar source). `notifications.js`: notification click and action handling.
- `keyboard.js`, `keyboard-layouts.js`: on-screen keyboard module for the viewer page (layout ids `lang` or `lang/variant`). `keyboard/` is generated data (`tools/keyboard/aosp_layouts.py`, from AOSP LatinIME).
- `ticker.js`, `ticker-core.js`: RSS ticker for the viewer page; `ticker-core.js` is DOM-free and tested. See [layout-and-ticker.md](layout-and-ticker.md).
- `pdf-view.js`: one-page PDF renderer (pdf.js) for the viewer. `settings.scss`: Vuetify overrides.
- `password-rules.js`: DOM-free mirror of the server password policy (`evaluate`, `failedIds`, `isValid`). Spec from `password_policy` (WS) or `window.__INITIAL_STATE__.rules`. Tested against `manager/tests/password_vectors.json`.
- `webui/vite.config.mjs`, `webui/package.json`: build, dev server, scripts. `webui/tests/ticker-core.test.mjs`, `webui/tests/password-rules.test.mjs`: node tests.

Pages (`webui/src/pages/`):

| File | Route | Content |
|---|---|---|
| `scheduler.vue` | `/` | playlist tabs, items (drag to reorder), uploaded files, Add URL and playlist settings dialogs |
| `viewers.vue` | `/viewers` | per-window matrix (playlist, sound, language, keyboard, interactive screen, refresh, developer tools), layout editors, RSS sources |
| `info.vue` | `/info` | CPU chart (stacked per core), memory, temperatures, fans, storage tree |
| `login.vue`, `setup.vue` | `/login`, `/setup` | login; first administrator (only while no administrator exists): name, password and confirmation with `PasswordChecklist`, submit disabled until all met |
| `NotFound.vue`, `empty_page.vue` | catch-all | 404, placeholder |
| `settings/audio.vue` | `/settings/audio` | default output, per-device volume and mute |
| `settings/display.vue` | `/settings/display` | screen preview, orientation, flip, insecure certificates, GPU status, `ScreenControl`, `TouchMapping` |
| `settings/remote.vue` | `/settings/remote` | server or client role, clients, pairing, adoption, leave or forget |
| `settings/users.vue` | `/settings/users` | accounts, permissions, add and password dialogs with `PasswordChecklist`, login page user list switch |
| `settings/timers.vue` | `/settings/timers` | scheduled jobs (shutdown, reboot, suspend, screen on/off) |
| `settings/network.vue` | `/settings/network` | hostname, devices, saved connections, Wi-Fi scan and connect |
| `settings/updates.vue` | `/settings/updates` | A/B slots, check, download, install, rollback, automatic policy |
| `settings/backup.vue` | `/settings/backup` | backup, restore, reset of parts |
| `settings/datetime.vue` | `/settings/datetime` | server time zone (searchable selector), NTP switch and status |

Components (`webui/src/components/`): `PasswordChecklist` (live rule rows, see Rules and gotchas), `FloatingWindow` (draggable, resizable, minimisable; base of terminal and screen), `TerminalWindow` (xterm.js), `VncWindow` (noVNC), `WindowTaskbar` (32 px strip), `NotificationMenu`, `NotificationToasts`, `SuspendDialog`, `CardColumn`, `WindowLayout`, `PaneTree`, `TickerSettings`, `TickerSources`, `AssetPreview`, `ScreenControl` (DDC/CI, CEC, Wake-on-LAN, serial, GPIO), `TouchMapping`.

## Navigation
- Top bar: terminal and screen buttons (admin, node plugin only), notification bell, theme cycle (light, dark, auto), reboot, suspend, power off (each with its permission), user menu.
- Drawer: Scheduler, Viewers, Settings (one entry per tab the user may open), Info. Footer: display size, version.
- A page mounts only when the user and permissions are known. A forbidden route redirects to the first allowed page.
- Settings tab permission keys: audio `Settings/Audio/devices`, display `Settings/Display/displays`, remote `Settings/Remote/mode`, users and backup `Settings/Security/users`, timers `Settings/Timers/jobs`, network `Settings/Network/devices`, updates `Settings/Update/status`, date and time `Settings/DateTime/status`.

## How it works
- Load: the server renders the shell with `window.__INITIAL_STATE__` and `window.__BOOT_ID__` (`manager/templates/base.html`); `main.js` mounts `App.vue`.
- Socket: `base.vue` opens `/ws`; on open it sends commands registered with `init`, then `Settings/Display/bounds` (node plugin, `viewer_id: local-webview`), then runs `onOpen` callbacks.
- Reads: `api.X.Y.on(cb, {init})` or `api.X.Y.use({pick, initial})`. The server pushes state, pages never poll.
- Writes: `api.X.Y.z(args)` is fire-and-forget; the page updates when the server pushes the new state.
- Permissions: `/api/schema` loaded at mount; `canCall(path, user)` hides menus and controls; the server checks every call.
- Errors: a message with an `error` key goes to the snackbar (and console) in `base.vue` and never reaches page listeners.
- Reconnect: socket reopens after 3 s. Close reason `Not Authenticated` reloads (goes to login).
- Notifications: bell and pop-ups show `Notifications/list`. A click runs the default action if any, marks read, opens `link` if it is a same-origin path.
- Windows: floating windows register in `windows.js` and show in the taskbar; minimised ones keep state.
- Terminal: `POST /terminal/token`, then `/terminal` websocket; closes with the window.
- Screen: `POST /vnc/token`, then `/vnc` websocket (noVNC). View-only by default; control chosen per session, never stored. Sends `{"activity":1}` every 5 s.
- Scheduler: selecting a playlist requests `assets`, `current`, `default_duration`. Upload `POST /api/scheduler/upload` per file; download `GET /uploaded/<name>`.
- Viewers: rows are playlists, columns windows (`Viewers/list`); a cell toggles the playlist of a window. Area and panes are edited in `WindowLayout.vue`, pushed back by `Viewers/layout`.
- Date and time: the clock is drawn in the browser (1 s tick) in the server zone. The zone selector is searchable. The NTP switch shows a status chip; it is disabled with a hint when `CanNTP` is false. Controls are disabled while a call is pending and always show the server value.
- Updates: `Settings/Update/status` pushed; progress in `status.op.progress`; install and slot switch need confirmation dialogs.
- Backup: `GET /backup?parts=...` download, `POST /backup` (multipart) restore, `DELETE /backup?parts=...` reset; parts from `GET /backup/parts`.

## Interfaces
Websocket `/ws` (session cookie):
- Client to server: `{"target": "Settings/Network/devices", ...args}`. No request ids.
- Reply types (`manager/api/ws/responses.py`): `WSResponse` goes to the sender only, `WSBroadcast` to every client, `WSMulticast` to named users.
- On connect: `{"target": "connected", "boot": "<id>"}`. A boot id different from `__BOOT_ID__` triggers a fresh reload.
- Error: `{"target": "<target>", "error": "<text>", "extra": "<traceback or details>"}`.
- `/terminal`: first frame `{"token": ...}`, then raw I/O; resize `{"resize": [cols, rows]}`. `/vnc?output=NAME&control=1`: first frame `{"token": ...}`, then RFB.
- `GET /api/schema`: `{"<Path/Function>": {"params": <JSON Schema>, "permissions": [..] | null}}`; `null` = any logged-in user.

HTTP endpoints:

| Endpoint | Use |
|---|---|
| `POST /auth/token` (form: username, password, remember_me) | login |
| `GET /login/users`, `GET /logout` | user list on login, logout |
| `POST /setup` (JSON username, password) | first administrator; 404 once an administrator exists |
| `POST /api/scheduler/upload` (multipart `files`) | 201 per stored file |
| `GET /uploaded/<name>` | download, preview |
| `GET /backup/parts`, `GET /backup?parts=`, `POST /backup`, `DELETE /backup?parts=` | backup, restore, reset |
| `POST /devtools/open` (`window_id`) returns `{path}` | developer tools tab |
| `POST /pdf-view/failed?file&problem&recovered` | PDF failure report |

API groups (`api.*`, names as in the schema):
- Scheduler: push `playlists`, `assets`, `current`, `files`, `default_duration`. Commands `create_playlist`, `rename_playlist`, `set_default_playlist`, `delete_playlist`, `set_default_duration`, `add_url_assets`, `add_file_assets`, `edit_asset`, `delete_asset`, `copy_assets`, `move_assets`, `reorder_assets`, `goto_asset`, `next_asset`, `previous_asset`, `delete_files`.
- Viewers: push `list`, `layout`, `audio_outputs`, `screensaver`, `refresh`, `keyboard`, `language`. Commands `assign_playlist`, `unassign_playlist`, `set_audio_output`, `set_keyboard`, `set_language`, `set_screensaver`, `set_refresh`, `refresh`, `set_area`, `split_pane`, `close_pane`, `set_split_ratio`.
- Settings: push `info`. `Audio`: `devices`, `set_default_device`, `set_volume`, `set_mute`. `Display`: `displays`, `bounds`, `orientation`, `flip`, `allow_insecure_certs`, `gpu_feature_stats`, `set_orientation`, `set_flip`, `set_allow_insecure_certs`. `Screens`: `screens`, `gpio_lines`, `probe`, `configure`, `set_power`, `set_input`, `set_volume`, `set_mute`. `Touch`: `devices`, `setup`, `start_setup`, `confirm_setup`, `cancel_setup`, `reset`, `forget`, `set_output`, `set_orientation`.
- Settings `Network`: `hostname`, `set_hostname`, `devices`, `connections`, `connection_details`, `active_connections`, `has_wireless`, `wireless_enabled`, `set_wireless_enabled`, `wireless_networks`, `connect_wifi`, `default_wlan_device`, `activate_connection`, `deactivate_connection`, `edit_connection`, `delete_connection`.
- Settings `Remote`: `mode`, `probe`, `become_client`, `become_server`, `adopt`, `request_pairing`, `cancel_pairing`, `approve_request`, `reject_request`, `set_client_enabled`, `unpair_client`, `leave_server`, `forget_server`.
- Settings `Security`: `current_user`, `users`, `password_policy`, `login_user_list`, `add_user`, `delete_user`, `set_user_password`, `set_user_permissions`, `set_login_user_list`. `Timers`: `jobs`, `add_job`, `edit_job`, `delete_job`, `set_job_enabled`. `Update`: `status`, `availability`, `check`, `fetch`, `apply`, `confirm`, `cancel`, `rollback`, `copy_to_other`, `set_policy`.
- Settings `DateTime`: `status`, `set_timezone`, `set_ntp`.
- Power: `suspend_support`, `reboot`, `poweroff`, `suspend`. Notifications: push `list`; `mark_read`, `dismiss`, `dismiss_all`, `invoke`. Ticker: push `sources`, `settings`, `preview`; `add_source`, `edit_source`, `delete_source`, `enable_source`, `fetch_now`, `set_settings`. Vnc: push `outputs` (`{outputs, available}`).

Payload fields used by pages:
- Scheduler item: `uuid`, `name`, `url` (`file:<name>` for uploads), `media_type` (0 web, 1 image, 2 video, 3 audio, -1 unknown), `duration` (s, 0 = forever), `pages`, `enabled`, `fit` (0 contain, 1 cover, 2 fill), `bg_color` (null = auto), `ena_date`, `dis_date`, `volume` (0-1), `muted`, `zoom` (0.25-5), `allow_pinch_zoom`.
- Viewer window: `window_id`, `width`, `height`, `screen_name`, `assigned_playlist`, `audio_output`, `keyboard {enabled, button_position, layout}`, `screensaver {enabled, home_url, idle_timeout}`, `refresh {refresh_after_idle, refresh_schedules}`, `orientation` (0-3), `flip` (0 none, 1 horizontal, 2 vertical), `layout {area, tree, main, panes}`.
- Timer job: `uuid`, `command` (`pwr`, `reb`, `sus`, `scr_on`, `scr_off`), cron fields as strings (`hour`, `minute`, `day_of_month`, `month`, `day_of_week`), `output`, `mechanism`, `wake` (`sus` only).
- Update status: `slot`, `other_slot`, `current_version`, `other_version`, `default_slot`, `running`, `armed`, `trial`, `pending_confirm`, `staged`, `op {progress {phase, percent, eta_s}}`, `auto.policy {mode, time}`, `last_result`.
- Network device state: NetworkManager `NM_DEVICE_STATE` (100 connected, 120 failed, 40-90 connecting); device type 32 has no connect or disconnect actions.

Globals and storage:
- `window.__INITIAL_STATE__`: `hostname`, `ip_addr`, `os_vers`, `ut_vers`, `plugins`, `src` (post-login target), `show_users` (login), `rules` (setup: the password policy spec, `passwords.rules_spec()`). Also `window.__BOOT_ID__`, `window.utKeyboard`, `window.utTicker`.
- `localStorage`: `themeMode` (`light`, `dark`, `auto`), `last_user`. `sessionStorage`: `unitotem-chunk-reload`, `unitotem-boot-reload`.
- Keyboard config `{enabled, button_position, layout}`; positions are the 8 edge names.

Build and dev:
- Build: `cd webui && npm ci && npm run build` writes `manager/static/` with `manifest.json`; copies `pdfjs-dist` standard fonts and cmaps to `assets/pdfjs/`.
- Entries: `main`, `keyboard`, `ticker`, `pdf`; the last three are loaded by the viewer page.
- Dev: `npm run dev` on port 3000; non-module requests go to `UNITOTEM_BACKEND` (default `https://localhost`) with header `X-Unitotem-Vite-Dev: 1`.

## Rules and gotchas
- The websocket API is id-less by design; do not add request or response correlation.
- Error replies never reach page listeners: a page must not wait for a success reply to clear a busy flag.
- State flows one way: server pushes, pages read. Screen and window changes arrive as events, never by polling.
- Pages are not mounted before the user is known and allowed (`routeAllowed`, `base.vue`).
- The permission list of `settings/users.vue` mirrors `UserPerms` (`scheduler`, `audio`, `power`, `admin`); `admin` implies all, enforced client-side too.
- Cron fields are comboboxes, not selects: `*/15`, `1-5`, `0,30` must round-trip.
- Admin rows (keyboard, language, layout, RSS sources) are hidden from non-admins with `canCall`; the server still checks.
- Keyboard and ticker are separate entries loaded by the viewer, not Vue pages; they publish on `window`, do not rely on chunk exports.
- Layout-editor drags listen on `window`, not on the grabbed element; UI tests send mouse events with `buttons` set.
- The RSS crawl moves by compositor transforms only; no per-frame JavaScript positioning.
- Stale tabs: a failed chunk load reloads once per 10 s (`main.js`); a different boot id reloads once per id (`base.vue`).
- The taskbar sets `--taskbar-height`; bottom-anchored elements read it.
- Notification links: paths starting with `/`, never `//`.
- Every page route is listed in `routes.js` (`main.js` imports the table); an unlisted page is not reachable.
- API calls take ONE object: `api.X.y({a, b})`. Positional arguments give a pydantic `unexpected_keyword_argument` error.
- Scoped styles of `FloatingWindow` do not reach slot content: buttons put in the titlebar slot carry their own CSS (`VncWindow` does). The 8 resize grips (`.resize-handle`) sit over the border.
- Moving or resizing something inside the viewer page (keyboard) uses pointer events directly, not interact.js or similar: page content is rotated and flipped with CSS and those libraries do not follow a transformed parent. `keyboard.js` limits (`KEEP_PX` = 160 px of the panel width and its header always stay on screen, minimum size, header never shrinks) are applied after every gesture, screen size change and rotation.
- `npm run build ... | tail -1` hides a failing build: read the whole output. A backtick inside a CSS comment within a template literal of a Vue or keyboard file breaks the build.
- English only, comments included.
- Password form (setup, add user, change password): `PasswordChecklist` (props `spec` = server spec, `password`, `username`, `confirm`; `confirm` undefined = no match row; emits `valid` at mount and on change) shows one row per spec rule, met or not met. It only shows the rules: the server decides. `spec` null shows nothing and reports not valid. The inputs take `maxlength` = `max_length` characters.
- Checklist rows wrap onto a second line (no truncation, no horizontal scroll) in the 400 px dialogs and at 360 px; the dialog text areas clip horizontal overflow.
- Users page: the trash icon opens a `Delete <username>?` dialog (Cancel focused, Delete in the error colour); `delete_user` is sent only on Delete.
- Buttons stay disabled until the checklist reports valid (and the name is filled, for setup and add user): unavailable, not hidden.
- Server refusals: `Password refused` with `extra` (list of reasons) shows in the snackbar, one reason per line (`base.vue` `errorMessage`). `setup.vue` shows the same list (`detail`) in an alert above the form.
- Timer mutations (`add_job`, `edit_job`, `delete_job`, `set_job_enabled`) never edit the list locally: the backend answers each with a fresh `jobs` push and the listener rewrites the list.
- `ScreenControl` lists every mechanism of a screen; an unavailable one stays visible (outlined chip) and its tooltip shows the reason.

## Tests
- `cd webui && npm test` (`node --test tests/*.test.mjs`): `ticker-core.js`, and `password-rules.js` against `manager/tests/password_vectors.json` (same vectors as pytest). `npm run lint` (eslint, runs with `--fix`).
- UI tests check visibility by computed `display` or `aria-expanded`, not DOM presence: a hidden `v-badge` keeps its text in the DOM and a `v-menu` content stays after its first opening.
- After changing an API function: `.venv/bin/python tools/gen-api-types.py` regenerates `webui/src/api.d.ts`.
- Browser tools against a running node: see [testing.md](testing.md).
