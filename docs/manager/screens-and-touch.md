# Screens and touch

Per-output power, input and volume control of the node's own monitors, touch-screen mapping and guided calibration, compositor configuration fragments, boot-splash orientation. Part of the node plugin; importable on a headless node (missing hardware or tools means "unavailable", never an import error).

Paths: relative to unitotem-manager/; `P` = `manager/plugins/unitotem_node/`.

## Files

| Path | Role |
|---|---|
| `P` `system/screens/control.py` | Facade: `screens()`, `probe()`, `set_power()`, `power_state()`, `set_input()`, `set_volume()`, `set_mute()`, `configure()`, `wake_all()` |
| `P` `system/screens/mechanism.py` | Pure mechanism priority (`candidates`, `resolve_mechanism`) |
| `P` `system/screens/wayland.py` | Compositor side: `wlr-randr --json` outputs, `wlopm` power, transform, blank watch |
| `P` `system/screens/identity.py` | EDID decoder (`MFG:Model:Serial`), output-name join |
| `P` `system/screens/ddc.py`, `ddc_ctl.py` | ddcutil parsers, DDC/CI calls (VCP `60` input, `62` volume, `8D` mute, `D6` power) |
| `P` `system/screens/cec.py` | `cec-ctl` adapters, standby/on, power state |
| `P` `system/screens/wol.py` | Wake-on-LAN (UDP broadcast and raw Ethernet 0x0842 frame) |
| `P` `system/screens/serial.py` | Raw serial commands (RS-232 / USB-serial) |
| `P` `system/screens/gpio.py` | GPIO relay or button via libgpiod (API 2) |
| `P` `system/screens/_exec.py` | Subprocess helper off the event loop (`ToolMissing`, `ToolTimeout`) |
| `P` `models/screen_control.py` | `OutputConfig`, `ScreenControl` store (`screen_control.json`) |
| `P` `api/display_screens.py` | `Settings/Display/Screens/*` |
| `P` `api/display_touch.py` | `Settings/Display/Touch/*` |
| `P` `api/display.py` | `Settings/Display/*`: displays, orientation, flip, GPU stats, insecure certificates |
| `P` `system/touch.py` | Touch device discovery (`/proc/bus/input/devices`), identity keys, compositor fragment |
| `P` `system/touch_service.py` | Device list kept current (inotify on `/dev/input`, debounce 0.3 s) |
| `P` `system/touch_setup.py`, `touch_calibration.py` | Guided setup service and pure calibration maths |
| `P` `system/libinput_names.py` | Device name as libinput reports it (ctypes) |
| `P` `models/touch_map.py` | `TouchMap` (`touch_map.json`) |
| `P` `system/boot_orientation.py` | Kernel command-line turn for the boot splash |
| `manager/utils/labwc.py` | Compositor configuration fragments |
| `manager/utils/outputs.py` | Output name canonicalisation |

## How it works

