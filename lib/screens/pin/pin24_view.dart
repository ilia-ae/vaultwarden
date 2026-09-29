import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../glass.dart' show appSpring;
import '../../l10n/app_localizations.dart';
import '../../pin_tools/bip39.dart';
import '../../pin_tools/ledger_pin24.dart' show kCharsets, kPinMask;
import '../../services/privacy_service.dart';
import '../../widgets/option_pills.dart';
import 'nickname_backup.dart';
import 'nickname_backup_picker.dart';
import 'pin24_engine.dart';
import 'pin24_selftest_hook.dart';
import 'pin_prefs.dart';
import 'pin_session.dart';
import 'pin_widgets.dart';

/// Placeholder of the seed field: a few masked words, short enough for one
/// line on a 360 pt phone (LTR and RTL) without an ellipsis.
const _seedPlaceholder = '•••• •••• •••• ••••';

/// Derivation waits this long after the last edit.
const _debounceDelay = Duration(milliseconds: 250);

/// Copied results leave the clipboard after this long.
const _copyTtl = Duration(seconds: 60);

/// Ledger PIN 24: recovery-only reimplementation of the Ledger Passwords app
/// (BIP39 seed + nickname → the PIN or password the device would type).
///
/// Secrets live only in this widget's state and in the section's
/// [PinSeedCache]; they are cleared on every [PinSession] wipe and when the
/// widget goes away. Derivation runs through [pinComputeRunnerProvider]
/// (`Isolate.run`) 250 ms after the last edit.
class Pin24View extends ConsumerStatefulWidget {
  const Pin24View({super.key});

  @override
  ConsumerState<Pin24View> createState() => _Pin24ViewState();
}

/// Output of the last successful derivation (strings cannot be zeroed; the
/// references are dropped on every edit and wipe).
class _Pin24Output {
  const _Pin24Output({
    required this.mode,
    required this.nickname,
    required this.length,
    required this.charsets,
    this.rawMask,
    this.pin,
    this.fullPassword,
    this.digitsInOutput = 0,
    this.paddedZeros = 0,
    this.password,
    this.errorCode,
  });

  final Pin24Mode mode;
  final String nickname;
  final int length;
  final Set<Pin24Charset> charsets;

  /// Password mode with a backup entry's mask the toggles cannot show.
  final int? rawMask;
  final String? pin;
  final String? fullPassword;
  final int digitsInOutput;
  final int paddedZeros;
  final String? password;
  final String? errorCode;
}

class _Pin24ViewState extends ConsumerState<Pin24View> {
  late final ProviderSubscription<PinSession> _sessionSub;
  late final PinSession _session;
  late final PrivacyService _privacy;
  late final PinComputeRunner _runner;
  late final PinPrefs _prefs;
  VoidCallback? _unregisterProbe;

  final _seedCtrl = TextEditingController();
  final _ppCtrl = TextEditingController();
  final _nickCtrl = TextEditingController();

  String _lastSeedText = '';
  String _lastPpText = '';
  SeedTextAnalysis _analysis = analyzeSeedText('');

  late bool _acknowledged;
  late Pin24Mode _mode;
  late int _length;
  late Set<Pin24Charset> _charsets;

  /// A backup entry's charset mask that the five toggles cannot express
  /// (e.g. `MINUS` alone): Password mode derives with exactly this mask
  /// until the user goes back to the toggles or changes the mode.
  int? _rawMask;

  /// Nickname-list import (the list itself lives in the session).
  bool _importing = false;
  NicknameBackupError? _importError;

  /// The nickname last filled in from the list: while the field still holds
  /// exactly that, another entry may replace it without asking (nothing the
  /// user typed is lost).
  String? _nicknameFromList;

  // Reveal toggles: off on every visit and after every wipe.
  bool _showWords = false;
  bool _revealPin = false;
  bool _showFull = false;

  /// Unpaired surrogates were dropped from the nickname.
  bool _nicknameSanitized = false;

  /// Bumped on every wipe: the fields are rebuilt with an empty undo
  /// history (seed and passphrase on every wipe, nickname on a full one).
  int _seedFieldGen = 0;
  int _nickFieldGen = 0;

  /// Opened from the YubiKey tool to enter the seed: show a way back.
  PinTool? _returnTo;
  final _seedFieldKey = GlobalKey();

  Timer? _debounce;

  /// Bumped by every edit and wipe; results of older runs are dropped.
  int _generation = 0;

  /// Bumped by every wipe; a seed derived before it is never cached.
  int _wipeEpoch = 0;
  bool _busy = false;
  _Pin24Output? _output;

  bool _checkRunning = false;
  String? _checkText;
  PinNoticeKind _checkKind = PinNoticeKind.info;

