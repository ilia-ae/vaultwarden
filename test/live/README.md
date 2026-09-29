# Live smoke test (real servers, no credentials)

`live_smoke_test.dart` drives the app's real network code (`VaultApiService`, `NotificationService`,
`ServerEnvironment`, the typed errors in `lib/models/api_error.dart`) against real servers:

| Key    | Target                                                              |
|--------|---------------------------------------------------------------------|
| `ddns` | main server `https://ddns.ilia.ae:2053` (Vaultwarden behind Cloudflare) |
| `us`   | Bitwarden cloud US (`ServerEnvironment.us`)                         |
| `eu`   | Bitwarden cloud EU (`ServerEnvironment.eu`)                         |

It is skipped unless `VA_LIVE=1`, so a plain `flutter test` never touches the network.

```sh
VA_LIVE=1 flutter test test/live/live_smoke_test.dart
VA_LIVE=1 VA_LIVE_TARGETS=us,eu flutter test test/live/live_smoke_test.dart   # a subset
VA_LIVE=1 VA_LIVE_OUT=/tmp/va-live flutter test test/live/live_smoke_test.dart # + .md/.json report
```

`VA_LIVE_MAIN_URL` overrides the main server URL. The test prints a per-target table as `[live] …`
lines.

## What it touches

It makes one pass per target with no loops or retries. A guard in the HTTP adapter and in the hub
channel factory refuses any request that is not on the list below, or that repeats one already
made. The refusal happens locally, before anything is sent, and it fails the test.

1. `GET {api}/config`: checks for JSON and records the server version.
2. `POST {identity}/accounts/prelogin` with `vaultapprover-live-smoke@example.invalid`, a reserved
   TLD that can never be an account. Checks that the KDF parses and passes `KdfParams.validate()`
   (F15).
3. `POST {identity}/connect/token`: one password grant through `VaultApiService.login()`, with the
   same fake e-mail, a random password, a fresh random `deviceIdentifier` and the app's real
   `Bitwarden-Client-*` / `Device-Type` headers. Expects `InvalidCredentialsException` carrying the
   server's own message verbatim (F9). A client-version rejection (F2), a Cloudflare page, a 403 or
   a 429 fails the test.
4. No request: the clock offset from the HTTP `Date` header, computed with the formula of
   `VaultApiService._clockOffsetFrom`. It must be under 2 minutes (F5).
5. One WebSocket upgrade to the hub (`{notifications}/hub`, or `/notifications/hub` on a self-hosted
   server) with an obviously invalid token. Expects HTTP 401 and hub state `waitingForToken`
   (F10/F16). The hub is reset right after this first failure, and a reconnect attempt would fail
   the test.
6. `GET {api}/auth-requests/pending` without a token. Expects a typed 401 (`ServerException`,
   `isAuthError`), which shows the route exists.

The test uses no real credentials and reads no keychain, because secure storage is mocked. It
creates no auth requests, registers no accounts and calls no other endpoints. That comes to 4 HTTP
requests and 1 WebSocket upgrade per target, 15 in total.

Keep manual runs rare. Each run makes one failed login per target, and repeated runs can trip the
servers' login rate limits.

# Live auth test (real server, your own account)

`live_auth_test.dart` runs the whole "Log in with device" flow against a real self-hosted
Vaultwarden with a real account. The approving side is the app's real services
(`VaultApiService`, `CryptoService`, `NotificationService`, `ClientCertService`,
`SecureStorageService` over a mocked keychain), wired like `test/e2e/server_e2e_test.dart`. The
requesting device is `tool/e2e/requester.py`.

It is skipped unless `VA_LIVE_BASE`, `VA_LIVE_EMAIL` and `VA_LIVE_PASSWORD` are all set, so
`flutter test` never touches a server or an account on its own. It does not need Docker or the
local e2e stack.

## One-time setup: the requester venv

The requester is Python (3.10 or newer) and needs `tool/e2e/requirements.txt`, as described in
`tool/e2e/README.md`. The venv is gitignored:

```sh
python3 -m venv tool/e2e/.venv
tool/e2e/.venv/bin/pip install -r tool/e2e/requirements.txt
```

## Run

From the repository root:

```sh
read -rs VA_LIVE_PASSWORD && export VA_LIVE_PASSWORD   # keeps it out of shell history
VA_LIVE_BASE=https://ddns.ilia.ae:2053 \
VA_LIVE_EMAIL='you@example.com' \
VA_LIVE_PYTHON=tool/e2e/.venv/bin/python \
flutter test test/live/live_auth_test.dart
unset VA_LIVE_PASSWORD
```

