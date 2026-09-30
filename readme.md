<p align="center">
  <img src="assets/icon/vault_approver_1024.png" width="128" height="128" alt="Vault Approver icon">
</p>

<h1 align="center">Vault Approver</h1>

<p align="center">
  <strong>EN</strong> &nbsp;|&nbsp; <a href="readme_ru.md">RU</a>
</p>

<p align="center">
  Lightweight mobile app for approving <em>"Log in with device"</em> requests<br>
  on Bitwarden cloud (bitwarden.com / bitwarden.eu) or a self-hosted
  <a href="https://github.com/dani-garcia/vaultwarden">Vaultwarden</a> / Bitwarden server.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/vaultapprover/id6759904301"><img src="https://img.shields.io/badge/App_Store-0D96F6?style=for-the-badge&logo=app-store&logoColor=white" alt="Download on the App Store"></a>
  &nbsp;
  <a href="https://play.google.com/store/apps/details?id=com.vaultapprover.app"><img src="https://img.shields.io/badge/Google_Play-414141?style=for-the-badge&logo=google-play&logoColor=white" alt="Get it on Google Play"></a>
</p>

<p align="center">
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.5+-02569B?logo=flutter" alt="Flutter"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart" alt="Dart"></a>
  <img src="https://img.shields.io/badge/Platform-iOS%20%7C%20Android-lightgrey" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="License"></a>
</p>

---

## Why?

Bitwarden supports passwordless login via "Log in with device", but approving those requests requires a **full-featured** client (Bitwarden Mobile / Desktop).

Vault Approver is a **single-purpose** alternative:

```
Open app → Face ID / Touch ID → see pending requests → Approve or Deny → done
```

No vault UI, no stored passwords — just an approver.

## Features

| | Feature | Details |
|---|---|---|
| ☁️ | **Cloud or self-hosted** | bitwarden.com (US), bitwarden.eu (EU) or any self-hosted Vaultwarden / Bitwarden URL — custom port and path are kept |
| 🪪 | **Client certificates (mTLS)** | Import a `.p12` / `.pfx` for a self-hosted server that requires one; subject and expiry are shown, with a warning 30 days before it expires; used for both REST and the WebSocket |
| 🔐 | **Biometric unlock** | Face ID / Touch ID on every launch |
| 🗂️ | **Two tabs** | **Vault** (Pending and History) and **PIN** (offline PIN tools, see below) |
| ⚡ | **Real-time notifications** | SignalR WebSocket + MessagePack; polling fallback |
| 🔑 | **Fingerprint phrase** | 5-word EFF phrase shown before approval — computed exactly like the official Bitwarden clients, so it matches the phrase on the requesting device |
| ⏳ | **5-minute window** | Countdown on the server's clock; an expired request can no longer be approved (Vaultwarden only honours approvals for 5 minutes) |
| 🛡️ | **Full E2E encryption** | Master password never stored; RSA-2048-OAEP key exchange |
| 📲 | **Two-step login** | Authenticator app (TOTP), email (the code is requested for you, with resend), YubiKey OTP and recovery code; "Remember this device". Duo and passkeys / FIDO2 keys are listed but need another method |
| ✉️ | **New-device verification** | bitwarden.com's e-mailed device code, with resend. The device ID survives logout, so the app stays one device on the server |
| 🌍 | **Localization** | English, Russian, Arabic and Simplified Chinese; language switcher on the setup screen and in Settings |
| 🎨 | **Themes** | System / Light / Dark |
| 🔒 | **Privacy screen** | iOS blur overlay + Android FLAG_SECURE; hides content in app switcher |
| 🔄 | **Auto-refresh** | Configurable polling (5 s / 15 s / 30 s / 1 min) |
| ⏱️ | **Lock timeout** | Auto-lock: immediate / 15 s / 1 min / 5 min / 15 min / never |

## Servers

| Server | In the app |
|:--|:--|
| bitwarden.com | Pick **bitwarden.com** (uses `api.`, `identity.` and `notifications.bitwarden.com`) |
| bitwarden.eu | Pick **bitwarden.eu** |
| Self-hosted | Pick **Self-hosted** and enter the URL, e.g. `https://vault.example.com:8443` |
| Self-hosted with mTLS | Also tap **Import .p12 / .pfx** under *Client certificate* and enter the file's password |

