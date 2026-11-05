# Third-party notices

UniTotem itself is GPL-3.0 (see [LICENSE](LICENSE)). This file lists the third-party material it contains or ships.
Paths are relative to the repository root; `unitotem-manager/` is a submodule. The Debian package metadata of the manager
is in `unitotem-manager/debian/copyright`.

## Image builder (this repository)

| Component | Used as | Path | License | Copyright | Upstream |
|---|---|---|---|---|---|
| pi-gen | Fork: build framework (`build.sh`, `scripts/`, `stage0`-`stage2`, `export-image`, Dockerfile, patches, `files/`) | `build.sh`, `build-docker.sh`, `Dockerfile`, `scripts/`, `stage0/`, `stage1/`, `stage2/`, `export-image/` | BSD-3-Clause (full text below) | 2015 Raspberry Pi (Trading) Ltd. | https://github.com/RPi-Distro/pi-gen |
| raspi-config `init_resize.sh` | Patched with a diff (part of the pi-gen stages) | `stage1/01-sys-tweaks/01-patches/02-init_resize.diff` | MIT-style (raspi-config) | Raspberry Pi (Trading) Ltd. | https://github.com/RPi-Distro/raspi-config |
| RaspberryPi-ImgAutoSizer | Adapted code: `resize_qcow2()` (e2fsck, resize2fs, parted) | `scripts/qcow2_handling` | GPL-3.0 | SirLagz | https://github.com/SirLagz/RaspberryPi-ImgAutoSizer |
| Raspberry Pi archive keyring | Public key copied | `stage0/files/raspberrypi.gpg` | Public key | Raspberry Pi (Trading) Ltd. | https://archive.raspberrypi.com/ |
| Debian and Raspberry Pi OS packages | Installed into the images (not copied into the repository) | `unitotem/stage1-packages.sh`, `unitotem/locks/` | Per package, see below | Per package | https://www.debian.org/ , https://archive.raspberrypi.com/ |
| Debian debconf choice lists | Choice lists copied into comments | `stage2/01-sys-tweaks/00-debconf` | GPL-2+ (package data) | Debian debconf authors | https://www.debian.org/ |

