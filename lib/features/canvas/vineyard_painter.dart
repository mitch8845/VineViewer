import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/geometry/polyline.dart';
import '../../core/geometry/spatial_index.dart';
import 'viewport.dart';

/// Everything the painter needs, assembled once per change rather than looked
/// up per frame.
///
/// Immutable and compared by identity in [VineyardPainter.shouldRepaint]: the
/// providers rebuild this only when something actually changed, so identity is
/// both correct and free. A deep comparison of 3,000 vines every frame would
/// cost more than the painting.
@immutable
class VineyardScene {
  const VineyardScene({
    required this.vines,
    required this.index,
    required this.rows,
    this.image,
    this.imageTransform = Matrix4.identity,
    this.selection = const <String>{},
    this.colors = const <String, Color>{},
    this.labels = const <String, String>{},
    this.showLabels = false,
  });

  /// Positions by id. The index holds the same points for spatial queries.
  final Map<String, Offset> vines;
  final SpatialIndex index;
  final List<Polyline> rows;

  final ui.Image? image;

  /// Placement of the image beneath the layout, as a factory so the default
  /// can stay const.
  final Matrix4 Function() imageTransform;

  final Set<String> selection;

  /// Per-vine colour from colour-by-field. Absent means use the default.
  final Map<String, Color> colors;

  final Map<String, String> labels;
  final bool showLabels;
}

/// Draws the vineyard.
///
/// One painter for the whole layout. A widget per vine would mean 3,000
/// RenderObjects laid out and composited every frame, which the plan rules out
/// explicitly and which the Fire Max 11 would not survive.
class VineyardPainter extends CustomPainter {
  VineyardPainter({required this.scene, required this.viewport});

  final VineyardScene scene;
  final CanvasViewport viewport;

  /// Below this scale, individual markers stop being distinguishable and rows
  /// carry the information instead. Also where per-vine painting would start
  /// costing more than it conveys.
  static const _markerVisibleScale = 0.25;

  /// Labels need room to be legible; drawing them sooner produces overlapping
  /// mush and a large text-layout bill.
  static const _labelVisibleScale = 1.2;

  static final _rowPaint = Paint()
    ..color = const Color(0x66000000)
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static final _vinePaint = Paint()..style = PaintingStyle.fill;
  static final _selectionPaint = Paint()
    ..color = const Color(0xFF5B2C6F)
    ..strokeWidth = 2
    ..style = PaintingStyle.stroke;

  static const _defaultVineColor = Color(0xFF4CAF50);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(viewport.translation.dx, viewport.translation.dy);
    canvas.scale(viewport.scale);

    _paintImage(canvas);
    _paintRows(canvas);
    _paintVines(canvas);

    canvas.restore();
  }

  void _paintImage(Canvas canvas) {
    final image = scene.image;
    if (image == null) return;

    canvas.save();
    canvas.transform(scene.imageTransform().storage);
    // Nearest-neighbour would shimmer while zooming; the image is decoded once
    // so filtering costs nothing per frame.
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  void _paintRows(Canvas canvas) {
    if (scene.rows.isEmpty) return;

    final visible = viewport.visibleLayoutRect(padding: 50);
    // Stroke width is in layout units, so it has to shrink as we zoom in or
    // the lines become thick slabs.
    final paint = Paint()
      ..color = _rowPaint.color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.5 / viewport.scale;

    for (final row in scene.rows) {
      if (!row.bounds.inflate(10).overlaps(visible)) continue;

      final path = Path()..moveTo(row.points.first.dx, row.points.first.dy);
      for (var i = 1; i < row.points.length; i++) {
        path.lineTo(row.points[i].dx, row.points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  void _paintVines(Canvas canvas) {
    if (scene.vines.isEmpty) return;
    if (viewport.scale < _markerVisibleScale) return;

    // The culling that makes the whole thing viable: query the index for what
    // is on screen instead of walking 3,000 vines and rejecting most of them.
    final visible = viewport.visibleLayoutRect(padding: 20);
    final onScreen = scene.index.inRect(visible);

    // Constant on-screen size, so markers do not balloon as you zoom in.
    final radius = (5 / viewport.scale).clamp(0.5, 40.0);
    final selectionWidth = 2 / viewport.scale;
    final drawLabels = scene.showLabels && viewport.scale >= _labelVisibleScale;

    for (final point in onScreen) {
      final colour = scene.colors[point.id] ?? _defaultVineColor;
      canvas.drawCircle(point.position, radius, _vinePaint..color = colour);

      if (scene.selection.contains(point.id)) {
        canvas.drawCircle(
          point.position,
          radius * 1.8,
          _selectionPaint..strokeWidth = selectionWidth,
        );
      }

      if (drawLabels) {
        _paintLabel(canvas, point, radius);
      }
    }
  }

  void _paintLabel(Canvas canvas, IndexedPoint point, double radius) {
    final text = scene.labels[point.id];
    if (text == null) return;

    // Laid out per label per frame. Only runs when zoomed past the label
    // threshold, where few vines are on screen -- at 3,000 visible this would
    // dominate the frame.
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xDD000000),
          fontSize: 10 / viewport.scale,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    painter.paint(
      canvas,
      point.position + Offset(radius * 1.5, -painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(VineyardPainter oldDelegate) {
    // Specific fields, never `true`. Returning true repaints on every pointer
    // move -- the single easiest way to lose the frame budget, and invisible
    // until you profile.
    return oldDelegate.scene != scene || oldDelegate.viewport != viewport;
  }

  @override
  bool shouldRebuildSemantics(VineyardPainter oldDelegate) => false;
}
