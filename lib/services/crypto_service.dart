import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../models/cipher_string.dart';
import '../models/encryption_type.dart';
import '../models/kdf_params.dart';
import '../utils/eff_wordlist.dart';

/// Master key + server hash derived for a password login.
class LoginKeys {
  const LoginKeys({
    required this.masterKey,
    required this.stretchedMasterKey,
    required this.masterPasswordHashB64,
  });

  /// 32-byte KDF output.
  final Uint8List masterKey;

  /// 64 bytes = HKDF-Expand(masterKey, "enc") ‖ HKDF-Expand(masterKey, "mac").
  final Uint8List stretchedMasterKey;

  /// base64(PBKDF2-SHA256(masterKey, password, 1)) — the `password` form field.
  final String masterPasswordHashB64;

  /// Best-effort wipe of the key material held by this object.
  void wipe() {
    masterKey.fillRange(0, masterKey.length, 0);
    stretchedMasterKey.fillRange(0, stretchedMasterKey.length, 0);
  }
}

/// Implements the complete Bitwarden-compatible crypto chain in pure Dart.
///
/// Key hierarchy:
///   masterPassword + salt(email) → KDF → masterKey (32B)
///   masterKey → HKDF-Expand → stretchedMasterKey (64B = encKey + macKey)
///   stretchedMasterKey → decrypt(protectedSymmetricKey) → userKey (64B)
///   userKey → RSA-OAEP-SHA1(publicKey) → encryptedKey (for auth request approval)
class CryptoService {
  /// [runKdfInIsolate] moves PBKDF2/Argon2id off the calling isolate (UI
  /// stays responsive during a 64 MiB Argon2id derivation).
  CryptoService({this.runKdfInIsolate = true});

  final bool runKdfInIsolate;

  // ──────────────────────────────────────────────
  // Key Derivation
  // ──────────────────────────────────────────────

  /// Derive masterKey from the password using server-provided KDF params.
  ///
  /// Salt = `(kdf.salt ?? email).trim().toLowerCase()` (sdk-internal kdf.rs).
  /// PBKDF2-SHA256: salt bytes as-is. Argon2id: salt = full 32-byte
  /// SHA-256(salt), memory = `kdf.memory` MiB × 1024 KiB.
  ///
  /// Throws [KdfTooWeakException]/[UnsupportedKdfException] (from
  /// [KdfParams.validate]) before doing any work.
  Future<Uint8List> deriveMasterKey(
    String email,
    String masterPassword,
    KdfParams kdf,
  ) async {
    kdf.validate();
    final job = _KdfJob(
      kdfType: kdf.kdfType,
      iterations: kdf.iterations,
      memoryMiB: kdf.memory ?? 0,
      parallelism: kdf.parallelism ?? 0,
      password: Uint8List.fromList(utf8.encode(masterPassword)),
      salt: Uint8List.fromList(utf8.encode(kdf.saltFor(email))),
    );
    try {
      if (runKdfInIsolate) return await _runKdfInIsolate(job);
      return await _runKdf(job);
    } finally {
      job.password.fillRange(0, job.password.length, 0);
    }
  }

  /// masterKey → stretched key → server hash, in one call.
  Future<LoginKeys> deriveLoginKeys(
    String email,
    String masterPassword,
    KdfParams kdf,
  ) async {
    final masterKey = await deriveMasterKey(email, masterPassword, kdf);
    final hash = await deriveMasterPasswordHash(masterKey, masterPassword);
    return LoginKeys(
      masterKey: masterKey,
      stretchedMasterKey: stretchMasterKey(masterKey),
      masterPasswordHashB64: base64Encode(hash),
    );
  }

  /// Stretch masterKey (32 bytes) → stretchedMasterKey (64 bytes)
  /// using HKDF-Expand(SHA-256).
  ///   encKey = HKDF-Expand(prk=masterKey, info="enc", len=32)
  ///   macKey = HKDF-Expand(prk=masterKey, info="mac", len=32)
  Uint8List stretchMasterKey(Uint8List masterKey) {
    final encKey = _hkdfExpand(masterKey, utf8.encode('enc'), 32);
    final macKey = _hkdfExpand(masterKey, utf8.encode('mac'), 32);
    return Uint8List.fromList([...encKey, ...macKey]);
  }

