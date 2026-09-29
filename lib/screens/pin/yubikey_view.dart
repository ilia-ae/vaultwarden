import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../pin_tools/python_text.dart' show hasLoneSurrogate;
import '../../pin_tools/yubikey_ledger.dart';
import '../../pin_tools/yubikey_secrets.dart';
import '../../services/privacy_service.dart';
import '../../widgets/option_pills.dart';
import 'pin24_engine.dart';
import 'pin_session.dart';
import 'pin_widgets.dart';
import 'yubikey_engine.dart';

/// Computation waits this long after the last edit.
const _debounceDelay = Duration(milliseconds: 250);

/// Copied values and CSVs leave the clipboard after this long.
const _copyTtl = Duration(seconds: 60);

/// Fixed-width mask for a hidden value (no length leak).
const _hiddenValue = '••••••••';

/// Why nothing is computed yet, checked in this order.
enum _Gate {
  none,
  badSerials,
  noSerials,
  noSeed,
  noMask,
  masterMissing,
  masterBroken,
  masterShort,
}

/// YubiKey secrets for one or more keys: from Ledger Passwords entries
/// (`yk-<serial>-pins/-puk/-admin`, yubikey-fleet `docs/BITWARDEN.md`), from a
/// master key (the fleet script's derived mode) or at random.
///
/// Values are computed off the UI isolate ([pinComputeRunnerProvider]) and
/// live only in this widget: the master key in its text controller, results
/// and random values in state. Every section wipe clears them (a seed-only
/// wipe clears Ledger results), as does Clear and leaving the tool; Clear and
/// leaving the tool ask first while random values exist. The non-secret
/// settings (source, serials, applets, charsets, toggles) live in the
/// session ([PinSession.yk]) and survive a trip to PIN 24. Values are hidden
/// by default, revealed per row, and copied only through
/// [PrivacyService.copySensitive] (60 s, sensitive; local only on iOS). YAML
/// manifests and ykman provisioning stay desktop-only.
class YubikeyView extends ConsumerStatefulWidget {
  const YubikeyView({super.key});

  @override
  ConsumerState<YubikeyView> createState() => _YubikeyViewState();
}

class _YubikeyViewState extends ConsumerState<YubikeyView> {
  late final ProviderSubscription<PinSession> _sessionSub;
  late final ProviderSubscription<PinSeedCache> _seedSub;
  late final PinSession _session;
  late final PinSeedCache _seed;
  late final PrivacyService _privacy;
  late final PinComputeRunner _runner;
  late final YkSettings _s;
  final List<VoidCallback> _unregister = [];

  late final TextEditingController _serialsCtrl;
  final _masterCtrl = TextEditingController();
  String _lastMasterText = '';
  int _masterBytes = 0;

  /// Random values generated so far (serial → field → value): reused so
  /// they stay put until Regenerate, Clear or a wipe.
  final Map<String, Map<String, String>> _randomValues = {};

  /// Revealed rows, as `serial/field`.
  final Set<String> _revealed = {};

  /// Bumped by every wipe and Clear: the fields are rebuilt with an empty
  /// undo history.
  int _fieldGen = 0;

  Timer? _debounce;

  /// Bumped by every edit and wipe; results of older runs are dropped.
  int _generation = 0;

  /// Bumped by every wipe and Clear; a dialog opened before one must not
  /// act on what it showed.
  int _wipeEpoch = 0;
  bool _busy = false;
  YkResponse? _result;

