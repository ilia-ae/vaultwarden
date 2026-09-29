<p align="center">
  <img src="assets/icon/vault_approver_1024.png" width="128" height="128" alt="Vault Approver icon">
</p>

<h1 align="center">Vault Approver</h1>

<p align="center">
  <strong>EN</strong> &nbsp;|&nbsp; <a href="readme_ru.md">RU</a>
</p>

<p align="center">
  Lightweight mobile app for approving <em>"Login with device"</em> requests<br>
  on a self-hosted <a href="https://github.com/dani-garcia/vaultwarden">Vaultwarden</a> server.
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

Bitwarden supports passwordless login via "Login with device", but approving those requests requires a **full-featured** client (Bitwarden Mobile / Desktop).

Vault Approver is a **single-purpose** alternative:

```
Open app → Face ID / Touch ID → see pending requests → Approve or Deny → done
```

No vault UI, no stored passwords — just an approver.

## Features

| | Feature | Details |
|---|---|---|
| 🔐 | **Biometric unlock** | Face ID / Touch ID on every launch |
| ⚡ | **Real-time notifications** | SignalR WebSocket + MessagePack; polling fallback |
| 🔑 | **Fingerprint phrase** | 5-word EFF phrase shown before approval |
| 🛡️ | **Full E2E encryption** | Master password never stored; RSA-2048-OAEP key exchange |
| 📲 | **2FA / TOTP** | Supports two-factor auth during initial setup |
| 🌍 | **Localization** | English & Russian, in-app language switcher |
| 🎨 | **Themes** | System / Light / Dark |
| 🔒 | **Privacy screen** | iOS blur overlay + Android FLAG_SECURE; hides content in app switcher |
| 🔄 | **Auto-refresh** | Configurable polling (5 s / 15 s / 30 s / 1 min) |
| ⏱️ | **Lock timeout** | Auto-lock: immediate / 15 s / 1 min / 5 min / 15 min / never |

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
| Platform | local_auth 2.x, flutter_secure_storage 9.x, uuid 4.x |
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
├── app.dart                          # MaterialApp, providers (theme, locale, timeout)
│
├── l10n/
│   ├── app_en.arb                    # English strings (template)
│   └── app_ru.arb                    # Russian strings
│
├── models/
│   ├── auth_request.dart             # AuthRequest model
│   ├── cipher_string.dart            # CipherString parser & HMAC verifier
│   ├── encryption_type.dart          # EncType enum
│   ├── kdf_params.dart               # KDF parameters (Argon2id / PBKDF2)
│   └── user_session.dart             # Session state (server URL, tokens, keys)
│
├── providers/
│   ├── auth_requests_provider.dart   # Pending & history request providers
│   ├── service_providers.dart        # DI providers for services
│   └── session_provider.dart         # Session state provider
│
├── screens/
│   ├── setup_screen.dart             # First-time setup (URL, email, password, 2FA)
│   └── requests_screen.dart          # Main screen: request list, history, settings
│
├── services/
│   ├── vault_api.dart                # REST API client (Vaultwarden / Bitwarden API)
│   ├── crypto_service.dart           # Full Bitwarden-compatible crypto chain
│   ├── notification_service.dart     # SignalR WebSocket + polling fallback
│   ├── biometric_service.dart        # Face ID / Touch ID wrapper
│   └── secure_storage_service.dart   # Keychain / Keystore wrapper
│
├── utils/
│   ├── constants.dart                # App constants
│   ├── eff_wordlist.dart             # EFF long wordlist (7 776 words)
│   ├── error_formatter.dart          # Localized error message formatter
│   └── wordlist.dart                 # Wordlist loader
│
└── widgets/
    ├── auth_request_card.dart        # Request card UI
    └── fingerprint_phrase.dart       # Fingerprint phrase widget