  /// Derive masterPasswordHash for server authentication.
  /// PBKDF2-SHA256(password=masterKey, salt=masterPassword, iterations=1)
  /// Returns raw 32 bytes (caller base64-encodes for API).
  Future<Uint8List> deriveMasterPasswordHash(
    Uint8List masterKey,
    String masterPassword,
  ) async {
    return _pbkdf2Sha256(
      masterKey,
      Uint8List.fromList(utf8.encode(masterPassword)),
      1,
      32,
    );
  }

  // ──────────────────────────────────────────────
  // Symmetric Encryption / Decryption
  // ──────────────────────────────────────────────

  /// Decrypt protectedSymmetricKey (CipherString type 2) → userKey.
  ///
  /// 1. Verify HMAC-SHA256(iv || ciphertext, macKey) == mac (mandatory)
  /// 2. AES-256-CBC decrypt with PKCS7 padding
  ///
  /// Throws [ArgumentError] for other types, [FormatException] when the MAC
  /// is missing, [StateError] ('MAC verification failed') on a wrong key.
  Uint8List decryptUserKey(
    CipherString protectedKey,
    Uint8List stretchedMasterKey,
  ) {
    if (protectedKey.encType != EncryptionType.aesCbc256_HmacSha256_B64) {
      throw ArgumentError(
        'Expected type 2 (AES-256-CBC-HMAC), got ${protectedKey.encType}',
      );
    }
    return decryptSymmetric(protectedKey, stretchedMasterKey);
  }

  /// Decrypt the protected user key with the *unstretched* master key.
  ///
  /// Type 2 (current): stretch + [decryptUserKey]. Type 0 (legacy, very old
  /// accounts): AES-256-CBC with the raw 32-byte master key, no MAC — as the
  /// SDK still does (master_key.rs decrypt_user_key).
  Uint8List decryptUserKeyWithMasterKey(
    CipherString protectedKey,
    Uint8List masterKey,
  ) {
    switch (protectedKey.encType) {
      case EncryptionType.aesCbc256_HmacSha256_B64:
        final stretched = stretchMasterKey(masterKey);
        try {
          return decryptUserKey(protectedKey, stretched);
        } finally {
          stretched.fillRange(0, stretched.length, 0);
        }
      case EncryptionType.aesCbc256_B64:
        if (masterKey.length != 32) {
          throw ArgumentError('Master key must be 32 bytes');
        }
        final iv = protectedKey.iv;
        if (iv == null || iv.length != 16) {
          throw const FormatException('Invalid IV');
        }
        try {
          return _aesCbcDecrypt(masterKey, iv, protectedKey.ciphertext);
        } on ArgumentError {
          // Bad PKCS7 padding = wrong key for an unauthenticated cipher.
          throw StateError('MAC verification failed');
        }
      default:
        throw ArgumentError(
          'Unsupported protected user key type ${protectedKey.encType}',
        );
    }
  }

  /// Encrypt plaintext with a symmetric key using AES-256-CBC + HMAC-SHA256.
  /// Returns CipherString type 2.
  CipherString encryptSymmetric(Uint8List plaintext, Uint8List key) {
    assert(key.length == 64, 'Key must be 64 bytes (32 enc + 32 mac)');
    final encKey = Uint8List.sublistView(key, 0, 32);
    final macKey = Uint8List.sublistView(key, 32, 64);

    final iv = _randomBytes(16);
    final ciphertext = _aesCbcEncrypt(encKey, iv, plaintext);
    final macData = Uint8List.fromList([...iv, ...ciphertext]);
    final mac = _hmacSha256(macKey, macData);

    return CipherString(
      encType: EncryptionType.aesCbc256_HmacSha256_B64,
      iv: iv,
      ciphertext: ciphertext,
      mac: mac,
    );
  }