- A client certificate belongs to one server (`scheme://host:port`), is kept in the Keychain / Keystore, survives logout and can be viewed, replaced or removed in **Settings**. If a server demands a certificate the app says so instead of showing a generic TLS error.
- Only accounts that unlock with a master password are supported (not SSO, trusted-device or Key Connector accounts).
- Vaultwarden ≥ 1.35 is recommended (`/api/auth-requests/pending`); older versions fall back to `/api/auth-requests`.
- An `http://` address sends the password hash and tokens unencrypted: the app asks before signing in (except for `localhost` / `127.0.0.1`). IPv6 addresses work in brackets, e.g. `https://[fd00::1]:2053`.

## Screenshots

<p align="center">
  <img src="assets/screenshots/login.jpg" width="200" alt="Server login">
  &nbsp;&nbsp;
  <img src="assets/screenshots/setup.jpg" width="200" alt="Setup screen">
  &nbsp;&nbsp;
  <img src="assets/screenshots/request.jpg" width="200" alt="Pending request">
  &nbsp;&nbsp;
  <img src="assets/screenshots/history.jpg" width="200" alt="Approval history">
</p>

<p align="center">
  <em>Server login &nbsp;·&nbsp; App setup &nbsp;·&nbsp; Pending request &nbsp;·&nbsp; History</em>
</p>

## Tech Stack

| Layer | Libraries |
|:--|:--|
| Framework | Flutter SDK ≥ 3.5, Dart |
| State management | flutter_riverpod 2.x |
| Crypto | pointycastle 4.x, cryptography 2.x |
| Networking | dio 5.x, web_socket_channel 3.x, msgpack_dart 1.x |
| Platform | local_auth 2.x, flutter_secure_storage 9.x, uuid 4.x, file_selector 1.x |
| UI | flutter_native_splash 2.x, flutter_launcher_icons 0.14.x |
| L10n | flutter_localizations (SDK), intl |

## Getting Started

### Prerequisites

- Flutter SDK ≥ 3.5.0
- Xcode 15+ (for iOS)
- Android Studio / Android SDK (for Android)

### Run

```bash
flutter pub get
flutter run
```

### Build

```bash
# iOS
flutter build ios --release --no-codesign
# → build/ios/iphoneos/VaultApprover.app

# Android APK
flutter build apk --release

# Android AAB (for Google Play)
flutter build appbundle --release
```

> **Note:** The iOS Xcode target is named **VaultApprover** (`ios/VaultApprover.xcodeproj`), but the scheme is kept as `Runner` for Flutter tooling compatibility.

## Project Structure

