import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app.dart';
import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../providers/auth_requests_provider.dart';
import '../providers/session_provider.dart';
import '../services/settings_sync.dart';
import '../utils/error_formatter.dart';
import '../widgets/auth_request_card.dart';
import '../widgets/glass_top_bar.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start polling + aggressive refresh on unlock.
    ref.read(authRequestsProvider.notifier).resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ref.read(authRequestsProvider.notifier).pause();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(authRequestsProvider.notifier).resume();
    }
  }

  Future<void> _approve(String requestId) async {
    setState(() => _loadingRequestId = requestId);
    try {
      final requests = ref.read(authRequestsProvider).value ?? [];
      final request = requests.firstWhere((r) => r.id == requestId);
      await ref.read(authRequestsProvider.notifier).approve(request);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.requestApproved)),
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
        title: l.authRequestsTitle,
        controller: _tabController,
        tabs: [l.pendingTab, l.historyTab],
        tabIdentifiers: const ['tab_pending', 'tab_history'],
        actions: [
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
      body: TabBarView(
        controller: _tabController,
        children: [
          _PendingTab(
            loadingRequestId: _loadingRequestId,
            onApprove: _approve,
            onDeny: _deny,
          ),
          const _HistoryTab(),
        ],
      ),
    );
  }
}

class _PendingTab extends ConsumerWidget {
  final String? loadingRequestId;
  final Future<void> Function(String) onApprove;
  final Future<void> Function(String) onDeny;

  const _PendingTab({
    required this.loadingRequestId,
    required this.onApprove,
    required this.onDeny,
  });

  /// Check last history entry for this IP: true=approved, false=denied, null=unknown.
  bool? _ipTrustStatus(String ip, List<HistoryEntry> history) {
    for (final entry in history) {
      if (entry.ipAddress == ip) return entry.approved;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(authRequestsProvider);
    final history = ref.watch(historyProvider);

    return requestsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) {
        final l = AppLocalizations.of(context)!;
        final isNetwork = isNetworkError(error);
        final isAuth = isAuthError(error);

        return RefreshIndicator(
          onRefresh: () =>
              ref.read(authRequestsProvider.notifier).refresh(),
          child: ListView(
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.6,
                child: Center(
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
                          isNetwork
                              ? l.errorNoConnection
                              : formatError(error, l),
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        if (isNetwork) ...[
                          const SizedBox(height: 8),
                          Text(
                            l.errorNoConnectionSubtitle,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
              ),
            ],
          ),
        );
      },
      data: (requests) {
        if (requests.isEmpty) {
          return RefreshIndicator(
            onRefresh: () =>
                ref.read(authRequestsProvider.notifier).refresh(),
            child: ListView(
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 64,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
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
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          // Body extends behind the glass bar; start the spinner below it.
          edgeOffset: MediaQuery.of(context).padding.top,
          onRefresh: () =>
              ref.read(authRequestsProvider.notifier).refresh(),
          child: ListView.builder(
            padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8, bottom: 16),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              return AuthRequestCard(
                request: request,
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

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

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
      return Center(
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

    // history.length items + 1 "Clear All" footer
    return ListView.builder(
      padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8, bottom: 32),
      itemCount: history.length + 1,
      itemBuilder: (context, index) {
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
        final responseStr = responseSeconds < 60
            ? '${responseSeconds}s'
            : '${entry.responseTime.inMinutes}m ${responseSeconds % 60}s';

        return Dismissible(
          key: ValueKey(entry.requestId + entry.respondedAt.toIso8601String()),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                        entry.approved ? AppLocalizations.of(context)!.approved : AppLocalizations.of(context)!.denied,
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
                  Row(
                    children: [
                      Icon(Icons.devices, size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(entry.deviceType, style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 16),
                      Icon(Icons.language, size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(entry.ipAddress, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.timer_outlined, size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
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
                        Icon(Icons.fingerprint, size: 16,
                            color: theme.colorScheme.onSurfaceVariant),
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

  static List<({int value, String label})> _timeoutOptions(AppLocalizations l) => [
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
      padding: const EdgeInsets.symmetric(vertical: 16),
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

            // Theme
            _sectionHeader(theme, l.themeSection),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: const Icon(Icons.brightness_auto, size: 18),
                    label: Text(l.themeAuto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: const Icon(Icons.light_mode, size: 18),
                    label: Text(l.themeLight),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: const Icon(Icons.dark_mode, size: 18),
                    label: Text(l.themeDark),
                  ),
                ],
                selected: {currentTheme},
                onSelectionChanged: (v) {
                  ref.read(themeModeProvider.notifier).state = v.first;
                },
              ),
            ),
            const SizedBox(height: 20),

            // Language
            _sectionHeader(theme, l.languageSection),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (value, label) in <(Locale?, String)>[
                    (null, l.languageSystem),
                    (const Locale('en'), 'English'),
                    (const Locale('ru'), 'Русский'),
                    (const Locale('ar'), 'العربية'),
                    (const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'), '简体中文'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: currentLocale == value,
                      onSelected: (_) =>
                          ref.read(localeProvider.notifier).state = value,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Lock timeout
            _sectionHeader(theme, l.lockTimeoutSection),
            const SizedBox(height: 4),
            _buildOptionChips<int>(
              context: context,
              options: _timeoutOptions(l),
              selected: currentTimeout,
              onSelected: (v) =>
                  ref.read(lockTimeoutProvider.notifier).state = v,
            ),
            const SizedBox(height: 20),

            // Poll interval
            _sectionHeader(theme, l.autoRefreshSection),
            const SizedBox(height: 4),
            _buildOptionChips<int>(
              context: context,
              options: _pollOptions(l),
              selected: currentPoll,
              onSelected: (v) =>
                  ref.read(pollIntervalProvider.notifier).state = v,
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

  // ── Cloud sync (Firebase) account section ──
  // TODO(l10n): strings here are inline English pending translation once the
  // feature is verified end-to-end (needs the Google provider enabled).

  Widget _accountSection(BuildContext context, WidgetRef ref, ThemeData theme) {
    final authState = ref.watch(authStateProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        _sectionHeader(theme, 'Cloud sync'),
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
            'Sign in to sync your settings (theme, language, timers) across '
            'your devices. Your vault keys never leave this device.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _handleSignIn(
                  context, () => ref.read(authServiceProvider).signInWithGoogle()),
              icon: const Icon(Icons.login, size: 18),
              label: const Text('Continue with Google'),
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
                label: const Text('Continue with Apple'),
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
              Icon(Icons.cloud_done, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  user.email ?? user.displayName ?? 'Signed in',
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Settings sync across your devices.',
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
                label: const Text('Connect Apple'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => ref.read(authServiceProvider).signOut(),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out of sync'),
            ),
          ),
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
        _showResultDialog(context, 'Signed in ✓', 'Settings will sync now.');
      }
    } catch (e) {
      if (context.mounted) {
        _showResultDialog(context, 'Sign-in result', e.toString());
      }
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
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildOptionChips<T>({
    required BuildContext context,
    required List<({T value, String label})> options,
    required T selected,
    required ValueChanged<T> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: options.map((opt) {
          final isSelected = opt.value == selected;
          return ChoiceChip(
            label: Text(opt.label),
            selected: isSelected,
            onSelected: (_) => onSelected(opt.value),
          );
        }).toList(),
      ),
    );
  }
}
