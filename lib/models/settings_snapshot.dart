/// An immutable, serialisable view of the user's synced settings.
///
/// This is the wire format for cloud sync: it maps 1:1 to the Firestore
/// document at `users/{uid}` and to the local providers (theme, locale,
/// lock timeout, poll interval). Only non-sensitive preferences — never
/// keys or tokens.
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.themeMode,
    required this.locale,
    required this.lockTimeout,
    required this.pollInterval,
  });

  /// 'system' | 'light' | 'dark'
  final String themeMode;

  /// BCP-47 language tag (e.g. 'en', 'ru', 'zh-Hans'); null = follow system.
  final String? locale;

  /// Seconds; 0 = immediate, -1 = never.
  final int lockTimeout;

  /// Seconds between auth-request polls.
  final int pollInterval;

  Map<String, dynamic> toMap() => {
        'themeMode': themeMode,
        'locale': locale,
        'lockTimeout': lockTimeout,
        'pollInterval': pollInterval,
      };

  factory SettingsSnapshot.fromMap(Map<String, dynamic> m) => SettingsSnapshot(
        themeMode: (m['themeMode'] as String?) ?? 'system',
        locale: m['locale'] as String?,
        lockTimeout: (m['lockTimeout'] as num?)?.toInt() ?? 0,
        pollInterval: (m['pollInterval'] as num?)?.toInt() ?? 15,
      );

  @override
  bool operator ==(Object other) =>
      other is SettingsSnapshot &&
      other.themeMode == themeMode &&
      other.locale == locale &&
      other.lockTimeout == lockTimeout &&
      other.pollInterval == pollInterval;

  @override
  int get hashCode =>
      Object.hash(themeMode, locale, lockTimeout, pollInterval);
}
