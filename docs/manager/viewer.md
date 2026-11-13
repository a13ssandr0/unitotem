# Viewer

Local kiosk display of a node: one frameless fullscreen CEF window per output on labwc (Wayland), a Qt boot splash handed over to it, and a DevTools bridge that drives the pages. Package `unitotem-viewer` (needs `unitotem-manager` and `unitotem-node`). Manager side: `manager/webview/controller.py`.

Paths: relative to `unitotem-manager/`

## Files

| Path | Role |
|---|---|
| `manager/plugins/unitotem_viewer/__init__.py` | `PLUGIN`, `run_gui()`, headless wait, `request_quit()` |
| `.../app.py` | `WebviewApp`: Qt (outputs, splash), CEF init and switches, WebSocket client, command dispatch, window lifecycle, hand-off to pages, GPU profile |
| `.../window.py` | `WebviewWindow` (CEF Views top-level per output), `PageCommands`, CEF delegates, output wait (`_DisplayWatch`) |
| `.../cdp.py` | `Cdp`: DevTools client, page scripts, bindings, load and exception notifications, per-window language |
| `.../idle.py` | `IdleState`/`IdleWatch` (screensaver, idle refresh, scheduled refresh), `schedule_due()` (croniter) |
| `.../keys.py` | Key policy `decide()`: pass, block, reload |
| `.../language.py` | `default_language()`: LC_ALL, LC_MESSAGES, LANG, `/etc/default/locale`; fallback `en-US` |
| `.../profile_prefs.py` | Kiosk preferences merged into `<profile>/Default/Preferences` |
| `.../splash.py` | Qt splash per output, shown before CEF starts |
| `.../bootsplash.py` | Standalone first-frame process, run as a script, not as part of the plugin package (QtGui only, no QtWidgets, no UniTotem imports; plus Pillow and `sdnotify`) |
| `.../boot.py` | Stops `unitotem-splash.service` through D-Bus |
| `.../output_transform.py` | Standalone script: applies saved modes, turns and mirrors with `wlr-randr` |
| `.../wayland.py` | `socket_available()` |
| `.../static/boot-screen.html` | Page of every window (`?window=N`): containers, panes, layout, screensaver, keyboard, ticker hooks |
| `.../static/NotoSans.ttf` | Font of the page |
| `.../static/bootsplash/` | Plymouth PNGs, copied by `debian/rules`; without it `bootsplash.py` reads `plymouth/unitotem/` |
| `.../requirements.txt` | PySide6-Essentials, sdbus, croniter |
| `debian/unitotem-viewer.unitotem-compositor.service` | labwc unit |
| `debian/unitotem-viewer.unitotem-splash.service` | splash unit |
| `debian/labwc-rc.xml` | Base labwc config, installed as `/usr/share/unitotem/xdg/labwc/rc.xml` |
| `debian/10-wayland.conf` | Drop-in of `unitotem-manager.service`, shipped by `unitotem-node` |
| `manager/webview/controller.py` | `WebviewManager`, `PlaylistLoop`, `show_payload()`: playlist assignments, per-window settings |

## How it works
Boot (order set by the image build):
- Plymouth shows the theme. Compositor `ExecStartPre`: `plymouth deactivate` (5 s max), `/run/unitotem/xdg/output-pending`, empty node fragment of `rc.xml`.
- `ExecStart`: `labwc --merge-config` on tty1, `LIBSEAT_BACKEND=builtin`, `LANG=C`.
- `ExecStartPost`: waits up to 20 s for `wayland-0`, runs `output_transform.py`, clears tty1 and `/dev/fb0`, kills `plymouthd`.
- `unitotem-splash.service` starts in parallel: `bootsplash.py` waits for the socket and for `output-pending` to vanish (3 s max), draws one fullscreen window per output, sends `READY=1` 300 ms later. Ring: 1 s per turn, 60 steps.
- The viewer stops `unitotem-splash.service` (`boot.stop_boot_splash()`, D-Bus `StopUnit`) only after its own Qt splash (`splash.py`, same look) is on screen, never earlier.
- `unitotem-manager.service` starts after the compositor and `user@0.service`.

