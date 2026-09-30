import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../l10n/app_localizations.dart';
import '../../pin_tools/pin_shift.dart';
import '../../services/pin_shift_vector_store.dart';
import '../../widgets/option_pills.dart';
import 'pin_prefs.dart';
import 'pin_session.dart';
import 'pin_widgets.dart';

/// Quick-pick lengths: the source page's 4 and 8, plus 6 (spec #3 SHOULD).
const List<int> _quickLengths = [4, 6, 8];

/// Cell colours of the source page (`PALETTE`).
const Color _inputColor = PinColors.info; // #4B6FFF
const Color _vectorColor = PinColors.partial; // #D97706
const Color _outputColor = PinColors.valid; // #2EA043

/// The one mask of a saved vector's digits (never the digits, in any view).
const String _mask = '•';

/// PIN Shift: per-position modulo-10 shift of a PIN by a secret vector
/// (port of `crypto_tools/pin_shift_ui.py`, core in
/// `lib/pin_tools/pin_shift.dart`).
///
/// Top to bottom: the PIN, the vector, the result, the settings (direction,
/// length, reveal, Clear), then what it is and how to do it on paper.
///
/// Mnemonic obfuscation, not a cipher. The PIN and a typed vector live only
/// in this widget's text controllers; they are cleared by every section wipe
/// (background, 2 min idle, 🚨, screenshot, leaving the tab), by Clear and
/// when the widget goes away. There is deliberately no copy button: the
/// derived PIN is meant to be recomputed, never written down. Errors report
/// positions only, never the characters typed. While "Reveal" is off
/// nothing hints at the hidden inputs: no weak-vector notices, and screen
/// readers are not given the digits. The length is remembered
/// ([PinPrefs.pinShiftLength], this device only).
///
/// The vector can be saved on this device ([PinShiftVectorStore]: the
/// keychain, never the preferences or the cloud). A saved vector is used
/// automatically and is never shown again — no eye, masked cells, a masked
/// breakdown column, no weak-vector notices, no digits in any semantics
/// label; to see it, the user enters it again (Replace). It fixes the length
/// until it is replaced or deleted. The in-memory copy is dropped by every
/// wipe and by Clear and read from the keychain again on the next use; the
/// saved vector itself survives wipes.
class PinShiftView extends ConsumerStatefulWidget {
  const PinShiftView({super.key});

  @override
  ConsumerState<PinShiftView> createState() => _PinShiftViewState();
}

/// One input field after [normalizeInputDigits], checked against the
/// selected length.
class _FieldCheck {
  _FieldCheck(String raw, this.length) : value = normalizeInputDigits(raw) {
    nonDigits = nonDigitPositions(value);
    runeLength = value.runes.length;
  }

  final int length;

  /// ASCII-normalized, stripped text (what goes to [shiftPin]).
  final String value;

  /// 1-based positions of characters that are not `0`–`9`.
  late final List<int> nonDigits;
  late final int runeLength;

  bool get isEmpty => value.isEmpty;
  bool get hasError => nonDigits.isNotEmpty;
  bool get lengthMismatch => !isEmpty && !hasError && runeLength != length;
  bool get ok => !isEmpty && !hasError && runeLength == length;
}

/// What the keychain holds for PIN Shift, as far as this view knows.
enum _Saved {
  /// Being read (the tool just opened, or Retry).
  loading,

  /// No vector saved (or no keychain wired: then there is no Save either).
  none,

  /// A vector is saved; its digits may or may not be in memory right now.
  saved,

  /// The keychain could not be read.
  error,
}

class _PinShiftViewState extends ConsumerState<PinShiftView> {
  late final ProviderSubscription<PinSession> _sessionSub;
  late final PinSession _session;
  VoidCallback? _unregisterProbe;

  final _pinCtrl = TextEditingController();
  final _vecCtrl = TextEditingController();
  final _vecFocus = FocusNode();

  /// Where the chosen length is kept (loaded by `PinSection` before any tool
  /// is built).
  PinPrefs? _prefs;

  /// Where a saved vector lives; `null` = saving is not offered.
  PinShiftVectorStore? _store;

  bool _decode = false;
  int _length = kPinShiftDefaultLength;

  // Reveal toggles: off on every visit, after every wipe and on Clear.
  bool _showPin = false;
  bool _showVector = false;
  bool _reveal = false;

  /// Bumped by every wipe and Clear: the fields are rebuilt with an empty
  /// undo history.
  int _fieldGen = 0;

  // ── Saved vector ──

  _Saved _saved = _Saved.none;

