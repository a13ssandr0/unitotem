# VM and board test lab

The libvirt guest that runs the amd64 kiosk image, and the tools that deploy to and measure real boards. Unit tests and browser tools: [testing.md](testing.md).

Paths: relative to `unitotem-manager/`

## Files

| Path | Role |
|---|---|
| `tools/vm-env.sh` | `VM_*` settings and SSH options, sourced by the VM helpers |
| `tools/vm-ssh`, `tools/vm-deploy` | Run a command in the test VM; rsync the working copy and restart the manager (`--no-restart` skips restart) |
| `tools/unitotem-test.xml`, `unitotem-test-gpu.xml`, `unitotem-ab.xml` | libvirt domains: virtio GPU with 2 heads and NAT; GPU passthrough; second VM for A/B update |
| `tools/gfx-bench/` | On-target graphics benchmarks (WebGL, video decode, Chrome trace, Wayland harness); own `README.md` |
| `tools/gfx-bench/rotation/` | Rotation benches: `rotation-bench.py` (workloads per configuration A, B1/B3 page turn, C90/C270 compositor turn), `rotation-equivalence.py` (pixel comparison through a camera or capture device on the dev PC; needs `--host` and `--camera`), `rotation-vnc.py` (VNC click check), `rotation-touch.py`, `report.py` (tables) |
| `tools/wayland/session.sh` | `start` or `stop` (root, over ssh): runs the real `unitotem-compositor.service` plus the manager from a copy of a dev tree as transient unit `unitotem-wl-test`; `stop` gives the board its normal session back |
| `tools/ticker/deploy-board.sh` | Deploys a dev tree to a board by bind mounts |

## How it works
- Guest: libvirt domain `unitotem-test` on `qemu:///system`, boots the amd64 kiosk image from a qcow2 overlay. The default NAT network gives it a fixed address through a DHCP reservation for the domain MAC (`net-update ... --live --config`); no port forwarding, so the manager keeps ports 80 and 443. Web UI over HTTPS on that address, SSH as root.
- Files: overlay, `OVMF_VARS.fd` and the serial log are in `/var/tmp/unitotem-vm/`. The serial console is the file `serial.log`, the only diagnostic before sshd runs. SSH key and `known_hosts` are outside the manager repository (defaults in `vm-env.sh`).
- `vm-deploy` rsyncs `manager/{api,routers,templates,utils,webview,plugins,resources,static}`, `init.py`, `main.py`, `requirements.txt` to `/var/unitotem-manager` (excludes `__pycache__`, `uploaded`); the unit runs `/var/unitotem-venv/bin/python3 /var/unitotem-manager/init.py`. Guest units: `unitotem-manager`, `start-xorg.service` (X on `:0`, auth `/run/unitotem-x11.auth`).
- Display: the virtio video device declares `heads=2` (`virtio-vga,max_outputs=2`) for multi-monitor tests; the second connector starts disconnected and costs nothing when unused.
- GPU passthrough domain (`unitotem-test-gpu.xml`): the GPU and its HDMI audio function are two managed `hostdev` entries; video model `none`, no `graphics` element. The guest displays on the card's physical monitor, so nothing else is needed to see its screen; `virsh screenshot` does not work.
- Web login is PAM: test accounts are system users in group `unitotem`; the guest venv needs `python-pam` (`manager/requirements.txt`).
- Screenshots: `virsh screenshot` (virtio only) writes PPM; convert with ImageMagick. It paces at a few frames per second: to catch a transient (boot splash, flash on window creation) start the capture loop before triggering the event.
- Board deploy by bind mount (`deploy-board.sh`): changed files are copied under `/var/lib/unitotem/<dir>` and bound over `/usr/share/unitotem-manager/<path>` (a read-only `/usr` allows file binds), then `unitotem-manager` restarts; binds vanish at reboot. A new package directory cannot be bound file by file (no mount point), so the script binds whole directories (`api`, `utils`, `webview`, `static`, `templates`, `routers`, viewer and node plugins). Python packages missing from the image (for example `python3-feedparser` before the package with the new `Depends` is installed) go on `PYTHONPATH` through a volatile drop-in.
- `session.sh` needs the `labwc`, `wlrctl`, `wlr-randr`, `wlopm`, `wayvnc`, `qt6-wayland` and `xwayland` packages extracted with `dpkg-deb -x` under `W` (default `/var/lib/unitotem/wl`).
- CPU and decoder measurement: see [testing.md](testing.md).

