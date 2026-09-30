import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app.dart';
import '../demo_runtime.dart';
import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../models/server_environment.dart';
import '../providers/auth_requests_provider.dart';
import '../providers/session_provider.dart';
import '../services/privacy_service.dart';
import '../services/settings_sync.dart';
import '../utils/error_formatter.dart';
import '../widgets/auth_request_card.dart';
import '../widgets/client_cert_section.dart';
import '../widgets/cloud_account_delete_button.dart';
import '../widgets/device_icon.dart';
import '../widgets/server_selector.dart';
import '../widgets/glass_top_bar.dart';
import '../widgets/option_pills.dart';
import '../widgets/segmented_tabs.dart';
import 'pin/pin_section.dart';

/// What the Vault tab shows, switched by the segmented tabs at its top.
enum VaultView { pending, history }

/// The main screen: a Vault tab (login-with-device requests, with its
/// Pending/History segmented tabs) and the PIN tools tab.
class RequestsScreen extends ConsumerStatefulWidget {
  const RequestsScreen({super.key});

  @override
  ConsumerState<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends ConsumerState<RequestsScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  String? _loadingRequestId;
  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  /// Index of the Vault tab (the requests, first and default).
  static const _vaultTab = 0;

  /// Index of the PIN tools tab (2nd tab, inside the unlock shell).
  static const _pinTab = 1;
  int _tabIndex = _vaultTab;

  /// The Vault tab's segment. Kept here, not in the tab's page, so it survives
  /// a visit to the PIN tab (the page itself is not kept alive); a new
  /// screen (unlock, next launch) starts on Pending.
  VaultView _vaultView = VaultView.pending;

  /// Keeps the Vault picker's state (its gliding droplet) while the list
  /// under it is swapped: Pending and History are different lists, each
  /// with the picker as its first item.
  final _vaultPickerKey = GlobalKey(debugLabel: 'vault_picker');

  /// Whether this screen holds a FLAG_SECURE request for the PIN tab.
  bool _pinSecureHeld = false;
  late final PrivacyService _privacy = ref.read(privacyServiceProvider);

  /// Read once: `ref` must not be used in dispose().
  late final AuthRequestsNotifier _requests =
      ref.read(authRequestsProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController.addListener(_onTabChanged);
    _tabController.animation!.addListener(_onTabChanged);
    // Start polling + refresh burst on unlock (the provider's first build
    // already connected the hub and is fetching — no second connect).
    _requests.resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.animation!.removeListener(_onTabChanged);
    _tabController.removeListener(_onTabChanged);
    // Locked or logged out: stop polling and the WebSocket (R3).
    _requests.pause();
    _tabController.dispose();
    if (_pinSecureHeld) unawaited(_privacy.setSecureScreen(false));
    super.dispose();
  }