  /// The saved vector's digits while in memory: read when the tool opens and
  /// on the first use after a wipe, dropped by every wipe, Clear and
  /// dispose. Never rendered.
  String? _savedVector;

  /// Its length (known while [_saved] is [_Saved.saved], also when the
  /// digits were dropped).
  int? _savedLength;

  /// "Replace": a new vector is typed while the saved one stays stored.
  bool _replacing = false;

  /// A save or delete is running.
  bool _busy = false;
  bool _reloading = false;

  /// Bumped by every keychain call: a late answer of an older one is
  /// ignored.
  int _loadGen = 0;

  /// Bumped by every wipe and Clear: digits read before one are not kept.
  int _wipeCount = 0;

  @override
  void initState() {
    super.initState();
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _session.wipes.addListener(_onWipe);
    _unregisterProbe = _session.registerContentProbe(_hasContent);
    _prefs = ref.read(pinPrefsProvider).valueOrNull;
    _length = _prefs?.pinShiftLength ?? kPinShiftDefaultLength;
    _store = ref.read(pinShiftVectorStoreProvider);
    if (_store != null) {
      _saved = _Saved.loading;
      unawaited(_loadSaved());
    }
    _session.touch();
  }

  @override
  void dispose() {
    _session.wipes.removeListener(_onWipe);
    _unregisterProbe?.call();
    _sessionSub.close();
    _savedVector = null;
    _pinCtrl.clear();
    _vecCtrl.clear();
    _pinCtrl.dispose();
    _vecCtrl.dispose();
    _vecFocus.dispose();
    // Never let iOS/Android offer to save what was typed as a password.
    TextInput.finishAutofillContext(shouldSave: false);
    super.dispose();
  }

  /// Whether a saved vector (rather than the field) feeds the result.
  bool get _usingSaved => _saved == _Saved.saved && !_replacing;

  /// A saved vector fixes the length until it is replaced or deleted.
  bool get _lengthLocked => _usingSaved;

  /// Whether the vector field offers "Save" (no saved vector yet, or
  /// replacing one).
  bool get _canSave =>
      _store != null &&
      (_saved == _Saved.none || (_saved == _Saved.saved && _replacing));

  bool _hasContent() => _pinCtrl.text.isNotEmpty || _vecCtrl.text.isNotEmpty;

  void _onWipe() {
    final event = _session.wipes.value;
    if (event == null || !mounted) return;
    // A seed-only wipe (🧹 in PIN 24) has nothing to clear here.
    if (event.scope == PinWipeScope.seed) return;
    _clearInputs();
  }

  void _clearInputs() {
    _pinCtrl.clear();
    _vecCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    final wasReplacing = _replacing;
    setState(() {
      _fieldGen++;
      _showPin = false;
      _showVector = false;
      _reveal = false;
      // The saved vector stays in the keychain; its digits leave memory and
      // are read again on the next use.
      _wipeCount++;
      _savedVector = null;
      _replacing = false;
    });
    final saved = _savedLength;
    if (wasReplacing && saved != null) _useLength(saved);
  }

  void _onClearPressed() {
    _session.touch();
    HapticFeedback.mediumImpact();
    FocusManager.instance.primaryFocus?.unfocus();
    _clearInputs();
    _session.userCleared();
  }

  void _edited(String _) {
    _session.touch();
    setState(() {});
  }

  void _pinEdited(String value) {
    _edited(value);
    _reloadSavedIfDropped();
  }

  void _setDecode(bool decode) {
    _session.touch();
    setState(() => _decode = decode);
  }

  void _setLength(int length) {
    _session.touch();
    if (_lengthLocked) return;
    _useLength(length);
  }

  /// Shows [length] and remembers it on this device.
  void _useLength(int length) {
    final clamped = clampPinShiftLength(length);
    if (clamped != _length) setState(() => _length = clamped);
    final prefs = _prefs;
    if (prefs != null && prefs.pinShiftLength != clamped) {
      unawaited(prefs.setPinShiftLength(clamped));
    }
  }

  // ── Saved vector: keychain ──

  /// A stored value PIN Shift can use: ASCII digits, 1–16 of them; else
  /// `null` (treated as nothing saved; a new save overwrites it).
  static String? _usable(String? raw) {
    if (raw == null) return null;
    final value = normalizeInputDigits(raw);
    final n = value.runes.length;
    if (n < kShiftMinLength ||
        n > kShiftMaxLength ||
        nonDigitPositions(value).isNotEmpty) {
      return null;
    }
    return value;
  }

