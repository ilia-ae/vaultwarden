/// YubiKey PINs from Ledger Passwords, per yubikey-fleet `docs/BITWARDEN.md`
/// ("Откуда берётся каждое значение", operator decisions 2026-08-30).
///
/// For a key with serial S the operator keeps up to three Ledger Passwords
/// entries, whose names are the derivation input:
///
/// | Entry         | Fields                                                |
/// |---------------|-------------------------------------------------------|
/// | `yk-S-pins`   | 00 PIV PIN (first 4 + last 4 characters), 23 OpenPGP  |
/// |               | User PIN, 34 FIDO2 PIN, 24 Admin PIN (whole output)   |
/// | `yk-S-puk`    | 14 PIV PUK (first 4 + last 4 characters)              |
/// | `yk-S-admin`  | 24 Admin PIN (whole output), only if the operator     |
/// |               | moves it out of the shared `-pins` entry              |
///
/// Each output is `derivePassword(bip39Seed:, nickname: entry, setMask:)`
/// with the device defaults (20 characters, minimum-per-set 1/1/1/0/0/1/0/0),
/// i.e. exactly what the device types for that entry. PIV PIN and PUK take
/// 4 + 4 characters because the card stores at most 8 bytes; the other PINs
/// take the whole output. Fields 25 (Reset Code) and 41 (OATH) never come
/// from Ledger, 45/46 come from the serial; [ykResolveKeyWithLedger] fills
/// them the script's way.
///
/// Values are validated against the card limits, not the fleet policy of
/// [ykFields] (see [ykHardwareLimits] / [ykValidateLedgerValue]), plus the
/// two BITWARDEN.md conditions: (1) the 8 picked characters are printable
/// ASCII without space, (2) a warning when the PIV PIN is part of another
/// secret from the same entry. Validation never throws: problems and
/// warnings are reported per field in [YkLedgerResult].
///
/// Pure Dart; run it in `Isolate.run` together with `bip39ToSeed`. Results
/// hold plaintext secrets: [YkLedgerResult.toString] redacts them.
library;

import 'dart:typed_data';

import 'ledger_pin24.dart';
import 'python_text.dart';
import 'yubikey_secrets.dart';

/// UPPERCASE | LOWERCASE | NUMBERS: letters and digits, the default mask for
/// the YubiKey entries (no separators or special characters, so every value
/// can be typed on any layout and exported to CSV).
const int ykLedgerDefaultMask = kUppercase | kLowercase | kNumbers;

/// Field numbers Ledger Passwords may fill, in number order.
const List<String> ykLedgerFields = ['00', '14', '23', '24', '34'];

/// The Ledger Passwords entries of one key.
enum YkLedgerEntry {
  /// `yk-<serial>-pins`: PIV PIN (4 + 4), OpenPGP User, FIDO2 and, unless
  /// separated, Admin PIN.
  pins,

  /// `yk-<serial>-puk`: PIV PUK (4 + 4).
  puk,

  /// `yk-<serial>-admin`: the OpenPGP Admin PIN when the operator keeps it
  /// out of the shared `-pins` entry.
  admin;

  /// The entry name (nickname) to create on the device for [serial], e.g.
  /// `yk-38715242-pins`. [serial] is used as given, after
  /// [ykLedgerSerial].
  String nickname(String serial) => 'yk-${ykLedgerSerial(serial)}-$name';
}

/// The serial as it goes into entry names: Python `str.strip()`, otherwise
/// verbatim (`"00012345"` stays `"00012345"`, like the fleet script's
/// serials). Throws [YkException] `SERIAL_INVALID` if it is empty or has an
/// unpaired surrogate (it could not be typed or UTF-8 encoded).
String ykLedgerSerial(String serial) {
  final s = pythonStrip(serial);
  if (s.isEmpty) {
    throw const YkException(YkException.serialInvalid, 'serial is empty');
  }
  if (hasLoneSurrogate(s)) {
    throw const YkException(
      YkException.serialInvalid,
      'serial contains an unpaired UTF-16 surrogate',
    );
  }
  return s;
}

/// Which entry each field is taken from.
YkLedgerEntry ykLedgerEntryFor(String field, {bool separateAdmin = false}) =>
    switch (field) {
      '00' || '23' || '34' => YkLedgerEntry.pins,
      '14' => YkLedgerEntry.puk,
      '24' => separateAdmin ? YkLedgerEntry.admin : YkLedgerEntry.pins,
      _ => throw ArgumentError.value(
          field, 'field', 'is not a field Ledger Passwords may fill'),
    };