Viewer start (`run_gui`):
- Qt import fails, or cefpython3 is missing (`cef` is None in `app.py`): `ready('no viewer')`, returns False before any display check.
- No socket: `ready('no display')`, polls every 5 s until a display appears or shutdown.
- `WebviewApp.__init__`: `QT_QPA_PLATFORM=wayland`, `QT_NO_GLIB=1`; one splash per output, painted before return (3 s max); `stop_boot_splash()`; `ready('first frame on screen')`.
- Profile `/var/lib/unitotem/browser` (persistent); stale `Singleton*` locks removed. `profile_prefs.apply()` writes kiosk prefs and `intl.accept_languages`. HTTP cache `/var/cache/unitotem-cef` (RAM).
- `cef.Initialize`: `multi_threaded_message_loop=False`, `remote_debugging_port=9223`, locale `en-US`, context menu and downloads off, black background. GPU profile (`utils/system/gpu.py`) adds switches; explicit switches win.
- One window per real screen; zero screens is valid; `quitOnLastWindowClosed=False`.
- `WebviewWindow.show()`: waits for the `cef.Display` of the output name (observer when `Display.AddObserver` exists, else poll 150 ms x 40 = 6 s). Then a BrowserView on `boot-screen.html?window=N` in a frameless top-level, fullscreen on that display. After 6 s without a match the window is created unbound and goes fullscreen where the compositor places it.
- Page load end: queued JS flushed; navigation away from the page reverted; a reloaded page sends `WindowReloaded`.
- Renderer crash: reload after 200 ms, doubling, 10 s max. The new page has no keyboard focus: see Window and page.
- WebSocket client to `wss://localhost:<port_secure>/remote`, `instance_id=local-webview`, retry every 3 s. `WebviewInfo` sent on connect and on every screen or window change (debounced 100 ms).
- DevTools (`cdp.py`, asyncio thread): polls `/json/version`, attaches to page targets, enables Runtime, Page, Network, adds bindings, injects FOCUS, ACTIVITY, NO_PRINT, NO_DROP, CURSOR, FRAME_COOKIE scripts (`PAGE_SCRIPTS`), auto-attaches iframes. Target `?window=N` maps to window N. On page ready: keyboard, screensaver, ticker config re-applied, idle watch reset.
- Threads: commands go WS thread to Qt thread by `Signal`. `Cdp` and `IdleWatch` run on the asyncio thread.
- First frame: page calls `utFrame`; its splash leaves 300 ms later. Safety net: all splashes close after 20 s.
- Shutdown: `request_quit()` quits `exec()`, then `cef.Shutdown()`. If Qt ends the loop alone (compositor gone), `run_gui` raises `RuntimeError` so systemd restarts the service.

Runtime behaviour:
- Turn and mirror: `SetOrientation`/`SetFlip` update the window; `_turn_window` asks the compositor to transform the output (`unitotem_node.system.screens.wayland`) and updates the kernel command line (`boot_orientation`). On failure the page turns its content. `_OutputTurned` (seq-checked) sets `turned_by_output`.
- Idle: activity from `utActivity` (max 1/s per frame). Screensaver: after `idle_timeout`, `showSaver()`; `utSaver` `dismissed` ends it. Refresh after idle: `refreshPage()`, only for windows without screensaver. Scheduled refresh: each minute matching `refresh_schedules`, independent of idle.
- Keys: `keys.decide()` in `OnPreKeyEvent`; reload keys call `refreshPage()`.
- On-screen keyboard: page reports text focus per frame; text sent with `Input.insertText`/`dispatchKeyEvent`; field rectangle places the keyboard.
- The keyboard opens by itself when a text field gets focus in any frame and closes when focus leaves, unless the visitor opened it with the button; a `number` or `tel` field switches it to the numeric layout (`utKeyboard.focusChanged`).
- Screensaver layering (interactive windows): the home page is the base layer and `#stage` (playlist) an overlay hidden until idle, covering the whole window including the margin colour. A shield above everything swallows the first touch (it ends the screensaver) and stays a moment so the compatibility mouse events that follow do not reach the page. The keyboard layer is hidden under the screensaver.

