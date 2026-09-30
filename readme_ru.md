<p align="center">
  <img src="assets/icon/vault_approver_1024.png" width="128" height="128" alt="Vault Approver icon">
</p>

<h1 align="center">Vault Approver</h1>

<p align="center">
  <a href="readme.md">EN</a> &nbsp;|&nbsp; <strong>RU</strong>
</p>

<p align="center">
  Легковесное мобильное приложение для одобрения запросов <em>«Вход с устройства»</em><br>
  в облаке Bitwarden (bitwarden.com / bitwarden.eu) или на своём сервере
  <a href="https://github.com/dani-garcia/vaultwarden">Vaultwarden</a> / Bitwarden.
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
| ☁️ | **Облако или свой сервер** | bitwarden.com (США), bitwarden.eu (ЕС) или любой свой URL Vaultwarden / Bitwarden — нестандартный порт и путь сохраняются |
| 🪪 | **Клиентские сертификаты (mTLS)** | Импорт `.p12` / `.pfx` для своего сервера, который его требует; показываются владелец и срок действия, предупреждение за 30 дней до истечения; используется и для REST, и для WebSocket |
| 🔐 | **Биометрическая разблокировка** | Face ID / Touch ID при каждом запуске |
| ⚡ | **Уведомления в реальном времени** | SignalR WebSocket + MessagePack; фолбэк на опрос |
| 🔑 | **Fingerprint-фраза** | 5 слов из EFF-списка перед одобрением — вычисляется так же, как в официальных клиентах Bitwarden, и совпадает с фразой на запрашивающем устройстве |
| ⏳ | **Окно 5 минут** | Обратный отсчёт по часам сервера; истёкший запрос одобрить нельзя (Vaultwarden принимает одобрение только 5 минут) |
| 🛡️ | **Полное E2E-шифрование** | Мастер-пароль не сохраняется; RSA-2048-OAEP |
| 📲 | **Двухэтапный вход** | Приложение-аутентификатор (TOTP), почта (код запрашивается автоматически, есть повторная отправка), YubiKey OTP и код восстановления; «Запомнить это устройство». Duo и ключи доступа / FIDO2 показываются, но нужен другой способ |
| ✉️ | **Подтверждение нового устройства** | Код из письма bitwarden.com с повторной отправкой. ID устройства переживает выход из аккаунта, поэтому на сервере приложение остаётся одним устройством |
| 🌍 | **Локализация** | Английский, русский, арабский и упрощённый китайский; переключатель в приложении |
| 🎨 | **Темы** | Системная / Светлая / Тёмная |
| 🔒 | **Защита экрана** | iOS: blur-оверлей; Android: FLAG_SECURE; скрывает контент в переключателе задач |
| 🔄 | **Автообновление** | Настраиваемый интервал (5 с / 15 с / 30 с / 1 мин) |
| ⏱️ | **Таймаут блокировки** | Автоблокировка: сразу / 15 с / 1 мин / 5 мин / 15 мин / никогда |

## Серверы

| Сервер | В приложении |
|:--|:--|
| bitwarden.com | Выберите **bitwarden.com** (используются `api.`, `identity.` и `notifications.bitwarden.com`) |
| bitwarden.eu | Выберите **bitwarden.eu** |
| Свой сервер | Выберите **Свой сервер** и введите URL, например `https://vault.example.com:8443` |
| Свой сервер с mTLS | Дополнительно нажмите **Импорт .p12 / .pfx** в блоке *Клиентский сертификат* и введите пароль файла |

