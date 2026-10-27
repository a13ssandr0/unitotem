# Instructions for Claude in this repository

## SSH/SCP to UniTotem targets: always and only non-interactive

Every `ssh`/`scp` invocation towards a Raspberry Pi/UniTotem target (real system or OTA fallback) **must**
go through the helpers already provided in `deploy/lib.sh` (`ssh_t`, `ota_ssh`, `scp_t`, `ota_ssh_send`, or the
`_sshpass` function directly for ad-hoc cases) — never a direct `ssh`/`scp` call. These helpers
guarantee `SSH_ASKPASS_REQUIRE=never` + `env -u DISPLAY -u SSH_ASKPASS` around `sshpass -p
"$OTA_PASSWORD"`, which is the only verified way to stop a graphical askpass helper from trying to
open when password authentication finds no credentials ready.

**Why this rule exists**: `deploy/remote-deploy.sh`'s `do_probe()` and the final wait loop of
`cmd_deploy()` (until 2026-08-02) invoked raw `ssh`/`scp`, bypassing `_sshpass`. Real result
observed on actual hardware: OpenSSH, without a ready password, tries to launch a graphical askpass (which fails
for lack of a display, log full of `libEGL warning: ... failed to create dri2 screen`), then
`Permission denied, please try again` repeated, then failure — blocking the whole deploy sequence without
a clear error at the start. Fixed by wrapping all three calls with `_sshpass`.

**Before adding a new SSH/SCP call to this codebase**: check that it goes through one of
these helpers. A quick way to check:
```
grep -n '\bssh \|\bscp \b' deploy/*.sh | grep -v '_sshpass\|ssh_t\|ota_ssh\|scp_t\|command -v\|ssh-keyscan'
```
If this command prints lines (other than comments/`require_cmd`), there is an unprotected call to fix.

## arm64 builds run on the real Raspberry Pi