## Interfaces
- `vm-env.sh`: `VM_HOST`, `VM_USER` (default `root`), `VM_KEY`, `VM_KNOWN_HOSTS`, `VM_APP_DIR` (`/var/unitotem-manager`), `VM_VENV` (`/var/unitotem-venv`), `VM_RSYNC_PATH` (`/usr/bin/rsync`), `VM_SSH_OPTS` (derived: key, known_hosts, `accept-new`, `BatchMode=yes`, `ConnectTimeout=10`); `SSH_ASKPASS_REQUIRE=never` forced, `SSH_ASKPASS` unset.
- `session.sh start|stop`, env `W`.

## Rules and gotchas
- Never bare `ssh`/`scp`: use `tools/vm-ssh` and the `vm-env.sh` options. `scp` needs `-O` (guest sshd has no SFTP subsystem); `rsync` is unaffected.
- Do not build a `.deb` to test a code change: `tools/vm-deploy` (rsync plus restart, about 1 s) is the loop. Build a package only when the packaging itself is under test.
- `vm-deploy` refuses without `manager/static/manifest.json`: run `npm run build` in `webui/` first. Manifest and `assets/` deploy together or the server serves stale bundles silently.
- `vm-deploy` rsyncs with `--delete` and takes no lock: on a shared VM it silently removes another agent's code (shows as the misleading websocket error `Invalid command`). Serialise deploy, test and restore by hand; kill by PID, never `pkill` by name.
- `pkill -f <pattern>` inside an ssh command line matches the command's own shell and kills it, so the rest never runs (a restart was skipped, the manager stayed down). Use `pkill -x name`, a PID, or a pattern like `[i]nit.py`.
- Guest root is read-only. Code goes to `/var` (writable overlay on DATA), never `/usr`.
- `rsync -a` keeps the source uid: `chown root:root` every file under `/etc` (sudo ignores non-root files in `sudoers.d`).
- Do not use `unitotem-maintenance enter/exit` to install packages for the VM bootstrap: `exit` reboots the guest 5 s later and can rebuild initramfs and GRUB (see [image-runtime.md](../system/image-runtime.md)). A manual remount rw, install, `sync`, remount ro is enough.
- journald keeps warnings only (`MaxLevelStore=warning`). For INFO and tracebacks: stop the unit, run `init.py` by hand with `DISPLAY=:0 XAUTHORITY=/run/unitotem-x11.auth` under `timeout`, redirect to a file.
- `systemctl stop unitotem-manager` must return in seconds; a hang is a shutdown bug. A stray old manager keeps ports 443 and 4443: kill it by PID with its CEF subprocesses.
- Guest `/var/tmp` is a 64 MiB tmpfs and empties at reboot. Large files: `TMPDIR` on DATA. Symptom of an overflow: `mkinitramfs` dies with `No space left on device` naming only the file it copied, leaves `linux-image` unconfigured and dpkg wedged; fix with `TMPDIR` on DATA, then `dpkg --configure -a`. Helper scripts belong in `/var/opt/vmtest/` (persistent overlay).
- Missing Qt xcb libraries abort with a misleading "libxcb-cursor0 is needed". Check `ldd .../PySide6/Qt/plugins/platforms/libqxcb.so | grep "not found"`.
- Hot-plug (virtio): `echo on > /sys/kernel/debug/dri/0/Virtual-2/force`, then poll `xrandr --query` until the mode list appears (X needs a moment to re-probe; `xrandr --mode` before that fails with `cannot find mode`, no event reaches the manager and the test exercises nothing). Read the mode list, never hard-code it. `/sys/class/drm/*/status` is unusable. Unplug: `xrandr --output Virtual-2 --off`, then `force` off.
- Hot-plug (proprietary NVIDIA driver): no connector debugfs; toggle with `xrandr --output <OUT> --off` and `--mode`. `--addmode` fails with `BadMatch` for any mode the display EDID does not advertise: plan around the EDID mode list.
- Hot-plug dead ends, do not retry: `xrandr --auto` (no EDID); forcing a CRTC or mode without the debugfs `force` (Qt ignores it); RandR 1.5 `--setmonitor` (Qt filters on the Connected bit); QEMU `-display dbus`; any QMP command for output state (none exists); SPICE (`spice-vdagentd` needs a logind session).
- Virtio accelerated GPU (`accel3d`, `egl-headless`) is a dead end: QEMU fails with `egl: render node init failed` on the proprietary NVIDIA render node. GPU acceleration in the VM is passthrough (`unitotem-test-gpu.xml`). Looking Glass is a dead end too (its host application aborts with `lgmpHostMemPtr` assertion before publishing a frame) and unneeded: the passthrough card drives a physical monitor.
- `virsh undefine` only with `--keep-nvram`; `--nvram` deletes the OVMF vars file and the VM stops booting. Compare `virsh domstate` output with `LC_ALL=C` (it is localised).
- Back up `overlay.qcow2` with `cp --reflink=auto` before a driver experiment: on a reflink filesystem the copy is nearly free and restores a broken guest in seconds. Back up `users.json` before first-access or reset tests on a shared VM, or use a throwaway container.
- NVIDIA proprietary driver: DKMS builds against `linux-headers-amd64`, the newest kernel rather than the running one, so reboot afterwards. Nouveau needs no install (the stock kernel binds it): `glxinfo -B` reports `Accelerated: yes`, and in the browser `Settings/Display/gpu_feature_stats` moves `gpu_compositing`, `rasterization`, `opengl`, `webgl` and `video_decode` from disabled to enabled.
- Video assets: check `canPlayType` first. WebM (VP9/Opus) plays on any CEF build; H.264/AAC need the codec-enabled wheel (see [cef.md](cef.md)). Test video: `ffmpeg -i <source> -c:v libvpx-vp9 -b:v 4M -deadline realtime -cpu-used 8 -row-mt 1 -tile-columns 2 -c:a libopus -b:a 128k <out>.webm`, rsync it to `/var/unitotem-manager/uploaded/` on the guest (`VM_*` SSH options), then `Scheduler/add_file`; verify the `<video>` state through CDP.
- Zero screens: force every connector off; the manager stays up and the web UI works.
- Viewer checklist after touching `manager/webview/`: starts; ports 80 to 443; hot-plug and unplug seen as pushed `Viewers/list` frames (window ids increase, never reused); zero screens; no white flash on window creation; fast shutdown; playback (image, video, web page, `fit`, `bg_color`, per-asset volume).
- Boards: after any deploy check `systemctl show unitotem-manager -p NRestarts` and `ss -ltnp | grep :443`. A manager that survives `systemctl stop` is killed by PID, never with `pkill -f`.
- Rotation tests: `rotlib.Board` starts a safety net `sleep 3000; wlr-randr --transform normal` on the board. A script that dies before `__aexit__` leaves it, and the screen turns back to normal 50 minutes later (looks like a product bug); `rotlib` kills it when `__aenter__` fails, but after an interrupted run check `ps` for `sleep 3000` on every board.
- Touch tests: the virtual panel must carry the real panel's `phys` and have a sibling node of the same name, or labwc matching differs and tests stay green while the real panel is wrong. A tap test uses an off-centre point (a centre tap proves nothing for rotation). `rotation-touch.py` has `--unmapped` and `--manual`; `touchrec.py` writes each tap as it happens. A page with an autofocus text field opens the on-screen keyboard, which swallows taps in its default box: `rotation-touch.py` closes it first.
- labwc tests: `labwc -d` logs `[map] identifier=, title=` per window. A rule or keybinding with wrong quoting makes labwc silently load the DEFAULT config (look for `error parsing config file`). Chromium rewrites `/proc/<pid>/environ` (it looks empty): check the environment with a shim that prints `getenv`. `umount` of a bind-mounted `libcef` reports busy while the viewer runs.
- Audio tests: a recording of a sink MONITOR does not show the sink volume or mute (taken before them). `pw-record` needs SIGINT to finish its file and a background shell leaves SIGINT ignored: reset the disposition (`signal SIG_DFL`) then `exec`. Chromium with no PulseAudio server makes no sound and does not fall back to ALSA.
- Graphics benches: a `requestAnimationFrame` counter keeps ticking when the WebGL context is null, so count draws and check the context. A CDP `/json/new` window is not the screen size: print `innerWidth x innerHeight` and fix the size. A stray video tab keeps decoding and pollutes the next run. Kill tools by script file, not `pkill -f` inside ssh. On a Pi 4 the same page sometimes comes up in a fast mode (WebGL, heavy shader, canvas all much faster) after about one reload in five: it follows the page load, not the transform, so repeat reloads and never compare single loads.
- Judge Plymouth visuals only on real captured boot frames: a reimplementation of `Image.Rotate` and `Scale` did not reproduce the faceting. Confirm a frame is Plymouth by its status line (the webview shows near-identical graphics), and start the capture loop before the reboot.
- In a per-thread CPU listing, `ThreadPoolForeground` and `VizCompositorThread` at the top mean software rasterisation, not a busy loop. The viewer cost is in the CEF subprocess tree, not the Python pid (the main pid reads about 1 % while the tree is far higher).