- Клиентский сертификат привязан к одному серверу (`схема://хост:порт`), хранится в Keychain / Keystore, переживает выход из аккаунта; посмотреть, заменить или удалить его можно в **Настройках**. Если сервер требует сертификат, приложение так и пишет вместо общей ошибки TLS.
- Поддерживаются только аккаунты, которые разблокируются мастер-паролем (не SSO, не доверенные устройства и не Key Connector).
- Рекомендуется Vaultwarden ≥ 1.35 (`/api/auth-requests/pending`); со старыми версиями используется `/api/auth-requests`.
- Адрес `http://` передаёт хеш пароля и токены без шифрования: приложение спрашивает перед входом (кроме `localhost` / `127.0.0.1`). IPv6-адреса указываются в скобках, например `https://[fd00::1]:2053`.

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
| Платформа | local_auth 2.x, flutter_secure_storage 9.x, uuid 4.x, file_selector 1.x |
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
├── app.dart                          # MaterialApp, провайдеры (тема, локаль, таймаут), автоблокировка
├── demo_fixtures.dart                # Демо-запросы и история
├── demo_runtime.dart                 # Флаги демо (при сборке и переключатель для тестировщиков)
├── firebase_options.dart             # Конфигурация Firebase (облачная синхронизация настроек)
├── glass.dart                        # Стиль Liquid Glass: настройки, пружина, Pressable
│
├── l10n/
│   ├── app_en.arb                    # Английские строки (шаблон)
│   ├── app_ru.arb                    # Русские строки
│   ├── app_ar.arb                    # Арабские строки (RTL)
│   └── app_zh.arb, app_zh_Hans.arb   # Упрощённый китайский (одинаковые)
│
├── models/
│   ├── api_error.dart                # Типизированные ошибки сервера (2FA, новое устройство, mTLS, 429…)
│   ├── auth_request.dart             # Модель AuthRequest + окно 5 минут
│   ├── cipher_string.dart            # Парсер CipherString и HMAC-верификатор
│   ├── encryption_type.dart          # Enum EncType
│   ├── hub_event.dart                # События WebSocket-хаба
│   ├── json_util.dart                # Чтение JSON в camelCase / PascalCase
│   ├── kdf_params.dart               # Параметры KDF (Argon2id / PBKDF2)
│   ├── server_environment.dart       # URL bitwarden.com / bitwarden.eu / своего сервера
│   ├── settings_snapshot.dart        # Синхронизируемые настройки и их проверка («никогда» — только локально)
│   ├── token_response.dart           # Ответ /connect/token
│   └── user_session.dart             # Состояние сессии (URL, токены, ключи)
│
├── pin_tools/                        # Ядра PIN: чистый Dart, офлайн, сверены с Python-инструментами
│   ├── bip39.dart                    # Слова BIP39, контрольная сумма, сид (PBKDF2-HMAC-SHA512)
│   ├── bip39_english.dart            # Английский словарь BIP39 (закреплён SHA-256)
│   ├── ledger_pin24.dart             # Вывод Ledger Passwords (пароль / PIN)
│   ├── mask_pin.dart                 # Устаревший pass_pin (проход маски)
│   ├── pin24_selftest.dart           # Официальные векторы LedgerHQ для «Проверить движок»
│   ├── pin_shift.dart                # PIN Shift (поразрядно по модулю 10)
│   ├── python_text.dart              # Правила текста как в Python (NFKD, пробелы, lower)
│   ├── yubikey_ledger.dart           # Значения YubiKey из выдачи Ledger (правило 4 + 4)
│   └── yubikey_secrets.dart          # Порт yk-batch-secrets.py (derived / random, CSV)
│
├── providers/
│   ├── auth_requests_provider.dart   # Провайдеры запросов (pending и история)
│   ├── service_providers.dart        # DI-провайдеры сервисов
│   └── session_provider.dart         # Провайдер состояния сессии
│
├── screens/
│   ├── setup_screen.dart             # Настройка: сервер, сертификат, вход, 2FA, новое устройство
│   ├── requests_screen.dart          # Главный экран: запросы, история, вкладка PIN, настройки
│   └── pin/                          # Вкладка PIN
│       ├── pin_section.dart          # Выбор инструмента, правила стирания, защитная шторка
│       ├── pin_session.dart          # Сессия раздела: кэш сида, стирание, таймер бездействия
│       ├── pin_prefs.dart            # Несекретные настройки PIN (только на этом устройстве)
│       ├── pin_widgets.dart          # Защищённые поля, ячейки слов/цифр, диалоги, копирование
│       ├── pin24_view.dart           # Экран PIN 24
│       ├── pin24_engine.dart         # Связка PIN 24 с isolate и помощники ввода сида
│       ├── pin24_selftest_hook.dart  # Запуск «Проверить движок»
│       ├── nickname_backup.dart      # Список nickname из бэкапа Ledger Passwords
│       ├── nickname_backup_picker.dart # Выбор его файла (единственный доступ к файлам во вкладке PIN)
│       ├── pin_shift_view.dart       # PIN Shift
│       ├── yubikey_view.dart         # YubiKey
│       ├── yubikey_engine.dart       # Связка YubiKey с isolate и настройки
│       └── legacy_mask_view.dart     # Legacy mask
│
├── services/
│   ├── vault_api.dart                # REST API-клиент (Vaultwarden / Bitwarden API)
│   ├── crypto_service.dart           # Полная Bitwarden-совместимая крипто-цепочка
│   ├── notification_service.dart     # SignalR WebSocket + polling-фолбэк
│   ├── biometric_service.dart        # Обёртка Face ID / Touch ID
│   ├── client_cert_service.dart      # Импорт .p12 и TLS-контексты (mTLS)
│   ├── secure_storage_service.dart   # Обёртка Keychain / Keystore
│   ├── settings_service.dart         # Локальные настройки (тема, язык, блокировка, опрос)
│   ├── settings_sync.dart            # Синхронизация настроек через Firestore
│   ├── auth_service.dart             # Вход Google / Apple для синхронизации
│   ├── auth_exception.dart           # Ошибки входа (локализует интерфейс)
│   └── privacy_service.dart          # Чувствительный буфер обмена, FLAG_SECURE, события записи экрана
│
├── utils/
│   ├── constants.dart                # Константы приложения
│   ├── eff_wordlist.dart             # EFF long wordlist (7 776 слов)
│   ├── error_formatter.dart          # Форматирование локализованных ошибок
│   ├── external_picker.dart          # «Открыт системный выбор файла» (без блокировки и стирания)
│   └── wordlist.dart                 # Загрузчик списка слов
│
└── widgets/
    ├── app_background.dart           # Фон под всеми экранами
    ├── auth_request_card.dart        # Карточка запроса: отсчёт, статус доверия, кнопки
    ├── client_cert_section.dart      # Блок клиентского сертификата (импорт / замена / удаление)
    ├── device_icon.dart              # Иконки браузеров, десктопа, CLI, телефонов
    ├── fingerprint_phrase.dart       # Виджет fingerprint-фразы
    ├── glass_top_bar.dart            # Стеклянная панель с вкладками
    ├── login_dialogs.dart            # Выбор способа 2FA, диалоги кодов
    ├── option_pills.dart             # Пилюли выбора и заголовок раздела (настройки, PIN)
    ├── server_selector.dart          # Переключатель bitwarden.com / bitwarden.eu / свой сервер
    └── unlock_shell.dart             # Экран блокировки Face ID и проявление

