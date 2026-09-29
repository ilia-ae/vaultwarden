import 'package:flutter/widgets.dart';

/// A Semantics identifier (Maestro/XCUITest id) on ONE control's own node.
///
/// A plain `Semantics(identifier:)` around a button (or a CheckboxListTile)
/// adds a node that carries nothing but the id and has the control's node as
/// its child. iOS exposes such a node as an accessibility container, whose
/// frame is the whole screen: XCUITest resolves the id to a screen-sized
/// element and taps the screen centre (in a dialog: the dialog, not the
/// button). Merging folds the id into the control's element instead — its
/// own frame, label and tap action — on iOS and Android alike.
///
/// Only for a single control: everything below [child] becomes one node.
class ControlId extends StatelessWidget {
  const ControlId(this.identifier, {super.key, required this.child});

  final String identifier;
  final Widget child;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Semantics(identifier: identifier, child: child),
      );
}
