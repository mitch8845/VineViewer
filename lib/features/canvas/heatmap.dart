import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/geometry/spatial_index.dart';

/// Where plants with the chosen values are concentrated, as an area to see
/// at a glance rather than three thousand dots to read.
///
/// Each chosen plant spreads a little weight over the ground around it, out
/// to [radius]; where many are close together the weight piles up. The
/// result is measured against the same thing done for **every** plant, so
/// full strength means "every vine around here is one of these" -- a patch
/// of dead vines in a block reads hot whatever else is on the map, and a few
/// strays spread across the vineyard stay faint. Sparse is played down and
/// dense exaggerated by [toPixels], which is the point: areas, not plants.
///
/// Pure arithmetic, so it is tested without a canvas.
class HeatDensity {
  HeatDensity._({
    required this.origin,
    required this.cellSize,
    required this.width,
    required this.height,
    required this.values,
  });

  /// Layout position of the grid's top-left corner.
  final ui.Offset origin;
  final double cellSize;
  final int width;
  final int height;

  /// Row-major, 0 to 1: how concentrated the chosen plants are in each cell,
  /// against the densest planting anywhere in the vineyard.
  final Float32List values;

  /// The layout area the grid covers.
  ui.Rect get rect => origin & ui.Size(width * cellSize, height * cellSize);

  /// The longest side of the grid, in cells. Enough for a smooth picture once
  /// the image is scaled up with filtering; more only costs time.
  static const maxCells = 320;

  /// Builds the grid over [all] (every living plant) for the [hot] ones.
  static HeatDensity compute({
    required Map<String, ui.Offset> all,
    required Set<String> hot,
    required double radius,
  }) {
    var bounds = ui.Rect.zero;
    var first = true;
    for (final p in all.values) {
      bounds = first
          ? ui.Rect.fromLTWH(p.dx, p.dy, 0, 0)
          : bounds.expandToInclude(ui.Rect.fromLTWH(p.dx, p.dy, 0, 0));
      first = false;
    }
    final area = bounds.inflate(radius);
    final longest = math.max(area.width, area.height);
    final cell = math.max(radius / 4, longest / maxCells);
    final width = math.max(1, (area.width / cell).ceil());
    final height = math.max(1, (area.height / cell).ceil());

    final everyone = Float32List(width * height);
    final chosen = Float32List(width * height);
    final reach = (radius / cell).ceil();
    final r2 = radius * radius;

    for (final e in all.entries) {
      final p = e.value;
      final isHot = hot.contains(e.key);
      final cx = ((p.dx - area.left) / cell).floor();
      final cy = ((p.dy - area.top) / cell).floor();
      for (
        var y = math.max(0, cy - reach);
        y <= cy + reach && y < height;
        y++
      ) {
        final dy = area.top + (y + 0.5) * cell - p.dy;
        for (
          var x = math.max(0, cx - reach);
          x <= cx + reach && x < width;
          x++
        ) {
          final dx = area.left + (x + 0.5) * cell - p.dx;
          final d2 = dx * dx + dy * dy;
          if (d2 >= r2) continue;
          // Biweight: full at the plant, easing smoothly to nothing at the
          // radius, so there is no hard edge to read as a boundary.
          final k = 1 - d2 / r2;
          final w = k * k;
          everyone[y * width + x] += w;
          if (isHot) chosen[y * width + x] += w;
        }
      }
    }

    var densest = 0.0;
    for (final v in everyone) {
      if (v > densest) densest = v;
    }
    final values = Float32List(width * height);
    if (densest > 0) {
      for (var i = 0; i < values.length; i++) {
        values[i] = chosen[i] / densest;
      }
    }
    return HeatDensity._(
      origin: area.topLeft,
      cellSize: cell,
      width: width,
      height: height,
      values: values,
    );
  }

  /// Below this, nothing is drawn: one stray plant should not tint the
  /// ground around it.
  static const floor = 0.15;

  /// Full strength is reached a little short of 1: a patch where nearly
  /// every vine is affected is as bad as it gets. Not much shorter, or a
  /// block that is mostly affected saturates into one flat colour and the
  /// worst parts of it can no longer be told apart.
  static const saturation = 0.85;

  /// How strongly a cell shows, 0 to 1.
  static double strength(double value) {
    if (value <= floor) return 0;
    final t = ((value - floor) / (saturation - floor)).clamp(0.0, 1.0);
    // Eased in, so sparse stays faint and dense stands out.
    return t * t * (3 - 2 * t);
  }

  static const _ramp = [
    (0.0, 0xFFFFE066), // pale yellow
    (0.4, 0xFFFFA62B), // amber
    (0.75, 0xFFE8432E), // red
    (1.0, 0xFF8E0B2C), // deep crimson
  ];

  /// The colour for a strength, as ARGB.
  static int colorAt(double s) {
    for (var i = 1; i < _ramp.length; i++) {
      final (t1, c1) = _ramp[i];
      if (s <= t1) {
        final (t0, c0) = _ramp[i - 1];
        final f = (s - t0) / (t1 - t0);
        int ch(int shift) {
          final a = (c0 >> shift) & 0xFF, b = (c1 >> shift) & 0xFF;
          return (a + (b - a) * f).round() & 0xFF;
        }

        return 0xFF000000 | ch(16) << 16 | ch(8) << 8 | ch(0);
      }
    }
    return _ramp.last.$2;
  }

  /// RGBA bytes, premultiplied-free, for [ui.decodeImageFromPixels].
  Uint8List toPixels() {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < values.length; i++) {
      final s = strength(values[i]);
      if (s == 0) continue;
      final c = colorAt(s);
      out[i * 4] = (c >> 16) & 0xFF;
      out[i * 4 + 1] = (c >> 8) & 0xFF;
      out[i * 4 + 2] = c & 0xFF;
      // Faint where sparse, fading to nothing rather than stopping at an
      // edge, so the ground shows through everywhere but the hotspots.
      out[i * 4 + 3] = (255 * 0.88 * math.pow(s, 0.75)).round();
    }
    return out;
  }

  Future<ui.Image> toImage() {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      toPixels(),
      width,
      height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}

/// The usual distance from a plant to its nearest neighbour: the vine
/// spacing, whatever units the layout is drawn in. The heatmap's spread is
/// set in plants, so it means the same on any aerial.
double typicalSpacing(Map<String, ui.Offset> positions, SpatialIndex index) {
  if (positions.length < 2) return 1;
  final ids = positions.keys.toList();
  final step = math.max(1, ids.length ~/ 200);
  final found = <double>[];
  for (var i = 0; i < ids.length; i += step) {
    final p = positions[ids[i]]!;
    // Widening the search until something turns up.
    for (var w = 1.0; w < 1e5; w *= 4) {
      var best = double.infinity;
      for (final q in index.inRect(
        ui.Rect.fromCenter(center: p, width: w * 2, height: w * 2),
      )) {
        final d = (q.position - p).distance;
        if (d > 0 && d < best) best = d;
      }
      if (best <= w) {
        found.add(best);
        break;
      }
    }
  }
  if (found.isEmpty) return 1;
  found.sort();
  return found[found.length ~/ 2];
}
