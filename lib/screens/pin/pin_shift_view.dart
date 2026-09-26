import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'pin_widgets.dart';

/// PIN Shift: reversible digit-wise shift of a PIN by a secret vector (`lib/pin_tools/pin_shift.dart`).
///
/// PLACEHOLDER: the tool itself is built in the next step (plan block C2).
/// Replace this widget; keep the class name so `PinSection` needs no change.
/// Available building blocks: `pin_session.dart` (`pinSessionProvider`:
/// wipe events, `touch()`, content probes; `pinSeedProvider`: the shared
/// seed cache), `pin_widgets.dart` (hardened `PinSecretField`, cells,
/// notices, `PinCopyable`) and `lib/widgets/option_pills.dart`.
class PinShiftView extends StatelessWidget {
  const PinShiftView({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Semantics(
      identifier: 'pin_shift_placeholder',
      container: true,
      child: PinCard(
        title: l.pinToolShift,
        children: [PinNotice(l.pinComingSoon)],
      ),
    );
  }
}