## Procedure
1. Host: groups `kvm`, `libvirt`; packages `qemu-system-x86 libvirt-daemon-system ovmf imagemagick`.
2. Images under `/var/tmp/unitotem-vm/` (`qemu:///system` cannot read home): `xz -dc <amd64 image> > base.img`; `qemu-img create -f qcow2 -b base.img -F raw overlay.qcow2 16G`; `cp OVMF_VARS_4M.fd OVMF_VARS.fd`.
3. `virsh define tools/unitotem-test.xml`; DHCP reservation with `net-update ... --live --config`; `virsh start`.
4. `ssh-copy-id` once (bootstrap only); `tools/vm-ssh hostname` prints `unitotem`.
5. One-time bootstrap: grow DATA (`sfdisk`, `partx -u`, `resize2fs`); remount root rw; install `libxcb-cursor0 libxcb-keysyms1 libxcb-icccm4 libxcb-shape0 libdbus-1-dev libglib2.0-dev rsync`; remount ro; copy a venv to `/var/unitotem-venv` (PySide6, the amd64 `cefpython3` wheel from `vendor/cefpython-wheels/`, `manager/requirements.txt`); unit override with `WorkingDirectory` and `ExecStart` above; sudoers file (`chown root:root`); disable haproxy (holds 80 and 443). Rebuild the venv only when `manager/requirements.txt` or the CEF wheel changes.
6. Loop: `npm run build` in `webui/`, `tools/vm-deploy`, run UI tools, check logs.
7. Limits: `apt dist-upgrade` cannot work on the read-only root; the Updates page is tested on a headless install only.
8. GPU domain: `virsh destroy`, `undefine --keep-nvram`, `define` the other XML, `start`.

Package build and CEF rebuild: [packaging.md](packaging.md), [cef.md](cef.md).