  /// Title/actions follow the selected tab; FLAG_SECURE is on while any part
  /// of the PIN tab is on screen (including mid-swipe).
  void _onTabChanged() {
    final index = _tabController.index;
    final pinVisible =
        index == _pinTab || _tabController.animation!.value > _pinTab - 1;
    if (pinVisible != _pinSecureHeld) {
      _pinSecureHeld = pinVisible;
      unawaited(_privacy.setSecureScreen(pinVisible));
      pinTabVisible.value = pinVisible; // leaving the tab wipes it
    }
    if (index != _tabIndex) setState(() => _tabIndex = index);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _requests.pause();
    } else if (state == AppLifecycleState.resumed) {
      _requests.resume();
    }
  }

  Future<void> _approve(String requestId) async {
    HapticFeedback.lightImpact();
    setState(() => _loadingRequestId = requestId);
    try {
      final requests = ref.read(authRequestsProvider).value ?? [];
      final request = requests.firstWhere((r) => r.id == requestId);
      await ref.read(authRequestsProvider.notifier).approve(request);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!.requestApproved)),
        );
      }
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.approveFailedMessage(formatError(e, l))),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingRequestId = null);
    }
  }

  Future<void> _deny(String requestId) async {
    HapticFeedback.lightImpact();
    setState(() => _loadingRequestId = requestId);
    try {
      final requests = ref.read(authRequestsProvider).value ?? [];
      final request = requests.firstWhere((r) => r.id == requestId);
      await ref.read(authRequestsProvider.notifier).deny(request);
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.denyFailedMessage(formatError(e, l))),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingRequestId = null);
    }
  }

  Future<void> _logout() async {
    // The Settings sheet can outlive this screen (session ended meanwhile).
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.logoutTitle),
        content: Text(
          AppLocalizations.of(context)!.logoutConfirmation,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.logout),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(sessionProvider.notifier).logout();
    }
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent, // let the glass show through
      builder: (context) => DraggableScrollableSheet(
        // Open tall enough that all settings are visible without dragging.
        initialChildSize: 0.92,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => GlassContainer(
          clipBehavior: Clip.antiAlias,
          settings: appGlassFor(Theme.of(context).brightness),
          child: _SettingsSheet(
            onLogout: _logout,
            scrollController: scrollController,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      // Content scrolls UNDER the glass bar — the bar refracts it.
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        title: _tabIndex == _pinTab ? l.pinTitle : l.authRequestsTitle,
        controller: _tabController,
        tabs: [l.vaultTab, l.pinTab],
        tabIdentifiers: const ['tab_vault', 'tab_pin'],
        actions: [
          if (_tabIndex != _pinTab)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  ref.read(authRequestsProvider.notifier).refresh(),
            ),
          Semantics(
            identifier: 'btn_open_settings',
            child: IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => _showSettings(),
            ),
          ),
        ],
      ),
      // Demo-only: a '+' to inject fresh incoming requests into the list —
      // only where that list is, Vault › Pending.
      floatingActionButton: demoActive &&
              _tabIndex == _vaultTab &&
              _vaultView == VaultView.pending
          ? Semantics(
              identifier: 'btn_add_demo',
              child: FloatingActionButton(
                heroTag: 'demo_add',
                tooltip: l.demoAddRequest,
                // Neutral: the accent is kept for Approve.
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                onPressed: () =>
                    ref.read(authRequestsProvider.notifier).addDemoRequest(),
                child: const Icon(Icons.add),
              ),
            )
          : null,
      body: TabBarView(
        controller: _tabController,
        children: [
          _VaultTab(
            pickerKey: _vaultPickerKey,
            view: _vaultView,
            onViewChanged: (view) {
              if (view != _vaultView) setState(() => _vaultView = view);
            },
            loadingRequestId: _loadingRequestId,
            onApprove: _approve,
            onDeny: _deny,
          ),
          const PinSection(),
        ],
      ),
    );
  }
}

/// The Vault tab: Pending/History segmented tabs at the top (where the PIN
/// tab has its tool picker, the same control) over the selected list. They
/// scroll with the list, like the PIN picker, so the list still slides under
/// the glass bar.
///
/// Pending shows how many requests can still be answered ("Pending 1"),
/// only while there are any. The count drops by itself when a request's
/// 5-minute window closes (a timer to the next expiry: the demo list keeps
/// expired requests, and the live list only sweeps them a moment later).
class _VaultTab extends ConsumerStatefulWidget {
  const _VaultTab({
    required this.pickerKey,
    required this.view,
    required this.onViewChanged,
    required this.loadingRequestId,
    required this.onApprove,
    required this.onDeny,
  });

  final GlobalKey pickerKey;
  final VaultView view;
  final ValueChanged<VaultView> onViewChanged;
  final String? loadingRequestId;
  final Future<void> Function(String) onApprove;
  final Future<void> Function(String) onDeny;

  @override
  ConsumerState<_VaultTab> createState() => _VaultTabState();
}

