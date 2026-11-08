# CEF runtime

Chromium Embedded Framework 147 as `cefpython` (Python bindings, fork in `vendor/cefpython`), the CEF build that produces its wheels, and the `python3-cefpython3` package. Wayland support through the Views API.

Paths: relative to `unitotem-manager/`

## Files
- `.gitmodules`: submodule `vendor/cefpython` (fork URL, `branch = cefpython147-qt`). The pin is in no remote branch of the fork (only local `wayland-views`, one commit ahead of `origin/wayland-views`); `branch` is not changed until it is pushed.
- `vendor/cefpython/`: submodule, pinned commit `65a5ad0` (branch `wayland-views`, `v147.0.0-arm64-16-g65a5ad0`).
- `vendor/cefpython-wheels/`: built wheels, untracked. Input of `python3-cefpython3`.
- `tools/build-cef-wheels.sh`: copies the submodule to the build server, builds wheels detached, fetches them.
- `tools/cef-wheels-inner.sh`: runs in `debian:trixie` on the build server; builds wheels per Python and arch.
- `tools/build-debs.sh cefpython`, `debian/rules`, `debian/control`: package from the wheel (see [packaging.md](packaging.md)).
- `tools/cef-server/`: Chromium and CEF distribution build; reference `tools/cef-server/README.md`. Edit the scripts here and push them with `sync.sh`; never edit them on the build server.
  - `build-all.sh`: x64 native, then arm64 cross; stage markers.
  - `cef-rebuild.sh`: rebuilds both distributions after a patch change.
  - `cef-arm64-v4l2.sh`, `cef-arm64-dbg.sh`, `cef-lean-x64.sh`: arm64 V4L2 build, arm64 debug build, measured lean x64 build.
  - `apply-patches.sh`: applies `patches/0*.patch` (Chromium) and the `patches/cef/` series (CEF).
  - `patches/`: Chromium patches `0001-v4l2-stateful-nv12-candidate-first`, `0002-gbm-no-scanout-buffers-env`, `0003-allow-framing-switch`; `experimental-*.patch` is never applied. `patches/cef/` CEF series 0001-0007; `patches/cef-master/` 0001-0006 rebased on CEF master.
  - `sync.sh`: copies the `*.sh` files to or from the build server.
  - `probe-gn-args.sh`: `gn gen` dry run per argument set. `nm-areas.py`: `libcef.so` symbol size per C++ namespace.
  - `check-nonozone.py`, `list-nonozone-changes.py`: guard checks for non-Ozone platforms.
- `tools/cef-wayland-tests/`: test programs for a Wayland board.
- `[cef/lean-build.md](cef/lean-build.md)`: measurements of build arguments and `libcef.so` size.
- `[cef/wayland-design.md](cef/wayland-design.md)`: Wayland design, platform contract, upstream state. `pr-cef.md`, `pr-cefpython.md`: upstream PR texts.

