import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/widgets/client_cert_section.dart';

import '../screens/screen_harness.dart';

const _server = 'https://vault-test.example.org:2053';
const _origin = 'https://vault-test.example.org:2053';

final _goodFile = PickedCertificateFile(
  name: 'ilia-android.p12',
  bytes: Uint8List.fromList(List.generate(64, (i) => i)),
);
final _badFile = PickedCertificateFile(
  name: 'notes.pfx',
  bytes: FakeClientCertService.badFile,
);

Future<(FakeClientCertService, FakePicker, ProviderContainer)> _pump(
  WidgetTester tester, {
  String? serverUrl = _server,
  FakeClientCertService? certs,
  PickedCertificateFile? file,
}) async {
  final service = certs ?? FakeClientCertService();
  final picker = FakePicker(file);
  final container = ProviderContainer(overrides: [
    clientCertServiceProvider.overrideWithValue(service),
    certificateFilePickerProvider.overrideWithValue(picker.call),
  ]);
  await tester.pumpWidget(testApp(
    container,
    Scaffold(
      body: SingleChildScrollView(
        child: ClientCertificateSection(serverUrl: serverUrl),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (service, picker, container);
}

Future<void> _enterPassword(WidgetTester tester, String password) async {
  final l = en();
  await tester.enterText(
    find.widgetWithText(TextField, l.clientCertPasswordLabel),
    password,
  );
  await tester.tap(find.text(l.clientCertImportAction));
  await tester.pumpAndSettle();
}

void main() {
  final l = en();

  testWidgets('without a server URL the import is disabled', (tester) async {
    final (_, picker, c) = await _pump(tester, serverUrl: 'https://');
    expect(find.text(l.clientCertNeedsUrl), findsOneWidget);
    await tester.tap(find.text(l.clientCertImport), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(picker.calls, 0);
    c.dispose();
  });

  testWidgets('not a PKCS#12 file: inline error, nothing stored (F1)',
      (tester) async {
    final (certs, picker, c) = await _pump(tester, file: _badFile);
    expect(find.text(l.clientCertNone), findsOneWidget);

    await tester.tap(find.text(l.clientCertImport));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(find.text(l.clientCertPasswordTitle), findsOneWidget);
    expect(find.text(l.clientCertPasswordPrompt('notes.pfx')), findsOneWidget);

    await _enterPassword(tester, 'whatever');
    expect(find.text(l.errorClientCertUnsupported), findsOneWidget);
    expect(find.text(l.clientCertPasswordTitle), findsOneWidget,
        reason: 'the dialog stays open');
    expect(certs.stored, isEmpty);

    await tester.tap(find.text(l.cancel));
    await tester.pumpAndSettle();
    expect(find.text(l.clientCertNone), findsOneWidget);
    c.dispose();
  });

  testWidgets('wrong password: inline error, retry with the right one',
      (tester) async {
    final (certs, _, c) = await _pump(tester, file: _goodFile);
    await tester.tap(find.text(l.clientCertImport));
    await tester.pumpAndSettle();

    await _enterPassword(tester, 'wrong');
    expect(find.text(l.errorClientCertBadPassword), findsOneWidget);
    expect(certs.stored, isEmpty);

    await _enterPassword(tester, FakeClientCertService.goodPassword);
    expect(find.text(l.clientCertPasswordTitle), findsNothing);
    expect(certs.stored.keys, [_origin]);
    // Subject, issuer and expiry of the leaf are shown (A14).
    expect(find.text('ilia-android'), findsOneWidget);
    expect(find.text(l.clientCertIssuedBy('ilia.ae mTLS CA')), findsOneWidget);
    expect(find.textContaining('Valid until'), findsOneWidget);
    expect(find.text(l.clientCertReplace), findsOneWidget);
    expect(find.text(l.clientCertImported), findsOneWidget);
    c.dispose();
  });

  testWidgets(
      'a picker that hands over an unmodifiable buffer still imports (B1)',
      (tester) async {
    // file_selector on Android returns the platform channel's unmodifiable
    // view; zeroing it used to throw after the dialog closed, so the success
    // message and onChanged never ran.
    final file = PickedCertificateFile(
      name: 'ilia-android.p12',
      bytes: _goodFile.bytes.asUnmodifiableView(),
    );
    final (certs, _, c) = await _pump(tester, file: file);
    await tester.tap(find.text(l.clientCertImport));
    await tester.pumpAndSettle();

    await _enterPassword(tester, FakeClientCertService.goodPassword);
    expect(tester.takeException(), isNull);
    expect(certs.stored.keys, [_origin]);
    expect(find.text(l.clientCertImported), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()));
    c.dispose();
  });

  test('readCertificateFile copies the picked bytes into a wipeable buffer',
      () async {
    final source = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final picked = await readCertificateFile(
      XFile.fromData(source.asUnmodifiableView(), name: 'a.p12', path: 'a.p12'),
    );
    expect(picked.name, 'a.p12');
    expect(picked.bytes, source);
    wipeCertificateBytes(picked.bytes);
    expect(picked.bytes.every((b) => b == 0), isTrue);
    // The caller's buffer is untouched.
    expect(source.first, 1);
  });

  test('wipeCertificateBytes tolerates an unmodifiable view', () {
    final view = Uint8List.fromList([1, 2, 3]).asUnmodifiableView();
    expect(() => wipeCertificateBytes(view), returnsNormally);
  });

  test('readCertificateFile refuses files over the size limit', () async {
    final big = Uint8List(kMaxCertificateFileBytes + 1);
    await expectLater(
      readCertificateFile(XFile.fromData(big, name: 'big.p12')),
      throwsA(isA<ClientCertUnsupportedFormatException>()),
    );
  });

  testWidgets('a certificate expiring within 30 days is flagged (A14)',
      (tester) async {
    final certs = FakeClientCertService();
    certs.stored[_origin] = ClientCertificateInfo(
      commonName: 'ilia-ios',
      notAfter: DateTime.now().toUtc().add(const Duration(days: 10, hours: 1)),
    );
    final (_, _, c) = await _pump(tester, certs: certs);
    expect(find.text('ilia-ios'), findsOneWidget);
    expect(find.textContaining('Expires in 10 d'), findsOneWidget);
    c.dispose();
  });

  testWidgets('an expired certificate is flagged', (tester) async {
    final certs = FakeClientCertService();
    certs.stored[_origin] = ClientCertificateInfo(
      commonName: 'old',
      notAfter: DateTime.now().toUtc().subtract(const Duration(days: 2)),
    );
    final (_, _, c) = await _pump(tester, certs: certs);
    expect(find.textContaining('Expired on'), findsOneWidget);
    c.dispose();
  });

  testWidgets('re-import replaces, remove asks first (A14)', (tester) async {
    final certs = FakeClientCertService();
    certs.stored[_origin] = const ClientCertificateInfo(commonName: 'old');
    final (_, picker, c) = await _pump(tester, certs: certs, file: _goodFile);
    expect(find.text('old'), findsOneWidget);

    await tester.tap(find.text(l.clientCertReplace));
    await tester.pumpAndSettle();
    await _enterPassword(tester, FakeClientCertService.goodPassword);
    expect(picker.calls, 1);
    expect(find.text('ilia-android'), findsOneWidget);

    await tester.tap(find.text(l.clientCertRemove));
    await tester.pumpAndSettle();
    expect(find.text(l.clientCertRemoveTitle), findsOneWidget);
    await tester.tap(find.text(l.cancel));
    await tester.pumpAndSettle();
    expect(certs.removals, isEmpty);

    await tester.tap(find.text(l.clientCertRemove));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.clientCertRemove));
    await tester.pumpAndSettle();
    expect(certs.removals, [_origin]);
    expect(find.text(l.clientCertNone), findsOneWidget);
    c.dispose();
  });

  testWidgets('inside the Settings sheet, errors are visible in the card',
      (tester) async {
    final container = ProviderContainer(overrides: [
      clientCertServiceProvider.overrideWithValue(FakeClientCertService()),
      certificateFilePickerProvider
          .overrideWithValue(() async => throw Exception('no provider')),
    ]);
    await tester.pumpWidget(testApp(
      container,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const SizedBox(
                  height: 500,
                  child: SingleChildScrollView(
                    child: ClientCertificateSection(serverUrl: _server),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.clientCertImport));
    await tester.pumpAndSettle();

    final message = find.text(l.clientCertPickFailed);
    expect(message, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final hit = tester.hitTestOnBinding(tester.getCenter(message));
    expect(
        hit.path.any((e) => identical(e.target, tester.renderObject(message))),
        isTrue);
    container.dispose();
  });

  testWidgets('card padding follows the text direction (RTL)', (tester) async {
    final container = ProviderContainer(overrides: [
      clientCertServiceProvider.overrideWithValue(FakeClientCertService()),
    ]);
    await tester.pumpWidget(testApp(
      container,
      const Scaffold(
        body: SingleChildScrollView(
          child: ClientCertificateSection(serverUrl: _server),
        ),
      ),
      locale: const Locale('ar'),
    ));
    await tester.pumpAndSettle();
    final title = tester.getRect(
        find.text(lookupAppLocalizations(const Locale('ar')).clientCertTitle));
    final icon = tester.getRect(find.byIcon(Icons.badge_outlined));
    final card = tester.getRect(find.byType(ClientCertificateSection));
    // RTL: the icon sits at the start (right) edge, 16 px in like in LTR.
    expect(icon.left, greaterThan(title.right));
    expect(card.right - icon.right, greaterThanOrEqualTo(16));
    container.dispose();
  });

  test('certificateDisplayName', () {
    expect(certificateDisplayName('CN=ilia.ae mTLS CA, O=ilia.ae'),
        'ilia.ae mTLS CA');
    expect(certificateDisplayName('O=x, CN=y'), 'y');
    expect(certificateDisplayName('O=x'), 'O=x');
  });
}
