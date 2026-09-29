<p align="center">
  <img src="assets/icon/vault_approver_1024.png" width="128" height="128" alt="Vault Approver icon">
</p>

<h1 align="center">Vault Approver</h1>

<p align="center">
  <a href="readme.md">EN</a> &nbsp;|&nbsp; <strong>RU</strong>
</p>

<p align="center">
  Легковесное мобильное приложение для одобрения запросов <em>«Вход с устройства»</em><br>
  на self-hosted сервере <a href="https://github.com/dani-garcia/vaultwarden">Vaultwarden</a>.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/vaultapprover/id6759904301"><img src="https://img.shields.io/badge/App_Store-0D96F6?style=for-the-badge&logo=app-store&logoColor=white" alt="Скачать в App Store"></a>
  &nbsp;
  <a href="https://play.google.com/store/apps/details?id=com.vaultapprover.app"><img src="https://img.shields.io/badge/Google_Play-414141?style=for-the-badge&logo=google-play&logoColor=white" alt="Скачать в Google Play"></a>
</p>

<p align="center">
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.5+-02569B?logo=flutter" alt="Flutter"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart" alt="Dart"></a>
  <img src="https://img.shields.io/badge/Platform-iOS%20%7C%20Android-lightgrey" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="License"></a>
</p>

---

## Зачем?

Bitwarden поддерживает вход без мастер-пароля через «Login with device», но для одобрения запросов нужен **полноценный** клиент (Bitwarden Mobile / Desktop).

Vault Approver — **узкоспециализированная** альтернатива:

```
Открыл приложение → Face ID / Touch ID → список запросов → Одобрить или Отклонить → всё
```

Никакого UI хранилища, никаких сохранённых паролей — только approver.

## Возможности

| | Функция | Детали |
|---|---|---|
| 🔐 | **Биометрическая разблокировка** | Face ID / Touch ID при каждом запуске |
| ⚡ | **Уведомления в реальном времени** | SignalR WebSocket + MessagePack; фолбэк на опрос |
| 🔑 | **Fingerprint-фраза** | 5 слов из EFF-списка перед одобрением |
| 🛡️ | **Полное E2E-шифрование** | Мастер-пароль не сохраняется; RSA-2048-OAEP |
| 📲 | **2FA / TOTP** | Двухфакторная аутентификация при настройке |
| 🌍 | **Локализация** | Английский и русский, переключатель в приложении |
| 🎨 | **Темы** | Системная / Светлая / Тёмная |
| 🔒 | **Защита экрана** | iOS: blur-оверлей; Android: FLAG_SECURE; скрывает контент в переключателе задач |
| 🔄 | **Автообновление** | Настраиваемый интервал (5 с / 15 с / 30 с / 1 мин) |
| ⏱️ | **Таймаут блокировки** | Автоблокировка: сразу / 15 с / 1 мин / 5 мин / 15 мин / никогда |

## Скриншоты

<p align="center">
  <img src="assets/screenshots/login.jpg" width="200" alt="Вход на сервер">
  &nbsp;&nbsp;
  <img src="assets/screenshots/setup.jpg" width="200" alt="Настройка приложения">
  &nbsp;&nbsp;
  <img src="assets/screenshots/request.jpg" width="200" alt="Ожидающий запрос">
  &nbsp;&nbsp;
  <img src="assets/screenshots/history.jpg" width="200" alt="История одобрений">
</p>

<p align="center">
  <em>Вход на сервер &nbsp;·&nbsp; Настройка &nbsp;·&nbsp; Ожидающий запрос &nbsp;·&nbsp; История</em>
</p>

## Технологии

| Слой | Библиотеки |
|:--|:--|
| Фреймворк | Flutter SDK ≥ 3.5, Dart |
| State management | flutter_riverpod 2.x |
| Крипто | pointycastle 4.x, cryptography 2.x |
| Сеть | dio 5.x, web_socket_channel 3.x, msgpack_dart 1.x |
| Платформа | local_auth 2.x, flutter_secure_storage 9.x, uuid 4.x |
| UI | flutter_native_splash 2.x, flutter_launcher_icons 0.14.x |
| Локализация | flutter_localizations (SDK), intl |

## Быстрый старт

### Требования

- Flutter SDK ≥ 3.5.0
- Xcode 15+ (для iOS)
- Android Studio / Android SDK (для Android)

