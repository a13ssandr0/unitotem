# System states and how to reach each

Paths: relative to the repository root. Sources: [boot](boot.md), [deploy-and-recovery](deploy-and-recovery.md), [storage-and-persistence](storage-and-persistence.md), [ab-updates](ab-updates.md), [image-runtime](image-runtime.md). "Not verified" marks what comes from the code and docs only.

## Ports and identities

| Where | Port | Who |
|---|---|---|
| Installed system, web | 443 (80 redirects) | administrator accounts of the manager (system accounts of group `sudo`) |
| Installed system, ssh | 22 | administrators: password or key; root: key only (`/root/.ssh/authorized_keys`); root with an empty password only in first access |
| OTA fallback (initramfs), ssh | 2222 (dropbear) | see [Fallback](#ota-fallback) |
| Console | tty1 / serial | no login prompt on the installed system; emergency and rescue shells reboot after 120 s |

## States of the installed system

| State | How it shows | Access | Leaves by |
|---|---|---|---|
| Running (slot A or B) | kiosk content; `unitotem-update status` says the slot | web as administrator; `ssh <admin>@host`; `ssh root@host` with a key | normal operation |
| First access (no administrator) | the welcome page on the screen; `/login` redirects to `/setup` | `https://host/setup` (create the administrator); `ssh -t root@host`: root has no password, the forced command `unitotem-first-admin` creates the first administrator, nothing else is reachable | the first administrator exists: root is closed to keys only |
| Volatile overlays (no DATA partition, or DATA fails to mount) | status `volatile:no-data` / `volatile:data-mount` (`/run/unitotem-overlay.status`, DATA record); `unitotem-first-admin` prints `No data partition: settings are lost on reboot.` | as Running, with an administrator created in the tmpfs; everything is lost at reboot; `/home` is a 32 MiB tmpfs | a DATA partition (reflash, or the first-boot layout) |
| Overlay failure | status `failed:overlay-etc` / `overlay-root` / `overlay-var` / `dpkg-pin` / `volatile`; the boot continues | as Running if sshd came up; else the fallback after three unhealthy boots | repair DATA, reboot |
| Trial boot (pending slot after an update or a deploy) | `pending_confirm` true in `unitotem-update status` | same as Running (new slot) | health gate (`UPDATE_HEALTH_URL`, 180 s) confirms the slot, or a timeout rolls back by a plain reboot to the previous slot |
| Rolled back / failover | `unitotem-ota.failover` guard on the boot FAT; the other slot runs | same as Running (other slot); `other_version` shows what failed | confirm a new update; the guard refuses a second failover until then |
| Maintenance | `unitotem.maintenance=1` on the command line, or `unitotem-maintenance enter` | ssh only: manager and compositor stopped, `/` read-write, apt available; the compositor is `Restart=always` (stop it with systemctl) | `unitotem-maintenance exit [--initramfs]` (reboots) |
| Network watchdog reboot | cabled link without a usable address for `THRESHOLD_MIN` (15 min) | the machine reboots into the OTA fallback | an address (see fallback) |
| Image, first boot | ROOT_B and DATA do not exist yet: `layout_complete` creates them, `grow_data` grows DATA to the disk end (GPT or DOS) | as Running afterwards; the first boot is longer | automatic |
| Duplicate slot label (`ROOT_A` twice) | `slot_pick` relabels the other copy `ROOT_STALE` in the initramfs | as Running | repair writes in `unitotem-update` |
| Secure Boot enforcing | `SecureBoot` 1, kernel lockdown | as Running; the NVIDIA module is not loaded until its key is enrolled in the MOK (needs the console); nouveau takes the GPU (`unitotem-nouveau-fallback`) | MOK enrolment (physical) |
| Raspberry Pi, MBR table (every model) | Primaries only: FIRMWARE (type c) p1, ROOT_A p2, ROOT_B p3, DATA p4; a device whose DATA is kept keeps its table | as Running. Pi 3 / Zero 2 (no EEPROM bootloader): no A/B update, slot-switch commands exit `backend-unsupported` | n/a |

## OTA fallback

The fallback is the recovery kernel and initrd that live on the boot partition (FIRMWARE on a Pi, EFI on a PC; `unitotem/recovery-*`, `recovery8.img`), booted by GRUB entry `UniTotem OTA fallback` or by a `config.txt` without `os_prefix`. It shows a progress screen with the address, brings the network up (wait up to 30 s for a wired device, 12 s for carrier, DHCP per interface; without an address dropbear still starts and the whole procedure repeats every 5 s for about 35 min) and serves dropbear on 2222.

### Why it starts

| Reason | Timer | Notes |
|---|---|---|
| Root missing or failing its read-only fsck on both slots (`ab_failover` found no good slot) | idle reboot after 21600 s | kind `recovery` |
| `local-bottom-verify`: no `/sbin/init` or `ota-preserve.list` | 21600 s | kind `recovery` |
| Boot counter reached 3 (`unitotem-ota.bootcount`): three boots without a healthy manager | 21600 s; the count is set to 2 on entry, so exactly one normal attempt follows | kind `recovery` |
| `unitotem.ota=1` on the command line, or the file `unitotem-ota.request` on the boot partition | 1800 s without a login | kind `update` |
| `unitotem.ota=recover` (the preboot card, a deploy armed by `remote-deploy.sh`) | none | waits for the host |
| Net watchdog | see above | |
| Windows install environment (`tools/windows-installer`, GRUB4DOS) | none | the key is on the command line: `unitotem.ota.authkey=` |

A successful dropbear login stands down the idle watchdog.

### Who can log in (`fallback_auth_setup`, in order)

| State | When | Login |
|---|---|---|
| Key | an armed key is present: `unitotem.ota.authkey=<base64 ssh-ed25519>` on the command line, or `unitotem-ota.authorized_keys` on the boot partition, or `root/.ssh/authorized_keys` of the booted slot in DATA | `ssh -p 2222 root@host` with that key (`deploy` tries `OTA_FALLBACK_KEY` and `~/.ssh/id_ed25519` by itself) |
| Administrator | DATA holds administrators of group `sudo` (`upper/etc.<slot>/group` and `shadow`) | `ssh -p 2222 <admin>@host`: root shell with the administrator's password or key (`deploy <admin>@host` asks the password on the terminal); root itself takes keys only |
| Open | no key and no administrator was found at all, DATA absent or unreadable included | `ssh -p 2222 root@host` with an empty password (`deploy` finds it by itself); dropbear runs with `-B`; this is the preboot card |
| Closed | an administrator exists but its password is forgotten, and no key | no login: arm a key by writing `unitotem-ota.authorized_keys` on the boot partition from another machine, or reset the first access |

Only one slot's accounts are read: `unitotem.slot=` on the command line, else `saved_entry` of the boot partition grubenv, else slot A.

Host side: `deploy [USER@]HOST[:PORT]` finds a fallback by its dropbear banner and logs in by itself (`ota_auth_resolve`, `deploy-and-recovery.md#fallback-authentication`): keys, then open, then a password typed on the terminal.

### Preboot card (Raspberry Pi 3, 4, 5)

`deploy/script/write-preboot.sh`: one FAT partition with the Pi firmware, `recovery8.img`, `recovery-initrd.img` and `config.txt`/`cmdline.txt` (`unitotem.ota=recover`). No password, key or DATA exists on it: the fallback is open. The screen shows the DHCP address; then

`deploy/script/remote-deploy.sh deploy <address> --image <image> --yes`

The initrd of the card carries the engine of the repository (appended cpio archive).

## What a deploy goes through

`remote-deploy.sh deploy`: stage 1 (the target runs the fallback; a power loss reboots into it) → table and partitions → ROOT_A → ROOT_B formatted empty → DATA kept or new → first boot in trial (`reboot -f '0 tryboot'` on a Pi, `grub-reboot` on a PC) → confirm. A failure before stage 2 leaves the old system; after the table is written the state is the fallback.

| Moment | State of the target |
|---|---|
| Stage 1 armed, not yet rebooted | old system running; `disarm` removes the arming |
| In the fallback, table not written | fallback (open or armed key); old partitions intact |
| Table written (point of no return) | fallback; the data of the old system is in the backup taken first |
| Trial | Trial boot above |

## Not verified

- A full deploy on a Raspberry Pi 3 and the trial boot of its first slot (the stages up to the ROOT_A restore ran against an emulated Pi 3).
- `/run/unitotem-overlay.status` after `switch_root`.
- The `Closed` login recovery by a boot-partition key on every board.
- Pi 3 / Zero 2 trial: `deploy` arms `rpi-tryboot` on them (`PI3` forces `TRYBOOT_CAPABLE=1`), but their firmware has no tryboot and `unitotem-update` refuses the slot-switch commands there. Not verified on hardware.