Window and page:
- Window commands wait for the page LOAD (`_page_loaded`, set on `OnLoadEnd` of the main frame). `OnBrowserCreated` comes before the page exists: a `Show` sent there hit the blank document and was lost.
- A replaced renderer starts without keyboard focus (`document.hasFocus()` false). `SetFocus`, `RequestFocus` and `Activate` do not restore it: `refocus()` hides and shows the window, then activates and requests view focus (300 ms after the load). A plain reload keeps the focus.
- A window with no assigned playlist is parked on the idle page by the manager (`_send_idle`), never left on the boot logo. Window ids increase and are never reused: windows of a newly plugged screen match no assignment and get the idle page.
- Pages that are only looked at do not react to touch: `.pane.inert` (no pointer events, no touch action, no selection) is set by `Stage.show` for idle and boot assets; `body[data-inert]` hides the keyboard button and panel. A calibration overlay is built the same way: it reads raw panel events in the node.
- CEF paints opaque white before a document loads: the application and per-browser `background_color` are `0xFF000000`, so a new window shows no white flash.
- Occlusion handling is off (`disable-backgrounding-occluded-windows`, `disable-renderer-backgrounding`, features `CalculateNativeWinOcclusion` and `NativeWindowOcclusion`): Chromium otherwise stops painting a window covered by the Qt splash, the page never draws and the splash never leaves. The splash closes on the page's `utFrame`.
- DevTools bindings are window globals: `utSaver`, `utKey`, `utFocus`, `utActivity`, `utFrame`. Page functions must not reuse these names.
- Identify: `identify()` in `boot-screen.html` shows an overlay (`#identify`) over the whole content for 5 s: output name and `Screen N`. It is in the content, so it turns and mirrors with the page; it has no pointer events and does not end the screensaver.
- Screen labels: with more than one connected screen the idle pages (no-assets, first-boot) show `Screen N: <output>` under the IP. The address carries `?screen=<name>&index=<N>` and is served on loopback only (`/unitotem-{page}`). N is the screen's place in `WebviewInfo`, from 1. A change in the screen count sends the idle pages again. With one screen the pages are byte-identical to the earlier ones (golden fixtures in `manager/tests/fixtures/idle-pages`).

Profile and switches:
- Kiosk preferences (password manager, profile and card autofill, translation off; notifications, geolocation, popups blocked) are merged into `<profile>/Default/Preferences` by `profile_prefs.apply()` before `cef.Initialize`. CEF reads Chrome enterprise policies only when the application names a policy directory, which cefpython does not expose.
- cefpython has no `accept_language_list` setting (passing it raises `Invalid appSettings key` and crash-loops the manager). `locale` is `en-US`; the node language goes into the profile preference `intl.accept_languages`.
- `disable-web-security` needs an explicit `user-data-dir`, else Chromium logs an error and ignores the switch: `cache_path` is passed as `user-data-dir`.
- `disable-component-update` and `disable-background-networking` keep the persistent profile small (no unused component downloads, about 75 MB).
- `persist_session_cookies=True`: cookies without an expiry date (most logins) survive a browser exit. Cookies are credentials: the profile is not part of the backup.
- `enable-features=ResamplingInputEvents` turns on `InputEventPrediction` (Kalman predictor of pointer moves) so a dragged keyboard does not trail the finger.
- X-Frame-Options and `frame-ancestors` refusals are overridden by the `unitotem-allow-framing` switch of the patched CEF. `Fetch.enable` at the Response stage with `continueResponse` cannot do it: the out-of-process iframe target attaches only after the commit.
- Camera and microphone capture (`enable-media-stream`, `auto-accept-camera-and-microphone-capture`) is unverified on hardware.

GPU profiles and cost:
- `pi` sets `use-gl=angle` and `use-angle=gles` (ANGLE on Mesa GLES): without them the GPU process dies at start ("GLES3 is unsupported") and everything is software (7 fps against 44 fps on a Pi 4). It sets `webgl-antialiasing-mode=none`: default WebGL MSAA halves full-canvas redraw on the V3D (33 against 60 fps at about 1080p). `implicit` makes every `getContext()` return null while a `requestAnimationFrame` counter still runs. Video decode features stay out: see [cef.md](cef.md).
- `pi3` (device-tree model `Raspberry Pi 3*` or `Raspberry Pi Zero 2*`, DRM `vc4` without `v3d`) sets `disable-gpu`. VC4 (V3D 2.1) offers GLES 2.0 / GL 2.1 only; Chromium 147 requests an ES 3.0 context in the GPU process (`eglCreateContext ES 3.0 failed with error EGL_BAD_ATTRIBUTE`, `ES version fallback is disabled`) and ANGLE cannot emulate ES 3 on it, so hardware GL does not work on this chip. Measured on a Pi 3 B (Mesa 26.2, 1280x800, full-screen canvas 2D animation with 300 sprites, 20 s): `use-angle=gles`, `use-angle=gl-egl`, `MESA_GLES_VERSION_OVERRIDE=3.0` all end in `gl=disabled`, `gpu_compositing=disabled_software`, 16 fps at 182% of one core; `disable-gpu` gives the same result (`enable-low-end-device-mode` too) without the failing GPU-process starts and their error log; `use-angle=swiftshader` + `enable-unsafe-swiftshader` enables compositing/WebGL on the CPU but is slower (7 fps at 289%, WebGL 2 1.7 fps at 328%, 90 MB less free memory). An idle page costs about 2% of a core in every variant. Keep pages on the Pi 3 light (static layouts, few animated layers).
- Without a working GPU Chromium composites on the CPU (`gpu_compositing` disabled_software) and an idle kiosk costs about a core. This is not a busy loop and is fixed by the GPU (firmware, driver, `gpu.py` profile), not by the page. The cost of an animation grows with animated layers, surface and frame rate; compare before and after on the same machine only.
- `boot-screen.html` animates only `opacity` and `transform`: a paint-property animation (text-shadow glow, ring rotation) cost about 200 % of a core at 5120x2160 on software compositing. When a CSS rule seems not to apply, check `document.getAnimations()` or the computed style: equal specificity loses on source order (hence `.loader.halo::before`).
- Boot screen wordmark: `UniT`, two non-breaking spaces, `tem`; the gap holds a ring spinner (white ring, one arc `border-bottom-color: #FF3D00`, not the web UI blue) inside a pulsing `.glow` copy of the wordmark. No letter-spacing.
- Letterbox colour is the average of a 16x9 canvas (`getImageData(0, 0, 16, 9)`); a 1x1 downscale returned white on the Pi.
- Autoplay restarts media on `load()`: the page pauses media when the stage is hidden.

