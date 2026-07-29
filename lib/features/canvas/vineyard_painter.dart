import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/geometry/shapes.dart';
import '../../core/geometry/spatial_index.dart';
import 'viewport.dart';

/// One drawn instance, reduced to what painting and hit-testing need.
typedef DrawnObject = ({
  String id,
  String fieldDefId,
  String label,
  Shape shape,
  bool isContainer,
});

/// Everything the painter needs, assembled once per change rather than looked
/// up per frame.
///
/// Immutable and compared by identity in [VineyardPainter.shouldRepaint]: the
/// providers rebuild this only when something actually changed, so identity is
/// both correct and free. A deep comparison of 3,000 plants every frame would
/// cost more than the painting.
@immutable
class VineyardScene {
  const VineyardScene({
    required this.plants,
    required this.index,
    required this.objects,
    this.image,
    this.imageTransform = Matrix4.identity,
    this.selection = const <String>{},
    this.colors = const <String, Color>{},
    this.labels = const <String, String>{},
    this.showLabels = false,
    this.marquee,
    this.lasso = const <Offset>[],
  });

  /// Positions by id. The index holds the same points for spatial queries.
  final Map<String, Offset> plants;
  final SpatialIndex index;

  /// Everything drawn: rows, blocks, roads, posts. Painted per object because
  /// there are tens of them, not thousands.
  final List<DrawnObject> objects;

  /// The box being dragged out, in layout coordinates, or null.
  final Rect? marquee;

  /// The lasso being drawn, in layout coordinates.
  final List<Offset> lasso;

  final ui.Image? image;

  /// Placement of the image beneath the layout, as a factory so the default
  /// can stay const.
  final Matrix4 Function() imageTransform;

  final Set<String> selection;

  /// Per-plant colour from colour-by-field. Absent means use the default.
  final Map<String, Color> colors;

  final Map<String, String> labels;
  final bool showLabels;
}

/// Draws the vineyard.
///
/// One painter for the whole layout. A widget per plant would mean 3,000
/// RenderObjects laid out and composited every frame, which the plan rules out
/// explicitly and which the Fire Max 11 would not survive.
class VineyardPainter extends CustomPainter {
  VineyardPainter({required this.scene, required this.viewport});

  final VineyardScene scene;
  final CanvasViewport viewport;

  /// Below this scale, individual markers stop being distinguishable and rows
  /// carry the information instead. Also where per-plant painting would start
  /// costing more than it conveys.
  static const _markerVisibleScale = 0.25;

  /// Labels need room to be legible; drawing them sooner produces overlapping
  /// mush and a large text-layout bill.
  static const _labelVisibleScale = 1.2;

  static final _selectionPaint = Paint()
    ..color = const Color(0xFF5B2C6F)
    ..strokeWidth = 2
    ..style = PaintingStyle.stroke;

  static const _defaultPlantColor = Color(0xFF4CAF50);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(viewport.translation.dx, viewport.translation.dy);
    canvas.scale(viewport.scale);

    _paintImage(canvas);
    _paintObjects(canvas);
    _paintPlants(canvas);
    _paintSelectionGesture(canvas);

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

  /// Palette for object fields, keyed by the order they were created.
  ///
  /// Colour per *field*, not per instance, so every Row looks like a Row and
  /// Blocks are distinguishable from them at a glance. Derived from sort order
  /// rather than stored, which keeps a colour column out of the schema for
  /// something the user has not asked to control.
  static const _objectPalette = [
    Color(0xFF546E7A), // slate -- rows
    Color(0xFF6A1B9A), // purple -- blocks
    Color(0xFF00838F), // teal
    Color(0xFFEF6C00), // orange
    Color(0xFF33691E), // olive
  ];

  Color _objectColour(DrawnObject object) {
    // Hashing the field id gives a stable colour without needing sort order
    // threaded through the scene. Stable across restarts, which matters more
    // than the particular hue.
    return _objectPalette[object.fieldDefId.hashCode.abs() %
        _objectPalette.length];
  }