  /// Reads the saved vector. A keychain that cannot be read (locked device,
  /// keystore failure) is an error with Retry, never "nothing saved".
  Future<void> _loadSaved() async {
    final store = _store;
    if (store == null) return;
    final gen = ++_loadGen;
    final wipes = _wipeCount;
    String? vector;
    var failed = false;
    try {
      vector = _usable(await store.loadShiftVector());
    } catch (_) {
      // SecureStorageReadException or a plugin error; never shown as text.
      failed = true;
    }
    if (!mounted || gen != _loadGen) return;
    setState(() {
      if (failed) {
        _saved = _Saved.error;
        _savedVector = null;
        _savedLength = null;
      } else if (vector == null) {
        _saved = _Saved.none;
        _savedVector = null;
        _savedLength = null;
      } else {
        _saved = _Saved.saved;
        _savedLength = vector.length;
        // A wipe while the keychain answered: keep knowing that a vector is
        // saved, not its digits.
        _savedVector = wipes == _wipeCount ? vector : null;
      }
    });
    if (vector == null || _replacing) return;
    _useLength(vector.length);
    // A vector typed by hand meanwhile (Retry after a read error) is not
    // used any more: it does not stay behind the saved card.
    if (_vecCtrl.text.isNotEmpty) {
      _vecCtrl.clear();
      setState(() {
        _fieldGen++;
        _showVector = false;
      });
    }
  }

  /// The first use after a wipe reads the saved vector again.
  void _reloadSavedIfDropped() {
    if (!_usingSaved || _savedVector != null || _reloading) return;
    _reloading = true;
    unawaited(_loadSaved().whenComplete(() => _reloading = false));
  }

  void _retryLoad() {
    _session.touch();
    setState(() => _saved = _Saved.loading);
    unawaited(_loadSaved());
  }

