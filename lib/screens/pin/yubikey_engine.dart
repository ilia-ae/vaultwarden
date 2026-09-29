/// Off-UI computation for the YubiKey tool: parses the serial list and
/// resolves every needed field of every key from Ledger Passwords, a master
/// key or the secure random generator, through the ported cores
/// (`yubikey_secrets.dart`, `yubikey_ledger.dart`).
///
/// Pure Dart (no Flutter imports): [ykCompute] runs inside `Isolate.run`.
/// It never throws; failures come back as codes, never as messages that
/// could quote a secret. Requests and responses redact themselves in
/// `toString`.
library;

import 'dart:typed_data';

import '../../pin_tools/ledger_pin24.dart' show Pin24Exception;
import '../../pin_tools/yubikey_ledger.dart';
import '../../pin_tools/yubikey_secrets.dart';
import 'pin24_engine.dart'
    show Pin24Charset, PinComputeRunner, kPin24DefaultCharsets;

/// Where the values come from.
enum YkSource { ledger, master, random }

/// Where one value came from.
enum YkOrigin { ledger, derived, random, serial }

/// Most serials handled at once (the list is typed on a phone).
const int kYkMaxSerials = 32;

/// Longest serial whose OTP access code still fits 12 digits.
const int kYkOtpSerialDigits = 12;

/// Ledger fields an operator may still set by hand during the transition to
/// Ledger (yubikey-fleet `docs/BITWARDEN.md`, source table: "by hand → later
/// Ledger" for 00, 23 and 34).
const List<String> kYkHandSettableFields = ['00', '23', '34'];

/// The YubiKey tool's non-secret settings. They live in the PIN session, so
/// switching to another tool and back keeps them; they never hold a secret
/// (serial numbers are public: they are the item's username).
class YkSettings {
  YkSource source = YkSource.ledger;
  final Set<YkPhase> phases = {...YkPhase.values};
  bool otpFromSerial = true;
  Set<Pin24Charset> mask = {...kPin24DefaultCharsets};
  bool separateAdmin = false;
  YkMode ledgerRest = YkMode.random;

  /// Ledger fields the operator still sets by hand ([kYkHandSettableFields]):
  /// not derived, not shown, not in the CSV.
  final Set<String> handSet = {};

  /// The serial-number field as typed.
  String serials = '';

  @override
  String toString() => 'YkSettings(${source.name})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Serial list
// ─────────────────────────────────────────────────────────────────────────────

/// The serial field, parsed. Serials are public (they are the item's
/// username), so the lists may be shown as typed.
class YkSerialList {
  const YkSerialList({
    required this.serials,
    required this.invalid,
    required this.duplicates,
    required this.leadingZero,
    required this.tooLongForOtp,
    required this.tooMany,
  });

  /// Valid serials in first-seen order, duplicates removed, capped at
  /// [kYkMaxSerials].
  final List<String> serials;

  /// Tokens that are not ASCII digits only.
  final List<String> invalid;

  /// Serials that appeared more than once (listed once each).
  final List<String> duplicates;

  /// Serials with a leading zero: used verbatim, so `0012389` ≠ `12389`.
  final List<String> leadingZero;

  /// Serials longer than [kYkOtpSerialDigits] digits.
  final List<String> tooLongForOtp;

  /// More than [kYkMaxSerials] distinct serials were given.
  final bool tooMany;

