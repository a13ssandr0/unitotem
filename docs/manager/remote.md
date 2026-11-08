# Remote control

Pairs UniTotem nodes. A server drives the windows of its paired clients over a certificate-pinned mutual-TLS link and moves playlists, uploads and window settings between nodes. Every node owns an identity; standalone is a server with no clients.

Paths: relative to unitotem-manager/

## Files

- `manager/utils/remote/service.py`: `RemoteService` (singleton `service`): lifecycle, role changes, pair/adopt/unpair/leave, notifications, UI state push, file-cache sync.
- `manager/utils/remote/identity.py`: node certificate and key (ECDSA P-256), fingerprints, `node_id`, pair check.
- `manager/utils/remote/tls.py`: `server_context` / `client_context` (TLS 1.3, pinned certs, no CA, no hostname check).
- `manager/utils/remote/pairing.py`: validation (`parse_hello`, `clean_*`), `PairRequests`, `RateLimiter`, `call()` (HTTP client to other nodes).
- `manager/utils/remote/discovery.py`: mDNS `Announcer` and `Browser`, `parse_announcement`.
- `manager/utils/remote/link.py`: `LinkServer` (server listener), `ClientUplink` (client connection), control-frame helpers.
- `manager/utils/remote/transfer.py`: transfer protocol, `plan_leave`, `validate_manifest`, `send_bundle`, `receive_bundle`.
- `manager/utils/remote/bundle.py`: gather, apply (all-or-nothing) and remove playlists, uploads, windows.
- `manager/utils/remote/filecache.py`: client file cache (manifests, apply, clear).
- `manager/utils/remote/viewers.py`: registers remote viewers in `WebviewManager`.
- `manager/utils/models/remote.py`: `RemoteManager` (state in `remote.json`), `Peer`.
- `manager/api/remote.py`: WS API class `Remote` (admin only).
- `manager/routers/pairing.py`: `/remote/hello`, `/remote/adopt`, `/remote/pair-request` (web port).
- `manager/routers/websocket/remote.py`: `/remote` viewer websocket (loopback only); includes the pairing router.
- `manager/main.py`: starts and stops `service`, creates identity if `remote.json` is missing, serves the cache folder.
- `manager/tests/test_remote_*.py`: 8 files.

## How it works

- Roles: `server` (default) or `client`. A client is `paired` when it has a `server_cert`. Standalone = server with no peers.
- Identity: generated once (`ensure_identity`), stored in `remote.json`. `node_id` = first 32 hex of SHA-256 of the DER certificate. A broken cert/key pair is regenerated and logged; paired nodes must pair again.
- Discovery (unpaired client only): registers `unitotem-<node_id[:12]>._unitotem-client._tcp.local.`. TXT: `v=1`, `id`, `name`, `web`, `link`. Servers browse it. Announcements are hints; identity is the certificate presented at contact.
- Adopt (server, `adopt`):
  1. `GET /remote/hello` on the device.
  2. Compare its fingerprint with the one the admin confirmed (from `probe`); mismatch aborts.
  3. Pin the client cert in `peers` and in the live listener (`LinkServer.pin`, no restart).
  4. `POST /remote/adopt` with own cert and `expect_fingerprint`.
  5. On failure: forget the peer, reload the listener.
- Adopt (client, `accept_adoption`): accepted only if unpaired, `expect_fingerprint` equals own fingerprint, and any pending request names this server. Stores the server cert, sets `migrate_on_connect`, applies the client role.
- Pair request (client, `request_pairing`): `GET /remote/hello` on the server (must be `server`), then `POST /remote/pair-request`. The server queues a `PairRequest` (TTL 600 s) and notifies admins. Approve = `adopt` from the server; reject = drop. The client keeps `pending_server` (TTL 600 s) and refuses other servers meanwhile.
- Link: server listens on `bind_link:port_link`, path `/remote`, TLS 1.3, client certificate required and checked against pinned peers. Upgrade refused (HTTP 403) for unknown or disabled peers. A new connection of a peer replaces the old one (close 4409).
- Client uplink: `wss://<server_ip>:<server_link_port>/remote`. Rechecks the server fingerprint at application level. Reconnect backoff 2 s to 30 s.
- Link frames: text not starting with `link:` = viewer frame (server to client viewer; client to server `WebviewInfo` / `WindowReloaded`); `link:` prefix = control JSON; binary = file chunk.
- Migration on adopt (client): sends everything it has (`plan_everything`) as bundle `adopt:<node_id>`, then removes it locally; keeps the empty default playlist. On failure nothing is removed and it retries on the next connection.
- Unpair (server, `unpair_client`):
  1. If connected: sends what the client's windows use (`plan_for`) as bundle `leave:<id>`.
  2. Removes here only what no other viewer or the default playlist uses (`plan_leave`).
  3. Sends `link:unpaired`, disconnects (4403), forgets the peer, reloads the listener.
  - Offline and not `force`: refused. `force` forgets without moving content.
