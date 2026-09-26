import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'pin_widgets.dart';

/// YubiKey secrets from a Ledger seed, a master key or at random (`lib/pin_tools/yubikey_secrets.dart`).
///
/// PLACEHOLDER: the tool itself is built in the next step (plan block C4).
/// Replace this widget; keep the class name so `PinSection` needs no change.
/// Available building blocks: `pin_session.dart` (`pinSessionProvider`:
/// wipe events, `touch()`, content probes; `pinSeedProvider`: the shared
/// seed cache), `pin_widgets.dart` (hardened `PinSecretField`, cells,
/// notices, `PinCopyable`) and `lib/widgets/option_pills.dart`.
class YubikeyView extends StatelessWidget {
  const YubikeyView({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Semantics(
      identifier: 'yubikey_placeholder',
      container: true,
      child: PinCard(
        title: l.pinToolYubikey,
        children: [PinNotice(l.pinComingSoon)],
      ),
    );
  }
}