- Output names follow the DRM connector (`HDMI-A-1`). Old spellings (`HDMI-1`) are mapped by `find_renamed`; saved settings follow the new name.
- Probe (`control.probe`, background, about 30 s per monitor): runs at every manager start after `wake_all`; no hot-plug event triggers it (a DRM uevent only re-blanks outputs kept off); `probe(name)` probes one output on request. It reads EDID identity, matches `ddcutil detect` by identity first, then by connector name (`same_output`), stores `ddc_bus`, `ddc_capabilities`, `ddc_features` in `screen_control.json` (a monitor matching nothing gets empty `ddc_features`). Only one probe runs at a time; `Settings/Display/Screens/screens` is broadcast when it ends.
- The screens layer needs no display: `screens_at_start` wakes outputs and probes on a headless node, where both find nothing to do. Only the viewer is gated by `display_available`.
- Mechanisms: `output` (compositor), `ddc`, `cec`, `wol`, `serial`, `gpio`. `wol`, `serial`, `gpio` exist only when configured for the output.
- Availability: `output` when the compositor lists the output; `ddc` when ddcutil exists, a bus is probed and VCP `D6` is supported; `cec` when `cec_device` is set or exactly one adapter exists; others when configured.
- Auto order: on `wol, output, cec, ddc, serial, gpio`; off `output, ddc, cec, serial, gpio`. Per-output `on_mechanism` / `off_mechanism` override `auto`. An explicit mechanism is the only attempt, never rerouted. On `auto` each candidate is tried until one works; errors are joined in the message.
- Compositor power (`wayland.set_power`): off = `wlopm --off` (output stays enabled, window stays); if refused, `wlr-randr --output X --off`. On = `wlopm --on`, then `wlr-randr --on` with remembered position and transform if the output is still disabled.
- Kept off: outputs blanked by the node are blanked again when a DRM `change` uevent shows them active (a monitor that drops its link wakes the output). Listener exists only while some output is kept off.
- Availability of `ddc` requires ddcutil 2.0 or newer (`ddcutil --version`, timeout 10 s): an older one (1.4) reports the reason `ddcutil 2.0 or newer is required (found X.Y)`, distinct from `ddcutil is not installed`.
- Capabilities: when `ddcutil capabilities` gives nothing (often "Maximum DDC retries exceeded"), each code the node uses (`60`, `62`, `8D`, `D6`) is asked with `getvcp --terse` and kept if answered; one transient communication failure is retried first. Capability is per VCP code: a monitor that `detect` lists as `Invalid display` is kept (`valid=False`) because it can still answer codes. `capabilities` is slow (about 30 s cold), so only the background probe calls it. ddcutil's own cache is not used; the result lives in `screen_control.json`.
- `getvcp` makes 3 attempts 0.6 s apart; `setvcp` retries the same way on "communication failed" or "retries exceeded".
- Errors are typed: `Bus /dev/i2c-N does not exist` raises `BusNotFound`, `DDC communication failed` raises `CommunicationFailed`, `VCP xx ERR` (unsupported code) returns `None`, not an error.
- ddcutil runs as a CLI subprocess, not through the libddcutil binding: the ABI differs between 1.4 and 2.x and a hung I2C transaction must be killable by timeout. 2.2 has no JSON output: everything is parsed from text.
- The `ddc` power-off value is the first of `04, 05, 02, 03` that the monitor advertises (`04` when it advertises none). The wake reset (`05` then `01`) goes only to a monitor believed off: `05` switches an active one off.
- Blind mechanisms (`ddc`, `cec`, `serial`, `gpio`): the compositor cannot see a monitor in standby. The commanded state is stored in `/var/lib/unitotem/screen_state.json` (`commanded_off`: `{mechanism, at}`; override with `UNITOTEM_SCREEN_STATE`), forgotten on switch-on or when the output disappears. A switch-on tries that mechanism first.
- DDC power-off is never default. Read-back of `D6`: `01` on, `04/02/03` standby, `05` off, `None` unanswered.
- CEC implements standby, on and power status only (no input select; volume is relative and mute a toggle), via `cec-ctl` of v4l-utils over the kernel CEC API (`/dev/cec*`), not libcec. On: `--playback` (claims a logical address), `--to 0 --image-view-on`, `--active-source phys-addr=1.0.0.0`; off: `--to 0 --standby`. The physical address is fixed: a TV on another HDMI port is not made the active source with its real address. The Raspberry Pi `vc4_hdmi` exposes CEC; desktop Intel, AMD and NVIDIA GPUs generally have none.
- `gpio` modes: `level` (line asserted while on; asserted again before release at shutdown) and `pulse` (`pulse_ms` press for on and off). A pulse "on" on a screen not commanded off is refused ("the screen is already on").
- Start-up wake (`control.wake_all`, budget 240 s, every 20 s): switches on outputs that are off and have `power_on_at_start` (default true), skipping outputs the operator touched since start; also wakes monitors the node had put in standby. `wayland.wake_all` unblanks everything at start and after resume (no idle blanking in the compositor).
- Input, volume, mute: DDC only. Input source is refused unless the monitor advertised it. Volume 0-100 scaled to the monitor maximum. Mute `8D` 01/02.
- Touch devices: input devices with property DIRECT and absolute axes. Identity key = name, `vendor:product`, serial (sysfs), never `eventN`. `libinput_name` is what the compositor matches.
- Touch mapping: written as the `node` fragment of the labwc configuration (`<touch deviceName=... mapToOutput=...>`), then SIGHUP via `labwc.reload()`. labwc matches by name: two identical panels share one mapping (first wins).
- Fragments: `$UNITOTEM_LABWC_RUN/<name>/labwc/rc.xml` (default `/run/unitotem/labwc`), merged by labwc through `XDG_CONFIG_DIRS`. Elements are built with ElementTree, never pasted as text; illegal XML characters are dropped. `ensure_fragments()` writes empty valid ones so the compositor starts first.
- Automatic touch mapping: a device with no operator choice is mapped to the output when exactly one output is active (`touch.effective_mapping`); with several it stays automatic and the Display page asks. `touch_service.outputs_changed()` rewrites the mapping when a screen comes or goes. A device with no mapping spans the layout and ignores the output transform.
- Touch orientation: `turn` (quarter turns clockwise) and `flip` (0 none, 1 horizontal, 2 vertical) per device, for a panel not glued to its screen. A built-in panel follows its output rotation by itself.
- Guided setup (`touch_setup`): reads raw taps from the event node (no compositor in between), draws targets in the viewer window of the panel's output, mirrors state to the web page (`Settings/Display/Touch/setup`). Methods: `corners` (four corners, quadrants decide one of eight turn/mirror transforms) and `points` (five targets, least-squares affine matrix, refused when a tap is off by more than 8 % of the picture). Step timeout 60 s. Nothing is saved before `confirm_setup`; cancel, timeout, panel unplugged or restart restore the stored configuration.
- Window rotation: the compositor transform replaces content rotation. `wayland.CONTENT_TO_TRANSFORM` maps (turn, flip) to the `wlr-randr` transform, pixel-identical to the page turn: (0,0) normal, (0,1) flipped, (0,2) flipped-180, (1,0) 270, (1,1) flipped-270, (1,2) flipped-90, (2,0) 180, (2,1) flipped-180, (2,2) flipped, (3,0) 90, (3,1) flipped-90, (3,2) flipped-270 (turn = quarter turns clockwise, flip 1 horizontal, 2 vertical). Why the compositor: `wayvnc` captures the scanned-out picture, so a page turn shows the VNC window lying on its side and a click lands mirrored, while a compositor turn is upright and exact. Cost is the same either way (fps, dropped frames, CPU, GPU equal on three boards). The compositor owns window geometry: a window goes to its output through `SetFullscreenOnDisplay(display id)`. Boot splash: `boot_orientation.set_turn` runs the image helper `unitotem-boot-orientation set <connector> <name>` (`normal|right|inverted|left`, effective next boot), only when the value differs; quarter turns only.