On-screen keyboard (`webui/src/keyboard.js`, loaded by the page):
- Keys type on RELEASE: `wireKeys` handles pointer events, simple-keyboard only draws. Key buttons cancel `touchstart` so the field keeps the focus, and a cancelled `touchstart` also cancels the synthesised click: use pointer events. CDP mouse tests hide this; test real touch with a uinput multitouch device. Long press (380 ms) opens the variants; backspace repeats; shift twice is caps lock.
- Drag changes only a `translate3d` of the panel; position and size are written at the end of the gesture (writing them on every pointer event relaid out the key grid). The pointer passes through a 1 Euro filter because a still finger plus input prediction jumped.
- Placement: a touch on a text field puts the keyboard just below the field (above when there is no room). The field rectangle comes from the frame focus script; for out-of-process frames `cdp._place_keyboard` finds the iframe with `DOM.getFrameOwner` and converts with `utKeyboard.placeNear`. A touch on a field that already has the focus reopens the keyboard: the `pointerup` re-report carries `touch` true and `_on_focus_changed` lets it through.
- Layout setting: a language id (`it`, `pt-BR`) or `lang/variant` (`de/de_neo2`); the old layout names still map to a language (`webui/src/keyboard-layouts.js`).
- Layouts come from AOSP LatinIME (Apache-2.0): `tools/keyboard/aosp_layouts.py` reads its tablet (`xml-sw600dp`) keyboards, more-keys tables and symbols pages into `webui/src/keyboard/` (one JSON per language, `symbols.json` shared, `NOTICE`). A PC-style number row from AOSP `pcqwerty` sits on top; `keyboard.js` stretches short rows to the full width and adds the arrow keys and the digit pad.

## Interfaces
Commands from the manager (`target`, `window_id`):

| target | fields | page call |
|---|---|---|
| `Show` | src, container, fit, bg_color, volume, muted, zoom, allow_pinch_zoom, idle, pane | `show(...)` |
| `SetAssetAudio` | volume, muted, pane | `setAssetAudio` |
| `SetWindowLayout` | area, tree | `setWindowLayout` |
| `SetTouchSetup` | state | `touchSetup` |
| `SetAudioOutput` | device | `setAudioOutput` |
| `SetOrientation` / `SetFlip` | orientation / flip | `setOrientation`, `setFlip` |
| `SetScreensaver` | enabled, home_url, idle_timeout | `applySaver`, `showSaver` |
| `SetRefresh` | refresh_after_idle, refresh_schedules | `refreshPage` |
| `SetKeyboard` | enabled, button_position, layout | `applyKeyboard` |
| `SetTicker` / `TickerItems` | config / items | `applyTicker` |
| `SetLanguage` | language, reload | `Emulation.*` overrides, `refreshPage` |
| `Identify` | screen_name (null = every screen) | `identify(name, caption, 5000)` |
| `AddWindow` | display, x, y, width, height | new window |
| `RemoveWindow` | window_id | close |

