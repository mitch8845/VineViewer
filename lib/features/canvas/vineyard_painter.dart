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
    this.imageOpacity = 1,
    this.selection = const <String>{},
    this.colors = const <String, Color>{},
    this.fallbackColor,
    this.retired = const <String, Offset>{},
    this.labels = const <String, String>{},
    this.showLabels = false,
    this.fieldNames = const <String, String>{},
    this.selectedObjectId,
    this.marquee,
    this.lasso = const <Offset>[],
    this.heat,
    this.heatRect = Rect.zero,
    this.showPlants = true,
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

  /// How strongly the aerial shows. Turned down, the layout reads more clearly
  /// over a busy photo.
  final double imageOpacity;

  final Set<String> selection;

  /// Per-plant colour from colour-by-field. Absent means [fallbackColor].
  final Map<String, Color> colors;

  /// Colour for a plant missing from [colors], or null for the default green.
  /// Colour-by-field sets this to grey, so a plant with nothing recorded is
  /// visibly a gap rather than passing for a healthy one.
  final Color? fallbackColor;

  /// Retired plants -- the empty slots -- drawn as hollow rings.
  ///
  /// Not in [index]: a slot is where a plant was, not a plant, and painting it
  /// the same as a living one is what made a replant look like two plants on
  /// one spot.
  final Map<String, Offset> retired;

  final Map<String, String> labels;
  final bool showLabels;

  /// Object field names by id, for labelling areas on the map ("Block 2").
  final Map<String, String> fieldNames;

  /// The drawn object currently selected, drawn highlighted.
  final String? selectedObjectId;

  /// The heatmap, stretched over [heatRect] in layout coordinates, or null.
  final ui.Image? heat;
  final Rect heatRect;

  /// False under a heatmap: the dots would hide the very areas it shows.
  /// Selection rings still draw, so a selected plant can be found.
  final bool showPlants;
}

