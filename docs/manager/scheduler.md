# Scheduler: playlists, assets, uploads, viewer routing

Plays playlists: ordered assets, each shown for its duration on the panes assigned to its playlist. Covers playlist CRUD, asset editing and scheduling (enable/disable dates), uploads, and assignment of playlists to viewer windows and panes (layouts).

Paths: relative to unitotem-manager/

## Files

| Path | Role |
|---|---|
| `manager/api/scheduler.py` | WS API `Scheduler`: playlists, assets, files, URL media-type probe |
| `manager/api/viewers.py` | WS API `Viewers`: window/pane assignment, layout editing, per-window settings |
| `manager/utils/models/playlists.py` | `PlaylistsManager`: playlist set, default, index file, transfer, referenced files |
| `manager/utils/models/assets.py` | `Asset`, `AssetsManager` (cursor, timers, persistence), `FitEnum`, `MediaType`, `idle_asset()` |
| `manager/utils/models/layout.py` | Pure layout model (`WindowLayout`, `Leaf`, `Split`, `Area`), `WindowLayouts` store |
| `manager/utils/models/viewer.py` | `ViewerSettings` (per-window), screensaver/refresh/keyboard models |
| `manager/utils/storage/uploadmanager.py` | `UploadManager`: uploads folder, save, remove, rescan (watchdog) |
| `manager/utils/storage/file_info.py` | `get_file_info`: MediaInfo mime/duration, PDF page count |
| `manager/utils/outputs.py` | Output name canonicalisation (`HDMI-A-1` = `HDMI-1`) for stored keys |
| `manager/utils/async_timer.py` | `Timer`: one-shot asyncio timer |
| `manager/webview/controller.py` | `WebviewManager`, `PlaylistLoop`, `show_payload()`, assignments, `_sync_window()` |
| `manager/routers/scheduler.py` | `POST /api/scheduler/upload` |
| `manager/main.py` | `/uploaded` mount, `/pdf-view` route |
| `webui/src/pages/scheduler.vue`, `viewers.vue`, `webui/src/components/WindowLayout.vue` | Web UI |

## How it works

- One `AssetsManager` per playlist. `PlaylistsManager` owns the set and the default playlist (target of calls without `playlist_id`).
- Playback: `AssetsManager.iter_wait()` moves a cursor over enabled assets. Each step arms a timer for `asset.duration` (0 = wait forever). On expiry: next page of a multi-page PDF, else next enabled asset.
- Each step calls `on_current_update` and wakes `PlaylistLoop._run`, which multicasts `Show` (`show_payload()`) to every `(viewer, window, pane)` assigned to that playlist.
- No enabled asset: cursor -1, `idle_asset()`: `no_assets` when an admin exists, else `first_boot` (welcome page). Unassigned windows show the same idle asset.
- Every change (add, delete, move, edit, enable/disable) ends with `revalidate_current()` then `save()`; without it the playback loop, parked on `_waiting_evt`, does not wake.
- `save()` writes `<file>.tmp`, fsyncs, renames. Broadcasts: `Scheduler/assets` (`playlist_id`, `items`, `current`) and `Scheduler/current`.
- Duration: an asset whose `duration` is None takes the playlist `default_duration` (default 30 s). Uploads take the MediaInfo duration when present (video, audio); images and PDFs get None.
- Media type: uploads from MediaInfo mime (PDF by extension). URL assets: `probe_media_type()` (HEAD, then 1-byte ranged GET, 5 s each, TLS verified). Probe failure, including a certificate error, gives `undefined`; the viewer decides. Run in a thread from `add_url_assets` and `edit_asset` (a changed URL), never on the event loop.
- Container sent to the viewer = `media_type + 1` (undefined -> -1, viewer probes the URL).
- PDF (`file:*.pdf`): sent as `/pdf-view?file=&page=&fit=&bg=`, one page per `duration`. Unreadable PDF = 1 page.
- Scheduling: `ena_date` / `dis_date` each arm a `Timer` (`TIMERS[uuid]`). On expiry the asset is enabled/disabled, the date cleared, then `_owner.scheduled_change()` runs: `revalidate_current()` (a parked playlist starts) and `save()`.
- Ownership: every asset of a playlist has `_owner` set to its `AssetsManager` (validator on construction, load, assignment; `_asset()` for add, insert, set, extend, copy, move). `_owner` is a private attribute, never serialised. An asset that has left the playlist is ignored by its schedule.
- Upload (`upload_manager.save`): file written to the uploads folder, appended to the default playlist as disabled. The watcher rescans and broadcasts `Scheduler/files`.
- `delete_files`: removes every `file:<name>` asset from all playlists, then unlinks the file.
- `transfer_assets` (copy/move): copies get new uuids; move deletes sources. Same source and target is refused.
- Routing: a window has a main pane whose playlist is the screen assignment `(viewer_id, screen_name)`. Other panes keep their playlist in `window_layouts.json`.
- Assigning requires the window to be on a named output; otherwise the call is logged and ignored.
- `_sync_window()` is the only reconciler of loops and idle panes: assign, unassign, split, close, restore all end there. A pane plays one playlist; a playlist drives any number of panes/windows.
- Layout: `area` (percent rectangle + margin colour) and a binary tree of panes (`h` side by side, `v` stacked). Max 8 panes, depth 4, split ratio 10-90 %; out-of-range values are clamped.
- Closing the main pane promotes the next pane; its playlist becomes the window assignment.
- Deleting a playlist unassigns its screens, removes it from pane maps, sends idle to affected windows.
- Volume/mute edits of the playing asset are pushed to the windows showing it.