```
lib/
├── main.dart                         # Entry point
├── app.dart                          # MaterialApp, providers (theme, locale, timeout), auto-lock
├── demo_fixtures.dart                # Sample requests and history for the demo
├── demo_runtime.dart                 # Demo flags (compile-time and the tester toggle)
├── firebase_options.dart             # Firebase config (settings cloud sync)
├── glass.dart                        # Liquid Glass look: settings, spring, Pressable
│
├── l10n/
│   ├── app_en.arb                    # English strings (template)
│   ├── app_ru.arb                    # Russian strings
│   ├── app_ar.arb                    # Arabic strings (RTL)
│   └── app_zh.arb, app_zh_Hans.arb   # Simplified Chinese (identical)
│
├── models/
│   ├── api_error.dart                # Typed server errors (2FA, new device, mTLS, 429…)
│   ├── auth_request.dart             # AuthRequest model + 5-minute window
│   ├── cipher_string.dart            # CipherString parser & HMAC verifier
│   ├── encryption_type.dart          # EncType enum
│   ├── hub_event.dart                # WebSocket hub events
│   ├── json_util.dart                # camelCase / PascalCase JSON helpers
│   ├── kdf_params.dart               # KDF parameters (Argon2id / PBKDF2)
│   ├── server_environment.dart       # bitwarden.com / bitwarden.eu / self-hosted URLs
│   ├── settings_snapshot.dart        # Synced settings + their validation ("never lock" stays local)
│   ├── token_response.dart           # /connect/token response
│   └── user_session.dart             # Session state (server URL, tokens, keys)
│
├── pin_tools/                        # PIN cores: pure Dart, offline, checked against the Python tools
│   ├── bip39.dart                    # BIP39 words, checksum, seed (PBKDF2-HMAC-SHA512)
│   ├── bip39_english.dart            # BIP39 English wordlist (SHA-256 pinned)
│   ├── ledger_pin24.dart             # Ledger Passwords derivation (password / PIN)
│   ├── mask_pin.dart                 # Legacy pass_pin mask walk
│   ├── pin24_selftest.dart           # Official LedgerHQ vectors for "Check engine"
│   ├── pin_shift.dart                # PIN Shift (per-digit mod 10)
│   ├── python_text.dart              # Python-compatible text rules (NFKD, whitespace, lower)
│   ├── yubikey_ledger.dart           # YubiKey values from Ledger outputs (the 4 + 4 rule)
│   └── yubikey_secrets.dart          # yk-batch-secrets.py port (derived / random, CSV)
│
├── providers/
│   ├── auth_requests_provider.dart   # Pending & history request providers
│   ├── service_providers.dart        # DI providers for services
│   └── session_provider.dart         # Session state provider
│
├── screens/
│   ├── setup_screen.dart             # Setup: server, client certificate, login, 2FA, new device
│   ├── requests_screen.dart          # Main screen: requests, history, PIN tab, settings
│   └── pin/                          # The PIN tab
│       ├── pin_section.dart          # Tool picker, wipe rules, privacy cover
│       ├── pin_session.dart          # Section session: seed cache, wipes, idle timer
│       ├── pin_prefs.dart            # Non-secret PIN prefs (this device only)
│       ├── pin_widgets.dart          # Hardened fields, word/digit cells, dialogs, copy
│       ├── pin24_view.dart           # PIN 24 screen
│       ├── pin24_engine.dart         # PIN 24 isolate glue and seed-entry helpers
│       ├── pin24_selftest_hook.dart  # "Check engine" runner
│       ├── nickname_backup.dart      # Nickname list of a Ledger Passwords backup
│       ├── nickname_backup_picker.dart # Its file picker (the PIN tab's only file access)
│       ├── pin_shift_view.dart       # PIN Shift
│       ├── yubikey_view.dart         # YubiKey
│       ├── yubikey_engine.dart       # YubiKey isolate glue and settings
│       └── legacy_mask_view.dart     # Legacy mask
│
├── services/
│   ├── vault_api.dart                # REST API client (Vaultwarden / Bitwarden API)
│   ├── crypto_service.dart           # Full Bitwarden-compatible crypto chain
│   ├── notification_service.dart     # SignalR WebSocket + polling fallback
│   ├── biometric_service.dart        # Face ID / Touch ID wrapper
│   ├── client_cert_service.dart      # .p12 import + TLS contexts (mTLS)
│   ├── secure_storage_service.dart   # Keychain / Keystore wrapper
│   ├── settings_service.dart         # Local settings (theme, language, lock, polling)
│   ├── settings_sync.dart            # Firestore settings sync
│   ├── auth_service.dart             # Google / Apple sign-in for the sync
│   ├── auth_exception.dart           # Sign-in failures (localized by the UI)
│   └── privacy_service.dart          # Sensitive clipboard, FLAG_SECURE, capture events
│
├── utils/
│   ├── constants.dart                # App constants
│   ├── eff_wordlist.dart             # EFF long wordlist (7 776 words)
│   ├── error_formatter.dart          # Localized error message formatter
│   ├── external_picker.dart          # "A system picker is open" (no lock, no wipe)
│   └── wordlist.dart                 # Wordlist loader
│
└── widgets/
    ├── app_background.dart           # Scene background under every screen
    ├── auth_request_card.dart        # Request card: countdown, trust status, actions
    ├── client_cert_section.dart      # Client certificate row (import / replace / remove)
    ├── device_icon.dart              # Browser / desktop / CLI / mobile icons
    ├── fingerprint_phrase.dart       # Fingerprint phrase widget
    ├── glass_top_bar.dart            # Glass app bar with tabs
    ├── login_dialogs.dart            # 2FA method picker, code dialogs
    ├── option_pills.dart             # Selection pills + section header (settings, PIN)
    ├── server_selector.dart          # bitwarden.com / bitwarden.eu / self-hosted pills
    └── unlock_shell.dart             # Face ID lock screen and reveal

tool/e2e/                             # Local Vaultwarden 1.37.x + Caddy mTLS stack and Python harness
test/
├── e2e/server_e2e_test.dart          # Server e2e (skipped unless the stack is up)
├── firestore_rules/                  # firestore.rules checks in the Firebase emulator
└── …                                 # Unit and widget tests (mirrors lib/)
```