  /// Decrypt CipherString type 2 with a 64-byte symmetric key. The MAC is
  /// mandatory (F15): a missing MAC is a [FormatException], a wrong one a
  /// [StateError].
  Uint8List decryptSymmetric(CipherString cs, Uint8List key) {
    if (key.length != 64) {
      throw ArgumentError('Key must be 64 bytes (32 enc + 32 mac)');
    }
    if (cs.encType != EncryptionType.aesCbc256_HmacSha256_B64) {
      throw ArgumentError('Expected type 2, got ${cs.encType}');
    }
    final iv = cs.iv;
    final mac = cs.mac;
    if (iv == null || iv.length != 16) {
      throw const FormatException('Invalid IV');
    }
    if (mac == null || mac.length != 32) {
      throw const FormatException('Missing or invalid MAC');
    }
    final encKey = Uint8List.sublistView(key, 0, 32);
    final macKey = Uint8List.sublistView(key, 32, 64);

    final macData = Uint8List.fromList([...iv, ...cs.ciphertext]);
    final expectedMac = _hmacSha256(macKey, macData);
    if (!_constantTimeEquals(expectedMac, mac)) {
      throw StateError('MAC verification failed');
    }

    return _aesCbcDecrypt(encKey, iv, cs.ciphertext);
  }

  // ──────────────────────────────────────────────
  // RSA-OAEP (Auth Request Approval)
  // ──────────────────────────────────────────────

  /// Encrypt userKey with the requesting device's RSA public key.
  /// Uses RSA-2048 OAEP with SHA-1 (Bitwarden EncryptionType 4).
  /// Returns CipherString "4.{base64(ciphertext)}".
  String encryptUserKeyForApproval(Uint8List userKey, String publicKeyBase64) {
    final publicKeyBytes = base64Decode(publicKeyBase64);
    final rsaPublicKey = _parseSpkiPublicKey(publicKeyBytes);

    final cipher = OAEPEncoding.withSHA1(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(rsaPublicKey));

    final encrypted = cipher.process(userKey);
    return '4.${base64Encode(encrypted)}';
  }

  // ──────────────────────────────────────────────
  // Fingerprint Phrase
  // ──────────────────────────────────────────────

  /// Fingerprint phrase of an auth request, identical to the official
  /// clients (sdk-internal crates/bitwarden-crypto/src/fingerprint.rs):
  ///
  ///   okm = HKDF-Expand(prk = SHA-256(spki), info = utf8(email.trim().toLowerCase()), 32)
  ///   n   = big-endian unsigned integer of okm
  ///   5 × { words.add(wordlist[n % 7776]); n ~/= 7776 }
  ///   join with '-'
  ///
  /// (The SDK uses the SPKI itself as the HMAC key; HMAC hashes keys longer
  /// than its 64-byte block, so that equals SHA-256(spki) for any RSA key.)
  ///
  /// Throws [FormatException] when [publicKeyBase64] is not a base64 RSA
  /// SubjectPublicKeyInfo.
  String generateFingerprintPhrase(
    String publicKeyBase64,
    String email, [
    List<String> wordlist = effWordlist,
  ]) {
    final Uint8List spki;
    try {
      spki = base64Decode(publicKeyBase64.trim());
      _parseSpkiPublicKey(spki);
    } catch (_) {
      throw const FormatException('Invalid auth request public key');
    }
    final prk = _sha256(spki);
    final info = Uint8List.fromList(utf8.encode(email.trim().toLowerCase()));
    final okm = _hkdfExpand(prk, info, 32);

    var n = BigInt.zero;
    for (final b in okm) {
      n = (n << 8) | BigInt.from(b);
    }
    final size = BigInt.from(wordlist.length);
    final words = <String>[];
    for (var i = 0; i < 5; i++) {
      words.add(wordlist[(n % size).toInt()]);
      n = n ~/ size;
    }
    return words.join('-');
  }

  /// Like [generateFingerprintPhrase] but returns null instead of throwing
  /// (malformed keys must not break the whole request list — A1).
  String? tryGenerateFingerprintPhrase(
    String publicKeyBase64,
    String email, [
    List<String> wordlist = effWordlist,
  ]) {
    try {
      return generateFingerprintPhrase(publicKeyBase64, email, wordlist);
    } catch (_) {
      return null;
    }
  }

