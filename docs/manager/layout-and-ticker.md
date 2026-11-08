# Window layouts and RSS ticker

Per-window layout (content area and pane tree) and the RSS news bar. Both are stored per window in `window_layouts.json`. Feeds are global. Configuration is admin-only in the web UI.

Paths: relative to `unitotem-manager/`

## Files

| Path | Role |
|---|---|
| `manager/utils/models/layout.py` | `Area`, `Leaf`, `Split`, `WindowLayout`; pure tree ops (`split_leaf`, `close_leaf`, `set_ratio`, `set_area`, `with_pane_playlist`); store `WindowLayouts`, singleton `window_layouts` |
| `manager/utils/models/ticker.py` | `TickerSettings`, `TickerSelect`, `TickerClock`, `TickerSource`, limits, colour and URL checks |
| `manager/utils/ticker/__init__.py` | Lazy singletons `store()`, `service()`, `windows()` |
| `manager/utils/ticker/feed.py` | RSS 2.0, RSS 1.0, Atom bytes to plain items; strips markup, caps lengths |
| `manager/utils/ticker/fetcher.py` | One conditional HTTP GET (ETag, Last-Modified), timeouts, size and redirect caps |
| `manager/utils/ticker/store.py` | Sources file, cache file, merge and dedup |
| `manager/utils/ticker/service.py` | Scheduler: one asyncio task, event driven |
| `manager/utils/ticker/push.py` | Events to windows: `SetTicker`, `TickerItems` |
| `manager/utils/ticker/windows.py` | Read and write of a window's bar (`WindowLayout.ticker`) |
| `manager/api/ticker.py` | `Ticker/*` WebSocket API; `start()` called from `manager/main.py` |
| `manager/api/viewers.py` | Layout API (`Viewers/layout`, `set_area`, `split_pane`, `close_pane`, `set_split_ratio`) |
| `manager/webview/controller.py` | `_commit_layout`, `_push_layout`, `_wanted_playlists`, `_sync_window`, `_supports_layout` |
| `manager/utils/backup.py` | Backup parts `layouts`, `ticker` |
| `manager/plugins/unitotem_viewer/app.py` | `SetWindowLayout`, `SetTicker`, `TickerItems`, `_apply_ticker` |
| `manager/plugins/unitotem_viewer/static/boot-screen.html` | `#area`, `#ticker-host`, `setTickerPlacement()`, `applyTicker()` |
| `webui/src/ticker-core.js` | Pure logic: template parser and renderer, time formats, selection, geometry |
| `webui/src/ticker.js` | Page module (Vite entry), exposes `window.utTicker` |
| `webui/src/components/WindowLayout.vue`, `PaneTree.vue` | Layout and panes section of the window dialog (`ViewerDetail.vue`, opened from a window name on the Viewers page) |
| `webui/src/components/TickerSettings.vue`, `TickerSources.vue` | Bar settings with preview and template presets (window dialog, administrators); feed sources (Viewers page, administrators) |
| `tools/ticker/` | Test page, feed server, board scripts (test helpers, not shipped) |

