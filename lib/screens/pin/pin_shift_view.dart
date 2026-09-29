import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../l10n/app_localizations.dart';
import '../../pin_tools/pin_shift.dart';
import '../../widgets/option_pills.dart';
import 'pin_session.dart';
import 'pin_widgets.dart';

/// Quick-pick lengths: the source page's 4 and 8, plus 6 (spec #3 SHOULD).
const List<int> _quickLengths = [4, 6, 8];

/// Cell colours of the source page (`PALETTE`).
const Color _inputColor = PinColors.info; // #4B6FFF
const Color _vectorColor = PinColors.partial; // #D97706
const Color _outputColor = PinColors.valid; // #2EA043

/// PIN Shift: per-position modulo-10 shift of a PIN by a secret vector
/// (port of `crypto_tools/pin_shift_ui.py`, core in
/// `lib/pin_tools/pin_shift.dart`).
///
/// Mnemonic obfuscation, not a cipher. The PIN and the vector live only in
/// this widget's text controllers; they are cleared by every section wipe
/// (background, 2 min idle, 🚨, screenshot, leaving the tab), by Clear and
/// when the widget goes away. There is deliberately no copy button: the
/// derived PIN is meant to be recomputed, never written down. Errors report
/// positions only, never the characters typed. While "Reveal" is off
/// nothing hints at the hidden inputs: no weak-vector notices, and screen
/// readers are not given the digits.
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

class _PinShiftViewState extends ConsumerState<PinShiftView> {
  late final ProviderSubscription<PinSession> _sessionSub;
  late final PinSession _session;
  VoidCallback? _unregisterProbe;

  final _pinCtrl = TextEditingController();
  final _vecCtrl = TextEditingController();

  bool _decode = false;
  int _length = kShiftDefaultLength;

  // Reveal toggles: off on every visit, after every wipe and on Clear.
  bool _showPin = false;
  bool _showVector = false;
  bool _reveal = false;

  /// Bumped by every wipe and Clear: the fields are rebuilt with an empty
  /// undo history.
  int _fieldGen = 0;

  @override
  void initState() {
    super.initState();
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _session.wipes.addListener(_onWipe);
    _unregisterProbe = _session.registerContentProbe(_hasContent);
    _session.touch();
  }

  @override
  void dispose() {
    _session.wipes.removeListener(_onWipe);
    _unregisterProbe?.call();
    _sessionSub.close();
    _pinCtrl.clear();
    _vecCtrl.clear();
    _pinCtrl.dispose();
    _vecCtrl.dispose();
    // Never let iOS/Android offer to save what was typed as a password.
    TextInput.finishAutofillContext(shouldSave: false);
    super.dispose();
  }

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
    setState(() {
      _fieldGen++;
      _showPin = false;
      _showVector = false;
      _reveal = false;
    });
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

  void _setDecode(bool decode) {
    _session.touch();
    setState(() => _decode = decode);
  }

