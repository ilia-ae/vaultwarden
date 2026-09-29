/// Lock-timeout choices the app offers (seconds; 0 = immediately,
/// -1 = never). Keep in sync with `firestore.rules`.
const kLockTimeoutOptions = [0, 15, 60, 300, 900, -1];

/// "Never lock" — a per-device choice that is never synced (A15).
const kLockTimeoutNever = -1;

/// Poll-interval choices the app offers (seconds). Keep in sync with
/// `firestore.rules`.
const kPollIntervalOptions = [5, 15, 30, 60];

/// Bounds for any poll interval that reaches a timer (R2): a 0 or negative
/// value would poll the server in a tight loop.
const kMinPollIntervalSeconds = 5;
const kMaxPollIntervalSeconds = 3600;
const kDefaultPollIntervalSeconds = 15;

/// Clamps a poll interval to [kMinPollIntervalSeconds]..
/// [kMaxPollIntervalSeconds]; null / non-numeric → the default.
int sanitizePollInterval(Object? seconds) {
  if (seconds is! num || seconds.isNaN) return kDefaultPollIntervalSeconds;
  return seconds
      .clamp(kMinPollIntervalSeconds, kMaxPollIntervalSeconds)
      .toInt();
}

/// A lock timeout from [kLockTimeoutOptions]; anything else (corrupt pref,
/// unknown value) becomes 0 — lock immediately, the safe choice.
int sanitizeLockTimeout(Object? seconds) {
  if (seconds is num && seconds == seconds.roundToDouble()) {
    final value = seconds.toInt();
    if (kLockTimeoutOptions.contains(value)) return value;
  }
  return 0;
}

/// A lock timeout that may be synced: one of [kLockTimeoutOptions] except
/// "never"; null for anything else.
int? syncedLockTimeout(Object? seconds) {
  if (seconds is! num || seconds != seconds.roundToDouble()) return null;
  final value = seconds.toInt();
  if (value == kLockTimeoutNever) return null;
  return kLockTimeoutOptions.contains(value) ? value : null;
}

/// An immutable, serialisable view of the user's synced settings.
///
/// This is the wire format for cloud sync: it maps 1:1 to the Firestore
/// document at `users/{uid}` and to the local providers (theme, locale,
/// lock timeout, poll interval). Only non-sensitive preferences — never
/// keys or tokens.
///
/// Values are validated on the way in ([SettingsSnapshot.fromMap]): an
/// unknown theme becomes 'system', the poll interval is clamped to ≥ 5 s,
/// and a lock timeout outside the synced set (including "never") is
/// dropped, so a remote document can never make the app poll in a tight
/// loop or stop locking.
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.themeMode,
    required this.locale,
    required this.lockTimeout,
    required this.pollInterval,
  });

  static const themeModes = ['system', 'light', 'dark'];

  /// 'system' | 'light' | 'dark'
  final String themeMode;

  /// BCP-47 language tag (e.g. 'en', 'ru', 'zh-Hans'); null = follow system.
  final String? locale;

  /// Seconds, one of [kLockTimeoutOptions] except "never". Null = not synced:
  /// the local choice is "never" (a per-device setting, A15), or the remote
  /// value is missing/unknown/"never" (never applied).
  final int? lockTimeout;

  /// Seconds between auth-request polls (≥ [kMinPollIntervalSeconds]).
  final int pollInterval;

  /// Omits `lockTimeout` when it is not synced: with a merge write the
  /// document keeps the value other devices synced.
  Map<String, dynamic> toMap() => {
        'themeMode': themeMode,
        'locale': locale,
        if (lockTimeout != null) 'lockTimeout': lockTimeout,
        'pollInterval': pollInterval,
      };

  factory SettingsSnapshot.fromMap(Map<String, dynamic> m) {
    final theme = m['themeMode'];
    final locale = m['locale'];
    return SettingsSnapshot(
      themeMode:
          theme is String && themeModes.contains(theme) ? theme : 'system',
      locale: locale is String && locale.isNotEmpty ? locale : null,
      lockTimeout: syncedLockTimeout(m['lockTimeout']),
      pollInterval: sanitizePollInterval(m['pollInterval']),
    );
  }

  /// Same values as far as sync is concerned: a lock timeout that is not
  /// synced on either side does not count as a difference.
  bool sameSyncedValues(SettingsSnapshot other) =>
      themeMode == other.themeMode &&
      locale == other.locale &&
      pollInterval == other.pollInterval &&
      (lockTimeout == null ||
          other.lockTimeout == null ||
          lockTimeout == other.lockTimeout);

  @override
  bool operator ==(Object other) =>
      other is SettingsSnapshot &&
      other.themeMode == themeMode &&
      other.locale == locale &&
      other.lockTimeout == lockTimeout &&
      other.pollInterval == pollInterval;

  @override
  int get hashCode => Object.hash(themeMode, locale, lockTimeout, pollInterval);

  @override
  String toString() => 'SettingsSnapshot($themeMode, $locale, '
      'lock: $lockTimeout, poll: $pollInterval)';
}
