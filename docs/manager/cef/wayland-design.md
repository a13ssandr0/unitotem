# CEF on Wayland: Views windows, per-output fullscreen

Status 2026-10-21. Branch `viewer-wayland`. Code: CEF patch series `tools/cef-server/patches/cef/` (against CEF
`d58e84d17`, Chromium 147.0.7727.118), cefpython branch `wayland-views` of `a13ssandr0/cefpython` (what this repository builds) and
`wayland-views-pr` (the same work in 3 commits on top of `linesight/cefpython147-qt`, for a PR), tests `tools/cef-wayland-tests/`. Draft PR texts:
`pr-cef.md`, `pr-cefpython.md`.

## Why

The kiosk runs labwc (Wayland only). cefpython opened browsers with `WindowInfo()`, which CEF implements natively for X11 only
(`CefBrowserPlatformDelegateNativeLinux::CreateHostWindow` is `#if BUILDFLAG(SUPPORTS_OZONE_X11)`). On the Wayland Ozone backend the
result is a Chrome-style window (a real Chromium `Browser`) with an empty `app_id` and title that `CloseBrowser()` never destroys
(measured: `wlrctl toplevel list` shows `:` before and after `CloseBrowser(True)`, `OnBeforeClose` never fires, the toplevel only goes
at `Shutdown()`). The viewer therefore opened windows through DevTools (`Target.createTarget newWindow`) and placed them on their
output with a labwc key binding pressed through a uinput keyboard.

CEF's supported way to get a frameless, UI-less, closable top-level window that works on every Ozone platform is the Views framework
(`CefWindow::CreateTopLevelWindow`, `CefBrowserView::CreateBrowserView`). cefpython had no bindings for it.

## What was built

1. **cefpython Views bindings** (`src/views.pyx`, `src/display.pyx`, `src/client_handler/views_delegate.*`, `src/extern/cef/cef_views.pxd`):
   `cef.Window`, `cef.Panel`, `cef.View`, `cef.BrowserView`, `cef.Display`, Python window/browser-view delegates (object with optional
   methods named like CEF's: `OnWindowCreated`, `OnWindowDestroyed`, `CanClose`, `IsFrameless`, `GetInitialBounds`,
   `GetInitialShowState`, `GetLinuxWindowProperties` -> `wayland_app_id`, ...). Documented in `vendor/cefpython/api/{Window,BrowserView,View,
   WindowDelegate,Display}.md`.