- Leave (client, `leave_server`): sends `leave-request`. Server unpairs; on failure replies `leave-refused`. Client receives `unpaired` and runs `forget_server`.
- Forget server (client): standalone with local content; clears the file cache.
- Transfer: `transfer-begin {id, manifest}` -> `transfer-want {files}` (files missing by name and SHA-256) -> per file `file-begin`, binary chunks (512 KiB), `file-end` -> `transfer-commit` -> receiver applies all or nothing -> `transfer-done` or `transfer-error`. Sender removes nothing before `transfer-done`.
- Transfer id = hash of scope and content. A retry resumes staged files; applied ids are remembered (last 100) and skipped.
- Apply (`bundle.apply_bundle`): files (name clash gets a new name), playlists (id clash gets a new id, `file:` URLs remapped), assignments, window settings and layouts. Any failure undoes the call.
- Window settings that travel (`bundle.WINDOW_FIELDS`, keyed `<viewer>|<screen>`): `audio_outputs`, `keyboards`, `orientations`, `flips`, `screensavers`, `refreshes`, `languages`, `modes`. `modes` (confirmed output mode) is validated as `OutputMode` on arrival. A viewer that leaves takes the same fields with it (`WebviewManager.drop_viewer_settings`).
- File cache: the server computes per client viewer the files of its assigned playlists (panes included) and sends `kind: cache` transfers with a `keep` list. The client sends `cache-have` ({name: sha256}) on connect and after each transfer. Server debounce 1.5 s. Files live beside uploads, served by `UploadedFiles`.
- Viewers: remote viewers are registered in `WebviewManager` with ip, port, hostname. The local viewer id is `local-webview`. A paired client's local viewer is detached from its scheduler (`viewer_gone`).
- UI: `service.state()` is pushed to admins (`Settings/Remote/mode`) on every `changed()`. Notifications: `remote.start`, `remote.pair-requests`, `remote.client-offline.<id>`, `remote.server`.

## Interfaces

CLI: `--bind_link` (0.0.0.0), `--port_link` (4443), `--port_secure` (443, web port used for hello/adopt/pair-request and advertised as `web_port`), `--remote_file` (`/etc/unitotem/remote.json`, 0600), `--uploads_folder` (`transfer/` and `remote-files/` sit beside it).

`remote.json` keys: `role`, `identity_cert`, `identity_key`, `server_ip`, `server_port` (443), `server_link_port`, `server_id`, `server_name`, `server_cert`, `migrate_on_connect`, `peers` (`{node_id: {id, name, cert, ip, port, enabled, paired_at}}`), `rsa_prik` (signs viewer commands; not a link boundary). Written atomically (`.tmp`, fsync, rename). An unreadable file is renamed `remote.json.corrupt` and the node starts unpaired.

HTTP (web port, unauthenticated, rate limited per source IP):

| Endpoint | Limit | Body | Answer |
|---|---|---|---|
| `GET /remote/hello` | 30/min | none | `{v, node_id, name, role, adoptable, cert, web_port, link_port}` |
| `POST /remote/adopt` | 6/min | `{v, cert, name, web_port, link_port, expect_fingerprint}` | hello of this node |
| `POST /remote/pair-request` | 6/min | `{v, cert, name, web_port, link_port}` | hello of this node |

Errors: 400 not a JSON object, 409 `PairingError` (`detail` = message), 413 body over 16 KiB, 429 rate limited.

