import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/widgets/segmented_tabs.dart';

const _labels = ['PIN Shift', 'PIN 24', 'YubiKey', 'Legacy mask'];
const _ids = ['seg_0', 'seg_1', 'seg_2', 'seg_3'];

/// A host that owns the selection, like the two screens do.
class _Host extends StatefulWidget {
  const _Host({
    required this.count,
    this.onTap,
    this.initial = 0,
    this.labels = _labels,
    this.counts,
  });

  final int count;
  final int initial;
  final ValueChanged<int>? onTap;
  final List<String> labels;
  final Map<int, int>? counts;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int selected = widget.initial;

  @override
  Widget build(BuildContext context) => SegmentedTabs<int>(
        segments: [
          for (var i = 0; i < widget.count; i++)
            (value: i, label: widget.labels[i]),
        ],
        identifiers: _ids.take(widget.count).toList(),
        counts: widget.counts,
        selected: selected,
        onSelected: (v) {
          widget.onTap?.call(v);
          setState(() => selected = v);
        },
      );
}

Future<void> _pump(
  WidgetTester tester, {
  int count = 2,
  double width = 402,
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  bool reduceMotion = false,
  ValueChanged<int>? onTap,
  int initial = 0,
  List<String> labels = _labels,
  Map<int, int>? counts,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width * 3, 874 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    // The app's themes: Material 3, blue seed (the accent is blue).
    theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: _Host(
                count: count,
                onTap: onTap,
                initial: initial,
                labels: labels,
                counts: counts,
              ),
            ),
          ),
        ),
      ),
    ),
  ));
}

Finder _seg(int i) => find.bySemanticsIdentifier(_ids[i]);

/// The selected segment (the "thumb") and the track under it.
Rect _thumb(WidgetTester tester) =>
    tester.getRect(find.byKey(SegmentedTabs.thumbKey));

Rect _track(WidgetTester tester) =>
    tester.getRect(find.byKey(SegmentedTabs.trackKey));

ShapeDecoration _decoration(WidgetTester tester, Key key) =>
    tester.widget<DecoratedBox>(find.byKey(key)).decoration as ShapeDecoration;

/// The thumb inside the selected segment's cell: the same columns, inset
/// [SegmentedTabs.inset] from the track at the top and bottom.
Rect _thumbFor(WidgetTester tester, int i) {
  final segment = tester.getRect(_seg(i));
  final track = _track(tester);
  return Rect.fromLTRB(
    segment.left,
    track.top + SegmentedTabs.inset,
    segment.right,
    track.bottom - SegmentedTabs.inset,
  );
}

/// A grey: red, green and blue within a few steps of each other.
bool _isNeutral(Color c) {
  final r = (c.r * 255).round(), g = (c.g * 255).round();
  final b = (c.b * 255).round();
  return (r - g).abs() <= 6 && (g - b).abs() <= 6 && (r - b).abs() <= 6;
}

/// Colours of every label's text runs in the control.
List<Color> _labelColors(WidgetTester tester) {
  final colors = <Color>[];
  for (final p in tester.renderObjectList<RenderParagraph>(find.descendant(
      of: find.byType(SegmentedTabs<int>), matching: find.byType(RichText)))) {
    // The label's colour is on the root span, a count's on its own span.
    final root = p.text.style?.color;
    if (root != null) colors.add(root);
    p.text.visitChildren((span) {
      final color = span.style?.color;
      if (color != null) colors.add(color);
      return true;
    });
  }
  return colors;
}

