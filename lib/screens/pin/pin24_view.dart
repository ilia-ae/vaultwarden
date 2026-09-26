import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../pin_tools/bip39.dart';
import '../../pin_tools/ledger_pin24.dart' show kCharsets;
import '../../services/privacy_service.dart';
import '../../widgets/option_pills.dart';
import 'pin24_engine.dart';
import 'pin24_selftest_hook.dart';
import 'pin_prefs.dart';
import 'pin_session.dart';
import 'pin_widgets.dart';

/// Placeholder of the seed field: twelve masked groups.
const _seedPlaceholder =
    '•••• •••• •••• •••• •••• •••• •••• •••• •••• •••• •••• ••••';

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

  // Reveal toggles: off on every visit and after every wipe.
  bool _showWords = false;
  bool _revealPin = false;
  bool _showFull = false;

  /// A paste put the phrase on the clipboard, which still holds it.
  bool _clipboardHoldsPaste = false;

  /// Unpaired surrogates were dropped from the nickname.
  bool _nicknameSanitized = false;

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
    _session.touch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    _wipeEpoch++;
    _session.wipes.removeListener(_onWipe);
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
      _analysis = analyzeSeedText('');
      _showWords = false;
      _revealPin = false;
      _showFull = false;
      _clipboardHoldsPaste = false;
      if (event.scope == PinWipeScope.all) _nicknameSanitized = false;
      _busy = false;
      _output = null;
      _checkText = null;
    });
  }

  Future<void> _confirmWipeAll() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.delete_forever_outlined, color: cs.error),
          title: Text(l.pin24WipeAllTitle),
          content: Text(l.pin24WipeAllBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
            Semantics(
              identifier: 'pin24_wipe_all_confirm',
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: cs.error),
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.pin24WipeAllConfirm),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
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
      _clipboardHoldsPaste = true;
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
      _clipboardHoldsPaste = true;
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
    if (!mounted) return;
    setState(() => _clipboardHoldsPaste = true);
  }

  Future<void> _clearClipboard() async {
    _session.touch();
    await _privacy.clearClipboard();
    if (!mounted) return;
    setState(() => _clipboardHoldsPaste = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.pinClipboardCleared)),
    );
  }

  void _setMode(Pin24Mode mode) {
    _session.touch();
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

  // ── Derivation ──

  /// Which gate blocks derivation (1: phrase, 2: nickname, 3: charsets), or
  /// 0 when none does. Checked in this order.
  int get _gate {
    if (!_analysis.validation.isValid) return 1;
    if (_nickCtrl.text.isEmpty) return 2;
    if (_mode == Pin24Mode.password && _charsets.isEmpty) return 3;
    return 0;
  }

  void _inputsChanged() {
    _debounce?.cancel();
    _generation++;
    final ready = _gate == 0;
    setState(() {
      _output = null;
      _busy = ready;
    });
    if (!ready) return;
    final generation = _generation;
    _debounce = Timer(_debounceDelay, () => _derive(generation));
  }

  Future<void> _derive(int generation) async {
    if (!mounted || generation != _generation) return;
    final epoch = _wipeEpoch;
    final mode = _mode;
    final nickname = _nickCtrl.text;
    final length = _length;
    final charsets = {..._charsets};
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
      setMask: pin24MaskOf(charsets),
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
    if (fresh != null && mounted && epoch == _wipeEpoch) {
      // Keyed by phrase + passphrase, so it is valid even if the nickname
      // or mode changed meanwhile.
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
      result = await pin24EngineCheck(_runner);
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
        Text(l.pin24Summary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        PinCaption(l.pin24Bullets),
        const SizedBox(height: 10),
        PinCaption(l.pin24Caption),
        const SizedBox(height: 12),
        PinBanner(child: Text(l.pin24Banner)),
        if (!_acknowledged) ...[
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
        PinCaption(l.pin24SeedLabel),
        const SizedBox(height: 8),
        PinSecretField(
          controller: _seedCtrl,
          identifier: 'pin24_seed',
          enabled: _acknowledged,
          hintText: _seedPlaceholder,
          helperText: _acknowledged ? l.pin24SeedHelp : l.pin24AckRequired,
          onChanged: _onSeedChanged,
          onPasted: _onMenuPaste,
          normalizePaste: normalizePastedSeed,
        ),
        if (_clipboardHoldsPaste) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: PinNotice(
                  l.pinPastedStillOnClipboard,
                  kind: PinNoticeKind.warning,
                ),
              ),
              Semantics(
                identifier: 'pin24_clear_clipboard',
                child: TextButton(
                  onPressed: _clearClipboard,
                  child: Text(l.pinClearClipboard),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 4),
        PinSwitchRow(
          identifier: 'pin24_show_words',
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
        Row(
          children: [
            Text(l.pin24WordsMetric, style: theme.textTheme.labelLarge),
            const SizedBox(width: 8),
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
          children: [
            PinSecretField(
              controller: _ppCtrl,
              identifier: 'pin24_passphrase',
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
                child: PinWarningChip(l.pin24PassphraseWhitespace),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Semantics(
              identifier: 'pin24_wipe_seed',
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _wipeSeed,
                child: Text(l.pin24WipeSeed),
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

  Widget _wipeAllButton(AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: cs.error,
        side: BorderSide(color: cs.error.withAlpha(128)),
      ),
      onPressed: _confirmWipeAll,
      child: Text(l.pin24WipeAll),
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
        zeroBased.map((i) => '${i + 1}').join(', ');

    // Invalid words (glued ones get their own, more helpful note).
    final invalid = [
      for (final i in a.parsed.invalidPositions)
        if (!a.gluedPositions.contains(i)) i,
    ];
    if (invalid.isNotEmpty) {
      out.add(PinNotice(
        _showWords
            ? l.pin24InvalidRevealed(
                invalid.map((i) => '“${a.words[i]}” (#${i + 1})').join(', '))
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
            Text('#${index + 1} “$prefix” →', style: pinMono(context, size: 13)),
            if (options.isEmpty) Text(l.pin24NoCompletions),
            for (final word in options)
              ActionChip(
                label: Text(word, style: pinMono(context, size: 13)),
                visualDensity: VisualDensity.compact,
                onPressed: () => _acceptWord(index, word),
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
          Row(
            children: [
              Expanded(child: PinCaption(l.pin24LengthCustom)),
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
              SizedBox(
                width: 44,
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
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.pin24SpecialsTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.pin24SpecialsBody),
            const SizedBox(height: 12),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(kCharsets[6], style: pinMono(context, size: 16)),
            ),
            const SizedBox(height: 4),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(kCharsets[7], style: pinMono(context, size: 16)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
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
            child: Text(pin, style: pinMono(context, size: 20)),
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
              child: Text(withVisibleSpaces(full),
                  style: pinMono(context, size: 17)),
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
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok ? l.pinCopiedTtl : l.pinCopyFailed),
                ));
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
    final sets = [
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
                    style: pinMono(
                      context,
                      size: 22,
                      weight: FontWeight.w700,
                      color: PinColors.valid,
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
      PinCaption(l.pin24PasswordCaption(sets, out.nickname)),
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
              Text(body, style: theme.textTheme.bodySmall?.copyWith(height: 1.4)),
            ],
          ),
        );
    return PinCard(
      children: [
        PinDisclosure(
          title: l.pin24ThreatTitle,
          identifier: 'pin24_threat_model',
          children: [
            section(l.pin24ThreatProtectsTitle, l.pin24ThreatProtectsBody),
            section(l.pin24ThreatCannotTitle, l.pin24ThreatCannotBody),
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