## How it works
- Wheels come from `vendor/cefpython` at the pinned commit. Wheel version `147.0+codecs`.
- CEF distribution: Chromium 147.0.7727.118, CEF commit `d58e84d17`, built from source with `use_sysroot=true symbol_level=1 is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome`.
- Build order on the server: `automate-git.py` (CEF's own patches), `apply-patches.sh`, `python3 tools/version_manager.py -u --fast-check` in `chromium/src/cef`, `autoninja libcef`.
- Distributions: `binary_distrib/cef_binary_*_linux64` (x64) and `*_linuxarm64` (arm64, `use_v4l2_codec=true use_vaapi=false`).
- Wheel build (`cef-wheels-inner.sh`):
  - Per arch `prepare_cef` makes `bin/` (Release and Resources, debug-stripped `libcef.so`), `lib/` (wrapper), `include/`. Cache: `.ready` holds `CEF_KEY` (sha256 of `tools/cef-server/patches/*` and the pinned commit); reused only if equal and newer than `libcef.so`.
  - Python 3.13 only (`CEF_PYTHON` in `build-cef-wheels.sh`): venv with `cython==3.2.9`, interpreter from `uv`.
  - aarch64 is cross compiled (`gcc-aarch64-linux-gnu`, arm64 libgtk, x11, glib dev packages); only the arm64 Python `include/` is used. No emulation.
  - Extension renamed `cefpython_pyXY.so` (no ABI suffix); platform tag pinned `linux_x86_64` or `linux_aarch64`; wheel written by `build_distrib.py` (`--out-dir /work/out`).
- Host side: `start` copies the submodule (without `build/`, `.git`, `cefpython3/*` except `__init__.py`), runs the container under systemd, writes `DONE` or `FAILED`. `fetch` rsyncs `out/` to `vendor/cefpython-wheels/`.
- Ozone backend at runtime: Wayland when `WAYLAND_DISPLAY` is set and `DISPLAY` is not, else X11. `GDK_BACKEND=x11` is not forced in a pure Wayland session.
- Wayland, parentless `WindowInfo` in `CreateBrowserSync()`: a Views window (800x600, framed), closed with the browser. Other `WindowInfo` kinds are unchanged.
- Views windows use the Alloy runtime style (`BrowserView.GetRuntimeStyle()` is `RUNTIME_STYLE_ALLOY`), a thin layer on top: every CEF 147 process still runs Chrome's bootstrap (profile, Preferences, password manager, autofill, safe browsing, component updater); no GN switch removes it.
- CEF patches `patches/cef/`: `0001` frameless windows on Wayland (`remove_standard_frame`, X11-only paths skipped, `IsRunningOnWayland` moved to `view_util`); `0002` `CefWindow::SetFullscreenOnDisplay(int64)`; `0003` `CefDisplay::GetLabel()`; `0004` `CefWindow::GetDisplay()` uses the entered output (`display::Screen::GetDisplayNearestWindow`); `0005` ceftests; `0006` `CefDisplayObserver` with `AddObserver`/`RemoveObserver`; `0007` OSR menu offset (`menu_runner_views_aura.cc`) built only with X11 (needed by `ozone_platform_x11=false`).
- Wayland fullscreen: `Window.SetFullscreenOnDisplay(id)` sends `xdg_toplevel.set_fullscreen(wl_output)` before `Show()`. A window already fullscreen leaves fullscreen first.
- Display ids on Wayland are the `wl_output` registry name; they change on unplug and replug. Look up by name (`Display.FindByOutputName`).
- `Display.AddObserver` delivers `OnDisplayAdded`, `OnDisplayRemoved`, `OnDisplayMetricsChanged`. A switched-on output is listed about 210-230 ms later.
- Chromium fires `OnDisplayMetricsChanged` only while a browser window is open: with none, a mode change (`wlr-randr --mode`) changes no display list and sends no event.
- Chromium patch `0002`: `UNITOTEM_NO_SCANOUT_BUFFERS` selects tiled non-scanout GBM buffers on V3D (60 fps instead of 30). Patch `0003`: `--unitotem-allow-framing` lets pages that forbid framing load. A stock CEF ignores both.

## Interfaces
- `tools/build-cef-wheels.sh start|status|fetch` (exit 2 on unknown command). Env: `BUILD_HOST` (ssh target), `WHEEL_VERSION` (`147.0+codecs`), `CEF_PYTHON` (`3.13`, passed as `PYTHONS`), `ARCHES` (`x86_64 aarch64`). Server side: systemd unit `cef-wheels`, `build.log`, markers `DONE`/`FAILED`, output `out/*.whl`.
- `tools/cef-wheels-inner.sh` (container): mounts `/work/src` (rw), `/work/distrib` (ro), `/work/out`, `/work/tmp` (kept between runs).
- `build-all.sh`, `cef-rebuild.sh`: env `CEF_WORK`, `CEF_DEPOT_TOOLS`. Markers `logs/x64.done`, `logs/arm64.done` (delete one to redo the stage); timeline `logs/stages.log`.
- `apply-patches.sh [CHROMIUM_SRC]`: `DRY_RUN=1` checks only. Per patch: already applied (reverse applies) skipped; applies cleanly applied; else stop. Exit 1 on a patch that fits neither state, 2 on bad input.
- `sync.sh push|pull`: env `CEF_HOST`, `CEF_WORK`.
- `probe-gn-args.sh RESULTS < SETS`: set line `name|arg arg ...`; output `name | ok | steps=N` or `GN REFUSES`. Base args: `out/Release_GN_x64/args.gn` of the tree (`BASE_ARGS` overrides); exit 2 with usage when missing.
- `nm-areas.py LLVM_NM libcef.so`. `check-nonozone.py ozone|nonozone FILE...` (FILE relative to `chromium/src/cef`; env `OUTDIR`, `CEF_OVERLAY`).
- `tools/build-debs.sh cefpython`: env `TARGET_ARCH=arm64` (cross), `CEF_WHEEL_DIR` (default `vendor/cefpython-wheels`).
- Runtime env: `WAYLAND_DISPLAY`, `DISPLAY`, `GDK_BACKEND` (ozone selection); `UNITOTEM_NO_SCANOUT_BUFFERS` (any value, read once; the viewer sets it for the `pi` GPU profile); switch `--unitotem-allow-framing`.
- Python API (`cefpython3.cefpython`):
  - Classes `cef.Window`, `cef.Panel`, `cef.View`, `cef.BrowserView`, `cef.Display`.
  - Window: `SetFullscreenOnDisplay(display_id)`, `GetDisplay()`, `GetClientAreaBoundsInScreen()`.
  - Display: `FindByOutputName(name)`, `GetLabel()`, `AddObserver(obs)`, `RemoveObserver(obs)`.
  - Optional window delegate methods: `OnWindowCreated`, `OnWindowDestroyed`, `CanClose`, `IsFrameless`, `GetInitialBounds`, `GetInitialShowState`, `GetLinuxWindowProperties` (key `wayland_app_id`).
  - Observer methods: `OnDisplayAdded`, `OnDisplayRemoved`, `OnDisplayMetricsChanged`.
  - Without Wayland: `SetFullscreenOnDisplay` acts as `SetFullscreen(True)`, `GetLabel` returns empty, `AddObserver` never calls back.
- Board suite (`board-suite.sh`): `W` (default `/var/lib/unitotem/wl`), `CEFPY=system|dev`, `HOTPLUG=OUTPUT`, `SKIP="outputs views ceftests perf"`, `SECONDS_PERF` (15), `PERF_GPU=pi|vaapi|none`, `OUTPUT`.
- `run-suite.sh HOST x86_64|aarch64` (env `DEV=1`, `HOTPLUG`, `SKIP`, `CEFTESTS_PKG`, `LOG`); `deploy.sh HOST ARCH quick|libcef|tests|full`.

## Rules and gotchas
- `is_official_build=true` is mandatory: a non-official build segfaults in Skia at `sk_malloc_size` -> `malloc_usable_size` (SIGSEGV, registers full of `0xcd`), killing the manager in font setup and a standalone CEF in `ContentsContainerOutline::SetClipPath`. The official flag set also sets `use_partition_alloc_as_malloc=false` (the non-official default is true): treat "build official" as the rule, not that single argument.
- Official builds need PGO profiles. `--with-pgo-profiles` takes effect only when `.gclient` is written: on an existing checkout GN fails with a missing `.profdata`. Set `'checkout_pgo_profiles': True` in `chromium/.gclient` by hand and run `gclient runhooks`.
- `proprietary_codecs=true ffmpeg_branding=Chrome` is mandatory: H.264 and AAC are linked into `libcef.so` (`FFmpegVideoDecoder`).
- Codec coverage, any wheel: HEVC, AC3/EAC3, DTS and Theora do not play (`ffmpeg_branding=Chrome` brings no AC3/EAC3/DTS; HEVC needs hardware decode). With a plain wheel `canPlayType` answers empty and H.264 fails with `DEMUXER_ERROR_NO_SUPPORTED_STREAMS`: test media must then be WebM (VP9, AV1, Opus, Vorbis) or MP3.
- `use_v4l2_codec=true` and `use_vaapi=true` are mutually exclusive (`gn gen` asserts). On arm64 `use_vaapi` defaults to false and `use_v4l2_codec` to false on every arch: the default build has no hardware video decode client, and no runtime switch adds one.
- Chromium never uses VA-API on NVIDIA: `vaapi_wrapper.cc` skips `nvidia-drm` devices (crbug 1492880) unless the feature `VaapiOnNvidiaGPUs` (off by default) is on; `VaapiIgnoreDriverChecks` does not bypass it. Forcing the feature gets past the skip, then `nvidia_drv_video` fails CUDA init: nothing to enable (`manager/utils/system/gpu.py`). AMD VA-API decode is untested.
- Pi 4 V4L2 hardware decode is not enabled (`VERIFIED['v4l2']` is False). With a `use_v4l2_codec` build and `AcceleratedVideoDecoder` on, Chromium picks `V4L2VideoDecoder` and stalls with no frame and no error (GBM cannot make NV12 buffers, so no ImageProcessor is found). A patch and a `SetFormat` fix decoded slower than software and a second video hung. Do not retry on the Pi 4 without a different output path; keep `AcceleratedVideoDecoder` out of the `pi` profile. Software H.264 on a Pi 4: 1080p30 drops about 15 % of frames. To judge any decoder use the CDP Media domain (`kIsPlatformVideoDecoder`) or `SystemInfo` `videoDecoding` non-empty; debug with a `dcheck_always_on=true` libcef in its own out dir (`cef-arm64-dbg.sh`), never the release tree (`DVLOG` is compiled out).
- V3D: `gbm_bo_create_with_modifiers` gives LINEAR scanout buffers that the compositor presents two vblanks late (about 31 flips/s, a 30 fps cap). Do not add the SCANOUT flag; patch `0002` (`UNITOTEM_NO_SCANOUT_BUFFERS`) gives tiled non-scanout buffers (60 fps). Diagnose with `WAYLAND_DEBUG=1` and the DRM vblank tracepoint.
- Never write into `binary_distrib/` while a wheel build reads it. Never delete the Chromium tree (incremental builds).
- `automate-git.py --force-clean` and `--force-update` reset patched files: run `apply-patches.sh` again.
- `build-all.sh` and `cef-rebuild.sh` run `apply-patches.sh` between the `automate-git.py` download and each build. `cef-arm64-v4l2.sh`, `cef-arm64-dbg.sh`, `cef-lean-x64.sh` do not: run `apply-patches.sh` first.
- After changing the CEF series run `version_manager.py -u --fast-check` before `autoninja` (C API wrappers).
- Patched headers with an unpatched `libcef` (or the reverse) fail at `CefInitialize`: "API hashes for libcef and libcef_dll_wrapper do not match". Headers of CEF patches 0002, 0003, 0006 are copied to `vendor/cefpython/src/include/views/`.
- Every new CEF API is `added=experimental` (`CEF_EXPERIMENTAL`).
- New code is Wayland only, under `BUILDFLAG(IS_OZONE)` or `IsRunningOnWayland()`. Windows and macOS are not compiled (no SDK); unchanged by construction.
- labwc ignores `set_fullscreen` output on a toplevel already fullscreen: leave fullscreen first.
- `Display.FindByOutputName` matches the `(DP-1)` suffix that wlroots compositors append to the `wl_output` description (`CefDisplay::GetLabel`). CEF learns of a new output about 200 ms after Qt: `show()` waits for it, a window made earlier went fullscreen on the wrong output. A Wayland client does not know where its toplevel is (bounds start at 0,0): `CefWindow::GetDisplay` needs the entered-output patch (`patches/cef/0004`). X11 has no target display.
- CToCpp wrappers hand out a NEW wrapper object each time (`window.AsPanel()`, a delegate argument): never keep a raw pointer from a temporary `CefRefPtr` (use-after-free, `kWrapperType` FATAL), never use the address as identity (`CefView::IsSame`).
- The DevTools HTTP server is served by the message loop: a script that polls `127.0.0.1:<port>/json` from the thread that pumps `MessageLoopWork` deadlocks; poll from another thread.
- Build scripts run as systemd units (`sudo systemd-run --unit=cef-build`, `cef-rebuild`) so a lost ssh session does not stop them; units do not survive a reboot, the scripts are re-runnable.
- The CEF tree build needs `buildtools/linux64-format` and `depot_tools` in `PATH` (`make_distrib.py` runs clang-format). Test scripts must not be named `bisect.py` or `random.py` (the standard library imports them).
- Parentless `WindowInfo` on Wayland gives a Chrome-style window that `CloseBrowser()` never destroys. Use Views.
- `SetAsChild(handle)` cannot embed into a Wayland surface (X11 only).
- CEF patch `0001` overlaps upstream PR #4274; if it merges first, `0001` shrinks to the X11 guards.
- Only `locales/en-US.pak` is shipped; the page language is set per window.
- Lean build: `gn gen` accepting an argument proves nothing. `enable_compose`, `enable_captive_portal_detection`, `enable_media_remoting*`, `enable_webui_certificate_viewer`, `use_bluez` pass `gn gen` and fail to compile or link; `enable_extensions`, `enable_supervised_users`, `enable_screen_ai_service`, `enable_speech_service`, `enable_on_device_translation`, `enable_print_preview`, `enable_widevine`, `enable_plugins` are asserted. Wayland-only needs CEF patch `0007`. The accepted set gives `libcef.so` 252.0 to 250.3 MiB (-0.7 %); not part of the shipped build (`[cef/lean-build.md](cef/lean-build.md)`). Try an argument with `autoninja -k 0` in a server tree dir.
- Lean build, also refused by the build: `safe_browsing_mode=0`, `enable_printing=false` and `enable_pdf=false` (`cef/BUILD.gn` asserts `enable_print_preview`), `enable_widevine=false` (required argument). Measured dead ends: `optimize_for_size=true` changes flags, not the step count; `use_dawn=false` would remove WebGPU; dropping the Chrome interface cuts at most about 25 MB of `libcef.so` and needs a patch series redone at every Chromium update.
- The lean `libcef.so` (-1.7 MiB) is not shipped (`debian/rules` has no lean switch): adoption would need the arm64 build, the wheel and the full viewer test battery on a board.
- Probe builds need `chrome_pgo_phase=0` (the PGO profile of the Chromium tree is owned by another user): `probe-gn-args.sh` strips `chrome_pgo_phase` and `target_cpu` from its base args and appends it; `cef-lean-x64.sh` must run under `systemd-run` as root for the same reason.
- Windows and macOS cannot be built here: `gn gen` with `target_os=win` stops with `KeyError 'WINDOWSSDKDIR'`, `target_os=mac` needs an Xcode SDK. `check-nonozone.py` compiles the touched units syntax-only with and without `USE_OZONE` instead.
- `libcef.so` is stripped on both arches; extension modules link with `--allow-shlib-undefined` (NSS, ALSA, ... load at run time).
- The Chrome bootstrap runs in every process (profile, password manager, autofill); no GN switch removes it.

## Tests
- `vendor/cefpython/unittests/_test_runner.py`: X11 session, 85 tests with the stock module, 93 with Views (`views_test.py`).
- ceftests `Views*` with `--ozone-platform=wayland` (includes `WindowFullscreenOnDisplay`, `DisplayObserverAddRemove`).
- `tools/cef-server/check-nonozone.py`: compile check with and without `-DUSE_OZONE`.
- `tools/cef-wayland-tests/run-suite.sh HOST ARCH`: deploy and run `board-suite.sh`. Parts: `outputs.py`, `views_open.py [--output NAME] [--app-id ID]`, `observer_hotplug.py OUTPUT` (two outputs), `observer_metrics.py`, `perf.py --mode views|devtools [--gpu pi|vaapi|none] [--page webgl2|webgl2aa|canvas2d|idle] [--output NAME] [--seconds N]`, `x11_embed.py` (X11 regression), `old_windowinfo.py` (Chrome-style window).
- `board-suite.sh` runs in image mode when `unitotem-compositor.service` is active: the manager is stopped for the run and restarted by a trap, the compositor unit is never touched, system `python3-cefpython3` is used (`CEFPY=dev` for the development tree). Otherwise (X session) `compositor.sh` starts and stops its own labwc.
- `compositor.sh start|stop`: labwc without the manager; `stop` must run when the test ends.
- Test scripts need `WAYLAND_DISPLAY=/run/unitotem/xdg/wayland-0` and no `XDG_RUNTIME_DIR`.
