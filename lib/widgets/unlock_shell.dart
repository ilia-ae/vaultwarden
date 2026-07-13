import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../demo_fixtures.dart';
import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../providers/service_providers.dart';
import '../providers/session_provider.dart';
import '../utils/error_formatter.dart';

/// The Face ID reveal: while locked, a full-screen frosted layer (sigma 44
/// + scrim + lock UI) covers a content-shaped SKELETON — never real data,
/// so nothing sensitive enters memory before unlock. On success the real
/// screen mounts UNDER the still-opaque blur (the swap is invisible at
/// sigma 44) and the glass "evaporates" over ~700ms on a critically-damped
/// spring. Going to background snaps the blur back instantly — this IS the
/// privacy screen, one mechanism.
class UnlockShell extends StatefulWidget {
  const UnlockShell({super.key, required this.locked, required this.child});

  final bool locked;
  final Widget child;

  @override
  State<UnlockShell> createState() => _UnlockShellState();
}

class _UnlockShellState extends State<UnlockShell>
    with SingleTickerProviderStateMixin {
  // 1 = fully locked (blur + scrim + lock UI), 0 = revealed.
  late final AnimationController _veil =
      AnimationController(vsync: this, value: widget.locked ? 1 : 0);

  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 90, // settles in ~0.7s
    ratio: 1, // critically damped — blur can't overshoot below zero
  );

  bool get _veilVisible => widget.locked || _veil.value > 0.001;

  @override
  void didUpdateWidget(UnlockShell old) {
    super.didUpdateWidget(old);
    if (old.locked == widget.locked) return;
    if (widget.locked) {
      // Relock (background / timeout): privacy demands NO animation.
      _veil.stop();
      _veil.value = 1;
    } else {
      HapticFeedback.lightImpact(); // unlock success
      if (MediaQuery.disableAnimationsOf(context)) {
        _veil.value = 0; // Reduce Motion: instant reveal
      } else {
        // Unlock: real content just mounted under full blur — evaporate.
        _veil.animateWith(SpringSimulation(_spring, _veil.value, 0, 0));
      }
    }
  }

  @override
  void dispose() {
    _veil.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _veil,
          builder: (context, _) {
            if (!_veilVisible) return const SizedBox.shrink();
            final t = _veil.value.clamp(0.0, 1.0);
            final dark = Theme.of(context).brightness == Brightness.dark;
            return IgnorePointer(
              ignoring: !widget.locked,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 44 * t, sigmaY: 44 * t),
                  child: Container(
                    color: (dark ? Colors.black : Colors.white)
                        .withValues(alpha: (dark ? 0.35 : 0.45) * t),
                    child: Opacity(
                      opacity: t,
                      child: Transform.scale(
                        // Lock UI shrinks to 0.8 while dissolving.
                        scale: 0.8 + 0.2 * t,
                        child: _LockOverlay(active: widget.locked),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Content-shaped placeholder rendered UNDER the veil while locked.
/// Deliberately data-free and cheap: it sits behind sigma-44 blur, so
/// rough silhouettes are enough — no providers, no API, no secrets.
class LockSkeleton extends StatelessWidget {
  const LockSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final blob = dark ? Colors.white : Colors.black;
    Widget bar(double w, double h, [double r = 8]) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: blob.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(r),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: bar(180, 22, 11)),
              const SizedBox(height: 28),
              for (var i = 0; i < 3; i++) ...[
                ContentCard(
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          bar(36, 36, 18),
                          const SizedBox(width: 12),
                          bar(140, 16),
                          const Spacer(),
                          bar(48, 12),
                        ],
                      ),
                      const SizedBox(height: 14),
                      bar(double.infinity, 12),
                      const SizedBox(height: 8),
                      bar(200, 12),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The lock UI + biometric logic (ported intact from the old LockScreen:
/// delayed auto-prompt, NotInteractive retry, unavailable fallback).
/// Failure plays the Apple-style horizontal shake: 3 oscillations, 8px,
/// decaying.
class _LockOverlay extends ConsumerStatefulWidget {
  const _LockOverlay({required this.active});

  /// False while the reveal animation plays — suppresses interaction.
  final bool active;

  @override
  ConsumerState<_LockOverlay> createState() => _LockOverlayState();
}

class _LockOverlayState extends ConsumerState<_LockOverlay>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _authenticating = false;
  bool _biometricUnavailable = false;
  bool _pendingUnlock = false;

  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDemoMode) return; // screenshots capture the lock UI itself
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only prompt biometrics when iOS confirms the app is fully active;
      // calling earlier triggers "User interaction required".
      if (WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed) {
        _tryUnlock();
      } else {
        _pendingUnlock = true;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shake.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingUnlock) {
      _pendingUnlock = false;
      // Small safety margin for iOS to fully settle its UI stack.
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && widget.active) _tryUnlock();
      });
    }
  }

  bool _isNotInteractiveError(Object e) =>
      e is PlatformException &&
      e.code == 'NotAvailable' &&
      (e.details?.toString().contains('LocalAuthentication') ?? false);

  Future<void> _tryUnlock() async {
    if (_authenticating || !widget.active) return;
    _authenticating = true;
    try {
      final biometric = ref.read(biometricServiceProvider);
      final available = await biometric.isAvailable();
      if (!available) {
        final existingKey = ref.read(userKeyProvider);
        if (existingKey != null) {
          ref.read(isLockedProvider.notifier).state = false;
          return;
        }
        if (mounted) setState(() => _biometricUnavailable = true);
        return;
      }
      if (mounted) setState(() => _biometricUnavailable = false);

      // Retry once if iOS reports "not interactive" (UI not yet ready).
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await ref.read(sessionProvider.notifier).unlockWithBiometrics();
          break;
        } catch (e) {
          if (attempt == 0 && _isNotInteractiveError(e)) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!mounted) return;
            continue;
          }
          rethrow;
        }
      }
      // Guard: if lock() zeroed the key mid-auth, do not unlock.
      if (mounted && ref.read(userKeyProvider) != null) {
        ref.read(isLockedProvider.notifier).state = false;
      }
    } catch (e) {
      final msg = e.toString();
      final userCancelled =
          msg.contains('UserCancelled') || msg.contains('PasscodeNotSet');
      if (mounted && !userCancelled) {
        _shake.forward(from: 0); // Apple-style refusal
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.unlockFailedMessage(formatError(e, l)))),
        );
      }
    } finally {
      _authenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final s = _shake.value;
        // 3 decaying oscillations, 8px amplitude.
        final dx = 8 * math.sin(s * 3 * 2 * math.pi) * (1 - s);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _biometricUnavailable
                    ? Icons.fingerprint_outlined
                    : Icons.lock_outlined,
                size: 64,
                color: _biometricUnavailable
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                _biometricUnavailable ? l.biometricUnavailable : l.locked,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              Semantics(
                identifier: 'btn_unlock',
                child: FilledButton.icon(
                  onPressed: _tryUnlock,
                  icon: Icon(_biometricUnavailable
                      ? Icons.refresh
                      : Icons.fingerprint),
                  label: Text(
                      _biometricUnavailable ? l.biometricRetry : l.unlock),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
