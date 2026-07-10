import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists user-facing settings locally so they survive app restarts.
///
/// Only non-sensitive preferences live here (theme, language, lock timeout,
/// poll interval) — never keys or tokens, which stay in secure storage.
/// This is also the local source of truth that the optional Firebase cloud
/// sync (see cloud sync layer) reads from and writes back to.
class SettingsService {
  SettingsService(this._prefs);

  final SharedPreferences _prefs;

  static const _kThemeMode = 'settings.theme_mode';
  static const _kLocale = 'settings.locale';
  static const _kLockTimeout = 'settings.lock_timeout';
  static const _kPollInterval = 'settings.poll_interval';

  /// Loads the backing store. Call once during app startup.
  static Future<SettingsService> create() async =>
      SettingsService(await SharedPreferences.getInstance());

  // ── Theme ──

  ThemeMode get themeMode {
    switch (_prefs.getString(_kThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _prefs.setString(_kThemeMode, mode.name);

  // ── Locale (null = follow system) ──

  Locale? get locale {
    final tag = _prefs.getString(_kLocale);
    if (tag == null || tag.isEmpty) return null;
    return _decodeLocale(tag);
  }

  Future<void> setLocale(Locale? locale) => locale == null
      ? _prefs.remove(_kLocale)
      : _prefs.setString(_kLocale, locale.toLanguageTag());

  // ── Lock timeout (seconds; 0 = immediate, -1 = never) ──

  int? get lockTimeout =>
      _prefs.containsKey(_kLockTimeout) ? _prefs.getInt(_kLockTimeout) : null;

  Future<void> setLockTimeout(int seconds) =>
      _prefs.setInt(_kLockTimeout, seconds);

  // ── Poll interval (seconds) ──

  int? get pollInterval =>
      _prefs.containsKey(_kPollInterval) ? _prefs.getInt(_kPollInterval) : null;

  Future<void> setPollInterval(int seconds) =>
      _prefs.setInt(_kPollInterval, seconds);
}

/// Decodes a BCP-47 tag (produced by [Locale.toLanguageTag]) back into a
/// [Locale], distinguishing 4-letter script subtags (Hans/Hant) from
/// 2-letter region codes so `zh-Hans` round-trips exactly.
Locale? _decodeLocale(String tag) {
  final parts = tag.split('-');
  if (parts.length == 1) return Locale(parts[0]);
  final second = parts[1];
  if (second.length == 4) {
    return Locale.fromSubtags(languageCode: parts[0], scriptCode: second);
  }
  return Locale(parts[0], second);
}
