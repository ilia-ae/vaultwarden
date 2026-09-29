import 'api_error.dart';
import 'json_util.dart';

/// Master-password KDF parameters (+ optional server-provided salt).
///
/// Sources, in order of preference:
///  * prelogin `kdfSettings` {kdfType, iterations, memory, parallelism},
///    falling back to the flat (deprecated, PM-28143) `kdf`, `kdfIterations`,
///    `kdfMemory`, `kdfParallelism` fields — see [KdfParams.fromJson];
///  * token response `UserDecryptionOptions.MasterPasswordUnlock`
///    {Kdf: {KdfType, Iterations, Memory, Parallelism}, Salt} — see
///    [KdfParams.tryFromMasterPasswordUnlock].
class KdfParams {
  static const int typePbkdf2Sha256 = 0;
  static const int typeArgon2id = 1;

  /// Official clients' minimums (sdk-internal kdf.rs, clients kdf-config.ts).
  static const int pbkdf2MinIterations = 5000;
  static const int argon2MinMemoryMiB = 16;
  static const int argon2MinIterations = 2;
  static const int argon2MinParallelism = 1;

  /// Sanity maxima = the official settings ranges (clients kdf-config.ts,
  /// server KdfConstants). A hostile server could otherwise pin the KDF
  /// isolate for hours (2^31-1 iterations) or exhaust memory ("4 GiB").
  static const int pbkdf2MaxIterations = 2000000;
  static const int argon2MaxMemoryMiB = 1024;
  static const int argon2MaxIterations = 10;
  static const int argon2MaxParallelism = 16;

  /// 0 = PBKDF2-SHA256, 1 = Argon2id
  final int kdfType;
  final int iterations;

  /// **MiB** (server unit), Argon2id only. Multiply by 1024 for KiB-based
  /// Argon2 APIs.
  final int? memory;

  /// Argon2id only.
  final int? parallelism;

  /// Master-password salt from the server (prelogin `salt` /
  /// `MasterPasswordUnlock.Salt`). Null → use the account e-mail.
  final String? salt;

  const KdfParams({
    required this.kdfType,
    required this.iterations,
    this.memory,
    this.parallelism,
    this.salt,
  });

  /// Parses a prelogin response. Throws [FormatException] when neither
  /// `kdfSettings` nor the flat fields are usable.
  factory KdfParams.fromJson(Map<String, dynamic> json) {
    final salt = jsonNonEmptyString(json, 'salt');
    final settings = jsonMap(json, 'kdfSettings');
    if (settings != null) {
      final parsed = _tryFromSettings(settings, salt: salt);
      if (parsed != null) return parsed;
    }
    final type = jsonInt(json, 'kdf');
    final iterations = jsonInt(json, 'kdfIterations');
    if (type == null || iterations == null) {
      throw const FormatException('Prelogin response has no KDF parameters');
    }
    return KdfParams(
      kdfType: type,
      iterations: iterations,
      memory: jsonInt(json, 'kdfMemory'),
      parallelism: jsonInt(json, 'kdfParallelism'),
      salt: salt,
    );
  }

  /// Parses a KDF settings object: `{kdfType|kdf, iterations|kdfIterations,
  /// memory|kdfMemory, parallelism|kdfParallelism}` (any key casing).
  factory KdfParams.fromKdfSettings(Map<String, dynamic> json, {String? salt}) {
    final parsed = _tryFromSettings(json, salt: salt);
    if (parsed == null) {
      throw const FormatException('Invalid KDF settings');
    }
    return parsed;
  }

  /// Reads `MasterPasswordUnlock` ({Kdf, Salt, …}) from a token response's
  /// `UserDecryptionOptions`. Returns null when absent or unusable.
  static KdfParams? tryFromMasterPasswordUnlock(Object? masterPasswordUnlock) {
    final kdf = jsonMap(masterPasswordUnlock, 'Kdf');
    if (kdf == null) return null;
    return _tryFromSettings(
      kdf,
      salt: jsonNonEmptyString(masterPasswordUnlock, 'Salt'),
    );
  }

  static KdfParams? _tryFromSettings(Map<String, dynamic> s, {String? salt}) {
    final type = jsonInt(s, 'kdfType') ?? jsonInt(s, 'kdf');
    final iterations = jsonInt(s, 'iterations') ?? jsonInt(s, 'kdfIterations');
    if (type == null || iterations == null) return null;
    return KdfParams(
      kdfType: type,
      iterations: iterations,
      memory: jsonInt(s, 'memory') ?? jsonInt(s, 'kdfMemory'),
      parallelism: jsonInt(s, 'parallelism') ?? jsonInt(s, 'kdfParallelism'),
      salt: salt,
    );
  }

  bool get isArgon2id => kdfType == typeArgon2id;
  bool get isPbkdf2 => kdfType == typePbkdf2Sha256;

  /// The salt string fed to the KDF: `(salt ?? email).trim().toLowerCase()`
  /// — exactly what sdk-internal does (password_prelogin_response.rs + kdf.rs).
  String saltFor(String email) {
    final s = salt;
    return ((s != null && s.trim().isNotEmpty) ? s : email)
        .trim()
        .toLowerCase();
  }

  /// Throws [KdfTooWeakException] / [UnsupportedKdfException] when the
  /// parameters must not be used (downgrade protection, F15).
  void validate() {
    if (isPbkdf2) {
      if (iterations < pbkdf2MinIterations) {
        throw KdfTooWeakException(
          'PBKDF2 iterations $iterations < $pbkdf2MinIterations',
        );
      }
      if (iterations > pbkdf2MaxIterations) {
        throw KdfTooWeakException(
          'PBKDF2 iterations $iterations > $pbkdf2MaxIterations',
        );
      }
      return;
    }
    if (isArgon2id) {
      final m = memory;
      final p = parallelism;
      if (m == null || p == null) {
        throw const KdfTooWeakException('Argon2id memory/parallelism missing');
      }
      if (m < argon2MinMemoryMiB) {
        throw KdfTooWeakException(
            'Argon2id memory $m MiB < $argon2MinMemoryMiB');
      }
      if (m > argon2MaxMemoryMiB) {
        throw KdfTooWeakException(
            'Argon2id memory $m MiB > $argon2MaxMemoryMiB');
      }
      if (iterations < argon2MinIterations) {
        throw KdfTooWeakException(
          'Argon2id iterations $iterations < $argon2MinIterations',
        );
      }
      if (iterations > argon2MaxIterations) {
        throw KdfTooWeakException(
          'Argon2id iterations $iterations > $argon2MaxIterations',
        );
      }
      if (p < argon2MinParallelism || p > argon2MaxParallelism) {
        throw KdfTooWeakException('Argon2id parallelism $p out of range');
      }
      return;
    }
    throw UnsupportedKdfException(kdfType);
  }

  KdfParams copyWith({String? salt}) => KdfParams(
        kdfType: kdfType,
        iterations: iterations,
        memory: memory,
        parallelism: parallelism,
        salt: salt ?? this.salt,
      );

  /// True when both describe the same KDF (salt ignored).
  bool sameKdfAs(KdfParams other) =>
      kdfType == other.kdfType &&
      iterations == other.iterations &&
      (isPbkdf2 ||
          (memory == other.memory && parallelism == other.parallelism));

  @override
  String toString() => isArgon2id
      ? 'KdfParams(Argon2id i=$iterations m=${memory}MiB p=$parallelism)'
      : 'KdfParams(PBKDF2 i=$iterations)';
}