  void _snack(ScaffoldMessengerState? messenger, String text) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveVector() async {
    final store = _store;
    final check = _FieldCheck(_vecCtrl.text, _length);
    if (store == null || _busy || !_canSave || !check.ok) return;
    _session.touch();
    _vecFocus.unfocus();
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final replaced = _saved == _Saved.saved;
    final vector = check.value;
    final wipes = _wipeCount;
    _loadGen++; // an older read must not undo this
    setState(() => _busy = true);
    try {
      await store.saveShiftVector(vector);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _snack(messenger, l.pinShiftVectorSaveError);
      return;
    }
    if (!mounted) return;
    _vecCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _busy = false;
      _saved = _Saved.saved;
      _savedLength = vector.length;
      _savedVector = wipes == _wipeCount ? vector : null;
      _replacing = false;
      _showVector = false;
    });
    _useLength(vector.length);
    HapticFeedback.mediumImpact();
    _snack(messenger,
        replaced ? l.pinShiftVectorReplacedSnack : l.pinShiftVectorSavedSnack);
  }

  Future<void> _deleteVector() async {
    final store = _store;
    if (store == null || _busy || !_usingSaved) return;
    _session.touch();
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await confirmPinAction(
      context: context,
      session: _session,
      tone: PinDialogTone.destructive,
      title: l.pinShiftVectorDeleteTitle,
      body: l.pinShiftVectorDeleteBody,
      confirmLabel: l.pinShiftVectorDelete,
      confirmId: 'pin_shift_vector_delete_confirm',
      cancelId: 'pin_shift_vector_delete_cancel',
    );
    if (!confirmed || !mounted) return;
    _session.touch();
    _loadGen++;
    setState(() => _busy = true);
    try {
      await store.deleteShiftVector();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _snack(messenger, l.pinShiftVectorDeleteError);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _saved = _Saved.none;
      _savedVector = null;
      _savedLength = null;
      _replacing = false;
    });
    HapticFeedback.mediumImpact();
    _snack(messenger, l.pinShiftVectorDeletedSnack);
  }

  void _startReplace() {
    _session.touch();
    _vecCtrl.clear();
    setState(() {
      _replacing = true;
      _showVector = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _replacing) _vecFocus.requestFocus();
    });
  }

  void _cancelReplace() {
    _session.touch();
    _vecFocus.unfocus();
    _vecCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _replacing = false;
      _showVector = false;
    });
    final saved = _savedLength;
    if (saved != null) _useLength(saved);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final pin = _FieldCheck(_pinCtrl.text, _length);
    final _FieldCheck? vec;
    if (_usingSaved) {
      final saved = _savedVector;
      vec = saved == null ? null : _FieldCheck(saved, _length);
    } else {
      vec =
          _saved == _Saved.loading ? null : _FieldCheck(_vecCtrl.text, _length);
    }
    return Semantics(
      identifier: 'pin_shift_view',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pinCard(l, pin),
          _vectorCard(l),
          _resultCard(l, pin, vec),
          _settingsCard(l),
          _aboutCard(l),
          _paperCard(l),
          _threatCard(l),
        ],
      ),
    );
  }

  Widget _eye({
    required String identifier,
    required String field,
    required bool shown,
    required VoidCallback onPressed,
  }) {
    final l = AppLocalizations.of(context)!;
    return Semantics(
      identifier: identifier,
      child: IconButton(
        tooltip: shown ? l.pinHideField(field) : l.pinShowField(field),
        icon: Icon(shown ? Icons.visibility_off_outlined : Icons.visibility),
        onPressed: () {
          _session.touch();
          onPressed();
        },
      ),
    );
  }

  /// Error / length notes under a field. Positions only, never characters.
  List<Widget> _fieldNotes({
    required _FieldCheck check,
    required String Function(String positions) nonDigit,
    required String Function(int actual, int expected) wrongLength,
    required String idPrefix,
  }) {
    if (check.hasError) {
      return [
        const SizedBox(height: 6),
        Semantics(
          identifier: '${idPrefix}_error',
          child: PinNotice(
            nonDigit(ltrIsolate(check.nonDigits.join(', '))),
            kind: PinNoticeKind.error,
          ),
        ),
      ];
    }
    if (check.lengthMismatch) {
      return [
        const SizedBox(height: 6),
        Semantics(
          identifier: '${idPrefix}_length_warning',
          child: PinNotice(
            wrongLength(check.runeLength, _length),
            kind: PinNoticeKind.warning,
          ),
        ),
      ];
    }
    return const [];
  }

  Widget _pinCard(AppLocalizations l, _FieldCheck pin) {
    return PinCard(
      title: l.pinShiftSectionPin,
      children: [
        PinSecretField(
          controller: _pinCtrl,
          identifier: 'pin_shift_pin',
          wipeGeneration: _fieldGen,
          obscure: !_showPin,
          pasteOnlyMenu: true,
          monospace: true,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.number,
          labelText: _decode ? l.pinShiftFieldDerived : l.pinShiftFieldBase,
          helperText: _decode
              ? l.pinShiftFieldDerivedHelp(_length)
              : l.pinShiftFieldBaseHelp(_length),
          onChanged: _pinEdited,
          suffixIcon: _eye(
            identifier: 'pin_shift_pin_eye',
            field: _decode ? l.pinShiftFieldDerived : l.pinShiftFieldBase,
            shown: _showPin,
            onPressed: () => setState(() => _showPin = !_showPin),
          ),
        ),
        ..._fieldNotes(
          check: pin,
          nonDigit: l.pinShiftPinNonDigit,
          wrongLength: l.pinShiftPinLengthWarning,
          idPrefix: 'pin_shift_pin',
        ),
      ],
    );
  }

  // ── Vector ──

  Widget _vectorCard(AppLocalizations l) {
    return PinCard(
      title: l.pinShiftSectionVector,
      children: [
        ...switch (_saved) {
          _Saved.loading => [_loadingSaved()],
          _Saved.saved when !_replacing => _savedVectorBody(l),
          _Saved.error => [
              _readError(l),
              const SizedBox(height: 10),
              ..._vectorEntry(l),
            ],
          _ => _vectorEntry(l),
        },
        // A PIN or vector pasted earlier (it survives wipes).
        PinClipboardReminder(
          session: _session,
          identifier: 'pin_clear_clipboard',
        ),
      ],
    );
  }

  Widget _loadingSaved() {
    return Semantics(
      identifier: 'pin_shift_vector_loading',
      child: const SizedBox(
        height: 56,
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      ),
    );
  }

  /// (a) no saved vector, (c) replacing it, or the keychain was unreadable:
  /// the vector is typed (and may be revealed while it is not saved).
  List<Widget> _vectorEntry(AppLocalizations l) {
    final vec = _FieldCheck(_vecCtrl.text, _length);
    final label = _replacing ? l.pinShiftVectorNewLabel : l.pinShiftFieldVector;
    return [
      if (_replacing) ...[
        PinCaption(l.pinShiftVectorReplaceNote),
        const SizedBox(height: 10),
      ],
      PinSecretField(
        controller: _vecCtrl,
        focusNode: _vecFocus,
        identifier: 'pin_shift_vector',
        wipeGeneration: _fieldGen,
        obscure: !_showVector,
        pasteOnlyMenu: true,
        monospace: true,
        textDirection: TextDirection.ltr,
        keyboardType: TextInputType.number,
        labelText: label,
        helperText: l.pinShiftFieldVectorHelp(_length),
        onChanged: _edited,
        suffixIcon: _eye(
          identifier: 'pin_shift_vector_eye',
          field: label,
          shown: _showVector,
          onPressed: () => setState(() => _showVector = !_showVector),
        ),
      ),
      ..._fieldNotes(
        check: vec,
        nonDigit: l.pinShiftVectorNonDigit,
        wrongLength: l.pinShiftVectorLengthWarning,
        idPrefix: 'pin_shift_vector',
      ),
      if (_canSave) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              identifier: 'pin_shift_vector_save',
              child: _replacing
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48)),
                      onPressed: vec.ok && !_busy ? _saveVector : null,
                      icon: const Icon(Icons.lock_outline, size: 18),
                      label: Text(l.pinShiftVectorSaveReplace),
                    )
                  : OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48)),
                      onPressed: vec.ok && !_busy ? _saveVector : null,
                      icon: const Icon(Icons.lock_outline, size: 18),
                      label: Text(l.pinShiftVectorSave),
                    ),
            ),
            if (_replacing)
              Semantics(
                identifier: 'pin_shift_vector_cancel',
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _busy ? null : _cancelReplace,
                  child: Text(l.cancel),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        PinCaption(l.pinShiftVectorSaveHelp),
      ],
    ];
  }

  /// (b) a saved vector: its length and fixed masks, never the digits and no
  /// way to reveal them.
  List<Widget> _savedVectorBody(AppLocalizations l) {
    final theme = Theme.of(context);
    final n = _savedLength ?? _length;
    return [
      Semantics(
        identifier: 'pin_shift_vector_saved',
        container: true,
        label: l.pinShiftVectorSavedSemantics(n),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: PinColors.textFor(_vectorColor, theme.brightness),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.pinShiftVectorSavedTitle(n),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              PinDigitCells(
                value: _mask * n,
                color: _vectorColor,
                cellWidth: 36,
                cellHeight: 44,
                fontSize: 20,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      PinCaption(l.pinShiftVectorSavedHelp),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Semantics(
            identifier: 'pin_shift_vector_replace',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _busy ? null : _startReplace,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(l.pinShiftVectorReplace),
            ),
          ),
          Semantics(
            identifier: 'pin_shift_vector_delete',
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                minimumSize: const Size(0, 48),
              ),
              onPressed: _busy ? null : _deleteVector,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l.pinShiftVectorDelete),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _readError(AppLocalizations l) {
    return Semantics(
      identifier: 'pin_shift_vector_read_error',
      child: PinNotice(
        l.pinShiftVectorReadError,
        kind: PinNoticeKind.error,
        action: Semantics(
          identifier: 'pin_shift_vector_retry',
          child: TextButton.icon(
            onPressed: _retryLoad,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l.retry),
          ),
        ),
      ),
    );
  }

  // ── Result ──

  /// [vec] is `null` while the vector is not available yet (the keychain is
  /// being read).
  Widget _resultCard(AppLocalizations l, _FieldCheck pin, _FieldCheck? vec) {
    final body = <Widget>[];

    if (pin.hasError || (vec?.hasError ?? false)) {
      body.add(Semantics(
        identifier: 'pin_shift_fix_errors',
        child: PinNotice(l.pinFixErrorsAbove),
      ));
    } else if (vec == null || !(pin.ok && vec.ok)) {
      body
        ..add(_digitRow(
          label: _decode ? l.pinShiftRowOutputBase : l.pinShiftRowOutputDerived,
          value: _mask * _length,
          color: PinColors.emptyText,
          identifier: 'pin_shift_output',
          semantics: l.pinShiftOutputEmpty,
        ))
        ..add(const SizedBox(height: 6))
        ..add(Semantics(
          identifier: 'pin_shift_incomplete',
          child: PinCaption(_usingSaved
              ? l.pinShiftFillPin(_length)
              : l.pinShiftFillBoth(_length)),
        ));
    } else {
      body.addAll(_validResult(l, pin.value, vec.value));
    }

    body.addAll([
      const SizedBox(height: 12),
      PinCaption(l.pinShiftNoCopyNote),
    ]);
    return PinCard(title: l.pinShiftSectionResult, children: body);
  }

  List<Widget> _validResult(AppLocalizations l, String pin, String vector) {
    final String output;
    final String back;
    try {
      output = shiftPin(pin, vector, decode: _decode);
      back = shiftPin(output, vector, decode: !_decode);
    } on PinShiftException {
      // Unreachable after the checks above; never show the core's text.
      return [PinNotice(l.pinFixErrorsAbove, kind: PinNoticeKind.error)];
    }
    // A saved vector is never shown, not even with "Reveal" on.
    final saved = _usingSaved;
    final sign = _decode ? '−' : '+';
    final inputLabel =
        _decode ? l.pinShiftRowInputDerived : l.pinShiftRowInputBase;
    final outputLabel =
        _decode ? l.pinShiftRowOutputBase : l.pinShiftRowOutputDerived;
    final base = _decode ? output : pin;

    final out = <Widget>[];
    if (_reveal) {
      out
        ..add(_digitRow(
          label: inputLabel,
          value: pin,
          color: _inputColor,
          identifier: 'pin_shift_input_row',
        ))
        ..add(const SizedBox(height: 8))
        ..add(_digitRow(
          label: l.pinShiftRowVector(sign),
          value: saved ? _mask * vector.length : vector,
          color: _vectorColor,
          identifier: 'pin_shift_vector_row',
          semantics:
              saved ? l.pinShiftVectorSavedSemantics(vector.length) : null,
        ))
        ..add(const SizedBox(height: 8));
    }
    out.add(_digitRow(
      label: outputLabel,
      value: output,
      color: _outputColor,
      identifier: 'pin_shift_output',
      // Screen readers get the digits only while "Reveal" is on (the same
      // rule as PIN 24's "Show the PIN as text").
      semantics: _reveal
          ? null
          : l.pinSecretHiddenSemantics(outputLabel, output.length),
    ));
    if (!_reveal) {
      out
        ..add(const SizedBox(height: 6))
        ..add(PinCaption(
            saved ? l.pinShiftHiddenNoteSaved : l.pinShiftHiddenNote));
    }

    out.add(const SizedBox(height: 10));
    out.add(Semantics(
      identifier: 'pin_shift_roundtrip',
      child: back == pin
          ? PinNotice(
              _decode ? l.pinShiftRoundTripOkDecode : l.pinShiftRoundTripOk,
              kind: PinNoticeKind.ok,
            )
          : PinNotice(l.pinShiftRoundTripMismatch, kind: PinNoticeKind.warning),
    ));

    // Weak vectors (spec threat model / README "what not to do"). Only while
    // revealed: with the rows hidden, "the vector is all fives" plus the
    // visible output would give away the base PIN. Never for a saved vector:
    // each notice would describe its digits.
    final weakChecks = _reveal && !saved;
    if (weakChecks && vector.runes.every((r) => r == 0x30)) {
      out.add(Semantics(
        identifier: 'pin_shift_weak_zero',
        child: PinNotice(l.pinShiftWeakZero, kind: PinNoticeKind.warning),
      ));
    }
    if (weakChecks && vector == base) {
      out.add(Semantics(
        identifier: 'pin_shift_weak_equal',
        child: PinNotice(l.pinShiftWeakEqualsBase, kind: PinNoticeKind.warning),
      ));
    }
    if (weakChecks && vector.runes.every((r) => r == 0x35)) {
      out.add(Semantics(
        identifier: 'pin_shift_weak_fives',
        child: PinNotice(l.pinShiftWeakFives, kind: PinNoticeKind.warning),
      ));
    }

    if (_reveal) {
      out
        ..add(const SizedBox(height: 4))
        ..add(PinDisclosure(
          title: l.pinShiftBreakdownTitle,
          identifier: 'pin_shift_breakdown',
          children: [
            _breakdownTable(l, pin, vector, maskVector: saved),
          ],
        ));
    }
    return out;
  }

  Widget _digitRow({
    required String label,
    required String value,
    required Color color,
    required String identifier,
    String? semantics,
  }) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: identifier,
      container: true,
      label: semantics ?? '$label: ${value.split('').join(' ')}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            // The source page's 56×72 / 32 px cells, scaled for a phone.
            PinDigitCells(
              value: value,
              color: color,
              cellWidth: 48,
              cellHeight: 64,
              fontSize: 30,
            ),
          ],
        ),
      ),
    );
  }

  /// The per-digit table. With [maskVector] (a saved vector) its column and
  /// the formula show a fixed mask instead of the vector's digits.
  Widget _breakdownTable(
    AppLocalizations l,
    String pin,
    String vector, {
    required bool maskVector,
  }) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final rows = shiftBreakdown(pin, vector, decode: _decode);
    final sign = _decode ? '−' : '+';
    Widget cell(String text, {bool header = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Text(
            text,
            style: header
                ? theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                : pinMono(context, size: 13, color: color),
          ),
        );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          children: [
            TableRow(children: [
              cell('#', header: true),
              cell(l.pinShiftColInput, header: true),
              cell(l.pinShiftColVector, header: true),
              cell(l.pinShiftColFormula, header: true),
              cell(l.pinShiftColOutput, header: true),
            ]),
            for (final r in rows)
              TableRow(children: [
                cell('${r.position}'),
                cell('${r.input}', color: PinColors.textFor(_inputColor, b)),
                cell(maskVector ? _mask : '${r.vector}',
                    color: PinColors.textFor(_vectorColor, b)),
                cell(maskVector
                    ? '(${r.input} $sign $_mask) mod 10'
                    : r.formula),
                cell('${r.output}', color: PinColors.textFor(_outputColor, b)),
              ]),
          ],
        ),
      ),
    );
  }

  // ── Settings ──

  Widget _settingsCard(AppLocalizations l) {
    final locked = _lengthLocked;
    // A saved vector fixes the length: the controls stay visible, disabled.
    Widget lockable(Widget child) => locked
        ? IgnorePointer(child: Opacity(opacity: 0.45, child: child))
        : child;
    return PinCard(
      title: l.pinShiftSectionSettings,
      children: [
        SectionHeader(l.pinShiftSectionDirection, padding: EdgeInsets.zero),
        const SizedBox(height: 6),
        OptionPills<bool>(
          padding: EdgeInsets.zero,
          options: [
            (value: false, label: l.pinShiftEncode),
            (value: true, label: l.pinShiftDecode),
          ],
          identifiers: const ['pin_shift_encode', 'pin_shift_decode'],
          selected: _decode,
          onSelected: _setDecode,
        ),
        const SizedBox(height: 8),
        PinCaption(_decode ? l.pinShiftDecodeHelp : l.pinShiftEncodeHelp),
        const SizedBox(height: 14),
        SectionHeader(l.pinShiftSectionLength, padding: EdgeInsets.zero),
        const SizedBox(height: 6),
        PinCaption(l.pinShiftLengthMustMatch),
        if (locked) ...[
          const SizedBox(height: 6),
          Semantics(
            identifier: 'pin_shift_len_locked',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(child: PinCaption(l.pinShiftLengthSetBySaved)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        lockable(OptionPills<int>(
          padding: EdgeInsets.zero,
          options: [
            for (final n in _quickLengths)
              (value: n, label: l.pin24LengthButton(n)),
          ],
          identifiers: [for (final n in _quickLengths) 'pin_shift_len_$n'],
          selected: _length,
          onSelected: _setLength,
        )),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            PinCaption(l.pinShiftLengthCustom),
            Semantics(
              identifier: 'pin_shift_len_dec',
              child: IconButton.outlined(
                tooltip: l.pin24LengthShorter,
                onPressed: !locked && _length > kShiftMinLength
                    ? () => _setLength(_length - 1)
                    : null,
                icon: const Icon(Icons.remove),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44),
              child: Semantics(
                identifier: 'pin_shift_len_value',
                child: Text(
                  '$_length',
                  textAlign: TextAlign.center,
                  style: pinMono(context, size: 18),
                ),
              ),
            ),
            Semantics(
              identifier: 'pin_shift_len_inc',
              child: IconButton.outlined(
                tooltip: l.pin24LengthLonger,
                onPressed: !locked && _length < kShiftMaxLength
                    ? () => _setLength(_length + 1)
                    : null,
                icon: const Icon(Icons.add),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        PinSwitchRow(
          identifier: 'pin_shift_reveal',
          icon: Icons.visibility_outlined,
          // With a saved vector the switch reveals the PIN only.
          label: _usingSaved ? l.pinShiftRevealSaved : l.pinShiftReveal,
          caption:
              _usingSaved ? l.pinShiftRevealHelpSaved : l.pinShiftRevealHelp,
          value: _reveal,
          onChanged: (v) {
            _session.touch();
            setState(() => _reveal = v);
          },
        ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin_shift_clear',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _onClearPressed,
              icon: const Icon(Icons.backspace_outlined, size: 18),
              label: Text(l.clear),
            ),
          ),
        ),
      ],
    );
  }

  // ── Reference material (always available) ──

  Widget _aboutCard(AppLocalizations l) {
    final theme = Theme.of(context);
    return PinCard(
      children: [
        Row(
          children: [
            Icon(Icons.swap_vert_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l.pinToolShift, style: theme.textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(l.pinShiftSummary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Semantics(
          identifier: 'pin_shift_not_cipher',
          child: PinCaption(l.pinShiftCaption),
        ),
        const SizedBox(height: 12),
        Text(l.pinShiftWhyShape, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Semantics(
          identifier: 'pin_shift_keyspace',
          child: PinCaption(
            l.pinShiftWhyShapeBody(_length, _keyspaceText(l.localeName)),
          ),
        ),
      ],
    );
  }

  /// `10^L = N` with locale thousands separators (ASCII digits, so it reads
  /// the same way in every locale; en matches the source page byte for
  /// byte), in a left-to-right isolate so Arabic does not turn `10^4` into
  /// `4^10`.
  String _keyspaceText(String localeName) {
    final count = shiftKeyspace(_length).toInt();
    NumberFormat format;
    try {
      format = NumberFormat.decimalPattern(
          localeName.startsWith('ar') ? 'en' : localeName);
    } catch (_) {
      format = NumberFormat.decimalPattern('en');
    }
    return ltrIsolate('10^$_length = ${format.format(count)}');
  }

  Widget _codeBlock(String text, {String? identifier}) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: identifier,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(text, style: pinMono(context, size: 13)),
          ),
        ),
      ),
    );
  }

  /// The paper template for the chosen length and direction: blanks only,
  /// never the user's (or the saved) digits.
  String _paperTemplate() {
    final blanks = List.filled(_length, '_').join(' ');
    final unknown = List.filled(_length, '?').join(' ');
    final rule = '─' * (2 * _length + 7);
    return _decode
        ? '  new:   $blanks\n− vec:   $blanks\n  $rule\n  base:  $unknown'
        : '  base:  $blanks\n+ vec:   $blanks\n  $rule\n  new:   $unknown';
  }

  /// Worked example `1234 + 3719 = 4943` (source page / README).
  static const _encodeExample = '  base:   1 2 3 4\n'
      '+ vec:    3 7 1 9\n'
      '  ─────────────\n'
      '  raw:    4 9 4 13\n'
      '  mod10:  4 9 4 3\n'
      '  new:    4 9 4 3   ✓';

  /// Worked example `4943 − 3719 = 1234`.
  static const _decodeExample = '  new:    4 9 4 3\n'
      '− vec:    3 7 1 9\n'
      '  ─────────────\n'
      '  raw:    1 2 3 -6\n'
      '  mod10:  1 2 3 4\n'
      '  base:   1 2 3 4   ✓';

  Widget _paperCard(AppLocalizations l) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Text(text, style: theme.textTheme.titleSmall),
        );
    Widget body(String text) => Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
        );
    return PinCard(
      children: [
        PinDisclosure(
          title: l.pinShiftPaperTitle,
          identifier: 'pin_shift_paper',
          children: [
            body(_decode
                ? l.pinShiftPaperIntroDecode
                : l.pinShiftPaperIntroEncode),
            _codeBlock(_paperTemplate(),
                identifier: 'pin_shift_paper_template'),
            PinCaption(l.pinShiftPaperLegend(_length)),
            heading(l.pinShiftPaperExampleEncode),
            _codeBlock(_encodeExample),
            PinCaption(l.pinShiftPaperExampleEncodeNote),
            heading(l.pinShiftPaperExampleDecode),
            _codeBlock(_decodeExample),
            PinCaption(l.pinShiftPaperExampleDecodeNote),
            heading(l.pinShiftPaperRulesTitle),
            body(l.pinShiftPaperRules(_decode
                ? l.pinShiftDirectionDecode
                : l.pinShiftDirectionEncode)),
            heading(l.pinShiftPaperDontTitle),
            body(l.pinShiftPaperDontBody),
          ],
        ),
      ],
    );
  }

  Widget _threatCard(AppLocalizations l) {
    final theme = Theme.of(context);
    Widget section(String title, String text) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(text,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4)),
            ],
          ),
        );
    return PinCard(
      children: [
        PinDisclosure(
          title: l.pinShiftThreatTitle,
          identifier: 'pin_shift_threat',
          children: [
            Text(
              '${l.pinShiftThreatBody(_length)}\n• ${l.pinHiddenLastCharNote}',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
            section(l.pinShiftUseTitle, l.pinShiftUseBody),
            section(l.pinShiftDontUseTitle, l.pinShiftDontUseBody),
          ],
        ),
      ],
    );
  }
}
