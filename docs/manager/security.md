# Security: accounts, login, sessions, permissions, web TLS

Access control of the manager web interface. Accounts are operating-system accounts (checked by PAM). Web access and administration come from group membership; capabilities are stored in `users.json`. Browser sessions are JWT cookies.

Paths: relative to unitotem-manager/

## Files

| Path | Role |
|---|---|
| `manager/api/security.py` | WS API `Security`: users, add/delete, password, permissions, password policy |
| `manager/api/ws/permissions.py` | `check_permissions()`, `APIPermissionError` |
| `manager/api/ws/endpoints.py` | `handle_call()` runs `check_permissions()` before every WS call |
| `manager/routers/login.py` | `LOGMAN` (fastapi-login), `session_cookie()`, `/login`, `/auth/token`, `/logout`, `/login/users`, `/api/settings/set_passwd`, `require_perm()` |
| `manager/routers/setup.py` | `/setup`: first administrator |
| `manager/routers/websocket/web_ui.py` | `/ws`: cookie check at handshake |
| `manager/utils/sessions.py` | Registry of authenticated websockets; server-side close |
| `manager/utils/osusers.py` | System accounts: group membership, PAM check, adduser/gpasswd/usermod/chpasswd/deluser, shadow hash |
| `manager/utils/first_access.py` | First administrator: `create_first_admin()`, `reconcile()`, lock `/run/unitotem/first-admin.lock`. Used by `/setup` and the script |
| `manager/utils/passwords.py` | Username and password rules |
| `manager/utils/models/user.py` | `UserPerms`, `UserData` (users.json), `User`, `UserManager` |
| `manager/utils/models/security.py` | `SecuritySettings` (security.json) |
| `manager/utils/backup.py` | `_export_users`, `_restore_users`, `_reset_users` |
| `manager/utils/environment.py` | `auth_token`: session signing secret (unitotem.env) |
| `manager/main.py` | HTTPS serving, HTTP to HTTPS redirect, session gate for assets and uploads |
| `debian/unitotem-first-admin` | `/usr/sbin/unitotem-first-admin`: login shell of root and sshd forced command ([Root and first access](#root-and-first-access)) |
| `debian/unitotem-manager.pam` | PAM service `unitotem-manager` (`common-auth`, `common-account`) |
| `debian/unitotem-manager.postinst`, `.postrm` | TLS certificate (no group is created); certificate removed on purge |

## How it works

- Login accepts a name and password that PAM accepts for a system account.
- Allowed accounts: members of group `users` (primary or supplementary), uid not 0. Root never logs in to the web. `osusers.may_login()` runs before PAM: non-members never reach PAM. `osusers.authenticate()` refuses an empty password.
- Administrator: member of group `sudo` (primary or supplementary). Membership is read on each request; it is not stored in `users.json`.
- `POST /auth/token` (form `username`, `password`, `src`, `remember_me`): rate limited per client address (10 per 60 s, 429 beyond; `RateLimiter` of `utils/remote/pairing.py`). PAM runs in a thread. Failure raises `InvalidCredentialsException` (401). Success returns 303 to `src` and sets the cookie.
- `src` (`POST /auth/token` field, `GET /login` query) accepts only a same-site relative path: one leading `/`, no `//`, no backslash, no control characters, at most 2048 characters. Anything else becomes `/` (`routers/login.py` `safe_src`).
- Login page: shows an error on 401 (wrong name or password) and on 429 (too many attempts); it does not redirect on failure.
- `GET /login/users`: account names only, never permissions; rate limited per client address (30 per 60 s, 429 beyond). Returns `[]` when `show_login_users` is off (default on); the login page then shows a plain username field. Settings > Users switch "Show the list of users on the login page" sets it (WS `set_login_user_list`).
- Cookie: JWT signed with `environ.auth_token`. Claims `sub`, `sid` (random per login), `at` (issue time), `cre`. HttpOnly, Secure, SameSite=Strict. `remember_me` gives Max-Age 7 days; otherwise a browser-session cookie.
- Each request: `user_manager.get_user()` loads the user (the account must exist and may log in), then `session_valid()` checks revocation. Removing an account from group `users` ends its access on the next request.
- Revocation (`revoke_sessions`): sets `invalid_before` to now and `keep_sid`; earlier cookies stop working except `keep_sid`. Open websockets of the user are closed by the server (1008, `Not Authenticated`).
  - Own password change: current session kept, others end.
  - Admin changes another user's password: all its sessions end.
  - Account deleted, access removed, backup restored or reset: all sessions end.
  - Promotion or demotion: the next request sees the new group membership.
- `/ws`: cookie checked once at handshake, never again; only server-side revocation ends it.
- Each WS call: `handle_call()` runs `check_permissions(func, user)`. Denied: `Permission error: not allowed to execute <target>`.
- Capabilities: `scheduler`, `power`, `audio`, `admin`. `@UserPerms.requires.<name>` (stacked = OR); `requires.none` = any logged-in user; no decorator = admin only.
- `admin` implies every capability. It is not stored: the user's `admin` flag is membership of `sudo`. `UserData` stores only `scheduler`, `power`, `audio`; an `admin` entry in an old file is dropped on save.
- Accounts and roles:
  - Web access = member of `users`. Admin = member of `sudo`, which also gives a shell (`/bin/bash`) and a home directory.
  - Created by UniTotem with `adduser`, GECOS `UniTotem user`:
    - administrator: home from skel, shell `/bin/bash`, group `sudo`;
    - non-admin: no home, shell `/usr/sbin/nologin`.
    - Both are members of `users` (adduser puts new non-system users there).
  - Grant admin (`set_admin(name, True)`): `gpasswd -a name sudo`, shell `/bin/bash`, home created with `mkhomedir_helper` when missing.
  - Revoke admin (`set_admin(name, False)`): `gpasswd -d name sudo`, shell `/usr/sbin/nologin`. The home directory is kept.
  - Foreign accounts (not created by UniTotem) lose web access with `gpasswd -d name users`; the account itself is not changed.
- First administrator: `has_admin()` (`osusers.admin_exists()`) is false while no account other than root can log in and is in `sudo`. Then `/login` redirects to `/setup`.
  - `/setup` and `/usr/sbin/unitotem-first-admin` create it through one function, `first_access.create_first_admin()`: under flock `/run/unitotem/first-admin.lock`, the "no administrator" check is repeated, the admin is created (above), then `close_first_access()` runs. Two creations never both succeed.
  - `/setup` logs the new administrator in (remember).
  - The manager watches `/etc` with inotify for changes of `group` and `gshadow`. When an administrator appears, the WELCOME screen leaves through `WebviewManager.refresh_idle()`. Inotify is used because the manager exposes no method-call D-Bus service; its only D-Bus name is the `org.freedesktop.Notifications` server.
- Self-protection: no user deletes itself; the last user cannot be deleted; an admin cannot remove its own admin role.
- User list: entries of users.json whose account exists, plus members of `users` without an entry (no capabilities).
- Passwords are never stored by UniTotem; `/etc/shadow` is the only store. Set with `chpasswd` on stdin (`--encrypted` for hashes). A failed creation is rolled back with `deluser`.
- Deleting a user removes the system account only if UniTotem created it (GECOS `UniTotem user`); otherwise it only leaves group `users` and `sudo`.
- Password rules:
  - Basic (always): not empty, at most 128 characters, no control characters.
  - Strict (only when `enforce_password_policy`; add user, admin password change, own change, first administrator at `/setup` and by the script): at least 10 characters, not the username (case-insensitive), not one repeated character, not a common word.
  - Username (always): `^[a-z_][a-z0-9_-]{0,31}$`.
- Backup: stores capabilities, the admin flag (membership of `sudo`) and each `/etc/shadow` hash, never a password. Restore recreates accounts with `adduser` + `chpasswd --encrypted` (admins also get `sudo`, shell and home). Reset deletes UniTotem accounts and removes the others from `users` and `sudo`.
- Assets (`.js` chunks) and uploads need a session, except from loopback (127.0.0.1, ::1).
- Web TLS: Hypercorn serves HTTPS on `port_secure` (443) with `certfile` and `keyfile` (same PEM). Port 80 redirects to HTTPS. The certificate is self-signed.
- No claim code and no default password exist. While no administrator exists the totem shows the WELCOME screen (idle asset `first_boot`). Two simultaneous setups have one winner (flock and asyncio lock).
- A/B update keeps root's shadow entry, root's login shell and marker group membership, and local accounts (uid 1000-65533 with group memberships) by merging the identity files (image base + root + local accounts, `unitotem/files/unitotem_identity.py`): validated, atomic, any failure falls back to the plain image files, the old slot is never touched; the update never locks a device out.
- The remote-link identity is a separate certificate ([remote.md](remote.md)).

## Root and first access

Root has no password after first access and never logs in to the web. Its SSH access is key only. Until the first administrator exists, root is open (empty password, script as login shell).

- Image state while open (stage 2 of the image): `passwd -d root`, root shell `/usr/sbin/unitotem-first-admin`, root in the system group `unitotem-first-admin` (marker).
- sshd (`unitotem/files/sshd_config`): `PermitRootLogin prohibit-password`, `PermitEmptyPasswords no`, and at the end:

  ```
  Match User root Group unitotem-first-admin
      PermitRootLogin yes
      PermitEmptyPasswords yes
      ForceCommand /usr/sbin/unitotem-first-admin
      DisableForwarding yes
      PermitTunnel no
      PermitUserRC no
  ```

  Membership is read at each connection: no sshd reload.
- sshd `Match` matches user and group only, not the password state. The marker group bounds the empty-password window: without it, a later `passwd root` or `passwd -d root` would reopen root over SSH.
- The closed state is `*` in the shadow field, not `!`. OpenSSH without PAM treats `!` as locked and would also refuse key logins.
- Closing (`close_first_access()`, one idempotent function, runs after the first administrator is created):
  1. `gpasswd -d root unitotem-first-admin`: sshd no longer matches the `Match` block;
  2. `usermod -p '*' root`: no empty password;
  3. `usermod -s /bin/bash root`: root gets a normal shell (key login only).
- Start-up reconcile (`first_access.reconcile()`, on manager start): if an administrator exists and root is still open, the close runs. This covers an interruption between the steps above or between creating the administrator and closing.
- `/usr/sbin/unitotem-first-admin` (login shell of root and sshd forced command):
  - Ignores argv and environment (clean environment set first). `umask 077`.
  - Traps SIGINT, SIGQUIT, SIGTSTP and SIGHUP: exit. A 5-minute alarm ends an idle session. At most 3 attempts.
  - Never executes a shell, pager or editor.
  - Asks for a name (`osusers.valid_name`) and a password twice (no echo), with the same rules as `/setup`.
  - If an administrator already exists, it prints `Root accepts SSH keys only. Log in with an administrator account.` and exits.
  - Errors: a generic message on the terminal; the detail goes to syslog.
  - On success it creates the administrator through `first_access.create_first_admin()` and prints `Administrator <name> created. Log in again as <name>.`.

## Interfaces

Files (directory `/etc/unitotem/`, overridable by CLI flags):

| File | Content |
|---|---|
| `users.json` (`--users_file`, 0600) | `{"<name>": {"permissions": [...], "invalid_before": float, "keep_sid": str or null}}`. `permissions` holds `scheduler`, `power`, `audio` only. No passwords; legacy `password` keys are dropped on next save |
| `security.json` (beside users.json) | `{"enforce_password_policy": bool, "show_login_users": bool}`. Defaults: `enforce_password_policy` false, `show_login_users` true. Missing or broken file = defaults |
| `unitotem.env` (`--envfile`) | `AUTH_TOKEN` (cookie signing key), `INSTANCE_ID`, `HOTSPOT_UUID`. Generated when missing. Changing `AUTH_TOKEN` invalidates every cookie |
| `/etc/ssl/unitotem.pem` (`--certfile`, `--keyfile`) | Certificate and key in one PEM |
| `/run/unitotem/first-admin.lock` | flock of the first-administrator creation (web and script) |
| `/etc/group`, `/etc/gshadow` | Watched with inotify: membership of `users`, `sudo` and `unitotem-first-admin` |

CLI: `--port` (80), `--port_secure` (443), `--bind`, `--bind_secure`, `--users_file`, `--envfile`, `--certfile`, `--keyfile`.

HTTP:

| Method and path | Auth | Result |
|---|---|---|
| GET `/login?src=` | none | Login page; `src` checked as in [How it works](#how-it-works); redirects to `/setup` if no admin, to `src` if logged in |
| POST `/auth/token` | none, rate limited per address (10 per 60 s) | 303 + cookie; 401 invalid credentials; 429 too many attempts |
| GET `/logout` | none | Clears the browser cookie only; the token stays valid until expiry or revocation |
| GET `/login/users` | none, rate limited per address (30 per 60 s) | JSON list of account names, never permissions; `[]` when `show_login_users` is off; 429 beyond the limit |
| GET `/setup` | none | Setup page; 404 once an admin exists |
| POST `/setup` | none | JSON `{username (max 64), password (max 512)}`: 200 `{"ok": true}`, 422 `{"detail": [...]}` (same policy as `set_passwd`), 409 account exists, 404 when set up |
| POST `/api/settings/set_passwd` | session | JSON body `{"password": str (max 2048)}`; own password; 422 `{"detail": [...]}`. No web UI caller |
| GET `/api/schema` | session | Every WS function with permissions and arguments |

WS class `Security`:

| Function | Permission | Arguments | Result |
|---|---|---|---|
| `users` | admin | none | multicast to administrator sessions only: `users: {name: {perms}}` |
| `current_user` | none | none | `name`, `perms` |
| `password_policy` | none | none | broadcast `enforced`, `rules` |
| `set_password_policy` | admin | `enforce` | policy |
| `login_user_list` | admin | none | multicast to administrators: `show` |
| `set_login_user_list` | admin | `show` | `show`, as `login_user_list` |
| `add_user` | admin | `username`, `password` | users, or error |
| `set_user_password` | admin | `username`, `password` | none, or error; that user's sessions end |
| `set_user_permissions` | admin | `username`, `perms` (`admin` in `perms` sets or removes `sudo`) | multicast `reload` to that user, then users |
| `delete_user` | admin | `username` | users, or error |

Errors: `User already exists`, `Password refused` (`extra` list), `User <name> does not exist`, `Cannot delete current user`, `An admin cannot remove their own admin role`.

## Rules and gotchas

- SameSite=Strict is the CSRF and cross-site websocket defence; `/ws` checks no Origin. Keep the attribute.
- A function without `perms` is admin only: new functions are admin only unless decorated.
- `has_admin()` ignores root: a node with only root shows the setup page.
- Admin status is group membership: `usermod -aG sudo` or `gpasswd` outside UniTotem changes the web role at the next request.
- Passwords never go on a command line or into logs. `set_password` refuses `\n`, `\r`, `\0` (chpasswd line format). Hashes must match crypt(3) format.
- PAM runs in a thread; a wrong password can take seconds (`pam_faildelay`). The PAM service falls back to `login` when `/etc/pam.d/unitotem-manager` is missing.
- The backup archive holds shadow hashes: treat it like the private keys.
- Logout does not revoke the token server-side.
- The web certificate is created once by postinst (36500 days), kept across upgrades, removed on purge.
- Loopback skips the session check for assets and uploads: local processes read uploads without login.
- `WSMulticast(users, /, target, **payload)` and `WSManager.send/multicast/broadcast`: the leading parameters are positional only, so a payload may carry a `users` key (`Security/users` does; with keyword-capable parameters the reply failed with `Internal error`).
- `/ws` handler: an unexpected exception is logged server-side with its traceback; the client receives only `{"error": "Internal error"}`.

## Tests

- `pytest` from the repository root. `test_osusers.py` needs the module `pam`: pip `python-pam`, Debian `python3-pampy` (the package the deb depends on); `utils/osusers.py` imports `pam` lazily.
- `manager/tests/test_osusers.py`: membership checks (`users`, `sudo`), root refused by `may_login` and `authenticate`, empty password refused, PAM not called for non-members, adduser/gpasswd/usermod/chpasswd argument lists, newline injection, deletion of UniTotem accounts only, backup hash read, revoked sessions (fake passwd/group, mocked PAM).
- `manager/tests/test_password_policy.py`: default off, settings round trip, rules.
- `manager/tests/test_login_hardening.py`: rate limits on `/auth/token` and `/login/users`, `src` validation, `show_login_users` (default, `[]` when off, WS toggle), `set_passwd` JSON body, `users` and `login_user_list` multicast to administrators only, `/setup` policy, `/ws` internal error.