### Запуск

```bash
flutter pub get
flutter run
```

### Сборка

```bash
# iOS
flutter build ios --release --no-codesign
# → build/ios/iphoneos/VaultApprover.app

# Android APK
flutter build apk --release

# Android AAB (для Google Play)
flutter build appbundle --release
```

> **Примечание:** iOS-таргет в Xcode называется **VaultApprover** (`ios/VaultApprover.xcodeproj`), но схема сохранена как `Runner` для совместимости с Flutter-инструментами.

## Структура проекта

```
lib/
├── main.dart                         # Точка входа
├── app.dart                          # MaterialApp, провайдеры (тема, локаль, таймаут)
│
├── l10n/
│   ├── app_en.arb                    # Английские строки (шаблон)
│   └── app_ru.arb                    # Русские строки
│
├── models/
│   ├── auth_request.dart             # Модель AuthRequest
│   ├── cipher_string.dart            # Парсер CipherString и HMAC-верификатор
│   ├── encryption_type.dart          # Enum EncType
│   ├── kdf_params.dart               # Параметры KDF (Argon2id / PBKDF2)
│   └── user_session.dart             # Состояние сессии (URL, токены, ключи)
│
├── providers/
│   ├── auth_requests_provider.dart   # Провайдеры запросов (pending и история)
│   ├── service_providers.dart        # DI-провайдеры сервисов
│   └── session_provider.dart         # Провайдер состояния сессии
│
├── screens/
│   ├── setup_screen.dart             # Первичная настройка (URL, email, пароль, 2FA)
│   └── requests_screen.dart          # Главный экран: запросы, история, настройки
│
├── services/
│   ├── vault_api.dart                # REST API-клиент (Vaultwarden / Bitwarden API)
│   ├── crypto_service.dart           # Полная Bitwarden-совместимая крипто-цепочка
│   ├── notification_service.dart     # SignalR WebSocket + polling-фолбэк
│   ├── biometric_service.dart        # Обёртка Face ID / Touch ID
│   └── secure_storage_service.dart   # Обёртка Keychain / Keystore
│
├── utils/
│   ├── constants.dart                # Константы приложения
│   ├── eff_wordlist.dart             # EFF long wordlist (7 776 слов)
│   ├── error_formatter.dart          # Форматирование локализованных ошибок
│   └── wordlist.dart                 # Загрузчик списка слов
│
└── widgets/
    ├── auth_request_card.dart        # Карточка запроса
    └── fingerprint_phrase.dart       # Виджет fingerprint-фразы
```

## Безопасность

| Аспект | Реализация |
|:--|:--|
| Хранение ключей | UserKey зашифрован (AES-256-CBC) и хранится в Keychain (iOS) / Keystore (Android) |
| Биометрический барьер | Face ID / Touch ID при каждом запуске для расшифровки UserKey |
| E2E | Сервер не видит ключей шифрования |
| Мастер-пароль | Вводится **один раз** при настройке, не сохраняется |
| Верификация запроса | Fingerprint-фраза перед одобрением |
| Защита экрана | iOS: blur-оверлей в app switcher; Android: `FLAG_SECURE` блокирует скриншоты |
| Смена биометрии | Ключ инвалидируется → повторная настройка |
| Компрометация сервера | Не раскрывает UserKey |

## PIN-инструменты

Третья вкладка, **PIN**, находится за той же биометрической блокировкой. Все инструменты работают **полностью офлайн на телефоне**: ничего из введённого там не сохраняется, не синхронизируется, не пишется в журналы и никуда не отправляется (тест следит, чтобы PIN-код не импортировал ничего, что может выйти в сеть).