## How it works
Layout:
- A window is `area` (percent rectangle, content space) plus `tree` (splits and leaves). Each leaf is a pane with one playlist.
- First leaf in tree order is the MAIN pane. Its playlist is the window assignment, never stored in `panes`.
- Operations are pure: they return a new validated `WindowLayout`. The controller stores it, sends `SetWindowLayout`, reconciles playlists (`_sync_window`).
- Split: the pane keeps its id; the new pane gets `next_id`, goes right (`h`) or below (`v`).
- Close: the sibling takes the parent's place. Closing the main pane promotes the next leaf; its playlist becomes the assignment.
- No entry = default layout (one pane, full area). A default layout with default ticker is not stored.
- `area` exists because under Wayland the compositor owns window geometry: the content rectangle is a page property set from the web UI (for example the middle third of a tall vertical panel).
- Area, panes, screensaver overlay and keyboard live in content space, so a window turned by content orientation or by the compositor (`wlr-randr --transform`, orientation stays 0) lays out the same.
- Page contract for panes: flat, absolutely positioned percent children of `#panes`; never nest them or move one to another parent (the iframe or video would reload). A surviving pane keeps playing through splits, closes and splitter drags; stages of closed panes are destroyed.
- The page sanitises what the manager sends (areas clamped, invalid tree ignored and the old one kept). A `Show` for a pane the layout has not created yet is kept, latest per pane, until the next layout. A new pane starts blank and the manager parks it on the idle page.
- Sound output is per window for all panes; a video's volume is per asset.
- Access: the area, split and close controls and the ticker settings are for administrators and hidden for the others. Pane playlists are changed with `assign_playlist` (scheduler permission).
- Editor hint above 4 panes: on a Pi 4 videos are decoded by the CPU (about four 720p videos at once); still pictures and static web pages cost about 1 % of a core per pane. The editor cannot detect video.

Ticker:
- `TickerService.run()` sleeps until the earliest `next_due` or until poked (safety wake-up 3600 s). Due sources are fetched, 4 at a time.
- Success: items replaced, ETag and Last-Modified kept, `next_due = now + interval`. HTTP 304: timestamps only.
- Failure: retry after 60 s, doubling per consecutive failure, capped at the source interval.
- A source deleted or re-addressed while its fetch is in flight: the answer is dropped, nothing is recorded or notified for it.
- Admin notification `ticker.source.<id>` after 2 consecutive failures (link `/viewers`). Resolved on success, disable or delete.
- Merge: enabled sources, dedup by link (else `source.id:item.id`), newest first, cap 500. Items without a date get the first-seen time. On equal time the first listed source wins.
- `on_items` fires only when the merged list changes. `on_status` fires on source state changes (administrators only).
- To windows: `items_changed` to every window with the bar on; `window_appeared` on creation; `refresh_all` after restore or reset; `set_settings` to the edited window.
- Page: `applyTicker()` receives `window.__utTickerConfig` and `__utTickerItems` by DevTools evaluate, loads the `ticker` entry once the bar is on, calls `utTicker.update(cfg, items)`.
- The page selects headlines each cycle with the device clock (`count`, `today`, `range`); one timer for the next expiry, no polling.
- Crawl: each lane recycles pages. A page is one element with consecutive headlines and one linear `transform` Web Animation; pages chain by `startTime` on `document.timeline`. Max 8192 px per page, 3 pages ahead per lane, pool of 4.
- Any CSS or JS animation has a fixed compositor cost per animated layer in this CEF on Wayland (60 fps compositing plus an empty `BeginMainFrame` per frame), even one empty animated div: do not chase that cost in the ticker code. The animated boot page also caps a Pi 4 page at about 40 fps and uses about 85 % of a core: measure Pi performance on a static page (`tools/ticker/board-static-page.py`).
- Bar height is `--ticker-h` on `#area`; 0 px when nothing is selected and no clock is shown.
- Resize or rotation (ResizeObserver) rebuilds the lanes; the crawl restarts pre-filled.
- A change of the headline list never touches pages already built in a lane; only pages not yet built use the new list, so the crawl never jumps or repeats.
- At fractional pixel offsets the composited layer is bilinearly resampled, so text is slightly softer while the bar moves. Accepted: rounding positions from script caused 1/2 px steps.

## Interfaces
`Ticker/*` WebSocket API (admin):

| Method | Arguments | Notes |
|---|---|---|
| `sources` | none | `{sources}`: public fields plus `items`, `last_ok`, `last_try`, `error`, `fetching` |
| `add_source` | `url`, `name=''`, `interval=900`, `enabled=true` | |
| `edit_source` | `id`, optional `url`, `name`, `interval`, `enabled` | omitted or null = unchanged; new URL refetches now |
| `enable_source` | `id`, `enabled` | |
| `delete_source` | `id` | |
| `fetch_now` | `id?` | all enabled sources if omitted |
| `preview` | none | `{items, at}`: merged list |
| `settings` | `viewer_id`, `window_id` | `{settings}` |
| `set_settings` | `viewer_id`, `window_id`, `settings` | numbers clamped; other errors refused, nothing changes |

