import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import 'ink_controller.dart';

/// Pen and highlighter widths as a fraction of the page width.
const _penWidth = 0.0032;
const _markerWidth = 0.024;
const _eraserRadius = 14.0;

/// Draws a PDF page's ink and, when [interactive], turns S Pen (and, in pen
/// mode, finger) input into strokes. Must be sized exactly to the page.
class InkLayer extends StatefulWidget {
  const InkLayer({
    super.key,
    required this.page,
    required this.controller,
    required this.night,
    this.interactive = true,
  });

  final int page;
  final InkController controller;
  final bool night;
  final bool interactive;

  @override
  State<InkLayer> createState() => _InkLayerState();
}

class _InkLayerState extends State<InkLayer> {
  /// The stroke being drawn right now (pixels), or null.
  final _live = ValueNotifier<List<Offset>?>(null);
  bool _erasing = false;
  Size _size = Size.zero;

  InkController get _c => widget.controller;

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  bool _isEraser(PointerEvent e) =>
      _c.tool == DrawTool.eraser ||
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.buttons & kSecondaryStylusButton) != 0;

  void _down(PointerEvent e) {
    if (_stylus(e)) _c.stylusSeen(down: true);
    _erasing = _isEraser(e);
    if (_erasing) {
      _c.eraseAt(widget.page, e.localPosition, _eraserRadius, _size);
    } else {
      _live.value = [e.localPosition];
    }
  }

  void _move(PointerEvent e) {
    if (_erasing || _isEraser(e)) {
      _erasing = true;
      _live.value = null;
      _c.eraseAt(widget.page, e.localPosition, _eraserRadius, _size);
      return;
    }
    final pts = _live.value;
    if (pts == null) return;
    // Skip points that barely moved: smoother lines and smaller saves.
    if ((e.localPosition - pts.last).distance < 1.5) return;
    _live.value = [...pts, e.localPosition];
  }

  void _up(PointerEvent e, {bool cancelled = false}) {
    if (_stylus(e)) _c.stylusSeen();
    final pts = _live.value;
    _live.value = null;
    if (cancelled || _erasing || pts == null || _size.isEmpty) return;
    final marker = _c.tool == DrawTool.marker;
    _c.add(
      widget.page,
      InkStroke(
        tool: marker ? InkTool.marker : InkTool.pen,
        color: (marker ? _c.markerColor : _c.penColor).toARGB32(),
        width: marker ? _markerWidth : _penWidth,
        points: [
          for (final p in pts) ...[
            (p.dx / _size.width).clamp(0.0, 1.0),
            (p.dy / _size.height).clamp(0.0, 1.0),
          ],
        ],
      ),
    );
  }

  static bool _stylus(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      final paint = Stack(fit: StackFit.expand, children: [
        RepaintBoundary(
          child: ListenableBuilder(
            listenable: _c,
            builder: (_, _) => CustomPaint(
              painter: _StrokesPainter(
                strokes: _c.strokes(widget.page),
                version: _c.version(widget.page),
                night: widget.night,
              ),
            ),
          ),
        ),
        CustomPaint(
          painter: _LivePainter(_live, _c, widget.night),
        ),
      ]);
      if (!widget.interactive) return IgnorePointer(child: paint);
      return Listener(
        // Hovering S Pen: keep the palm from turning the page.
        onPointerHover: (e) {
          if (_stylus(e)) _c.stylusSeen();
        },
        behavior: HitTestBehavior.translucent,
        child: RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            _InkRecognizer: GestureRecognizerFactoryWithHandlers<_InkRecognizer>(
              () => _InkRecognizer(acceptsTouch: () => _c.penMode),
              (r) => r
                ..acceptsTouch = (() => _c.penMode)
                ..onDown = _down
                ..onMove = _move
                ..onUp = _up,
            ),
          },
          child: paint,
        ),
      );
    });
  }
}