| Инструмент | Что делает |
|:--|:--|
| **PIN 24** — восстановление Ledger | Только для восстановления: повторяет приложение Ledger Passwords — сид BIP39 (12/15/18/21/24 слова, необязательная passphrase) + nickname → PIN или 20-символьный пароль, который набрало бы устройство. Первые 4 буквы слова и пробел дописывают слово целиком (пока слово набирается, ничего не дописывается). Бит в бит совпадает с официальными векторами LedgerHQ; кнопка **«Проверить движок»** прогоняет их на телефоне. |
| **PIN Shift** | Позиционный сдвиг по модулю 10, `новый = база + вектор (mod 10)` без переноса: кодирование/декодирование, длина 1–16, разбор по цифрам, расчёт на бумаге и модель угроз. Мнемоническая обфускация, **не шифр**; кнопки копирования нет намеренно. |
| **YubiKey** | PIV PIN/PUK, OpenPGP, FIDO2, OATH и коды доступа OTP для одного или нескольких серийников — те же, что у `yk-batch-secrets.py` из yubikey-fleet: из записей Ledger Passwords, из мастер-ключа (режим derived) или случайные. Источник Ledger использует сид, введённый в PIN 24: как только фраза там верна, сид хранится в памяти вкладки (nickname не нужен), а **«Назад к YubiKey»** возвращает с сохранёнными серийниками и настройками. PIN, которые на время перехода на Ledger ещё задаются вручную (00, 23, 34), можно исключить. Значения скрыты построчно, с контрольной суммой `sha256_6`; можно скопировать одно значение или CSV `folder,name,field,value` для менеджера паролей (Bitwarden напрямую его не импортирует). Случайных значений больше нигде нет: «Очистить» и переход в другой инструмент сначала спрашивают. YAML-манифесты и прошивка через `ykman` остаются на компьютере. |
| **Legacy mask** | Архивный генератор `pass_pin` (маска из 8 цифр по строке из 20 символов) — только при включённом **«Показать устаревшие инструменты»**, чтобы восстановить созданные им PIN. Заменён PIN Shift. |

**Ledger → YubiKey: правило 4 + 4.** Карта хранит не больше 8 байт PIV PIN/PUK, поэтому это **первые 4 + последние 4 символа** того, что Ledger набирает для записей `yk-<серийник>-pins` и `yk-<серийник>-puk`; PIN User/Admin OpenPGP и FIDO2 берут всю выдачу из 20 символов (Admin — по желанию из `yk-<серийник>-admin`). Поля 25 (Reset Code) и 41 (OATH) никогда не берутся из Ledger; 45/46 — серийник, дополненный нулями до 12 цифр. Приложение предупреждает, если PIV PIN — часть другого секрета той же записи или Admin PIN делит запись `-pins`, и блокирует значения, которые не подходят карте (непечатные символы, пробелы в выборке из 8 символов).

**Безопасность**

- Секреты живут только в состоянии виджетов и автоматически освобождаемой сессии. Всё — включая общий для PIN 24 и YubiKey 64-байтовый сид — стирается кнопками **«Стереть сид»** / **«Стереть всё»**, при уходе с вкладки PIN, при уходе приложения с экрана, после 2 минут без действий и при блокировке; переход в другой инструмент очищает его поля. Стирание нельзя отменить (история отмены не переживает его), и оно закрывает открытые диалоги PIN. Строки Dart обнулить нельзя — окончательно их стирает только закрытие приложения.
- В полях секретов выключены подсказки, автокоррекция, обучение клавиатуры и автозаполнение, в меню — только «Вставить», сочетания копирования, вырезания и отмены не работают; у поля сида нет показа. Сообщения об ошибках не повторяют секретный ввод, пока не включено **«Показывать слова»** (тогда видны неверные слова и варианты); неверные серийные номера цитируются — они не секретны.
- После вставки приложение напоминает, что секрет всё ещё в буфере обмена; **«Стереть сид»**, **«Стереть всё»**, **«Очистить»** и уход с вкладки заодно очищают буфер (и скопированный результат, если он ещё наш).
- Android ставит `FLAG_SECURE` на вкладку PIN (тестовые сборки с `-Pallow-screenshots=true` об этом предупреждают); iOS скрывает вкладку во время записи или трансляции экрана и предупреждает после скриншота.
- Копирование идёт через нативный канал: на iOS только локально (без Универсального буфера) и с истечением; на Android клип помечен `IS_SENSITIVE` и очищается через 60 секунд, но приложения синхронизации буфера всё равно могут его скопировать. Вычисления выполняются в фоновом isolate.
- PIN 24 — только для восстановления: сид, введённый в телефон, доступен ОС, клавиатурам и резервным копиям — по возможности пользуйтесь настоящим Ledger.

## Крипто-цепочка

<details>
<summary><strong>Первичная настройка</strong></summary>