2. **CEF patches** (`tools/cef-server/patches/cef/`, one concern per patch):
   - 0001 frameless windows and X11 assumptions on Ozone/Wayland: `remove_standard_frame` on Wayland (upstream issue
     chromiumembedded/cef#4273, PR #4274 is open for the same thing), and the X11-only window handling in `CefWindowView::CreateWidget`/
     `WindowClosing` (`ui::SetUseOSWindowFrame`, transient-for/modal properties) is skipped on Wayland; `IsRunningOnWayland()` moves to
     `view_util` (what the maintainer asked for in #4274).
   - 0002 `CefWindow::SetFullscreenOnDisplay(int64 display_id)`.
   - 0003 `CefDisplay::GetLabel()`.
   - 0004 `CefWindow::GetDisplay()` on Wayland uses the entered output instead of matching the window bounds.
   - 0005 ceftests.
   - 0006 `CefDisplayObserver` and `CefDisplay::AddObserver/RemoveObserver` (independent of 0001-0004).
3. **cefpython**: `ozone-platform` is chosen automatically (wayland when `WAYLAND_DISPLAY` is set and `DISPLAY` is not, X11 otherwise,
   overridable), `GDK_BACKEND=x11` is no longer forced in a pure Wayland session, the `SetAsChild` warning is accurate,
   `CreateBrowserSync()` with a parentless `WindowInfo` on Wayland opens a Views window and closes it with the browser.

## Per-output fullscreen (B): findings

* `views::Widget::SetFullscreen(bool, int64_t target_display_id)` exists; `WaylandToplevelWindow::SetFullscreen` passes
  `GetWaylandOutputForDisplayId(id)` to `xdg_toplevel.set_fullscreen(wl_output)`. Windows and macOS widgets take the id too (CEF does not use it there, by decision). **X11
  does not** (`X11Window::SetFullscreen` has `DCHECK_EQ(target_display_id, kInvalidDisplayId)`, crbug.com/40111909), so the CEF API
  falls back to `SetFullscreen(true)` there.
* CEF's `CefWindow::SetFullscreen(bool)` had no way to pass it, and `CefWindowImpl::SetFullscreen` returns early when the window is
  already fullscreen, hence a new method (experimental API, `CEF_EXPERIMENTAL`; `CEF_NEXT` if the maintainers want it stable).
* It works before `Show()`: calling it in `OnWindowCreated` puts `set_fullscreen(wl_output)` on the wire for the very first configure
  (`WAYLAND_DEBUG`: `xdg_toplevel#47.set_fullscreen(wl_output#32)` then `configure(1024, 768, ...)`).
* **labwc ignores the output of `set_fullscreen` for a toplevel that is already fullscreen** (measured: after an unplug/replug the
  request went out and nothing came back). The CEF implementation leaves fullscreen first when the window must move.
* Display ids: Chromium's display id on Wayland is the registry name of the `wl_output` global (49, 50, ...). It **changes when the
  output is unplugged and plugged back** (51, 52, ...), so applications look the display up again by name after a hot-plug.
* The output name (`DP-1`) is not in `display::Display`; Chromium has it (`zxdg_output_v1.name`, `WaylandOutput::Metrics::name`) but only
  the `wl_output` description reaches `Display::label()`. wlroots compositors end the description with `(NAME)` (`"Invalid Vendor Codename
  - RTK FHD demoset-1 (DP-2)"`, `"(null) (null) (HDMI-A-1)"`, and `"... (DP-1 via Unknown)"` for some connectors), so `CefDisplay::GetLabel()`
  + `cef.Display.FindByOutputName(name)` resolve a connector name; other compositors can match on bounds.
* A Wayland client does not know where its toplevel is in the global space: `Window.GetClientAreaBoundsInScreen()` starts at 0,0, and
  `CefWindowView::GetDisplay()` (match by bounds) reported the first output for a window on the second: fixed in 0004.

### Hot-plug timing and the display observer

Right after `wlr-randr --output DP-1 --on` Qt knew the output at once, but `cef.Display.FindByOutputName("DP-1")` returned None for a moment
(found by the viewer integration): Chromium's display list follows the `wl_output` global and its description events, and a window made
then went fullscreen on the other output. The viewer polled up to 6 s. Options considered on the CEF side:
1. `SetFullscreenOnDisplay` waiting for an unknown id: rejected (it would block or defer on an id that may never appear and hide errors).
2. A display observer: implemented as patch 0006, `CefDisplayObserver` (`OnDisplayAdded`, `OnDisplayRemoved`, `OnDisplayMetricsChanged`) with
   `CefDisplay::AddObserver/RemoveObserver`, a thin wrapper of `display::DisplayObserver` (`ScopedOptionalDisplayObserver`: a removal after the
   `display::Screen` is gone is harmless). cefpython: `cef.Display.AddObserver(obj)` (`examples/views_hotplug.py`).

Measured on an Intel Iris Xe PC (amd64) (labwc, `tools/cef-wayland-tests/observer_hotplug.py`, `wlr-randr --output DP-2 --off` then `--on`, 6 runs; times from the
start of the wlr-randr command): `OnDisplayRemoved` after 184-219 ms, `OnDisplayAdded` after 211-228 ms, `FindByOutputName` already finds the
display inside the callback (6/6), the new window is created 7-8 ms after the callback, on the right output, fullscreen. No polling.
(The numbers are those of one board and one compositor.)

## D. The Alloy "native" Wayland gap: recommendation

Do **not** implement a Wayland version of the native windowed path (`CefWindowX11` equivalent). The Views framework is the supported
path (maintainer, issue #2804: "the Views framework is required"), it already provides what a Wayland application needs, and upstream
is working on embedding in third party Wayland applications (subsurfaces) in #2804 as a separate feature. Changing
`CloseHostWindow` or `ChromeBrowserHostImpl` so that the Chrome-style window created for a parentless `WindowInfo` is destroyed by
`CloseBrowser()` is not a small change: the window belongs to a real Chromium `Browser`/`BrowserView` whose lifetime Chrome style owns
(`OnBeforeClose` only fires when the whole `BrowserList` is torn down at shutdown). Instead cefpython (not CEF) maps a parentless
`WindowInfo` on Wayland to a Views window whose delegate closes the window when the browser is destroyed: measured
(`tools/cef-wayland-tests/old_windowinfo.py`) `before close: [':']`, `after CloseBrowser: []`, `OnBeforeClose` fired.
Embedding into a foreign window (`SetAsChild(handle)`) stays X11/XWayland only.

## Test evidence

All on the real boards with the real compositor (labwc 0.8.3), pure Wayland (no X server), CEF 147 built from source with the patches.

| test | Intel Iris Xe PC (amd64, DP-1 640x480 forced + DP-2 1920x1080) | Raspberry Pi 4 (V3D, arm64, HDMI-A-1/2 forced) |
|---|---|---|
| `outputs.py --hotplug`: one frameless window per output, fullscreen on its output, sizes, app_id, off/on, move back, close | 18/18 PASS (19 in the last runs) | 18/18 PASS (forced connectors, no monitor attached at that time) |
| `observer_hotplug.py`: windows follow `OnDisplayAdded/Removed` | all PASS (9 checks, 8 runs) | not run (one real output; a second connector cannot be forced on the image: `force` is accepted, the status stays disconnected) |
| `observer_metrics.py`: `OnDisplayMetricsChanged` on `wlr-randr --mode` | not run | PASS: 69 ms (1280x720) and 73 ms (back to 1920x1080) after the command, with a window open; with NO window open Chromium's display list did not change at all and no event came |
| ceftests `Views*` (`--ozone-platform=wayland`) | 105 pass, none fail (includes `WindowFullscreenOnDisplay`, `DisplayObserverAddRemove`) | 105 pass, none fail (arm64 binary) |
| `outputs.py` on the real output (one output: window fullscreen on it, size, app_id, GetDisplay, close) | 19/19 with two outputs | 9/9 (HDMI-A-1, a 1920x1080 HDMI sink) |
| `views_test.py` | OK | OK (image's compositor, aarch64 cp313 wheel with the observer, Python 3.13) |
| `views_test.py` (cefpython unit test) | OK on Wayland and on X11 (the backend is chosen from the environment) | not run (Raspberry Pi 4 reserved) |
| doc example `api/Window.md` verbatim | works | - |
| `old_windowinfo.py`: parentless WindowInfo, CloseBrowser | window closes, `OnBeforeClose` | - |

`WAYLAND_DEBUG=1` on the Raspberry Pi 4: two toplevels, `set_fullscreen(wl_output#32)` / `(wl_output#34)`, `configure(1024, 768)` / `(800, 600)`,
`wl_surface.enter` of the right outputs.

### Frame rate, CPU, memory (`tools/cef-wayland-tests/perf.py`, 15-20 s, whole process tree, PSS)

Views window against a Chrome-style window opened through DevTools (the workaround the viewer used before), fullscreen, same compositor,
same output, the page draws every `requestAnimationFrame` (fps counted by the page). Raspberry Pi 4: the image's own labwc (unitotem-compositor),
HDMI-A-1 = a 1920x1080 HDMI sink, `--gpu pi` flags, 20 s per run; Intel Iris Xe PC (amd64): 15 s per run, DP-2 1920x1080.

| board | page | mode | fps | CPU (% of a core) | PSS MB |
|---|---|---|---|---|---|
| Intel Iris Xe PC (amd64) 1920x1080 | WebGL2 | Views | 60.0 | 36.7 | 411 |
| | | DevTools | 60.0 | 36.3 | 421 |
| | canvas 2D | Views | 60.0 | 38.9 | 412 |
| | | DevTools | 60.0 | 39.0 | 433 |
| | idle page | Views | 60.0 | 13.5 | 399 |
| | | DevTools | 60.0 | 14.1 | 417 |
| Raspberry Pi 4 1920x1080 (real output) | WebGL2 | Views | 60.0 | 75.8 | 371 |
| | | DevTools | 60.0 | 76.9 | 385 |
| | canvas 2D | Views | 60.0 | 86.0 | 369 |
| | | DevTools | 60.0 | 84.6 | 376 |
| | idle page | Views | 60.0 | 11.4 | 356 |
| | | DevTools | 60.0 | 11.9 | 375 |

Views windows run at the same frame rate and CPU and use 2-5% less memory (one run per cell; CPU differences of 1-2 points are noise).
An earlier Raspberry Pi 4 run on forced connectors (no monitor) gave the same picture (60 fps, 76/77% CPU WebGL2).

## Behaviour changes of the cefpython branch (regression analysis)

Everything new is additive except two decisions made at `Initialize()`/`CreateBrowserSync()` time on Linux. The table lists every case.

| platform / backend | WindowInfo kind | before | after |
|---|---|---|---|
| Linux, X11 backend (DISPLAY set, or `ozone-platform=x11`) | `SetAsChild(handle)` | embedded X11 child window | unchanged (proved: `x11_embed.py`) |
| Linux, X11 backend | parentless (`WindowInfo()`, `SetAsChild(0)`, no window info) | CEF native X11 top-level window | unchanged (proved: `x11_embed.py`, parent of the window = root) |
| Linux, X11 backend | `SetAsOffscreen` | windowless | unchanged (`osr_test.py` passes) |
| Linux, no DISPLAY, WAYLAND_DISPLAY set (kiosk, pure Wayland) | any | `ozone-platform=x11` forced: no X server, CEF cannot start | `ozone-platform=wayland` chosen: this is a CHANGE (it did not work before) |
| Linux, both set (desktop with XWayland) | any | x11 (XWayland) | x11: unchanged; `GDK_BACKEND=x11` is still set |
| Linux, `ozone-platform=wayland` passed by the caller | parentless | Chrome-style window, empty app_id/title, `CloseBrowser` leaves a zombie toplevel, no `OnBeforeClose` | Views window (800x600, framed), closed with the browser: CHANGE |
| same | `SetAsChild(handle != 0)` | not embeddable on Wayland (CEF cannot parent into an X11 handle) | unchanged: the condition requires a parent handle of 0 |
| same | `SetAsOffscreen` | windowless | unchanged (the new branch needs `windowType == "child"`) |
| Windows, macOS | any | - | unchanged: the branch and the backend selection are inside `IF UNAME_SYSNAME == "Linux"` (Cython compile time); the new Cython modules were only built and run on Linux |

The X11 test suite is the fork's own `unittests/_test_runner.py` on an X session of the Intel Iris Xe PC (amd64), stock module (the board's installed cefpython3)
against the new module: 85 tests OK before, 93 OK after (85 + 8 of `views_test.py`).

## Upstream state checked 2026-10-21 (fresh clone of chromiumembedded/cef master 7f8a5ec28, Chromium 156.0.8078.0)

* The series applies with a plain `git am` (no 3-way, no fuzz) on master: 158 commits since `d58e84d17`; one of them touches the same files (`2d3ce7f94` "views: Preserve overlay contents during Chrome window teardown") and does not conflict.
* Not obsolete: master has no `SetFullscreenOnDisplay`, no `CefDisplay::GetLabel`, and `CefWindowView::CreateWidget` still sets
  `remove_standard_frame` on Windows only.
* chromiumembedded/cef#2804 "Linux: Add support for embedded Ozone/Wayland windows" is OPEN. magreenblatt, 2022-01-31: "Ozone builds can
  currently run with different platform backends (Wayland, X11, etc). Usage of the Views framework is required, and the cefclient sample
  application is not supported. See issue #2296. What's currently missing (and covered by this issue) is the ability to embed CEF windows in
  third-party Wayland applications."
* chromiumembedded/cef#4273 "Linux: Frameless Views windows request server-side decorations on Wayland" is OPEN and PR #4274 "Fix frameless
  Views windows on Wayland" (one file, `window_view.cc`, by swarogan, `Assisted-by: Codex`) is OPEN, unmerged: it overlaps our patch 0001
  (both set `remove_standard_frame` for frameless Wayland windows); the review asked for the `IsRunningOnWayland()` helper to move to `view_util`
  (our patch 0001 does that). If #4274 merges first, 0001 shrinks to the X11 guards and the helper.
* chromiumembedded/cef#4061 "Linux, Wayland uses very old Google Chrome decoration" is CLOSED (Chrome style window frame, not our topic).
* crbug.com/40111909: the page requires a sign-in and could not be read. What is verified is the source comment in
  `ui/ozone/platform/x11/x11_window.cc` (Chromium 147): `// TODO(crbug.com/40111909) Support target_display_id on this platform.` followed by
  `DCHECK_EQ(target_display_id, display::kInvalidDisplayId);`. The same file in master/156 was not checked.
* No upstream issue exists for choosing the display of a fullscreen CefWindow or for a display observer (GitHub issue search on 2026-10-21: SetFullscreen, fullscreen display/monitor, CefDisplay, DisplayObserver).

## Platform contract and review of the CEF series

Decision (user, 2026-10-25): the fixes exist to make Wayland work, so everything is Wayland only and Windows, macOS (and X11 where noted) are
unchanged by construction. What each new or changed piece does outside Wayland:

| API / code | Wayland | Windows, macOS, X11 |
|---|---|---|
| `CefWindow::SetFullscreenOnDisplay(id)` | `xdg_toplevel.set_fullscreen(wl_output)`, moves a fullscreen window (leaves fullscreen first) | exactly `SetFullscreen(true)` (the code is under `BUILDFLAG(IS_OZONE)` and `IsRunningOnWayland()`) |
| `CefDisplay::GetLabel()` | the `wl_output` description | empty string (`display::Display::label()` is set differently by Windows, macOS and X11: not exposed) |
| `CefDisplay::AddObserver/RemoveObserver`, `CefDisplayObserver` | `OnDisplayAdded/Removed/MetricsChanged` | `AddObserver` does nothing, the observer is never called; the adapter code is compiled only under `BUILDFLAG(IS_OZONE)` |
| frameless windows (`remove_standard_frame`), X11 handling skipped, `GetDisplay` by entered output | under `BUILDFLAG(IS_OZONE)` and `IsRunningOnWayland()` | unchanged: the Windows branch is textually the original (the comment edit of the first draft was reverted); the X11-only code only gets `is_x11 &&` / `!IsRunningOnWayland()` conditions inside the existing `IS_LINUX` + `SUPPORTS_OZONE_X11` blocks, true on X11 |

`tools/cef-server/list-nonozone-changes.py CEF_DIR BASE` lists every added or removed line outside a `BUILDFLAG(IS_OZONE)` or
`CEF_API_ADDED` conditional (73 lines for the master series, about half of them the license text of the new header). The rest: the `#include
"include/cef_api_hash.h"` lines, the new header's include guard, `#include "cef/libcef/browser/views/view_util.h"` in `window_view.cc` (declares nothing
outside `IS_OZONE`), the shells of `SetFullscreenOnDisplay`/`GetLabel`/`AddObserver`/`RemoveObserver` whose non-Wayland path is the fallback of the
table above, the two `IS_LINUX`+X11 lines, and the test includes. ceftests: `WindowFullscreenOnDisplay` is `SetFullscreen(true)` outside Wayland (the
same transitions as the existing `WindowFullscreen` test), `DisplayObserverAddRemove` asserts nothing but "no crash", and the `GetLabel()` call asserts
nothing: none can fail or flake on Windows, macOS or X11.

Older table (first draft, kept for the guard list):

| file | change | guard / why other platforms are not affected |
|---|---|---|
| `include/views/cef_window.h`, `cef_display.h`, `cef_display_observer.h` (new) | new pure virtual methods / interface | inside `#if CEF_API_ADDED(CEF_EXPERIMENTAL)`, `/*--cef(added=experimental)--*/` like `CefBrowserHost::SetAxViewportCollapse`; the wrappers are generated by `tools/version_manager.py` (untracked, regenerated in every build) |
| `libcef/browser/views/display_impl.{h,cc}` | `GetLabel()`, the observer adapter | Wayland only, see the table above |
| `libcef/browser/views/window_impl.{h,cc}` | `SetFullscreenOnDisplay`; `IsRunningOnWayland()` calls now `view_util::` | Wayland only; the calls are inside the existing `IS_OZONE` blocks |
| `libcef/browser/views/view_util.h`, `view_util_aura.cc` | `view_util::IsRunningOnWayland()` | declared and defined only under `BUILDFLAG(IS_OZONE)`; `view_util_mac.mm` is not touched |
| `libcef/browser/views/window_view.cc` | see the table above | see the table above |
| `tests/ceftests/views/window_unittest.cc` | new tests | `#if CEF_API_ADDED(CEF_EXPERIMENTAL)`, platform independent assertions |

Windows and macOS were NOT compiled. Why: `gn gen` with `target_os="win"` stops at `KeyError: 'WINDOWSSDKDIR'` (`build/vs_toolchain.py`: no
Windows SDK/MSVC), with `target_os="mac"` in `build/config/mac/mac_sdk.gni` (no Xcode SDK); Chromium's guide for cross-compiling Chrome/win
(docs/win_cross.md) needs a toolchain package built from a Windows installation (`DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL`), and Apple's SDK has a
licence that ties it to Apple hardware/Xcode. What was done instead (`tools/cef-server/check-nonozone.py`): the four touched translation units
(`display_impl.cc`, `window_impl.cc`, `window_view.cc`, `view_util_aura.cc`) compile syntax-only with Chromium's clang and the flags of the
Linux `libcef_static` target both with and without `-DUSE_OZONE`; without it `BUILDFLAG(IS_OZONE)` is 0, the situation of Windows and macOS in
shared code. 0 errors in both modes. This checks types, includes and guards of that path, nothing OS specific.

## Running the whole suite on a board (one command)

`tools/cef-wayland-tests/run-suite.sh HOST x86_64|aarch64` puts the tests (and, with `DEV=1`, the dev build of cefpython3) on the board and runs
`board-suite.sh` there: `outputs.py`, `views_test.py`, the ceftests Views suites (binary from `CEFTESTS_PKG`, default
`/tmp/ceftests-pkg-ARCH`) and the Views-against-DevTools `perf.py` matrix (WebGL2, canvas 2D, idle). It detects the mode by itself:
on the image (`unitotem-compositor` active) it stops `unitotem-manager`, uses the image's compositor and the system python3-cefpython3 and starts
the manager again at the end (the compositor unit is never touched); on a board with the X session it starts its own labwc and brings X back.
For the Raspberry Pi 4 (no `--off` of the last output, so no hot-plug there):
`CEFTESTS_PKG=/tmp/ceftests-pkg-aarch64 OUTPUT=HDMI-A-1 tools/cef-wayland-tests/run-suite.sh <host> aarch64`. Validated in X mode on
the Intel Iris Xe PC (amd64) (all parts) and in image mode on the Raspberry Pi 4 (this run: `W=/run/cefsuite CEFPY=dev OUTPUT=HDMI-A-1`, everything in `/run` because `/tmp` of the image is 256 MB).

### CEF master (Chromium 156) compile check

A separate CEF master tree on a build host holds Chromium 156.0.8078.0 (the tag master's `CHROMIUM_BUILD_COMPATIBILITY.txt` names) and CEF master e537569ec,
separate from the 147 tree. `gn gen` needed `GN_DEFINES="use_sysroot=true symbol_level=0 proprietary_codecs=true ffmpeg_branding=Chrome
is_component_build=false"` and `python3 cef/tools/gclient_hook.py` run as the owner of the tree. The four touched libcef_static objects and `window_unittest.o` build
with the six `patches/cef-master` applied (details in `pr-cef.md`); the full libcef of master was not built.

## Not verified

* Windows and macOS: not built (reasons above). `SetFullscreenOnDisplay`, `GetLabel` and the observer do nothing special there by construction (see the platform contract); the whole
  series was only compiled for Linux.
* aarch64: `outputs.py`, `views_test.py`, ceftests `Views*`, the metrics observer and perf ran on the Raspberry Pi 4 image (labwc, real output). Not run there:
  the hot-plug observer test (no second output can be forced), `x11_embed` (no X on the image).
* A monitor other than the HDMI sink on the Raspberry Pi 4 and a second real monitor on the Intel Iris Xe PC (amd64); a compositor other than labwc (the output-name lookup relies on the wlroots description format).
* X11 behaviour of the new CEF methods (only the fallback `SetFullscreen(true)` path; the cefpython regression on X11 was run).
* The observer's `OnDisplayMetricsChanged` was not provoked (no test changes metrics); only added/removed were measured.
* The forum was not searched for existing discussions of choosing a display; the GitHub issue tracker was (queries SetFullscreen, fullscreen
  display/monitor, CefDisplay, DisplayObserver: nothing relevant).