## Security Model

| Aspect | Implementation |
|:--|:--|
| Key storage | UserKey encrypted (AES-256-CBC) and stored in Keychain (iOS) / Keystore (Android) |
| Biometric gate | Face ID / Touch ID required on every app launch to decrypt UserKey |
| E2E | Server never sees encryption keys |
| Master password | Entered **once** during setup, never stored |
| Request verification | Fingerprint phrase displayed before approval (official Bitwarden algorithm); no phrase → Approve disabled |
| Client certificate | `.p12` + password in Keychain / Keystore, per server; presented only to that server (redirects are not followed) |
| Weak or extreme KDF from a server | Refused outside the official ranges (PBKDF2 5 000–2 000 000 iterations; Argon2id 16–1024 MiB, 2–10 iterations, 1–16 lanes) |
| Reinstall | iOS keeps Keychain items after the app is deleted; a reinstalled app wipes them on first start |
| "Known IP" frame | Only for public IPs: a private, CGNAT or loopback address names a proxy or NAT hop, not the device |
| Session ended on the server | Password change or "deauthorize sessions" → back to login; the device ID is kept |
| Privacy screen | iOS: blur overlay in app switcher; Android: `FLAG_SECURE` blocks screenshots & recents |
| Biometric change | Key invalidated → re-setup required |
| Server compromise | Does not reveal UserKey |

## PIN tools

The second tab, **PIN** (next to **Vault**), sits behind the same biometric lock. Every tool runs **fully offline on the phone**: nothing typed there is synced, logged or sent anywhere, and nothing is saved except a PIN Shift vector you choose to keep on the device (a test guards that no PIN code imports anything that can reach the network).

| Tool | What it does |
|:--|:--|
| **PIN Shift** | Per-position modulo-10 shift, `new = base + vector (mod 10)` without carry: encode/decode, lengths 1–16, per-digit breakdown, a paper walkthrough and the threat model. Mnemonic obfuscation, **not a cipher**; no copy button by design. The vector can be saved on the device (**Save on this device**): it is then used automatically, so only the PIN is typed, and the app never shows it again; Replace and Delete are offered instead. |
| **PIN 24** — Ledger recovery | Recovery-only reimplementation of the Ledger Passwords app: BIP39 seed (12/15/18/21/24 words, optional passphrase) + nickname → the PIN or 20-character password the device would type. Typing the first 4 letters of a word and a space completes it (nothing is completed while you are still typing a word). Matches the official LedgerHQ vectors bit for bit; **Check engine** replays them on the phone. Nicknames can also be picked from a list: import a Ledger Passwords backup (`.json` from passwords.ledger.com, `{"parsed": [{"nickname", "charsets"}]}`) **before** typing the seed — the file picker sends the app to the background, so the import is off while a seed is entered or cached. Only nicknames and charsets are read (none given = all sets), the list stays in memory until the next full wipe, a pick never overwrites a typed nickname without asking, and a charset mask the five toggles cannot express (e.g. `MINUS` alone) is used exactly, with a warning. |
| **YubiKey** | PIV PIN/PUK, OpenPGP, FIDO2, OATH and OTP access codes for one or more serials, identical to yubikey-fleet `yk-batch-secrets.py`: from Ledger Passwords entries, from a master key (derived mode) or at random. The Ledger source uses the seed entered in PIN 24: as soon as the phrase there is valid it stays in memory for the tab (no nickname needed), and **Back to YubiKey** returns with the serials and settings kept. PINs still set by hand during the move to Ledger (00, 23, 34) can be excluded. Values are hidden per row with a `sha256_6` checksum; copy one value, or copy a `folder,name,field,value` CSV for a password manager (not directly importable by Bitwarden). Random values exist nowhere else: Clear and switching tools ask first. YAML manifests and `ykman` provisioning stay on the desktop. |
| **Legacy mask** | The archived `pass_pin` generator (an 8-digit mask walked over a 20-character string), shown only with **Show legacy tools**, to recover PINs made with it. Superseded by PIN Shift. |