tool/e2e/                             # Локальный стек Vaultwarden 1.37.x + Caddy с mTLS и Python-обвязка
test/
├── e2e/server_e2e_test.dart          # E2E с сервером (пропускается без поднятого стека)
├── firestore_rules/                  # Проверка firestore.rules в эмуляторе Firebase
└── …                                 # Unit- и виджет-тесты (повторяют lib/)
```

## Безопасность

| Аспект | Реализация |
|:--|:--|
| Хранение ключей | UserKey зашифрован (AES-256-CBC) и хранится в Keychain (iOS) / Keystore (Android) |
| Биометрический барьер | Face ID / Touch ID при каждом запуске для расшифровки UserKey |
| E2E | Сервер не видит ключей шифрования |
| Мастер-пароль | Вводится **один раз** при настройке, не сохраняется |
| Верификация запроса | Fingerprint-фраза перед одобрением (официальный алгоритм Bitwarden); нет фразы — кнопка «Одобрить» неактивна |
| Клиентский сертификат | `.p12` + пароль в Keychain / Keystore для каждого сервера; предъявляется только этому серверу (редиректы не выполняются) |
| Слабый или чрезмерный KDF от сервера | Отклоняется вне официальных диапазонов (PBKDF2 5 000–2 000 000 итераций; Argon2id 16–1024 МиБ, 2–10 итераций, 1–16 потоков) |
| Переустановка | iOS сохраняет элементы Keychain после удаления приложения; переустановленное приложение стирает их при первом запуске |
| Рамка «Известный IP» | Только для публичных IP: частный, CGNAT- или loopback-адрес указывает на прокси или NAT, а не на устройство |
| Сессия завершена сервером | Смена пароля или «деавторизация сессий» → экран входа; ID устройства сохраняется |
| Защита экрана | iOS: blur-оверлей в app switcher; Android: `FLAG_SECURE` блокирует скриншоты |
| Смена биометрии | Ключ инвалидируется → повторная настройка |
| Компрометация сервера | Не раскрывает UserKey |

## PIN-инструменты

Вторая вкладка, **PIN**, находится за той же биометрической блокировкой. Все инструменты работают **полностью офлайн на телефоне**: ничего из введённого там не сохраняется, не синхронизируется, не пишется в журналы и никуда не отправляется (тест следит, чтобы PIN-код не импортировал ничего, что может выйти в сеть).

| Инструмент | Что делает |
|:--|:--|
| **PIN 24** — восстановление Ledger | Только для восстановления: повторяет приложение Ledger Passwords — сид BIP39 (12/15/18/21/24 слова, необязательная passphrase) + nickname → PIN или 20-символьный пароль, который набрало бы устройство. Первые 4 буквы слова и пробел дописывают слово целиком (пока слово набирается, ничего не дописывается). Бит в бит совпадает с официальными векторами LedgerHQ; кнопка **«Проверить движок»** прогоняет их на телефоне. Nickname можно выбрать из списка: импортируйте бэкап Ledger Passwords (`.json` с passwords.ledger.com, `{"parsed": [{"nickname", "charsets"}]}`) **до** ввода сида — выбор файла уводит приложение в фон, поэтому импорт недоступен, пока сид введён или хранится в памяти. Читаются только nickname и наборы символов (не указаны — все наборы), список живёт в памяти до следующего полного стирания, выбор из списка не перетирает набранный nickname без вопроса, а маска, которую не выразить пятью переключателями (например, один `MINUS`), применяется как есть, с предупреждением. |
| **PIN Shift** | Позиционный сдвиг по модулю 10, `новый = база + вектор (mod 10)` без переноса: кодирование/декодирование, длина 1–16, разбор по цифрам, расчёт на бумаге и модель угроз. Мнемоническая обфускация, **не шифр**; кнопки копирования нет намеренно. |
| **YubiKey** | PIV PIN/PUK, OpenPGP, FIDO2, OATH и коды доступа OTP для одного или нескольких серийников — те же, что у `yk-batch-secrets.py` из yubikey-fleet: из записей Ledger Passwords, из мастер-ключа (режим derived) или случайные. Источник Ledger использует сид, введённый в PIN 24: как только фраза там верна, сид хранится в памяти вкладки (nickname не нужен), а **«Назад к YubiKey»** возвращает с сохранёнными серийниками и настройками. PIN, которые на время перехода на Ledger ещё задаются вручную (00, 23, 34), можно исключить. Значения скрыты построчно, с контрольной суммой `sha256_6`; можно скопировать одно значение или CSV `folder,name,field,value` для менеджера паролей (Bitwarden напрямую его не импортирует). Случайных значений больше нигде нет: «Очистить» и переход в другой инструмент сначала спрашивают. YAML-манифесты и прошивка через `ykman` остаются на компьютере. |
| **Legacy mask** | Архивный генератор `pass_pin` (маска из 8 цифр по строке из 20 символов) — только при включённом **«Показать устаревшие инструменты»**, чтобы восстановить созданные им PIN. Заменён PIN Shift. |

**Ledger → YubiKey: правило 4 + 4.** Карта хранит не больше 8 байт PIV PIN/PUK, поэтому это **первые 4 + последние 4 символа** того, что Ledger набирает для записей `yk-<серийник>-pins` и `yk-<серийник>-puk`; PIN User/Admin OpenPGP и FIDO2 берут всю выдачу из 20 символов (Admin — по желанию из `yk-<серийник>-admin`). Поля 25 (Reset Code) и 41 (OATH) никогда не берутся из Ledger; 45/46 — серийник, дополненный нулями до 12 цифр. Приложение предупреждает, если PIV PIN — часть другого секрета той же записи или Admin PIN делит запись `-pins`, и блокирует значения, которые не подходят карте (непечатные символы, пробелы в выборке из 8 символов).

**Безопасность**

- Секреты живут только в состоянии виджетов и автоматически освобождаемой сессии. Всё — включая общий для PIN 24 и YubiKey 64-байтовый сид — стирается кнопками **«Стереть сид»** / **«Стереть всё»**, при уходе с вкладки PIN, при уходе приложения с экрана, после 2 минут без действий и при блокировке; переход в другой инструмент очищает его поля. Стирание нельзя отменить (история отмены не переживает его), и оно закрывает открытые диалоги PIN. Строки Dart обнулить нельзя — окончательно их стирает только закрытие приложения.
- В полях секретов выключены подсказки, автокоррекция, обучение клавиатуры и автозаполнение, в меню — только «Вставить», сочетания копирования, вырезания и отмены не работают; у поля сида нет показа. Сообщения об ошибках не повторяют секретный ввод, пока не включено **«Показывать слова»** (тогда видны неверные слова и варианты); неверные серийные номера цитируются — они не секретны.
- Скрытые поля на мгновение показывают последний введённый символ — как системные поля паролей: это стандартное поведение Flutter без переключателя для отдельного поля (на Android зависит от системной настройки «Показывать пароли», iOS делает так всегда). Вставленный текст не показывается.
- После вставки приложение напоминает, что секрет всё ещё в буфере обмена; **«Стереть сид»**, **«Стереть всё»**, **«Очистить»** и уход с вкладки заодно очищают буфер (и скопированный результат, если он ещё наш).
- Android ставит `FLAG_SECURE` на вкладку PIN (тестовые сборки с `-Pallow-screenshots=true` об этом предупреждают); iOS скрывает вкладку во время записи или трансляции экрана и предупреждает после скриншота.
- Копирование идёт через нативный канал: на iOS только локально (без Универсального буфера) и с истечением; на Android клип помечен `IS_SENSITIVE` и очищается через 60 секунд, но приложения синхронизации буфера всё равно могут его скопировать. Android 13+ сам подтверждает каждое копирование, поэтому второго сообщения «Скопировано» приложение там не показывает. Вычисления выполняются в фоновом isolate.
- PIN 24 — только для восстановления: сид, введённый в телефон, доступен ОС, клавиатурам и резервным копиям — по возможности пользуйтесь настоящим Ledger.

## Крипто-цепочка

<details>
<summary><strong>Первичная настройка</strong></summary>

```
1. POST {identity}/accounts/prelogin { email }
   → { kdf, kdfIterations, kdfMemory (МиБ), kdfParallelism, salt?, kdfSettings? }