The one-line form works too:
`VA_LIVE_BASE=https://ddns.ilia.ae:2053 VA_LIVE_EMAIL=… VA_LIVE_PASSWORD=… VA_LIVE_PYTHON=tool/e2e/.venv/bin/python flutter test test/live/live_auth_test.dart`.

| Variable | Meaning |
|---|---|
| `VA_LIVE_BASE` | Server base URL. Self-hosted only. `http://` is accepted for localhost only. |
| `VA_LIVE_EMAIL`, `VA_LIVE_PASSWORD` | The account. The test reads them only from the environment. |
| `VA_LIVE_TOTP_SECRET` | Base32 authenticator secret, required if the account has TOTP 2FA. Other 2FA methods are not supported. |
| `VA_LIVE_PYTHON` | Python with the requirements. Default `tool/e2e/.venv/bin/python`, else `python3`. |
| `VA_LIVE_P12`, `VA_LIVE_P12_PASS` | Client certificate for a server behind mandatory mTLS (the app side). |
| `VA_LIVE_CLIENT_CRT`, `VA_LIVE_CLIENT_KEY` | The same identity as PEM, for the requester, because Python `requests` cannot read a `.p12`. |
| `VA_LIVE_CA` | PEM of a private CA that signed the server certificate. Used by both sides. |

For the mTLS stand, extract the PEM pair once with
`openssl pkcs12 -in me.p12 -clcerts -nokeys -out me.crt` and
`openssl pkcs12 -in me.p12 -nocerts -nodes -out me.key` (add `-legacy` for old `.p12` files).
The key file is unencrypted, so delete it afterwards.

The output is one `PASS`/`FAIL` line per step, printed as `[live-auth] …`, plus non-secret facts:
the server version, KDF parameters, timings, the hub latency, whether responses came through
Cloudflare, and what kind of address Vaultwarden recorded for the requester. The test never
prints the password, the password hash, tokens, the TOTP secret or code, or any key, and it masks
the e-mail address. Every printed line and failure message goes through a redaction filter.

## Steps

0. Configuration checks (no request). It refuses Bitwarden cloud and plain `http://` to a remote
   host, and checks the requester's Python.
1. `GET {api}/version` returns the server version.
2. `POST {identity}/accounts/prelogin` returns the KDF parameters, which must pass
   `KdfParams.validate()`.
3. One password grant as the device **"VaultApprover live test"**. Its fixed `deviceIdentifier` is
   kept in `test/live/.device_id`. With TOTP, the code goes in the same grant with
   `twoFactorRemember=0`, so no remember token is issued. The user key must decrypt (MAC
   verified).
4. The notifications hub connects with the real token.
5. The requester creates auth request #1. On its first run it first registers its own device with
   one password login.
6. The hub must deliver Type 15 for that request within 10 s. Behind Cloudflare, this checks the
   WebSocket path through the proxy.
7. `GET {api}/auth-requests/pending` lists it. The app's fingerprint phrase must equal the
   requester's Bitwarden phrase, the request must be actionable, and 4 to 5 minutes must be left.
8. Approve. The requester decrypts the user key, logs in with the auth request, and proves the
   key: the account's private key decrypts, matches the server's public key, and equals the
   master-password unwrap.
9. The requester creates auth request #2.
10. Type 15 arrives within 10 s, `/pending` lists it, and the phrase matches.
11. Deny. The requester sees the request deleted, and `/pending` no longer lists it.
12. `GET {api}/devices`: this test device's row exists exactly once.
13. The test stops the hub, resets the services and wipes the keys and the mocked keychain.

If a step fails after a request was created, the test denies (deletes) that request before it
exits, so nothing is left pending on your other devices.

## What one run does to the account

- **Device entries.** It adds "VaultApprover live test" (iOS type, identifier in
  `test/live/.device_id`) and "VaultApprover live test requester" (web/Chrome type, identifier in
  `test/live/.state/state.json`). Both are created on the first run, and later runs reuse them.
  Both files are gitignored. If you delete them, the next run adds new rows. The entries stay in the
  account's device list until you remove them.
- **Two auth requests.** Request #1 is approved and consumed by the requester's login. Request #2
  is denied, and Vaultwarden deletes it at once. Vaultwarden's purge job removes old auth requests
  after 15 minutes.
- **Logins.** One password login by the test device, and one auth-request login by the requester.
  The first run adds one password login by the requester, plus a TOTP retry on a TOTP account.
  These update device activity, and the event log if you have it enabled.