  bool get isEmpty => serials.isEmpty && invalid.isEmpty;
}

final RegExp _serialSeparators = RegExp(r'[\s,;]+');

bool _asciiDigits(String s) =>
    s.isNotEmpty && s.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

/// Splits [text] on commas, semicolons, spaces and line breaks. Each token
/// must be ASCII `0`–`9` only; duplicates are dropped (first one wins).
YkSerialList ykParseSerials(String text) {
  final serials = <String>[];
  final seen = <String>{};
  final invalid = <String>[];
  final duplicates = <String>[];
  var tooMany = false;
  for (final token in text.split(_serialSeparators)) {
    if (token.isEmpty) continue;
    if (!_asciiDigits(token)) {
      if (!invalid.contains(token)) invalid.add(token);
      continue;
    }
    if (!seen.add(token)) {
      if (!duplicates.contains(token)) duplicates.add(token);
      continue;
    }
    if (serials.length == kYkMaxSerials) {
      tooMany = true;
      continue;
    }
    serials.add(token);
  }
  return YkSerialList(
    serials: serials,
    invalid: invalid,
    duplicates: duplicates,
    leadingZero: [
      for (final s in serials)
        if (s.length > 1 && s.startsWith('0')) s,
    ],
    tooLongForOtp: [
      for (final s in serials)
        if (s.length > kYkOtpSerialDigits) s,
    ],
    tooMany: tooMany,
  );
}

/// Number of bytes the master key has after the script's `bytes.strip()`
/// (ASCII space, tab, LF, CR, VT, FF at both ends). [bytes] is not changed.
int ykStrippedLength(List<int> bytes) {
  bool space(int b) =>
      b == 0x20 ||
      b == 0x09 ||
      b == 0x0A ||
      b == 0x0D ||
      b == 0x0B ||
      b == 0x0C;
  var start = 0;
  var end = bytes.length;
  while (start < end && space(bytes[start])) {
    start++;
  }
  while (end > start && space(bytes[end - 1])) {
    end--;
  }
  return end - start;
}

// ─────────────────────────────────────────────────────────────────────────────
// Request / response
// ─────────────────────────────────────────────────────────────────────────────

/// Top-level failure codes of [ykCompute] (per-key codes are the cores'
/// [YkException] / [Pin24Exception] codes).
class YkComputeError {
  static const noSeed = 'NO_SEED';
  static const masterMissing = 'MASTER_MISSING';
  static const masterTooShort = YkException.masterTooShort;
  static const unexpected = 'UNEXPECTED';
}

/// Everything one computation needs; only sendable fields.
class YkRequest {
  const YkRequest({
    required this.source,
    required this.serials,
    required this.phases,
    required this.otpFromSerial,
    this.masterBytes,
    this.seed,
    this.setMask = ykLedgerDefaultMask,
    this.separateAdmin = false,
    this.ledgerRest = YkMode.random,
    this.randomValues = const {},
    this.handSet = const {},
  });

  final YkSource source;
  final List<String> serials;
  final Set<YkPhase> phases;

  /// Fields 45/46 from the serial (always on for [YkSource.ledger]).
  final bool otpFromSerial;

  /// UTF-8 bytes of the pasted master key, not yet stripped. Private copy:
  /// [ykCompute] zeroes it.
  final Uint8List? masterBytes;

  /// Private copy of the cached 64-byte BIP39 seed; [ykCompute] zeroes it.
  final Uint8List? seed;

  /// Ledger Passwords charset mask of the `yk-<serial>-*` entries.
  final int setMask;
  final bool separateAdmin;

  /// Ledger source: how fields Ledger never fills (25, 41) are made.
  final YkMode ledgerRest;

  /// Serial → field → random value generated earlier. Reused so random
  /// values stay stable until the user regenerates them.
  final Map<String, Map<String, String>> randomValues;

  /// Ledger source: fields of [kYkHandSettableFields] the operator still
  /// sets by hand. They are neither derived nor generated, and they are
  /// left out of the result (and so of the CSV).
  final Set<String> handSet;

  @override
  String toString() => 'YkRequest(<redacted>)';
}

/// All values of one key, with their origin, checks and checksums. Holds
/// plaintext secrets; [toString] redacts them.
class YkKeyResult {
  const YkKeyResult({
    required this.serial,
    this.values = const {},
    this.ledgerFields = const {},
    this.origins = const {},
    this.valueProblems = const {},
    this.ledgerProblems = const {},
    this.warnings = const {},
    this.sha256Prefix = const {},
    this.entryNames = const [],
    this.handSetFields = const [],
    this.errorCode,
  });

  final String serial;

  /// Field → value, in field order.
  final Map<String, String> values;

  /// Fields whose value came from Ledger (validated by card limits).
  final Set<String> ledgerFields;
  final Map<String, YkOrigin> origins;