void main() {
  testWidgets('equal-width segments span the content width in the gutters',
      (tester) async {
    await _pump(tester, count: 2);
    final track = _track(tester);
    expect(track.left, 20, reason: 'the cards\' gutter');
    expect(track.right, 402 - 20);
    expect(track.height, SegmentedTabs.minTrackHeight);
    // The control's box: the track plus its tap margins.
    expect(tester.getSize(find.byType(SegmentedTabs<int>)).height,
        SegmentedTabs.minTrackHeight + 2 * SegmentedTabs.tapMargin);
    final widths = [for (var i = 0; i < 2; i++) tester.getRect(_seg(i)).width];
    expect(widths.first, moreOrLessEquals(widths.last));
    expect(widths.first * 2, moreOrLessEquals(402 - 40 - 2 * 3));
    // Left to right, touching.
    expect(tester.getRect(_seg(0)).left, 20 + SegmentedTabs.inset);
    expect(tester.getRect(_seg(1)).left,
        moreOrLessEquals(tester.getRect(_seg(0)).right));
    // The selected segment sits 3 pt inside the track on every side.
    final thumb = _thumb(tester);
    expect(thumb, rectMoreOrLessEquals(_thumbFor(tester, 0)));
    expect(thumb.left - track.left, SegmentedTabs.inset);
    expect(thumb.top - track.top, SegmentedTabs.inset);
    expect(track.bottom - thumb.bottom, SegmentedTabs.inset);
    expect(thumb.height, SegmentedTabs.minTrackHeight - 2 * 3);
    // The labels sit on the track's centre line.
    expect(tester.getCenter(find.text(_labels[0])).dy,
        moreOrLessEquals(track.center.dy, epsilon: 0.5));
  });

  testWidgets('every segment takes taps over at least 48 x 48 pt',
      (tester) async {
    final taps = <int>[];
    await _pump(tester, count: 4, width: 320, onTap: taps.add);
    final track = _track(tester);
    for (var i = 0; i < 4; i++) {
      final hit = tester.getRect(_seg(i));
      expect(hit.height, greaterThanOrEqualTo(48), reason: 'segment $i');
      expect(hit.width, greaterThanOrEqualTo(48), reason: 'segment $i');
      // Taller than the visible track: the tap margins above and below.
      expect(hit.top, lessThan(track.top));
      expect(hit.bottom, greaterThan(track.bottom));
    }
    // A tap just above the track still selects the segment under it.
    final third = tester.getRect(_seg(2));
    await tester.tapAt(Offset(third.center.dx, track.top - 4));
    await tester.pumpAndSettle();
    expect(taps, [2]);
    expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 2)));
    // ...and just below it.
    final second = tester.getRect(_seg(1));
    await tester.tapAt(Offset(second.center.dx, track.bottom + 4));
    await tester.pumpAndSettle();
    expect(taps, [2, 1]);
  });

  for (final brightness in Brightness.values) {
    testWidgets('neutral colours, no accent (${brightness.name})',
        (tester) async {
      await _pump(tester, count: 2, brightness: brightness);
      final cs =
          Theme.of(tester.element(find.byType(SegmentedTabs<int>))).colorScheme;
      final track = _decoration(tester, SegmentedTabs.trackKey);
      final thumb = _decoration(tester, SegmentedTabs.thumbKey);
      expect(track.color, SegmentedTabs.trackColor(brightness));
      expect(thumb.color, SegmentedTabs.thumbColor(brightness));
      for (final d in [track, thumb]) {
        expect(_isNeutral(d.color!), isTrue, reason: '${d.color}');
        expect(d.color, isNot(cs.primary));
        expect(d.gradient, isNull, reason: 'flat');
        expect(d.shadows, isNull);
        final shape = d.shape as RoundedSuperellipseBorder;
        expect(shape.side, BorderSide.none, reason: 'no visible border');
      }
      // One neutral container: dark grey in dark, light grey in light; the
      // selected segment a little lighter than it.
      final trackLum = track.color!.computeLuminance();
      final thumbLum = thumb.color!.computeLuminance();
      if (brightness == Brightness.dark) {
        expect(trackLum, inExclusiveRange(0.005, 0.05));
      } else {
        expect(trackLum, inExclusiveRange(0.6, 0.9));
      }
      expect(thumbLum, greaterThan(trackLum));
      expect(thumbLum - trackLum, lessThan(0.3), reason: 'slightly lighter');
      // Concentric corners: 12 on the track, 12 - 3 on the segment.
      expect((track.shape as RoundedSuperellipseBorder).borderRadius,
          BorderRadius.circular(SegmentedTabs.radius));
      expect((thumb.shape as RoundedSuperellipseBorder).borderRadius,
          BorderRadius.circular(SegmentedTabs.radius - SegmentedTabs.inset));
      // No accent in the labels either.
      final colors = _labelColors(tester);
      expect(colors, isNotEmpty);
      for (final c in colors) {
        expect(c, isNot(cs.primary));
        expect(c, isNot(cs.secondary));
      }
      // 14 pt labels.
      final paragraph =
          tester.renderObject<RenderParagraph>(find.text(_labels[0]));
      expect(paragraph.text.style!.fontSize, 14);
    });
  }

  testWidgets('a count after a label: shown, updated, gone at zero',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, count: 2, counts: {0: 1});
    const nbsp = '\u00A0';
    expect(find.text('PIN Shift${nbsp}1'), findsOneWidget);
    expect(
      tester.getSemantics(_seg(0)),
      matchesSemantics(
        identifier: 'seg_0',
        label: 'PIN Shift, 1',
        isButton: true,
        hasTapAction: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    // A quiet digit: the muted colour, not the label's, not the accent.
    final context = tester.element(find.byType(SegmentedTabs<int>));
    final cs = Theme.of(context).colorScheme;
    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
        of: find.text('PIN Shift${nbsp}1'), matching: find.byType(RichText)));
    TextSpan? countSpan;
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && span.text == '${nbsp}1') countSpan = span;
      return true;
    });
    expect(countSpan!.style!.color, cs.onSurfaceVariant);
    expect(countSpan!.style!.color, isNot(cs.primary));
    // The segment without a count is unchanged.
    expect(find.text('PIN 24'), findsOneWidget);
    expect(tester.getSemantics(_seg(1)).label, 'PIN 24');

    await _pump(tester, count: 2, counts: {0: 2});
    expect(find.text('PIN Shift${nbsp}2'), findsOneWidget);
    expect(tester.getSemantics(_seg(0)).label, 'PIN Shift, 2');

    await _pump(tester, count: 2, counts: {0: 0});
    expect(find.text('PIN Shift'), findsOneWidget);
    expect(find.textContaining(nbsp), findsNothing);
    expect(tester.getSemantics(_seg(0)).label, 'PIN Shift');
    handle.dispose();
  });

  testWidgets('tap selects with a spring glide and a selection haptic',
      (tester) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final taps = <int>[];
    await _pump(tester, count: 2, onTap: taps.add);

    await tester.tap(_seg(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    // Mid-glide: between the two segments, its size unchanged (calm: no
    // liquid stretch).
    final mid = _thumb(tester);
    final a = _thumbFor(tester, 0);
    final b = _thumbFor(tester, 1);
    expect(mid.center.dx, inExclusiveRange(a.center.dx, b.center.dx));
    expect(mid.width, moreOrLessEquals(a.width));
    await tester.pumpAndSettle();
    expect(_thumb(tester), rectMoreOrLessEquals(b));
    expect(taps, [1]);
    expect(haptics, ['HapticFeedbackType.selectionClick']);

    // The selected segment again: reported, but no haptic, no move.
    await tester.tap(_seg(1));
    await tester.pumpAndSettle();
    expect(taps, [1, 1]);
    expect(haptics, hasLength(1));
    expect(_thumb(tester), rectMoreOrLessEquals(b));
  });

  testWidgets('Reduce Motion: the selected segment jumps', (tester) async {
    await _pump(tester, count: 3, reduceMotion: true);
    await tester.tap(_seg(2));
    await tester.pump();
    expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 2)));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('semantics: a tab bar of selectable tabs with their ids',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, count: 2);
    expect(
      tester.getSemantics(_seg(0)),
      matchesSemantics(
        identifier: 'seg_0',
        label: 'PIN Shift',
        isButton: true,
        hasTapAction: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    expect(
      tester.getSemantics(_seg(1)),
      matchesSemantics(
        identifier: 'seg_1',
        label: 'PIN 24',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    final tab = tester.getSemantics(_seg(1));
    expect(tab.getSemanticsData().role, SemanticsRole.tab);
    expect(tab.parent!.getSemanticsData().role, SemanticsRole.tabBar);
    // The segment's own node carries the id: its frame is the segment's
    // whole tap target.
    expect(tab.rect.size, tester.getSize(_seg(1)));
    expect(tab.rect.height, greaterThanOrEqualTo(48));

    await tester.tap(_seg(1));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(_seg(1)).flagsCollection.isSelected,
        Tristate.isTrue);
    expect(tester.getSemantics(_seg(0)).flagsCollection.isSelected,
        Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('RTL mirrors the order and the selected segment', (tester) async {
    await _pump(tester, count: 3, direction: TextDirection.rtl);
    final first = tester.getRect(_seg(0));
    final last = tester.getRect(_seg(2));
    expect(first.right, moreOrLessEquals(402 - 20 - SegmentedTabs.inset),
        reason: 'starts on the right');
    expect(last.left, moreOrLessEquals(20 + SegmentedTabs.inset));
    expect(first.width, moreOrLessEquals(last.width));
    expect(tester.getRect(_seg(1)).width, moreOrLessEquals(first.width));
    expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 0)));
    await tester.tap(_seg(2));
    await tester.pumpAndSettle();
    expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 2)));
  });

  testWidgets('RTL: a count follows its label (on its left)', (tester) async {
    await _pump(tester,
        count: 2,
        direction: TextDirection.rtl,
        labels: const ['معلّقة', 'السجل'],
        counts: {0: 3});
    final label = find.text('معلّقة\u00A03');
    expect(label, findsOneWidget);
    expect(tester.getCenter(label).dx,
        moreOrLessEquals(tester.getCenter(_seg(0)).dx, epsilon: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('4 segments: equal widths, the selection reaches the last',
      (tester) async {
    await _pump(tester, count: 4, initial: 3);
    final widths = [for (var i = 0; i < 4; i++) tester.getRect(_seg(i)).width];
    for (final w in widths) {
      expect(w, moreOrLessEquals((402 - 40 - 2 * 3) / 4));
    }
    expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 3)));
    await tester.tap(_seg(0));
    await tester.pumpAndSettle();
    expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 0)));
  });

  for (final direction in TextDirection.values) {
    testWidgets(
        'text scale 2.0 at 320 pt: 4 segments grow, nothing clips '
        '(${direction.name})', (tester) async {
      await _pump(tester,
          count: 4, width: 320, textScale: 2, direction: direction);
      expect(tester.takeException(), isNull);
      final track = _track(tester);
      expect(track.left, 20);
      expect(track.right, 300);
      expect(track.height, greaterThan(SegmentedTabs.minTrackHeight),
          reason: 'the control grows with the text');
      for (var i = 0; i < 4; i++) {
        final segment = tester.getRect(_seg(i));
        final text = find.text(_labels[i]);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, isFalse, reason: _labels[i]);
        // The painted text (after any scale-down) stays in its segment and
        // on the track.
        final painted = tester.getRect(text);
        expect(painted.left, greaterThanOrEqualTo(segment.left - 0.01));
        expect(painted.right, lessThanOrEqualTo(segment.right + 0.01));
        expect(painted.top, greaterThanOrEqualTo(track.top - 0.01));
        expect(painted.bottom, lessThanOrEqualTo(track.bottom + 0.01));
      }
      // Still tappable and still moving.
      await tester.tap(_seg(3));
      await tester.pumpAndSettle();
      expect(_thumb(tester), rectMoreOrLessEquals(_thumbFor(tester, 3)));
    });
  }

  testWidgets('labels a little too long shrink together on one line',
      (tester) async {
    // Test font: every glyph is as wide as the font size. 4 segments on
    // 402 pt leave 81 pt per label; 'Abcdef' needs 84 pt at 14 pt.
    const labels = ['Abcdef', 'Ab', 'Abc', 'Abcd'];
    await _pump(tester, count: 4, labels: labels);
    final sizes = <double>{};
    for (final label in labels) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(paragraph.maxLines, 1, reason: label);
      expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      expect(
          find.ancestor(of: find.text(label), matching: find.byType(FittedBox)),
          findsNothing);
      sizes.add(paragraph.text.style!.fontSize!);
    }
    expect(sizes, hasLength(1), reason: 'one size for all labels');
    expect(sizes.single, inInclusiveRange(14 * 0.8, 14 * 81 / 84));
    expect(_track(tester).height, SegmentedTabs.minTrackHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text wraps two words to two lines before scaling',
      (tester) async {
    await _pump(tester, count: 2, width: 320, textScale: 1.5);
    final label = find.text('PIN Shift');
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(paragraph.didExceedMaxLines, isFalse);
    // Not scaled: drawn at full size (labelLarge 14/20 x 1.5), two lines.
    expect(find.ancestor(of: label, matching: find.byType(FittedBox)),
        findsNothing);
    expect(tester.getRect(label).height, moreOrLessEquals(2 * 20 * 1.5));
    expect(tester.takeException(), isNull);
  });
}