2. salt = (соль сервера ?? email).trim().toLowerCase()
   PBKDF2-SHA256(password, salt, iterations)  или
   Argon2id(password, SHA-256(salt), memory = kdfMemory × 1024 КиБ, …)
   → masterKey (32 байта)

3. HKDF-Expand-SHA256(masterKey, info="enc", 32) → stretchedEncKey
   HKDF-Expand-SHA256(masterKey, info="mac", 32) → stretchedMacKey

4. PBKDF2-SHA256(masterKey, password, 1 итерация) → masterPasswordHash

5. POST {identity}/connect/token {   # заголовки: Bitwarden-Client-Name,
                                      #   Bitwarden-Client-Version, Device-Type
     grant_type: "password", username: email,
     password: masterPasswordHash, client_id: "mobile",
     scope: "api offline_access",
     deviceType: 0|1, deviceIdentifier: uuid,
     deviceName: "VaultApprover"
   }
     (+ twoFactorProvider/twoFactorToken/twoFactorRemember, newDeviceOtp)
   → { access_token, refresh_token, TwoFactorToken?,
       UserDecryptionOptions.MasterPasswordUnlock.MasterKeyEncryptedUserKey (или Key) }

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

2. GET {api}/auth-requests/pending (Bearer token; фолбэк на /auth-requests)
   → [{ id, publicKey, requestDeviceType, requestIpAddress, creationDate, … }]
   остаются неотвеченные запросы моложе 5 минут по часам сервера
   (HTTP-заголовок Date или GET /api/now), самый новый с каждого устройства