/// First 4 + last 4 characters of a Ledger output: the 8-byte PIV pick.
String ykLedgerPick8(String output) {
  if (output.length < 8) {
    throw ArgumentError.value(
        output.length, 'output.length', 'must be at least 8');
  }
  return output.substring(0, 4) + output.substring(output.length - 4);
}

/// Advisory findings; they do not block setting or exporting a value.
enum YkLedgerWarningKind {
  /// BITWARDEN.md condition 2: the PIV PIN (field 00) is part of another
  /// secret in this result ([YkLedgerWarning.otherField]); either its first
  /// 4 + last 4 characters or a plain substring. Typing the PIV PIN often
  /// then exposes 8 characters of the longer PIN. Accept it consciously or
  /// take that PIN from another entry.
  pivPinPartOfOtherSecret,

  /// The OpenPGP Admin PIN (field 24) comes from the shared `-pins` entry,
  /// so it is the same password as the User and FIDO2 PINs that are typed
  /// daily. BITWARDEN.md: move it to `yk-<serial>-admin` if that is not
  /// acceptable (`separateAdmin: true`).
  adminSharesPinsEntry,
}

/// One advisory finding for [field]. Never holds a secret value.
class YkLedgerWarning {
  final YkLedgerWarningKind kind;
  final String field;

  /// The other field involved ([YkLedgerWarningKind.pivPinPartOfOtherSecret]).
  final String? otherField;

  const YkLedgerWarning({
    required this.kind,
    required this.field,
    this.otherField,
  });

  /// English description (no value echoed).
  String get message => switch (kind) {
        YkLedgerWarningKind.pivPinPartOfOtherSecret =>
          'field $field (${ykFields[field]!.name}) is part of field '
              '$otherField (${ykFields[otherField]!.name}) from the same '
              'Ledger entry: typing it exposes characters of that PIN',
        YkLedgerWarningKind.adminSharesPinsEntry =>
          'field $field (${ykFields[field]!.name}) shares the -pins entry '
              'with the everyday PINs',
      };

  @override
  String toString() => message;
}

/// Result of [ykFromLedger]. Holds plaintext secrets ([values],
/// [outputs]); [toString] redacts them.
class YkLedgerResult {
  const YkLedgerResult({
    required this.serial,
    required this.setMask,
    required this.separateAdmin,
    required this.entries,
    required this.outputs,
    required this.values,
    required this.problems,
    required this.warnings,
  });

  /// Stripped serial ([ykLedgerSerial]).
  final String serial;
  final int setMask;
  final bool separateAdmin;

  /// Field → entry name it was derived from, e.g. `'14': 'yk-S-puk'`.
  final Map<String, String> entries;

  /// Entry name → the full 20-character output the device types for it, to
  /// cross-check on the Ledger. Only entries some requested field needs.
  final Map<String, String> outputs;

  /// Field → value to set on the card, for the requested fields in number
  /// order.
  final Map<String, String> values;

  /// Field → blocking problems ([ykValidateLedgerValue]); every requested
  /// field has a (possibly empty) list.
  final Map<String, List<YkLedgerProblem>> problems;

  /// Field → advisory warnings; every requested field has a (possibly
  /// empty) list.
  final Map<String, List<YkLedgerWarning>> warnings;

  /// No field has a blocking problem: every value can be set and exported.
  bool get isValid => problems.values.every((p) => p.isEmpty);

  bool get hasWarnings => warnings.values.any((w) => w.isNotEmpty);

  /// The entries the operator must have on the device, in order.
  List<String> get entryNames => outputs.keys.toList(growable: false);

  @override
  String toString() => 'YkLedgerResult($serial, mask 0x'
      '${setMask.toRadixString(16).padLeft(2, '0')}, '
      'fields: ${values.keys.join(',')}, <redacted>)';
}

