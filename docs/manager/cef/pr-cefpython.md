# Draft upstream pull request: cefpython

Not opened. Where to send it: `gh repo view a13ssandr0/cefpython --json parent` gives `linesight/cefpython`, whose parent is
`cztomczak/cefpython` (root, default branch `master`, last push 2026-10-09). The CEF 147 line lives in `linesight/cefpython`, branches
`cefpython147` and `cefpython147-qt` (both pushed 2026-10-21; `cztomczak/cefpython` PR #691 "Add CEF 147, Python 3.10-3.14..." is open
from `linesight:cefpython147-qt` into `cztomczak:cefpython147`). The branch prepared for a PR is `wayland-views-pr` of
`a13ssandr0/cefpython`: three commits on top of `linesight/cefpython147-qt` a2a95cf (`git cherry-pick` of the work, conflicts in
`window_info.pyx` (the warning now uses `NonCriticalError`), the vendored CEF headers (deleted upstream) and the migration guide were
resolved). Suggested base: `cefpython147-qt` of `linesight/cefpython` (so it rides along with #691). Whether `linesight` takes PRs is unknown
(there are none open there). The older branch `wayland-views` (on `cefpython147-qt` f86bdbf of the fork, with vendored headers and the fork's
arm64 commits) is what the UniTotem repository builds.

**The Views API is cross-platform, everything Wayland specific is Linux/Wayland only and the other platforms are unchanged by construction**: the backend selection and
the parentless-`WindowInfo` change are inside `IF UNAME_SYSNAME == "Linux"` and only act on the Wayland backend; `Window.SetFullscreenOnDisplay`, `Display.GetLabel`,
`Display.FindByOutputName` and `Display.AddObserver` are honored by Wayland only (elsewhere `SetFullscreen(True)`, empty label, `None`, observer never called; the
docs in `api/` say so); nothing Wayland specific runs at import or window creation on Windows/macOS. **Not tested on Windows or macOS** (everything new is platform independent Views code; the Linux parts are inside `IF UNAME_SYSNAME ==
"Linux"`). Tested on Linux x86_64, Python 3.13 (and 3.14 for the Views test from the wheel); aarch64 (Raspberry Pi 4, Python 3.13): `views_test.py`, `outputs.py` pass.

## Title

CEF Views bindings (Window, BrowserView, Display), Wayland backend selection, CreateBrowserSync on Wayland

## Requires the CEF patches

The branch calls `CefWindow::SetFullscreenOnDisplay`, `CefDisplay::GetLabel` and `CefDisplay::AddObserver/RemoveObserver`, which exist only in
the CEF patch series of the UniTotem repository (`tools/cef-server/patches/cef`, patches 0002, 0003 and 0006; CEF `d58e84d17`, 147.0.7727.118;
experimental API, `CEF_EXPERIMENTAL`; draft PR text `pr-cef.md`). Against a CEF distribution without them the module does not compile (the
Cython code refers to the three methods), so the build needs the patched `include/` (`CEF_ROOT`). `libcef_dll_wrapper` compares API hashes
with libcef at `CefInitialize`, so a module built with the patched headers also refuses an unpatched libcef (observed: "API hashes for libcef and
libcef_dll_wrapper do not match"). Making the three methods optional at build time was not done.

## What it does

* `cef.Window`, `cef.Panel`, `cef.View`, `cef.BrowserView`, `cef.Display`; Python delegates (objects with optional methods named like
  `CefWindowDelegate`, `CefViewDelegate`, `CefBrowserViewDelegate`). One C++ delegate forwards to Python; views are identified with
  `CefView::IsSame` (the library hands out a new wrapper each time).
* `ozone-platform` is chosen from the session: wayland when `WAYLAND_DISPLAY` is set and `DISPLAY` is not, x11 otherwise (a desktop with
  XWayland is unchanged); `GDK_BACKEND=x11` is not forced in a pure Wayland session; the `SetAsChild` warning says what is wrong.
* On the Wayland backend `CreateBrowserSync()` with a parentless `WindowInfo` opens a Views window that closes with the browser (CEF's
  native windowed browser is X11 only; its Wayland window cannot be destroyed). Every other WindowInfo case is unchanged (table in
  `wayland-design.md`; X11 `SetAsChild` and parentless windows checked against the old module).
* Docs in `api/`, README index, migration guide, `examples/views.py`, `examples/views_hotplug.py`, `unittests/views_test.py`.

## Tested

`unittests/_test_runner.py` on an X11 session: 85 tests pass with the unmodified module, 93 with this branch (85 + the 8 of `views_test`).
`views_test.py` on a Wayland compositor (labwc, pure Wayland): pass; `outputs.py` (UniTotem repository, 19 checks, two outputs, hot-plug and
move) pass; `observer_hotplug.py` (9 checks) pass. The two examples were run. Not tested: Windows, macOS, Python versions other than 3.13/3.14,
PyInstaller.