Not stored, only linked in `README.md`: DonateButtons (GPL-3.0, https://github.com/aha999/DonateButtons) and the
Buy Me a Coffee / PayPal images (brand assets of their owners).

### Debian and Raspberry Pi packages in the images

Each package keeps its own license text in `/usr/share/doc/<package>/copyright` inside the image. The images contain
GPL/LGPL software (Linux kernel, GRUB, systemd, glibc, ...). When an image is distributed, the corresponding source is
available from the Debian and Raspberry Pi archives (`deb-src`); the exact package versions of each image are pinned in
`unitotem/locks/` (snapshot.debian.org). A copy of the source for any of them is also available on request to the
project maintainer for three years after the image was distributed. The amd64 images also copy the shim and GRUB
binaries signed by Microsoft/Debian to the ESP (`unitotem/stage3-image.sh`); NVIDIA and Debian non-free firmware are
installed as packages under their own licenses.

## Manager (Python, `unitotem-manager/manager/`)

| Component | Used as | Path | License | Copyright | Upstream |
|---|---|---|---|---|---|
| psutil | Copied code: `cpu_times_percent()` and its globals; `sensors_temperatures()` derived from it (BSD text below). The `psutil` package itself is a runtime dependency. | `manager/utils/system/cpu.py`, `manager/utils/system/sensors.py`, `manager/utils/system/procfs.py` | BSD-3-Clause | 2009 Jay Loden, Dave Daeschler, Giampaolo Rodola | https://github.com/giampaolo/psutil |
| Ansible `flatten` filter | Copied code: `flatten()` | `manager/utils/objs.py` | GPL-3.0-or-later | 2012 Jeroen Hoekx (file header of the upstream commit) and Ansible contributors | https://github.com/ansible/ansible/blob/0830b6905996fb02eefcba79a9b055961e251078/lib/ansible/plugins/filter/core.py |
| Stack Overflow answer 61730849 | Adapted snippet: `get_dominant_color()` | `manager/utils/storage/file_info.py` | CC BY-SA 4.0 | Pithikos (https://stackoverflow.com/users/474563) | https://stackoverflow.com/a/61730849 |
| Stack Overflow question 45419723 | Adapted snippet: `Timer` class | `manager/utils/async_timer.py` | CC BY-SA 3.0 | Mikhail Gerasimov (answer 45430833) | https://stackoverflow.com/questions/45419723/python-timer-with-asyncio-coroutine |
| Chromium `chrome://gpu` (`info_view.ts`) | Data tables (feature labels and status colors) ported | `manager/utils/system/gpu.py`, `webui/src/pages/settings/display.vue` | BSD-3-Clause | The Chromium Authors | https://chromium.googlesource.com/chromium/src/+/main/content/browser/resources/gpu/info_view.ts |
| python-fastapi-login | Repackaged unmodified as a .deb and installed in the image | `unitotem-manager/packaging/python-fastapi-login/` | MIT | 2019-2024 Max Rausch-Dupont | https://github.com/MushroomMaula/fastapi_login |
| python-sdbus-networkmanager | Repackaged unmodified as a .deb and installed in the image | `unitotem-manager/packaging/python-sdbus-networkmanager/` | LGPL-2.1-or-later | 2020-2024 igo95862 | https://github.com/igo95862/python-sdbus |
| 404 page image | Own work, not third-party | `manager/resources/404.png` | GPL-3.0 (project) | Alessandro Campolo | - |

The Stack Overflow snippets are user contributions licensed under CC BY-SA
(https://creativecommons.org/licenses/by-sa/4.0/ and https://creativecommons.org/licenses/by-sa/3.0/). The URLs lead to the answers.

## Web UI bundle (`unitotem-manager/webui/`, built into `unitotem-manager/manager/static/`)

The files in `manager/static/assets/` are generated by Vite from `webui/`; exact versions are in
`webui/package.json` and `webui/package-lock.json`.

| Component | Used as | Path | License | Copyright | Upstream |
|---|---|---|---|---|---|
| Vue, vue-router, pinia | Bundled library | `manager/static/assets/*.js` | MIT | Evan You and contributors | https://github.com/vuejs |
| Vuetify | Bundled library | `manager/static/assets/*.js`, `*.css` | MIT | Vuetify, LLC and contributors | https://github.com/vuetifyjs/vuetify |
| @vueuse/core | Bundled library | `manager/static/assets/*.js` | MIT | Anthony Fu and contributors | https://github.com/vueuse/vueuse |
| Chart.js | Bundled library | `manager/static/assets/*.js` | MIT | Chart.js contributors | https://github.com/chartjs/Chart.js |
| vuedraggable, SortableJS | Bundled library | `manager/static/assets/*.js` | MIT | SortableJS contributors | https://github.com/SortableJS/vue.draggable.next |
| xterm.js (@xterm/xterm, @xterm/addon-fit) | Bundled library | `manager/static/assets/*.js`, `*.css` | MIT | The xterm.js authors, Microsoft Corporation | https://github.com/xtermjs/xterm.js |
| noVNC (@novnc/novnc 1.7.0) | Bundled library (core files MPL-2.0, source at the upstream URL; vendored pako MIT) | `manager/static/assets/*.js` | MPL-2.0 (pako: MIT) | 2022 The noVNC authors, Joel Martin; pako: Vitaly Puzrin, Andrei Tuputcyn | https://github.com/novnc/noVNC |
| simple-keyboard | Bundled library (on-screen keyboard) | `manager/static/assets/keyboard-CGqOWm1s.js` | MIT | Francisco Hodge (hodgef) | https://github.com/hodgef/simple-keyboard |
| core-js | Bundled polyfill | `manager/static/assets/scheduler-JAaWa7ri.js`, `keyboard-CGqOWm1s.js` | MIT | Denis Pushkarev (zloirock) | https://github.com/zloirock/core-js |
| @mdi/font (Material Design Icons) | Icon font bundled | `manager/static/assets/` | Apache-2.0 (code), OFL-1.1 (font) | Austin Andrews | https://github.com/Templarian/MaterialDesign-Webfont |
| Roboto via @fontsource/roboto | Fonts bundled | `manager/static/assets/` | OFL-1.1 (wrapper: MIT) | Christian Robertson, Google | https://github.com/fontsource/font-files |
| pdf.js (pdfjs-dist 6.3.289) | Bundled library | `manager/static/assets/` | Apache-2.0 | Mozilla Foundation and contributors | https://github.com/mozilla/pdf.js |
| pdf.js CMaps | Data copied by `webui/vite.config.mjs` | `manager/static/assets/pdfjs/cmaps/` (license: `LICENSE` in that directory) | BSD-3-Clause (Adobe CMap license) | 1990-2009 Adobe Systems Incorporated | https://github.com/mozilla/pdf.js |
| pdf.js standard fonts: Foxit | Data copied (`Foxit*.pfb`) | `manager/static/assets/pdfjs/standard_fonts/` (license: `LICENSE_FOXIT`) | BSD-3-Clause (PDFium) | 2014 PDFium Authors | https://pdfium.googlesource.com/pdfium/ |
| pdf.js standard fonts: Liberation Sans | Data copied (`LiberationSans-*.ttf`) | `manager/static/assets/pdfjs/standard_fonts/` (license: `LICENSE_LIBERATION`) | GPL-2.0 with font exceptions (Liberation 1.x) | Red Hat, Inc. and others | https://github.com/liberationfonts/liberation-fonts |
| AOSP LatinIME | Data: on-screen keyboard layouts, key widths, long-press keys, symbol pages, generated from LatinIME resources by `tools/keyboard/aosp_layouts.py` | `webui/src/keyboard/` (notice: `webui/src/keyboard/NOTICE`) | Apache-2.0 | 2008-2025 The Android Open Source Project | https://android.googlesource.com/platform/packages/inputmethods/LatinIME (commit 127336e9f29d69607eab55982324b210279ae8c5) |

Not bundled although listed in `package.json`: `simple-keyboard-layouts`, `vue-monaco-cdn` (unused). Gboard data was
removed; no HeliBoard or OpenBoard data remains in the source tree (only older notes in `docs/` mention them as
research).

## Viewer runtime (`unitotem-manager/manager/plugins/unitotem_viewer/`, `python3-cefpython3`)

| Component | Used as | Path | License | Copyright | Upstream |
|---|---|---|---|---|---|
| cefpython | Fork (submodule, branch cefpython147-qt/wayland-views); built wheel installed as `python3-cefpython3` | `unitotem-manager/vendor/cefpython` (license: `License`, authors: `Authors`) | BSD-3-Clause | 2012 The CEF Python authors | https://github.com/cztomczak/cefpython (fork: https://github.com/a13ssandr0/cefpython) |
| CEF (Chromium Embedded Framework) | `libcef.so` built with our patch series and shipped in `python3-cefpython3` | `unitotem-manager/tools/cef-server/patches/cef/` | BSD-3-Clause | Marshall A. Greenblatt, The Chromium Embedded Framework Authors | https://bitbucket.org/chromiumembedded/cef |
| Chromium | Source patched (`0001`-`0003`) and compiled into `libcef.so`, with its bundled libraries (FFmpeg, ANGLE, libyuv, SwiftShader, FreeType, lcms2, libjpeg, OpenJPEG, libtiff, libsrtp, jsoncpp, ...) | `unitotem-manager/tools/cef-server/patches/` | BSD-3-Clause plus the licenses of the bundled libraries (FFmpeg: LGPL/GPL according to build options) | The Chromium Authors and the authors of each bundled library | https://www.chromium.org/ , https://chromium.googlesource.com/chromium/src/+/main/tools/licenses/ |
| Noto Sans | Font copied (also used by `plymouth/generate-assets.py`) | `unitotem-manager/manager/plugins/unitotem_viewer/static/NotoSans.ttf` | OFL-1.1 | 2012 Google Inc. and the Noto Project Authors | https://github.com/notofonts/latin-greek-cyrillic |

The Chromium/CEF license notices (`about:credits` equivalent) are not shipped in the cefpython wheel used today (it
contains no credits or license file, checked on `cefpython3-147.0+codecs-*.whl`). The complete list is generated by
Chromium's `tools/licenses` (`credits.html`) for the Chromium version the library was built from (147). The FFmpeg
build enables proprietary codecs (H.264, AAC): codec patent licensing is separate from copyright.

## License texts

### pi-gen (BSD-3-Clause)

```
Copyright (c) 2015 Raspberry Pi (Trading) Ltd.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### psutil (BSD-3-Clause)

```
BSD 3-Clause License

Copyright (c) 2009, Jay Loden, Dave Daeschler, Giampaolo Rodola
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name of the psutil authors nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
