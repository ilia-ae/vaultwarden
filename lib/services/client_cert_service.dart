import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import '../models/server_environment.dart';
import 'secure_storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────

/// Import/validation error of a client certificate file.
sealed class ClientCertException implements Exception {
  const ClientCertException();
}

/// The .p12/.pfx password is wrong (MAC check or key decryption failed).
final class ClientCertBadPasswordException extends ClientCertException {
  const ClientCertBadPasswordException();
  @override
  String toString() => 'ClientCertBadPasswordException';
}

/// Not a usable PKCS#12 file (not PKCS#12, no private key / certificate,
/// or an encryption scheme neither we nor the TLS stack support).
final class ClientCertUnsupportedFormatException extends ClientCertException {
  const ClientCertUnsupportedFormatException(this.detail);

  /// Technical detail (not localised).
  final String detail;

  @override
  String toString() => 'ClientCertUnsupportedFormatException($detail)';
}

/// An extra trusted CA PEM could not be loaded.
final class ClientCertInvalidCaException extends ClientCertException {
  const ClientCertInvalidCaException();
  @override
  String toString() => 'ClientCertInvalidCaException';
}

// ─────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────

/// What the UI may show about an imported client certificate. All fields
/// describe the LEAF certificate (the one matching the private key — in
/// ordered bundles that is chain[0], never the trailing CA).
class ClientCertificateInfo {
  const ClientCertificateInfo({
    this.subject,
    this.commonName,
    this.issuer,
    this.notBefore,
    this.notAfter,
    this.certificateCount = 0,
  });

  /// RFC 4514-style, most specific first: `CN=ilia-android, O=ilia.ae`.
  final String? subject;
  final String? commonName;
  final String? issuer;

  /// UTC.
  final DateTime? notBefore;

  /// UTC.
  final DateTime? notAfter;

  /// Number of certificates in the bundle (leaf + chain).
  final int certificateCount;

  bool isExpired({DateTime? now}) {
    final end = notAfter;
    return end != null && !(now ?? DateTime.now()).toUtc().isBefore(end);
  }

  /// True when the certificate expires within [threshold] (default 30 days)
  /// or already has.
  bool isExpiringSoon({
    DateTime? now,
    Duration threshold = const Duration(days: 30),
  }) {
    final end = notAfter;
    if (end == null) return false;
    return end.difference((now ?? DateTime.now()).toUtc()) < threshold;
  }

  Duration? timeLeft({DateTime? now}) =>
      notAfter?.difference((now ?? DateTime.now()).toUtc());

  Map<String, dynamic> toJson() => {
        'subject': subject,
        'commonName': commonName,
        'issuer': issuer,
        'notBefore': notBefore?.toIso8601String(),
        'notAfter': notAfter?.toIso8601String(),
        'certificateCount': certificateCount,
      };

