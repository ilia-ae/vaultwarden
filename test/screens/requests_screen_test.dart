import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/widgets/auth_request_card.dart';
import 'package:vault_approver/widgets/glass_top_bar.dart';
import 'package:vault_approver/widgets/option_pills.dart';
import 'package:vault_approver/widgets/segmented_tabs.dart';

import '../providers/provider_fakes.dart';
import 'screen_harness.dart';

final _l = en();

/// Counts the screen's pause/resume calls (R3).
class _SpyRequests extends AuthRequestsNotifier {
  int pauses = 0;
  int resumes = 0;

  @override
  void pause() {
    pauses++;
    super.pause();
  }

  @override
  void resume() {
    resumes++;
    super.resume();
  }
}

/// A fixed list that is never swept (like the demo's): expired requests
/// stay in it.
class _FixedRequests extends AuthRequestsNotifier {
  _FixedRequests(this.requests);

  final List<AuthRequest> requests;

  @override
  Future<List<AuthRequest>> build() async => requests;

  @override
  void pause() {}

  @override
  void resume() {}
}

Future<(Harness, FakeClientCertService)> _pump(
  WidgetTester tester, {
  String serverUrl = kServer,
  List<Override> overrides = const [],
  void Function(WidgetTester tester)? view,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  view?.call(tester);
  final certs = FakeClientCertService();
  final h = await Harness.create(overrides: [
    clientCertServiceProvider.overrideWithValue(certs),
    ...overrides,
  ]);
  await h.signIn(session: testSession(serverUrl: serverUrl));
  await tester.pumpWidget(testApp(h.container, const RequestsScreen()));
  await tester.pump();
  await tester.pump();
  return (h, certs);
}

Future<void> _finish(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  h.dispose();
}

/// iPhone 18 Pro, 402 × 874 pt (62 pt status bar, 34 pt home indicator).
void _portrait(WidgetTester tester) {
  tester.view.physicalSize = const Size(402 * 3, 874 * 3);
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
}

/// The same phone in landscape: 874 × 402 pt, no top inset.
void _landscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(874 * 3, 402 * 3);
  tester.view.padding =
      const FakeViewPadding(left: 62 * 3, right: 62 * 3, bottom: 21 * 3);
}

HistoryEntry _entry(String id, {required bool approved, String? ip}) =>
    HistoryEntry(
      requestId: id,
      deviceType: 'Chrome',
      ipAddress: ip ?? '10.0.0.30',
      approved: approved,
      respondedAt: DateTime.now(),
      requestCreatedAt: DateTime.now().subtract(const Duration(seconds: 5)),
    );