class _VaultTabState extends ConsumerState<_VaultTab> {
  Timer? _expiry;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  /// Requests still inside their window; re-arms the rebuild at the next
  /// expiry among them.
  int _actionableCount() {
    final requests = ref.watch(authRequestsProvider).valueOrNull ?? const [];
    final now = ref.read(requestClockProvider)();
    var count = 0;
    Duration? next;
    for (final r in requests) {
      if (!r.isActionableAt(now)) continue;
      count++;
      final left = r.remaining(now);
      if (next == null || left < next) next = left;
    }
    _expiry?.cancel();
    _expiry = next == null
        ? null
        : Timer(next + const Duration(milliseconds: 50), () {
            if (mounted) setState(() {});
          });
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final pending = _actionableCount();
    final picker = SegmentedTabs<VaultView>(
      key: widget.pickerKey,
      segments: [
        (value: VaultView.pending, label: l.pendingTab),
        (value: VaultView.history, label: l.historyTab),
      ],
      counts: {VaultView.pending: pending},
      // The store screenshot flows tap these (they were the tabs' ids).
      identifiers: const ['tab_pending', 'tab_history'],
      selected: widget.view,
      onSelected: widget.onViewChanged,
    );
    return switch (widget.view) {
      VaultView.pending => _PendingView(
          header: picker,
          loadingRequestId: widget.loadingRequestId,
          onApprove: widget.onApprove,
          onDeny: widget.onDeny,
        ),
      VaultView.history => _HistoryView(header: picker),
    };
  }
}

/// Padding of a tab's list. The body extends behind the glass bar, so the
/// top clears the bar; left/right add the safe-area insets (the Dynamic
/// Island / cutout in landscape) under the cards' own 16/20 pt gutters, and
/// the bottom adds the home-indicator inset to [bottom].
EdgeInsets _listPadding(BuildContext context, {required double bottom}) {
  final padding = MediaQuery.paddingOf(context);
  return EdgeInsets.fromLTRB(
    padding.left,
    padding.top + 8,
    padding.right,
    padding.bottom + bottom,
  );
}

/// Room under the last card for the demo '+' FAB: its height (56), the
/// margin the Scaffold keeps below it (16, on top of the home-indicator
/// inset that [_listPadding] adds anyway) and a 16 pt gap above it.
const double _fabClearance = 56 + 16 + 16;

/// The Vault picker as a list's first item. The visible gap from its track
/// to the first card (the picker's own tap margin, this padding and the
/// card's vertical [cardMargin]) is 14 pt, as under the PIN tab's tool
/// picker.
class _ListHeader extends StatelessWidget {
  const _ListHeader(this.header, {required this.cardMargin});

  final Widget header;
  final double cardMargin;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          bottom: math.max(0, 14 - cardMargin - SegmentedTabs.tapMargin),
        ),
        child: header,
      );
}

/// Empty/error/loading placeholder anchored to the exact SCREEN center on
/// both Vault views, under the Vault picker ([header]) at the spot where the
/// lists show them. The body fills the whole scaffold
/// (extendBodyBehindAppBar), so centering in the full viewport height puts
/// the child at the screen's vertical middle — identical on Pending and
/// History, no bar-height offset. Where the middle would run into the picker
/// (landscape, large text) the child sits right below them instead and the
/// placeholder grows. Stays scrollable so pull-to-refresh keeps working.
class _CenteredPlaceholder extends StatelessWidget {
  const _CenteredPlaceholder({required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        // A null padding makes ListView auto-inset MediaQuery.padding.top —
        // which, under extendBodyBehindAppBar, is the app bar + status bar
        // (~150pt). That shoved the centred child well below the screen
        // middle. Zero padding keeps the box at least the viewport height so
        // the child lands on the true screen centre. Side insets only: they
        // keep the text clear of the Dynamic Island / cutout in landscape.
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        children: [
          _HeaderedCenter(
            // Same spot as the lists' first item (see [_listPadding]).
            top: padding.top + 8,
            height: constraints.maxHeight,
            header: header,
            child: child,
          ),
        ],
      ),
    );
  }
}