Link (`wss://host:port_link/remote`): headers `hostname`, `port`. Close codes: 4403 unpaired/unknown or disabled, 4409 replaced. Control messages (`link:`): `transfer-begin`, `transfer-want`, `file-begin`, `file-end`, `transfer-commit`, `transfer-done`, `transfer-error`, `transfer-abort`, `cache-have`, `leave-request`, `leave-refused`, `unpaired`.

WS API `Settings/Remote/<method>` (admin): `mode`, `key_status`, `become_client`, `become_server`, `probe(host, port=443)`, `adopt(host, port, fingerprint)`, `approve_request(client_id)`, `reject_request(client_id)`, `unpair_client(client_id, force=false)`, `request_pairing(server_ip, server_port=443)`, `cancel_pairing`, `leave_server`, `forget_server`, `set_client_enabled(client_id, enabled)`. `PairingError` returns `{error}`.

State pushed as `mode`: `role`, `name`, `node_id`, `fingerprint`, `link_port`, `discovery`, `clients[]`, `discovered[]`, `requests[]`, `server{ip, port, name, fingerprint, state, error}`, `pairing{ip, name, fingerprint}`, `notice`, `migrating`. Uplink `state`: `idle | connecting | connected | rejected | unreachable`.

Limits: HTTP body 16 KiB; certificate PEM 8 KiB; link message 2 MiB; chunk 512 KiB; files 5000; playlists 500; windows 64; file size 1 TiB; transfer silence timeout 120 s; pair requests 16 total, 3 per IP, TTL 600 s; discovery 64 found, names 64 chars, resolve 3 s; HTTP client timeout 10 s; disk margin 256 MiB; stale staging removed after 24 h.

Discovery needs `python3-zeroconf`; without it `AVAILABLE` is false and only manual pairing works.

## Rules and gotchas

- Trust = certificate fingerprint. The admin confirms the fingerprint from `probe`; the client page shows the same one. HTTP calls to unpaired devices skip verification by design (`ssl=False`).
- An unpaired client accepts adoption from anyone. A paired node is never adopted by a request alone.
- Pairing addresses must be non-loopback, non-multicast IPv4 (`clean_host`): a node cannot pair with itself on localhost.
- Peer input is never trusted: strict parsing, bounded sizes, `fullmatch` on ids and digests. File names: no `/`, `\`, NUL, or leading `.`.
- Pinning needs the peer certificate, which Hypercorn does not expose: the mutual-TLS link is its own `websockets` server (`bind_link:port_link`), the web UI stays on Hypercorn.
- A pinned certificate cannot be removed from a live `SSLContext`: adding uses `load_verify_locations` (no restart); removing reloads the listener.
- With TLS 1.3 a refused client certificate reaches the client as an invalid HTTP response (`InvalidMessage`), not as a TLS alert.
- Identity validity starts 2000-01-01 for 80 years: a board without RTC must not refuse it. Never renew it behind a peer's back.
- Restore replaces the whole state and rejects a cert/key pair that does not match.
- Nothing is removed at the sender before `transfer-done`. A failed unpair changes nothing unless `force`.
- Committed transfer ids are reset on every pairing change (same content moving again is a new transfer).
- One transfer at a time per channel (`Another transfer is in progress`).
- The client file cache is state: not in backups, emptied by `forget_server`.
- `/remote` websocket on the web port accepts loopback only; paired clients reach the node through the link.
- A paired client's windows belong to its server; its local scheduler does not drive them.
- A role or peer-set change takes effect through `apply_role()`, the only restart path for link, announcer and browser.
- Link listener bind failure is logged and retried (delays 5 s doubling to 60 s, 10 attempts); a pending retry is cancelled by `stop()`. After the last attempt the listener waits for the next `apply_role()`.
- Announcer (no IPv4 address, registration failure) and browser (open failure) are retried the same way, cancelled by `stop()`.
- mDNS in containers needs host networking.
- Do not remove zeroconf entries by hand: no "added" event fires on re-announce. Filter in the view.

## Tests

- `pytest manager/tests/test_remote_*.py` from the repository root.
- Files: `test_remote_model`, `_pairing`, `_tls`, `_discovery`, `_link`, `_transfer`, `_filecache`, `_windows` (93 test functions).
