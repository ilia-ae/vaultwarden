# Local end-to-end stack for server tests

A throwaway, local-only copy of the servers VaultApprover talks to: Vaultwarden 1.37.1 (what the
`vault-test.ilia.ae` stand runs), the same instance behind Caddy with **mandatory mTLS** (a mirror of
the stand's `Caddyfile.j2`), and Vaultwarden 1.37.3 for regression checks. It also ships a Python
harness that plays the *other* side of "Log in with device": the new device that asks for approval,
and a reference approver.

Everything binds to `127.0.0.1`. All containers, volumes and networks belong to the Docker Compose
project `va-e2e` (`va-e2e-*` / `va-e2e_*`). Never point these scripts at a real server.

| Port  | Container      | What                                                              |
|-------|----------------|-------------------------------------------------------------------|
| 18080 | `va-e2e-vw`    | Vaultwarden 1.37.1, plain HTTP, direct                            |
| 18443 | `va-e2e-caddy` | Caddy 2.11.4, TLS + `client_auth require_and_verify` → `va-e2e-vw` |
| 18081 | `va-e2e-vw137` | Vaultwarden 1.37.3, plain HTTP, direct, **separate database**     |

18080 and 18443 share one database. `DOMAIN` is `https://localhost:18443`.

## Start / stop

Prerequisites: Docker (the `vaultwarden/server:1.37.1`, `vaultwarden/server:1.37.3` and
`caddy:2.11.4` images), OpenSSL 3.4 or newer (Homebrew `openssl@3`, not macOS LibreSSL), and
Python 3.10 or newer.

```sh
tool/e2e/up.sh              # venv (.venv) + PKI (if missing) + containers + accounts
tool/e2e/up.sh --selftest   # the same, then the full harness self-test (about 1 minute)
```

`up.sh` is idempotent. It runs these steps, which you can also run by hand:

```sh
python3 -m venv tool/e2e/.venv && tool/e2e/.venv/bin/pip install -r tool/e2e/requirements.txt
PYTHON=tool/e2e/.venv/bin/python tool/e2e/gen-pki.sh      # re-running regenerates ALL certs
docker compose -f tool/e2e/compose.yaml up -d --wait
tool/e2e/.venv/bin/python tool/e2e/create_accounts.py      # also writes .state/e2e.env
```

If you regenerate the PKI while the stack is running, run `docker restart va-e2e-caddy`.

To tear everything down, including all accounts and certificates:

```sh
docker compose -p va-e2e down -v
rm -rf tool/e2e/.pki tool/e2e/.state            # optional: throwaway PKI + harness state
```

Logs: `docker logs -f va-e2e-caddy` prints one JSON access-log line per request, with `remote_ip`
and `access_token` redacted. `docker logs -f va-e2e-vw` prints Vaultwarden's extended logging.

## Environment for the Dart e2e tests

`create_accounts.py` writes these values to `tool/e2e/.state/e2e.env`. Load them with
`set -a; . tool/e2e/.state/e2e.env; set +a` before `flutter test`. The Python harness reads the same
variables, so overriding one changes both sides.

The Dart suite is `test/e2e/server_e2e_test.dart`. It is skipped unless `VA_E2E_BASE` is set, so a
plain `flutter test` never needs the stack:

```sh
set -a; . tool/e2e/.state/e2e.env; set +a
flutter test test/e2e/server_e2e_test.dart            # about 8 minutes
VA_E2E_SKIP_LONG=1 flutter test test/e2e/server_e2e_test.dart   # without the 5-minute-window test
```

It drives the app's real services and runs `requester.py` and `ops.py` with `VA_E2E_PYTHON`
(default `tool/e2e/.venv/bin/python`). Every scenario prints what it observed as `[e2e] …` lines.
The 1.37.3 tests are skipped when `VA_E2E_VW137_BASE` is not reachable.

| Variable | Default |
|---|---|
| `VA_E2E_BASE` | `http://127.0.0.1:18080` |
| `VA_E2E_MTLS_BASE` | `https://localhost:18443` (use `localhost`: Caddy enforces SNI = Host) |
| `VA_E2E_VW137_BASE` | `http://127.0.0.1:18081` |
| `VA_E2E_CA_PEM` | `<repo>/tool/e2e/.pki/ca.pem`, which signs the server cert and all client certs |
| `VA_E2E_P12` | `<repo>/tool/e2e/.pki/client-compat2022.p12` |
| `VA_E2E_P12_PASS` | `e2e-pass` |
| `VA_E2E_CLIENT_CRT`, `VA_E2E_CLIENT_KEY` | PEM form of the same identity (`client.crt`, `client.key`) |
| `VA_E2E_TOTP_SECRET` | `VAE2ETOTPSECRETXVAE2ETOTPSECRETX` (base32, 20 bytes) |
| `VA_E2E_ADMIN_TOKEN` | `va-e2e-admin-token` (plain-text `/admin` token, local only) |
| `VA_E2E_PBKDF2_EMAIL` / `_PASSWORD` | `pbkdf2@e2e.test` / `E2e-Pbkdf2-Passw0rd!` |
| `VA_E2E_ARGON_EMAIL` / `_PASSWORD` | `argon@e2e.test` / `E2e-Argon2-Passw0rd!` |
| `VA_E2E_TOTP_EMAIL` / `_PASSWORD` | `totp@e2e.test` / `E2e-Totp-Passw0rd!` |

### Accounts

These accounts exist on both databases (18080/18443 and 18081).

| Email | KDF | 2FA |
|---|---|---|
| `pbkdf2@e2e.test` | PBKDF2-SHA256, 600000 iterations | none |
| `argon@e2e.test` | Argon2id, 64 MiB, 3 iterations, 4 lanes | none |
| `totp@e2e.test` | PBKDF2-SHA256, 600000 iterations | authenticator (TOTP, SHA-1, 30 s, 6 digits) |

`(cd tool/e2e && .venv/bin/python -c 'import bwproto; print(bwproto.totp("VAE2ETOTPSECRETXVAE2ETOTPSECRETX"))')`
prints the current code. Vaultwarden stores the last TOTP time step used per user and accepts only
a later step (with ±1 step of clock drift). After one login, a second login in the same 30-second
window needs the next step's code, or has to wait for the next window. `bwproto.BwClient.login`
handles this and uses a remember token (provider 5) when it has one.

## Client identities (`.pki/`, gitignored)

`gen-pki.sh` creates an EC P-256 CA. Its extensions match `vaultwarden-ansible/roles/client_pki`:
`CA:TRUE, pathlen:0` and `keyCertSign, cRLSign`, both critical. The client certs are EC P-256 with
`CN=<name>, O=e2e.test`, no SAN, `digitalSignature` (critical) and EKU `clientAuth`. Every `.p12` has
the password `e2e-pass` and includes the CA cert.

| File | Format | dart:io `SecurityContext` |
|---|---|---|
| `client-compat2022.p12` | Same as the stand's ansible export (`community.crypto` `compatibility2022`): PBES1 SHA1+3DES for key and certs, 50000 rounds, SHA-1 MAC | accepted |
| `client-openssl3.p12` | `openssl pkcs12 -export` defaults: PBES2 PBKDF2-HMAC-SHA256 + AES-256-CBC, SHA-256 MAC | accepted |
| `client-legacy.p12` | `openssl pkcs12 -export -legacy`: RC2-40 certs, 3DES key, SHA-1 MAC | accepted |
| `client-chain.pem` + `client.key` | PEM chain + PKCS#8 key | accepted |
| `client-soon.p12` | Valid identity that expires in 10 days (certificate-expiry warning UI) | accepted |
| `client-expired.p12` | Expired 5 days ago | rejected by Caddy |
| `client-foreign.p12` | Signed by an unrelated CA (`foreign-ca.pem`) | rejected by Caddy |

The client identity is loaded with
`SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(ca)..useCertificateChainBytes(p12, password:)..usePrivateKeyBytes(p12, password:)`.
Without `setTrustedCertificatesBytes(ca)` the handshake fails with `CERTIFICATE_VERIFY_FAILED`,
because the server cert is issued by the throwaway CA. The real stand uses a public Let's Encrypt
certificate instead.

How mTLS failures show up in dart:io: with TLS 1.3, the client finishes its side of the handshake
before the server checks the certificate. A missing, expired or unknown-CA client certificate
therefore arrives as an **`HttpException`** on the first read, not as a `HandshakeException`. The
message contains `TLSV1_ALERT_CERTIFICATE_REQUIRED`, `SSLV3_ALERT_CERTIFICATE_EXPIRED` or
`TLSV1_ALERT_UNKNOWN_CA`. A wrong `.p12` password throws `TlsException ... INCORRECT_PASSWORD` from
`useCertificateChainBytes`.

## Harness scripts

Run the scripts with the venv's Python. Each script accepts `--help`. Device ids and remember tokens
persist in `.state/state.json`.

- `bwproto.py`: Bitwarden client crypto that follows sdk-internal (`kdf.rs`, `master_key.rs`,
  EncString, RSA-OAEP, `fingerprint.rs`), plus a small API client. It reads the EFF wordlist from
  the app's `lib/utils/eff_wordlist.dart`. `python bwproto.py` runs sdk-internal's known-answer tests.
- `create_accounts.py`: registers the accounts (legacy `/identity/accounts/register` body), enables
  TOTP through `/api/two-factor/authenticator`, and checks each account by logging in. It is
  idempotent.
- `requester.py`: the new device. It creates an auth request, prints the id and fingerprint phrase,
  and polls `/api/auth-requests/{id}/response?code=`. On approval it decrypts the user key and logs
  in with `authRequest=<id>` and `password=<accessCode>`. It then checks the key three ways: the
  MAC-verified `PrivateKey` decrypts, its public key matches the server's copy, and it equals the
  user key unwrapped from `Key` with the master password.
  - Exit codes: `0` for the expected outcome, `2` if verification failed, `3` if denied, `4` on
    timeout, `5` if the auth-request login was rejected (for example after the 5-minute window),
    and `1` for other errors.
  - Options: `--mtls`, `--base URL`, `--account pbkdf2|argon|totp`, `--device-type N` (9 Chrome,
    12 Edge, 17 Safari, 10 Firefox), `--client-ip A.B.C.D` (sets `X-Real-IP` on the direct ports to
    fake the requester IP), `--no-wait`, `--expect deny`, `--login-delay S`, `--json`.
  - `--json` prints JSON lines with the events `created` (`id`, `fingerprint`, `creationDate`,
    `requestIpAddress`, …), `answered`, then `verified`, `denied`, `timeout` or `error`.
- `approver_ref.py`: a reference approver. It sends the same PUT body as the app: key
  `"4."+RSA-OAEP-SHA1(userKey[64])`, `masterPasswordHash: null`, and its own `deviceIdentifier`.
  Options: `--list`, `--request-id`, `--expect-fingerprint`, `--deny`, `--mtls`, `--json`.
- `ops.py`: account operations for the Dart suite. `register` creates a throwaway PBKDF2 account
  (optionally with `--totp-secret` authenticator 2FA). `change-password` changes the master
  password through `/api/accounts/password` and keeps the user key. Vaultwarden then rotates
  every device's refresh token and pushes a hub LogOut. Each command prints one JSON line.
- `selftest.py`: runs all of the above end to end. It checks `/alive`, mTLS accept/reject, an
  approve round trip for every account on all three bases, deny round trips, and the
  `/notifications/hub` push of a new auth request, both direct and through Caddy.

Example: create a request, then approve it in the app under test.

```sh
tool/e2e/.venv/bin/python tool/e2e/requester.py --mtls --account totp --timeout 600
```

## Vaultwarden behaviours the tests depend on (1.37.1 and 1.37.3)

- **Known device.** `POST /api/auth-requests` is accepted only from a `deviceIdentifier` that is
  already a device of the account and has the same `Device-Type` header. Otherwise the server
  answers "AuthRequest doesn't exist". `requester.py` registers its device once with a password
  login.
- **Same IP and type.** The response poll and the auth-request login must come from the IP and
  device type that created the request.
- **5-minute window.** The auth-request login is refused ("Username or access code is incorrect")
  5 minutes after `creationDate`, even when the request was approved in time. Check this with
  `--login-delay 305`.
- **Deny deletes.** A deny deletes the row. The requester then sees "AuthRequest doesn't exist",
  and a second PUT fails the same way. A second approve fails with "An authentication request with
  the same device already exists".
- **2FA on auth-request login.** 2FA also applies to the auth-request login on a TOTP account.
- **Hub handshake.** On `/notifications/hub`, the SignalR handshake must be a **text** frame. The
  server answers with a *binary* `{}\x1e` frame, echoes back any other binary frame the client
  sends, and pings with WebSocket ping frames that carry the MessagePack payload `02 91 06`. A new
  auth request arrives as a MessagePack `ReceiveMessage` frame that contains the request id.
  Caddy proxies the upgrade without special config.
- **Rate limits.** The compose file raises the login, admin and unauthenticated rate limits so
  repeated runs never hit 429. To test 429 handling, recreate 1.37.3 with low limits:
  `VA_E2E_UNAUTH_BURST=3 VA_E2E_UNAUTH_RL_SECONDS=60 docker compose -f tool/e2e/compose.yaml up -d va-e2e-vw137`.
  From 1.37.3 onwards, this limit also covers prelogin, `POST /api/auth-requests` and the response
  poll.
- **Requester IP.** On 18443, Caddy sets `X-Real-IP` to the Docker gateway address (for example
  `172.24.0.1`), so every client looks the same. On the direct ports, a client-supplied `X-Real-IP`
  is trusted, which is useful for trust-frame tests.
