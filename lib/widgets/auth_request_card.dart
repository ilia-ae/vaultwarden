import 'dart:async';

import 'package:flutter/material.dart';

import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../models/auth_request.dart';
import 'device_icon.dart';
import 'fingerprint_phrase.dart';

/// iOS system green, the "approved before" trust colour.
const kTrustGreen = Color(0xFF34C759);

/// `m:ss` for a countdown (never negative).
String formatCountdown(Duration d) {
  final seconds = d.isNegative ? 0 : d.inSeconds;
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// One pending "Login with device" request.
///
/// * Countdown of the 5-minute window on the server clock (F5): red under a
///   minute; once expired the card says so and Approve is disabled.
/// * No fingerprint phrase (malformed key) → "cannot verify", Approve
///   disabled (A1).
/// * Trust frame from local history plus a text/Semantics status line
///   ("Known IP" / "Denied IP", A7).
class AuthRequestCard extends StatefulWidget {
  final AuthRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  final bool isLoading;

  /// IP trust from history: true=previously approved, false=previously denied, null=unknown.
  final bool? ipTrust;

  /// Local clock (tests pass a fixed one); the request applies the server
  /// clock offset itself.
  final DateTime Function()? clock;

  const AuthRequestCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onDeny,
    this.isLoading = false,
    this.ipTrust,
    this.clock,
  });

  @override
  State<AuthRequestCard> createState() => _AuthRequestCardState();
}

class _AuthRequestCardState extends State<AuthRequestCard> {
  Timer? _ticker;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AuthRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Ticks every second while the request can still be answered.
  void _syncTicker() {
    final live = widget.request.isActionableAt(_now());
    if (live && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!widget.request.isActionableAt(_now())) {
          _ticker?.cancel();
          _ticker = null;
        }
      });
    } else if (!live) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  String _timeAgo(AppLocalizations l, Duration age) {
    if (age.inSeconds < 60) return l.secondsAgo(age.inSeconds.clamp(0, 59));
    if (age.inMinutes < 60) return l.minutesAgo(age.inMinutes);
    if (age.inHours < 24) return l.hoursAgo(age.inHours);
    return l.daysAgo(age.inDays);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final request = widget.request;
    final ipTrust = widget.ipTrust;
    final now = _now();

    final remaining = request.remaining(now);
    final expired = !request.isActionableAt(now);
    final urgent = !expired && remaining < const Duration(minutes: 1);
    final fingerprint = request.fingerprint;
    final canApprove = !expired && fingerprint != null && !widget.isLoading;

    // Trust frame replaces the old inline badge: previously-approved IP = green,
    // previously-denied = red, never-seen = grey.
    final Color trustBorder = ipTrust == true
        ? kTrustGreen
        : ipTrust == false
            ? cs.error
            : cs.outlineVariant;

    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );

    return ContentCard(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      borderColor: trustBorder,
      borderWidth: 1.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: device (left) + timing (right).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DeviceIcon(
                deviceName: request.requestDeviceType,
                typeValue: request.requestDeviceTypeValue,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    request.requestDeviceType,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (request.hasCreationDate)
                    Text(_timeAgo(l, request.age(now)), style: secondary),
                  Semantics(
                    identifier: 'text_request_countdown',
                    child: Text(
                      expired
                          ? l.requestExpired
                          : l.requestTimeLeft(formatCountdown(remaining)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            expired || urgent ? cs.error : cs.onSurfaceVariant,
                        fontWeight: expired || urgent ? FontWeight.w600 : null,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          // IP on its own line so long IPv6 addresses aren't squeezed, plus
          // the trust status in words (A7) — the frame colour alone is not
          // accessible.
          Semantics(
            identifier: 'text_request_ip',
            container: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.public, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    request.requestIpAddress,
                    style: secondary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (ipTrust != null) ...[
                  const SizedBox(width: 8),
                  _TrustStatus(trusted: ipTrust),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Fingerprint phrase (look unchanged; now the SDK algorithm, F3).
          if (fingerprint != null) ...[
            Text(
              l.fingerprintLabel,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            FingerprintPhrase(phrase: fingerprint),
            const SizedBox(height: 16),
          ] else ...[
            Semantics(
              identifier: 'text_fingerprint_unavailable',
              child: _Notice(
                icon: Icons.gpp_bad_outlined,
                text: l.fingerprintUnavailable,
                color: cs.error,
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (expired) ...[
            _Notice(
              icon: Icons.timer_off_outlined,
              text: l.requestExpiredHint,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
          ],
          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Semantics(
                identifier: 'btn_deny',
                child: Pressable(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                    ),
                    onPressed: widget.isLoading ? null : widget.onDeny,
                    child: Text(l.deny),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                identifier: 'btn_approve',
                child: Pressable(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                    ),
                    onPressed: canApprove ? widget.onApprove : null,
                    child: widget.isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l.approve),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Known IP" / "Denied IP" next to the address (A7).
class _TrustStatus extends StatelessWidget {
  const _TrustStatus({required this.trusted});

  final bool trusted;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final color = trusted ? kTrustGreen : theme.colorScheme.error;
    return Semantics(
      identifier: 'text_ip_trust',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            trusted ? Icons.verified_outlined : Icons.block,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            trusted ? l.ipTrusted : l.ipDenied,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.10),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