- `Show.container`: index into `boot, web, image, video, audio` (-1 = page probes). `fit`: `contain, cover, fill`. `zoom` clamped 0.25 to 5.0 (also in the page, since it ends in a division). `pane` None = main pane. `allow_pinch_zoom` (default off) becomes `touch-action` on the pane frame, intersected with the content's own `touch-action`: `pan-x pan-y` forbids pinch whatever the page says; `auto` leaves it to the page.
- Outgoing `WebviewInfo`: `screens[{index,name,x,y,width,height}]`, `windows[{window_id,screen_name,x,y,width,height,orientation,flip,turned_by_output}]`, `layout: true` (viewers without it are driven as one pane). Outgoing `WindowReloaded {window_id}`.
- Incoming frames: JSON, or `b64(json).b64(signature)`.
- Env: `WAYLAND_DISPLAY` (default `wayland-0`; absolute or relative to `XDG_RUNTIME_DIR`); `XDG_RUNTIME_DIR` (default `/run/user/0`); `UNITOTEM_NO_SCANOUT_BUFFERS` (set by the viewer with `setdefault` on the `pi` GPU profile); `UNITOTEM_CEF_SWITCHES` (`name=value;name2`); `JOURNAL_STREAM` (log lines prefixed `<4>`).
- Paths: `/run/unitotem/xdg/wayland-0`; `/run/unitotem/xdg/output-pending`; `/run/unitotem/labwc/node/labwc/rc.xml` (touch mapping fragment); `/usr/share/unitotem/xdg/labwc/rc.xml`; `/var/lib/unitotem/browser`; `/var/cache/unitotem-cef`.
- `output_transform.py [CONFIG_DIR]` (default `/etc/unitotem`): reads `viewer_settings.json` keys `modes` (applied only when the compositor lists the mode), `orientations`, `flips`, indexed `<viewer id>|<output name>` (`local-webview|<output>`); the mode and the transform of all outputs go in one `wlr-randr` call. Always exits 0. `viewer_settings.json` sits beside `assets.json` (`--assets_file`, default `/etc/unitotem/assets.json`).
- Constants: CDP port 9223 (loopback); `APP_ID=org.unitotem.viewer`; window title `unitotem-<window_id>`; `SPLASH_MAX_MS=20000`; `PRESENT_MS=300`.
- Screensaver `idle_timeout`: 5 to 86400 s, default 120. Refresh: 10 to 604800 s. Schedules: five cron fields.
- Language tag: `[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}`, max 35 chars. Stored in `viewer_settings.languages[<viewer>|<output>]`; `''` = node language.
- GPU profiles (`utils/system/gpu.py` `PROFILES`): `unknown`, `software` (no extra switches), `nvidia`, `vaapi`, `v4l2`, `pi`, `pi3`. Selected by `detect_gpu()`.
- Notifications: `viewer.load.<window>` (warning, audience scheduler) when a page cannot load; `viewer.page.<window>` (error, audience admin) for exceptions in the viewer's own `file://` page.
- systemd: `unitotem-compositor.service` (Type=simple, Restart=always, RestartSec=3, TTYPath=/dev/tty1, RuntimeDirectory=unitotem); packaged disabled, the image enables it. `unitotem-splash.service` (Type=notify, NotifyAccess=main, TimeoutStartSec=120). `unitotem-manager.service` (Type=notify, TimeoutStartSec=300).
- D-Bus: `org.freedesktop.systemd1.Manager.StopUnit(unitotem-splash.service, replace)`.
- Exit: `run_gui` returns False (no libraries), True (shutdown while waiting), raises `RuntimeError` (display lost). `bootsplash.py` exits 1 without socket after 120 s.
- Notable switches: `ozone-platform=wayland`, `remote-debugging-address=127.0.0.1`, `user-data-dir`, `disable-web-security`, `allow-file-access-from-files`, `unitotem-allow-framing`, `ignore-certificate-errors-spki-list` (own certificate), `ignore-certificate-errors` (only with `allow_insecure_certs`), `enable-media-stream`, `auto-accept-camera-and-microphone-capture`, `deny-permission-prompts`, `hide-scrollbars`, `enable-features=ResamplingInputEvents`, `disable-background-networking`, `disable-component-update`.
- Key policy: F5 and Ctrl+R reload; F1 to F24 blocked; Alt combinations blocked; Ctrl+A/C/V/X/Y/Z and editing keys pass; other Ctrl combinations blocked; Ctrl+Shift+editing letter blocked except Ctrl+Shift+Z. Plain keys and Shift combinations pass.