  /// `--check` problems of script-made values (fleet FIELDS policy).
  final Map<String, List<YkValueProblem>> valueProblems;

  /// Card-limit / BITWARDEN.md problems of Ledger values.
  final Map<String, List<YkLedgerProblem>> ledgerProblems;
  final Map<String, List<YkLedgerWarning>> warnings;

  /// Field → first 6 hex characters of SHA-256 (operator checksum).
  final Map<String, String> sha256Prefix;

  /// Ledger entries the operator needs on the device, e.g.
  /// `yk-38715242-pins`.
  final List<String> entryNames;

  /// Needed fields the operator sets by hand ([YkRequest.handSet]): they
  /// have no value here and are not in the CSV.
  final List<String> handSetFields;

  /// Set when this key could not be computed.
  final String? errorCode;

  bool get hasProblems =>
      valueProblems.values.any((p) => p.isNotEmpty) ||
      ledgerProblems.values.any((p) => p.isNotEmpty);

  /// The input of [ykBitwardenCsv] for this key.
  YkKeySecrets get secrets =>
      YkKeySecrets(serial: serial, values: values, ledgerFields: ledgerFields);

  @override
  String toString() => 'YkKeyResult($serial, <redacted>)';
}

/// Result of [ykCompute].
class YkResponse {
  const YkResponse({this.keys = const [], this.errorCode});

  final List<YkKeyResult> keys;

  /// A [YkComputeError] code when nothing could be computed.
  final String? errorCode;