```

## Security Model

| Aspect | Implementation |
|:--|:--|
| Key storage | UserKey encrypted (AES-256-CBC) and stored in Keychain (iOS) / Keystore (Android) |
| Biometric gate | Face ID / Touch ID required on every app launch to decrypt UserKey |
| E2E | Server never sees encryption keys |
| Master password | Entered **once** during setup, never stored |
| Request verification | Fingerprint phrase displayed before approval |
| Privacy screen | iOS: blur overlay in app switcher; Android: `FLAG_SECURE` blocks screenshots & recents |
| Biometric change | Key invalidated → re-setup required |
| Server compromise | Does not reveal UserKey |

## PIN tools

A third tab, **PIN**, sits behind the same biometric lock. Every tool runs **fully offline on the phone**: nothing typed there is saved, synced, logged or sent anywhere (a test guards that no PIN code imports anything that can reach the network).

| Tool | What it does |
|:--|:--|
| **PIN 24** — Ledger recovery | Recovery-only reimplementation of the Ledger Passwords app: BIP39 seed (12/15/18/21/24 words, optional passphrase) + nickname → the PIN or 20-character password the device would type. Typing the first 4 letters of a word and a space completes it (nothing is completed while you are still typing a word). Matches the official LedgerHQ vectors bit for bit; **Check engine** replays them on the phone. |
| **PIN Shift** | Per-position modulo-10 shift, `new = base + vector (mod 10)` without carry: encode/decode, lengths 1–16, per-digit breakdown, a paper walkthrough and the threat model. Mnemonic obfuscation, **not a cipher**; no copy button by design. |
| **YubiKey** | PIV PIN/PUK, OpenPGP, FIDO2, OATH and OTP access codes for one or more serials, identical to yubikey-fleet `yk-batch-secrets.py`: from Ledger Passwords entries, from a master key (derived mode) or at random. The Ledger source uses the seed entered in PIN 24: as soon as the phrase there is valid it stays in memory for the tab (no nickname needed), and **Back to YubiKey** returns with the serials and settings kept. PINs still set by hand during the move to Ledger (00, 23, 34) can be excluded. Values are hidden per row with a `sha256_6` checksum; copy one value, or copy a `folder,name,field,value` CSV for a password manager (not directly importable by Bitwarden). Random values exist nowhere else: Clear and switching tools ask first. YAML manifests and `ykman` provisioning stay on the desktop. |
| **Legacy mask** | The archived `pass_pin` generator (an 8-digit mask walked over a 20-character string), shown only with **Show legacy tools**, to recover PINs made with it. Superseded by PIN Shift. |

**Ledger → YubiKey: the 4 + 4 rule.** The card holds at most 8 bytes of PIV PIN/PUK, so they are the **first 4 + last 4 characters** of what the Ledger types for the entries `yk-<serial>-pins` and `yk-<serial>-puk`; the OpenPGP User/Admin and FIDO2 PINs take the whole 20-character output (Admin optionally from `yk-<serial>-admin`). Fields 25 (Reset Code) and 41 (OATH) never come from Ledger; 45/46 are the serial padded to 12 digits. The app warns when the PIV PIN is part of another secret of the same entry and when the Admin PIN shares the `-pins` entry, and blocks values that do not fit the card (non-printable characters, spaces in the 8-character pick).

**Security notes**

- Secrets live only in widget state and an auto-disposed session. Everything — including the 64-byte seed shared by PIN 24 and YubiKey — is wiped by **Wipe seed** / **Wipe all**, when you leave the PIN tab, when the app leaves the screen, after 2 minutes without activity and on lock; switching tools clears that tool's inputs. A wipe cannot be undone (no undo history survives it) and closes any open PIN dialog. Dart strings cannot be zeroed — closing the app is the final wipe.
- Secret fields turn off suggestions, autocorrect, keyboard learning and autofill, offer only Paste and ignore the copy/cut/undo shortcuts; the seed field has no reveal. Error messages never quote secret input unless you turn on **Show typed words** (then invalid words and completions are shown); invalid serial numbers are quoted, since serials are not secret.
- After a paste the app reminds you that the secret is still on the clipboard; **Wipe seed**, **Wipe all**, **Clear** and leaving the tab also clear it (and a copied result that is still ours).
- Android sets `FLAG_SECURE` on the PIN tab (test builds made with `-Pallow-screenshots=true` say so); iOS hides the tab while the screen is recorded or mirrored and warns after a screenshot.
- Copies use a native channel: local-only (no Universal Clipboard) with an expiry on iOS; on Android the clip is flagged `IS_SENSITIVE` and cleared after 60 seconds, which clipboard-sync apps can still copy. Derivations run in a background isolate.
- PIN 24 is for recovery only: a seed typed into a phone is exposed to the OS, keyboards and backups — use the real Ledger whenever possible.

## Crypto Chain

<details>
<summary><strong>First-time setup</strong></summary>

```
1. POST /api/accounts/prelogin { email }
   → { kdf: 1 (Argon2id), kdfIterations, kdfMemory, kdfParallelism }

2. Argon2id(password, salt=email, params)
   → masterKey (32 bytes)

3. HKDF-Expand-SHA256(masterKey, info="enc", 32) → stretchedEncKey
   HKDF-Expand-SHA256(masterKey, info="mac", 32) → stretchedMacKey

4. PBKDF2-SHA256(masterKey, password, 1 iteration) → masterPasswordHash

5. POST /identity/connect/token {
     grant_type: "password", username: email,
     password: masterPasswordHash, client_id: "mobile",
     scope: "api offline_access",
     deviceType: 0|1, deviceIdentifier: uuid,
     deviceName: "VaultApprover"
   }
   → { access_token, refresh_token, Key (protectedSymmetricKey), … }

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

2. GET /api/auth-requests (Bearer token)
   → [{ id, publicKey, requestDeviceType, requestIpAddress, creationDate }]

3. Fingerprint phrase:
   SHA256(publicKey) → HKDF-Expand(info=email) → 5 EFF words

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
1. Connect: ws(s)://server/notifications/hub?access_token=JWT
2. Handshake: {"protocol":"messagepack","version":1}\x1e → {}\x1e
3. Messages: [1, {}, null, "ReceiveMessage", [{ Type: 15, Payload: {Id, UserId} }]]
4. Keepalive: ping (type 6) every 30 s
5. Fallback: polling GET /api/auth-requests
```

</details>

## API Notes

- Auth requests expire after **15 minutes** (server purge job)
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

Generated code is created automatically (`generate: true` in `pubspec.yaml`).

To add a locale: create `app_XX.arb` → add to `supportedLocales` in `lib/app.dart`.

Users can switch language in-app: **Settings → Language** (System / English / Русский).

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
