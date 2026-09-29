// Contrast (UX #7) and bidi (UX #6) checks for the PIN tab.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';

/// WCAG 2.x contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Left edge of the glyph at [index] as laid out in [painter].
double glyphLeft(TextPainter painter, int index) => painter
    .getBoxesForSelection(
        TextSelection(baseOffset: index, extentOffset: index + 1))
    .first
    .left;

TextPainter layoutRtl(String text) => TextPainter(
      text: TextSpan(text: text, style: const TextStyle(fontSize: 14)),
      textDirection: TextDirection.rtl,
    )..layout(maxWidth: 2000);

void main() {
  group('UX #7: text colours meet WCAG AA (4.5:1)', () {
    // (text colour, source colour whose 10–14 % tint it may sit on)
    final pairs = <String, (Color Function(Brightness), Color)>{
      'ok / output digits': (PinColors.okText, PinColors.valid),
      'warning / vector digits': (PinColors.warningText, PinColors.partial),
      'info / input digits': (PinColors.infoText, PinColors.info),
      'banner text': (PinColors.bannerText, PinColors.partial),
    };
    for (final b in Brightness.values) {
      final card = PinColors.cardSurface(b);
      for (final MapEntry(key: name, value: (text, source)) in pairs.entries) {
        test('$name on the ${b.name} card and on its tint', () {
          final fg = text(b);
          expect(contrast(fg, card), greaterThanOrEqualTo(4.5),
              reason: '$name on card');
          for (final alpha in [0.10, 0.12, 0.14]) {
            final tint =
                Color.alphaBlend(source.withValues(alpha: alpha), card);
            expect(contrast(fg, tint), greaterThanOrEqualTo(4.5),
                reason: '$name on a ${(alpha * 100).round()} % tint');
          }
        });
      }
    }

    test('the raw source colours are what failed in the light theme', () {
      final card = PinColors.cardSurface(Brightness.light);
      expect(contrast(PinColors.valid, card), lessThan(4.5));
      expect(contrast(PinColors.partial, card), lessThan(4.5));
      expect(PinColors.textFor(PinColors.valid, Brightness.light),
          PinColors.okText(Brightness.light));
      expect(PinColors.textFor(PinColors.info, Brightness.dark),
          PinColors.infoText(Brightness.dark));
    });
  });

  group('UX #6: maths keeps its order in Arabic', () {
    const sentence = 'فضاء المفاتيح: ';

    test('without an isolate the formula is reversed (the bug)', () {
      const text = '${sentence}10^4 = 10,000، وهي';
      final p = layoutRtl(text);
      const one = sentence.length; // "1" of "10^4"
      const four = sentence.length + 3; // "4" of "10^4"
      expect(glyphLeft(p, one), greaterThan(glyphLeft(p, four)));
    });

    test('ltrIsolate keeps 10^4 left-to-right', () {
      final text = '$sentence${ltrIsolate('10^4 = 10,000')}، وهي';
      final p = layoutRtl(text);
      const one = sentence.length + 1; // after U+2066
      const caret = one + 2; // "^"
      const four = one + 3;
      expect(glyphLeft(p, one), lessThan(glyphLeft(p, caret)));
      expect(glyphLeft(p, caret), lessThan(glyphLeft(p, four)));
    });

    test('the Arabic strings mark their formulas left-to-right', () async {
      final l = await AppLocalizations.delegate.load(const Locale('ar'));
      final cases = <String, String>{
        l.pinShiftThreatBody(4): '10^4',
        l.pinLegacyAboutBody: '9^8',
        l.pinShiftPaperExampleEncodeNote: '4 + 9 = 13',
        l.pinYkOtpFromSerialHelp: '38715242 → 000038715242',
      };
      for (final MapEntry(key: text, value: formula) in cases.entries) {
        final at = text.indexOf(formula);
        expect(at, greaterThan(0), reason: formula);
        expect(text[at - 1], '\u200e', reason: 'LRM before $formula');
        final p = layoutRtl(text);
        // The first character of the formula is drawn left of its last one.
        expect(
            glyphLeft(p, at), lessThan(glyphLeft(p, at + formula.length - 1)),
            reason: formula);
      }
      // No isolate controls in the ARB (the analyzer rejects them in the
      // generated code); the code adds them with ltrIsolate.
      expect(l.pinShiftThreatBody(4), isNot(contains('\u2066')));
    });
  });
}
