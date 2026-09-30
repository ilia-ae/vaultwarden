import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../glass.dart';
import '../l10n/app_localizations.dart';
import '../models/auth_request.dart';
import 'device_icon.dart';
import 'fingerprint_phrase.dart';

/// iOS system green, the "approved before" trust colour.
const kTrustGreen = Color(0xFF34C759);

/// `m:ss` for a countdown (never negative).
String formatCountdown(Duration d) {
  final seconds = d.isNegative ? 0 : d.inSeconds;
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// One pending "Login with device" request.
///
/// * Countdown of the 5-minute window on the server clock (F5): red under a
///   minute; once expired the card says so and Approve is disabled.
/// * No fingerprint phrase (malformed key) → "cannot verify", Approve
///   disabled (A1).
/// * Trust frame from local history plus a text/Semantics status line
///   ("Known IP" / "Denied IP", A7).
class AuthRequestCard extends StatefulWidget {
  final AuthRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  final bool isLoading;

  /// IP trust from history: true=previously approved, false=previously denied, null=unknown.
  final bool? ipTrust;

  /// Local clock (tests pass a fixed one); the request applies the server
  /// clock offset itself.
  final DateTime Function()? clock;

  const AuthRequestCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onDeny,
    this.isLoading = false,
    this.ipTrust,
    this.clock,
  });

  /// Width of the trust frame (1.5 before: it outshouted the content).
  static const double trustFrameWidth = 1;

  /// Opacity of the green/red trust frame.
  static const double trustFrameAlpha = 0.5;

  @override
  State<AuthRequestCard> createState() => _AuthRequestCardState();
}

/// The card's trust frame colour for [ipTrust] (see [AuthRequestCard]):
/// green for a previously approved IP, red for a denied one, grey for an
/// unknown one — all toned down.
Color trustFrameColor(bool? ipTrust, ColorScheme cs) => switch (ipTrust) {
      true => kTrustGreen.withValues(alpha: AuthRequestCard.trustFrameAlpha),
      false => cs.error.withValues(alpha: AuthRequestCard.trustFrameAlpha),
      null => cs.outlineVariant.withValues(alpha: 0.6),
    };

