import 'package:flutter/material.dart';

import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../models/auth_request.dart';
import 'fingerprint_phrase.dart';

class AuthRequestCard extends StatelessWidget {
  final AuthRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  final bool isLoading;
  /// IP trust from history: true=previously approved, false=previously denied, null=unknown.
  final bool? ipTrust;

  const AuthRequestCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onDeny,
    this.isLoading = false,
    this.ipTrust,
  });

  IconData _deviceIcon(String deviceType) {
    final lower = deviceType.toLowerCase();
    if (lower.contains('android')) return Icons.phone_android;
    if (lower.contains('ios') || lower.contains('iphone')) return Icons.phone_iphone;
    if (lower.contains('web') || lower.contains('browser')) return Icons.language;
    if (lower.contains('desktop') || lower.contains('windows') || lower.contains('mac') || lower.contains('linux')) {
      return Icons.computer;
    }
    return Icons.devices;
  }

  String _timeAgo(BuildContext context, DateTime date) {
    final l = AppLocalizations.of(context)!;
    final diff = DateTime.now().difference(date);
    if (diff.inSeconds < 60) return l.secondsAgo(diff.inSeconds);
    if (diff.inMinutes < 60) return l.minutesAgo(diff.inMinutes);
    return l.hoursAgo(diff.inHours);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // Trust frame replaces the old inline badge: previously-approved IP = green,
    // previously-denied = red, never-seen = grey.
    final Color trustBorder = ipTrust == true
        ? const Color(0xFF34C759) // iOS system green
        : ipTrust == false
            ? cs.error
            : cs.outlineVariant;

    return ContentCard(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      borderColor: trustBorder,
      borderWidth: 1.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: device name (left) + timing (right).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _deviceIcon(request.requestDeviceType),
                color: cs.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  request.requestDeviceType,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _timeAgo(context, request.creationDate),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Text(
                    AppLocalizations.of(context)!
                        .minutesLeft(request.minutesRemaining),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: request.minutesRemaining <= 3
                          ? cs.error
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          // IP on its own line so long IPv6 addresses aren't squeezed.
          Row(
            children: [
              Icon(Icons.public, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  request.requestIpAddress,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Fingerprint phrase
          if (request.fingerprint != null) ...[
            Text(
              AppLocalizations.of(context)!.fingerprintLabel,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            FingerprintPhrase(phrase: request.fingerprint!),
            const SizedBox(height: 16),
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
                    onPressed: isLoading ? null : onDeny,
                    child: Text(AppLocalizations.of(context)!.deny),
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
                    onPressed: isLoading ? null : onApprove,
                    child: isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(AppLocalizations.of(context)!.approve),
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