/// Wins the gesture arena immediately for the S Pen (and for a finger while
/// pen mode is on), so drawing never scrolls, zooms or turns the page.
/// Only one stroke at a time: a resting palm can't start a second one.
class _InkRecognizer extends OneSequenceGestureRecognizer {
  _InkRecognizer({required this.acceptsTouch});

  bool Function() acceptsTouch;
  void Function(PointerEvent)? onDown;
  void Function(PointerEvent)? onMove;
  void Function(PointerEvent, {bool cancelled})? onUp;
  int? _active;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (_active != null) return false;
    final k = event.kind;
    final ok = k == PointerDeviceKind.stylus ||
        k == PointerDeviceKind.invertedStylus ||
        (k == PointerDeviceKind.touch && acceptsTouch());
    return ok && super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _active = event.pointer;
    resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _active) return;
    if (event is PointerMoveEvent) {
      onMove?.call(event);
    } else if (event is PointerUpEvent) {
      onUp?.call(event);
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      onUp?.call(event, cancelled: true);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _active = null;

  @override
  String get debugDescription => 'ink';
}

/// Ink colour as shown: black pen would vanish on the Night page, so it
/// is drawn light grey there (stored colour is unchanged).
Color displayColor(Color c, bool night) =>
    night && c.computeLuminance() < 0.05 ? const Color(0xFFE0E0E0) : c;

void paintStroke(Canvas canvas, Size size, InkStroke s, bool night) {
  final marker = s.tool == InkTool.marker;
  final color = displayColor(Color(s.color), night);
  final paint = Paint()
    ..color = marker ? color.withValues(alpha: night ? 0.45 : 0.38) : color
    ..style = PaintingStyle.stroke
    ..strokeWidth = (s.width * size.width).clamp(1.6, 80.0)
    ..strokeCap = marker ? StrokeCap.square : StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  final n = s.length;
  if (n == 0) return;
  Offset pt(int i) =>
      Offset(s.points[i * 2] * size.width, s.points[i * 2 + 1] * size.height);
  if (n == 1) {
    canvas.drawCircle(pt(0), paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill);
    return;
  }
  canvas.drawPath(_smoothPath([for (var i = 0; i < n; i++) pt(i)]), paint);
}

/// Quadratic curves through the midpoints: smooth, but faithful to the hand.
Path _smoothPath(List<Offset> p) {
  final path = Path()..moveTo(p.first.dx, p.first.dy);
  if (p.length == 2) return path..lineTo(p[1].dx, p[1].dy);
  for (var i = 1; i < p.length - 1; i++) {
    final mid = (p[i] + p[i + 1]) / 2;
    path.quadraticBezierTo(p[i].dx, p[i].dy, mid.dx, mid.dy);
  }
  return path..lineTo(p.last.dx, p.last.dy);
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(
      {required this.strokes, required this.version, required this.night});
  final List<InkStroke> strokes;
  final int version;
  final bool night;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      paintStroke(canvas, size, s, night);
    }
  }

  @override
  bool shouldRepaint(_StrokesPainter old) =>
      old.version != version ||
      old.night != night ||
      !identical(old.strokes, strokes) ||
      old.strokes.length != strokes.length;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.live, this.c, this.night) : super(repaint: live);
  final ValueNotifier<List<Offset>?> live;
  final InkController c;
  final bool night;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = live.value;
    if (pts == null || pts.isEmpty || size.isEmpty) return;
    final marker = c.tool == DrawTool.marker;
    paintStroke(
      canvas,
      size,
      InkStroke(
        tool: marker ? InkTool.marker : InkTool.pen,
        color: (marker ? c.markerColor : c.penColor).toARGB32(),
        width: marker ? _markerWidth : _penWidth,
        points: [
          for (final p in pts) ...[p.dx / size.width, p.dy / size.height]
        ],
      ),
      night,
    );
  }

  @override
  bool shouldRepaint(_LivePainter old) => old.night != night;
}
