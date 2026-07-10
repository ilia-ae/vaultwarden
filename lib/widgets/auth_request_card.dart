import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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

    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      settings: appGlass,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device info row
            Row(
              children: [
                Icon(
                  _deviceIcon(request.requestDeviceType),
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.requestDeviceType,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        AppLocalizations.of(context)!.ipAddress(request.requestIpAddress),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (ipTrust != null && !isLoading) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ipTrust!
                                ? Colors.green.withAlpha(30)
                                : theme.colorScheme.error.withAlpha(30),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: ipTrust!
                                  ? Colors.green.withAlpha(128)
                                  : theme.colorScheme.error.withAlpha(128),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                ipTrust!
                                    ? Icons.verified_user_outlined
                                    : Icons.gpp_bad_outlined,
                                size: 12,
                                color: ipTrust!
                                    ? Colors.green
                                    : theme.colorScheme.error,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                ipTrust!
                                    ? AppLocalizations.of(context)!.ipTrusted
                                    : AppLocalizations.of(context)!.ipDenied,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: ipTrust!
                                      ? Colors.green
                                      : theme.colorScheme.error,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _timeAgo(context, request.creationDate),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      AppLocalizations.of(context)!.minutesLeft(request.minutesRemaining),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: request.minutesRemaining <= 3
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Fingerprint phrase
            if (request.fingerprint != null) ...[
              Text(
                AppLocalizations.of(context)!.fingerprintLabel,
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              FingerprintPhrase(phrase: request.fingerprint!),
              const SizedBox(height: 16),
            ],

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Semantics(
                  identifier: 'btn_deny',
                  child: OutlinedButton(
                    onPressed: isLoading ? null : onDeny,
                    child: Text(AppLocalizations.of(context)!.deny),
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  identifier: 'btn_approve',
                  child: FilledButton(
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
              ],
            ),
          ],
        ),
    );
  }
}
