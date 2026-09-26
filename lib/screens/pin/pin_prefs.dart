import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pin24_engine.dart';

/// Non-secret preferences of the PIN tab, stored on this device only.
///
/// Deliberately separate from `SettingsService`: these keys are not part of
/// `SettingsSnapshot`, so cloud sync never sees them. No seed, passphrase,
/// nickname, PIN or password is ever stored here.
class PinPrefs {
  PinPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const kPin24Mode = 'pin.pin24.mode';
  static const kPin24Length = 'pin.pin24.length';
  static const kPin24Charsets = 'pin.pin24.charsets';
  static const kPin24BannerAck = 'pin.pin24.banner_ack';
  static const kShowLegacy = 'pin.show_legacy';

  /// Every key this class writes (for tests and a future "reset" action).
  static const allKeys = [
    kPin24Mode,
    kPin24Length,
    kPin24Charsets,
    kPin24BannerAck,
    kShowLegacy,
  ];

  Pin24Mode get pin24Mode => _prefs.getString(kPin24Mode) == 'password'
      ? Pin24Mode.password
      : Pin24Mode.pin;

  Future<void> setPin24Mode(Pin24Mode mode) =>
      _prefs.setString(kPin24Mode, mode.name);

  /// Stored length, clamped into 1…12 (a hand-edited or older value can be
  /// out of range).
  int get pin24Length =>
      clampPin24Length(_prefs.getInt(kPin24Length) ?? kPin24DefaultLength);

  Future<void> setPin24Length(int length) =>
      _prefs.setInt(kPin24Length, clampPin24Length(length));

  /// Stored charset toggles; the device default when nothing is stored.
  Set<Pin24Charset> get pin24Charsets {
    final bits = _prefs.getInt(kPin24Charsets);
    if (bits == null) return {...kPin24DefaultCharsets};
    return {
      for (final c in Pin24Charset.values)
        if (bits & (1 << c.index) != 0) c,
    };
  }

  Future<void> setPin24Charsets(Set<Pin24Charset> charsets) => _prefs.setInt(
        kPin24Charsets,
        charsets.fold<int>(0, (bits, c) => bits | (1 << c.index)),
      );

  /// Whether the recovery-only banner was acknowledged once.
  bool get pin24BannerAcknowledged => _prefs.getBool(kPin24BannerAck) ?? false;

  Future<void> setPin24BannerAcknowledged() =>
      _prefs.setBool(kPin24BannerAck, true);

  bool get showLegacyTools => _prefs.getBool(kShowLegacy) ?? false;

  Future<void> setShowLegacyTools(bool show) =>
      _prefs.setBool(kShowLegacy, show);
}

/// Loaded once; `SharedPreferences.getInstance()` is already warm because
/// `main()` loaded the settings store.
final pinPrefsProvider = FutureProvider<PinPrefs>(
  (ref) async => PinPrefs(await SharedPreferences.getInstance()),
);
