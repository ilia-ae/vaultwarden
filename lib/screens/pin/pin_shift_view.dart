import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../l10n/app_localizations.dart';
import '../../pin_tools/pin_shift.dart';
import '../../services/shift_vectors.dart';
import '../../widgets/control_id.dart';
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
/// Top to bottom: the saved vectors to choose from (when there are any), the
/// PIN, the vector, the result, the settings (direction, length, reveal,
/// Clear), then what it is and how to do it on paper. With a saved vector
/// chosen only the PIN is typed, so the result follows it directly and the
/// vector card (edit / delete) comes after the result.
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
/// Vectors can be saved on this device under a name ([ShiftVectorStore]:
/// the keychain, encrypted with the Bitwarden account key; never the
/// preferences or the cloud) and chosen with one tap; the last choice is
/// remembered by its random id. A saved vector is used automatically and is
/// never shown again — no eye, masked cells, a masked breakdown column, no
/// weak-vector notices, no digits in any semantics label; to change it, the
/// user enters a new one (Edit). It fixes the length while chosen. The
/// in-memory digits are dropped by every wipe and by Clear and read again on
/// the next use; the saved vectors themselves survive wipes. Experimental and
/// off by default, vectors can also be read from the Bitwarden vault
/// ([ShiftVectorSource], memory only).
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

/// How far the saved vectors are known.
enum _Load {
  /// Being read (the tool just opened, or Retry).
  loading,

  /// Read (possibly none saved), or no store wired.
  ready,

  /// The keychain could not be read right now (Retry).
  error,

  /// Saved with another account's key, or damaged: can only be deleted.
  foreign,
}

/// The experimental vault reader.
enum _VaultLoad { off, loading, ready, error }

/// A vector the chooser offers: saved in the app or read from the vault.
class _Choice {
  _Choice(
    this.id,
    this.name,
    this.length, {
    required this.fromVault,
    this.digits,
  });

  final String id;
  final String name;
  final int length;
  final bool fromVault;

  /// The digits while in memory: dropped by every wipe, Clear and dispose,
  /// read again on the next use. Never rendered.
  String? digits;
}

/// The add / edit form of a saved vector.
class _Form {
  const _Form({this.editId});

  /// The saved vector being edited; null for a new one.
  final String? editId;

  bool get isNew => editId == null;
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

  /// Where saved vectors live; `null` = saving is not offered.
  ShiftVectorStore? _store;

  /// The experimental vault reader; `null` = not offered.
  ShiftVectorSource? _source;

  bool _decode = false;
  int _length = kPinShiftDefaultLength;

  // Reveal toggles: off on every visit, after every wipe and on Clear.
  bool _showPin = false;
  bool _showVector = false;
  bool _reveal = false;

  /// Bumped by every wipe and Clear: the fields are rebuilt with an empty
  /// undo history.
  int _fieldGen = 0;

  // ── Saved vectors ──

  _Load _load = _Load.ready;

  /// Why the saved set cannot be opened ([_Load.foreign]).
  ShiftVectorFailure? _foreign;

  /// Saved in the app, in saved order.
  List<_Choice> _local = const [];

  /// Read from the vault (experimental), sorted by name.
  List<_Choice> _vault = const [];
  bool _vaultOn = false;
  _VaultLoad _vaultLoad = _VaultLoad.off;

  /// The chosen vector's id; null = typed by hand.
  String? _selectedId;

  /// The user chose something on this visit: a late load does not change it.
  bool _picked = false;

  /// The add / edit form, while open.
  _Form? _form;
  final _nameCtrl = TextEditingController();
  final _nameFocus = FocusNode();

  /// The form's vector was generated here (shown once, until saved).
  bool _generated = false;

  /// A save or delete is running.
  bool _busy = false;
  bool _reloading = false;

