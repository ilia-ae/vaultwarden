import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../models/server_environment.dart';
import 'option_pills.dart';

/// Localised name of a server region ("bitwarden.com", "bitwarden.eu",
/// "Self-hosted").
String serverRegionLabel(ServerRegion region, AppLocalizations l) =>
    switch (region) {
      ServerRegion.us => l.serverRegionUs,
      ServerRegion.eu => l.serverRegionEu,
      ServerRegion.selfHosted => l.serverRegionSelfHosted,
    };

/// Server picker of the setup screen (F16): Bitwarden cloud US / EU or a
/// self-hosted URL. Same pill look as the settings sheet's option chips,
/// laid out as one row of equal segments.
class ServerSelector extends StatelessWidget {
  const ServerSelector({
    super.key,
    required this.region,
    required this.onChanged,
    this.enabled = true,
  });

  final ServerRegion region;
  final ValueChanged<ServerRegion> onChanged;
  final bool enabled;

  /// Semantics identifiers (Maestro flows / tests).
  static const identifiers = {
    ServerRegion.us: 'server_us',
    ServerRegion.eu: 'server_eu',
    ServerRegion.selfHosted: 'server_self_hosted',
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    // One row of equal pills (a segmented choice); labels shrink to fit on
    // narrow screens instead of wrapping.
    return Row(
      children: [
        for (final r in ServerRegion.values) ...[
          if (r != ServerRegion.values.first) const SizedBox(width: 8),
          Expanded(
            child: _RegionPill(
              label: serverRegionLabel(r, l),
              selected: r == region,
              identifier: identifiers[r]!,
              onTap: enabled ? () => onChanged(r) : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// One selection pill with [OptionPill]'s neutral look (selected = grey
/// stadium, unselected = hairline outline); spring squish + selection haptic
/// on tap.
class _RegionPill extends StatelessWidget {
  const _RegionPill({
    required this.label,
    required this.selected,
    required this.identifier,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final String identifier;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final enabled = onTap != null;
    return Pressable(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onTap!();
              }
            : null,
        child: Semantics(
          identifier: identifier,
          button: true,
          selected: selected,
          enabled: enabled,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: ShapeDecoration(
                color: selected
                    ? OptionPill.selectedFill(theme.brightness)
                    : Colors.transparent,
                shape: StadiumBorder(
                  side: selected
                      ? BorderSide.none
                      : OptionPill.unselectedSide(cs),
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: OptionPill.labelColor(cs, selected: selected),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
