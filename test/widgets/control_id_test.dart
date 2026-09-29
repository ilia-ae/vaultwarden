import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';
import 'package:vault_approver/widgets/client_cert_section.dart';
import 'package:vault_approver/widgets/control_id.dart';
import 'package:vault_approver/widgets/login_dialogs.dart';

/// Scroll actions do not make an iOS accessibility element on their own.
const _scrollActions = <SemanticsAction>{
  SemanticsAction.scrollUp,
  SemanticsAction.scrollDown,
  SemanticsAction.scrollLeft,
  SemanticsAction.scrollRight,
};

/// Identifiers that iOS would put on a screen-sized element.
///
/// The iOS bridge exposes a node that has children as an accessibility
/// container whose frame is the whole screen; when the node itself is not an
/// element (no label/value/hint, no non-scroll action), XCUITest reports its
/// identifier with that frame, and Maestro taps the screen centre. Merged
/// nodes are sent without children.
List<String> idsOnBareContainers() {
  bool bare(SemanticsNode node) {
    final data = node.getSemanticsData();
    final sendsChildren =
        node.hasChildren && !node.mergeAllDescendantsIntoThisNode;
    final isElement = data.label.isNotEmpty ||
        data.value.isNotEmpty ||
        data.hint.isNotEmpty ||
        SemanticsAction.values
            .any((a) => !_scrollActions.contains(a) && data.hasAction(a));
    return sendsChildren && !isElement;
  }

  return [
    for (final node in find.semantics
        .byPredicate((n) => n.identifier.isNotEmpty)
        .evaluate())
      if (bare(node)) node.identifier,
  ];
}

/// The semantics node that carries [id].
SemanticsNode nodeWithId(String id) =>
    find.semantics.byPredicate((n) => n.identifier == id).evaluate().single;

Widget _app(void Function(BuildContext) open) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester, Widget app) async {
  // An 874-pt iPhone.
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a plain Semantics id around a button is a bare container; '
      'ControlId puts it on the button element', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          Semantics(
            identifier: 'plain',
            child: FilledButton(onPressed: () {}, child: const Text('A')),
          ),
          ControlId(
            'merged',
            child: FilledButton(onPressed: () {}, child: const Text('B')),
          ),
        ]),
      ),
    ));
    expect(idsOnBareContainers(), ['plain']);
    final merged = nodeWithId('merged').getSemanticsData();
    expect(merged.label, 'B');
    expect(merged.hasAction(SemanticsAction.tap), isTrue);
    expect(merged.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets(
      'certificate password dialog: btn_cert_password_import is the '
      'Import button, not the whole dialog', (tester) async {
    final handle = tester.ensureSemantics();
    await _open(
      tester,
      _app((context) => showDialog<void>(
            context: context,
            builder: (_) => CertificatePasswordDialog(
              fileName: 'client.p12',
              onSubmit: (_) async => null,
            ),
          )),
    );
    expect(idsOnBareContainers(), isEmpty);
    final node = nodeWithId('btn_cert_password_import');
    final data = node.getSemanticsData();
    expect(data.label, 'Import');
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(node.rect.size,
        tester.getSize(find.widgetWithText(FilledButton, 'Import')));
    handle.dispose();
  });

  testWidgets('verification code dialog: every control id is on its control',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _open(
      tester,
      _app((context) => showVerificationCodeDialog(
            context,
            kind: VerificationCodeKind.email,
            title: 'Code',
            message: 'Check your e-mail',
            showRemember: true,
            offerAnotherMethod: true,
            onResend: () async => null,
            onSubmit: (_, __) async => const CodeAccepted(),
          )),
    );
    expect(idsOnBareContainers(), isEmpty);
    for (final id in [
      'btn_totp_verify',
      'btn_resend_code',
      'btn_another_method',
      'chk_remember_device',
    ]) {
      final data = nodeWithId(id).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue, reason: id);
      expect(data.label, isNotEmpty, reason: id);
    }
    handle.dispose();
  });

  testWidgets('PIN confirmation dialog: both button ids are on the buttons',
      (tester) async {
    final handle = tester.ensureSemantics();
    final session = PinSession();
    addTearDown(session.dispose);
    await _open(
      tester,
      _app((context) => confirmPinAction(
            context: context,
            session: session,
            tone: PinDialogTone.destructive,
            title: 'Wipe?',
            body: 'Everything goes.',
            confirmLabel: 'Wipe',
            confirmId: 'probe_confirm',
            cancelId: 'probe_cancel',
          )),
    );
    expect(idsOnBareContainers(), isEmpty);
    expect(nodeWithId('probe_confirm').getSemanticsData().label, 'Wipe');
    expect(nodeWithId('probe_cancel').getSemanticsData().label, 'Cancel');
    handle.dispose();
  });
}