  @override
  void initState() {
    super.initState();
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _session.wipes.addListener(_onWipe);
    _unregisterProbe = _session.registerContentProbe(_hasContent);
    _privacy = ref.read(privacyServiceProvider);
    _runner = ref.read(pinComputeRunnerProvider);
    _prefs = ref.read(pinPrefsProvider).requireValue;
    _acknowledged = _prefs.pin24BannerAcknowledged;
    _mode = _prefs.pin24Mode;
    _length = _prefs.pin24Length;
    _charsets = _prefs.pin24Charsets;
    _session.seed.addListener(_onCachedSeedChanged);
    _returnTo = _session.returnTo;
    if (_returnTo != null) {
      // Sent here to enter the seed: bring the seed field into view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _seedFieldKey.currentContext;
        if (!mounted || target == null) return;
        unawaited(Scrollable.ensureVisible(
          target,
          alignment: 0.15,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 400),
          curve: appSpring,
        ));
      });
    }
    _session.touch();
  }

  void _onCachedSeedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    _wipeEpoch++;
    _session.wipes.removeListener(_onWipe);
    _session.seed.removeListener(_onCachedSeedChanged);
    _unregisterProbe?.call();
    _sessionSub.close();
    _output = null;
    _seedCtrl.clear();
    _ppCtrl.clear();
    _nickCtrl.clear();
    _seedCtrl.dispose();
    _ppCtrl.dispose();
    _nickCtrl.dispose();
    // Never let iOS/Android offer to save what was typed as a password.
    TextInput.finishAutofillContext(shouldSave: false);
    super.dispose();
  }

  bool _hasContent() =>
      _seedCtrl.text.isNotEmpty ||
      _ppCtrl.text.isNotEmpty ||
      _nickCtrl.text.isNotEmpty ||
      _output != null;

  /// A file picker sends the app to the background, and the background wipe
  /// is held off while a picker is open; so the import is offered only
  /// while there is no seed that would sit in memory meanwhile.
  bool get _canImport =>
      _seedCtrl.text.isEmpty && _ppCtrl.text.isEmpty && !_session.seed.hasSeed;

  // ── Wipes ──

  void _onWipe() {
    final event = _session.wipes.value;
    if (event == null || !mounted) return;
    _debounce?.cancel();
    _generation++;
    _wipeEpoch++;
    _seedCtrl.clear();
    _ppCtrl.clear();
    _lastSeedText = '';
    _lastPpText = '';
    if (event.scope == PinWipeScope.all) _nickCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _seedFieldGen++;
      if (event.scope == PinWipeScope.all) {
        _nickFieldGen++;
        _nicknameSanitized = false;
        _returnTo = null;
        // The session dropped the nickname list; its settings go with it.
        _rawMask = null;
        _importError = null;
        _nicknameFromList = null;
      }
      _analysis = analyzeSeedText('');
      _showWords = false;
      _revealPin = false;
      _showFull = false;
      _busy = false;
      _output = null;
      _checkText = null;
    });
  }

  Future<void> _confirmWipeAll() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await confirmPinAction(
      context: context,
      session: _session,
      tone: PinDialogTone.destructive,
      title: l.pin24WipeAllTitle,
      body: l.pin24WipeAllBody,
      confirmLabel: l.pin24WipeAllConfirm,
      confirmId: 'pin24_wipe_all_confirm',
      cancelId: 'pin24_wipe_all_cancel',
    );
    if (confirmed && mounted) {
      HapticFeedback.mediumImpact();
      _session.wipe(reason: PinWipeReason.user);
    }
  }

  void _wipeSeed() {
    HapticFeedback.mediumImpact();
    _session.wipe(scope: PinWipeScope.seed, reason: PinWipeReason.user);
  }

  // ── Inputs ──

  void _onSeedChanged(String text) {
    _session.touch();
    if (text.length - _lastSeedText.length >= PinSecretField.pasteThreshold) {
      _session.markPasted();
    }
    final completed = autoAcceptSeedEdit(_lastSeedText, text);
    if (completed != null) {
      HapticFeedback.selectionClick();
      _setSeedText(completed);
      return;
    }
    _lastSeedText = text;
    _analysis = analyzeSeedText(text);
    _inputsChanged();
  }

  /// Replaces the whole seed text (suggestion accepted, split, confirm).
  void _setSeedText(String text) {
    _seedCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _lastSeedText = text;
    _analysis = analyzeSeedText(text);
    _session.touch();
    _inputsChanged();
  }

  bool get _hadTrailingSeparator =>
      _analysis.hasText && !_analysis.endsInsideWord;

  void _acceptWord(int index, String word) {
    HapticFeedback.selectionClick();
    _setSeedText(replaceSeedWord(
      _analysis.words,
      index,
      word,
      hadTrailingSeparator: _hadTrailingSeparator,
    ));
  }

  void _confirmPendingWord() {
    HapticFeedback.selectionClick();
    _setSeedText('${_seedCtrl.text} ');
  }

  void _splitGluedWords() {
    HapticFeedback.selectionClick();
    final words = <String>[];
    for (var i = 0; i < _analysis.words.length; i++) {
      words.addAll(_analysis.uniqueSplits[i] ?? [_analysis.words[i]]);
    }
    _setSeedText(words.join(' ') + (_hadTrailingSeparator ? ' ' : ''));
  }

  void _onPassphraseChanged(String text) {
    _session.touch();
    if (text.length - _lastPpText.length >= PinSecretField.pasteThreshold) {
      _session.markPasted();
    }
    _lastPpText = text;
    _inputsChanged();
  }

  void _onNicknameChanged(String nickname) {
    _session.touch();
    if (nickname.isEmpty) _nicknameSanitized = false;
    _inputsChanged();
  }

  void _onMenuPaste() {
    if (mounted) _session.markPasted();
  }

  void _backToReturnTool() {
    final to = _returnTo;
    if (to == null) return;
    _session.touch();
    HapticFeedback.selectionClick();
    _session.returnTo = null;
    ref.read(pinToolProvider.notifier).state = to;
  }

  void _setMode(Pin24Mode mode) {
    _session.touch();
    _rawMask = null;
    // Every tap on Password restores the device defaults, so separators or
    // specials switched on earlier never surprise the user.
    if (mode == Pin24Mode.password) {
      _charsets = {...kPin24DefaultCharsets};
      unawaited(_prefs.setPin24Charsets(_charsets));
    }
    _mode = mode;
    unawaited(_prefs.setPin24Mode(mode));
    _inputsChanged();
  }

  void _setLength(int length) {
    _session.touch();
    _length = clampPin24Length(length);
    unawaited(_prefs.setPin24Length(_length));
    _inputsChanged();
  }

  void _toggleCharset(Pin24Charset charset) {
    _session.touch();
    _rawMask = null;
    final next = {..._charsets};
    if (!next.remove(charset)) next.add(charset);
    _charsets = next;
    unawaited(_prefs.setPin24Charsets(next));
    _inputsChanged();
  }

  Future<void> _acknowledge() async {
    HapticFeedback.lightImpact();
    await _prefs.setPin24BannerAcknowledged();
    if (mounted) setState(() => _acknowledged = true);
  }

  // ── Nickname list (Ledger Passwords backup) ──

  Future<void> _importFile() async {
    if (!_canImport || _importing) return;
    _session.touch();
    final pick = ref.read(nicknameBackupPickerProvider);
    setState(() {
      _importing = true;
      _importError = null;
    });
    NicknameBackup? backup;
    NicknameBackupError? error;
    try {
      final bytes = await pick();
      if (bytes != null) backup = parseNicknameBackup(bytes);
    } on NicknameBackupException catch (e) {
      error = e.error;
    } catch (_) {
      // Picker or I/O failure: deliberately not logged (it names the file).
      error = NicknameBackupError.unreadable;
    }
    if (!mounted) return;
    _session.touch();
    setState(() {
      _importing = false;
      _importError = error;
      if (backup != null) _session.nicknameBackup = backup;
    });
  }

  void _forgetList() {
    _session.touch();
    HapticFeedback.selectionClick();
    setState(() {
      _session.nicknameBackup = null;
      _importError = null;
    });
  }

  /// Short description of an entry's charsets: the toggle labels when the
  /// toggles can show the mask, else the exact sets.
  String _entryCharsets(AppLocalizations l, int mask) {
    final toggles = pin24CharsetsForMask(mask);
    if (toggles == null) return ledgerCharsetsLabel(mask);
    return [
      for (final c in Pin24Charset.values)
        if (toggles.contains(c)) _charsetLabel(l, c),
    ].join(' + ');
  }

  Future<void> _chooseFromList() async {
    final backup = _session.nicknameBackup;
    if (backup == null) return;
    _session.touch();
    final l = AppLocalizations.of(context)!;
    Widget tile(BuildContext context, NicknameBackupEntry e, {int? index}) {
      final item = ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(e.nickname, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          ltrIsolate(_entryCharsets(l, e.mask)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: index == null ? null : () => Navigator.pop(context, e),
      );
      return index == null
          ? item
          : Semantics(identifier: 'pin24_import_entry_$index', child: item);
    }

    final entry = await showPinDialog<NicknameBackupEntry>(
      context: context,
      session: _session,
      builder: (context) => AlertDialog(
        title: Text(l.pin24ImportChooseTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: backup.entries.length,
              // Every row has the same shape: the list is sized without
              // building all of them.
              prototypeItem: tile(context, backup.entries.first),
              itemBuilder: (context, i) =>
                  tile(context, backup.entries[i], index: i),
            ),
          ),
        ),
        actions: [
          Semantics(
            identifier: 'pin24_import_choose_cancel',
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.cancel),
            ),
          ),
        ],
      ),
    );
    if (entry == null || !mounted || _session.nicknameBackup != backup) return;

    // Never overwrite what the user typed without asking.
    final typed = _nickCtrl.text;
    if (typed.isNotEmpty &&
        typed != entry.nickname &&
        typed != _nicknameFromList) {
      final replace = await confirmPinAction(
        context: context,
        session: _session,
        tone: PinDialogTone.sensitive,
        icon: Icons.edit_outlined,
        title: l.pin24ImportReplaceTitle,
        body: l.pin24ImportReplaceBody,
        confirmLabel: l.pin24ImportReplaceConfirm,
        confirmId: 'pin24_import_replace_confirm',
        cancelId: 'pin24_import_replace_cancel',
      );
      if (!replace ||
          !mounted ||
          _session.nicknameBackup != backup ||
          _nickCtrl.text != typed) {
        return;
      }
    }
    _applyEntry(entry);
  }

  /// Fills the nickname and sets the entry's charsets: PIN mode for the
  /// device's PIN mask (numbers + separators), otherwise Password mode with
  /// the matching toggles, or the raw mask when the toggles cannot show it.
  void _applyEntry(NicknameBackupEntry entry) {
    _session.touch();
    HapticFeedback.selectionClick();
    if (_nickCtrl.text != entry.nickname) {
      _nickCtrl.value = TextEditingValue(
        text: entry.nickname,
        selection: TextSelection.collapsed(offset: entry.nickname.length),
      );
      _nicknameSanitized = false;
    }
    _nicknameFromList = entry.nickname;
    final toggles = pin24CharsetsForMask(entry.mask);
    if (entry.mask == kPinMask) {
      _mode = Pin24Mode.pin;
      _rawMask = null;
    } else {
      _mode = Pin24Mode.password;
      _rawMask = toggles == null ? entry.mask : null;
      if (toggles != null) {
        _charsets = toggles;
        unawaited(_prefs.setPin24Charsets(toggles));
      }
    }
    unawaited(_prefs.setPin24Mode(_mode));
    _inputsChanged();
  }

  void _useToggles() {
    _session.touch();
    HapticFeedback.selectionClick();
    _rawMask = null;
    _inputsChanged();
  }

  // ── Derivation ──

  /// Which gate blocks derivation (1: phrase, 2: nickname, 3: charsets), or
  /// 0 when none does. Checked in this order.
  int get _gate {
    if (!_analysis.validation.isValid) return 1;
    if (_nickCtrl.text.isEmpty) return 2;
    if (_mode == Pin24Mode.password && _rawMask == null && _charsets.isEmpty) {
      return 3;
    }
    return 0;
  }

  void _inputsChanged() {
    _debounce?.cancel();
    _generation++;
    final gate = _gate;
    final ready = gate == 0;
    setState(() {
      _output = null;
      _busy = ready;
    });
    final generation = _generation;
    if (ready) {
      _debounce = Timer(_debounceDelay, () => _derive(generation));
    } else if (gate != 1) {
      // The phrase is valid but no nickname (or charset) yet: derive and
      // cache the seed now, so the YubiKey tool can use it at once.
      _debounce = Timer(_debounceDelay, () => _cacheSeed(generation));
    }
  }

  /// Whether [key] still describes the phrase and passphrase in the fields.
  bool _keyIsCurrent(Uint8List key) {
    if (!_analysis.validation.isValid) return false;
    final current =
        PinSeedCache.keyFor(_analysis.parsed.canonical, _ppCtrl.text);
    var diff = key.length ^ current.length;
    for (var i = 0; i < key.length && i < current.length; i++) {
      diff |= key[i] ^ current[i];
    }
    return diff == 0;
  }

  /// Derives the seed alone (no nickname needed) and caches it for the
  /// section, unless it is cached already.
  Future<void> _cacheSeed(int generation) async {
    if (!mounted || generation != _generation) return;
    if (!_analysis.validation.isValid) return;
    final epoch = _wipeEpoch;
    final wordCount = _analysis.words.length;
    final canonical = _analysis.parsed.canonical;
    final passphrase = _ppCtrl.text;
    final key = PinSeedCache.keyFor(canonical, passphrase);
    final cached = _session.seed.lookup(key);
    if (cached != null) {
      cached.fillRange(0, cached.length, 0);
      key.fillRange(0, key.length, 0);
      return;
    }
    Pin24Response response;
    try {
      response = await runPin24Seed(
        _runner,
        Pin24SeedRequest(canonicalPhrase: canonical, passphrase: passphrase),
      );
    } catch (_) {
      // Deliberately not logged or rethrown: the error could carry input.
      response = const Pin24Response(errorCode: pin24UnexpectedError);
    }
    final fresh = response.freshSeed;
    if (fresh != null && mounted && epoch == _wipeEpoch && _keyIsCurrent(key)) {
      _session.seed.store(key, fresh, wordCount: wordCount);
    } else {
      fresh?.fillRange(0, fresh.length, 0);
      key.fillRange(0, key.length, 0);
    }
  }

  Future<void> _derive(int generation) async {
    if (!mounted || generation != _generation) return;
    final epoch = _wipeEpoch;
    final mode = _mode;
    final nickname = _nickCtrl.text;
    final length = _length;
    final charsets = {..._charsets};
    final rawMask = mode == Pin24Mode.password ? _rawMask : null;
    final wordCount = _analysis.words.length;
    final canonical = _analysis.parsed.canonical;
    final passphrase = _ppCtrl.text;
    final key = PinSeedCache.keyFor(canonical, passphrase);
    final cached = _session.seed.lookup(key);
    final request = Pin24Request(
      canonicalPhrase: cached == null ? canonical : null,
      passphrase: cached == null ? passphrase : '',
      cachedSeed: cached,
      nickname: nickname,
      mode: mode,
      length: length,
      setMask: rawMask ?? pin24MaskOf(charsets),
    );
    Pin24Response response;
    try {
      response = await runPin24(_runner, request);
    } catch (_) {
      // Deliberately not logged or rethrown: the error could carry input.
      response = const Pin24Response(errorCode: pin24UnexpectedError);
    } finally {
      cached?.fillRange(0, cached.length, 0);
    }
    final fresh = response.freshSeed;
    if (fresh != null && mounted && epoch == _wipeEpoch && _keyIsCurrent(key)) {
      // Keyed by phrase + passphrase, so it is valid even if the nickname
      // or mode changed meanwhile (but not if the phrase did).
      _session.seed.store(key, fresh, wordCount: wordCount);
    } else {
      fresh?.fillRange(0, fresh.length, 0);
      key.fillRange(0, key.length, 0);
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _busy = false;
      _output = _Pin24Output(
        mode: mode,
        nickname: nickname,
        length: length,
        charsets: charsets,
        rawMask: rawMask,
        pin: response.pin,
        fullPassword: response.fullPassword,
        digitsInOutput: response.digitsInOutput,
        paddedZeros: response.paddedZeros,
        password: response.password,
        errorCode: response.errorCode,
      );
    });
  }

  Future<bool> _copy(String value) {
    _session.touch();
    return _privacy.copySensitive(value, ttl: _copyTtl);
  }

  Future<void> _runEngineCheck() async {
    final l = AppLocalizations.of(context)!;
    _session.touch();
    setState(() {
      _checkRunning = true;
      _checkText = null;
    });
    Pin24EngineCheckResult result;
    try {
      result = await pin24EngineCheck(
        _runner,
        vectors: ref.read(pin24SelfTestVectorsProvider),
      );
    } catch (_) {
      result = const Pin24EngineCheckResult(passed: 0, total: 0);
    }
    if (!mounted) return;
    setState(() {
      _checkRunning = false;
      if (result.ok) {
        _checkKind = PinNoticeKind.ok;
        _checkText = l.pin24SelfTestOk(result.passed, result.total);
      } else {
        _checkKind = PinNoticeKind.error;
        _checkText =
            l.pin24SelfTestFailed(result.total - result.passed, result.total);
      }
    });
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _introCard(l),
        _seedCard(l),
        _nicknameCard(l),
        _modeCard(l),
        _outputCard(l),
        _threatModelCard(l),
        _cleanupCard(l),
      ],
    );
  }

  Widget _introCard(AppLocalizations l) {
    final theme = Theme.of(context);
    final about = [
      Text(l.pin24Summary, style: theme.textTheme.bodyMedium),
      const SizedBox(height: 6),
      PinCaption(l.pin24Bullets),
      const SizedBox(height: 10),
      PinCaption(l.pin24Caption),
    ];
    return PinCard(
      children: [
        Row(
          children: [
            Icon(Icons.grid_view_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l.pinToolPin24, style: theme.textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Before "I understand": everything. After: the banner stays (it is
        // shown every time), the description folds away so the seed field
        // is close to the top.
        if (!_acknowledged) ...[
          ...about,
          const SizedBox(height: 12),
        ],
        PinBanner(child: Text(l.pin24Banner)),
        if (_acknowledged)
          PinDisclosure(
            title: l.pin24AboutTitle,
            identifier: 'pin24_about',
            children: about,
          )
        else ...[
          const SizedBox(height: 12),
          Semantics(
            identifier: 'pin24_ack',
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _acknowledge,
              icon: const Icon(Icons.check),
              label: Text(l.pin24Acknowledge),
            ),
          ),
        ],
      ],
    );
  }

  Widget _seedCard(AppLocalizations l) {
    final theme = Theme.of(context);
    final a = _analysis;
    return PinCard(
      title: l.pin24SectionSeed,
      children: [
        if (_returnTo == PinTool.yubikey) ...[
          Semantics(
            identifier: 'pin24_from_yk',
            child: PinNotice(
              l.pin24FromYubikey,
              action: Semantics(
                identifier: 'pin24_back_to_yk',
                child: FilledButton.tonalIcon(
                  onPressed: _backToReturnTool,
                  icon: const Icon(Icons.vpn_key_outlined, size: 18),
                  label: Text(l.pin24BackToYubikey),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
        PinCaption(l.pin24SeedLabel),
        if (!_acknowledged) ...[
          const SizedBox(height: 6),
          Semantics(
            identifier: 'pin24_ack_required',
            child: PinNotice(l.pin24AckRequired),
          ),
        ],
        const SizedBox(height: 8),
        KeyedSubtree(
          key: _seedFieldKey,
          child: PinSecretField(
            controller: _seedCtrl,
            identifier: 'pin24_seed',
            wipeGeneration: _seedFieldGen,
            enabled: _acknowledged,
            textDirection: TextDirection.ltr,
            hintText: _seedPlaceholder,
            helperText: l.pin24SeedHelp,
            onChanged: _onSeedChanged,
            onPasted: _onMenuPaste,
            normalizePaste: normalizePastedSeed,
          ),
        ),
        const SizedBox(height: 4),
        Semantics(
          identifier: 'pin24_autocomplete_hint',
          child: PinCaption(l.pin24AutoCompleteHint),
        ),
        PinClipboardReminder(
          session: _session,
          identifier: 'pin24_clear_clipboard',
        ),
        const SizedBox(height: 4),
        PinSwitchRow(
          identifier: 'pin24_show_words',
          icon: Icons.visibility_outlined,
          label: l.pin24ShowWords,
          caption: l.pin24ShowWordsHelp,
          value: _showWords,
          onChanged: (v) {
            _session.touch();
            setState(() => _showWords = v);
          },
        ),
        const SizedBox(height: 6),
        PinWordCells(
          words: a.words,
          states: a.states,
          target: a.target,
          reveal: _showWords,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(l.pin24WordsMetric, style: theme.textTheme.labelLarge),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                l.pin24WordsCounter(a.words.length, a.target),
                style: pinMono(context, size: 15),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ..._seedFeedback(l),
        const SizedBox(height: 4),
        PinDisclosure(
          title: l.pin24PassphraseTitle,
          identifier: 'pin24_passphrase_section',
          initiallyExpanded: _ppCtrl.text.isNotEmpty,
          // A passphrase changes every result: say so while folded away.
          badge: _ppCtrl.text.isNotEmpty ? l.pin24PassphraseSet : null,
          children: [
            PinSecretField(
              controller: _ppCtrl,
              identifier: 'pin24_passphrase',
              wipeGeneration: _seedFieldGen,
              enabled: _acknowledged,
              labelText: l.pin24PassphraseLabel,
              onChanged: _onPassphraseChanged,
              onPasted: _onMenuPaste,
            ),
            const SizedBox(height: 8),
            PinCaption(l.pin24PassphraseCaption),
            if (hasEdgeWhitespace(_ppCtrl.text)) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Semantics(
                  identifier: 'pin24_passphrase_whitespace',
                  child: PinWarningChip(l.pin24PassphraseWhitespace),
                ),
              ),
            ],
          ],
        ),
        ..._seedKeptHint(l),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Semantics(
              identifier: 'pin24_wipe_seed',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _wipeSeed,
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: Text(l.pin24WipeSeed),
              ),
            ),
            Semantics(
              identifier: 'pin24_wipe_all',
              child: _wipeAllButton(l),
            ),
          ],
        ),
        const SizedBox(height: 6),
        PinCaption(l.pin24WipeSeedHelp),
      ],
    );
  }

  /// The seed cached for the section (the YubiKey tool may use it): a note
  /// while it matches the field, a Wipe action once the field no longer
  /// holds it (e.g. back from another tool).
  List<Widget> _seedKeptHint(AppLocalizations l) {
    final cache = _session.seed;
    if (!cache.hasSeed) return const [];
    if (_analysis.validation.isValid) {
      return [
        const SizedBox(height: 6),
        Semantics(
          identifier: 'pin24_seed_kept',
          child: PinCaption(l.pin24SeedKept),
        ),
      ];
    }
    return [
      const SizedBox(height: 6),
      Semantics(
        identifier: 'pin24_seed_in_memory',
        child: PinNotice(
          l.pinSeedInMemory(cache.wordCount),
          action: Semantics(
            identifier: 'pin_wipe_cached_seed',
            child: TextButton.icon(
              onPressed: _wipeSeed,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: Text(l.pin24WipeSeed),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _wipeAllButton(AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: cs.error,
        side: BorderSide(color: cs.error.withAlpha(128)),
      ),
      onPressed: _confirmWipeAll,
      icon: const Icon(Icons.delete_forever_outlined, size: 18),
      label: Text(l.pin24WipeAll),
    );
  }

  /// Status line, invalid/partial/glued/ambiguous notes and suggestions.
  List<Widget> _seedFeedback(AppLocalizations l) {
    final a = _analysis;
    final out = <Widget>[];
    final v = a.validation;
    if (a.words.isEmpty) {
      if (a.hasText) out.add(PinNotice(l.pin24StatusEmpty));
    } else {
      out.add(switch (v.status) {
        Bip39Status.empty => PinNotice(l.pin24StatusEmpty),
        Bip39Status.wrongCount => PinNotice(l.pin24StatusCount(v.wordCount)),
        Bip39Status.notInWordlist => PinNotice(l.pin24StatusWordlist),
        Bip39Status.badChecksum => PinNotice(l.pin24StatusChecksum),
        Bip39Status.ok =>
          PinNotice(l.pin24StatusOk(v.wordCount), kind: PinNoticeKind.ok),
      });
    }

    String positions(Iterable<int> zeroBased) =>
        ltrIsolate(zeroBased.map((i) => '${i + 1}').join(', '));

    // Invalid words (glued ones get their own, more helpful note).
    final invalid = [
      for (final i in a.parsed.invalidPositions)
        if (!a.gluedPositions.contains(i)) i,
    ];
    if (invalid.isNotEmpty) {
      out.add(PinNotice(
        _showWords
            ? l.pin24InvalidRevealed(ltrIsolate(
                invalid.map((i) => '“${a.words[i]}” (#${i + 1})').join(', ')))
            : l.pin24InvalidMasked(positions(invalid)),
        kind: PinNoticeKind.error,
      ));
    }
    if (a.gluedPositions.isNotEmpty) {
      out.add(PinNotice(
        l.pin24GluedWords(positions(a.gluedPositions)),
        kind: PinNoticeKind.warning,
      ));
      if (a.uniqueSplits.isNotEmpty) {
        out.add(Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin24_split_glued',
            child: TextButton.icon(
              onPressed: _splitGluedWords,
              icon: const Icon(Icons.call_split, size: 18),
              label: Text(l.pin24GluedSplit),
            ),
          ),
        ));
      }
    }

    // Partial words: completions only while 👁 is on (they reveal prefixes).
    final partial = a.parsed.partialPositions;
    if (partial.isNotEmpty) {
      if (!_showWords) {
        out.add(PinNotice(
          l.pin24PartialMasked(positions(partial)),
          kind: PinNoticeKind.warning,
        ));
      } else {
        out.add(PinNotice(l.pin24PartialRevealed, kind: PinNoticeKind.warning));
        for (final i in partial) {
          out.add(_suggestionRow(
            l,
            index: i,
            prefix: a.words[i],
            options: suggestionsForPrefix(a.words[i]),
          ));
        }
      }
    }

    // A complete word that also starts longer words: confirm or keep typing.
    final pending = a.pendingAmbiguousPosition;
    if (pending != null) {
      out.add(PinNotice(l.pin24AmbiguousWord(pending + 1)));
      if (_showWords) {
        out.add(_suggestionRow(
          l,
          index: pending,
          prefix: a.words[pending],
          options: suggestionsForPrefix(a.words[pending]),
        ));
      } else {
        out.add(Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin24_confirm_word',
            child: TextButton.icon(
              onPressed: _confirmPendingWord,
              icon: const Icon(Icons.check, size: 18),
              label: Text(l.pin24ConfirmWord(pending + 1)),
            ),
          ),
        ));
      }
    }

    if (a.hasNonAsciiLetters) {
      out.add(PinNotice(l.pin24NonAscii, kind: PinNoticeKind.warning));
    }
    return out;
  }

  Widget _suggestionRow(
    AppLocalizations l, {
    required int index,
    required String prefix,
    required List<String> options,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('#${index + 1} “$prefix” →',
                style: pinMono(context, size: 13)),
            if (options.isEmpty) Text(l.pin24NoCompletions),
            for (final word in options)
              Semantics(
                identifier: 'pin24_suggest_${index + 1}_$word',
                child: ActionChip(
                  label: Text(word, style: pinMono(context, size: 13)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _acceptWord(index, word),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _nicknameCard(AppLocalizations l) {
    final warnings = NicknameWarnings.of(_nickCtrl.text);
    return PinCard(
      title: l.pin24SectionNickname,
      children: [
        PinSecretField(
          controller: _nickCtrl,
          identifier: 'pin24_nickname',
          wipeGeneration: _nickFieldGen,
          obscure: false,
          labelText: l.pin24NicknameLabel,
          hintText: 'visa',
          helperText: l.pin24NicknameHelp,
          onChanged: _onNicknameChanged,
          onBrokenCharactersRemoved: () => _nicknameSanitized = true,
        ),
        if (warnings.any || _nicknameSanitized) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_nicknameSanitized)
                PinWarningChip(l.pin24NicknameBrokenRemoved),
              if (warnings.edgeWhitespace)
                PinWarningChip(l.pin24NicknameWhitespace),
              if (warnings.nonAscii) PinWarningChip(l.pin24NicknameNonAscii),
              if (warnings.tooLong)
                PinWarningChip(l.pin24NicknameTooLong(
                    warnings.utf8Bytes, kLedgerMaxNicknameBytes)),
            ],
          ),
        ],
        const SizedBox(height: 4),
        _importSection(l),
      ],
    );
  }

  Widget _importSection(AppLocalizations l) {
    final backup = _session.nicknameBackup;
    final error = _importError;
    return PinDisclosure(
      title: l.pin24ImportTitle,
      identifier: 'pin24_import',
      initiallyExpanded: backup != null,
      children: [
        PinCaption(l.pin24ImportHelp),
        const SizedBox(height: 8),
        if (backup == null) ...[
          if (!_canImport) ...[
            Semantics(
              identifier: 'pin24_import_blocked',
              child: PinNotice(l.pin24ImportBlocked),
            ),
            const SizedBox(height: 6),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              identifier: 'pin24_import_file',
              enabled: _canImport && !_importing,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _canImport && !_importing ? _importFile : null,
                icon: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_open_outlined, size: 18),
                label: Text(l.pin24ImportFile),
              ),
            ),
          ),
        ] else ...[
          Semantics(
            identifier: 'pin24_import_loaded',
            child: PinNotice(
              l.pin24ImportLoaded(backup.entries.length),
              kind: PinNoticeKind.ok,
            ),
          ),
          if (backup.skipped > 0)
            Semantics(
              identifier: 'pin24_import_skipped',
              child: PinNotice(
                l.pin24ImportSkipped(backup.skipped),
                kind: PinNoticeKind.warning,
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Semantics(
                identifier: 'pin24_import_choose',
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _chooseFromList,
                  icon: const Icon(Icons.list_alt_outlined, size: 18),
                  label: Text(l.pin24ImportChoose),
                ),
              ),
              Semantics(
                identifier: 'pin24_import_forget',
                child: TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _forgetList,
                  icon: const Icon(Icons.playlist_remove, size: 18),
                  label: Text(l.pin24ImportForget),
                ),
              ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 6),
          Semantics(
            identifier: 'pin24_import_error',
            child: PinNotice(
              switch (error) {
                NicknameBackupError.tooLarge => l.pin24ImportErrorTooLarge,
                NicknameBackupError.unreadable => l.pin24ImportErrorRead,
                NicknameBackupError.empty => l.pin24ImportErrorEmpty,
              },
              kind: PinNoticeKind.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _modeCard(AppLocalizations l) {
    return PinCard(
      title: l.pin24SectionMode,
      children: [
        OptionPills<Pin24Mode>(
          padding: EdgeInsets.zero,
          options: [
            (value: Pin24Mode.pin, label: l.pin24ModePin),
            (value: Pin24Mode.password, label: l.pin24ModePassword),
          ],
          identifiers: const ['pin24_mode_pin', 'pin24_mode_password'],
          selected: _mode,
          onSelected: _setMode,
        ),
        const SizedBox(height: 8),
        PinCaption(_mode == Pin24Mode.pin
            ? l.pin24ModePinHelp
            : l.pin24ModePasswordHelp),
        const SizedBox(height: 14),
        if (_mode == Pin24Mode.pin) ...[
          SectionHeader(l.pin24Length, padding: EdgeInsets.zero),
          const SizedBox(height: 6),
          OptionPills<int>(
            padding: EdgeInsets.zero,
            options: [
              for (final n in kPin24QuickLengths)
                (value: n, label: l.pin24LengthButton(n)),
            ],
            identifiers: [for (final n in kPin24QuickLengths) 'pin24_len_$n'],
            selected: _length,
            onSelected: _setLength,
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              PinCaption(l.pin24LengthCustom),
              Semantics(
                identifier: 'pin24_len_dec',
                child: IconButton.outlined(
                  tooltip: l.pin24LengthShorter,
                  onPressed: _length > kPin24MinLength
                      ? () => _setLength(_length - 1)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 44),
                child: Text(
                  '$_length',
                  textAlign: TextAlign.center,
                  style: pinMono(context, size: 18),
                ),
              ),
              Semantics(
                identifier: 'pin24_len_inc',
                child: IconButton.outlined(
                  tooltip: l.pin24LengthLonger,
                  onPressed: _length < kPin24MaxLength
                      ? () => _setLength(_length + 1)
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
        ] else if (_rawMask != null) ...[
          SectionHeader(l.pin24Charsets, padding: EdgeInsets.zero),
          const SizedBox(height: 6),
          Semantics(
            identifier: 'pin24_raw_mask',
            child: PinNotice(
              l.pin24ImportRawMask(ltrIsolate(
                  '${ledgerCharsetsLabel(_rawMask!)} · 0x${_rawMask!.toRadixString(16).padLeft(2, '0').toUpperCase()}')),
              kind: PinNoticeKind.warning,
              action: Semantics(
                identifier: 'pin24_raw_mask_exit',
                child: TextButton.icon(
                  onPressed: _useToggles,
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(l.pin24ImportUseToggles),
                ),
              ),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: SectionHeader(l.pin24Charsets, padding: EdgeInsets.zero),
              ),
              Semantics(
                identifier: 'pin24_charset_help',
                child: IconButton(
                  tooltip: l.pin24SpecialsTitle,
                  icon: const Icon(Icons.info_outline),
                  onPressed: _showSpecialsHelp,
                ),
              ),
            ],
          ),
          MultiOptionPills<Pin24Charset>(
            padding: EdgeInsets.zero,
            options: [
              for (final c in Pin24Charset.values)
                (value: c, label: _charsetLabel(l, c)),
            ],
            identifiers: [
              for (final c in Pin24Charset.values) 'pin24_cs_${c.name}',
            ],
            selected: _charsets,
            onToggled: _toggleCharset,
          ),
          if (_charsets.isEmpty) ...[
            const SizedBox(height: 8),
            PinNotice(l.pin24CharsetNone, kind: PinNoticeKind.warning),
          ],
        ],
      ],
    );
  }

  String _charsetLabel(AppLocalizations l, Pin24Charset c) => switch (c) {
        Pin24Charset.upper => 'A-Z',
        Pin24Charset.lower => 'a-z',
        Pin24Charset.digits => '0-9',
        Pin24Charset.separators => l.pin24CharsetSeparators,
        Pin24Charset.specials => '#\$%@.[]{}',
      };

  Future<void> _showSpecialsHelp() async {
    final l = AppLocalizations.of(context)!;
    _session.touch();
    await showPinDialog<void>(
      context: context,
      session: _session,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(l.pin24SpecialsTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.pin24SpecialsBody),
            const SizedBox(height: 12),
            Semantics(
              identifier: 'pin24_specials_set6',
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(kCharsets[6], style: pinMono(context, size: 16)),
              ),
            ),
            const SizedBox(height: 4),
            Semantics(
              identifier: 'pin24_specials_set7',
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(kCharsets[7], style: pinMono(context, size: 16)),
              ),
            ),
          ],
        ),
        actions: [
          Semantics(
            identifier: 'pin24_specials_ok',
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _outputCard(AppLocalizations l) {
    final gate = _gate;
    final out = _output;
    final List<Widget> body;
    if (gate != 0) {
      body = [
        PinNotice(switch (gate) {
          1 => l.pin24Gate1,
          2 => l.pin24Gate2,
          _ => l.pin24Gate3,
        }),
      ];
    } else if (_busy || out == null) {
      body = [
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        PinCaption(l.pin24Deriving),
      ];
    } else if (out.errorCode != null) {
      body = [PinNotice(_errorText(l, out), kind: PinNoticeKind.error)];
    } else if (out.mode == Pin24Mode.pin) {
      body = _pinResult(l, out);
    } else {
      body = _passwordResult(l, out);
    }
    return PinCard(title: l.pin24SectionOutput, children: body);
  }

  String _errorText(AppLocalizations l, _Pin24Output out) =>
      switch (pin24ErrorKind(out.errorCode!)) {
        Pin24ErrorKind.bip39Invalid => l.pin24ErrorBip39,
        Pin24ErrorKind.passphraseNotUtf8 => l.pin24ErrorPassphraseUtf8,
        Pin24ErrorKind.nicknameEmpty => l.pin24Gate2,
        Pin24ErrorKind.nicknameNotUtf8 => l.pin24ErrorNicknameUtf8,
        Pin24ErrorKind.bip32Invalid => l.pin24ErrorBip32,
        Pin24ErrorKind.generic => out.mode == Pin24Mode.pin
            ? l.pin24ErrorGeneric
            : l.pin24ErrorGenericShort,
      };

  List<Widget> _pinResult(AppLocalizations l, _Pin24Output out) {
    final pin = out.pin!;
    final full = out.fullPassword!;
    return [
      PinCopyable(
        identifier: 'pin24_output',
        semanticLabel: l.pin24PinSemantics(pin.length),
        onCopy: () => _copy(pin),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: PinDigitCells(value: pin),
        ),
      ),
      const SizedBox(height: 6),
      Center(child: PinCaption(l.pinTapToCopy)),
      const SizedBox(height: 6),
      PinSwitchRow(
        identifier: 'pin24_reveal_pin',
        icon: Icons.visibility_outlined,
        label: l.pin24RevealPin,
        caption: l.pin24RevealPinHelp,
        value: _revealPin,
        onChanged: (v) {
          _session.touch();
          setState(() => _revealPin = v);
        },
      ),
      if (_revealPin)
        Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Semantics(
              identifier: 'pin24_pin_text',
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(pin,
                    softWrap: false, style: pinMono(context, size: 20)),
              ),
            ),
          ),
        ),
      if (out.paddedZeros > 0) ...[
        const SizedBox(height: 8),
        PinNotice(
          l.pin24PaddingWarning(out.digitsInOutput, out.paddedZeros),
          kind: PinNoticeKind.warning,
        ),
      ],
      const SizedBox(height: 8),
      PinCaption(l.pin24PinCaption(out.nickname, out.length)),
      const SizedBox(height: 6),
      PinSwitchRow(
        identifier: 'pin24_show_full',
        icon: Icons.manage_search_outlined,
        label: l.pin24FullToggle,
        caption: l.pin24FullHelp,
        value: _showFull,
        onChanged: (v) {
          _session.touch();
          setState(() => _showFull = v);
        },
      ),
      if (_showFull) ...[
        Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Semantics(
              identifier: 'pin24_full_password',
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(withVisibleSpaces(full),
                    softWrap: false, style: pinMono(context, size: 17)),
              ),
            ),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin24_copy_full',
            child: TextButton.icon(
              onPressed: () async {
                final ok = await _copy(full);
                if (!mounted) return;
                await showPinCopyResult(context, _privacy, ok: ok);
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(l.pin24CopyFull),
            ),
          ),
        ),
        PinCaption(l.pin24FullCaption(out.length)),
      ],
    ];
  }

  List<Widget> _passwordResult(AppLocalizations l, _Pin24Output out) {
    final password = out.password!;
    final raw = out.rawMask;
    final sets = raw != null
        ? ledgerCharsetsLabel(raw)
        : [
            for (final c in Pin24Charset.values)
              if (out.charsets.contains(c)) _charsetLabel(l, c),
          ].join(' + ');
    return [
      PinCopyable(
        identifier: 'pin24_output',
        semanticLabel: l.pin24PasswordSemantics(password.length),
        onCopy: () => _copy(password),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final chunk in chunked(password, 4))
                  Text(
                    withVisibleSpaces(chunk),
                    softWrap: false,
                    style: pinMono(
                      context,
                      size: 22,
                      weight: FontWeight.w700,
                      color: PinColors.okText(Theme.of(context).brightness),
                      letterSpacing: 2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Center(child: PinCaption(l.pinTapToCopy)),
      const SizedBox(height: 8),
      PinCaption(l.pin24PasswordCaption(ltrIsolate(sets), out.nickname)),
    ];
  }

  Widget _threatModelCard(AppLocalizations l) {
    final theme = Theme.of(context);
    Widget section(String title, String body) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(body,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4)),
            ],
          ),
        );
    return PinCard(
      children: [
        PinDisclosure(
          title: l.pin24ThreatTitle,
          identifier: 'pin24_threat_model',
          children: [
            section(l.pin24ThreatProtectsTitle,
                '${l.pin24ThreatProtectsBody}\n• ${pinClipboardPrivacyNote(l)}'),
            section(l.pin24ThreatCannotTitle,
                '${l.pin24ThreatCannotBody}\n• ${l.pinHiddenLastCharNote}'),
            section(l.pin24ThreatUseTitle, l.pin24ThreatUseBody),
            section(l.pin24ThreatDontTitle, l.pin24ThreatDontBody),
            section(l.pin24ThreatStepsTitle, l.pin24ThreatStepsBody),
          ],
        ),
      ],
    );
  }

  Widget _cleanupCard(AppLocalizations l) {
    return PinCard(
      title: l.pin24CleanupTitle,
      children: [
        PinCaption(l.pin24CleanupCaption),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin24_wipe_all_bottom',
            child: _wipeAllButton(l),
          ),
        ),
        const Divider(height: 28),
        PinCaption(l.pin24SelfTestCaption),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'pin24_selftest',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _checkRunning ? null : _runEngineCheck,
              icon: _checkRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_outlined, size: 18),
              label: Text(l.pin24SelfTest),
            ),
          ),
        ),
        if (_checkText != null) ...[
          const SizedBox(height: 8),
          PinNotice(_checkText!, kind: _checkKind),
        ],
      ],
    );
  }
}
