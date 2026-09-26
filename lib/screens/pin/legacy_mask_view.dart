import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'pin_widgets.dart';

/// Legacy mask (`pass_pin`): an 8-digit mask walked over a 20-character string (`lib/pin_tools/mask_pin.dart`), shown only with "Show legacy tools" on.
///
/// PLACEHOLDER: the tool itself is built in the next step (plan block C3).
/// Replace this widget; keep the class name so `PinSection` needs no change.
/// Available building blocks: `pin_session.dart` (`pinSessionProvider`:
/// wipe events, `touch()`, content probes; `pinSeedProvider`: the shared
/// seed cache), `pin_widgets.dart` (hardened `PinSecretField`, cells,
/// notices, `PinCopyable`) and `lib/widgets/option_pills.dart`.
class LegacyMaskView extends StatelessWidget {
  const LegacyMaskView({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Semantics(
      identifier: 'legacy_mask_placeholder',
      container: true,
      child: PinCard(
        title: l.pinToolLegacy,
        children: [PinNotice(l.pinComingSoon)],
      ),
    );
  }
}