/// Draws the vineyard.
///
/// One painter for the whole layout. A widget per plant would mean 3,000
/// RenderObjects laid out and composited every frame, which the plan rules out
/// explicitly and which the Fire Max 11 would not survive.
///
/// Drawn like a map rather than a diagram: everything that sits on the aerial
/// has a dark casing under it, so it reads on bright gravel and dark canopy
/// alike, and text is drawn in screen space so it stays crisp at any zoom.
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

  /// Row numbers appear once rows are far enough apart on screen to fit them.
  static const _rowLabelVisibleScale = 1.1;

  /// Selection is cyan: nothing in a vineyard aerial is that colour, so it
  /// cannot be mistaken for foliage, soil, or any of the object colours.
  static const selectionColor = Color(0xFF22D3EE);

  static const _defaultPlantColor = Color(0xFF8BD450);
  static const _casing = Color(0x99000000);

  /// A plant's drawn radius, in layout units: roughly a vine's canopy at the
  /// scale of a typical aerial. Drawn at map scale rather than at a fixed
  /// screen size, so a row reads as a row of dots with the ground visible
  /// between them, not as a solid bar -- clamped so it stays tappable-looking
  /// zoomed out and does not balloon zoomed in.
  static const _plantRadius = 2.1;

  double get _screenRadius =>
      (_plantRadius * viewport.scale).clamp(2.0, 8.0).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(viewport.translation.dx, viewport.translation.dy);
    canvas.scale(viewport.scale);

    _paintImage(canvas);
    _paintObjects(canvas);
    _paintHeat(canvas);
    _paintPlants(canvas);
    _paintSelectionGesture(canvas);

    canvas.restore();

    // Text last, in screen space, so it sits above everything at a size that
    // does not depend on the zoom.
    _paintObjectLabels(canvas);
    _paintPlantLabels(canvas);
  }

  void _paintImage(Canvas canvas) {
    final image = scene.image;
    if (image == null || scene.imageOpacity <= 0) return;

    canvas.save();
    canvas.transform(scene.imageTransform().storage);
    // Nearest-neighbour would shimmer while zooming; the image is decoded once
    // so filtering costs nothing per frame.
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, scene.imageOpacity.clamp(0, 1)),
    );
    canvas.restore();
  }

  void _paintHeat(Canvas canvas) {
    final heat = scene.heat;
    if (heat == null) return;
    // Scaled up with filtering, which is what smooths a few hundred cells
    // into a continuous surface. One draw call at any zoom.
    canvas.drawImageRect(
      heat,
      Offset.zero & Size(heat.width.toDouble(), heat.height.toDouble()),
      scene.heatRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  /// Areas: warm, high-visibility colours that stand out from green and brown.
  static const _areaPalette = [
    Color(0xFFFFC94D), // gold
    Color(0xFFFF8A65), // coral
    Color(0xFFB39DDB), // lavender
    Color(0xFF4DD0E1), // aqua
  ];

  /// Lines: pale, so rows read as structure rather than competing with plants.
  static const _linePalette = [
    Color(0xFFF5F5F0), // chalk
    Color(0xFF90CAF9), // sky
    Color(0xFFFFCC80), // sand
    Color(0xFFCE93D8), // orchid
  ];

  static const _pointPalette = [
    Color(0xFFFF7043),
    Color(0xFF26C6DA),
    Color(0xFFFFEE58),
  ];

  /// Colour per *field*, not per instance, so every Row looks like a Row and
  /// Blocks are distinguishable from them at a glance. Hashing the field id
  /// keeps it stable across restarts without storing a colour.
  static Color colourOf(DrawnObject object) {
    final palette = switch (object.shape) {
      PolygonShape() => _areaPalette,
      PolylineShape() => _linePalette,
      PointShape() => _pointPalette,
    };
    return palette[object.fieldDefId.hashCode.abs() % palette.length];
  }

  void _paintObjects(Canvas canvas) {
    if (scene.objects.isEmpty) return;

    final visible = viewport.visibleLayoutRect(padding: 50);
    final px = 1 / viewport.scale; // one screen pixel, in layout units

    // A handful of Paints for the whole pass, recoloured per object rather
    // than reallocated. Skia copies a Paint's state at draw time, so mutating
    // and reusing one within a pass is safe -- and allocating per object per
    // frame is pure waste at 60fps.
    final casing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _casing;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint();

    // Areas under lines under points, so a block never paints over its rows.
    final ordered = [
      for (final o in scene.objects)
        if (o.shape is PolygonShape) o,
      for (final o in scene.objects)
        if (o.shape is PolylineShape) o,
      for (final o in scene.objects)
        if (o.shape is PointShape) o,
    ];

    for (final object in ordered) {
      if (!object.shape.bounds.inflate(10).overlaps(visible)) continue;

      final colour = colourOf(object);
      final selected = object.id == scene.selectedObjectId;

      switch (object.shape) {
        case final PolylineShape line:
          final path = _pathOf(line.path.points, close: false);
          if (selected) _halo(canvas, path, px);
          canvas.drawPath(path, casing..strokeWidth = 3.2 * px);
          canvas.drawPath(
            path,
            stroke
              ..strokeWidth = 1.4 * px
              ..color = colour.withValues(alpha: 0.85),
          );

        case final PolygonShape polygon:
          final path = _pathOf(polygon.vertices, close: true);
          // Faint fill so the area reads as an area without hiding the aerial
          // underneath it -- the photo is what the user is drawing against.
          canvas.drawPath(
            path,
            fill..color = colour.withValues(alpha: selected ? 0.16 : 0.07),
          );
          if (selected) _halo(canvas, path, px);
          canvas.drawPath(path, casing..strokeWidth = 4.5 * px);
          canvas.drawPath(
            path,
            stroke
              ..strokeWidth = 2.2 * px
              ..color = colour,
          );

        case final PointShape point:
          // A diamond, deliberately unlike a plant's round dot: a post and a
          // plant must not be confusable at a glance.
          final r = 7 * px;
          final diamond = Path()
            ..moveTo(point.at.dx, point.at.dy - r)
            ..lineTo(point.at.dx + r, point.at.dy)
            ..lineTo(point.at.dx, point.at.dy + r)
            ..lineTo(point.at.dx - r, point.at.dy)
            ..close();
          if (selected) _halo(canvas, diamond, px);
          canvas.drawPath(diamond, fill..color = colour);
          canvas.drawPath(diamond, casing..strokeWidth = 1.5 * px);
      }
    }
  }

  /// The selected object's highlight: a wide translucent band in the
  /// selection colour, under the object's own strokes.
  void _halo(Canvas canvas, Path path, double px) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 10 * px
        ..color = selectionColor.withValues(alpha: 0.55),
    );
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
    final px = 1 / viewport.scale;
    final paint = Paint()
      ..color = selectionColor
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2 * px;

    final marquee = scene.marquee;
    if (marquee != null) {
      canvas.drawRect(
        marquee,
        Paint()..color = selectionColor.withValues(alpha: 0.14),
      );
      canvas.drawRect(marquee, paint);
    }

    if (scene.lasso.length >= 2) {
      canvas.drawPath(
        _pathOf(scene.lasso, close: false),
        Paint()
          ..color = selectionColor.withValues(alpha: 0.14)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(_pathOf(scene.lasso, close: false), paint);
    }
  }

  void _paintPlants(Canvas canvas) {
    if (viewport.scale < _markerVisibleScale) return;
    if (scene.showPlants) _paintRetired(canvas);
    if (scene.plants.isEmpty) return;

    // The culling that makes the whole thing viable: query the index for what
    // is on screen instead of walking 3,000 plants and rejecting most of them.
    final visible = viewport.visibleLayoutRect(padding: 20);
    final onScreen = scene.index.inRect(visible);
    if (onScreen.isEmpty) return;

    final px = 1 / viewport.scale;
    final radius = _screenRadius * px;

    // Grouped by colour and drawn with one call per colour.
    //
    // 4,000 individual drawCircle calls measured 17.1ms of raster on the Fire
    // Max 11 -- over the whole 16.7ms frame budget by itself, at 42fps with
    // 100% janky frames. Nearly all of that is per-call overhead rather than
    // pixels: the same dots as a handful of batched drawPoints calls cost a
    // fraction of it. Round stroke caps make each point render as a dot of
    // diameter strokeWidth.
    final fallback = scene.fallbackColor ?? _defaultPlantColor;
    if (scene.showPlants) _paintDots(canvas, onScreen, fallback, radius, px);

    // Selection stays per-plant: it is bounded by what a person can select,
    // not by the size of the vineyard.
    if (scene.selection.isNotEmpty) {
      final outer = Paint()
        ..color = const Color(0xCC000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * px;
      final ring = Paint()
        ..color = selectionColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * px;
      final ringRadius = radius + 3.5 * px;
      for (final point in onScreen) {
        if (!scene.selection.contains(point.id)) continue;
        canvas.drawCircle(point.position, ringRadius, outer);
        canvas.drawCircle(point.position, ringRadius, ring);
      }
    }
  }

  void _paintDots(
    Canvas canvas,
    List<IndexedPoint> onScreen,
    Color fallback,
    double radius,
    double px,
  ) {
    final all = <Offset>[];
    final byColour = <Color, List<Offset>>{};
    for (final point in onScreen) {
      all.add(point.position);
      (byColour[scene.colors[point.id] ?? fallback] ??= <Offset>[]).add(
        point.position,
      );
    }

    // One dark disc under every plant -- the casing that makes a green dot
    // visible on green grass. One extra call, not one per plant.
    canvas.drawPoints(
      ui.PointMode.points,
      all,
      Paint()
        ..color = const Color(0xB3000000)
        ..strokeWidth = (radius + px) * 2
        ..strokeCap = StrokeCap.round,
    );

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
  }

  /// Empty slots: a thin pale ring where a plant used to be.
  ///
  /// Per-plant calls, unlike living plants, because there are few of them --
  /// a vineyard losing a tenth of its vines in a season would be a disaster
  /// long before it was a rendering problem.
  void _paintRetired(Canvas canvas) {
    if (scene.retired.isEmpty) return;
    final visible = viewport.visibleLayoutRect(padding: 20);
    final px = 1 / viewport.scale;
    final radius = _screenRadius * px;
    final casing = Paint()
      ..color = _casing
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * px;
    final ring = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 * px;
    final selected = Paint()
      ..color = selectionColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 * px;

    for (final entry in scene.retired.entries) {
      if (!visible.contains(entry.value)) continue;
      canvas.drawCircle(entry.value, radius, casing);
      canvas.drawCircle(entry.value, radius, ring);
      if (scene.selection.contains(entry.key)) {
        canvas.drawCircle(entry.value, radius + 3.5 * px, selected);
      }
    }
  }

  // ------------------------------------------------------------------ text

  /// Laid-out labels, reused across frames.
  ///
  /// Text is drawn in screen space at a fixed size, so a label's layout does
  /// not change as you pan and zoom. The old painter laid every visible label
  /// out again every frame at a zoom-dependent size -- the most expensive
  /// thing it did when IDs were on.
  static final _textCache = <String, TextPainter>{};
  static const _textCacheLimit = 600;

  static TextPainter _text(
    String text, {
    required bool bold,
    double size = 11,
  }) {
    final key = '$bold|$size|$text';
    final hit = _textCache.remove(key);
    if (hit != null) {
      _textCache[key] = hit; // most recently used
      return hit;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          // Named rather than inherited: a painter has no theme to inherit
          // from, and Roboto is what the rest of the app is set in.
          fontFamily: 'Roboto',
          color: Colors.white,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _textCache[key] = painter;
    if (_textCache.length > _textCacheLimit) {
      _textCache.remove(_textCache.keys.first);
    }
    return painter;
  }

  /// Draws [painter] centred on [at] inside a dark rounded pill.
  void _pill(
    Canvas canvas,
    TextPainter painter,
    Offset at, {
    Color? accent,
    Alignment anchor = Alignment.center,
  }) {
    const padH = 6.0, padV = 3.0;
    final w = painter.width + padH * 2;
    final h = painter.height + padV * 2;
    final topLeft = at - Offset(w * (anchor.x + 1) / 2, h * (anchor.y + 1) / 2);
    final rect = RRect.fromRectAndRadius(
      topLeft & Size(w, h),
      Radius.circular(h / 2),
    );
    canvas.drawRRect(rect, Paint()..color = const Color(0xD91D221E));
    if (accent != null) {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    painter.paint(canvas, topLeft + const Offset(padH, padV));
  }

  /// Area names at their centres, and row numbers at their starts.
  void _paintObjectLabels(Canvas canvas) {
    if (scene.objects.isEmpty) return;
    final screen = viewport.size;

    for (final object in scene.objects) {
      if (object.label.isEmpty) continue;
      final bounds = object.shape.bounds;
      final topLeft = viewport.toScreen(bounds.topLeft);
      final bottomRight = viewport.toScreen(bounds.bottomRight);
      final onScreen = Rect.fromPoints(topLeft, bottomRight);
      if (!onScreen.inflate(40).overlaps(screen)) continue;

      final selected = object.id == scene.selectedObjectId;
      final accent = selected ? selectionColor : colourOf(object);
      switch (object.shape) {
        case PolygonShape():
          // Only once the area is big enough on screen for its name not to
          // cover it.
          if (onScreen.width < 90 || onScreen.height < 50) continue;
          final name = scene.fieldNames[object.fieldDefId];
          _pill(
            canvas,
            _text(
              name == null ? object.label : '$name ${object.label}',
              bold: true,
              size: 13,
            ),
            _visibleCentre(onScreen, screen),
            accent: accent,
          );

        case final PolylineShape line:
          if (viewport.scale < _rowLabelVisibleScale && !selected) continue;
          final points = line.path.points;
          final start = viewport.toScreen(points.first);
          final next = viewport.toScreen(points[1]);
          // Just past the start, pushed back along the line so it sits
          // beyond the first plant rather than on top of it.
          final dir = next - start;
          final unit = dir.distance == 0 ? Offset.zero : dir / dir.distance;
          _pill(
            canvas,
            _text(object.label, bold: true, size: 10),
            start - unit * 16,
            accent: selected ? selectionColor : null,
          );

        case final PointShape point:
          if (viewport.scale < _rowLabelVisibleScale && !selected) continue;
          _pill(
            canvas,
            _text(object.label, bold: false, size: 10),
            viewport.toScreen(point.at) + const Offset(0, -12),
            anchor: Alignment.bottomCenter,
          );
      }
    }
  }

  /// The centre of [rect], pulled inside [screen] so a label for an area that
  /// runs off the edge stays visible.
  Offset _visibleCentre(Rect rect, Rect screen) {
    final clipped = rect.intersect(screen.deflate(24));
    if (clipped.isEmpty) return rect.center;
    return clipped.center;
  }

  void _paintPlantLabels(Canvas canvas) {
    if (!scene.showLabels || viewport.scale < _labelVisibleScale) return;
    final visible = viewport.visibleLayoutRect(padding: 20);
    final offset = Offset(_screenRadius + 3, 0);

    for (final point in scene.index.inRect(visible)) {
      final text = scene.labels[point.id];
      if (text == null) continue;
      final painter = _text(text, bold: false, size: 10);
      final at = viewport.toScreen(point.position) + offset;
      final rect = Rect.fromLTWH(
        at.dx - 2,
        at.dy - painter.height / 2 - 1,
        painter.width + 4,
        painter.height + 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = const Color(0xB31D221E),
      );
      painter.paint(canvas, Offset(at.dx, at.dy - painter.height / 2));
    }
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