Pushes `Ticker/sources` and `Ticker/settings` go to administrator sessions only.

`Viewers/*` layout API:

| Method | Arguments | Permission |
|---|---|---|
| `layout` | `viewer_id`, `window_id` | scheduler |
| `set_area` | `viewer_id`, `window_id`, `left`, `top`, `width`, `height`, `margin_color` | admin |
| `split_pane` | `viewer_id`, `window_id`, `pane_id`, `direction` (`h`/`v`) | admin |
| `close_pane` | `viewer_id`, `window_id`, `pane_id` | admin |
| `set_split_ratio` | `viewer_id`, `window_id`, `path` (string of `a`/`b`), `ratio` | admin |
| `assign_playlist` / `unassign_playlist` | `viewer_id`, `window_id`, `playlist_id`, `pane_id?` | scheduler |

Manager to page (`send_webview_command`), layout-aware viewers only (`layout: true` in `WebviewInfo`):
- `SetWindowLayout {window_id, area, tree}`
- `SetTicker {window_id, ...TickerSettings}` (also on a settings change from the web UI: `Ticker.set_settings` checks `_supports_layout` first)
- `TickerItems {window_id, items: [{time, source, title, summary, link}]}`; `summary` empty unless the template contains `{summary`
- `Show {pane}`, `SetAssetAudio {pane}`

Files (beside `assets.json`, `--assets_file`, default `/etc/unitotem/`):

| File | Content | Backup |
|---|---|---|
| `ticker_sources.json` | `{version: 1, sources: [TickerSource]}` | part `ticker` |
| `window_layouts.json` | `{version: 1, windows: {"<viewer id>\|<screen name>": WindowLayout}}`; bar inside as `ticker` | part `layouts` |
| `/var/lib/unitotem/ticker-cache.json` | `{version: 1, sources: {id: {items, etag, last_modified, last_ok}}}` | never |

`TickerSource`: `id` (12 hex), `name` (max 80), `url` (http/https, max 2048), `interval` (60 to 86400 s, default 900), `enabled`. Max 50 sources.

`TickerSettings`:

| Key | Type or range | Default |
|---|---|---|
| `enabled` | bool | false |
| `position` | `top` / `bottom` | `bottom` |
| `mode` | `overlay` / `reserve` | `reserve` |
| `rows` | 1 / 2 | 1 |
| `font_size` | percent 1-15 (of the smaller window side) or px 8-400 | 3.0 |
| `font_unit` | `percent` / `px` | `percent` |
| `color`, `background` | CSS colour | `rgb(255,255,255)`, `rgba(0,0,0,0.85)` |
| `speed` | em/s, 0.25-10 | 2.5 |
| `separator` | max 20 printable chars | `   •   ` |
| `template` | 1-500 chars, no control chars | `[b]{time:HH:mm}[/b] - {title}` |
| `select` | `{mode: count/today/range, count: 1-500, seconds: 60-2592000}` | count 20, 7200 s |
| `clock` | `{enabled, position: start/end, seconds, date, rows: 1/2}` | off |
| `locale` | BCP 47 tag or empty (device locale) | empty |

Layout limits: area at least 5 % each way and inside the window; max 8 leaves; depth max 4; split ratio 0.1-0.9; pane ids unique, never reused; `panes` holds playlists of existing non-main panes only.

