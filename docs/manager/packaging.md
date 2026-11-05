# Packaging

Debian packages of `unitotem-manager` (native source package, format `3.0 (native)`), build scripts and the apt repository.

Paths: relative to `unitotem-manager/`

## Packages
Built from `debian/control`. Version scheme `3.0.0~devNN` for pre-releases (all packages share the source version).

| Package | Arch | Content | Depends on |
|---|---|---|---|
| `unitotem-manager` | all | Core orchestrator: `api`, `routers`, `templates`, `utils`, `resources`, `static`, `webview`, `init.py`, `main.py` in `/usr/share/unitotem-manager`; launcher `/usr/sbin/unitotem-manager`; unit; PAM service; man page | Python libraries (see control); Recommends `unitotem-node` |
| `unitotem-node` | all | `plugins/unitotem_node`: network, audio, displays, power, timers, updates, terminal, VNC, hotspot | core, `network-manager`, `netplan.io`, `wlr-randr`, `wlopm`; Recommends `alsa-utils`, `ddcutil`, `wayvnc`, `v4l-utils`, `python3-libgpiod` |
| `unitotem-viewer` | all | `plugins/unitotem_viewer`, compositor and splash units, labwc base config, Plymouth PNGs | core, node, `python3-cefpython3`, PySide6 (QtCore, QtGui, QtWidgets), `labwc`, `qt6-wayland`, `python3-sdbus` |
| `unitotem` | all | Metapackage: manager, node, viewer. Recommends `plymouth-theme-unitotem` | the three |
| `python3-cefpython3` | any | CEF 147 with codecs and bindings, unpacked from a wheel | `python3 (>= 3.13), (<< 3.14)` |
| `plymouth-theme-unitotem` | all | Theme `unitotem` (script module, four width tiers) | `plymouth` |

Third-party packages built in `packaging/` (not in Debian): `python3-fastapi-login` (1.10.3), `python3-sdbus-networkmanager` (2.0.0), version suffix `-0unitotem1`. Each has `debian/` only; the sdist is downloaded from PyPI at build time.

## Files
- `debian/control`, `debian/rules`, `debian/changelog`, `debian/copyright`, `debian/source/format`.
- `debian/unitotem-manager.{install,dirs,postinst,postrm,service,sh,pam,8}`: `.install` installs the man page; `.dirs` creates `/etc/unitotem` and `/usr/share/unitotem-manager/plugins`.
- `debian/unitotem-node.install`: `01-unitotem-nm.yaml` to `/etc/netplan`, `10-wayland.conf` to the manager unit's drop-in directory, `org.unitotem.Notifications.conf` to `/usr/share/dbus-1/system.d`, `90-unitotem-arp.conf` to `/usr/lib/sysctl.d`.
- `debian/unitotem-viewer.unitotem-{compositor,splash}.service`, `debian/labwc-rc.xml`: see [viewer.md](viewer.md).
- `debian/plymouth-theme-unitotem.{postinst,prerm}`.
- `debian/*.lintian-overrides`: netplan file mode 0600; embedded Chromium libraries in `libcef.so`.
- `debian/tests/{control,unit}`: autopkgtest `unit` (needs root, allows stderr): copies `manager/tests`, runs pytest with `PYTHONPATH=/usr/share/unitotem-manager`.
- `tools/build-debs.sh`: container build. `plymouth/generate-assets.py`: renders theme PNGs (wordmark, spinner; tiers 1280, 1920, 2560, 3840). `manager/requirements*.txt` and `manager/plugins/*/requirements.txt`: Python dependencies for a development venv (not packaged: `debian/rules` deletes them). `frozen_requirements.txt`: pinned pip versions, not used by any script.
- `docs/`: GitHub Pages apt repository (`Packages`, `Packages.gz`, `Release`, `Release.gpg`, `InRelease`, `KEY.gpg`, `unitotem-manager.list`, `*.deb`) plus developer notes. `docs/update-pkgs.sh` regenerates it.

## How it works
Build (`debian/rules`):
- `dh_auto_build-indep`: `cd webui && npm ci && npm run build` (needs network). `dh_auto_test` is empty: tests need cron and a writable `/etc/unitotem` (see `debian/tests`).
- Install: core directories copied to `usr/share/unitotem-manager`; each plugin to its own package; Plymouth `wordmark-*.png` and `spinner-*.png` copied to the viewer's `static/bootsplash/`; `__pycache__` and `requirements.txt` removed; files 644 except `*.sh`.
- `dh_python3` runs per package on its own directory, so no package shares modules with another.
- `dh_builddeb -Zgzip`: gzip so that older dpkg on a system being updated can read the packages.
- `unitotem-manager.service`: `dh_installsystemd`, enabled and started. `unitotem-splash.service`: enabled, not started on install (it would sit on a running screen). `unitotem-compositor.service`: neither enabled nor started; the image enables it.
- `python3-cefpython3` (`dh_auto_install-arch`): unpacks `vendor/cefpython-wheels/cefpython3-*-cpXY-*-linux_<cpu>.whl` matching the build Python (`PYTAG`) and CPU; the build fails when there is none and never falls back to the stock `cefpython3` wheel (every UniTotem CEF build ships proprietary codecs), sets rpath of `cefpython3/subprocess` to `$ORIGIN`, deletes every locale pak except `en-US.pak`, `chmod 755` on `subprocess`. `dh_strip --no-automatic-dbgsym` (libcef.so 465 MB unstripped, 252 MB stripped), `dh_python3` skipped (it would rename `libcef.so` with an ABI tag), `dh_shlibdeps` with `-l` on the package directory.
- `unitotem-node`: `01-unitotem-nm.yaml` chmod 600 (netplan refuses wider modes).
- Plymouth spinner (`plymouth/unitotem/unitotem.script`): `Image.Rotate` pivots on integer division, so the script forces the ring size odd (`size += 1` when even) or the ring wobbles. The ring PNG is rendered at `SPINNER_OVERSAMPLE=2` times its displayed size and the script divides by the same factor, so `Scale()` averages pixels before every `Rotate()`; bilinear-only rotation facets the circle. A new rotating sprite needs the same 2x source.