  @override
  String toString() => 'YkResponse(${keys.length} key(s), <redacted>)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Compute
// ─────────────────────────────────────────────────────────────────────────────

bool _otpField(String f) => f == '45' || f == '46';

/// Whether the Ledger source needs [YkRequest.ledgerRest] at all: some
/// needed field is neither a Ledger field nor an OTP code from the serial.
bool ykLedgerNeedsRest(Set<YkPhase> phases, {required bool otpFromSerial}) =>
    ykNeededFields(phases).any(
        (f) => !ykLedgerFields.contains(f) && !(otpFromSerial && _otpField(f)));

/// Resolves every key of [r]. Never throws; zeroes [YkRequest.masterBytes]
/// and [YkRequest.seed] (and the normalized master) before returning.
YkResponse ykCompute(YkRequest r) {
  Uint8List? master;
  try {
    final otp = r.otpFromSerial || r.source == YkSource.ledger;
    final needsMaster = r.source == YkSource.master ||
        (r.source == YkSource.ledger &&
            r.ledgerRest == YkMode.derived &&
            ykLedgerNeedsRest(r.phases, otpFromSerial: otp));
    if (r.source == YkSource.ledger && r.seed == null) {
      return const YkResponse(errorCode: YkComputeError.noSeed);
    }
    if (needsMaster) {
      final raw = r.masterBytes;
      if (raw == null || ykStrippedLength(raw) == 0) {
        return const YkResponse(errorCode: YkComputeError.masterMissing);
      }
      try {
        master = ykNormalizeMasterKey(raw);
      } on YkException catch (e) {
        return YkResponse(errorCode: e.code);
      }
    }
    return YkResponse(keys: [
      for (final serial in r.serials) _computeKey(r, serial, master, otp),
    ]);
  } catch (_) {
    // Deliberately no message: it could carry input.
    return const YkResponse(errorCode: YkComputeError.unexpected);
  } finally {
    master?.fillRange(0, master.length, 0);
    final raw = r.masterBytes;
    raw?.fillRange(0, raw.length, 0);
    final seed = r.seed;
    seed?.fillRange(0, seed.length, 0);
  }
}

YkKeyResult _computeKey(
    YkRequest r, String serial, Uint8List? master, bool otp) {
  // Hand-set fields apply to the Ledger source only.
  final handSet = r.source == YkSource.ledger
      ? {
          for (final f in r.handSet)
            if (kYkHandSettableFields.contains(f)) f,
        }
      : const <String>{};
  try {
    YkLedgerResult? ledger;
    YkKeySecrets secrets;
    YkMode mode;
    switch (r.source) {
      case YkSource.ledger:
        final needed = ykNeededFields(r.phases);
        ledger = ykFromLedger(
          bip39Seed: r.seed!,
          serial: serial,
          setMask: r.setMask,
          separateAdmin: r.separateAdmin,
          fields: {
            for (final f in needed)
              if (ykLedgerFields.contains(f) && !handSet.contains(f)) f,
          },
        );
        mode = ykLedgerNeedsRest(r.phases, otpFromSerial: otp)
            ? r.ledgerRest
            : YkMode.random; // nothing is generated in this case
        secrets = ykResolveKeyWithLedger(
          ledger: ledger,
          phases: r.phases,
          mode: mode,
          master: mode == YkMode.derived ? master : null,
          otpFromSerial: otp,
          manual: mode == YkMode.random
              ? (r.randomValues[serial] ?? const {})
              : const {},
        );
      case YkSource.master:
        mode = YkMode.derived;
        secrets = ykResolveKey(
          serial: serial,
          phases: r.phases,
          mode: YkMode.derived,
          master: master,
          otpFromSerial: otp,
        );
      case YkSource.random:
        mode = YkMode.random;
        secrets = ykResolveKey(
          serial: serial,
          phases: r.phases,
          mode: YkMode.random,
          otpFromSerial: otp,
          manual: r.randomValues[serial] ?? const {},
        );
    }

    // ykResolveKey fills every needed field; the ones set by hand are dropped
    // before anything is shown, checked or exported.
    final needed = ykNeededFields(r.phases);
    final handSetFields = [
      for (final f in kYkHandSettableFields)
        if (handSet.contains(f) && needed.contains(f)) f,
    ];
    if (handSetFields.isNotEmpty) {
      secrets = YkKeySecrets(
        serial: secrets.serial,
        values: {
          for (final MapEntry(key: f, value: v) in secrets.values.entries)
            if (!handSetFields.contains(f)) f: v,
        },
        ledgerFields: {
          for (final f in secrets.ledgerFields)
            if (!handSetFields.contains(f)) f,
        },
      );
    }

    final origins = <String, YkOrigin>{};
    final valueProblems = <String, List<YkValueProblem>>{};
    final ledgerProblems = <String, List<YkLedgerProblem>>{};
    final warnings = <String, List<YkLedgerWarning>>{};
    final sha = <String, String>{};
    for (final MapEntry(key: f, value: v) in secrets.values.entries) {
      if (secrets.ledgerFields.contains(f)) {
        origins[f] = YkOrigin.ledger;
        ledgerProblems[f] = ledger!.problems[f] ?? ykValidateLedgerValue(f, v);
        warnings[f] = ledger.warnings[f] ?? const [];
      } else {
        origins[f] = otp && _otpField(f)
            ? YkOrigin.serial
            : (mode == YkMode.derived ? YkOrigin.derived : YkOrigin.random);
        valueProblems[f] = ykValidateValue(f, v);
      }
      try {
        sha[f] = ykSha256Prefix6(v);
      } on ArgumentError {
        // Unpaired surrogate: cannot happen for these alphabets.
      }
    }
    return YkKeyResult(
      serial: secrets.serial,
      values: secrets.values,
      ledgerFields: secrets.ledgerFields,
      origins: origins,
      valueProblems: valueProblems,
      ledgerProblems: ledgerProblems,
      warnings: warnings,
      sha256Prefix: sha,
      entryNames: ledger?.entryNames ?? const [],
      handSetFields: handSetFields,
    );
  } on YkException catch (e) {
    return YkKeyResult(serial: serial, errorCode: e.code);
  } on Pin24Exception catch (e) {
    return YkKeyResult(serial: serial, errorCode: e.code);
  } catch (_) {
    return YkKeyResult(serial: serial, errorCode: YkComputeError.unexpected);
  }
}

/// Sends [request] through [runner]. Top-level so the closure handed to the
/// isolate captures nothing but [request].
Future<YkResponse> runYubikey(PinComputeRunner runner, YkRequest request) =>
    runner(() => ykCompute(request));