`build-unitotem.sh` probes the test Pi (`root@<pi-host>`, SSH through the `deploy/lib.sh` helpers; credentials in
[[no-ssh-password-prompts]]) and, when it is reachable, runs the whole arm64 pipeline natively there. Only when the Pi is
unreachable does it fall back to Docker + `qemu-aarch64` on the x86_64 host, which is structurally slow: `mkinitramfs`
(`copy_exec` runs `ldd`, i.e. the target's dynamic linker) and the postinst/trigger scripts of `apt-get install`
(`ldconfig`, `depmod`, `systemctl`) execute real arm64 code through binfmt_misc emulation.

## The test Pi's real SD card: never unbounded writes

The test Raspberry Pi's SD card is a resource that costs the user money. On 2026-10-17 a load generator launched
with `ssh … 'nohup … &'` kept running for 14.7 hours (ssh never returned, script waiting) and wrote ~475 GiB
to the SD before anyone noticed. Rules, valid for every session/agent:

- Every job that writes to the Pi has a **built-in hard limit** (duration or maximum bytes) and starts with
  `systemd-run --collect -p RuntimeMaxSec=N …`. Never a long process started with `ssh host 'cmd &'`.
- Estimate the bytes written before starting; if > ~1 GiB, tell the user.
- Run `tools/pi-sd-guard.sh SECONDS` (detached) alongside write jobs: it stops `pwr-writer`/`*-testload.service`
  above 300 MiB/min and writes `SDGUARD` in `work/pi-test/STATE.md`.
- Script steps that wait for a remote command must be time-limited (ssh with
  `ServerAliveInterval`, loops with a maximum) and check the write budget (`/sys/block/mmcblk0/stat`, field 7 × 512).
- Check long jobs at intervals; at the end of the work report to the user the bytes written to the SD.

## Disk and working folder: keep tidy, delete the old

On 2026-10-17 `work/` and `deploy/` occupied ~450 GB (test images, qcow2, daily builds, `.prev*`). Rules for
every session and agent of this repo (and of the manager session):

- **One test = one folder under `work/<name>/`**, with a line in `work/README.md` (purpose, date, "deletable when"). No
  loose images in the root of `work/` or `deploy/`.
- **Keep only the latest useful result.** For builds: the latest `unitotem-*.img.xz` and the latest `*.parts` per architecture, plus
  the release served to the Pi. `.prevNN` copies, old `*.parts`, intermediate releases and test images are deleted
  as soon as the test is over, not "later".
- **At the end of every test/round: clean up.** List what was produced (`du -sh`), delete what is regenerable using literal
  paths (never globs/variables in `rm`; see the `rm` rules), record the space freed in `work/pi-test/STATE.md`.
- **Large test files = sparse and temporary.** VM and power-cut `qcow2`/`.img`: create with overlay/backing files (not
  full copies), delete them when the test passes; keep only the reports (`REPORT.md`) and logs.
- **Directories created by Docker are owned by root**: delete them with Docker itself (`docker run --rm -v <parent-folder>:/w <image
  already present> rm -rf -- /w/<literal name>`), never with sudo; better still, create them with `--user $(id -u):$(id -g)`.
- **Space check:** before a build or a series of tests, `df -h /home`; under 150 GB free, clean up before
  starting. Never leave a job that writes without a limit (see the SD section).

## Priority during builds

During a build (especially the native one on the Pi) the build has the highest priority and the UniTotem services the lowest; when the build is over
everything is restored as it was. First save the current values (nice, `CPUWeight` of unitotem-manager/splash/start-xorg and of the
CEF subprocesses), apply `systemctl set-property --runtime … CPUWeight=1` / `renice 19` to the services and `nice -n -20` to the build,
and do the restore in a `trap … EXIT` (so an interruption restores anyway). Runtime-only values: they vanish at reboot.

## Build server (alessandro@build-server)

Since 2026-10-18 heavy compilations and **amd64** images are built on the **KVM VM `build-server`** (Proxmox VM 1008 `<build-vm>`, Ubuntu 26.04,
128 vCPUs with 4-node NUMA and host affinity, 256 GB RAM with ballooning, 64 GB system + 256 GB on `/nas`). Connect with
`ssh alessandro@build-server` (VPN, key already installed, passwordless `sudo`); Proxmox is `root@<hypervisor>` (only with the VPNs
`<vpn>` and `<vpn>` up; use them only if VPN drops, then turn them off). Rules:
- Work under `/nas/build/` (repo in `/nas/build/unitotem-system`, Docker with `data-root=/nas/docker-vm`); do not fill the system disk.
- Every build starts detached with `sudo systemd-run --unit=<name> --collect --working-directory=… <script>` (e.g. `work/run-build.sh ARCH VERSION`): a dropped
  ssh does not stop it. Log in `work/logs/build-ARCH.log`, sentinel `work/logs/build-ARCH.done`. Never foreground builds in an ssh session.
- On this VM `mknod`, privileged Docker and loop devices work (in the old LXC container they did not). **arm64: images are ALWAYS built on the Pi**
  (user's decision: the server CPU is too slow for emulation, no qemu-user).
- The release signing key stays on the user's PC: the image is brought here with rsync and the release is signed here.
- VPN with kernel TUN: ~400-500 Mbit/s with one stream (VPNs `<vpn>`/`<vpn>` off during transfers, otherwise VPN goes through the VPN and drops to 30-65).
- Avoid retry loops on the same failed command: after an error, diagnose (Proxmox console `qm monitor` screendump, cloud-init log, etc.).

## Cross-compilation: always preferred

Before EVERY compilation (C/C++, kernel/firmware, Python extensions, wheels, packages, image parts) check and state whether it can be
done as a cross build from the x86 host (cross-gcc/clang, sysroot, multiarch, dpkg-cross, `--host-arch`). If emulation (qemu/binfmt) is chosen
you are probably doing it wrong: keep it only for what must run target code (debootstrap second stage, postinst, tests) and
say why. This repo's arm64 images compile nothing (they install packages and generate the initramfs): there the target code
necessarily runs, so the real Pi is used, not emulation.