**Ledger → YubiKey: the 4 + 4 rule.** The card holds at most 8 bytes of PIV PIN/PUK, so they are the **first 4 + last 4 characters** of what the Ledger types for the entries `yk-<serial>-pins` and `yk-<serial>-puk`; the OpenPGP User/Admin and FIDO2 PINs take the whole 20-character output (Admin optionally from `yk-<serial>-admin`). Fields 25 (Reset Code) and 41 (OATH) never come from Ledger; 45/46 are the serial padded to 12 digits. The app warns when the PIV PIN is part of another secret of the same entry and when the Admin PIN shares the `-pins` entry, and blocks values that do not fit the card (non-printable characters, spaces in the 8-character pick).

**Security notes**

- Secrets live only in widget state and an auto-disposed session (the one exception is a saved PIN Shift vector, below). Everything — including the 64-byte seed shared by PIN 24 and YubiKey — is wiped by **Wipe seed** / **Wipe all**, when you leave the PIN tab, when the app leaves the screen, after 2 minutes without activity and on lock; switching tools clears that tool's inputs. A wipe cannot be undone (no undo history survives it) and closes any open PIN dialog. Dart strings cannot be zeroed — closing the app is the final wipe.
- Secret fields turn off suggestions, autocorrect, keyboard learning and autofill, offer only Paste and ignore the copy/cut/undo shortcuts; the seed field has no reveal. Error messages never quote secret input unless you turn on **Show typed words** (then invalid words and completions are shown); invalid serial numbers are quoted, since serials are not secret.
- Hidden fields show the last character you type for a moment, like the system's own password fields: this is Flutter's standard behaviour with no per-field switch (on Android it follows the system setting "Show passwords"; iOS always does it). Pasted text is never shown.
- After a paste the app reminds you that the secret is still on the clipboard; **Wipe seed**, **Wipe all**, **Clear** and leaving the tab also clear it (and a copied result that is still ours).
- Android sets `FLAG_SECURE` on the PIN tab (test builds made with `-Pallow-screenshots=true` say so); iOS hides the tab while the screen is recorded or mirrored and warns after a screenshot.
- Copies use a native channel: local-only (no Universal Clipboard) with an expiry on iOS; on Android the clip is flagged `IS_SENSITIVE` and cleared after 60 seconds, which clipboard-sync apps can still copy. Android 13+ confirms every copy itself, so the app shows no second "Copied" message there. Derivations run in a background isolate.
- A saved PIN Shift vector is kept in the Keychain / Keystore (iOS: a this-device-only item that needs a device passcode), never in preferences or cloud sync. It survives logout (it is device data, not vault data) and is removed by **Delete**, a full reset or a reinstall. It is never shown or read aloud again; anyone who can open the unlocked app can compute with it, and one result for a PIN they know reveals it.
- PIN 24 is for recovery only: a seed typed into a phone is exposed to the OS, keyboards and backups — use the real Ledger whenever possible.

## Crypto Chain

<details>
<summary><strong>First-time setup</strong></summary>

```
1. POST {identity}/accounts/prelogin { email }
   → { kdf, kdfIterations, kdfMemory (MiB), kdfParallelism, salt?, kdfSettings? }

2. salt = (server salt ?? email).trim().toLowerCase()
   PBKDF2-SHA256(password, salt, iterations)  or
   Argon2id(password, SHA-256(salt), memory = kdfMemory × 1024 KiB, …)
   → masterKey (32 bytes)

3. HKDF-Expand-SHA256(masterKey, info="enc", 32) → stretchedEncKey
   HKDF-Expand-SHA256(masterKey, info="mac", 32) → stretchedMacKey

4. PBKDF2-SHA256(masterKey, password, 1 iteration) → masterPasswordHash

5. POST {identity}/connect/token {   # headers: Bitwarden-Client-Name,
                                      #   Bitwarden-Client-Version, Device-Type
     grant_type: "password", username: email,
     password: masterPasswordHash, client_id: "mobile",
     scope: "api offline_access",
     deviceType: 0|1, deviceIdentifier: uuid,
     deviceName: "VaultApprover"
   }
     (+ twoFactorProvider/twoFactorToken/twoFactorRemember, newDeviceOtp)
   → { access_token, refresh_token, TwoFactorToken?,
       UserDecryptionOptions.MasterPasswordUnlock.MasterKeyEncryptedUserKey (or Key) }

6. CipherString.parse(Key)          # "2.{iv}|{ct}|{mac}"
   → HMAC-SHA256 verify → AES-256-CBC decrypt
   → userKey (64 bytes = 32 enc + 32 mac)

7. Random biometricStorageKey (64 bytes)
   → AES-256-CBC encrypt(userKey) → store in Keychain/Keystore
   → Store refresh_token in secure storage
```

