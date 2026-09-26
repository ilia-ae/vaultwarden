import 'package:flutter/foundation.dart';

/// Tracks system pickers (document/file pickers) the app has put on screen.
///
/// On Android a picker is a separate activity, so opening one sends the app
/// to `hidden`/`paused` exactly like leaving it. While a picker is open:
/// * the auto-lock in `app.dart` does not lock, and does not close routes, so
///   the sheet or dialog that asked for the file is still there to receive it;
/// * the PIN tools do not wipe their inputs on the background transition.
///
/// A leaf library (Flutter foundation only) so `app.dart` and the PIN section
/// can both read it without an import cycle.
///
/// Wrap every picker call with [runExternalPicker]:
///
/// ```dart
/// final file = await runExternalPicker(() => openFile(acceptedTypeGroups: …));
/// ```
final ValueNotifier<int> externalPickerDepth = ValueNotifier<int>(0);

/// True while at least one [runExternalPicker] call is in flight.
bool get externalPickerActive => externalPickerDepth.value > 0;

/// Runs [open] (which shows a system picker) with [externalPickerActive] set,
/// and clears it again however [open] ends.
Future<T> runExternalPicker<T>(Future<T> Function() open) async {
  externalPickerDepth.value++;
  try {
    return await open();
  } finally {
    externalPickerDepth.value--;
  }
}