/// Derives the YubiKey PINs of key [serial] from Ledger Passwords.
///
/// [bip39Seed] is the 64-byte BIP39 seed (`bip39ToSeed(mnemonic, passphrase:
/// …)`), computed once and reused for every serial; it is not modified.
/// [setMask] is the Ledger charset mask the entries were created with
/// (default [ykLedgerDefaultMask]; any 1..255). [separateAdmin] takes field
/// 24 from `yk-S-admin` instead of `yk-S-pins`. [fields] selects which of
/// [ykLedgerFields] to fill (e.g. only 14 while the PIV PIN is still set by
/// hand); only the entries they need are derived.
///
/// Never throws for values that do not fit: see [YkLedgerResult.problems]
/// and [YkLedgerResult.warnings]. Throws [YkException] `SERIAL_INVALID` for
/// an unusable serial, [Pin24Exception] for a seed that is not 64 bytes
/// (`SEED_LENGTH`) or a mask outside 1..255 (`SET_MASK_RANGE`), and
/// [ArgumentError] for a field Ledger may not fill.
YkLedgerResult ykFromLedger({
  required Uint8List bip39Seed,
  required String serial,
  int setMask = ykLedgerDefaultMask,
  bool separateAdmin = false,
  Set<String> fields = const {'00', '14', '23', '24', '34'},
}) {
  final s = ykLedgerSerial(serial);
  final requested = [
    for (final f in ykLedgerFields)
      if (fields.contains(f)) f,
  ];
  for (final f in fields) {
    if (!ykLedgerFields.contains(f)) {
      throw ArgumentError.value(
          f, 'fields', 'is not a field Ledger Passwords may fill');
    }
  }

  final entries = <String, String>{
    for (final f in requested)
      f: ykLedgerEntryFor(f, separateAdmin: separateAdmin).nickname(s),
  };
  final outputs = <String, String>{};
  for (final entry in YkLedgerEntry.values) {
    final name = entry.nickname(s);
    if (!entries.containsValue(name)) continue;
    outputs[name] = derivePassword(
      bip39Seed: bip39Seed,
      nickname: name,
      setMask: setMask,
    );
  }

  final values = <String, String>{
    for (final f in requested)
      f: f == '00' || f == '14'
          ? ykLedgerPick8(outputs[entries[f]]!)
          : outputs[entries[f]]!,
  };

  final warnings = <String, List<YkLedgerWarning>>{
    for (final f in requested) f: <YkLedgerWarning>[],
  };
  final pin = values['00'];
  if (pin != null) {
    for (final other in requested) {
      if (other == '00') continue;
      final v = values[other]!;
      final pick = v.length >= 8 && ykLedgerPick8(v) == pin;
      if (pick || v.contains(pin)) {
        warnings['00']!.add(YkLedgerWarning(
          kind: YkLedgerWarningKind.pivPinPartOfOtherSecret,
          field: '00',
          otherField: other,
        ));
      }
    }
  }
  if (values.containsKey('24') && !separateAdmin) {
    warnings['24']!.add(const YkLedgerWarning(
      kind: YkLedgerWarningKind.adminSharesPinsEntry,
      field: '24',
    ));
  }

  return YkLedgerResult(
    serial: s,
    setMask: setMask,
    separateAdmin: separateAdmin,
    entries: Map.unmodifiable(entries),
    outputs: Map.unmodifiable(outputs),
    values: Map.unmodifiable(values),
    problems: Map.unmodifiable({
      for (final f in requested)
        f: List<YkLedgerProblem>.unmodifiable(
            ykValidateLedgerValue(f, values[f]!)),
    }),
    warnings: Map.unmodifiable({
      for (final e in warnings.entries)
        e.key: List<YkLedgerWarning>.unmodifiable(e.value),
    }),
  );
}

/// [ykResolveKey] for a key whose PINs come from Ledger: the fields in
/// [ledger] that [phases] need take the Ledger values (over [manual]); every
/// other field resolves the script's way. Field 25 and 41 come from [mode]
/// (derived from [master], or random) or [manual]; 45/46 from the serial
/// when [otpFromSerial] (the BITWARDEN.md default, hence `true` here).
///
/// The result lists those fields in [YkKeySecrets.ledgerFields], so
/// [ykBitwardenCsv] validates them against the card limits. Check
/// [YkLedgerResult.isValid] first to show problems per field; the export
/// refuses them anyway (`VALUE_INVALID`).
YkKeySecrets ykResolveKeyWithLedger({
  required YkLedgerResult ledger,
  required Set<YkPhase> phases,
  required YkMode mode,
  Uint8List? master,
  bool otpFromSerial = true,
  Map<String, String> manual = const {},
  YkNextInt? nextIntForTest,
}) {
  final needed = ykNeededFields(phases);
  final fromLedger = {
    for (final f in needed)
      if (ledger.values.containsKey(f)) f,
  };
  final k = ykResolveKey(
    serial: ledger.serial,
    phases: phases,
    mode: mode,
    master: master,
    otpFromSerial: otpFromSerial,
    manual: {
      ...manual,
      for (final f in fromLedger) f: ledger.values[f]!,
    },
    nextIntForTest: nextIntForTest,
  );
  return YkKeySecrets(
    serial: k.serial,
    values: k.values,
    ledgerFields: Set.unmodifiable(fromLedger),
  );
}