Template language:
- Fields: `{time:FMT}`, `{title}`, `{source}`, `{summary}`, `{link}`. `{{` and `}}` are literal braces.
- `FMT`: LDML (`HH mm ss hh a dd MM MMM MMMM EEE EEEE yyyy yy`) or strftime when it contains `%`; formatted in the window locale.
- Text spec `[[fill]<|>|^][width][.precision]`; conversions `!u` upper, `!l` lower, `!t` title, `!c` capitalise.
- Markup (Rich style): `bold dim italic underline strike reverse overline` (short `b d i u s r o`), `not <flag>`, colours (`red`, CSS names, `bright_red`, `#rgb`, `#rrggbb`, `rgb(r,g,b)`, `color(0-255)`), `on <colour>`. `[/]` closes the last tag, `[/name]` the nearest match, `\[` escapes. `[link]` and `[@...]` are refused.
- The editor offers 12 template presets (`TickerSettings.vue`).

## Rules and gotchas
- Numbers are clamped, never refused: a bar must not make a screen unusable.
- Refused with a message: non-http(s) or invalid URL, invalid colour, empty or over-long template, control characters, bad locale tag, more than 50 sources, duplicate URL.
- Ticker colours: `#hex`, `rgb/rgba/hsl/hsla` with plain numbers, or a colour name. No `url()`, `var()`, `;`.
- Layout `margin_color` is stricter: `#` hex (3-8 digits) or `rgb()`/`rgba()`; anything else becomes `rgb(0,0,0)`.
- Feed content is untrusted: markup stripped, control chars replaced, lengths capped (title 300, summary 400, link 1000, id 300), 500 entries per feed, only http/https links.
- Feed text is never parsed as template markup; the page draws it with `textContent`.
- `feed.py` hands `feedparser` an `io.BytesIO`, never the bytes (a bytes argument is opened as a file name).
- Fetch: http/https only, 25 s total timeout, 10 s connect, 5 redirects, 2 MiB body. Errors are short texts, never exception strings.
- Feed fetching has no private-address or loopback checks, by design: configuration is admin-only and only `http`/`https` schemes are accepted.
- An invalid bar template never breaks the bar: `parseTemplate` falls back to a plain title field and returns the error, which the settings dialog shows.
- Viewer setting `allow_insecure_certs` disables TLS verification for feeds.
- Changing a source URL drops its cache. Enabling a disabled source fetches it at once. Future-dated entries are clamped to now.
- Sources file and cache carry `version`; every field is optional on read, so a rollback reads a newer file.
- The cache is state, not configuration: not in the backup.
- Speed is in em/s, readable at any resolution. Rationale for range and default is in `manager/utils/models/ticker.py`; change only with new evidence.
- The crawl is moved by the compositor only. Never move it from JavaScript per frame, never use `steps()`, never round positions (judder and frame loss on a busy main thread).
- Page contract: `#area` contains `#panes` and `#ticker-host`; `#area[data-ticker]` and `[data-ticker-pos]` set placement; the bar sets `--ticker-h`. Nothing outside `#area` is touched.
- Letterbox colour of a picture: see [viewer.md](viewer.md) (16x9 canvas average).
- Viewers without `layout: true` get no layout messages and are driven as one pane (`_supports_layout`).
- The main pane's playlist is never in `panes` (`with_pane_playlist` refuses it).
- Restore of `layouts` replaces all window layouts and re-pushes them; restore of `ticker` replaces sources and refreshes all bars.
- Removing a viewer drops its windows' layouts; their playlists stay.
- `feedparser` is required; without it sources report "The feedparser library is not installed".
- The clock is static text; its minimum width never shrinks, so digits do not jitter the lanes.

## Tests
- `.venv/bin/python -m pytest manager/tests/test_layout.py manager/tests/test_layout_controller.py manager/tests/test_ticker_models.py manager/tests/test_ticker_feeds.py manager/tests/test_ticker_service.py` (feed tests use local HTTP servers, service tests a fake clock).
- `cd webui && npm test` (`webui/tests/ticker-core.test.mjs`; `webui/tests/viewer-core.test.mjs` for the window list of `ViewerCore.js`).
- `.venv/bin/python tools/ui-ticker.py [--shots DIR]`: headless Chrome against `tools/ticker/testpage.html` (needs `google-chrome`, `websockets`).
- `python3 tools/ticker/feedserver.py [port]`: dated, large, hostile and slow feeds for manual trials.