  /// Bumped by every keychain / vault call: a late answer of an older one
  /// is ignored.
  int _loadGen = 0;
  int _vaultGen = 0;

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
    _store = ref.read(shiftVectorStoreProvider);
    _source = ref.read(shiftVectorSourceProvider);
    _vaultOn = _source != null && (_prefs?.pinShiftVaultRead ?? false);
    if (_store != null) {
      _load = _Load.loading;
      unawaited(_loadSaved());
    }
    if (_vaultOn) {
      _vaultLoad = _VaultLoad.loading;
      unawaited(_fetchVault());
    }
    _session.touch();
  }

  @override
  void dispose() {
    _session.wipes.removeListener(_onWipe);
    _unregisterProbe?.call();
    _sessionSub.close();
    for (final c in [..._local, ..._vault]) {
      c.digits = null;
    }
    _pinCtrl.clear();
    _vecCtrl.clear();
    _nameCtrl.clear();
    _pinCtrl.dispose();
    _vecCtrl.dispose();
    _nameCtrl.dispose();
    _vecFocus.dispose();
    _nameFocus.dispose();
    // Never let iOS/Android offer to save what was typed as a password.
    TextInput.finishAutofillContext(shouldSave: false);
    super.dispose();
  }

  List<_Choice> get _choices => [..._local, ..._vault];

  /// The chosen saved or vault vector; null when typing by hand (or while
  /// the chosen one is not known yet).
  _Choice? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final c in _choices) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Whether a chosen vector (rather than the field) feeds the result.
  bool get _usingSaved => _form == null && _selected != null;

  /// A chosen vector fixes the length.
  bool get _lengthLocked => _usingSaved;

  /// Whether saving is possible now (the saved set is open).
  bool get _canSave => _store != null && _load == _Load.ready;

  bool get _full => _local.length >= kMaxShiftVectors;

  bool _hasContent() =>
      _pinCtrl.text.isNotEmpty ||
      _vecCtrl.text.isNotEmpty ||
      _nameCtrl.text.isNotEmpty;

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
    _nameCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _fieldGen++;
      _showPin = false;
      _showVector = false;
      _reveal = false;
      // The saved vectors stay stored; their digits leave memory and are
      // read again on the next use. An open form is dropped.
      _wipeCount++;
      for (final c in _choices) {
        c.digits = null;
      }
      _form = null;
      _generated = false;
    });
    final chosen = _selected;
    if (chosen != null) _useLength(chosen.length);
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
    _reloadIfDropped();
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

  // ── Saved vectors: keychain and vault ──

  /// Reads the saved vectors. A keychain that cannot be read (locked device,
  /// keystore failure) is an error with Retry, never "nothing saved".
  Future<void> _loadSaved() async {
    final store = _store;
    if (store == null) return;
    final gen = ++_loadGen;
    final wipes = _wipeCount;
    List<ShiftVector>? vectors;
    ShiftVectorFailure? failure;
    try {
      vectors = await store.load();
    } on ShiftVectorException catch (e) {
      failure = e.failure;
    } catch (_) {
      failure = ShiftVectorFailure.unavailable;
    }
    if (!mounted || gen != _loadGen) return;
    setState(() {
      if (vectors != null) {
        _load = _Load.ready;
        _foreign = null;
        _local = [
          for (final v in vectors)
            _Choice(v.id, v.name, v.length,
                fromVault: false,
                // A wipe while the keychain answered: keep the list, not the
                // digits.
                digits: wipes == _wipeCount ? v.vector : null),
        ];
      } else if (failure == ShiftVectorFailure.otherAccount ||
          failure == ShiftVectorFailure.corrupt) {
        _load = _Load.foreign;
        _foreign = failure;
        _local = const [];
      } else {
        _load = _Load.error;
      }
    });
    _restoreSelection();
  }

  /// Reads the vault's vectors (experimental). The caller sets
  /// [_vaultLoad] to loading.
  Future<void> _fetchVault() async {
    final source = _source;
    if (source == null || !_vaultOn) return;
    final gen = ++_vaultGen;
    final wipes = _wipeCount;
    List<ShiftVector>? vectors;
    try {
      vectors = await source.fetch();
    } catch (_) {
      // Network, server or a locked vault: never shown as text.
    }
    if (!mounted || gen != _vaultGen || !_vaultOn) return;
    setState(() {
      if (vectors == null) {
        _vaultLoad = _VaultLoad.error;
      } else {
        _vaultLoad = _VaultLoad.ready;
        _vault = [
          for (final v in vectors)
            _Choice(v.id, v.name, v.length,
                fromVault: true, digits: wipes == _wipeCount ? v.vector : null),
        ];
      }
    });
    _restoreSelection();
  }

  /// The first use after a wipe reads the chosen vector again.
  void _reloadIfDropped() {
    final chosen = _selected;
    if (!_usingSaved || chosen == null || chosen.digits != null || _reloading) {
      return;
    }
    _reloading = true;
    final Future<void> reload;
    if (chosen.fromVault) {
      setState(() => _vaultLoad = _VaultLoad.loading);
      reload = _fetchVault();
    } else {
      reload = _loadSaved();
    }
    unawaited(reload.whenComplete(() => _reloading = false));
  }

  void _retryLoad() {
    _session.touch();
    setState(() => _load = _Load.loading);
    unawaited(_loadSaved());
  }

  void _retryVault() {
    _session.touch();
    setState(() => _vaultLoad = _VaultLoad.loading);
    unawaited(_fetchVault());
  }

  /// Once the vectors are known: the remembered choice (by id), else the
  /// first saved vector, else typing by hand — unless the user already
  /// chose on this visit.
  void _restoreSelection() {
    if (_picked || !mounted) return;
    final remembered = _prefs?.pinShiftSelected;
    String? id;
    if (remembered == PinPrefs.shiftManual) {
      id = null;
    } else if (remembered != null && _choices.any((c) => c.id == remembered)) {
      id = remembered;
    } else if (remembered != null &&
        remembered.startsWith('vault:') &&
        _vaultLoad == _VaultLoad.loading) {
      return; // wait for the vault
    } else {
      id = _local.isEmpty ? null : _local.first.id;
    }
    _applySelection(id);
  }

  void _applySelection(String? id) {
    if (_selectedId != id) setState(() => _selectedId = id);
    final chosen = _selected;
    if (chosen != null) _useLength(chosen.length);
  }

  /// The user chose a vector (or "By hand").
  void _pick(String? id) {
    _session.touch();
    _picked = true;
    if (_form != null) _closeForm();
    _applySelection(id);
    final prefs = _prefs;
    if (prefs != null) {
      unawaited(prefs.setPinShiftSelected(id ?? PinPrefs.shiftManual));
    }
    _reloadIfDropped();
  }

  void _setVaultRead(bool on) {
    _session.touch();
    final prefs = _prefs;
    if (prefs != null) unawaited(prefs.setPinShiftVaultRead(on));
    setState(() {
      _vaultOn = on;
      _vaultGen++;
      if (on) {
        _vaultLoad = _VaultLoad.loading;
      } else {
        _vaultLoad = _VaultLoad.off;
        _vault = const [];
        if (_selectedId?.startsWith('vault:') ?? false) {
          _selectedId = _local.isEmpty ? null : _local.first.id;
        }
      }
    });
    if (on) unawaited(_fetchVault());
  }

  void _snack(ScaffoldMessengerState? messenger, String text) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ── Form: add / edit ──

  /// Opens the form: a new vector ([vector] carries one typed by hand) or
  /// [editId]'s name and a new vector (empty keeps the saved one).
  void _openForm({String? editId, String vector = ''}) {
    if (!_canSave) return;
    _session.touch();
    _Choice? editing;
    for (final c in _local) {
      if (c.id == editId) editing = c;
    }
    _nameCtrl.text = editing?.name ?? '';
    _vecCtrl.text = vector;
    setState(() {
      _form = _Form(editId: editing?.id);
      _showVector = false;
      _generated = false;
    });
    if (editing != null) _useLength(editing.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _form != null) _nameFocus.requestFocus();
    });
  }

  void _closeForm() {
    final wasEdit = !(_form?.isNew ?? true);
    _nameCtrl.clear();
    // A vector typed by hand stays in the field after "Cancel" on a new
    // one; an edit's new vector does not.
    if (wasEdit || _generated) _vecCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _form = null;
      _showVector = false;
      _generated = false;
    });
    final chosen = _selected;
    if (chosen != null) _useLength(chosen.length);
  }

  void _cancelForm() {
    _session.touch();
    _nameFocus.unfocus();
    _vecFocus.unfocus();
    _closeForm();
  }

  /// Why the form's name cannot be saved; null when it can (an empty name
  /// only disables Save).
  String? _nameProblem(AppLocalizations l) {
    final name = normalizeShiftVectorName(_nameCtrl.text);
    if (name.isEmpty) return null;
    final editId = _form?.editId;
    final taken =
        _local.any((c) => c.id != editId && sameShiftVectorName(c.name, name));
    return taken ? l.pinShiftNameTaken : null;
  }

  bool _formReady(AppLocalizations l) {
    final form = _form;
    if (form == null || _busy) return false;
    final name = normalizeShiftVectorName(_nameCtrl.text);
    if (name.isEmpty || _nameProblem(l) != null) return false;
    if (!form.isNew && _vecCtrl.text.isEmpty) return true;
    return _FieldCheck(_vecCtrl.text, _length).ok;
  }

  void _generate() {
    _session.touch();
    final r = Random.secure();
    _vecCtrl.text = List.generate(_length, (_) => r.nextInt(10)).join();
    setState(() {
      _showVector = true;
      _generated = true;
    });
  }

  Future<void> _saveForm() async {
    final store = _store;
    final form = _form;
    final l = AppLocalizations.of(context)!;
    if (store == null || form == null || !_formReady(l)) return;
    _session.touch();
    _nameFocus.unfocus();
    _vecFocus.unfocus();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = normalizeShiftVectorName(_nameCtrl.text);
    final keep = !form.isNew && _vecCtrl.text.isEmpty;
    final vector = keep ? null : _FieldCheck(_vecCtrl.text, _length).value;
    _loadGen++; // an older read must not undo this
    setState(() => _busy = true);
    final String id;
    try {
      // Always from the stored set: the digits in memory may be dropped.
      final current = await store.load();
      if (form.isNew) {
        if (current.length >= kMaxShiftVectors) throw StateError('full');
        id = newShiftVectorId();
        await store.save(
            [...current, ShiftVector(id: id, name: name, vector: vector!)]);
      } else {
        id = form.editId!;
        await store.save([
          for (final v in current)
            v.id == id ? v.copyWith(name: name, vector: vector) : v,
        ]);
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _snack(messenger, l.pinShiftVectorSaveError);
      return;
    }
    if (!mounted) return;
    _nameCtrl.clear();
    _vecCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _busy = false;
      _form = null;
      _showVector = false;
      _generated = false;
      _picked = true;
      _selectedId = id;
    });
    final prefs = _prefs;
    if (prefs != null) unawaited(prefs.setPinShiftSelected(id));
    await _loadSaved();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    _snack(messenger,
        form.isNew ? l.pinShiftVectorSavedSnack : l.pinShiftVectorUpdatedSnack);
  }

  // ── Delete, discard, keep a vault vector ──

  Future<void> _deleteChosen() async {
    final store = _store;
    final chosen = _selected;
    if (store == null || chosen == null || chosen.fromVault || _busy) return;
    _session.touch();
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await confirmPinAction(
      context: context,
      session: _session,
      tone: PinDialogTone.destructive,
      title: l.pinShiftVectorDeleteNamedTitle(chosen.name),
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
      final current = await store.load();
      await store.save([
        for (final v in current)
          if (v.id != chosen.id) v,
      ]);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _snack(messenger, l.pinShiftVectorDeleteError);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _local = [
        for (final c in _local)
          if (c.id != chosen.id) c,
      ];
      _picked = true;
      _selectedId = _local.isEmpty ? null : _local.first.id;
    });
    final prefs = _prefs;
    if (prefs != null) {
      unawaited(prefs.setPinShiftSelected(_selectedId ?? PinPrefs.shiftManual));
    }
    final next = _selected;
    if (next != null) _useLength(next.length);
    HapticFeedback.mediumImpact();
    _snack(messenger, l.pinShiftVectorDeletedSnack);
  }

  /// Deletes a set that cannot be opened (another account, damaged).
  Future<void> _discardForeign() async {
    final store = _store;
    if (store == null || _load != _Load.foreign || _busy) return;
    _session.touch();
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await confirmPinAction(
      context: context,
      session: _session,
      tone: PinDialogTone.destructive,
      title: l.pinShiftVectorsDiscardTitle,
      body: l.pinShiftVectorsDiscardBody,
      confirmLabel: l.pinShiftVectorDelete,
      confirmId: 'pin_shift_vectors_discard_confirm',
      cancelId: 'pin_shift_vectors_discard_cancel',
    );
    if (!confirmed || !mounted) return;
    _loadGen++;
    setState(() => _busy = true);
    try {
      await store.discard();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _snack(messenger, l.pinShiftVectorDeleteError);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _load = _Load.ready;
      _foreign = null;
      _local = const [];
    });
    _snack(messenger, l.pinShiftVectorDeletedSnack);
  }

  /// Saves the chosen vault vector in the app under its name.
  Future<void> _keepVaultVector() async {
    final store = _store;
    final chosen = _selected;
    final digits = chosen?.digits;
    if (store == null || chosen == null || !chosen.fromVault) return;
    if (digits == null || _busy || !_canSave || _full) return;
    _session.touch();
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    _loadGen++;
    setState(() => _busy = true);
    final String id;
    try {
      final current = await store.load();
      if (current.length >= kMaxShiftVectors) throw StateError('full');
      id = newShiftVectorId();
      await store.save([
        ...current,
        ShiftVector(
          id: id,
          name: uniqueShiftVectorName(chosen.name, current),
          vector: digits,
        ),
      ]);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _snack(messenger, l.pinShiftVectorSaveError);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _picked = true;
      _selectedId = id;
    });
    final prefs = _prefs;
    if (prefs != null) unawaited(prefs.setPinShiftSelected(id));
    await _loadSaved();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    _snack(messenger, l.pinShiftVectorSavedSnack);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final pin = _FieldCheck(_pinCtrl.text, _length);
    final _FieldCheck? vec;
    if (_usingSaved) {
      final digits = _selected?.digits;
      vec = digits == null ? null : _FieldCheck(digits, _length);
    } else {
      vec = _load == _Load.loading && _form == null
          ? null
          : _FieldCheck(_vecCtrl.text, _length);
    }
    // With a chosen vector only the PIN is typed, so its result comes right
    // after it; the vector card (edit / delete) moves below.
    final resultFirst = _usingSaved;
    return Semantics(
      identifier: 'pin_shift_view',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showChooser) _chooser(l),
          _pinCard(l, pin, step: 1),
          if (resultFirst) ...[
            _resultCard(l, pin, vec, step: 2),
            _vectorCard(l, step: 3),
          ] else ...[
            _vectorCard(l, step: 2),
            _resultCard(l, pin, vec, step: 3),
          ],
          _settingsCard(l, step: 4),
          _aboutCard(l),
          _paperCard(l),
          _threatCard(l),
        ],
      ),
    );
  }

  /// The chooser shows once there is something to choose from (or the vault
  /// option is on).
  bool get _showChooser =>
      _store != null && (_local.isNotEmpty || _vault.isNotEmpty || _vaultOn);

  /// Saved vectors (and vault ones) as one row of pills: one tap chooses.
  Widget _chooser(AppLocalizations l) {
    final theme = Theme.of(context);
    final pills = <Widget>[
      for (var i = 0; i < _local.length; i++)
        OptionPill(
          label: _local[i].name,
          selected: _selectedId == _local[i].id && _form == null,
          identifier: 'pin_shift_pick_$i',
          onTap: () => _pick(_local[i].id),
        ),
      for (var i = 0; i < _vault.length; i++)
        OptionPill(
          label: _vault[i].name,
          icon: Icons.cloud_download_outlined,
          semanticsLabel: l.pinShiftVaultChipSemantics(_vault[i].name),
          selected: _selectedId == _vault[i].id && _form == null,
          identifier: 'pin_shift_pick_vault_$i',
          onTap: () => _pick(_vault[i].id),
        ),
      OptionPill(
        label: l.pinShiftManual,
        icon: Icons.keyboard_outlined,
        selected: _selectedId == null && _form == null,
        identifier: 'pin_shift_pick_manual',
        onTap: () => _pick(null),
      ),
      if (_canSave && !_full)
        OptionPill(
          label: l.pinShiftAddVector,
          icon: Icons.add,
          selected: _form?.isNew ?? false,
          identifier: 'pin_shift_add',
          onTap: _busy ? () {} : () => _openForm(),
        ),
    ];
    return PinCard(
      title: l.pinShiftSavedVectors,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: pills),
        if (_vaultOn) ...[
          const SizedBox(height: 10),
          switch (_vaultLoad) {
            _VaultLoad.loading => Semantics(
                identifier: 'pin_shift_vault_loading',
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: PinCaption(l.pinShiftVaultLoading)),
                  ],
                ),
              ),
            _VaultLoad.error => Semantics(
                identifier: 'pin_shift_vault_error',
                child: PinNotice(
                  l.pinShiftVaultError,
                  kind: PinNoticeKind.error,
                  action: Semantics(
                    identifier: 'pin_shift_vault_retry',
                    child: TextButton.icon(
                      onPressed: _retryVault,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(l.retry),
                    ),
                  ),
                ),
              ),
            _ when _vault.isEmpty => Semantics(
                identifier: 'pin_shift_vault_empty',
                child: PinCaption(l.pinShiftVaultEmpty),
              ),
            _ => const SizedBox.shrink(),
          },
        ],
        if (_full) ...[
          const SizedBox(height: 8),
          Text(
            l.pinShiftVectorsFull(kMaxShiftVectors),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  /// A card title numbered in screen order ("1 · PIN").
  static String _stepTitle(int step, String title) => '$step · $title';

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

  Widget _pinCard(AppLocalizations l, _FieldCheck pin, {required int step}) {
    return PinCard(
      title: _stepTitle(step, l.pinShiftSectionPin),
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

  Widget _vectorCard(AppLocalizations l, {required int step}) {
    final form = _form;
    final chosen = _selected;
    final String title;
    if (form == null) {
      title = l.pinShiftSectionVector;
    } else if (form.isNew) {
      title = l.pinShiftFormNew;
    } else {
      title = l.pinShiftFormEdit(normalizeShiftVectorName(
          _local.firstWhere((c) => c.id == form.editId).name));
    }
    return PinCard(
      title: _stepTitle(step, title),
      children: [
        if (_load == _Load.loading && form == null)
          _loadingSaved()
        else if (form != null)
          ..._formBody(l, form)
        else if (chosen != null && chosen.fromVault)
          ..._vaultVectorBody(l, chosen)
        else if (chosen != null)
          ..._savedVectorBody(l, chosen)
        else ...[
          if (_load == _Load.error) ...[
            _readError(l),
            const SizedBox(height: 10),
          ],
          if (_load == _Load.foreign) ...[
            _foreignNotice(l),
            const SizedBox(height: 10),
          ],
          ..._manualEntry(l),
        ],
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

  /// The vector field: typed by hand (revealable), or the form's new vector.
  Widget _vectorField(AppLocalizations l,
      {required String label, required String helper}) {
    return PinSecretField(
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
      helperText: helper,
      onChanged: (v) {
        if (_generated) setState(() => _generated = false);
        _edited(v);
      },
      suffixIcon: _eye(
        identifier: 'pin_shift_vector_eye',
        field: label,
        shown: _showVector,
        onPressed: () => setState(() => _showVector = !_showVector),
      ),
    );
  }

  /// Typing by hand: the vector field and "Save on this device".
  List<Widget> _manualEntry(AppLocalizations l) {
    final vec = _FieldCheck(_vecCtrl.text, _length);
    return [
      _vectorField(l,
          label: l.pinShiftFieldVector,
          helper: l.pinShiftFieldVectorHelp(_length)),
      ..._fieldNotes(
        check: vec,
        nonDigit: l.pinShiftVectorNonDigit,
        wrongLength: l.pinShiftVectorLengthWarning,
        idPrefix: 'pin_shift_vector',
      ),
      if (_canSave && !_full) ...[
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin_shift_vector_save',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: vec.ok && !_busy
                  ? () => _openForm(vector: _vecCtrl.text)
                  : null,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text(l.pinShiftVectorSave),
            ),
          ),
        ),
        const SizedBox(height: 6),
        PinCaption(l.pinShiftVectorSaveHelp),
      ],
    ];
  }

  /// The add / edit form: a name, the vector (shown only while typed or
  /// generated), Generate, Save and Cancel.
  List<Widget> _formBody(AppLocalizations l, _Form form) {
    final vec = _FieldCheck(_vecCtrl.text, _length);
    final keep = !form.isNew && _vecCtrl.text.isEmpty;
    final problem = _nameProblem(l);
    return [
      ControlId(
        'pin_shift_name',
        child: TextField(
          controller: _nameCtrl,
          focusNode: _nameFocus,
          enableSuggestions: false,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          inputFormatters: [
            LengthLimitingTextInputFormatter(kMaxShiftVectorNameLength),
          ],
          decoration: InputDecoration(
            labelText: l.pinShiftNameLabel,
            hintText: l.pinShiftNameHint,
            helperText: l.pinShiftNameHelp,
            helperMaxLines: 3,
            errorText: problem,
            border: const OutlineInputBorder(),
          ),
          onChanged: _edited,
        ),
      ),
      const SizedBox(height: 12),
      _vectorField(l,
          label: form.isNew ? l.pinShiftFieldVector : l.pinShiftVectorNewLabel,
          helper: form.isNew
              ? l.pinShiftFieldVectorHelp(_length)
              : l.pinShiftVectorKeepHelp),
      if (!keep)
        ..._fieldNotes(
          check: vec,
          nonDigit: l.pinShiftVectorNonDigit,
          wrongLength: l.pinShiftVectorLengthWarning,
          idPrefix: 'pin_shift_vector',
        ),
      const SizedBox(height: 10),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          identifier: 'pin_shift_generate',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _busy ? null : _generate,
            icon: const Icon(Icons.casino_outlined, size: 18),
            label: Text(l.pinShiftGenerate),
          ),
        ),
      ),
      if (_generated) ...[
        const SizedBox(height: 8),
        Semantics(
          identifier: 'pin_shift_generated_note',
          child:
              PinNotice(l.pinShiftGeneratedNote, kind: PinNoticeKind.warning),
        ),
      ],
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            identifier: 'pin_shift_vector_save',
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _formReady(l) ? _saveForm : null,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text(l.pinShiftVectorSaveReplace),
            ),
          ),
          Semantics(
            identifier: 'pin_shift_vector_cancel',
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _busy ? null : _cancelForm,
              child: Text(l.cancel),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      PinCaption(l.pinShiftVectorSaveHelp),
    ];
  }

  /// The masked cells of a chosen vector: its length, never its digits.
  Widget _maskedVector(
    AppLocalizations l,
    _Choice chosen, {
    required IconData icon,
    required String identifier,
  }) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: identifier,
      container: true,
      label: l.pinShiftVectorNamedSemantics(chosen.name, chosen.length),
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: PinColors.textFor(_vectorColor, theme.brightness),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.pinShiftVectorNamedTitle(chosen.name, chosen.length),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PinDigitCells(
              value: _mask * chosen.length,
              color: _vectorColor,
              cellWidth: 36,
              cellHeight: 44,
              fontSize: 20,
            ),
          ],
        ),
      ),
    );
  }

  /// A chosen saved vector: its name, length and fixed masks, never the
  /// digits and no way to reveal them.
  List<Widget> _savedVectorBody(AppLocalizations l, _Choice chosen) {
    final theme = Theme.of(context);
    return [
      _maskedVector(l, chosen,
          icon: Icons.lock_outline, identifier: 'pin_shift_vector_saved'),
      if (_load == _Load.error) ...[
        const SizedBox(height: 10),
        _readError(l),
      ],
      const SizedBox(height: 10),
      PinCaption(l.pinShiftVectorSavedHelp),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Semantics(
            identifier: 'pin_shift_vector_edit',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _busy || !_canSave
                  ? null
                  : () => _openForm(editId: chosen.id),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(l.pinShiftVectorEdit),
            ),
          ),
          Semantics(
            identifier: 'pin_shift_vector_delete',
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                minimumSize: const Size(0, 48),
              ),
              onPressed: _busy || !_canSave ? null : _deleteChosen,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l.pinShiftVectorDelete),
            ),
          ),
        ],
      ),
    ];
  }

  /// A chosen vault vector: masked like a saved one; "Save on this device".
  List<Widget> _vaultVectorBody(AppLocalizations l, _Choice chosen) {
    return [
      _maskedVector(l, chosen,
          icon: Icons.cloud_download_outlined,
          identifier: 'pin_shift_vector_vault'),
      const SizedBox(height: 10),
      PinCaption(l.pinShiftVaultEntryHelp),
      if (_canSave && !_full) ...[
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin_shift_vector_keep',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed:
                  _busy || chosen.digits == null ? null : _keepVaultVector,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text(l.pinShiftVectorSave),
            ),
          ),
        ),
      ],
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

  /// The saved set belongs to another account (or is damaged).
  Widget _foreignNotice(AppLocalizations l) {
    return Semantics(
      identifier: 'pin_shift_vectors_foreign',
      child: PinNotice(
        _foreign == ShiftVectorFailure.corrupt
            ? l.pinShiftVectorsCorrupt
            : l.pinShiftVectorsOtherAccount,
        kind: PinNoticeKind.error,
        action: Semantics(
          identifier: 'pin_shift_vectors_discard',
          child: TextButton.icon(
            onPressed: _busy ? null : _discardForeign,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(l.pinShiftVectorsDiscard),
          ),
        ),
      ),
    );
  }

  // ── Result ──

  /// [vec] is `null` while the vector is not available yet (the keychain is
  /// being read).
  Widget _resultCard(
    AppLocalizations l,
    _FieldCheck pin,
    _FieldCheck? vec, {
    required int step,
  }) {
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
    final chosen = _usingSaved ? _selected : null;
    return PinCard(
      title: _stepTitle(
          step,
          chosen == null
              ? l.pinShiftSectionResult
              : l.pinShiftSectionResultFor(chosen.name)),
      children: body,
    );
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

  Widget _settingsCard(AppLocalizations l, {required int step}) {
    final locked = _lengthLocked;
    // A saved vector fixes the length: the controls stay visible, disabled.
    Widget lockable(Widget child) => locked
        ? IgnorePointer(child: Opacity(opacity: 0.45, child: child))
        : child;
    return PinCard(
      title: _stepTitle(step, l.pinShiftSectionSettings),
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
        if (_source != null && _store != null) ...[
          const SizedBox(height: 10),
          PinSwitchRow(
            identifier: 'pin_shift_vault_read',
            icon: Icons.cloud_download_outlined,
            label: l.pinShiftVaultReadLabel,
            caption: l.pinShiftVaultReadHelp,
            value: _vaultOn,
            onChanged: _setVaultRead,
          ),
        ],
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