  void _paintObjects(Canvas canvas) {
    if (scene.objects.isEmpty) return;

    final visible = viewport.visibleLayoutRect(padding: 50);
    // Stroke width is in layout units, so it has to shrink as we zoom in or the
    // lines become thick slabs.
    final width = 1.5 / viewport.scale;

    for (final object in scene.objects) {
      if (!object.shape.bounds.inflate(10).overlaps(visible)) continue;

      final colour = _objectColour(object);
      final stroke = Paint()
        ..color = colour.withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = width;

      switch (object.shape) {
        case final PolylineShape line:
          canvas.drawPath(_pathOf(line.path.points, close: false), stroke);

        case final PolygonShape polygon:
          final path = _pathOf(polygon.vertices, close: true);
          // Faint fill so the area reads as an area without hiding the aerial
          // underneath it -- the photo is what the user is drawing against.
          canvas.drawPath(
            path,
            Paint()..color = colour.withValues(alpha: 0.10),
          );
          canvas.drawPath(path, stroke);

        case final PointShape point:
          // A diamond, deliberately unlike a plant's round dot: a post and a
          // plant must not be confusable at a glance.
          final r = (6 / viewport.scale).clamp(0.5, 40.0);
          canvas.drawPath(
            Path()
              ..moveTo(point.at.dx, point.at.dy - r)
              ..lineTo(point.at.dx + r, point.at.dy)
              ..lineTo(point.at.dx, point.at.dy + r)
              ..lineTo(point.at.dx - r, point.at.dy)
              ..close(),
            Paint()..color = colour,
          );
      }
    }
  }

  Path _pathOf(List<Offset> points, {required bool close}) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    if (close) path.close();
    return path;
  }

  /// The marquee or lasso in progress.
  ///
  /// Drawn last, over everything: it is transient feedback about a gesture, not
  /// part of the vineyard.
  void _paintSelectionGesture(Canvas canvas) {
    final width = 1.5 / viewport.scale;
    final paint = Paint()
      ..color = _selectionPaint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    final marquee = scene.marquee;
    if (marquee != null) {
      canvas.drawRect(
        marquee,
        Paint()..color = _selectionPaint.color.withValues(alpha: 0.12),
      );
      canvas.drawRect(marquee, paint);
    }

    if (scene.lasso.length >= 2) {
      canvas.drawPath(_pathOf(scene.lasso, close: false), paint);
    }
  }

  void _paintPlants(Canvas canvas) {
    if (scene.plants.isEmpty) return;
    if (viewport.scale < _markerVisibleScale) return;

    // The culling that makes the whole thing viable: query the index for what
    // is on screen instead of walking 3,000 plants and rejecting most of them.
    final visible = viewport.visibleLayoutRect(padding: 20);
    final onScreen = scene.index.inRect(visible);

    // Constant on-screen size, so markers do not balloon as you zoom in.
    final radius = (5 / viewport.scale).clamp(0.5, 40.0);
    final selectionWidth = 2 / viewport.scale;
    final drawLabels = scene.showLabels && viewport.scale >= _labelVisibleScale;

    // Grouped by colour and drawn with one call per colour.
    //
    // 4,000 individual drawCircle calls measured 17.1ms of raster on the Fire
    // Max 11 -- over the whole 16.7ms frame budget by itself, at 42fps with
    // 100% janky frames. Nearly all of that is per-call overhead rather than
    // pixels: the same dots as a handful of batched drawPoints calls cost a
    // fraction of it. Round stroke caps make each point render as a dot of
    // diameter strokeWidth.
    final byColour = <Color, List<Offset>>{};
    for (final point in onScreen) {
      (byColour[scene.colors[point.id] ?? _defaultPlantColor] ??= <Offset>[])
          .add(point.position);
    }

    for (final entry in byColour.entries) {
      canvas.drawPoints(
        ui.PointMode.points,
        entry.value,
        Paint()
          ..color = entry.key
          ..strokeWidth = radius * 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Selection and labels stay per-plant: both are bounded by what a person
    // can select or read, not by the size of the vineyard.
    if (scene.selection.isNotEmpty || drawLabels) {
      for (final point in onScreen) {
        if (scene.selection.contains(point.id)) {
          canvas.drawCircle(
            point.position,
            radius * 1.8,
            _selectionPaint..strokeWidth = selectionWidth,
          );
        }
        if (drawLabels) _paintLabel(canvas, point, radius);
      }
    }
  }

  void _paintLabel(Canvas canvas, IndexedPoint point, double radius) {
    final text = scene.labels[point.id];
    if (text == null) return;

    // Laid out per label per frame. Only runs when zoomed past the label
    // threshold, where few plants are on screen -- at 3,000 visible this would
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
