/// The nickname list of a Ledger Passwords backup, for PIN 24's "choose from
/// a list" (plan C1, D2; spec pin24-ui §2.9, critic #4).
///
/// The file is what passwords.ledger.com saves on "Backup", or the superset
/// that `crypto-tools ledger-pw` keeps (`ledger_pw.py`):
///
/// ```json
/// {"key_id": "key-1", "description": "…",
///  "parsed": [{"nickname": "gmail",
///              "charsets": ["UPPERCASE", "LOWERCASE", "NUMBERS"]}]}
/// ```
///
/// Only `parsed[].nickname` and `parsed[].charsets` are read; every other key
/// is ignored. Nicknames and charsets are not secret (the device derives each
/// password from the seed), but they tell which services someone uses, so
/// the list lives only in the PIN section's memory.
///
/// Pure Dart. Nothing here logs, and no error carries file content: the UI
/// shows a fixed message per [NicknameBackupError].
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../pin_tools/ledger_pin24.dart';
import '../../pin_tools/python_text.dart' show hasLoneSurrogate;

/// Larger files are refused before they are read: a backup of the device's
/// 4 KiB of metadata is a few kilobytes of JSON.
const int kNicknameBackupMaxBytes = 1024 * 1024;

/// The device stores at most 4096 bytes of records of at least 4 bytes, so
/// no real backup has more entries; the rest of a larger list is skipped.
const int kNicknameBackupMaxEntries = 1024;

/// Charset names of the backup format and their mask bits, in the
/// canonical order of `ledger_pw.py` (`CHARSETS`).
const List<(String, int)> kLedgerCharsetNames = [
  ('UPPERCASE', kUppercase),
  ('LOWERCASE', kLowercase),
  ('NUMBERS', kNumbers),
  ('MINUS', kMinus),
  ('UNDERLINE', kUnderline),
  ('SPACE', kSpace),
  ('SPECIAL', kSpecial),
  ('BRACKETS', kBrackets),
];

/// Why a backup could not be used. Each maps to one fixed, localized message.
enum NicknameBackupError {
  /// Over [kNicknameBackupMaxBytes].
  tooLarge,

  /// Not UTF-8 JSON with a `parsed` list.
  unreadable,

  /// No usable entry.
  empty,
}

/// Thrown by [parseNicknameBackup] and the file reader. [toString] names
/// the kind only.
class NicknameBackupException implements Exception {
  const NicknameBackupException(this.error);

  final NicknameBackupError error;

  @override
  String toString() => 'NicknameBackupException(${error.name})';
}

/// One `parsed[]` entry.
class NicknameBackupEntry {
  const NicknameBackupEntry({required this.nickname, required this.mask});

  /// Exactly as stored (no trim, no normalization): it is the derivation
  /// input.
  final String nickname;

  /// Charset mask, 0x01…0xFF. [kAllSets] when the entry names none.
  final int mask;

  @override
  bool operator ==(Object other) =>
      other is NicknameBackupEntry &&
      other.nickname == nickname &&
      other.mask == mask;

  @override
  int get hashCode => Object.hash(nickname, mask);

  @override
  String toString() => 'NicknameBackupEntry(<redacted>)';
}

/// The usable entries of a backup, in file order.
class NicknameBackup {
  const NicknameBackup({required this.entries, required this.skipped});

  final List<NicknameBackupEntry> entries;

  /// Entries left out: no nickname, broken text (lone surrogates), unknown
  /// or contradictory charsets, a repeated nickname, or more than
  /// [kNicknameBackupMaxEntries].
  final int skipped;

  @override
  String toString() =>
      'NicknameBackup(${entries.length} entries, $skipped skipped)';
}

/// Charset mask of a `charsets` value, following `ledger_pw.py`:
/// missing (or `null`) means `["ALL_SETS"]` (0xFF), and so does an empty
/// list (the device's mask 0); `ALL_SETS` must stand alone; names are
/// case-sensitive and may not repeat. `null` when the value is unusable.
int? ledgerCharsetsToMask(Object? charsets) {
  if (charsets == null) return kAllSets;
  if (charsets is! List) return null;
  if (charsets.isEmpty) return kAllSets;
  if (charsets.contains('ALL_SETS')) {
    return charsets.length == 1 ? kAllSets : null;
  }
  var mask = 0;
  for (final name in charsets) {
    int? bit;
    for (final (n, b) in kLedgerCharsetNames) {
      if (n == name) bit = b;
    }
    if (bit == null || mask & bit != 0) return null;
    mask |= bit;
  }
  return mask;
}

/// Parses the bytes of a backup file. Throws [NicknameBackupException] and
/// nothing else.
NicknameBackup parseNicknameBackup(Uint8List bytes) {
  if (bytes.length > kNicknameBackupMaxBytes) {
    throw const NicknameBackupException(NicknameBackupError.tooLarge);
  }
  Object? json;
  try {
    var text = utf8.decode(bytes);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    json = jsonDecode(text);
  } catch (_) {
    // The exception text could quote the file: never passed on.
    throw const NicknameBackupException(NicknameBackupError.unreadable);
  }
  final parsed = json is Map ? json['parsed'] : null;
  if (parsed is! List) {
    throw const NicknameBackupException(NicknameBackupError.unreadable);
  }
  final entries = <NicknameBackupEntry>[];
  final seen = <String>{};
  var skipped = 0;
  for (final raw in parsed) {
    final nickname = raw is Map ? raw['nickname'] : null;
    final mask = raw is Map ? ledgerCharsetsToMask(raw['charsets']) : null;
    if (nickname is! String ||
        nickname.isEmpty ||
        hasLoneSurrogate(nickname) ||
        mask == null ||
        entries.length >= kNicknameBackupMaxEntries ||
        !seen.add(nickname)) {
      skipped++;
      continue;
    }
    entries.add(NicknameBackupEntry(nickname: nickname, mask: mask));
  }
  if (entries.isEmpty) {
    throw const NicknameBackupException(NicknameBackupError.empty);
  }
  return NicknameBackup(entries: List.unmodifiable(entries), skipped: skipped);
}

/// The exact charsets of [mask] with their characters, e.g.
/// `MINUS (-) + SPACE (␣)`. For masks the five toggles cannot show; the
/// names are the backup format's identifiers, so they are not translated.
String ledgerCharsetsLabel(int mask) => [
      for (final (i, (name, bit)) in kLedgerCharsetNames.indexed)
        if (mask & bit != 0) '$name (${_charsetSymbols[i]})',
    ].join(' + ');

/// What each charset holds, short: ranges for the letters and digits, the
/// full set otherwise (`kCharsets`, with the space shown as `␣`).
final List<String> _charsetSymbols = [
  'A-Z',
  'a-z',
  '0-9',
  for (final set in kCharsets.skip(3)) set.replaceAll(' ', '␣'),
];