  factory ClientCertificateInfo.fromJson(Map<String, dynamic> json) =>
      ClientCertificateInfo(
        subject: json['subject'] as String?,
        commonName: json['commonName'] as String?,
        issuer: json['issuer'] as String?,
        notBefore:
            DateTime.tryParse(json['notBefore'] as String? ?? '')?.toUtc(),
        notAfter: DateTime.tryParse(json['notAfter'] as String? ?? '')?.toUtc(),
        certificateCount: (json['certificateCount'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'ClientCertificateInfo($subject, notAfter: $notAfter)';
}

/// A certificate stored for one server origin.
class StoredClientCertificate {
  const StoredClientCertificate({
    required this.origin,
    required this.pkcs12,
    required this.password,
    required this.info,
    required this.importedAt,
  });

  final String origin;
  final Uint8List pkcs12;
  final String password;
  final ClientCertificateInfo info;
  final DateTime importedAt;

  // Never print secrets.
  @override
  String toString() => 'StoredClientCertificate($origin, ${info.subject})';
}

// ─────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────

/// Per-server client certificates (mTLS) and the TLS clients built from them.
///
/// Storage: `client_cert|<origin>` → JSON {p12 (base64), password, info,
/// importedAt}; `client_ca|<origin>` → extra trusted CA PEM. Same keychain
/// options as [SecureStorageService]. Kept on logout, removed by
/// `SecureStorageService.clearAll()`.
///
/// Transport: [securityContextFor] / [createHttpClient] build
/// `SecurityContext(withTrustedRoots: true)` + the PKCS#12 chain and key
/// (+ extra CA if configured) — never a trust-all callback. Use the context
/// for Dio (`IOHttpClientAdapter(createHttpClient: …)`) and the hub
/// (`IOWebSocketChannel.connect(uri, customClient: …)`); listen to [changes]
/// to rebuild them after an import/removal.
class ClientCertService {
  ClientCertService({
    FlutterSecureStorage? storage,
    this.extraTrustedCaPem,
  }) : _storage = storage ?? SecureStorageService.defaultStorage;

  /// The app-wide instance. VaultApiService and NotificationService default
  /// to it, so a certificate imported through it reaches both the REST client
  /// and the hub. Share it (e.g. via a provider) instead of creating more.
  static final ClientCertService instance = ClientCertService();

  final FlutterSecureStorage _storage;

  /// Extra CA trusted for every origin (tests / private CAs set up in code).
  final String? extraTrustedCaPem;

  final _changes = StreamController<String>.broadcast();
  final _cache = <String, _OriginEntry>{};
  int _revision = 0;

  /// Emits the origin whose certificate/CA changed.
  Stream<String> get changes => _changes.stream;

  /// Increments on every import/removal/CA change.
  int get revision => _revision;

  /// `scheme://host[:port]` for a server or request URL.
  static String originOf(String url) {
    final normalized = ServerEnvironment.normalizeBaseUrl(url);
    return Uri.parse(normalized).origin;
  }

  static String _certKey(String origin) =>
      '${SecureStorageService.clientCertPrefix}$origin';
  static String _caKey(String origin) =>
      '${SecureStorageService.clientCaPrefix}$origin';

  // ── Validation ──

  /// Validates a .p12/.pfx without storing it (synchronously — prefer
  /// [inspectAsync] on the UI isolate). Throws
  /// [ClientCertBadPasswordException] / [ClientCertUnsupportedFormatException].
  ClientCertificateInfo inspect(Uint8List pkcs12, String password) =>
      validatePkcs12(pkcs12, password);

  /// [inspect] in a background isolate (PKCS#12 key derivation can take a
  /// few hundred milliseconds).
  Future<ClientCertificateInfo> inspectAsync(
    Uint8List pkcs12,
    String password,
  ) =>
      _validateInIsolate(pkcs12, password);

  /// The validation behind [inspect]: our PKCS#12 reader (password check via
  /// the MAC, leaf certificate details) plus the TLS stack itself.
  static ClientCertificateInfo validatePkcs12(
    Uint8List pkcs12,
    String password,
  ) {
    Pkcs12Contents? parsed;
    Object? parseError;
    try {
      parsed = Pkcs12Contents.parse(pkcs12, password);
    } on ClientCertBadPasswordException {
      rethrow;
    } catch (e) {
      parseError = e;
    }
    if (parsed != null && !parsed.hasPrivateKey) {
      throw const ClientCertUnsupportedFormatException('no private key');
    }
    if (parsed != null && parsed.certificates.isEmpty) {
      throw const ClientCertUnsupportedFormatException('no certificate');
    }

    // The TLS stack must accept the file too (it does the real work).
    try {
      SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(pkcs12, password: password)
        ..usePrivateKeyBytes(pkcs12, password: password);
    } on ArgumentError {
      // e.g. a PEM certificate without a key.
      throw ClientCertUnsupportedFormatException(
        parseError?.toString() ?? 'no private key',
      );
    } on TlsException catch (e) {
      final text = '${e.message} ${e.osError?.message ?? ''}'.toUpperCase();
      if (text.contains('INCORRECT_PASSWORD') ||
          text.contains('BAD_PASSWORD') ||
          text.contains('BAD_DECRYPT') ||
          text.contains('MAC_VERIFY')) {
        throw const ClientCertBadPasswordException();
      }
      throw ClientCertUnsupportedFormatException(
        parseError?.toString() ?? 'rejected by TLS stack',
      );
    }
    return parsed?.leafInfo ?? const ClientCertificateInfo();
  }

  // ── Storage ──

  /// Validates and stores [pkcs12] for the origin of [serverUrl], replacing
  /// any previous certificate. Emits on [changes].
  Future<ClientCertificateInfo> importCertificate({
    required String serverUrl,
    required Uint8List pkcs12,
    required String password,
  }) async {
    final info = await inspectAsync(pkcs12, password);
    final origin = originOf(serverUrl);
    final now = DateTime.now().toUtc();
    await _storage.write(
      key: _certKey(origin),
      value: jsonEncode({
        'p12': base64Encode(pkcs12),
        'password': password,
        'info': info.toJson(),
        'importedAt': now.toIso8601String(),
      }),
    );
    _invalidate(origin);
    return info;
  }

  /// The stored certificate for the origin of [url], or null.
  Future<StoredClientCertificate?> load(String url) async =>
      (await _entry(originOf(url))).certificate;

  Future<ClientCertificateInfo?> info(String url) async =>
      (await load(url))?.info;

  Future<bool> hasCertificate(String url) async => (await load(url)) != null;

  /// Removes the certificate of [url]'s origin. Emits on [changes].
  Future<void> remove(String url) async {
    final origin = originOf(url);
    await _storage.delete(key: _certKey(origin));
    _invalidate(origin);
  }

  /// Sets (or clears with null) an extra trusted CA for [url]'s origin, for
  /// servers whose TLS certificate comes from a private CA.
  Future<void> setTrustedCaPem(String url, String? pem) async {
    final origin = originOf(url);
    if (pem == null || pem.trim().isEmpty) {
      await _storage.delete(key: _caKey(origin));
    } else {
      try {
        SecurityContext(withTrustedRoots: false)
            .setTrustedCertificatesBytes(utf8.encode(pem));
      } on TlsException {
        throw const ClientCertInvalidCaException();
      }
      await _storage.write(key: _caKey(origin), value: pem);
    }
    _invalidate(origin);
  }

  Future<String?> trustedCaPem(String url) async =>
      (await _entry(originOf(url))).caPem;

  /// Drops the in-memory cache (e.g. after the secure store was wiped).
  /// Call after `SecureStorageService.clearAll()` wiped the store.
  void clearCache() {
    final origins = _cache.keys.toList();
    _cache.clear();
    _revision++;
    for (final origin in origins) {
      _changes.add(origin);
    }
  }

  // ── Transport ──

  /// TLS context for requests to [url]'s origin, or null when neither a
  /// client certificate nor an extra CA applies (use a default HttpClient).
  Future<SecurityContext?> securityContextFor(String url) async {
    final String origin;
    try {
      origin = originOf(url);
    } on FormatException {
      return _globalContext();
    }
    final entry = await _entry(origin);
    return entry.context ??= _buildContext(entry.certificate, entry.caPem);
  }

  /// A fresh HttpClient for [url] (for `IOWebSocketChannel.connect(…,
  /// customClient: …)`).
  Future<HttpClient> createHttpClient(String url) async =>
      httpClientFor(await securityContextFor(url));

  /// HttpClient for a context from [securityContextFor] (sync, for Dio's
  /// `IOHttpClientAdapter(createHttpClient: …)`).
  static HttpClient httpClientFor(SecurityContext? context) =>
      context == null ? HttpClient() : HttpClient(context: context);

  SecurityContext? _globalContext() {
    final ca = extraTrustedCaPem;
    if (ca == null) return null;
    return SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(utf8.encode(ca));
  }

  SecurityContext? _buildContext(StoredClientCertificate? cert, String? caPem) {
    if (cert == null && caPem == null && extraTrustedCaPem == null) {
      return null;
    }
    final ctx = SecurityContext(withTrustedRoots: true);
    for (final pem in [extraTrustedCaPem, caPem]) {
      if (pem != null) ctx.setTrustedCertificatesBytes(utf8.encode(pem));
    }
    if (cert != null) {
      ctx
        ..useCertificateChainBytes(cert.pkcs12, password: cert.password)
        ..usePrivateKeyBytes(cert.pkcs12, password: cert.password);
    }
    return ctx;
  }

  Future<_OriginEntry> _entry(String origin) async {
    final cached = _cache[origin];
    if (cached != null) return cached;
    final entry = _OriginEntry(
      certificate: await _readCertificate(origin),
      caPem: await _storage.read(key: _caKey(origin)),
    );
    _cache[origin] = entry;
    return entry;
  }

  Future<StoredClientCertificate?> _readCertificate(String origin) async {
    final raw = await _storage.read(key: _certKey(origin));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return StoredClientCertificate(
        origin: origin,
        pkcs12: base64Decode(json['p12'] as String),
        password: json['password'] as String? ?? '',
        info: ClientCertificateInfo.fromJson(
          (json['info'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        importedAt:
            DateTime.tryParse(json['importedAt'] as String? ?? '')?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }

  void _invalidate(String origin) {
    _cache.remove(origin);
    _revision++;
    _changes.add(origin);
  }

  void dispose() {
    _changes.close();
  }
}

/// Top-level so the isolate closure captures only the arguments.
Future<ClientCertificateInfo> _validateInIsolate(
  Uint8List pkcs12,
  String password,
) =>
    Isolate.run(() => ClientCertService.validatePkcs12(pkcs12, password));

class _OriginEntry {
  _OriginEntry({this.certificate, this.caPem});
  final StoredClientCertificate? certificate;
  final String? caPem;
  SecurityContext? context;
}

// ─────────────────────────────────────────────────────────────────────────
// PKCS#12 / X.509 reader (read-only, just enough to verify the password and
// describe the leaf certificate). Supports DER and BER (indefinite lengths,
// constructed OCTET STRINGs), MAC with SHA-1/SHA-2, PKCS#12 PBE (3DES,
// RC2-40/128) and PBES2 (PBKDF2 + AES-CBC / 3DES).
// ─────────────────────────────────────────────────────────────────────────

/// Parsed contents of a PKCS#12 file.
class Pkcs12Contents {
  Pkcs12Contents._(this.certificates, this.keyLocalIds, this.hasPrivateKey);

  final List<X509Summary> certificates;
  final Set<String> keyLocalIds;
  final bool hasPrivateKey;

  /// Throws [ClientCertBadPasswordException] when the MAC does not verify,
  /// [FormatException] / [UnsupportedError] for anything it cannot read.
  static Pkcs12Contents parse(Uint8List bytes, String password) {
    final pfx = _Der.parse(bytes);
    final top = pfx.children;
    if (top.length < 2) throw const FormatException('Not PKCS#12');
    final authSafe = top[1];
    final ci = authSafe.children;
    if (ci.isEmpty || ci[0].oid != _oidData) {
      throw UnsupportedError('PKCS#12 authSafe is not plain data');
    }
    final authSafeBytes = ci[1].children.first.octets;

    if (top.length > 2) {
      _verifyMac(top[2], authSafeBytes, password);
    }

    final certs = <X509Summary>[];
    final keyIds = <String>{};
    var hasKey = false;

    void readSafeContents(Uint8List der) {
      for (final bag in _Der.parse(der).children) {
        final parts = bag.children;
        final bagId = parts[0].oid;
        final value = parts[1].children.first;
        final attrs = parts.length > 2 ? parts[2] : null;
        switch (bagId) {
          case _oidCertBag:
            final certParts = value.children;
            if (certParts[0].oid == _oidX509Certificate) {
              final der = certParts[1].children.first.octets;
              certs.add(X509Summary.parse(der, localKeyId: _localKeyId(attrs)));
            }
          case _oidShroudedKeyBag:
          case _oidKeyBag:
            hasKey = true;
            final id = _localKeyId(attrs);
            if (id != null) keyIds.add(id);
          case _oidSafeContentsBag:
            readSafeContents(value.encoded);
          default:
            break;
        }
      }
    }

    for (final contentInfo in _Der.parse(authSafeBytes).children) {
      final parts = contentInfo.children;
      final type = parts[0].oid;
      if (type == _oidData) {
        readSafeContents(parts[1].children.first.octets);
      } else if (type == _oidEncryptedData) {
        final encData = parts[1].children.first.children;
        final eci = encData[1].children; // EncryptedContentInfo
        final algorithm = eci[1];
        final ciphertext = eci[2].octets;
        readSafeContents(_decrypt(algorithm, ciphertext, password));
      }
      // envelopedData etc.: ignored.
    }
    return Pkcs12Contents._(certs, keyIds, hasKey);
  }

  /// The certificate belonging to the private key: matched by localKeyId,
  /// else the one that issued none of the others, else chain[0].
  X509Summary? get leaf {
    if (certificates.isEmpty) return null;
    for (final c in certificates) {
      if (c.localKeyId != null && keyLocalIds.contains(c.localKeyId)) return c;
    }
    for (final c in certificates) {
      final issuesOthers = certificates.any(
        (o) => !identical(o, c) && _bytesEqual(o.issuerDer, c.subjectDer),
      );
      if (!issuesOthers) return c;
    }
    return certificates.first;
  }

  ClientCertificateInfo get leafInfo {
    final l = leaf;
    if (l == null) return const ClientCertificateInfo();
    return ClientCertificateInfo(
      subject: l.subject,
      commonName: l.commonName,
      issuer: l.issuer,
      notBefore: l.notBefore,
      notAfter: l.notAfter,
      certificateCount: certificates.length,
    );
  }

  static String? _localKeyId(_Der? attributes) {
    if (attributes == null) return null;
    for (final attr in attributes.children) {
      final parts = attr.children;
      if (parts.length == 2 && parts[0].oid == _oidLocalKeyId) {
        final values = parts[1].children;
        if (values.isNotEmpty) return _hex(values.first.octets);
      }
    }
    return null;
  }

  static void _verifyMac(_Der macData, Uint8List content, String password) {
    final parts = macData.children;
    final digestInfo = parts[0].children;
    final digestOid = digestInfo[0].children.first.oid;
    final expected = digestInfo[1].octets;
    final salt = parts[1].octets;
    final iterations = parts.length > 2 ? parts[2].intValue : 1;
    final Digest Function()? makeDigest = _digests[digestOid];
    if (makeDigest == null) return; // e.g. PBMAC1: rely on the TLS stack

    bool check(Uint8List pass) {
      final digest = makeDigest();
      final gen = PKCS12ParametersGenerator(digest)
        ..init(pass, salt, iterations);
      final key = gen.generateDerivedMacParameters(digest.digestSize);
      final mac = HMac(makeDigest(), digest.byteLength)..init(key);
      return _bytesEqual(mac.process(content), expected);
    }

    if (check(_bmpPassword(password))) return;
    // OpenSSL also accepts an empty password encoded as zero bytes.
    if (password.isEmpty && check(Uint8List(0))) return;
    throw const ClientCertBadPasswordException();
  }

  static Uint8List _decrypt(_Der algorithm, Uint8List data, String password) {
    final oid = algorithm.children[0].oid;
    final params = algorithm.children.length > 1 ? algorithm.children[1] : null;
    try {
      if (oid == _oidPbes2) return _decryptPbes2(params!, data, password);
      final spec = _pkcs12Pbe[oid];
      if (spec == null) throw UnsupportedError('Encryption $oid');
      final p = params!.children;
      final salt = p[0].octets;
      final iterations = p[1].intValue;
      final gen = PKCS12ParametersGenerator(SHA1Digest())
        ..init(_bmpPassword(password), salt, iterations);
      final kiv = gen.generateDerivedParametersWithIV(spec.keyLength, 8);
      final key = (kiv.parameters! as KeyParameter).key;
      final BlockCipher engine;
      final CipherParameters keyParams;
      if (spec.rc2Bits != null) {
        engine = RC2Engine();
        keyParams = RC2Parameters(key, bits: spec.rc2Bits);
      } else {
        engine = DESedeEngine();
        keyParams = KeyParameter(key);
      }
      return _cbcDecrypt(engine, keyParams, kiv.iv, data);
    } on ArgumentError {
      // Bad padding: wrong password (when there was no MAC to tell us).
      throw const ClientCertBadPasswordException();
    }
  }

  static Uint8List _decryptPbes2(_Der params, Uint8List data, String password) {
    final p = params.children;
    final kdf = p[0].children;
    final enc = p[1].children;
    if (kdf[0].oid != _oidPbkdf2) throw UnsupportedError('KDF ${kdf[0].oid}');
    final kdfParams = kdf[1].children;
    final salt = kdfParams[0].octets;
    final iterations = kdfParams[1].intValue;
    var prfOid = _oidHmacSha1;
    for (final extra in kdfParams.skip(2)) {
      if (extra.tag == 0x30) prfOid = extra.children[0].oid;
    }
    final prf = _hmacDigests[prfOid];
    if (prf == null) throw UnsupportedError('PRF $prfOid');
    final cipher = _pbes2Ciphers[enc[0].oid];
    if (cipher == null) throw UnsupportedError('Cipher ${enc[0].oid}');
    final iv = enc[1].octets;
    final derivator = PBKDF2KeyDerivator(HMac(prf(), prf().byteLength))
      ..init(Pbkdf2Parameters(salt, iterations, cipher.keyLength));
    final key = derivator.process(Uint8List.fromList(utf8.encode(password)));
    return _cbcDecrypt(cipher.engine(), KeyParameter(key), iv, data);
  }

  static Uint8List _cbcDecrypt(
    BlockCipher engine,
    CipherParameters key,
    Uint8List iv,
    Uint8List data,
  ) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(engine))
      ..init(
        false,
        PaddedBlockCipherParameters(ParametersWithIV(key, iv), null),
      );
    return cipher.process(data);
  }

  static Uint8List _bmpPassword(String password) {
    final out = BytesBuilder();
    for (final unit in password.codeUnits) {
      out
        ..addByte(unit >> 8)
        ..addByte(unit & 0xff);
    }
    out
      ..addByte(0)
      ..addByte(0);
    return out.toBytes();
  }
}

/// The parts of an X.509 certificate the UI needs.
class X509Summary {
  X509Summary._({
    required this.subject,
    required this.issuer,
    required this.subjectDer,
    required this.issuerDer,
    required this.notBefore,
    required this.notAfter,
    required this.commonName,
    this.localKeyId,
  });

  final String subject;
  final String issuer;
  final String? commonName;
  final Uint8List subjectDer;
  final Uint8List issuerDer;
  final DateTime? notBefore;
  final DateTime? notAfter;
  final String? localKeyId;

  static X509Summary parse(Uint8List der, {String? localKeyId}) {
    final tbs = _Der.parse(der).children.first.children;
    var i = 0;
    if (tbs[0].tag == 0xA0) i = 1; // [0] version
    final issuer = tbs[i + 2];
    final validity = tbs[i + 3].children;
    final subject = tbs[i + 4];
    return X509Summary._(
      subject: _formatName(subject),
      issuer: _formatName(issuer),
      subjectDer: subject.encoded,
      issuerDer: issuer.encoded,
      notBefore: _parseTime(validity[0]),
      notAfter: _parseTime(validity[1]),
      commonName: _nameAttribute(subject, '2.5.4.3'),
      localKeyId: localKeyId,
    );
  }

  static const _names = {
    '2.5.4.3': 'CN',
    '2.5.4.5': 'SERIALNUMBER',
    '2.5.4.6': 'C',
    '2.5.4.7': 'L',
    '2.5.4.8': 'ST',
    '2.5.4.10': 'O',
    '2.5.4.11': 'OU',
    '1.2.840.113549.1.9.1': 'E',
  };

  static String _formatName(_Der name) {
    final parts = <String>[];
    for (final rdn in name.children) {
      for (final atv in rdn.children) {
        final oid = atv.children[0].oid;
        final value = atv.children[1].stringValue;
        parts.add('${_names[oid] ?? oid}=$value');
      }
    }
    return parts.reversed.join(', ');
  }

  static String? _nameAttribute(_Der name, String oid) {
    for (final rdn in name.children) {
      for (final atv in rdn.children) {
        if (atv.children[0].oid == oid) return atv.children[1].stringValue;
      }
    }
    return null;
  }

  static DateTime? _parseTime(_Der node) {
    final s = ascii.decode(node.content, allowInvalid: true).trim();
    final isUtcTime = node.tag == 0x17; // else GeneralizedTime (0x18)
    final m = RegExp(
      isUtcTime
          ? r'^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?'
          : r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?',
    ).firstMatch(s);
    if (m == null) return null;
    var year = int.parse(m.group(1)!);
    if (isUtcTime) year += year >= 50 ? 1900 : 2000;
    return DateTime.utc(
      year,
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    );
  }
}

// ── OIDs and algorithm tables ──

const _oidData = '1.2.840.113549.1.7.1';
const _oidEncryptedData = '1.2.840.113549.1.7.6';
const _oidKeyBag = '1.2.840.113549.1.12.10.1.1';
const _oidShroudedKeyBag = '1.2.840.113549.1.12.10.1.2';
const _oidCertBag = '1.2.840.113549.1.12.10.1.3';
const _oidSafeContentsBag = '1.2.840.113549.1.12.10.1.6';
const _oidX509Certificate = '1.2.840.113549.1.9.22.1';
const _oidLocalKeyId = '1.2.840.113549.1.9.21';
const _oidPbes2 = '1.2.840.113549.1.5.13';
const _oidPbkdf2 = '1.2.840.113549.1.5.12';
const _oidHmacSha1 = '1.2.840.113549.2.7';

final Map<String, Digest Function()> _digests = {
  '1.3.14.3.2.26': SHA1Digest.new,
  '2.16.840.1.101.3.4.2.4': SHA224Digest.new,
  '2.16.840.1.101.3.4.2.1': SHA256Digest.new,
  '2.16.840.1.101.3.4.2.2': SHA384Digest.new,
  '2.16.840.1.101.3.4.2.3': SHA512Digest.new,
};

final Map<String, Digest Function()> _hmacDigests = {
  _oidHmacSha1: SHA1Digest.new,
  '1.2.840.113549.2.8': SHA224Digest.new,
  '1.2.840.113549.2.9': SHA256Digest.new,
  '1.2.840.113549.2.10': SHA384Digest.new,
  '1.2.840.113549.2.11': SHA512Digest.new,
};

class _Pbes2Cipher {
  const _Pbes2Cipher(this.keyLength, this.engine);
  final int keyLength;
  final BlockCipher Function() engine;
}

const Map<String, _Pbes2Cipher> _pbes2Ciphers = {
  '2.16.840.1.101.3.4.1.2': _Pbes2Cipher(16, AESEngine.new),
  '2.16.840.1.101.3.4.1.22': _Pbes2Cipher(24, AESEngine.new),
  '2.16.840.1.101.3.4.1.42': _Pbes2Cipher(32, AESEngine.new),
  '1.2.840.113549.3.7': _Pbes2Cipher(24, DESedeEngine.new),
};

class _Pkcs12Pbe {
  const _Pkcs12Pbe(this.keyLength, {this.rc2Bits});
  final int keyLength;
  final int? rc2Bits;
}

const Map<String, _Pkcs12Pbe> _pkcs12Pbe = {
  '1.2.840.113549.1.12.1.3': _Pkcs12Pbe(24), // SHA1 + 3-key 3DES-CBC
  '1.2.840.113549.1.12.1.4': _Pkcs12Pbe(16), // SHA1 + 2-key 3DES-CBC
  '1.2.840.113549.1.12.1.5': _Pkcs12Pbe(16, rc2Bits: 128), // RC2-128
  '1.2.840.113549.1.12.1.6': _Pkcs12Pbe(5, rc2Bits: 40), // RC2-40
};

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Minimal BER/DER node.
class _Der {
  _Der(this.tag, this.content, this.encoded);

  /// First identifier octet (class | constructed | number).
  final int tag;

  /// Content octets (for indefinite lengths: without the end-of-contents).
  final Uint8List content;

  /// The complete TLV.
  final Uint8List encoded;

  List<_Der>? _children;

  bool get constructed => tag & 0x20 != 0;

  List<_Der> get children {
    if (!constructed) throw const FormatException('Primitive ASN.1 node');
    return _children ??= _parseAll(content);
  }

  /// OCTET STRING value (primitive, or BER-constructed chunks), or the
  /// content of an implicitly tagged octet string.
  Uint8List get octets {
    if (!constructed) return content;
    final out = BytesBuilder(copy: false);
    for (final c in children) {
      out.add(c.octets);
    }
    return out.toBytes();
  }

  String get oid {
    if (tag != 0x06) throw const FormatException('Not an OID');
    final c = content;
    if (c.isEmpty) throw const FormatException('Empty OID');
    final parts = <int>[];
    var value = 0;
    for (var i = 0; i < c.length; i++) {
      value = (value << 7) | (c[i] & 0x7f);
      if (c[i] & 0x80 == 0) {
        if (parts.isEmpty) {
          final first = value < 80 ? value ~/ 40 : 2;
          parts
            ..add(first)
            ..add(value - first * 40);
        } else {
          parts.add(value);
        }
        value = 0;
      }
    }
    return parts.join('.');
  }

  int get intValue {
    if (tag != 0x02) throw const FormatException('Not an INTEGER');
    var v = 0;
    for (final b in content) {
      v = (v << 8) | b;
    }
    return v;
  }

  String get stringValue {
    switch (tag) {
      case 0x1E: // BMPString
        final units = <int>[];
        for (var i = 0; i + 1 < content.length; i += 2) {
          units.add((content[i] << 8) | content[i + 1]);
        }
        return String.fromCharCodes(units);
      case 0x0C: // UTF8String
        return utf8.decode(content, allowMalformed: true);
      default: // Printable, IA5, T61, …
        return latin1.decode(content, allowInvalid: true);
    }
  }

  static _Der parse(Uint8List data) {
    final (node, _) = _read(data, 0);
    return node;
  }

  static List<_Der> _parseAll(Uint8List data) {
    final out = <_Der>[];
    var offset = 0;
    while (offset < data.length) {
      final (node, next) = _read(data, offset);
      out.add(node);
      offset = next;
    }
    return out;
  }

  static (_Der, int) _read(Uint8List data, int start) {
    var i = start;
    if (i >= data.length) throw const FormatException('Truncated ASN.1');
    final tag = data[i++];
    if (tag & 0x1f == 0x1f) {
      // High tag number form: skip the subsequent octets.
      while (i < data.length && data[i] & 0x80 != 0) {
        i++;
      }
      i++;
    }
    if (i >= data.length) throw const FormatException('Truncated ASN.1');
    final first = data[i++];
    if (first == 0x80) {
      // Indefinite length: children until end-of-contents (00 00).
      final contentStart = i;
      while (true) {
        if (i + 1 >= data.length) {
          throw const FormatException('Unterminated indefinite length');
        }
        if (data[i] == 0 && data[i + 1] == 0) break;
        final (_, next) = _read(data, i);
        i = next;
      }
      final content = Uint8List.sublistView(data, contentStart, i);
      final end = i + 2;
      return (_Der(tag, content, Uint8List.sublistView(data, start, end)), end);
    }
    var length = first;
    if (first & 0x80 != 0) {
      final n = first & 0x7f;
      if (n > 4 || i + n > data.length) {
        throw const FormatException('Bad ASN.1 length');
      }
      length = 0;
      for (var k = 0; k < n; k++) {
        length = (length << 8) | data[i++];
      }
    }
    final end = i + length;
    if (end > data.length) throw const FormatException('Truncated ASN.1');
    return (
      _Der(
        tag,
        Uint8List.sublistView(data, i, end),
        Uint8List.sublistView(data, start, end),
      ),
      end,
    );
  }
}
