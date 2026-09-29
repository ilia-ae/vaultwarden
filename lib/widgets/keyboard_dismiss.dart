import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../glass.dart';
import '../l10n/app_localizations.dart';
import 'control_id.dart';

/// Whether [type] opens an iOS keyboard without a return key (number pad,
/// decimal pad, phone pad), so it can only be closed from the app.
bool keyboardLacksReturnKey(TextInputType? type) {
  if (type == null) return false;
  if (type.index == TextInputType.phone.index) return true;
  // numberWithOptions(signed: true) gets numbers-and-punctuation, which has
  // a return key.
  return type.index == TextInputType.number.index && type.signed != true;
}

/// Keyboard dismissal for a scrolling form (the PIN tools).
///
/// * A tap on anything that does not take the tap itself (text, card
///   padding, empty space) unfocuses the field inside this region. Buttons,
///   switches and other fields keep their own taps.
/// * On iOS, while a field inside this region has focus, its keyboard has no
///   return key ([keyboardLacksReturnKey]) and the software keyboard is up,
///   a small "Done" pill floats right above the keyboard.
///
/// Put it where its bottom edge is the keyboard's top edge (inside a
/// `Scaffold` body, which resizes for the keyboard). Pair the scroll view
/// with [ScrollViewKeyboardDismissBehavior.onDrag]. Unfocusing never changes
/// a field's text: wipe rules stay with the fields' owners.
class KeyboardDismissRegion extends StatefulWidget {
  const KeyboardDismissRegion({super.key, required this.child});

  final Widget child;

  /// Space the Done pill covers above the keyboard. Fields that get the pill
  /// add it to their `scrollPadding`, so the keyboard never scrolls them
  /// under it.
  static const double reservedHeight = 56;

  @override
  State<KeyboardDismissRegion> createState() => _KeyboardDismissRegionState();
}

class _KeyboardDismissRegionState extends State<KeyboardDismissRegion>
    with WidgetsBindingObserver {
  bool _keyboardUp = false;
  bool _noReturnKeyFocused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_update);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardUp = _readKeyboardUp();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_update);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _update();

  /// The Scaffold strips the keyboard inset from its body's MediaQuery, so
  /// read it from the view.
  bool _readKeyboardUp() => View.of(context).viewInsets.bottom > 0;

  /// The focused field's element, when it is inside this region.
  BuildContext? _focusInside() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null || !focusContext.mounted || !mounted) return null;
    var inside = false;
    focusContext.visitAncestorElements((e) {
      if (e == context) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside ? focusContext : null;
  }

  void _update() {
    if (!mounted) return;
    final keyboardUp = _readKeyboardUp();
    final focus = _focusInside();
    final noReturnKey = focus != null &&
        keyboardLacksReturnKey(
            focus.findAncestorWidgetOfExactType<EditableText>()?.keyboardType);
    if (keyboardUp == _keyboardUp && noReturnKey == _noReturnKeyFocused) {
      return;
    }
    setState(() {
      _keyboardUp = keyboardUp;
      _noReturnKeyFocused = noReturnKey;
    });
  }

  void _unfocusInside() {
    final focus = _focusInside();
    if (focus != null) FocusManager.instance.primaryFocus?.unfocus();
  }

  void _done() {
    HapticFeedback.selectionClick();
    _unfocusInside();
  }

  @override
  Widget build(BuildContext context) {
    final showDone = defaultTargetPlatform == TargetPlatform.iOS &&
        _keyboardUp &&
        _noReturnKeyFocused;
    return GestureDetector(
      // Translucent: empty space counts too; any child that takes the tap
      // (button, field, switch) wins the gesture arena first.
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      onTap: _unfocusInside,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (showDone)
            PositionedDirectional(
              end: 12,
              bottom: 8,
              child: _DonePill(onTap: _done),
            ),
        ],
      ),
    );
  }
}

/// The "Done" key for keyboards without one: a small glass pill (overlay
/// layer, like the iOS 26 keyboard toolbar buttons).
class _DonePill extends StatelessWidget {
  const _DonePill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ControlId(
      'btn_keyboard_done',
      child: Semantics(
        button: true,
        child: Pressable(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: GlassContainer(
              useOwnLayer: true,
              quality: GlassQuality.standard,
              shape: const LiquidRoundedSuperellipse(borderRadius: 20),
              settings: appGlassFor(theme.brightness),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40, minWidth: 72),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Text(
                    AppLocalizations.of(context)!.keyboardDone,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
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