class _AuthRequestCardState extends State<AuthRequestCard> {
  Timer? _ticker;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AuthRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Ticks every second while the request can still be answered.
  void _syncTicker() {
    final live = widget.request.isActionableAt(_now());
    if (live && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!widget.request.isActionableAt(_now())) {
          _ticker?.cancel();
          _ticker = null;
        }
      });
    } else if (!live) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  String _timeAgo(AppLocalizations l, Duration age) {
    if (age.inSeconds < 60) return l.secondsAgo(age.inSeconds.clamp(0, 59));
    if (age.inMinutes < 60) return l.minutesAgo(age.inMinutes);
    if (age.inHours < 24) return l.hoursAgo(age.inHours);
    return l.daysAgo(age.inDays);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final request = widget.request;
    final ipTrust = widget.ipTrust;
    final now = _now();

    final remaining = request.remaining(now);
    final expired = !request.isActionableAt(now);
    final urgent = !expired && remaining < const Duration(minutes: 1);
    final fingerprint = request.fingerprint;
    final canApprove = !expired && fingerprint != null && !widget.isLoading;

    // Trust frame replaces the old inline badge: previously-approved IP = green,
    // previously-denied = red, never-seen = grey. Toned down (thin, half
    // alpha) so the request and the decision lead, not the frame; the status
    // line below says the same in words.
    final Color trustBorder = trustFrameColor(ipTrust, cs);

    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );

    return ContentCard(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      borderColor: trustBorder,
      borderWidth: AuthRequestCard.trustFrameWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: device (left) + timing (right). The timing takes at
          // most half the row: with large text it wraps instead of pushing
          // the row over the card's edge.
          LayoutBuilder(
            builder: (context, box) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DeviceIcon(
                  deviceName: request.requestDeviceType,
                  typeValue: request.requestDeviceTypeValue,
                  size: 36,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      request.requestDeviceType,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (request.hasCreationDate)
                        Text(
                          _timeAgo(l, request.age(now)),
                          style: secondary,
                          textAlign: TextAlign.end,
                        ),
                      Semantics(
                        identifier: 'text_request_countdown',
                        child: Text(
                          expired
                              ? l.requestExpired
                              : l.requestTimeLeft(formatCountdown(remaining)),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: expired || urgent
                                ? cs.error
                                : cs.onSurfaceVariant,
                            fontWeight:
                                expired || urgent ? FontWeight.w600 : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // IP on its own line so long IPv6 addresses aren't squeezed, plus
          // the trust status in words (A7) — the frame colour alone is not
          // accessible.
          Semantics(
            identifier: 'text_request_ip',
            container: true,
            child: LayoutBuilder(
              builder: (context, box) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.public, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      request.requestIpAddress,
                      style: secondary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (ipTrust != null) ...[
                    const SizedBox(width: 8),
                    // At most half the row, wrapping under large text.
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                      child: _TrustStatus(trusted: ipTrust),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Fingerprint phrase (look unchanged; now the SDK algorithm, F3).
          if (fingerprint != null) ...[
            Text(
              l.fingerprintLabel,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            FingerprintPhrase(phrase: fingerprint),
            const SizedBox(height: 16),
          ] else ...[
            Semantics(
              identifier: 'text_fingerprint_unavailable',
              child: _Notice(
                icon: Icons.gpp_bad_outlined,
                text: l.fingerprintUnavailable,
                color: cs.error,
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (expired) ...[
            _Notice(
              icon: Icons.timer_off_outlined,
              text: l.requestExpiredHint,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
          ],
          // Deny + Approve: side by side at the end of the card, or stacked
          // full width when large text leaves no room for both (no
          // overflow at 2x on a 320-pt phone). Approve is the only accent.
          _DecisionButtons(
            children: [
              Semantics(
                identifier: 'btn_deny',
                child: Pressable(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      // Neutral: the decision's accent belongs to Approve.
                      foregroundColor: cs.onSurface,
                    ),
                    onPressed: widget.isLoading ? null : widget.onDeny,
                    child: Text(l.deny, textAlign: TextAlign.center),
                  ),
                ),
              ),
              Semantics(
                identifier: 'btn_approve',
                child: Pressable(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                    ),
                    onPressed: canApprove ? widget.onApprove : null,
                    child: widget.isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l.approve, textAlign: TextAlign.center),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Known IP" / "Denied IP" next to the address (A7).
class _TrustStatus extends StatelessWidget {
  const _TrustStatus({required this.trusted});

  final bool trusted;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final color = trusted ? kTrustGreen : theme.colorScheme.error;
    return Semantics(
      identifier: 'text_ip_trust',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            trusted ? Icons.verified_outlined : Icons.block,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              trusted ? l.ipTrusted : l.ipDenied,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.10),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The decision buttons (Deny, Approve). Side by side at the end of the
/// card when both fit at their natural width; otherwise — large text on a
/// narrow phone — stacked, each the full width of the card, in the same
/// order, so the reading and focus order never change. Mirrors in RTL. The
/// buttons keep their own 48-pt minimum size in both layouts.
class _DecisionButtons extends MultiChildRenderObjectWidget {
  const _DecisionButtons({required super.children});

  @override
  RenderDecisionButtons createRenderObject(BuildContext context) =>
      RenderDecisionButtons(textDirection: Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    RenderDecisionButtons renderObject,
  ) =>
      renderObject.textDirection = Directionality.of(context);
}

class _DecisionButtonsParentData extends ContainerBoxParentData<RenderBox> {}

/// Render object of the card's decision buttons (public for tests: its
/// [stacked] says which layout was used).
class RenderDecisionButtons extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DecisionButtonsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DecisionButtonsParentData> {
  RenderDecisionButtons({required TextDirection textDirection})
      : _textDirection = textDirection;

  /// Gap between the buttons in a row, and between stacked buttons.
  static const double spacing = 12;
  static const double runSpacing = 8;

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Whether the last layout stacked the buttons.
  bool get stacked => _stacked;
  bool _stacked = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DecisionButtonsParentData) {
      child.parentData = _DecisionButtonsParentData();
    }
  }

  List<RenderBox> get _buttons {
    final list = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      list.add(child);
      child = childAfter(child);
    }
    return list;
  }

  /// Width of the buttons side by side at their natural widths.
  double get _rowWidth {
    final buttons = _buttons;
    if (buttons.isEmpty) return 0;
    var width = spacing * (buttons.length - 1);
    for (final b in buttons) {
      width += b.getMaxIntrinsicWidth(double.infinity);
    }
    return width;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    var width = 0.0;
    for (final b in _buttons) {
      width = math.max(width, b.getMinIntrinsicWidth(double.infinity));
    }
    return width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _rowWidth;

  double _intrinsicHeight(double width, double Function(RenderBox) of) {
    final buttons = _buttons;
    if (buttons.isEmpty) return 0;
    if (_rowWidth <= width) return buttons.map(of).reduce(math.max);
    return buttons.map(of).reduce((a, b) => a + b) +
        runSpacing * (buttons.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (b) => b.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (b) => b.getMaxIntrinsicHeight(width));

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final buttons = _buttons;
    if (buttons.isEmpty) return constraints.smallest;
    Size lay(RenderBox b, BoxConstraints c) {
      if (dry) return b.getDryLayout(c);
      b.layout(c, parentUsesSize: true);
      return b.size;
    }

    void place(RenderBox b, Offset offset) {
      if (!dry) (b.parentData! as _DecisionButtonsParentData).offset = offset;
    }

    final maxWidth = constraints.maxWidth;
    final rowWidth = _rowWidth;
    final rtl = _textDirection == TextDirection.rtl;
    if (rowWidth <= maxWidth) {
      if (!dry) _stacked = false;
      final loose = BoxConstraints(maxWidth: maxWidth);
      final sizes = [for (final b in buttons) lay(b, loose)];
      final height = sizes.map((s) => s.height).reduce(math.max);
      final width = constraints.hasBoundedWidth ? maxWidth : rowWidth;
      // At the end of the line: right in LTR, left in RTL.
      var x = width - rowWidth;
      for (var i = 0; i < buttons.length; i++) {
        final s = sizes[i];
        final left = rtl ? width - x - s.width : x;
        place(buttons[i], Offset(left, (height - s.height) / 2));
        x += s.width + spacing;
      }
      return constraints.constrain(Size(width, height));
    }

    if (!dry) _stacked = true;
    final full = BoxConstraints.tightFor(width: maxWidth);
    var y = 0.0;
    for (final b in buttons) {
      final s = lay(b, full);
      place(b, Offset(0, y));
      y += s.height + runSpacing;
    }
    return constraints.constrain(Size(maxWidth, y - runSpacing));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