## Interfaces

`Settings/Display/Screens/` (all calls answer with a `screens` broadcast: `screens`, `probing`):
- `screens()`: power or audio.
- `probe(name?)`: admin.
- `set_power(name, state, mechanism='auto')`: power. `state` `on|off`.
- `power_state(name)`: power. Per mechanism `output`, `ddc`, `cec`, `commanded_off`; None where unknown.
- `set_input(name, source)`: admin. `set_volume(name, volume)`, `set_mute(name, mute)`: audio.
- `gpio_lines()`: admin. Chips and lines with their users.
- `configure(name, on_mechanism?, off_mechanism?, power_on_at_start?, wol?, serial?, gpio?, cec_device?, clear_wol, clear_serial, clear_gpio)`: admin.
- Errors: `WSResponse(error=text)` with an operator-readable message.

`Settings/Display/Touch/` (admin; `devices`, `setup` pushed): `devices()`, `set_output(key, output?)` (None = whole screen), `forget(key)`, `set_orientation(key, turn=0, flip=0)`, `setup()`, `start_setup(key, method)`, `confirm_setup()`, `cancel_setup()`, `reset(key)`.

`Settings/Display/` (admin, `bounds` any user): `displays(viewer_id?)`, `orientation` / `set_orientation(viewer_id, window_id, orientation)`, `flip` / `set_flip`, `gpu_feature_stats()` (CDP `SystemInfo.getInfo` on the local viewer's loopback port), `allow_insecure_certs` / `set_allow_insecure_certs(allow)` (applied at the next viewer start), `bounds(viewer_id, window_id)`.

Files (directory of `--assets_file`, default `/etc/unitotem/`):
- `screen_control.json`: per output `{on_mechanism, off_mechanism, power_on_at_start, wol, serial, gpio, cec_device, identity, ddc_bus, ddc_capabilities, ddc_features}`. Atomic writes. Legacy mechanism name `x` reads as `output`.
- `touch_map.json`: `{mapping: {key: output}, orientation: {key: {turn 0-3, flip 0-2}}, calibration: {key: [6 floats]}}`.
- `/var/lib/unitotem/screen_state.json`: `{commanded_off: {output: {mechanism, at}}}`.

Config models:
- `wol`: `mac` (any separator, stored `aa:bb:..`), `broadcast` (255.255.255.255), `port` (9), `interface`, `repeat` (10, 1-30).
- `serial`: `port` (`/dev/ttyS*|ttyUSB*|ttyACM*|ttyAMA*|serial/by-id/*`), `baud` (9600; 1200-115200), `on_command`, `off_command` (ASCII with `\r \n \t \\ \xNN`).
- `gpio`: `chip` (`gpiochipN`), `line` (0-1023), `mode` (`level|pulse`), `active_low`, `pulse_ms` (500, 50-5000).
- Output names match `^[A-Za-z0-9_.-]{1,64}$`; no leading dash reaches a tool.

External tools: `wlr-randr`, `wlopm`, `ddcutil`, `cec-ctl`, `unitotem-boot-orientation`, python `gpiod`, libinput (`libinput.so.10`). Subprocess timeouts: ddcutil detect 60 s, capabilities 90 s, getvcp/setvcp 15 s, cec-ctl transmit 20 s, `--list-devices` 10 s, ddcutil `--version` 10 s, wlr-randr 10-15 s.

Backup: only `touch` (the mapping, not orientation or calibration) is a backup part. `screen_control.json` is not in backups.

## Rules and gotchas
- Touch methods, in this order: automatic (libinput calibration matrix follows the output transform), four-quadrant mapping, exact-point calibration. The UI is a guided step view in plain words. Test against a real panel, never only a virtual device.

- No `shell=True`: names, ports, MACs, chips are validated before use; paths are never built from input.
- ddcutil 2.2 prints connector-resolution diagnostics on stdout before the real result when it cannot resolve a DRM connector: parsers match each line by prefix (`Display N`, `Invalid display`, `VCP`, `DRM connector`), never by position.
- `cec-ctl` exit codes are reliable (a missing device returns 1); an empty `--list-devices` with exit 0 means no adapter, not an error.
- The proprietary NVIDIA driver has no per-connector directories in `/sys/class/drm`: the EDID is unreadable and the join uses the connector name ddcutil reports. `edid_identity` returns `None` for a disconnected output, a monitor without EDID or garbage: identity is unknown, not an error.
- DDC writes use `--noverify`: return code 0 does not prove a switch, and a monitor with no signal on the target input ignores an input write.
- labwc keeps the last libinput `calibrationMatrix` it applied when a device's entry disappears: every connected device gets a matrix, the identity included. Clearing an orientation or forgetting a panel writes the identity.
- A device named like a compositor category (`default`, `touch`, `touchpad`, `non-touch`, `tablet`, `tablet-pad`) gets no per-device entry. One NUL in the configuration makes labwc silently load its default one: `labwc.xml_clean` drops what XML cannot hold.
- GPIO: the chip is a name (`gpiochipN`) normalised by `normalise_chip`. A `level` line is requested at the wanted value and held while the manager lives; `release_all()` asserts every held line at shutdown, so a stopped manager never leaves a screen dark. A pulse on a line held by a level screen is refused.
- Tool calls run in a thread (`asyncio.to_thread`); per-output and per-bus locks serialise power and DDC calls.
- A DDC read-back of `D6` may say "on" for a dark panel: trust `commanded_off`.
- Many monitors do not answer DDC/CEC while off; a wake can take about a minute to show the source.
- A DDC probe is slow (`capabilities` about 31 s cold, `detect` several seconds) and runs in the background at each start.
- Never address a monitor with `ddcutil -d N`: it re-runs detection on every call and reproduces "Maximum retries exceeded". Use `--bus N`, one VCP code per call.
- The `screens` package imports no PySide6 or cefpython (stdlib, loguru, `utils.outputs` only), so `api/display.py` stays importable headless; it duplicates the CDP port as a literal for this reason. `Screens = Screens` in `api/display.py` keeps the path `Settings/Display/Screens/*` while the class lives in `api/display_screens.py`.
- ddcutil prints no `DRM connector` line on some drivers (and accepts both `DRM connector` and `DRM_connector`): there the EDID identity join is the only match, not a fallback.
- WOL has no off; it is never offered for switching off.
- Touch identity never uses `eventN`; a two-interface USB panel is named with its USB suffix by libinput, so the kernel name matches nothing in labwc.
- Plymouth cannot mirror: only quarter turns go to the kernel command line; the boot partition is written only when the value changes.

## Tests

- `pytest manager/tests/test_ddc_parsers.py test_identity.py test_mechanism_resolution.py test_screens_blind_power.py test_screens_gpio.py test_screens_io.py test_touch.py test_touch_calibration.py test_touch_panel.py test_touch_setup.py` from the repository root.