Maintainer scripts:
- `unitotem-manager.postinst` (configure): creates system group `unitotem` (members and root may log in); creates `/etc/ssl/unitotem.pem` (self-signed RSA 2048, 36500 days, kept across upgrades; paired nodes trust it) once.
- `unitotem-manager.postrm` (purge): removes `/etc/ssl/unitotem.pem`, `/etc/unitotem`, `/var/lib/unitotem`.
- `plymouth-theme-unitotem.postinst` (configure): `update-alternatives` for `default.plymouth`, `plymouth-set-default-theme unitotem`, `update-initramfs -u` (failures ignored).

Runtime units and config:
- `unitotem-manager.service`: `Type=notify`, `NotifyAccess=main`, `TimeoutStartSec=300`, `StateDirectory=unitotem`, `Restart=on-failure`, `RestartSec=10`, `KillMode=process`, default `SIGTERM` (CEF disables the `SIGINT` handler; never set `KillSignal=SIGINT`).
- `10-wayland.conf` (node): `Wants=`/`After=user@0.service`; `XDG_RUNTIME_DIR=/run/user/0`; `WAYLAND_DISPLAY=/run/unitotem/xdg/wayland-0`.
- PAM service `/etc/pam.d/unitotem-manager`: `common-auth`, `common-account`; the group check is in `manager/utils/osusers.py`.
- sysctl `90-unitotem-arp.conf`: `arp_ignore=1`, `arp_announce=2` (several interfaces on one subnet).
- D-Bus policy: only root owns `org.freedesktop.Notifications`; anyone may send to it.

## Interfaces
`tools/build-debs.sh WHAT` (needs Docker; builds in `debian:trixie`, runs `lintian`, output in `dist/`):

| WHAT | Builds |
|---|---|
| `third-party` (default) | `python3-fastapi-login`, `python3-sdbus-networkmanager` |
| `main` | `unitotem-manager`, `unitotem-node`, `unitotem-viewer`, `unitotem`, `python3-cefpython3`, `plymouth-theme-unitotem` (installs the third-party debs from `dist/` first; removes `manager/static`, `webui/node_modules` in the copy) |
| `cefpython` | Only `python3-cefpython3`, no npm |
| `all` | `third-party` then `main` |

- Env: `TARGET_ARCH` (`amd64` default, `arm64` cross builds `python3-cefpython3` with `crossbuild-essential-arm64`, no emulation), `PLATFORM` (container platform, default `linux/amd64`). Arch-all packages are identical on every architecture.
- `cefpython` copies the `cp313` wheel of the target CPU only from `vendor/cefpython-wheels/` (the package pins Python 3.13).
- `docs/update-pkgs.sh`: `dpkg-buildpackage -A`, copies `../unitotem-manager_*.deb` to `docs/`, then `dpkg-scanpackages --multiversion`, `Packages.gz`, `apt-ftparchive release`, signs `Release.gpg` and `InRelease` with the maintainer key.
- apt client: `docs/unitotem-manager.list` (`deb https://a13ssandr0.github.io/unitotem-manager ./`), key `KEY.gpg` into `/etc/apt/trusted.gpg.d/`.

## Rules and gotchas
- Plugin packages share nothing: a module imported by two packages belongs to the core.
- Package dependencies are listed by hand (`dh_python3` does not scan imports that are lazy).
- Blank lines in `debian/control` separate the stanzas: removing them gives `duplicate field Package found`.
- CEF's own libraries (`libgtk-3-0t64`, `libnss3`, ...) are in Build-Depends so `dpkg-shlibdeps` computes the `python3-cefpython3` Depends instead of guessing; the Debian t64 package names apply.
- `unitotem-viewer` and `unitotem-node` depend on the exact core version (`= ${source:Version}`).
- Do not enable `unitotem-compositor.service` from the package; the image decides.
- `ddcutil` is a Recommends of `unitotem-node`, never a Depends and never versioned: a versioned dependency would make the package uninstallable on a distribution with an older ddcutil. The runtime gate (`supports_ddc`, ddcutil 2.0 or newer) reports DDC unavailable with the reason instead. `i2c-tools` is not in the Recommends (image package set only).
- DDC/CI and CEC need `/dev/i2c-*`: the image's stage 2 writes `/etc/modules-load.d/unitotem-i2c.conf` (`i2c-dev`); without it the manager reports both unavailable. Stage 1 installs `ddcutil`, `v4l-utils` (`cec-ctl`) and `i2c-tools` from the distribution archive.
- Do not run `dh_python3` on `python3-cefpython3` (ABI tag renames break CEF's own library loading).
- The apt repository in `docs/` holds `unitotem-manager` 2.1.0 to 2.3.0 only (older single-package line).
- A development venv uses `manager/requirements.txt` plus the plugin files; `cefpython3` has no PyPI release and comes from `vendor/cefpython-wheels/`.

## Tests
- `python -m pytest` from the repository root (see [testing.md](testing.md)); `debian/tests/unit` repeats it against the installed package.
- `tools/build-debs.sh` runs `lintian --info --display-info` on every built `.deb`.