</details>

<details>
<summary><strong>Approving a request</strong></summary>

```
1. Biometric unlock → decrypt userKey from storage

2. GET {api}/auth-requests/pending (Bearer token; falls back to /auth-requests)
   → [{ id, publicKey, requestDeviceType, requestIpAddress, creationDate, … }]
   keep unanswered requests younger than 5 minutes on the server clock
   (HTTP Date header or GET /api/now), newest per device

3. Fingerprint phrase (same as the official clients):
   okm = HKDF-Expand(PRK = SHA-256(publicKey), info = lowercase(email), 32)
   n = big-endian integer(okm); 5 × { word = EFF[n mod 7776]; n = n div 7776 }

4. Approve:
   RSA-2048-OAEP-SHA1(userKey, publicKey) → "4.{base64}"
   PUT /api/auth-requests/{id} { key, requestApproved: true }

5. Deny:
   PUT /api/auth-requests/{id} { key: null, requestApproved: false }
```

</details>

<details>
<summary><strong>WebSocket notifications (SignalR + MessagePack)</strong></summary>

```
1. Connect: wss://{notifications}/hub?access_token=JWT (fresh token per connect;
   client certificate if configured)
2. Handshake: {"protocol":"messagepack","version":1}\x1e → {}\x1e
3. Messages: [1, {}, null, "ReceiveMessage", [{ Type: 15, Payload: {Id, UserId} }]]
4. Keepalive: ping (type 6) every 15 s; LogOut (type 11) → back to login
5. Fallback: polling GET /api/auth-requests
```

</details>

## API Notes

- An approval is honoured for **5 minutes** after the request was created (Vaultwarden; bitwarden.com allows 15); the rows are purged after about 15 minutes
- Token endpoint: `POST /identity/connect/token` (`application/x-www-form-urlencoded`)
- Refresh: `grant_type=refresh_token&refresh_token=…&client_id=mobile`
- Device registration is automatic on first login
- `client_id: "mobile"` is required

## Localization

Strings live in `lib/l10n/` as ARB files:

| File | Language |
|:--|:--|
| `app_en.arb` | English (template) |
| `app_ru.arb` | Russian |
| `app_ar.arb` | Arabic |
| `app_zh.arb`, `app_zh_Hans.arb` | Simplified Chinese |

Generated code is created automatically (`generate: true` in `pubspec.yaml`).

To add a locale: create `app_XX.arb` → add to `supportedLocales` in `lib/app.dart`.

Users can switch language in-app: **Settings → Language**, or the language button on the setup screen (System / English / Русский / العربية / 简体中文).

## License

MIT

## References

**Documentation:**
- [Bitwarden Security Whitepaper](https://bitwarden.com/help/bitwarden-security-white-paper/)
- [Bitwarden Authentication Deep-Dive](https://contributing.bitwarden.com/architecture/deep-dives/authentication/)
- [Bitwarden KDF Algorithms](https://bitwarden.com/help/kdf-algorithms/)
- [Bitwarden Fingerprint Phrase](https://bitwarden.com/help/fingerprint-phrase/)

**Source code:**
- [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) — server
- [bitwarden/clients](https://github.com/bitwarden/clients) — official clients

**Key dependencies:**
- [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) — state management
- [pointycastle](https://pub.dev/packages/pointycastle) — AES, RSA, HMAC, PBKDF2
- [cryptography](https://pub.dev/packages/cryptography) — Argon2id, HKDF
- [dio](https://pub.dev/packages/dio) — HTTP client
- [web_socket_channel](https://pub.dev/packages/web_socket_channel) — WebSocket
- [local_auth](https://pub.dev/packages/local_auth) — biometric authentication
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — Keychain / Keystore