```
1. POST /api/accounts/prelogin { email }
   → { kdf: 1 (Argon2id), kdfIterations, kdfMemory, kdfParallelism }

2. Argon2id(password, salt=email, параметры)
   → masterKey (32 байта)

3. HKDF-Expand-SHA256(masterKey, info="enc", 32) → stretchedEncKey
   HKDF-Expand-SHA256(masterKey, info="mac", 32) → stretchedMacKey

4. PBKDF2-SHA256(masterKey, password, 1 итерация) → masterPasswordHash

5. POST /identity/connect/token {
     grant_type: "password", username: email,
     password: masterPasswordHash, client_id: "mobile",
     scope: "api offline_access",
     deviceType: 0|1, deviceIdentifier: uuid,
     deviceName: "VaultApprover"
   }
   → { access_token, refresh_token, Key (protectedSymmetricKey), … }

6. CipherString.parse(Key)          # "2.{iv}|{ct}|{mac}"
   → HMAC-SHA256 проверка → AES-256-CBC расшифровка
   → userKey (64 байта = 32 enc + 32 mac)

7. Случайный biometricStorageKey (64 байта)
   → AES-256-CBC шифрование(userKey) → Keychain/Keystore
   → refresh_token → secure storage
```

</details>

<details>
<summary><strong>Одобрение запроса</strong></summary>

```
1. Биометрическая разблокировка → расшифровка userKey из хранилища

2. GET /api/auth-requests (Bearer token)
   → [{ id, publicKey, requestDeviceType, requestIpAddress, creationDate }]

3. Fingerprint-фраза:
   SHA256(publicKey) → HKDF-Expand(info=email) → 5 слов из EFF-списка

4. Одобрение:
   RSA-2048-OAEP-SHA1(userKey, publicKey) → "4.{base64}"
   PUT /api/auth-requests/{id} { key, requestApproved: true }

5. Отклонение:
   PUT /api/auth-requests/{id} { key: null, requestApproved: false }
```

</details>

<details>
<summary><strong>WebSocket-уведомления (SignalR + MessagePack)</strong></summary>

```
1. Подключение: ws(s)://server/notifications/hub?access_token=JWT
2. Handshake: {"protocol":"messagepack","version":1}\x1e → {}\x1e
3. Сообщения: [1, {}, null, "ReceiveMessage", [{ Type: 15, Payload: {Id, UserId} }]]
4. Keepalive: ping (type 6) каждые 30 с
5. Фолбэк: polling GET /api/auth-requests
```

</details>

## Детали API

- Запросы на вход истекают через **15 минут** (серверная purge-задача)
- Токен-эндпоинт: `POST /identity/connect/token` (`application/x-www-form-urlencoded`)
- Обновление: `grant_type=refresh_token&refresh_token=…&client_id=mobile`
- Регистрация устройства — автоматически при первом логине
- `client_id: "mobile"` — обязательно

## Локализация

Строковые ресурсы в `lib/l10n/` (формат ARB):

| Файл | Язык |
|:--|:--|
| `app_en.arb` | Английский (шаблон) |
| `app_ru.arb` | Русский |

Генерация кода — автоматически (`generate: true` в `pubspec.yaml`).

Добавить локаль: создать `app_XX.arb` → добавить в `supportedLocales` в `lib/app.dart`.

Переключение языка в приложении: **Настройки → Язык** (Системный / English / Русский).

## Лицензия

MIT

## Ссылки

**Документация:**
- [Bitwarden Security Whitepaper](https://bitwarden.com/help/bitwarden-security-white-paper/)
- [Bitwarden Authentication Deep-Dive](https://contributing.bitwarden.com/architecture/deep-dives/authentication/)
- [Bitwarden KDF Algorithms](https://bitwarden.com/help/kdf-algorithms/)
- [Bitwarden Fingerprint Phrase](https://bitwarden.com/help/fingerprint-phrase/)

**Исходный код:**
- [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) — сервер
- [bitwarden/clients](https://github.com/bitwarden/clients) — официальные клиенты

**Ключевые зависимости:**
- [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) — state management
- [pointycastle](https://pub.dev/packages/pointycastle) — AES, RSA, HMAC, PBKDF2
- [cryptography](https://pub.dev/packages/cryptography) — Argon2id, HKDF
- [dio](https://pub.dev/packages/dio) — HTTP-клиент
- [web_socket_channel](https://pub.dev/packages/web_socket_channel) — WebSocket
- [local_auth](https://pub.dev/packages/local_auth) — биометрическая аутентификация
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — Keychain / Keystore
