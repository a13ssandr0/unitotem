#!/usr/bin/env python3
"""Test of the ESP boot pictures and display mode of unitotem-update: drm_mode, record_boot_mode (real grub-editenv on a
temporary grubenv), sync_esp_assets and their use in sync_esp_grubcfg. Every path is inside a temporary directory.

  python3 tools/release/test_grub_assets_sync.py
"""
import importlib.machinery, importlib.util, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)

PNG = b"\x89PNG fake picture"
cfg = lambda lvl: (f"# unitotem-grub-level: {lvl}\n" if lvl else "") + "menuentry 'A' --id slot-a {}\nmenuentry 'B' --id slot-b {}\nmenuentry 'O' --id ota-recovery {}\n"

with tempfile.TemporaryDirectory() as td:
    drm = os.path.join(td, "drm"); os.makedirs(drm)
    empty_drm = os.path.join(td, "empty-drm"); os.makedirs(empty_drm)
    esp = os.path.join(td, "esp"); os.makedirs(esp + "/unitotem-grub/grub")
    logo = esp + "/unitotem-grub/grub/logo"
    assets = os.path.join(td, "assets"); os.makedirs(assets + "/logo")
    shipped = os.path.join(td, "esp-grub.cfg")
    state = os.path.join(td, "state"); os.makedirs(state)
    genv = esp + "/unitotem-grub/grub/grubenv"
    target = esp + "/unitotem-grub/grub/grub.cfg"
    base = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="grub", UPDATE_ESP_MOUNT=esp, UPDATE_ESP_GRUBCFG=shipped,
                UPDATE_ESP_ASSETS=assets, UPDATE_DRM_DIR=drm, UPDATE_GRUBENV=genv, UPDATE_STATE_DIR=state)
    # the sync cases keep the display out of the way: their grubenv is checked separately below
    gconf = dict(base, UPDATE_DRM_DIR=empty_drm)

    def display(name, status, modes=None):
        d = os.path.join(drm, name); os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "status"), "w").write(status + "\n")
        if modes is not None: open(os.path.join(d, "modes"), "w").write(modes)

    def displays(hdmi, dp2, hdmi_modes="1920x1080\n1280x720\n"):
        display("card0-DP-1", "disconnected", "3840x2160\n")
        display("card0-DP-2", dp2, "3840x2160\n")
        display("card0-HDMI-A-1", hdmi, hdmi_modes)

    # --- drm_mode: sorted order, first connected wins (card0-DP-2 sorts before card0-HDMI-A-1)
    displays("connected", "connected")
    check("drm_mode: first connected display in sorted order (card0-DP-2)", uu.drm_mode(dict(base)) == "3840x2160")
    displays("connected", "disconnected")
    check("drm_mode: the connected display's preferred mode", uu.drm_mode(dict(base)) == "1920x1080")
    displays("disconnected", "disconnected")
    check("drm_mode: None when nothing is connected", uu.drm_mode(dict(base)) is None)
    displays("connected", "disconnected", hdmi_modes="garbage\n1920x1080\n")
    check("drm_mode: None when the first mode line is garbage", uu.drm_mode(dict(base)) is None)
    displays("connected", "disconnected", hdmi_modes="")
    check("drm_mode: None when modes is empty", uu.drm_mode(dict(base)) is None)
    displays("connected", "disconnected")
    check("drm_mode: an absent DRM directory gives None", uu.drm_mode(dict(base, UPDATE_DRM_DIR=os.path.join(td, "none"))) is None)

    # --- ESP tree and shipped assets for the sync cases
    open(target, "w").write(cfg(5))
    open(shipped, "w").write(cfg(6))
    os.makedirs(logo)
    open(logo + "/800x600.png", "wb").write(PNG)                  # stale: not shipped any more
    for n in ("1920x1080.png", "1280x800.png"):
        open(f"{assets}/logo/{n}", "wb").write(PNG + n.encode())
    open(f"{assets}/logo/notes.txt", "w").write("junk")
    open(f"{assets}/logo/abc.png", "wb").write(PNG)

    # --- level rise: pictures first, grub.cfg replaced last
    replaced = []
    real_replace = os.replace
    def spy(a, b, *x, **k):
        replaced.append(b); return real_replace(a, b, *x, **k)
    uu.os.replace = spy
    try:
        r = uu.sync_esp_grubcfg(gconf)
    finally:
        uu.os.replace = real_replace
    check("sync: older ESP config is replaced", r == {"from": 5, "to": 6} and open(target).read() == cfg(6), r)
    check("sync: both shipped pictures are copied", open(logo + "/1920x1080.png", "rb").read() == PNG + b"1920x1080.png"
          and open(logo + "/1280x800.png", "rb").read() == PNG + b"1280x800.png")
    check("sync: the stale picture is removed", not os.path.exists(logo + "/800x600.png"))
    check("sync: junk files are ignored", sorted(os.listdir(logo)) == ["1280x800.png", "1920x1080.png"], os.listdir(logo))
    check("sync: grub.cfg is replaced last", bool(replaced) and replaced[-1] == target, replaced)
    check("sync: no .new left behind", not any(n.endswith(".new") for n in os.listdir(logo)) and not os.path.exists(target + ".new"))

    # --- same level: nothing copied, nothing touched
    before = {n: os.stat(f"{logo}/{n}").st_mtime_ns for n in os.listdir(logo)}
    check("sync: same level is left alone", uu.sync_esp_grubcfg(gconf) is None and open(target).read() == cfg(6))
    check("sync: same level rewrites no picture", {n: os.stat(f"{logo}/{n}").st_mtime_ns for n in os.listdir(logo)} == before)

    # --- rollback: an older image ships a lower level and different pictures
    open(shipped, "w").write(cfg(4))
    open(f"{assets}/logo/1024x768.png", "wb").write(PNG)
    check("sync: a rollback to an older image never downgrades or copies", uu.sync_esp_grubcfg(gconf) is None
          and open(target).read() == cfg(6) and not os.path.exists(logo + "/1024x768.png"))
    os.unlink(f"{assets}/logo/1024x768.png")

    # --- missing assets directory: grub.cfg is still synced, the pictures stay as they are
    open(shipped, "w").write(cfg(7))
    r = uu.sync_esp_grubcfg(dict(gconf, UPDATE_ESP_ASSETS=os.path.join(td, "no-assets")))
    check("sync: a missing assets directory still syncs grub.cfg", r == {"from": 6, "to": 7} and open(target).read() == cfg(7), r)
    check("sync: a missing assets directory leaves the pictures", os.path.exists(logo + "/1920x1080.png"))

    # --- display mode in grubenv (real grub-editenv on a temporary file)
    if shutil.which("grub-editenv") is None:
        print("SKIP: grub-editenv missing: record_boot_mode checks not run")
    else:
        subprocess.run(["grub-editenv", genv, "create"], check=True)
        rconf = dict(base, UPDATE_ESP_GRUBCFG=shipped)
        displays("connected", "disconnected")
        check("record: writes the connected display's mode", uu.record_boot_mode(rconf) == "1920x1080"
              and uu.grubenv_get(rconf, "unitotem_gfx") == "1920x1080")
        st = os.stat(genv); content = open(genv, "rb").read()
        check("record: an unchanged mode writes nothing", uu.record_boot_mode(rconf) is None
              and os.stat(genv).st_mtime_ns == st.st_mtime_ns and open(genv, "rb").read() == content)
        displays("disconnected", "connected", hdmi_modes="1920x1080\n")
        check("record: a different display changes the mode", uu.record_boot_mode(rconf) == "3840x2160"
              and uu.grubenv_get(rconf, "unitotem_gfx") == "3840x2160")
        displays("disconnected", "disconnected")
        check("record: no connected display leaves the recorded mode", uu.record_boot_mode(rconf) is None
              and uu.grubenv_get(rconf, "unitotem_gfx") == "3840x2160")
        check("record: not recorded on a non-GRUB backend", uu.record_boot_mode(dict(rconf, UPDATE_BACKEND="rpi")) is None)

print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