## Interfaces

WS API (`Scheduler/*` requires `scheduler`; `Viewers/*` requires `scheduler` unless marked admin):
- Scheduler: `playlists`, `create_playlist(name)`, `delete_playlist(playlist_id)`, `rename_playlist(playlist_id, name)`, `set_default_playlist(playlist_id)`, `copy_assets` / `move_assets(uuids, playlist_id, target_playlist_id)`, `assets(playlist_id)`, `files`, `add_url_assets(items, playlist_id)`, `add_file_assets(items, playlist_id)`, `edit_asset(uuid, playlist_id, name, url, duration, fit, bg_color, ena_date, dis_date, enabled, volume, muted, zoom, allow_pinch_zoom)`, `current(playlist_id)`, `delete_asset(uuid, playlist_id)`, `delete_files(files)`, `goto_asset(index|uuid, playlist_id)`, `previous_asset`, `next_asset`, `reorder_assets(from_i, to_i, playlist_id)`, `default_duration(playlist_id)`, `set_default_duration(duration, playlist_id)`.
- Viewers: `list`, `assign_playlist(viewer_id, window_id, playlist_id, pane_id?)`, `unassign_playlist(viewer_id, window_id, pane_id?)`, `layout(viewer_id, window_id)`. Admin: `add_window`, `remove_window`, `set_area`, `split_pane(..., direction h|v)`, `close_pane`, `set_split_ratio(..., path, ratio)` (path of `a`/`b`, `''` = root).
- Errors: `WSResponse(error=...)`. Unknown playlist: `Playlist '<id>' not found`. `add_file_assets` with unknown files: `error='Invalid elements'`, `extra=[...]`. Layout errors: `LayoutError` text.
- Broadcasts: `Scheduler/assets`, `Scheduler/current`, `Scheduler/files` (`files`, `disk_used`, `disk_total`, `used_in` = `{filename: [playlist_id]}`).

REST:
- `POST /api/scheduler/upload`: multipart `files` (list). 201; 403 without `scheduler`.
- `GET /uploaded/<name>`: no auth from loopback (`127.0.0.1`, `::1`); otherwise login required.

Asset fields (JSON in playlist files):

| Field | Type / values |
|---|---|
| `uuid` | 32 hex, frozen |
| `name` | str |
| `url` | `file:<basename>` or http(s); scheme added if missing |
| `duration` | int >= 0 seconds; None = playlist default |
| `enabled` | bool (default false) |
| `ena_date`, `dis_date` | datetime or null; empty string = none |
| `fit` | 0 `contain` (default), 1 `cover`, 2 `fill` |
| `bg_color` | serialised `#rrggbb`; null = none |
| `volume` | 0.0-1.0 (default 1.0) |
| `muted` | bool |
| `zoom` | 0.25-5.0 (web pages) |
| `allow_pinch_zoom` | bool |
| `pages` | int >= 1 (PDF) |
| `media_type` | -1 undefined, 0 web, 1 image, 2 video, 3 audio |

Files (beside `--assets_file`, default `/etc/unitotem/`; uploads in `/var/lib/unitotem/uploaded/`):
- `playlists.json`: `{"default": <id>, "playlists": {<id>: <path>}}`
- `playlist_<id>.json`: `{playlist_id, name, default_duration, assets: [...]}`
- `viewer_assignments.json`: `[{webview_id, screen_name, window_id, playlist_id}]` (`window_id` informative)
- `window_layouts.json`: `{version: 1, windows: {"<viewer>|<screen>": {area, tree, next_id, panes, ticker}}}`
- `viewer_settings.json`: per-window settings keyed `"<viewer>|<screen>"`

## Rules and gotchas

- The default playlist and the last playlist cannot be deleted; set another default first.
- `default_duration` is per playlist, applies only to assets with no duration. Never global.
- Empty-string dates mean "no date". `edit_asset` requires future datetimes; `add` accepts past dates, applied at once.
- Uploaded names pass `secure_filename`; a clash gets `_2`, `_3`... Only bare filenames in the uploads folder are referenced; no subfolders or parent paths.
- An asset is never shared between playlists: copies get a new uuid (a shared uuid would share timers and the current marker).
- The main pane's playlist is the window assignment, never stored in `window_layouts.json`.
- Remote viewers have no audio outputs; only the local viewer reports them.
- The idle page is the same for "playlist empty" and "window unassigned"; no separate path.
- Timers are per asset; `Asset.__del__` cancels them. `Timer` creates its task only when it has a timeout and a callback (no task otherwise); create assets with a running event loop when they carry dates.
- `edit_asset` treats `bg_color=None` as unchanged: the background colour cannot be cleared through it.
- In `api/viewers.py` the method `list` shadows the builtin inside the class body: annotations after it use `typing.List` (`list[str]` fails).
- Upload always goes to the default playlist, as disabled.

## Tests

- `python -m pytest manager/tests/test_playlists.py manager/tests/test_layout.py manager/tests/test_layout_controller.py manager/tests/test_asset_zoom.py` from the repository root.
- Related: `test_remote_transfer.py`, `test_remote_filecache.py`, `test_viewer_lockdown.py`.
- `test_asset_schedule.py`: scheduled enable/disable, save of a scheduled change, ownership, timer lookups.
- `test_layout_controller.py` covers playback and layout reconciliation (`WebviewManager` with a temporary `viewer_assignments.json`).
