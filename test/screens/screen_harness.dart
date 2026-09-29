import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/services/biometric_service.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/widgets/client_cert_section.dart';

/// Biometrics that are always available (setup refuses to run without).
class FakeBiometrics extends Fake implements BiometricService {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate({
    String reason = 'Authenticate to access Vault Approver',
  }) async =>
      true;
}

/// In-memory certificate store with the real service's error contract:
/// [badFile] bytes are not PKCS#12, [goodPassword] unlocks everything else.
class FakeClientCertService extends Fake implements ClientCertService {
  FakeClientCertService({this.issuedInfo});

  static final badFile = Uint8List.fromList([1, 2, 3, 4]);
  static const goodPassword = 'secret';

  /// Info returned for a successful import.
  final ClientCertificateInfo? issuedInfo;

  final stored = <String, ClientCertificateInfo>{};
  final imports = <String>[];
  final removals = <String>[];
  final _changes = StreamController<String>.broadcast();

  @override
  Stream<String> get changes => _changes.stream;

  @override
  Future<ClientCertificateInfo?> info(String url) async =>
      stored[ClientCertService.originOf(url)];

  @override
  Future<ClientCertificateInfo> importCertificate({
    required String serverUrl,
    required Uint8List pkcs12,
    required String password,
  }) async {
    imports.add(serverUrl);
    if (pkcs12.length == badFile.length &&
        List.generate(4, (i) => pkcs12[i] == badFile[i]).every((b) => b)) {
      throw const ClientCertUnsupportedFormatException('not PKCS#12');
    }
    if (password != goodPassword) throw const ClientCertBadPasswordException();
    final info = issuedInfo ??
        ClientCertificateInfo(
          subject: 'CN=ilia-android, O=ilia.ae',
          commonName: 'ilia-android',
          issuer: 'CN=ilia.ae mTLS CA, O=ilia.ae',
          notAfter: DateTime.now().toUtc().add(const Duration(days: 365)),
          certificateCount: 2,
        );
    final origin = ClientCertService.originOf(serverUrl);
    stored[origin] = info;
    _changes.add(origin);
    return info;
  }

  @override
  Future<void> remove(String url) async {
    final origin = ClientCertService.originOf(url);
    removals.add(origin);
    stored.remove(origin);
    _changes.add(origin);
  }
}

/// A picker that returns [file] (or null = cancelled) and counts calls.
class FakePicker {
  FakePicker(this.file);

  PickedCertificateFile? file;
  int calls = 0;

  Future<PickedCertificateFile?> call() async {
    calls++;
    final f = file;
    // The widget wipes the bytes after an import: hand out a copy.
    return f == null
        ? null
        : PickedCertificateFile(
            name: f.name,
            bytes: Uint8List.fromList(f.bytes),
          );
  }
}

/// MaterialApp with the app's localizations around [home].
Widget testApp(
  ProviderContainer container,
  Widget home, {
  Locale locale = const Locale('en'),
}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

AppLocalizations en() => lookupAppLocalizations(const Locale('en'));