3. Fingerprint-фраза (как в официальных клиентах):
   okm = HKDF-Expand(PRK = SHA-256(publicKey), info = lowercase(email), 32)
   n = big-endian число(okm); 5 × { слово = EFF[n mod 7776]; n = n div 7776 }

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
1. Подключение: wss://{notifications}/hub?access_token=JWT (свежий токен при каждом
   подключении; клиентский сертификат, если задан)
2. Handshake: {"protocol":"messagepack","version":1}\x1e → {}\x1e
3. Сообщения: [1, {}, null, "ReceiveMessage", [{ Type: 15, Payload: {Id, UserId} }]]
4. Keepalive: ping (type 6) каждые 15 с; LogOut (type 11) → экран входа
5. Фолбэк: polling GET /api/auth-requests
```

</details>

## Детали API

- Одобрение принимается **5 минут** с момента создания запроса (Vaultwarden; bitwarden.com — 15); записи удаляются примерно через 15 минут
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
| `app_ar.arb` | Арабский |
| `app_zh.arb`, `app_zh_Hans.arb` | Упрощённый китайский |

Генерация кода — автоматически (`generate: true` в `pubspec.yaml`).

Добавить локаль: создать `app_XX.arb` → добавить в `supportedLocales` в `lib/app.dart`.

Переключение языка в приложении: **Настройки → Язык** (Системный / English / Русский / العربية / 简体中文).

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