  void _setLength(int length) {
    _session.touch();
    setState(() => _length = length.clamp(kShiftMinLength, kShiftMaxLength));
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final pin = _FieldCheck(_pinCtrl.text, _length);
    final vec = _FieldCheck(_vecCtrl.text, _length);
    return Semantics(
      identifier: 'pin_shift_view',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _introCard(l),
          _directionCard(l),
          _lengthCard(l),
          _pinCard(l, pin),
          _vectorCard(l, vec),
          _resultCard(l, pin, vec),
          _paperCard(l),
          _threatCard(l),
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
      ],
    );
  }

  Widget _directionCard(AppLocalizations l) {
    return PinCard(
      title: l.pinShiftSectionDirection,
      children: [
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
      ],
    );
  }

  Widget _lengthCard(AppLocalizations l) {
    return PinCard(
      title: l.pinShiftSectionLength,
      children: [
        PinCaption(l.pinShiftLengthMustMatch),
        const SizedBox(height: 8),
        OptionPills<int>(
          padding: EdgeInsets.zero,
          options: [
            for (final n in _quickLengths)
              (value: n, label: l.pin24LengthButton(n)),
          ],
          identifiers: [for (final n in _quickLengths) 'pin_shift_len_$n'],
          selected: _length,
          onSelected: _setLength,
        ),
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
                onPressed: _length > kShiftMinLength
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
                onPressed: _length < kShiftMaxLength
                    ? () => _setLength(_length + 1)
                    : null,
                icon: const Icon(Icons.add),
              ),
            ),
          ],
        ),
      ],
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
          onChanged: _edited,
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

  Widget _vectorCard(AppLocalizations l, _FieldCheck vec) {
    final theme = Theme.of(context);
    return PinCard(
      title: l.pinShiftSectionVector,
      children: [
        PinSecretField(
          controller: _vecCtrl,
          identifier: 'pin_shift_vector',
          wipeGeneration: _fieldGen,
          obscure: !_showVector,
          pasteOnlyMenu: true,
          monospace: true,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.number,
          labelText: l.pinShiftFieldVector,
          helperText: l.pinShiftFieldVectorHelp(_length),
          onChanged: _edited,
          suffixIcon: _eye(
            identifier: 'pin_shift_vector_eye',
            field: l.pinShiftFieldVector,
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

  // ── Result ──

  Widget _resultCard(AppLocalizations l, _FieldCheck pin, _FieldCheck vec) {
    final body = <Widget>[
      PinSwitchRow(
        identifier: 'pin_shift_reveal',
        icon: Icons.visibility_outlined,
        label: l.pinShiftReveal,
        caption: l.pinShiftRevealHelp,
        value: _reveal,
        onChanged: (v) {
          _session.touch();
          setState(() => _reveal = v);
        },
      ),
      const SizedBox(height: 8),
    ];

    if (pin.hasError || vec.hasError) {
      body.add(Semantics(
        identifier: 'pin_shift_fix_errors',
        child: PinNotice(l.pinFixErrorsAbove),
      ));
    } else if (!(pin.ok && vec.ok)) {
      body
        ..add(_digitRow(
          label: _decode ? l.pinShiftRowOutputBase : l.pinShiftRowOutputDerived,
          value: '•' * _length,
          color: PinColors.emptyText,
          identifier: 'pin_shift_output',
          semantics: l.pinShiftOutputEmpty,
        ))
        ..add(const SizedBox(height: 6))
        ..add(Semantics(
          identifier: 'pin_shift_incomplete',
          child: PinCaption(l.pinShiftFillBoth(_length)),
        ));
    } else {
      body.addAll(_validResult(l, pin.value, vec.value));
    }

    body.addAll([
      const SizedBox(height: 12),
      PinCaption(l.pinShiftNoCopyNote),
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
          value: vector,
          color: _vectorColor,
          identifier: 'pin_shift_vector_row',
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
        ..add(PinCaption(l.pinShiftHiddenNote));
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
    // visible output would give away the base PIN.
    if (_reveal && vector.runes.every((r) => r == 0x30)) {
      out.add(Semantics(
        identifier: 'pin_shift_weak_zero',
        child: PinNotice(l.pinShiftWeakZero, kind: PinNoticeKind.warning),
      ));
    }
    if (_reveal && vector == base) {
      out.add(Semantics(
        identifier: 'pin_shift_weak_equal',
        child: PinNotice(l.pinShiftWeakEqualsBase, kind: PinNoticeKind.warning),
      ));
    }
    if (_reveal && vector.runes.every((r) => r == 0x35)) {
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
          children: [_breakdownTable(l, pin, vector)],
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

  Widget _breakdownTable(AppLocalizations l, String pin, String vector) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final rows = shiftBreakdown(pin, vector, decode: _decode);
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
                cell('${r.vector}', color: PinColors.textFor(_vectorColor, b)),
                cell(r.formula),
                cell('${r.output}', color: PinColors.textFor(_outputColor, b)),
              ]),
          ],
        ),
      ),
    );
  }

  // ── Reference material (always available) ──

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

  /// The paper template for the chosen length and direction.
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