/// [header] at [top], full width; [child] centred in [height] (the
/// viewport), but never higher than 16 pt under the header. Grows past
/// [height] when the child does not fit there.
class _HeaderedCenter extends MultiChildRenderObjectWidget {
  _HeaderedCenter({
    required this.top,
    required this.height,
    required Widget header,
    required Widget child,
  }) : super(children: [header, child]);

  final double top;
  final double height;

  @override
  _RenderHeaderedCenter createRenderObject(BuildContext context) =>
      _RenderHeaderedCenter(top: top, height: height);

  @override
  void updateRenderObject(
      BuildContext context, _RenderHeaderedCenter renderObject) {
    renderObject
      ..top = top
      ..height = height;
  }
}

class _HeaderedCenterParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderHeaderedCenter extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HeaderedCenterParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HeaderedCenterParentData> {
  _RenderHeaderedCenter({required double top, required double height})
      : _top = top,
        _height = height;

  static const double _gap = 16;

  double _top;
  set top(double value) {
    if (value == _top) return;
    _top = value;
    markNeedsLayout();
  }

  double _height;
  set height(double value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeaderedCenterParentData) {
      child.parentData = _HeaderedCenterParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final header = firstChild!;
    final child = childAfter(header)!;
    header.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    child.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final lowest = _top + header.size.height + _gap;
    final y = math.max((_height - child.size.height) / 2, lowest);
    (header.parentData! as _HeaderedCenterParentData).offset = Offset(0, _top);
    (child.parentData! as _HeaderedCenterParentData).offset =
        Offset((width - child.size.width) / 2, y);
    size = constraints.constrain(
        Size(width, math.max(_height, y + child.size.height + _gap)));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Vault › Pending: the requests waiting for an answer, under [header].
class _PendingView extends ConsumerWidget {
  /// The Vault picker: the list's first item, above every state.
  final Widget header;
  final String? loadingRequestId;
  final Future<void> Function(String) onApprove;
  final Future<void> Function(String) onDeny;

  const _PendingView({
    required this.header,
    required this.loadingRequestId,
    required this.onApprove,
    required this.onDeny,
  });

  /// Check last history entry for this IP: true=approved, false=denied,
  /// null=unknown (always for an empty IP, R5).
  bool? _ipTrustStatus(String ip, List<HistoryEntry> history) =>
      ipTrustStatus(ip, history);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(authRequestsProvider);
    final history = ref.watch(historyProvider);

    return requestsAsync.when(
      loading: () => _CenteredPlaceholder(
        header: header,
        child: const CircularProgressIndicator(),
      ),
      error: (error, _) {
        final l = AppLocalizations.of(context)!;
        final isNetwork = isNetworkError(error);
        final isAuth = isAuthError(error);

        return RefreshIndicator(
          edgeOffset: MediaQuery.of(context).padding.top,
          onRefresh: () => ref.read(authRequestsProvider.notifier).refresh(),
          child: _CenteredPlaceholder(
            header: header,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isNetwork
                        ? Icons.cloud_off_outlined
                        : isAuth
                            ? Icons.lock_clock_outlined
                            : Icons.error_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isNetwork ? l.errorNoConnection : formatError(error, l),
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (isNetwork) ...[
                    const SizedBox(height: 8),
                    Text(
                      l.errorNoConnectionSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    l.pullDownToRefresh,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(authRequestsProvider.notifier).refresh(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l.retry),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      data: (requests) {
        if (requests.isEmpty) {
          return RefreshIndicator(
            edgeOffset: MediaQuery.of(context).padding.top,
            onRefresh: () => ref.read(authRequestsProvider.notifier).refresh(),
            child: _CenteredPlaceholder(
              header: header,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizations.of(context)!.noPendingRequests,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context)!.pullDownToRefresh,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        }

        return RefreshIndicator(
          // Body extends behind the glass bar; start the spinner below it.
          edgeOffset: MediaQuery.of(context).padding.top,
          onRefresh: () => ref.read(authRequestsProvider.notifier).refresh(),
          child: ListView.builder(
            padding: _listPadding(
              context,
              // The demo '+' FAB floats over the list: let the last card
              // scroll clear of it (portrait and landscape).
              bottom: demoActive ? _fabClearance : 16,
            ),
            // The picker first, then the cards.
            itemCount: requests.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _ListHeader(header, cardMargin: 8);
              final request = requests[index - 1];
              return AuthRequestCard(
                request: request,
                clock: ref.read(requestClockProvider),
                isLoading: loadingRequestId == request.id,
                ipTrust: _ipTrustStatus(request.requestIpAddress, history),
                onApprove: () => onApprove(request.id),
                onDeny: () => onDeny(request.id),
              );
            },
          ),
        );
      },
    );
  }
}

/// Vault › History: the answered requests, under [header].
class _HistoryView extends ConsumerWidget {
  const _HistoryView({required this.header});

  /// The Vault picker: the list's first item, above the empty state too.
  final Widget header;

  Future<void> _clearHistory(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(AppLocalizations.of(context)!.clearHistoryTitle),
        content: Text(
          AppLocalizations.of(context)!.clearHistoryConfirmation,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.clear),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final theme = Theme.of(context);

    if (history.isEmpty) {
      return _CenteredPlaceholder(
        header: header,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.noHistoryYet,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.historyEmptySubtitle,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    // The picker, history.length entries, a "Clear All" footer.
    return ListView.builder(
      padding: _listPadding(context, bottom: 32),
      itemCount: history.length + 2,
      itemBuilder: (context, item) {
        if (item == 0) return _ListHeader(header, cardMargin: 6);
        final index = item - 1;
        // Last item = "Clear All" button
        if (index == history.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: () => _clearHistory(context, ref),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(AppLocalizations.of(context)!.clearAll),
            ),
          );
        }

        final entry = history[index];
        final ago = _timeAgo(context, entry.respondedAt);
        final responseSeconds = entry.responseTime.inSeconds;
        final l = AppLocalizations.of(context)!;
        final responseStr = responseSeconds < 60
            ? l.responseTimeSeconds(responseSeconds)
            : l.responseTimeMinutes(
                entry.responseTime.inMinutes, responseSeconds % 60);

        return Dismissible(
          key: ValueKey(entry.requestId + entry.respondedAt.toIso8601String()),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            decoration: ShapeDecoration(
              color: theme.colorScheme.error,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(ContentCard.radius),
              ),
            ),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) {
            ref.read(historyProvider.notifier).removeAt(index);
          },
          child: ContentCard(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      entry.approved ? Icons.check_circle : Icons.cancel,
                      color: entry.approved
                          ? Colors.green
                          : theme.colorScheme.error,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      entry.approved
                          ? AppLocalizations.of(context)!.approved
                          : AppLocalizations.of(context)!.denied,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: entry.approved
                            ? Colors.green
                            : theme.colorScheme.error,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      ago,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Wraps instead of overflowing: a long IPv6 address moves to
                // its own line (and is ellipsized only if even that is short).
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(deviceIconFor(entry.deviceType),
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            entry.deviceType,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.language,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            entry.ipAddress,
                            style: theme.textTheme.bodyMedium,
                            textDirection: TextDirection.ltr,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.timer_outlined,
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      AppLocalizations.of(context)!.respondedIn(responseStr),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (entry.fingerprint != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.fingerprint,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.fingerprint!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _timeAgo(BuildContext context, DateTime dt) {
    final l = AppLocalizations.of(context)!;
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return l.justNow;
    if (diff.inMinutes < 60) return l.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l.hoursAgo(diff.inHours);
    if (diff.inDays < 30) return l.daysAgo(diff.inDays);
    return '${dt.day}.${dt.month}.${dt.year}';
  }
}

class _SettingsSheet extends ConsumerWidget {
  final VoidCallback onLogout;
  final ScrollController scrollController;

  const _SettingsSheet({
    required this.onLogout,
    required this.scrollController,
  });

  static List<({int value, String label})> _timeoutOptions(
          AppLocalizations l) =>
      [
        (value: 0, label: l.timeoutImmediately),
        (value: 15, label: l.timeoutFifteenSeconds),
        (value: 60, label: l.timeoutOneMinute),
        (value: 300, label: l.timeoutFiveMinutes),
        (value: 900, label: l.timeoutFifteenMinutes),
        (value: -1, label: l.timeoutNever),
      ];

  static List<({int value, String label})> _pollOptions(AppLocalizations l) => [
        (value: 5, label: l.pollFiveSeconds),
        (value: 15, label: l.pollFifteenSeconds),
        (value: 30, label: l.pollThirtySeconds),
        (value: 60, label: l.pollOneMinute),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
    final currentTimeout = ref.watch(lockTimeoutProvider);
    final currentTheme = ref.watch(themeModeProvider);
    final currentPoll = ref.watch(pollIntervalProvider);
    final currentLocale = ref.watch(localeProvider);

    return ListView(
      controller: scrollController,
      // The sheet's SafeArea covers top/left/right; the bottom is ours, so
      // Log out never sits under the home indicator.
      padding: EdgeInsets.only(
        top: 16,
        bottom: 16 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        // Handle
        Center(
          child: Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withAlpha(64),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(l.settings, style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: 20),

        // Server (read-only) + client certificate of this server
        ..._serverSection(context, ref, theme, l),

        // Theme
        SectionHeader(l.themeSection),
        const SizedBox(height: 4),
        OptionPills<ThemeMode>(
          options: [
            (value: ThemeMode.system, label: l.themeAuto),
            (value: ThemeMode.light, label: l.themeLight),
            (value: ThemeMode.dark, label: l.themeDark),
          ],
          selected: currentTheme,
          onSelected: (v) => ref.read(themeModeProvider.notifier).state = v,
        ),
        const SizedBox(height: 20),

        // Language
        SectionHeader(l.languageSection),
        const SizedBox(height: 4),
        OptionPills<Locale?>(
          options: appLanguageOptions(l),
          selected: currentLocale,
          onSelected: (v) => ref.read(localeProvider.notifier).state = v,
        ),
        const SizedBox(height: 20),

        // Lock timeout
        SectionHeader(l.lockTimeoutSection),
        const SizedBox(height: 4),
        OptionPills<int>(
          options: _timeoutOptions(l),
          selected: currentTimeout,
          onSelected: (v) => ref.read(lockTimeoutProvider.notifier).state = v,
        ),
        const SizedBox(height: 20),

        // Poll interval
        SectionHeader(l.autoRefreshSection),
        const SizedBox(height: 4),
        OptionPills<int>(
          options: _pollOptions(l),
          selected: currentPoll,
          onSelected: (v) => ref.read(pollIntervalProvider.notifier).state = v,
        ),

        if (firebaseReady) _accountSection(context, ref, theme),

        const Divider(height: 32),

        // Logout
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withAlpha(128)),
              ),
              onPressed: () {
                Navigator.pop(context);
                onLogout();
              },
              icon: const Icon(Icons.logout, size: 18),
              label: Text(l.logout),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ── Server ──

  /// Where this session signs in (read-only) and, for a self-hosted server,
  /// its client certificate (view / replace / remove, F1 + A14). The demo
  /// shows no certificate row: nothing in it may touch the real keychain.
  List<Widget> _serverSection(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    AppLocalizations l,
  ) {
    final session = ref.watch(sessionProvider).valueOrNull;
    if (session == null) return const [];
    ServerEnvironment? env;
    try {
      env = session.environment;
    } on FormatException {
      env = null;
    }
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return [
      SectionHeader(l.serverSection),
      const SizedBox(height: 8),
      Semantics(
        identifier: 'text_server_info',
        container: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                env?.isCloud ?? false
                    ? Icons.cloud_outlined
                    : Icons.dns_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      env == null
                          ? session.serverUrl
                          : serverRegionLabel(env.region, l),
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (env != null) Text(env.baseUrl, style: secondary),
                    Text(l.signedInAs(session.email), style: secondary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      if (env != null && !env.isCloud && !demoActive) ...[
        const SizedBox(height: 12),
        ClientCertificateSection(
          serverUrl: env.baseUrl,
          margin: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ],
      const SizedBox(height: 20),
    ];
  }

  // ── Cloud sync (Firebase) account section ──

  Widget _accountSection(BuildContext context, WidgetRef ref, ThemeData theme) {
    final authState = ref.watch(authStateProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        SectionHeader(AppLocalizations.of(context)!.cloudSyncSection),
        const SizedBox(height: 8),
        authState.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (_, __) => const SizedBox.shrink(),
          data: (user) => user == null
              ? _signedOut(context, ref, theme)
              : _signedIn(context, ref, theme, user),
        ),
      ],
    );
  }

  Widget _signedOut(BuildContext context, WidgetRef ref, ThemeData theme) {
    // Google works on both platforms and is the reliable path. Apple is shown
    // additionally on iOS/macOS (required by App Store rule 4.8 when a
    // third-party login is offered). Sync identity is per-provider, so use the
    // same provider on all your devices for them to stay in sync.
    final isApplePlatform = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context)!.cloudSyncSignedOutHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _handleSignIn(context,
                  () => ref.read(authServiceProvider).signInWithGoogle()),
              icon: const Icon(Icons.login, size: 18),
              label:
                  Text(AppLocalizations.of(context)!.cloudSyncContinueGoogle),
            ),
          ),
          if (isApplePlatform) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _handleSignIn(context,
                    () => ref.read(authServiceProvider).signInWithApple()),
                icon: const Icon(Icons.apple, size: 18),
                label:
                    Text(AppLocalizations.of(context)!.cloudSyncContinueApple),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _signedIn(
      BuildContext context, WidgetRef ref, ThemeData theme, User user) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_done,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  user.email ??
                      user.displayName ??
                      AppLocalizations.of(context)!.cloudSyncSignedIn,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            AppLocalizations.of(context)!.cloudSyncSignedInHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          // Offer linking the platform-native provider to THIS account, so the
          // user can sign in either way later while keeping one uid (and one
          // synced settings document).
          if ((defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS) &&
              !user.providerData.any((p) => p.providerId == 'apple.com')) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _handleSignIn(context,
                    () => ref.read(authServiceProvider).signInWithApple()),
                icon: const Icon(Icons.apple, size: 18),
                label:
                    Text(AppLocalizations.of(context)!.cloudSyncConnectApple),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => ref.read(authServiceProvider).signOut(),
              icon: const Icon(Icons.logout, size: 18),
              label: Text(AppLocalizations.of(context)!.cloudSyncSignOut),
            ),
          ),
          const SizedBox(height: 4),
          const CloudAccountDeleteButton(),
        ],
      ),
    );
  }

  Future<void> _handleSignIn(
      BuildContext context, Future<Object?> Function() action) async {
    // Diagnostic: show the real outcome in a persistent dialog (SnackBars
    // vanish and debugPrint is a no-op in profile/release builds). A 30s
    // timeout surfaces a hung Firebase credential exchange as an error.
    try {
      await action().timeout(const Duration(seconds: 30));
      if (context.mounted) {
        final l = AppLocalizations.of(context)!;
        _showResultDialog(context, l.cloudSyncSignInSuccessTitle,
            l.cloudSyncSignInSuccessBody);
      }
    } catch (e) {
      if (!context.mounted) return;
      final l = AppLocalizations.of(context)!;
      final message = describeCloudSyncError(e, l);
      if (message == null) return; // cancelled: nothing to report
      _showResultDialog(context, l.cloudSyncSignInResultTitle, message);
    }
  }

  void _showResultDialog(BuildContext context, String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx)!.ok),
          ),
        ],
      ),
    );
  }
}