  @override
  void initState() {
    super.initState();
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _seedSub = ref.listenManual(pinSeedProvider, (_, __) {});
    _seed = _seedSub.read();
    _s = _session.yk;
    _serialsCtrl = TextEditingController(text: _s.serials);
    _seed.addListener(_onSeedChanged);
    _session.wipes.addListener(_onWipe);
    _unregister
      ..add(_session.registerContentProbe(_hasContent))
      ..add(_session.registerUnsavedProbe(() => _randomValues.isNotEmpty));
    _privacy = ref.read(privacyServiceProvider);
    _runner = ref.read(pinComputeRunnerProvider);
    _session.touch();
    // Settings kept from an earlier visit: compute right away.
    if (_serialsCtrl.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _inputsChanged();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    _seed.removeListener(_onSeedChanged);
    _session.wipes.removeListener(_onWipe);
    for (final f in _unregister) {
      f();
    }
    _seedSub.close();
    _sessionSub.close();
    _result = null;
    _randomValues.clear();
    _serialsCtrl.clear();
    _masterCtrl.clear();
    _serialsCtrl.dispose();
    _masterCtrl.dispose();
    TextInput.finishAutofillContext(shouldSave: false);
    super.dispose();
  }

  bool _hasContent() =>
      _serialsCtrl.text.isNotEmpty ||
      _masterCtrl.text.isNotEmpty ||
      _result != null ||
      _randomValues.isNotEmpty;

  // ── Wipes ──

  void _onWipe() {
    final event = _session.wipes.value;
    if (event == null || !mounted) return;
    if (event.scope == PinWipeScope.seed) {
      // Only what came from the seed: the Ledger results. Master-key and
      // random values stay (and a computation in flight for them runs on).
      if (_s.source != YkSource.ledger) return;
      _debounce?.cancel();
      _generation++;
      _wipeEpoch++;
      setState(() {
        _result = null;
        _busy = false;
        _revealed.clear();
      });
      return;
    }
    _clearAll();
  }

  void _clearAll() {
    _debounce?.cancel();
    _generation++;
    _wipeEpoch++;
    _serialsCtrl.clear();
    _s.serials = '';
    _masterCtrl.clear();
    _lastMasterText = '';
    _masterBytes = 0;
    _randomValues.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _fieldGen++;
      _result = null;
      _busy = false;
      _revealed.clear();
    });
  }

  Future<void> _onClearPressed() async {
    _session.touch();
    if (_randomValues.isNotEmpty) {
      final l = AppLocalizations.of(context)!;
      final ok = await confirmPinAction(
        context: context,
        session: _session,
        tone: PinDialogTone.destructive,
        title: l.pinYkRandomLoseTitle,
        body: l.pinYkRandomLoseBody,
        confirmLabel: l.pinYkRandomLoseConfirm,
        confirmId: 'yk_clear_confirm',
        cancelId: 'yk_clear_cancel',
      );
      if (!ok || !mounted) return;
    }
    HapticFeedback.mediumImpact();
    FocusManager.instance.primaryFocus?.unfocus();
    _clearAll();
    _session.userCleared();
  }

  /// The cached seed appeared or was wiped: only the Ledger source uses it.
  void _onSeedChanged() {
    if (!mounted || _s.source != YkSource.ledger) return;
    _inputsChanged();
  }

  // ── Inputs ──

  bool get _needsMaster =>
      _s.source == YkSource.master ||
      (_s.source == YkSource.ledger &&
          _s.ledgerRest == YkMode.derived &&
          ykLedgerNeedsRest(_s.phases, otpFromSerial: true));

  bool get _effectiveOtpFromSerial =>
      _s.source == YkSource.ledger || _s.otpFromSerial;

  _Gate _gate(YkSerialList serials) {
    if (serials.invalid.isNotEmpty) return _Gate.badSerials;
    if (serials.serials.isEmpty) return _Gate.noSerials;
    if (_s.source == YkSource.ledger) {
      if (!_seed.hasSeed) return _Gate.noSeed;
      if (_s.mask.isEmpty) return _Gate.noMask;
    }
    if (_needsMaster) {
      if (_masterCtrl.text.isEmpty) return _Gate.masterMissing;
      if (hasLoneSurrogate(_masterCtrl.text)) return _Gate.masterBroken;
      if (_masterBytes < ykMinMasterKeyLength) return _Gate.masterShort;
    }
    return _Gate.none;
  }

  static int _countMasterBytes(String text) {
    final bytes = utf8.encode(text);
    final n = ykStrippedLength(bytes);
    bytes.fillRange(0, bytes.length, 0);
    return n;
  }

  void _onSerialsChanged(String text) {
    _session.touch();
    _s.serials = text;
    _inputsChanged();
  }

  void _onMasterChanged(String text) {
    _session.touch();
    if (text.length - _lastMasterText.length >= PinSecretField.pasteThreshold) {
      _session.markPasted();
    }
    _lastMasterText = text;
    _masterBytes = _countMasterBytes(text);
    _inputsChanged();
  }

  void _onMenuPaste() {
    if (mounted) _session.markPasted();
  }

  void _setSource(YkSource source) {
    _session.touch();
    _s.source = source;
    _revealed.clear();
    _inputsChanged();
  }

  void _togglePhase(YkPhase phase) {
    _session.touch();
    if (!_s.phases.remove(phase)) _s.phases.add(phase);
    _inputsChanged();
  }

  void _toggleMask(Pin24Charset charset) {
    _session.touch();
    final next = {..._s.mask};
    if (!next.remove(charset)) next.add(charset);
    _s.mask = next;
    _inputsChanged();
  }

  void _toggleHandSet(String field, bool byHand) {
    _session.touch();
    if (byHand) {
      _s.handSet.add(field);
    } else {
      _s.handSet.remove(field);
    }
    _revealed.removeWhere((r) => r.endsWith('/$field'));
    _inputsChanged();
  }

  Future<void> _openPin24() async {
    _session.touch();
    if (_randomValues.isNotEmpty) {
      final l = AppLocalizations.of(context)!;
      final ok = await confirmPinAction(
        context: context,
        session: _session,
        tone: PinDialogTone.destructive,
        title: l.pinYkRandomLoseTitle,
        body: l.pinYkRandomLoseBody,
        confirmLabel: l.pinYkRandomLoseConfirm,
        confirmId: 'pin_tool_switch_confirm',
        cancelId: 'pin_tool_switch_cancel',
      );
      if (!ok || !mounted) return;
    }
    HapticFeedback.selectionClick();
    // PIN 24 scrolls to its seed field and offers the way back.
    _session.returnTo = PinTool.yubikey;
    ref.read(pinToolProvider.notifier).state = PinTool.pin24;
  }

  // ── Computation ──

  void _inputsChanged() {
    _debounce?.cancel();
    _generation++;
    final ready = _gate(ykParseSerials(_serialsCtrl.text)) == _Gate.none;
    setState(() {
      _result = null;
      _busy = ready;
    });
    if (!ready) return;
    final generation = _generation;
    _debounce = Timer(_debounceDelay, () => _compute(generation));
  }

  Future<void> _compute(int generation) async {
    if (!mounted || generation != _generation) return;
    final serials = ykParseSerials(_serialsCtrl.text).serials;
    final seed = _s.source == YkSource.ledger ? _seed.copySeed() : null;
    final Uint8List? master =
        _needsMaster ? utf8.encode(_masterCtrl.text) : null;
    final request = YkRequest(
      source: _s.source,
      serials: serials,
      phases: {..._s.phases},
      otpFromSerial: _effectiveOtpFromSerial,
      masterBytes: master,
      seed: seed,
      setMask: pin24MaskOf(_s.mask),
      separateAdmin: _s.separateAdmin,
      ledgerRest: _s.ledgerRest,
      handSet: {..._s.handSet},
      randomValues: {
        for (final e in _randomValues.entries) e.key: {...e.value},
      },
    );
    YkResponse response;
    try {
      response = await runYubikey(_runner, request);
    } catch (_) {
      // Deliberately not logged or rethrown: the error could carry input.
      response = const YkResponse(errorCode: YkComputeError.unexpected);
    } finally {
      seed?.fillRange(0, seed.length, 0);
      master?.fillRange(0, master.length, 0);
    }
    if (!mounted || generation != _generation) return;
    // Keep random values stable across recomputations.
    for (final k in response.keys) {
      for (final MapEntry(key: f, value: origin) in k.origins.entries) {
        if (origin == YkOrigin.random) {
          (_randomValues[k.serial] ??= {})[f] = k.values[f]!;
        }
      }
    }
    setState(() {
      _busy = false;
      _result = response;
    });
  }

  Future<void> _confirmRegenerate() async {
    final l = AppLocalizations.of(context)!;
    _session.touch();
    final confirmed = await confirmPinAction(
      context: context,
      session: _session,
      tone: PinDialogTone.destructive,
      icon: Icons.casino_outlined,
      title: l.pinYkRegenerateTitle,
      body: l.pinYkRegenerateBody,
      confirmLabel: l.pinYkRegenerateConfirm,
      confirmId: 'yk_regenerate_confirm',
      cancelId: 'yk_regenerate_cancel',
    );
    if (!confirmed || !mounted) return;
    HapticFeedback.mediumImpact();
    _randomValues.clear();
    _revealed.clear();
    _inputsChanged();
  }

  Future<void> _copyValue(String value) async {
    _session.touch();
    final ok = await _privacy.copySensitive(value, ttl: _copyTtl);
    if (!mounted) return;
    await showPinCopyResult(context, _privacy, ok: ok);
  }

  /// Why the current result cannot be exported, or `null` if it can. Builds
  /// the CSV only to validate it and drops it at once: the CSV that is
  /// copied is built after the confirmation, from the result shown then.
  String? _csvRefusal(AppLocalizations l, List<YkKeyResult> keys) {
    if (keys.isEmpty) return l.pinYkCsvRefusedGeneric;
    if (keys.any((k) => k.errorCode != null)) return l.pinYkCsvRefusedKeys;
    try {
      ykBitwardenCsv([for (final k in keys) k.secrets]);
      return null;
    } on YkException catch (e) {
      if (e.code == YkException.serialInvalid) return l.pinYkCsvRefusedSerial;
      final otp = keys.any((k) => [
            for (final f in ['45', '46']) ...?k.valueProblems[f],
          ].isNotEmpty);
      final ledger = keys.any((k) => k.ledgerProblems.values.any(
            (p) => p.isNotEmpty,
          ));
      return [
        l.pinYkCsvRefusedValues,
        if (otp) l.pinYkCsvRefusedOtp,
        if (ledger && _s.source == YkSource.ledger) l.pinYkCsvRefusedLedgerHint,
      ].join(' ');
    } catch (_) {
      return l.pinYkCsvRefusedGeneric;
    }
  }

  Future<void> _copyCsv() async {
    _session.touch();
    final l = AppLocalizations.of(context)!;
    final keys = _result?.keys ?? const <YkKeyResult>[];
    final refusal = _csvRefusal(l, keys);
    if (refusal != null) {
      HapticFeedback.heavyImpact();
      await showPinDialog<void>(
        context: context,
        session: _session,
        builder: (context) => AlertDialog(
          scrollable: true,
          icon: Icon(Icons.block, color: Theme.of(context).colorScheme.error),
          title: Text(l.pinYkCsvRefusedTitle),
          content: Semantics(
            identifier: 'yk_csv_refused',
            child: Text(refusal),
          ),
          actions: [
            Semantics(
              identifier: 'yk_csv_refused_ok',
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
            ),
          ],
        ),
      );
      return;
    }
    final count = keys.fold<int>(0, (n, k) => n + k.values.length);
    final epoch = _wipeEpoch;
    final generation = _generation;
    if (!mounted) return;
    final confirmed = await confirmPinAction(
      context: context,
      session: _session,
      tone: PinDialogTone.sensitive,
      icon: Icons.table_chart_outlined,
      title: l.pinYkCsvConfirmTitle,
      body: '${l.pinYkCsvConfirmBody(count)}\n\n${pinClipboardPrivacyNote(l)}',
      confirmLabel: l.pinYkCsvConfirm,
      confirmId: 'yk_csv_confirm',
      cancelId: 'yk_csv_cancel',
    );
    // Nothing is copied if anything was wiped, cleared or recomputed while
    // the dialog was open (the wipe also closes the dialog).
    final current = _result;
    if (!confirmed ||
        !mounted ||
        epoch != _wipeEpoch ||
        generation != _generation ||
        current == null) {
      return;
    }
    String csv;
    try {
      csv = ykBitwardenCsv([for (final k in current.keys) k.secrets]);
    } catch (_) {
      return;
    }
    final ok = await _privacy.copySensitive(csv, ttl: _copyTtl);
    if (!mounted) return;
    await showPinCopyResult(context, _privacy, ok: ok);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final serials = ykParseSerials(_serialsCtrl.text);
    final gate = _gate(serials);
    return Semantics(
      identifier: 'yk_view',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _introCard(l),
          _sourceCard(l),
          _serialsCard(l, serials),
          _phasesCard(l),
          if (_s.source == YkSource.ledger) _ledgerCard(l),
          if (_needsMaster) _masterCard(l),
          _resultCard(l, gate),
          _notesCard(l),
        ],
      ),
    );
  }

  Widget _introCard(AppLocalizations l) {
    final theme = Theme.of(context);
    return PinCard(
      children: [
        Row(
          children: [
            Icon(Icons.vpn_key_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l.pinToolYubikey, style: theme.textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(l.pinYkSummary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        PinCaption(l.pinYkDesktopOnlyNote),
      ],
    );
  }

  Widget _sourceCard(AppLocalizations l) {
    return PinCard(
      title: l.pinYkSectionSource,
      children: [
        OptionPills<YkSource>(
          padding: EdgeInsets.zero,
          options: [
            (value: YkSource.ledger, label: l.pinYkSourceLedger),
            (value: YkSource.master, label: l.pinYkSourceMaster),
            (value: YkSource.random, label: l.pinYkSourceRandom),
          ],
          identifiers: const [
            'yk_source_ledger',
            'yk_source_master',
            'yk_source_random',
          ],
          selected: _s.source,
          onSelected: _setSource,
        ),
        const SizedBox(height: 8),
        PinCaption(switch (_s.source) {
          YkSource.ledger => l.pinYkSourceLedgerHelp,
          YkSource.master => l.pinYkSourceMasterHelp,
          YkSource.random => l.pinYkSourceRandomHelp,
        }),
        // A master key pasted earlier: the reminder stays reachable even when
        // the master-key card is hidden.
        if (!_needsMaster)
          PinClipboardReminder(
            session: _session,
            identifier: 'yk_clear_clipboard',
          ),
      ],
    );
  }

  Widget _serialsCard(AppLocalizations l, YkSerialList serials) {
    final otpOn = _s.phases.contains(YkPhase.otp) && _effectiveOtpFromSerial;
    return PinCard(
      title: l.pinYkSectionSerials,
      children: [
        PinSecretField(
          controller: _serialsCtrl,
          identifier: 'yk_serials',
          wipeGeneration: _fieldGen,
          obscure: false,
          maxLines: 3,
          monospace: true,
          textDirection: TextDirection.ltr,
          labelText: l.pinYkSerialsLabel,
          hintText: '38715242, 17684504',
          helperText: l.pinYkSerialsHelp,
          onChanged: _onSerialsChanged,
        ),
        const SizedBox(height: 6),
        if (serials.serials.isNotEmpty)
          Semantics(
            identifier: 'yk_serials_count',
            child: PinCaption(l.pinYkSerialsCount(serials.serials.length)),
          ),
        if (serials.invalid.isNotEmpty)
          Semantics(
            identifier: 'yk_serials_invalid',
            child: PinNotice(
              l.pinYkSerialsInvalid(ltrIsolate(_quoteList(serials.invalid))),
              kind: PinNoticeKind.error,
            ),
          ),
        if (serials.duplicates.isNotEmpty)
          Semantics(
            identifier: 'yk_serials_duplicates',
            child: PinNotice(l.pinYkSerialsDuplicates(
                ltrIsolate(serials.duplicates.join(', ')))),
          ),
        if (serials.leadingZero.isNotEmpty)
          Semantics(
            identifier: 'yk_serials_leading_zero',
            child: PinNotice(
              l.pinYkSerialsLeadingZero(
                  ltrIsolate(serials.leadingZero.join(', '))),
              kind: PinNoticeKind.warning,
            ),
          ),
        if (serials.tooMany)
          Semantics(
            identifier: 'yk_serials_too_many',
            child: PinNotice(l.pinYkSerialsTooMany(kYkMaxSerials),
                kind: PinNoticeKind.warning),
          ),
        if (otpOn && serials.tooLongForOtp.isNotEmpty)
          Semantics(
            identifier: 'yk_serials_otp_too_long',
            child: PinNotice(
              l.pinYkSerialsOtpTooLong(
                  ltrIsolate(serials.tooLongForOtp.join(', '))),
              kind: PinNoticeKind.warning,
            ),
          ),
      ],
    );
  }

  /// Serial tokens are public, but anything pasted by mistake is shortened.
  static String _quoteList(List<String> tokens) => tokens
      .take(5)
      .map((t) => '“${t.length > 16 ? '${t.substring(0, 16)}…' : t}”')
      .join(', ');

  Widget _phasesCard(AppLocalizations l) {
    const phases = [
      (YkPhase.openpgp, 'OpenPGP'),
      (YkPhase.fido2, 'FIDO2'),
      (YkPhase.oath, 'OATH'),
      (YkPhase.otp, 'OTP'),
    ];
    final ledger = _s.source == YkSource.ledger;
    return PinCard(
      title: l.pinYkSectionPhases,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // PIV (00, 14) is always part of the set.
            OptionPill(
              label: 'PIV',
              selected: true,
              identifier: 'yk_phase_piv',
              onTap: _session.touch,
            ),
            for (final (phase, label) in phases)
              OptionPill(
                label: label,
                selected: _s.phases.contains(phase),
                identifier: 'yk_phase_${phase.name}',
                onTap: () => _togglePhase(phase),
              ),
          ],
        ),
        const SizedBox(height: 8),
        PinCaption(l.pinYkPhasesHelp),
        if (_s.phases.contains(YkPhase.otp)) ...[
          const SizedBox(height: 6),
          PinSwitchRow(
            identifier: 'yk_otp_from_serial',
            label: l.pinYkOtpFromSerial,
            caption:
                ledger ? l.pinYkOtpFromSerialLedger : l.pinYkOtpFromSerialHelp,
            value: _effectiveOtpFromSerial,
            onChanged: ledger
                ? null
                : (v) {
                    _session.touch();
                    _s.otpFromSerial = v;
                    _inputsChanged();
                  },
          ),
        ],
      ],
    );
  }

  Widget _ledgerCard(AppLocalizations l) {
    final needsRest = ykLedgerNeedsRest(_s.phases, otpFromSerial: true);
    final nonDefault = pin24MaskOf(_s.mask) != ykLedgerDefaultMask;
    final needed = ykNeededFields(_s.phases);
    return PinCard(
      title: l.pinYkSectionLedger,
      children: [
        if (_seed.hasSeed)
          Semantics(
            identifier: 'yk_seed_status',
            child: PinNotice(l.pinYkUsingSeed(_seed.wordCount),
                kind: PinNoticeKind.ok),
          )
        else ...[
          Semantics(
            identifier: 'yk_seed_status',
            child: PinNotice(l.pinYkNeedSeed, kind: PinNoticeKind.warning),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              identifier: 'yk_go_pin24',
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _openPin24,
                icon: const Icon(Icons.grid_view_rounded, size: 18),
                label: Text(l.pinYkGoToPin24),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        PinCaption(l.pinYkLedgerRule),
        const SizedBox(height: 12),
        SectionHeader(l.pinYkLedgerMask, padding: EdgeInsets.zero),
        const SizedBox(height: 6),
        MultiOptionPills<Pin24Charset>(
          padding: EdgeInsets.zero,
          options: [
            for (final c in Pin24Charset.values)
              (value: c, label: _charsetLabel(l, c)),
          ],
          identifiers: [
            for (final c in Pin24Charset.values) 'yk_mask_${c.name}',
          ],
          selected: _s.mask,
          onToggled: _toggleMask,
        ),
        if (_s.mask.isEmpty) ...[
          const SizedBox(height: 8),
          PinNotice(l.pin24CharsetNone, kind: PinNoticeKind.warning),
        ] else if (nonDefault) ...[
          const SizedBox(height: 8),
          Semantics(
            identifier: 'yk_mask_nondefault',
            child: PinNotice(l.pinYkLedgerMaskNonDefault,
                kind: PinNoticeKind.warning),
          ),
        ],
        const SizedBox(height: 6),
        PinSwitchRow(
          identifier: 'yk_separate_admin',
          label: l.pinYkSeparateAdmin,
          caption: l.pinYkSeparateAdminHelp,
          value: _s.separateAdmin,
          onChanged: (v) {
            _session.touch();
            _s.separateAdmin = v;
            _inputsChanged();
          },
        ),
        // docs/BITWARDEN.md transition: 00/23/34 may still be set by hand.
        const SizedBox(height: 10),
        SectionHeader(l.pinYkHandSetTitle, padding: EdgeInsets.zero),
        const SizedBox(height: 2),
        PinCaption(l.pinYkHandSetHelp),
        for (final f in kYkHandSettableFields)
          if (needed.contains(f))
            PinSwitchRow(
              identifier: 'yk_hand_$f',
              label: ltrIsolate('$f ${ykFields[f]!.name}'),
              value: _s.handSet.contains(f),
              onChanged: (v) => _toggleHandSet(f, v),
            ),
        if (needsRest) ...[
          const SizedBox(height: 10),
          SectionHeader(l.pinYkLedgerRest, padding: EdgeInsets.zero),
          const SizedBox(height: 6),
          OptionPills<YkMode>(
            padding: EdgeInsets.zero,
            options: [
              (value: YkMode.derived, label: l.pinYkSourceMaster),
              (value: YkMode.random, label: l.pinYkSourceRandom),
            ],
            identifiers: const ['yk_rest_master', 'yk_rest_random'],
            selected: _s.ledgerRest,
            onSelected: (mode) {
              _session.touch();
              _s.ledgerRest = mode;
              _inputsChanged();
            },
          ),
          const SizedBox(height: 6),
          PinCaption(l.pinYkLedgerRestHelp),
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

  Widget _masterCard(AppLocalizations l) {
    final text = _masterCtrl.text;
    // The key is masked, so its exact length is never shown: only whether
    // it is long enough.
    Widget? status;
    if (text.isNotEmpty) {
      if (hasLoneSurrogate(text)) {
        status = PinNotice(l.pinYkMasterBroken, kind: PinNoticeKind.error);
      } else if (_masterBytes < ykMinMasterKeyLength) {
        status = PinNotice(
          l.pinYkMasterShort(ykMinMasterKeyLength),
          kind: PinNoticeKind.error,
        );
      } else {
        status = PinNotice(l.pinYkMasterOk(ykMinMasterKeyLength),
            kind: PinNoticeKind.ok);
      }
    }
    return PinCard(
      title: l.pinYkSectionMaster,
      children: [
        PinSecretField(
          controller: _masterCtrl,
          identifier: 'yk_master_key',
          wipeGeneration: _fieldGen,
          textDirection: TextDirection.ltr,
          labelText: l.pinYkMasterLabel,
          helperText: l.pinYkMasterHint,
          onChanged: _onMasterChanged,
          onPasted: _onMenuPaste,
        ),
        if (status != null) ...[
          const SizedBox(height: 6),
          Semantics(identifier: 'yk_master_bytes', child: status),
        ],
        PinClipboardReminder(
          session: _session,
          identifier: 'yk_clear_clipboard',
        ),
        const SizedBox(height: 6),
        Semantics(
          identifier: 'yk_master_note',
          child: PinCaption(l.pinYkMasterNeverStored),
        ),
      ],
    );
  }

  // ── Result ──

  Widget _resultCard(AppLocalizations l, _Gate gate) {
    final body = <Widget>[];
    final result = _result;
    if (gate != _Gate.none) {
      body.add(Semantics(
        identifier: 'yk_gate',
        child: PinNotice(
          switch (gate) {
            _Gate.badSerials => l.pinYkGateBadSerials,
            _Gate.noSerials => l.pinYkNoSerials,
            _Gate.noSeed => l.pinYkGateNoSeed,
            _Gate.noMask => l.pin24CharsetNone,
            _Gate.masterMissing => l.pinYkMasterMissing,
            _Gate.masterBroken => l.pinYkMasterBroken,
            _Gate.masterShort => l.pinYkMasterShort(ykMinMasterKeyLength),
            _Gate.none => '',
          },
        ),
      ));
    } else if (_busy || result == null) {
      body.addAll([
        Semantics(
          identifier: 'yk_busy',
          child: const LinearProgressIndicator(),
        ),
        const SizedBox(height: 8),
        PinCaption(l.pinYkComputing),
      ]);
    } else if (result.errorCode != null) {
      body.add(Semantics(
        identifier: 'yk_error',
        child: PinNotice(
          switch (result.errorCode) {
            YkComputeError.noSeed => l.pinYkGateNoSeed,
            YkComputeError.masterMissing => l.pinYkMasterMissing,
            YkComputeError.masterTooShort =>
              l.pinYkMasterShort(ykMinMasterKeyLength),
            _ => l.pinYkComputeFailed,
          },
          kind: PinNoticeKind.error,
        ),
      ));
    } else {
      body.addAll(_values(l, result));
    }

    body.addAll([
      const SizedBox(height: 12),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          identifier: 'yk_clear',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _onClearPressed,
            icon: const Icon(Icons.backspace_outlined, size: 18),
            label: Text(l.clear),
          ),
        ),
      ),
    ]);
    return PinCard(title: l.pinYkSectionResult, children: body);
  }

  List<Widget> _values(AppLocalizations l, YkResponse result) {
    final anyRandom = result.keys
        .any((k) => k.origins.values.any((o) => o == YkOrigin.random));
    final handSet = {for (final k in result.keys) ...k.handSetFields}.toList()
      ..sort();
    final out = <Widget>[];
    if (anyRandom) {
      out.addAll([
        Semantics(
          identifier: 'yk_random_warning',
          child: PinBanner(child: Text(l.pinYkRandomWarning)),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            identifier: 'yk_regenerate',
            child: TextButton.icon(
              onPressed: _confirmRegenerate,
              icon: const Icon(Icons.casino_outlined, size: 18),
              label: Text(l.pinYkRegenerate),
            ),
          ),
        ),
      ]);
    }
    if (handSet.isNotEmpty) {
      out.add(Semantics(
        identifier: 'yk_hand_set_note',
        child: PinNotice(l.pinYkHandSetNote(ltrIsolate(handSet.join(', ')))),
      ));
    }
    out.add(PinCaption(l.pinYkValuesHiddenNote));
    for (final k in result.keys) {
      out
        ..add(const Divider(height: 24))
        ..add(_keyBlock(l, k));
    }
    out.addAll([
      const Divider(height: 24),
      Semantics(
        identifier: 'yk_copy_csv',
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _copyCsv,
          icon: const Icon(Icons.table_chart_outlined, size: 18),
          label: Text(l.pinYkCopyCsv, textAlign: TextAlign.center),
        ),
      ),
      const SizedBox(height: 6),
      Semantics(
        identifier: 'yk_csv_caption',
        child: PinCaption(l.pinYkCopyCsvCaption),
      ),
    ]);
    return out;
  }

  Widget _keyBlock(AppLocalizations l, YkKeyResult k) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: 'yk_result_${k.serial}',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.key_outlined, size: 18),
              const SizedBox(width: 8),
              // One line, never broken inside the number.
              Flexible(
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(k.serial,
                        softWrap: false,
                        style: pinMono(context,
                            size: 16, weight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
          ),
          if (k.entryNames.isNotEmpty) ...[
            const SizedBox(height: 4),
            Semantics(
              identifier: 'yk_entries_${k.serial}',
              child: PinCaption(
                  l.pinYkEntries(ltrIsolate(k.entryNames.join(' · ')))),
            ),
          ],
          if (k.errorCode != null)
            PinNotice(l.pinYkKeyError, kind: PinNoticeKind.error)
          else
            for (final f in k.values.keys) _valueRow(l, theme, k, f),
        ],
      ),
    );
  }

  String _originLabel(AppLocalizations l, YkOrigin? origin) => switch (origin) {
        YkOrigin.ledger => l.pinYkOriginLedger,
        YkOrigin.derived => l.pinYkOriginDerived,
        YkOrigin.random => l.pinYkOriginRandom,
        YkOrigin.serial => l.pinYkOriginSerial,
        null => '',
      };

  String _valueProblem(AppLocalizations l, YkValueProblem p) =>
      switch (p.kind) {
        YkValueProblemKind.length => p.field.min == p.field.max
            ? l.pinYkProblemLengthExact(p.length, p.field.min)
            : l.pinYkProblemLength(p.length, p.field.min, p.field.max),
        YkValueProblemKind.alphabet => l.pinYkProblemAlphabet,
      };

  String _ledgerProblem(AppLocalizations l, YkLedgerProblem p) {
    final limit = ykHardwareLimits[p.field]!;
    return switch (p.kind) {
      YkLedgerProblemKind.length =>
        l.pinYkLedgerProblemLength(p.byteLength, limit.min, limit.max),
      YkLedgerProblemKind.notPrintableAscii =>
        p.field == '00' || p.field == '14'
            ? l.pinYkLedgerProblemAscii8
            : l.pinYkLedgerProblemAscii,
      YkLedgerProblemKind.csvUnsafe => l.pinYkLedgerProblemCsv,
    };
  }

  /// The row's warnings. "The PIV PIN is part of field …" comes once per
  /// other field (usually 23, 24 and 34 at once), so those are merged into
  /// one warning that lists the fields.
  List<String> _warnings(AppLocalizations l, List<YkLedgerWarning> all) {
    final pivIn = [
      for (final w in all)
        if (w.kind == YkLedgerWarningKind.pivPinPartOfOtherSecret &&
            w.otherField != null)
          w.otherField!,
    ];
    return [
      if (pivIn.isNotEmpty)
        l.pinYkWarnPivInFields(
          pivIn.length,
          ltrIsolate([
            for (final f in pivIn) '$f (${ykFields[f]?.name ?? ''})',
          ].join(', ')),
        ),
      for (final w in all)
        if (w.kind != YkLedgerWarningKind.pivPinPartOfOtherSecret)
          switch (w.kind) {
            YkLedgerWarningKind.adminSharesPinsEntry => l.pinYkWarnAdminShares,
            YkLedgerWarningKind.pivPinPartOfOtherSecret => '', // merged above
          },
    ];
  }

  Widget _valueRow(
      AppLocalizations l, ThemeData theme, YkKeyResult k, String field) {
    final id = '${k.serial}_$field';
    final shown = _revealed.contains('${k.serial}/$field');
    final value = k.values[field]!;
    final fieldLabel = '$field ${ykFields[field]!.name}';
    final problems = [
      for (final p in k.valueProblems[field] ?? const <YkValueProblem>[])
        _valueProblem(l, p),
      for (final p in k.ledgerProblems[field] ?? const <YkLedgerProblem>[])
        _ledgerProblem(l, p),
    ];
    final warnings =
        _warnings(l, k.warnings[field] ?? const <YkLedgerWarning>[]);
    final valueStyle = pinMono(
      context,
      size: 17,
      color: problems.isEmpty ? null : theme.colorScheme.error,
    );
    return Semantics(
      identifier: 'yk_row_$id',
      container: true,
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Name at the start, origin at the end, at least 8 apart (in
            // RTL too); at large text the origin moves to its own line.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    fieldLabel,
                    style: pinMono(context,
                        size: 13, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                Text(
                  _originLabel(l, k.origins[field]),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    identifier: 'yk_value_$id',
                    label: shown ? null : l.pinYkValueHidden,
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      // Groups of four: long values wrap between groups,
                      // never inside one.
                      child: shown
                          ? Wrap(
                              spacing: 8,
                              runSpacing: 2,
                              children: [
                                for (final chunk in chunked(value, 4))
                                  Text(withVisibleSpaces(chunk),
                                      softWrap: false, style: valueStyle),
                              ],
                            )
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(_hiddenValue,
                                    softWrap: false, style: valueStyle),
                              ),
                            ),
                    ),
                  ),
                ),
                Semantics(
                  identifier: 'yk_reveal_$id',
                  child: IconButton(
                    tooltip: shown
                        ? l.pinHideField(fieldLabel)
                        : l.pinShowField(fieldLabel),
                    icon: Icon(shown
                        ? Icons.visibility_off_outlined
                        : Icons.visibility),
                    onPressed: () {
                      _session.touch();
                      setState(() {
                        if (!_revealed.remove('${k.serial}/$field')) {
                          _revealed.add('${k.serial}/$field');
                        }
                      });
                    },
                  ),
                ),
                Semantics(
                  identifier: 'yk_copy_$id',
                  child: IconButton(
                    tooltip: l.pinCopyField(fieldLabel),
                    icon: const Icon(Icons.copy, size: 20),
                    // A value with a blocking problem must not reach a card
                    // or a password manager.
                    onPressed:
                        problems.isEmpty ? () => _copyValue(value) : null,
                  ),
                ),
              ],
            ),
            if (shown && k.sha256Prefix[field] != null)
              Semantics(
                identifier: 'yk_sha_$id',
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    'sha256_6: ${k.sha256Prefix[field]}',
                    style: pinMono(context,
                        size: 12, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            if (problems.isNotEmpty)
              Semantics(
                identifier: 'yk_problem_$id',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in problems)
                      PinNotice(p, kind: PinNoticeKind.error),
                  ],
                ),
              ),
            if (warnings.isNotEmpty)
              Semantics(
                identifier: 'yk_warning_$id',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final w in warnings)
                      PinNotice(w, kind: PinNoticeKind.warning),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Notes ──

  Widget _notesCard(AppLocalizations l) {
    final theme = Theme.of(context);
    Widget section(String title, String text, {String? identifier}) =>
        Semantics(
          identifier: identifier,
          child: Padding(
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
          ),
        );
    return PinCard(
      children: [
        PinDisclosure(
          title: l.pinYkNotesTitle,
          identifier: 'yk_notes',
          children: [
            Text(l.pinYkHwTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _hardwareTable(l),
            const SizedBox(height: 6),
            PinCaption(l.pinYkHwFidoNote),
            section(l.pinYkBioTitle, l.pinYkBioNote, identifier: 'yk_bio_note'),
            section(l.pinYkPolicyTitle, l.pinYkPolicyNote,
                identifier: 'yk_policy_note'),
            section(l.pinYkDerivedTitle, l.pinYkDerivedNote),
            section(l.pinYkOtpTitle, l.pinYkOtpNote),
            section(l.pinYkMasterTitle,
                '${l.pinYkMasterNeverStored}\n${l.pinHiddenLastCharNote}'),
            section(l.pinYkDesktopTitle, l.pinYkDesktopOnlyNote,
                identifier: 'yk_desktop_note'),
          ],
        ),
      ],
    );
  }

  Widget _hardwareTable(AppLocalizations l) {
    final theme = Theme.of(context);
    String alphabet(YkField f) => switch (f.alphabet.length) {
          10 => l.pinYkAlphaDigits,
          16 => l.pinYkAlphaHex,
          _ => l.pinYkAlphaAlnum,
        };
    // Card limits (docs/BITWARDEN.md "Границы (факт)", ykman 5.9.0).
    String card(String f) => switch (f) {
          '00' || '14' => l.pinYkHwBytes(6, 8),
          '25' => l.pinYkHwChars(8, 127),
          '41' => l.pinYkHwChars(6, 128),
          '45' || '46' => l.pinYkHwExactHex(12),
          _ =>
            l.pinYkHwChars(ykHardwareLimits[f]!.min, ykHardwareLimits[f]!.max),
        };
    String generated(String f) {
      final spec = ykFields[f]!;
      final derived = ykDefaultLength(f, YkMode.derived);
      final random = ykDefaultLength(f, YkMode.random);
      return derived == random
          ? l.pinYkGenSame(derived, alphabet(spec))
          : l.pinYkGenModes(derived, random, alphabet(spec));
    }

    Widget cell(String text, {bool header = false, bool mono = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Text(
            text,
            style: header
                ? theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                : (mono
                    ? pinMono(context, size: 12)
                    : theme.textTheme.bodySmall),
          ),
        );
    return Semantics(
      identifier: 'yk_hw_limits',
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
              cell(l.pinYkHwField, header: true),
              cell(l.pinYkHwCard, header: true),
              cell(l.pinYkHwApp, header: true),
            ]),
            for (final f in ykFields.keys)
              TableRow(children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: cell('$f ${ykFields[f]!.name}', mono: true),
                ),
                cell(card(f)),
                cell(generated(f)),
              ]),
          ],
        ),
      ),
    );
  }
}