  // ──────────────────────────────────────────────
  // Private helpers
  // ──────────────────────────────────────────────

  Uint8List _sha256(Uint8List data) => SHA256Digest().process(data);

  Uint8List _hmacSha256(Uint8List key, Uint8List data) {
    final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    return hmac.process(data);
  }

  /// HKDF-Expand only (no Extract step).
  /// PRK is used directly as the HMAC key.
  Uint8List _hkdfExpand(Uint8List prk, List<int> info, int length) =>
      hkdfExpandSha256(prk, info, length);

  Uint8List _aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
    final params = ParametersWithIV(KeyParameter(key), iv);
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(false, PaddedBlockCipherParameters(params, null));
    return cipher.process(ciphertext);
  }

  Uint8List _aesCbcEncrypt(Uint8List key, Uint8List iv, Uint8List plaintext) {
    final params = ParametersWithIV(KeyParameter(key), iv);
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(true, PaddedBlockCipherParameters(params, null));
    return cipher.process(plaintext);
  }

  Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  /// Parse SPKI DER-encoded RSA public key. Throws on anything else.
  RSAPublicKey _parseSpkiPublicKey(Uint8List bytes) {
    final parser = ASN1Parser(bytes);
    final topSequence = parser.nextObject() as ASN1Sequence;
    final bitString = topSequence.elements![1] as ASN1BitString;
    // Skip the unused-bits byte (first byte of bit string value)
    final keyBytes = Uint8List.sublistView(bitString.valueBytes!, 1);

    final keyParser = ASN1Parser(keyBytes);
    final keySequence = keyParser.nextObject() as ASN1Sequence;
    final modulus = (keySequence.elements![0] as ASN1Integer).integer!;
    final exponent = (keySequence.elements![1] as ASN1Integer).integer!;
    if (modulus.bitLength < 1024 || exponent <= BigInt.one) {
      throw const FormatException('Unsupported RSA key');
    }

    return RSAPublicKey(modulus, exponent);
  }

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

/// HKDF-Expand (RFC 5869 §2.3) with HMAC-SHA256; [prk] is the HMAC key.
Uint8List hkdfExpandSha256(Uint8List prk, List<int> info, int length) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(prk));
  const hashLen = 32;
  final n = (length + hashLen - 1) ~/ hashLen;
  final result = BytesBuilder();
  var prev = Uint8List(0);
  for (var i = 1; i <= n; i++) {
    hmac.reset();
    prev = hmac.process(Uint8List.fromList([...prev, ...info, i]));
    result.add(prev);
  }
  return Uint8List.sublistView(result.toBytes(), 0, length);
}

// ── KDF (runs in a background isolate) ──

class _KdfJob {
  const _KdfJob({
    required this.kdfType,
    required this.iterations,
    required this.memoryMiB,
    required this.parallelism,
    required this.password,
    required this.salt,
  });

  final int kdfType;
  final int iterations;
  final int memoryMiB;
  final int parallelism;
  final Uint8List password;
  final Uint8List salt;
}

/// Top-level so the isolate closure captures nothing but [job].
Future<Uint8List> _runKdfInIsolate(_KdfJob job) =>
    Isolate.run(() => _runKdf(job));

Future<Uint8List> _runKdf(_KdfJob job) async {
  if (job.kdfType == KdfParams.typeArgon2id) {
    // Full 32-byte SHA-256 of the salt string (NOT truncated), memory in KiB.
    final saltHash = SHA256Digest().process(job.salt);
    final algorithm = crypto.Argon2id(
      memory: job.memoryMiB * 1024,
      parallelism: job.parallelism,
      iterations: job.iterations,
      hashLength: 32,
    );
    final result = await algorithm.deriveKey(
      secretKey: crypto.SecretKey(job.password),
      nonce: saltHash,
    );
    return Uint8List.fromList(await result.extractBytes());
  }
  return _pbkdf2Sha256(job.password, job.salt, job.iterations, 32);
}

Uint8List _pbkdf2Sha256(
  Uint8List password,
  Uint8List salt,
  int iterations,
  int keyLength,
) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, keyLength));
  return derivator.process(password);
}
