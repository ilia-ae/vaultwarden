import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/services.dart' show HapticFeedback;

import '../glass.dart';

/// Full-width segmented control for the pickers at the top of a tab (Vault's
/// Pending/History, the PIN tool picker).
///
/// A calm, neutral control — the second level under the top bar's primary
/// tabs, so it never uses the accent colour: one flat grey track (dark grey
/// in the dark theme, light grey in the light one; no border, no gradient)
/// and a slightly lighter selected segment inset [inset] on every side,
/// with concentric corners ([radius] on the track). The segment glides with
/// [appSpring]; Reduce Motion moves it instantly.
///
/// Equal-width segments span the content width inside the cards' gutters
/// ([gutter], on top of the list's safe-area insets). The track is short
/// ([minTrackHeight] at text scale 1), but every segment takes taps over a
/// [tapMargin] strip above and below it too, so each target is at least
/// [minTapHeight] tall.
///
/// A segment may show a count after its label ([counts]): "Pending 1", a
/// quiet digit rather than a badge, read as "Pending, 1".
///
/// Labels never clip: labels slightly too long for one line all shrink
/// together (to 80 % at most); beyond that a label wraps to two lines
/// between words, and one that still does not fit (a long word, a huge text
/// scale on a narrow phone) is scaled down. The control grows in height
/// with the text.
///
/// Accessibility: a tab bar of tabs, each with its selected state, a tap
/// action and the optional Semantics [identifiers] (Maestro / store
/// screenshot flows). RTL mirrors the order and the selected segment.
class SegmentedTabs<T> extends StatefulWidget {
  const SegmentedTabs({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.identifiers,
    this.counts,
    this.padding = gutter,
  }) : assert(segments.length >= 2, 'a segmented control needs 2+ segments');

  /// The segments, in reading order.
  final List<({T value, String label})> segments;

  /// The selected value. The selected segment follows it; a tap only
  /// reports [onSelected], so the owner may refuse or confirm the switch
  /// first.
  final T selected;

  /// Called on a tap of any segment, including the selected one.
  final ValueChanged<T> onSelected;

  /// Optional Semantics identifiers, one per segment.
  final List<String>? identifiers;

  /// Optional counts shown after a segment's label ("Pending 1"). A missing
  /// or non-positive count shows nothing.
  final Map<T, int>? counts;

  /// Space around the control: the cards' side gutters by default.
  final EdgeInsetsGeometry padding;

  /// The cards' side gutter (ContentCard/PinCard margins).
  static const EdgeInsetsGeometry gutter = EdgeInsets.symmetric(horizontal: 20);

  /// Visible track height with one-line labels at text scale 1.
  static const double minTrackHeight = 36;

  /// Minimum height of a segment's tap target.
  static const double minTapHeight = 48;

  /// The strip above and below the track that still takes a segment's taps
  /// (the control's box is the track plus these). Screens that want a given
  /// visible gap under the track subtract it.
  static const double tapMargin = (minTapHeight - minTrackHeight) / 2;

  /// Gap between the track and the selected segment, on every side.
  static const double inset = 3;

  /// Track corner radius; the selected segment's is concentric.
  static const double radius = 12;

  /// The track and the selected segment (tests find them by these keys).
  static const Key trackKey = ValueKey<String>('SegmentedTabs.track');
  static const Key thumbKey = ValueKey<String>('SegmentedTabs.thumb');

  /// Neutral greys: the track, and the slightly lighter selected segment.
  static Color trackColor(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF252528)
          : const Color(0xFFE4E4E9);

  static Color thumbColor(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF3B3B40)
          : const Color(0xFFFFFFFF);

  /// Label padding inside a segment.
  static const double _hPad = 4;
  static const double _vPad = 5;

  static const Duration _duration = Duration(milliseconds: 450);

  @override
  State<SegmentedTabs<T>> createState() => _SegmentedTabsState<T>();
}

