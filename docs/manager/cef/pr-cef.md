# Draft upstream pull request: chromiumembedded/cef

Not opened. Series: `tools/cef-server/patches/cef/0001..0006` (`git am`, base `d58e84d17`, 147.0.7727.118) and the same six rebased on master
(`patches/cef-master/`, base e537569ec on 2026-10-25). Checked 2026-10-25: the 147 series applies with plain `git am` on `d58e84d17`; on master
it needed `--3way` for 0002 (master's "Implement unified keyboard API" c5ca80128 touches the same `#include` list of `window_impl.cc`), one trivial
include conflict, resolved in `patches/cef-master/`, which applies with plain `git am` on e537569ec; `tools/fix_style.py` reports "ok" for every touched file.
CEF's rules (docs/contributing_with_git.md) ask for an issue number in the commit descriptions: open the issue first (text below), then add
"Fixes #N" to the commits. No CLA is mentioned in the repository docs.

**Behaviour changes on Linux/Wayland only; Windows, macOS and X11 are unchanged by construction** (new code is under `BUILDFLAG(IS_OZONE)` and
`IsRunningOnWayland()`; outside Wayland `SetFullscreenOnDisplay` is `SetFullscreen(true)`, `GetLabel` is empty, `AddObserver` does nothing). **Not tested on
Windows or macOS.** No Windows SDK/MSVC or Apple SDK is available to the author (`gn gen` with `target_os="win"` fails with
`KeyError: 'WINDOWSSDKDIR'`, with `target_os="mac"` in `mac_sdk.gni`; the official Windows cross-build needs a toolchain package made on a
Windows machine). Linux only: x86_64 and aarch64 builds, ceftests Views suites on x86_64 under labwc. As a partial check the touched
translation units (`display_impl.cc`, `window_impl.cc`, `window_view.cc`, `view_util_aura.cc`) were compiled syntax-only with Chromium's
clang both with and without `USE_OZONE`; without it `BUILDFLAG(IS_OZONE)` is 0, which is what Windows and macOS see (`tools/cef-server/check-nonozone.py`).
It does not replace a Windows or macOS build. The master-rebased series (`patches/cef-master`, CEF e537569ec) was built for real: master's `CHROMIUM_BUILD_COMPATIBILITY.txt` asks for
Chromium `refs/tags/156.0.8078.0`, which was checked out (no history) with CEF master in a second checkout beside the 147 tree, CEF's patches
applied (116 of 117, one skipped by CEF's own patcher), `gn gen` of the Linux x64 Release configuration, then `autoninja` of `window_impl.o`,
`display_impl.o`, `window_view.o` and `view_util_aura.o` of `libcef_static` (42686 steps for the generated headers and the base master: success)
and, after `git am` of the six patches and `version_manager.py -u`, again (54 steps): success, 0 errors; `ceftests/window_unittest.o` with the new
tests compiles too (208 steps). The syntax-only check with and without `USE_OZONE` gives 0 errors on all four units for both base master and
master + series. Not built: the full libcef of master (not linked, not run: runs and measurements were done on the 147 series).
`fix_style.py` is "ok" on all 11 files of the rebased series. aarch64: built, and run on a Raspberry Pi 4 image (labwc, real 1080p output): ceftests Views* 105 pass, outputs/views tests pass.

## Title

views: Wayland support for CefWindow (frameless windows, fullscreen on a chosen display, display label, display observer)

## Issue text

CEF Views windows are the supported way to run CEF on Ozone/Wayland (#2804). A kiosk-style application (frameless, fullscreen, one window per
output, closed for real) needs: (a) frameless windows without server-side decorations (#4273), (b) choosing the display of a fullscreen
CefWindow, (c) finding out which compositor output a CefDisplay is, (d) a correct CefWindow::GetDisplay(), (e) a notification when a display
appears, instead of polling.

## Commits

1. **Frameless windows and X11 assumptions.** `CefWindowView::CreateWidget` sets `remove_standard_frame` only on Windows; on Wayland the
   compositor then draws a title bar (xdg-decoration `set_mode(2)`, as in #4273/#4274). Set it for Wayland. The X11-only handling in
   `CreateWidget`/`WindowClosing` is skipped on Wayland. `IsRunningOnWayland()` moves to `view_util` (requested in the #4274 review).
   Overlaps PR #4274 (open); if it merges first this commit shrinks.
2. **`CefWindow::SetFullscreenOnDisplay(int64_t display_id)`** (experimental). `views::Widget::SetFullscreen(bool, int64_t)` takes a target
   display; Wayland turns it into `xdg_toplevel.set_fullscreen(wl_output)`. Works before `Show()`. For a window that is already fullscreen it
   leaves fullscreen first, because labwc ignores the output of a fullscreen request for a toplevel that is already fullscreen.
   Only Wayland honors the display; Windows, macOS and X11 (which does not support a target display: `DCHECK_EQ(target_display_id,
   kInvalidDisplayId)` in `X11Window::SetFullscreen`) behave exactly like `SetFullscreen(true)`.
3. **`CefDisplay::GetLabel()`** (experimental): on Wayland the `wl_output` description, the only place an application can learn the output name
   (wlroots compositors end it with `(DP-1)`); empty elsewhere (`display::Display::label()` differs per platform and is not exposed).
4. **`CefWindow::GetDisplay()` on Wayland** used the window bounds, which a Wayland client cannot know (they start at 0,0): a window on the
   second output was reported on the first. Use `display::Screen::GetDisplayNearestWindow()` there.
5. ceftests for 2 and 3.
6. **`CefDisplayObserver` + `CefDisplay::AddObserver/RemoveObserver`** (experimental; independent of 1-4, can be taken or left separately).
   `OnDisplayAdded/Removed/MetricsChanged`, a wrapper of `display::DisplayObserver` (`ScopedOptionalDisplayObserver`, so a late removal after
   shutdown is harmless); Wayland only, `AddObserver` does nothing elsewhere. Needed because Chromium lists a new output about 220 ms after it was switched on; measured with
   `wlr-randr --output DP-2 --off/--on` on labwc, 6 runs: removed 184-219 ms, added 211-228 ms after the command, `FindByOutputName`
   finds the display inside the callback every time, the window opened on the new output 7-8 ms later.

All new API is `added=experimental` (`CEF_EXPERIMENTAL`); say if `CEF_NEXT` is preferred.

## Tested

labwc 0.8.3 on an Intel Iris Xe PC (amd64) with two outputs and on a Raspberry Pi 4 (aarch64, two forced connectors, no monitor), pure Wayland,
CEF built from source (official build, proprietary codecs), driven through cefpython bindings: one frameless window per output goes
fullscreen on its output (`WAYLAND_DEBUG`: `set_fullscreen(wl_output#32)` / `#34`, `configure` with each output's size), `GetDisplay()` is right,
output off/on gives a new display id and the window returns with `SetFullscreenOnDisplay`, `Close()` destroys the toplevel and `OnBeforeClose`
fires. 18 checks pass on both boards, 19 on x86_64 with the observer. ceftests (x86_64, `--ozone-platform=wayland`): `Views*` 105 tests
pass, including `WindowFullscreenOnDisplay` (`WAYLAND_DEBUG` shows `set_fullscreen(wl_output)` then `unset_fullscreen`) and
`DisplayObserverAddRemove`. The test of the observer only checks registration: display changes cannot be provoked from ceftests. None of the new tests
asserts anything platform dependent (`WindowFullscreenOnDisplay` is `SetFullscreen(true)` outside Wayland). `tools/cef-server/list-nonozone-changes.py` lists
every changed line outside `IS_OZONE`/`CEF_API_ADDED`; the final series was re-checked 2026-10-25 (plain `git am` on d58e84d17 and on master e537569ec, `fix_style.py`
clean, compile with and without `USE_OZONE` on the 147 tree and on master with Chromium 156).

Not tested: Windows, macOS, X11 for the new methods (the X11 path only calls `SetFullscreen(true)`), a real monitor (the Pi output goes to a
1920x1080 HDMI sink), observer behaviour on compositors other than labwc. Observation: with no window open Chromium's display list did not follow a
mode change at all (no `OnDisplayMetricsChanged`); with a window open it fires, 69-73 ms after the mode change.

Related: #2804, #4273, #4274.