## Rules and gotchas
- Compositor runs `LANG=C`: labwc reads touch matrices with `strtof`; a decimal comma drops the matrix.
- Plymouth: `plymouth deactivate`, never `plymouth quit` (puts the VT in text mode, console repaints over the frame).
- `multi_threaded_message_loop` stays False on Linux (Windows-only: a no-op here, nothing pumps CEF, blank page). `external_message_pump=True` made no measurable difference. CEF is pumped by a 10 ms QTimer with `cef.MessageLoopWork`; `QT_NO_GLIB=1` avoids a full-core spin.
- Shutdown: CEF resets SIGINT to `SIG_DFL` and blocks it in its threads, so only SIGTERM reaches the Python handler; the unit must not set `KillSignal=SIGINT`. A 200 ms `QTimer` with a no-op slot forces CPython to re-enter bytecode so signal handlers run; without it SIGTERM shutdown hangs until systemd SIGKILL.
- `bootsplash.py` exits with `os._exit(0)` on SIGTERM and SIGINT (Qt Wayland teardown segfaults); it runs as a `Type=notify` unit.
- Boot picture is one picture in three places (Plymouth theme, `bootsplash.py`, Qt splash through `bootsplash.artwork()`): change artwork only in `plymouth/generate-assets.py`.
- labwc keeps its default keybinds and mousebinds only while the config has no entry of its own: `debian/labwc-rc.xml` carries an inert keybind `W-F24` and a Root Press mousebind on Left so the file is never empty. An empty `<name>` element is a labwc error.
- Showing a Qt window is not painting it: the splash waits for the paint before the previous frame goes.
- A window is a CEF Views top-level; CEF cannot be embedded in a Qt window on Wayland.
- `bootsplash.py` must not import the rest of UniTotem (runs as a script, starts in under a second).
- Qt must not quit on last window closed: a node with no screens keeps running.
- Browser profile survives reboots and updates; the cache stays in RAM.
- Browser security notices (framing, mixed content, CSP) are not reported, only load failures.
- Framing refusals are overridden only by the patched CEF (`unitotem-allow-framing`); `UNITOTEM_NO_SCANOUT_BUFFERS` also needs the patched build (see [cef.md](cef.md)).
- Screensaver windows are interactive: idle refresh skips them; scheduled refresh applies.
- Turn: the compositor turns the output when it can; the page is the fallback. `turned_by_output` tells the page which.
- Language: window choice overrides node language; the node language is written into the profile at every start.
- The page is `file://`; `disable-web-security` is deliberate (scheduled images are drawn into canvases for the average colour).
- Pages cannot open popups or print; `window.print` is a no-op; drops are cancelled unless the page handles them.
- Mouse pointer (`CURSOR_SCRIPT`, every frame): hidden from the start of each document, shown on the first `pointermove` of type mouse, hidden `CURSOR_HIDE_MS` (10 s) after the last one; a touch never shows it. The script runs before the document has a root element (`document.head` and `documentElement` are `null`), so the style is mounted by a `MutationObserver` as soon as one exists; mounting it at once threw `Cannot read properties of null (reading 'append')` and left the pointer visible from boot (found with DevTools on a Pi 3: the exception in the page). Test: `manager/tests/test_viewer_cursor.py` (Node, fake document).
- A page in a frame is cross-site to the window document, so the browser rejects a cookie it writes without `SameSite` (default Lax). The `document.cookie` setter of https frames adds `SameSite=None; Secure` to a cookie with no SameSite of its own (`FRAME_COOKIE_SCRIPT`). Measured on a Pi 3 with a university timetable monitor page (the page keeps its language in such a cookie and reloads itself when the cookie is missing): 11 reloads in 40 s (a reload every 3.5 s, the renderer at 100% of a core) before, none in 50 s after. Cause found with DevTools: `Network.requestWillBeSent` initiator stack (script and column) of the Document request, and `Network.getCookies`.

## Tests
- `python -m pytest manager/tests/test_viewer_profile.py manager/tests/test_viewer_lockdown.py manager/tests/test_viewer_turn.py manager/tests/test_output_transform.py manager/tests/test_identify_pages.py` (repository root).
- `manager/tests/test_touch_panel.py` also imports viewer code. `debian/tests/unit` runs the whole suite.
- Not unit tested: `app.py`, `window.py`, `cdp.py`, `bootsplash.py`, `splash.py`. These need a board with a compositor (`tools/cef-wayland-tests/`, `tools/ui-panes.py` for the page).