class _SegmentedTabsState<T> extends State<SegmentedTabs<T>>
    with SingleTickerProviderStateMixin {
  /// Selected-segment position in segment units (0 = first segment).
  /// Unbounded so the spring's small overshoot is not clipped.
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: math.max(_selectedIndex, 0).toDouble(),
  );

  /// Where the selected segment is going.
  double _to = 0;

  /// Bumped when a GlobalKey moves this control under a new parent (the
  /// Vault tab swaps the list under its picker and keeps the picker, so the
  /// selected segment can glide). The tabs then get NEW semantics nodes:
  /// iOS loses the parent link of a node that moved between parents, and
  /// its frame collapses to a 1/3-scale rect at the top-left (Maestro taps
  /// on `tab_history` hit the status bar).
  int _generation = 0;

  int get _selectedIndex =>
      widget.segments.indexWhere((s) => s.value == widget.selected);

  @override
  void initState() {
    super.initState();
    _to = _position.value;
  }

  @override
  void didUpdateWidget(SegmentedTabs<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = _selectedIndex;
    if (index < 0) return;
    final target = index.toDouble();
    if (target == _to) return;
    _to = target;
    // A changed segment list (a tool shown or hidden) is not a move.
    final instant = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (instant || oldWidget.segments.length != widget.segments.length) {
      _position.value = target;
    } else {
      _position.animateTo(target,
          duration: SegmentedTabs._duration, curve: appSpring);
    }
  }

  @override
  void activate() {
    super.activate();
    _generation++;
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _tap(int index) {
    if (index != _selectedIndex) HapticFeedback.selectionClick();
    widget.onSelected(widget.segments[index].value);
  }

  int _count(int index) => widget.counts?[widget.segments[index].value] ?? 0;

  /// What a segment shows: its label, then its count (if any) joined by a
  /// no-break space so the two never wrap apart.
  String _display(int index) {
    final label = widget.segments[index].label;
    final count = _count(index);
    return count > 0 ? '$label\u00A0$count' : label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final cs = theme.colorScheme;
    final base = DefaultTextStyle.of(context).style.merge(
          (theme.textTheme.labelLarge ?? const TextStyle(fontSize: 14))
              .copyWith(fontWeight: FontWeight.w500),
        );
    // Measured at the selected (heavier) weight, so selecting a segment
    // never reflows its label.
    final measureStyle = base.copyWith(fontWeight: FontWeight.w600);
    final n = widget.segments.length;
    final selected = _selectedIndex;

    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth =
              (constraints.maxWidth - 2 * SegmentedTabs.inset) / n;
          final available =
              math.max(segmentWidth - 2 * SegmentedTabs._hPad, 1.0);
          final texts = [for (var i = 0; i < n; i++) _display(i)];
          // Labels a little too long for one line all shrink together
          // (like UISegmentedControl) rather than one of them wrapping.
          final shrink = _LabelFit.uniformShrink(
            context,
            texts,
            measureStyle,
            available,
          );
          final labelStyle = _LabelFit.scaled(base, shrink);
          final fits = [
            for (final text in texts)
              _LabelFit.measure(
                context,
                text,
                _LabelFit.scaled(measureStyle, shrink),
                available,
              ),
          ];
          final labelHeight = fits.map((f) => f.height).reduce(math.max);
          final track = math.max(
            SegmentedTabs.minTrackHeight,
            labelHeight + 2 * (SegmentedTabs.inset + SegmentedTabs._vPad),
          );
          const margin = SegmentedTabs.tapMargin;
          const inset = SegmentedTabs.inset;

          // A new subtree (new semantics nodes) after a move to another
          // parent, see [_generation].
          return KeyedSubtree(
            key: ValueKey(_generation),
            child: SizedBox(
              height: track + 2 * margin,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: margin,
                    height: track,
                    child: DecoratedBox(
                      key: SegmentedTabs.trackKey,
                      decoration: _decoration(
                        SegmentedTabs.trackColor(brightness),
                        SegmentedTabs.radius,
                      ),
                    ),
                  ),
                  if (selected >= 0)
                    AnimatedBuilder(
                      animation: _position,
                      builder: (context, _) => PositionedDirectional(
                        // Positioned by start offset, so it mirrors in RTL
                        // with the row.
                        start: inset +
                            _position.value.clamp(0.0, n - 1.0) * segmentWidth,
                        top: margin + inset,
                        width: segmentWidth,
                        height: track - 2 * inset,
                        child: DecoratedBox(
                          key: SegmentedTabs.thumbKey,
                          decoration: _decoration(
                            SegmentedTabs.thumbColor(brightness),
                            SegmentedTabs.radius - inset,
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: inset),
                      child: Semantics(
                        container: true,
                        role: SemanticsRole.tabBar,
                        explicitChildNodes: true,
                        child: Row(
                          children: [
                            for (var i = 0; i < n; i++)
                              Expanded(
                                child: _segment(
                                  i,
                                  fits[i],
                                  labelStyle,
                                  cs,
                                  selected: i == selected,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// One segment: the whole cell, [SegmentedTabs.tapMargin] strips
  /// included, takes the tap; the label sits on the track's centre line.
  Widget _segment(
    int index,
    _LabelFit fit,
    TextStyle base,
    ColorScheme cs, {
    required bool selected,
  }) {
    final ids = widget.identifiers;
    final label = widget.segments[index].label;
    final count = _count(index);
    return Semantics(
      container: true,
      identifier: ids != null && index < ids.length ? ids[index] : null,
      role: SemanticsRole.tab,
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _tap(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SegmentedTabs._hPad,
          ),
          child: Center(
            child: AnimatedBuilder(
              animation: _position,
              builder: (context, _) {
                // 1 under the selected segment, fading with its distance.
                final active =
                    (1 - (_position.value - index).abs()).clamp(0.0, 1.0);
                final style = base.copyWith(
                  fontWeight:
                      FontWeight.lerp(FontWeight.w500, FontWeight.w600, active),
                  color: Color.lerp(cs.onSurfaceVariant, cs.onSurface, active),
                );
                return fit.build(
                  TextSpan(
                    text: label,
                    children: [
                      if (count > 0)
                        TextSpan(
                          // A quiet count: the muted colour, regular weight,
                          // figures that do not jump as it changes.
                          text: '\u00A0$count',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                  style,
                  // "Pending, 1": the count is read with the label.
                  semanticsLabel: count > 0 ? '$label, $count' : null,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Flat fill, no border, no gradient, no shadow.
  static ShapeDecoration _decoration(Color color, double radius) =>
      ShapeDecoration(
        color: color,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(math.max(radius, 0)),
        ),
      );
}

enum _LabelMode { oneLine, twoLines, scaled }

/// How one label fits its segment: on one line, wrapped to two lines, or
/// (a word longer than the segment) laid out at [layoutWidth] and scaled
/// down. [height] is the height it takes in the segment.
class _LabelFit {
  const _LabelFit(this.mode, this.height, [this.layoutWidth = 0]);

  final _LabelMode mode;
  final double height;
  final double layoutWidth;

  /// Labels may shrink down to this share of their size to stay on one
  /// line; below it they wrap instead (see [measure]).
  static const double minShrink = 0.8;

  /// The common factor that puts every label on one line, if that needs
  /// at most [minShrink]; 1 otherwise (nothing to do, or too much).
  static double uniformShrink(
    BuildContext context,
    List<String> labels,
    TextStyle style,
    double available,
  ) {
    var widest = 0.0;
    for (final label in labels) {
      final p = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
        locale: Localizations.maybeLocaleOf(context),
        textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
      )..layout();
      widest = math.max(widest, p.width);
      p.dispose();
    }
    if (widest <= available) return 1;
    // Rounded down so the shrunk labels fit, not overflow by a rounding.
    final factor = (available / widest * 1000).floorToDouble() / 1000;
    return factor >= minShrink ? factor : 1;
  }

  static TextStyle scaled(TextStyle style, double factor) => factor == 1
      ? style
      : style.copyWith(
          fontSize: (style.fontSize ?? 14) * factor,
          letterSpacing: style.letterSpacing == null
              ? null
              : style.letterSpacing! * factor,
        );

  static _LabelFit measure(
    BuildContext context,
    String label,
    TextStyle style,
    double available,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final heightBehavior = DefaultTextHeightBehavior.maybeOf(context);
    TextPainter painter(String text, int maxLines, double maxWidth) =>
        TextPainter(
          text: TextSpan(text: text, style: style),
          textAlign: TextAlign.center,
          textDirection: direction,
          textScaler: scaler,
          maxLines: maxLines,
          locale: locale,
          textHeightBehavior: heightBehavior,
        )..layout(maxWidth: maxWidth);

    final one = painter(label, 1, double.infinity);
    final oneWidth = one.width;
    final oneHeight = one.height;
    one.dispose();
    if (oneWidth <= available) return _LabelFit(_LabelMode.oneLine, oneHeight);

    var longestWord = 0.0;
    // A no-break space (label + count) does not split a word.
    for (final word in label.split(RegExp(r'[^\S\u00A0]+'))) {
      if (word.isEmpty) continue;
      final p = painter(word, 1, double.infinity);
      longestWord = math.max(longestWord, p.width);
      p.dispose();
    }
    if (longestWord <= available) {
      final two = painter(label, 2, available);
      final fitsTwo = !two.didExceedMaxLines;
      final twoHeight = two.height;
      two.dispose();
      if (fitsTwo) return _LabelFit(_LabelMode.twoLines, twoHeight);
    }

    // Too long even on two lines: lay it out wider (never breaking a word)
    // and scale the block down to the segment.
    var width = math.max(longestWord, available);
    while (true) {
      final p = painter(label, 2, width);
      final exceeded = p.didExceedMaxLines;
      final h = p.height;
      p.dispose();
      if (!exceeded || width >= oneWidth) {
        return _LabelFit(_LabelMode.scaled, h * available / width, width);
      }
      width = math.min(width * 1.2, oneWidth);
    }
  }

  Widget build(InlineSpan text, TextStyle style, {String? semanticsLabel}) =>
      switch (mode) {
        _LabelMode.oneLine => Text.rich(
            text,
            style: style,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
            semanticsLabel: semanticsLabel,
          ),
        _LabelMode.twoLines => Text.rich(
            text,
            style: style,
            maxLines: 2,
            textAlign: TextAlign.center,
            semanticsLabel: semanticsLabel,
          ),
        _LabelMode.scaled => FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: layoutWidth,
              child: Text.rich(
                text,
                style: style,
                maxLines: 2,
                textAlign: TextAlign.center,
                semanticsLabel: semanticsLabel,
              ),
            ),
          ),
      };
}