/// Taps the Vault segment (or top-bar tab) with Semantics identifier [id].
Future<void> _tapId(WidgetTester tester, String id) async {
  await tester.tap(find.bySemanticsIdentifier(id));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

/// The Vault picker's visible track.
Rect _picker(WidgetTester tester) =>
    tester.getRect(find.byKey(SegmentedTabs.trackKey));

/// Whether the Vault segment labelled [label] is the selected one.
bool _pillSelected(WidgetTester tester, String label) {
  final picker = tester
      .widget<SegmentedTabs<VaultView>>(find.byType(SegmentedTabs<VaultView>));
  return picker.segments
          .firstWhere((s) => s.label == label, orElse: () => throw label)
          .value ==
      picker.selected;
}

/// The icon-and-text block of an empty state, found by its title.
Rect _placeholder(WidgetTester tester, String title) => tester.getRect(
    find.ancestor(of: find.text(title), matching: find.byType(Column)).first);

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('settings: self-hosted server with its client certificate',
      (tester) async {
    final (h, certs) = await _pump(tester);
    certs.stored[ClientCertService.originOf(kServer)] = ClientCertificateInfo(
      commonName: 'ilia-android',
      notAfter: DateTime.now().toUtc().add(const Duration(days: 400)),
    );
    await _openSettings(tester);

    expect(find.text(_l.serverSection), findsOneWidget);
    expect(find.text(_l.serverRegionSelfHosted), findsOneWidget);
    expect(find.text(kServer), findsOneWidget);
    expect(find.text(_l.signedInAs(kEmail)), findsOneWidget);
    expect(find.text(_l.clientCertTitle), findsOneWidget);
    expect(find.text('ilia-android'), findsOneWidget);
    expect(find.text(_l.clientCertReplace), findsOneWidget);
    await _finish(tester, h);
  });

  testWidgets('settings: cloud server, no certificate row', (tester) async {
    final (h, _) = await _pump(tester, serverUrl: 'https://vault.bitwarden.eu');
    await _openSettings(tester);
    expect(find.text(_l.serverRegionEu), findsOneWidget);
    expect(find.text('https://vault.bitwarden.eu'), findsOneWidget);
    expect(find.text(_l.clientCertTitle), findsNothing);
    await _finish(tester, h);
  });

  testWidgets('pending card: countdown, trust status from history (A7)',
      (tester) async {
    final (h, _) = await _pump(tester);
    h.api.pending = [
      testRequest('known', ip: '198.51.100.20'),
      testRequest('fresh', ip: '198.51.100.21', fingerprint: null),
    ];
    await h.container.read(historyProvider.notifier).add(HistoryEntry(
          requestId: 'old',
          deviceType: 'Chrome',
          ipAddress: '198.51.100.20',
          approved: true,
          respondedAt: DateTime.now(),
          requestCreatedAt: DateTime.now(),
        ));
    await h.container.read(authRequestsProvider.notifier).refresh();
    await tester.pump();

    expect(find.text(_l.ipTrusted), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d:\d\d left$')), findsNWidgets(2));
    // The request without a fingerprint cannot be approved (A1).
    expect(find.text(_l.fingerprintUnavailable), findsOneWidget);
    await _finish(tester, h);
  });

  testWidgets('settings: shared option pills select and mark the choice',
      (tester) async {
    final (h, _) = await _pump(tester);
    await _openSettings(tester);

    // Theme, language, lock timeout, poll interval: one group each.
    expect(find.byType(OptionPills<ThemeMode>), findsOneWidget);
    expect(find.byType(OptionPills<Locale?>), findsOneWidget);
    for (final title in [
      _l.serverSection,
      _l.themeSection,
      _l.languageSection,
      _l.lockTimeoutSection,
    ]) {
      expect(find.widgetWithText(SectionHeader, title), findsOneWidget);
    }

    bool selected(String label) => tester
        .widget<OptionPill>(find.ancestor(
            of: find.text(label), matching: find.byType(OptionPill)))
        .selected;
    // Dark is the app's default look.
    expect(selected(_l.themeDark), isTrue);
    expect(selected(_l.themeAuto), isFalse);
    // Same semantics as the former private chips: a button with a selected
    // state and no identifier.
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text(_l.themeDark)),
      matchesSemantics(
        label: _l.themeDark,
        isButton: true,
        hasTapAction: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    handle.dispose();

    await tester.tap(find.text(_l.themeLight));
    await tester.pump();
    expect(h.container.read(themeModeProvider), ThemeMode.light);
    expect(selected(_l.themeLight), isTrue);
    expect(selected(_l.themeDark), isFalse);

    final sheet = find
        .descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text(_l.pollThirtySeconds), 200,
        scrollable: sheet);
    expect(find.byType(OptionPills<int>), findsNWidgets(2));
    expect(find.widgetWithText(SectionHeader, _l.autoRefreshSection),
        findsOneWidget);
    await tester.ensureVisible(find.text(_l.timeoutFiveMinutes));
    await tester.tap(find.text(_l.timeoutFiveMinutes));
    await tester.pump();
    expect(h.container.read(lockTimeoutProvider), 300);
    await tester.ensureVisible(find.text(_l.pollThirtySeconds));
    await tester.tap(find.text(_l.pollThirtySeconds));
    await tester.pump();
    expect(h.container.read(pollIntervalProvider), 30);
    await _finish(tester, h);
  });

  testWidgets('settings: Log out clears the home indicator at the sheet end',
      (tester) async {
    final (h, _) = await _pump(tester);
    // An 844-pt iPhone with a 34-pt home indicator.
    tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
    await tester.pump();
    await _openSettings(tester);
    final sheet = find
        .descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text(_l.logout), 200,
        scrollable: sheet);
    // Scrolled to the very end.
    await tester.drag(find.text(_l.logout), const Offset(0, -400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final logout = tester.getRect(find.ancestor(
      of: find.text(_l.logout),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    ));
    expect(logout.bottom, lessThanOrEqualTo(844 - 34 - 16));
    await _finish(tester, h);
  });

  testWidgets('two tabs, Vault first; its segments switch Pending and History',
      (tester) async {
    final (h, _) = await _pump(tester);
    final semantics = tester.ensureSemantics();
    h.api.pending = [testRequest('req-1')];
    await h.container.read(authRequestsProvider.notifier).refresh();
    await h.container
        .read(historyProvider.notifier)
        .add(_entry('old', approved: true));
    await tester.pump();

    final bar = tester.widget<GlassTopBar>(find.byType(GlassTopBar));
    expect(bar.tabs, [_l.vaultTab, _l.pinTab]);
    expect(bar.tabIdentifiers, ['tab_vault', 'tab_pin']);
    expect(bar.controller.length, 2);
    expect(bar.controller.index, 0, reason: 'Vault is the default tab');
    expect(bar.title, _l.authRequestsTitle);
    // The store screenshot flows tap tab_history: it is the History segment
    // now.
    for (final id in ['tab_vault', 'tab_pin', 'tab_pending', 'tab_history']) {
      expect(find.bySemanticsIdentifier(id), findsOneWidget, reason: id);
    }
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('tab_history')),
      matchesSemantics(
        identifier: 'tab_history',
        label: _l.historyTab,
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    expect(
      tester
          .getSemantics(find.bySemanticsIdentifier('tab_pending'))
          .getSemanticsData()
          .role,
      SemanticsRole.tab,
    );

    // Pending by default: the request, not the history.
    expect(find.byType(SegmentedTabs<VaultView>), findsOneWidget);
    expect(_pillSelected(tester, _l.pendingTab), isTrue);
    expect(_pillSelected(tester, _l.historyTab), isFalse);
    expect(find.byType(AuthRequestCard), findsOneWidget);
    expect(find.byType(Dismissible), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await _tapId(tester, 'tab_history');
    expect(_pillSelected(tester, _l.historyTab), isTrue);
    expect(_pillSelected(tester, _l.pendingTab), isFalse);
    expect(find.byType(AuthRequestCard), findsNothing);
    expect(find.byType(Dismissible), findsOneWidget);
    expect(find.text(_l.approved), findsOneWidget);
    expect(find.text(_l.clearAll), findsOneWidget);
    // Still the Vault tab: its title and refresh stay.
    expect(bar.controller.index, 0);
    expect(find.text(_l.authRequestsTitle), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await _tapId(tester, 'tab_pending');
    expect(_pillSelected(tester, _l.pendingTab), isTrue);
    expect(find.byType(AuthRequestCard), findsOneWidget);
    expect(find.byType(Dismissible), findsNothing);
    semantics.dispose();
    await _finish(tester, h);
  });

  testWidgets('Vault picker: the selected segment glides to History',
      (tester) async {
    final (h, _) = await _pump(tester, view: _portrait);
    final picker = find.byType(SegmentedTabs<VaultView>);
    final droplet = find.byKey(SegmentedTabs.thumbKey);
    final state = tester.state(picker);
    final semantics = tester.ensureSemantics();
    int nodeId() =>
        tester.getSemantics(find.bySemanticsIdentifier('tab_history')).id;
    final nodeBefore = nodeId();
    // The selected segment spans its tab's columns, 3 pt inside the track.
    final track = _picker(tester);
    Rect thumbOf(String id) {
      final tab = tester.getRect(find.bySemanticsIdentifier(id));
      return Rect.fromLTRB(tab.left, track.top + SegmentedTabs.inset, tab.right,
          track.bottom - SegmentedTabs.inset);
    }

    final pending = thumbOf('tab_pending');
    final history = thumbOf('tab_history');
    expect(tester.getRect(droplet), rectMoreOrLessEquals(pending));

    await tester.tap(find.bySemanticsIdentifier('tab_history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    // The list under it was swapped, the picker (and its droplet) was kept.
    expect(find.text(_l.noHistoryYet), findsOneWidget);
    expect(tester.state(picker), same(state));
    expect(tester.getRect(droplet).center.dx,
        inExclusiveRange(pending.center.dx, history.center.dx));
    // ...but its tabs are new semantics nodes: iOS mislocates a node that
    // moved to another parent (Maestro's tab_history tap missed).
    expect(nodeId(), isNot(nodeBefore));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getRect(droplet), rectMoreOrLessEquals(history));
    semantics.dispose();
    await _finish(tester, h);
  });

  testWidgets('history: a swipe deletes the swiped entry (picker is item 0)',
      (tester) async {
    final (h, _) = await _pump(tester);
    final history = h.container.read(historyProvider.notifier);
    await history.add(_entry('older', approved: false, ip: '10.0.0.41'));
    await history.add(_entry('newer', approved: true, ip: '10.0.0.42'));
    await _tapId(tester, 'tab_history');
    expect(find.byType(Dismissible), findsNWidgets(2));

    // Swipe the second card (the older, denied one) away.
    await tester.drag(find.text('10.0.0.41'), const Offset(-600, 0));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
        h.container.read(historyProvider).map((e) => e.requestId), ['newer']);
    expect(find.text('10.0.0.41'), findsNothing);
    expect(find.text('10.0.0.42'), findsOneWidget);
    await _finish(tester, h);
  });

  testWidgets('empty states: on the screen centre, under the picker',
      (tester) async {
    final (h, _) = await _pump(tester, view: _portrait);
    await tester.pump();
    // Bar: 62 pt status bar + 100 pt glass bar; the picker 8 pt below it
    // (its track after its tap margin), as the PIN tab's tool picker, full
    // width inside the cards' gutters.
    final picker = _picker(tester);
    expect(
        picker.top,
        62 +
            GlassTopBar.toolbarHeight +
            GlassTopBar.tabsHeight +
            8 +
            SegmentedTabs.tapMargin);
    expect(picker.left, 20);
    expect(picker.right, 402 - 20);
    final pending = _placeholder(tester, _l.noPendingRequests);
    expect(pending.center.dy, moreOrLessEquals(874 / 2));
    expect(pending.center.dx, moreOrLessEquals(402 / 2));

    await _tapId(tester, 'tab_history');
    expect(_picker(tester), picker,
        reason: 'the picker does not move between the two views');
    final history = _placeholder(tester, _l.noHistoryYet);
    expect(history.center.dy, moreOrLessEquals(874 / 2),
        reason: 'same height on Pending and History');
    await _finish(tester, h);
  });

  testWidgets('landscape: an empty state never runs into the picker',
      (tester) async {
    final (h, _) = await _pump(tester, view: _landscape);
    await tester.pump();
    final picker = _picker(tester);
    expect(picker.left, 62 + 20, reason: 'island inset + gutter');
    expect(picker.right, 874 - 62 - 20);
    final pending = _placeholder(tester, _l.noPendingRequests);
    expect(pending.top, greaterThanOrEqualTo(picker.bottom + 16));

    // Pull-to-refresh still works on the empty state.
    final before = h.api.pendingCalls;
    await tester.fling(
        find.text(_l.noPendingRequests), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(h.api.pendingCalls, greaterThan(before));
    await _finish(tester, h);
  });

  testWidgets(
      'Pending counts the requests that can be answered: appears, updates, '
      'disappears', (tester) async {
    final (h, _) = await _pump(tester);
    final semantics = tester.ensureSemantics();
    const nbsp = '\u00A0';
    String pendingLabel() => tester
        .getSemantics(find.bySemanticsIdentifier('tab_pending'))
        .getSemanticsData()
        .label;
    // No requests: no count.
    expect(find.text(_l.pendingTab), findsOneWidget);
    expect(pendingLabel(), _l.pendingTab);

    h.api.pending = [testRequest('req-1')];
    await h.container.read(authRequestsProvider.notifier).refresh();
    await tester.pump();
    expect(find.text('${_l.pendingTab}${nbsp}1'), findsOneWidget);
    expect(pendingLabel(), '${_l.pendingTab}, 1');
    // History carries no count.
    expect(find.text(_l.historyTab), findsOneWidget);

    h.api.pending = [testRequest('req-1'), testRequest('req-2')];
    await h.container.read(authRequestsProvider.notifier).refresh();
    await tester.pump();
    expect(find.text('${_l.pendingTab}${nbsp}2'), findsOneWidget);
    expect(pendingLabel(), '${_l.pendingTab}, 2');
    // The count stays on the picker while History is shown.
    await _tapId(tester, 'tab_history');
    expect(find.text('${_l.pendingTab}${nbsp}2'), findsOneWidget);
    await _tapId(tester, 'tab_pending');

    h.api.pending = [];
    await h.container.read(authRequestsProvider.notifier).refresh();
    await tester.pump();
    expect(find.text(_l.pendingTab), findsOneWidget);
    expect(find.textContaining(nbsp), findsNothing);
    expect(pendingLabel(), _l.pendingTab);
    semantics.dispose();
    await _finish(tester, h);
  });

  testWidgets('the Pending count drops when a request\'s window closes',
      (tester) async {
    // A fixed clock: the requests expire when it moves past their window.
    var now = DateTime.now();
    // A list nobody sweeps (as in the demo): the count must see the expiry
    // by itself.
    final (h, _) = await _pump(tester, overrides: [
      requestClockProvider.overrideWithValue(() => now),
      authRequestsProvider.overrideWith(() => _FixedRequests([
            testRequest('soon', age: const Duration(seconds: 270)),
            testRequest('gone', age: const Duration(minutes: 6)),
          ])),
    ]);
    // The expired request is not counted; the one with 30 s left is.
    expect(find.byType(AuthRequestCard), findsNWidgets(2));
    expect(find.text('${_l.pendingTab}\u00A01'), findsOneWidget);

    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    expect(find.text(_l.pendingTab), findsOneWidget,
        reason: 'the window closed: nothing left to answer');
    await _finish(tester, h);
  });

  testWidgets('dispose pauses the requests notifier (R3)', (tester) async {
    final spy = _SpyRequests();
    final (h, _) = await _pump(tester, overrides: [
      authRequestsProvider.overrideWith(() => spy),
    ]);
    expect(spy.resumes, 1, reason: 'initState resumes polling');
    expect(spy.pauses, 0);

    // Locked or logged out: the screen goes away and polling must stop.
    await tester.pumpWidget(const SizedBox());
    expect(spy.pauses, 1);
    expect(h.hub.pauses, 1, reason: 'the WebSocket is paused too');
    await tester.pump(const Duration(seconds: 1));
    h.dispose();
  });
}