- **The user key is exposed to the local requester.** Approving request #1 encrypts the account's
  user key to the requester's RSA key. The local `requester.py` process decrypts it (this is what
  the test checks), and it also derives the master key from the password to compare. The key lives
  only in that process's memory, and is never printed or written to disk. That is the same trust as
  signing in on a new device on this machine. The requester also downloads the encrypted vault once
  (`GET /api/sync`), and uses only the profile's public key from it.
- **Push notifications.** Your other signed-in clients (VaultApprover on your phone, the browser
  extension, the web vault) show both login requests, because Vaultwarden pushes every auth request
  to all of your devices. Don't answer them. The test answers within seconds, and answering from
  another device can make it fail.
- **E-mails,** if the server has SMTP. The first run can trigger "new device" mails for the two new
  devices. If the login stops at the 2FA prompt (TOTP account without `VA_LIVE_TOTP_SECRET`),
  Vaultwarden may later mail an "incomplete two-step login" notice.
- **TOTP accounts.** The test device never gets a remember token. `requester.py` registers its
  device with TOTP and "remember", and keeps that device's 2FA remember token in
  `test/live/.state/state.json` (gitignored), so later runs skip TOTP on the requester side.
  Deleting the file drops the token, and the next run registers a new requester device.
- **Tokens.** Access and refresh tokens are kept only in memory (the keychain is mocked) and are
  dropped at the end. As with any signed-in device, the test device's refresh token stays valid on
  the server until the device is removed.
- **Nothing else.** The test changes no password, does not reset the security stamp, changes no
  2FA setting, deletes no device, and does not touch the vault, the account settings or the
  account itself.

## Request budget

A guard in the app's HTTP adapter and hub channel factory allows only the requests below. It
refuses anything else, and any request over its count, locally before anything is sent, and the
refusal fails the test. There are no retries.

| Request | Max |
|---|---|
| `GET {api}/version` | 1 |
| `POST {identity}/accounts/prelogin` | 1 |
| `POST {identity}/connect/token` (password grant; a refresh grant is refused) | 1 |
| WebSocket `{base}/notifications/hub` | 2 (connect + at most one reconnect) |
| `GET {api}/auth-requests/pending` | 12 (up to 5 polls, 1 s apart, per request + 1 check; usually 3) |
| `PUT {api}/auth-requests/{id}` | 2 (approve + deny) |
| `GET {api}/devices` | 1 |
| `GET {api}/now` | 1 (only if a response has no `Date` header) |

A normal run sends 9 HTTP requests and 1 WebSocket upgrade from the app side. The requester
sends, per auth request, one anonymous `POST {api}/auth-requests` and a response poll every 2 s.
After the approval it sends one auth-request login and one `GET {api}/sync`. That makes 2 logins
per run (3 to 5 on the first run), well below Vaultwarden's default login limit of 10 per 60 s.
Leave at least a minute between runs: a TOTP code works only once, and the rate limit is per IP.

## If it fails

- **Step 3.** `InvalidCredentialsException` means a wrong e-mail or password.
  `TwoFactorRequiredException` means you need `VA_LIVE_TOTP_SECRET`. A rejected TOTP code or a
  `RateLimitedException` means you should wait a minute before running again.
- **Step 4 or 6.** The WebSocket upgrade or push does not get through the proxy. Check
  `ENABLE_WEBSOCKET` and the proxy's WebSocket support.
- **Step 8.** If the requester exits 3 ("denied") or 5 right after the approve, Vaultwarden saw a
  different client IP for the poll or the login than for the request. Behind Cloudflare, set
  `IP_HEADER=CF-Connecting-IP`. Step 7 prints whether the recorded IP is a Cloudflare edge
  address.
- **Requester error with an HTML page or HTTP 403.** Cloudflare bot protection is blocking the
  Python client. Allow it, or run from inside the LAN.

## Validation

The test was validated only against the local stack (`tool/e2e`): Vaultwarden 1.37.1 and 1.37.3
direct, and 1.37.1 behind Caddy with mandatory mTLS, with the PBKDF2, Argon2id and TOTP accounts.
To repeat that:

```sh
tool/e2e/up.sh
VA_LIVE_BASE=http://127.0.0.1:18080 VA_LIVE_EMAIL=pbkdf2@e2e.test \
VA_LIVE_PASSWORD='E2e-Pbkdf2-Passw0rd!' flutter test test/live/live_auth_test.dart
rm -f test/live/.device_id && rm -rf test/live/.state   # forget the local-stack devices
```
