import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// A point with an identity, as stored in the index.
typedef IndexedPoint = ({String id, Offset position});

/// Uniform grid over the layout, for viewport culling and tap hit-testing.
///
/// A quadtree would adapt better to clustering, but plants in a vineyard are
/// close to evenly distributed by construction -- that is what a vineyard is --
/// so a uniform grid gets the same result with a fraction of the code and no
/// rebalancing. The plan calls this "cheap insurance"; the cheapness is the
/// point.
///
/// Rebuilt whenever the layout changes rather than updated in place. At 3,000
/// plants a rebuild is well under a millisecond, and an index that can drift out
/// of sync with the data would produce taps selecting the wrong plant, which is
/// maddening to diagnose.
class SpatialIndex {
  SpatialIndex._(
    this._cells,
    this._cellSize,
    this._origin,
    this.count, {
    int columns = 1,
    int rows = 1,
  }) : _lastCx = columns - 1,
       _lastCy = rows - 1;

  final Map<int, List<IndexedPoint>> _cells;
  final double _cellSize;
  final Offset _origin;

  /// The highest occupied cell coordinate on each axis; the lowest is 0.
  ///
  /// **Every query is clamped to these.** Cell size is derived from the points'
  /// spread, so one plant or a tight cluster gives a cell well under a pixel --
  /// and a viewport walked cell by cell at that size is billions of empty
  /// lookups: 18 seconds for one plant behind a large viewport, measured. No
  /// cell outside this range can hold anything, so clamping costs nothing.
  final int _lastCx;
  final int _lastCy;

  /// Number of indexed points.
  final int count;

  /// Empty index, for a project with no plants yet.
  static final empty = SpatialIndex._({}, 1, Offset.zero, 0);

  /// The smallest cell, in layout pixels.
  ///
  /// The clamp above already bounds the walk; this bounds the *grid*. Without
  /// it a cluster spread over a hair would still be cut into thousands of cells
  /// per axis for no benefit -- no tap is ever that precise.
  static const minCellSize = 1.0;

  /// Builds an index over [points].
  ///
  /// Cell size targets a handful of points per cell: small enough that a tap
  /// examines few candidates, large enough that a viewport query does not walk
  /// thousands of empty cells.
  static SpatialIndex build(List<IndexedPoint> points) {
    if (points.isEmpty) return empty;

    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in points) {
      minX = math.min(minX, p.position.dx);
      minY = math.min(minY, p.position.dy);
      maxX = math.max(maxX, p.position.dx);
      maxY = math.max(maxY, p.position.dy);
    }

    final width = math.max(maxX - minX, 1);
    final height = math.max(maxY - minY, 1);

    // Aim for roughly one cell per 4 points, so a tap tests a handful.
    final targetCells = math.max(1, points.length / 4);
    final cellSize = math.max(
      math.sqrt((width * height) / targetCells),
      minCellSize,
    );

    final origin = Offset(minX, minY);
    final cells = <int, List<IndexedPoint>>{};
    for (final p in points) {
      cells.putIfAbsent(_keyFor(p.position, origin, cellSize), () => []).add(p);
    }

    return SpatialIndex._(
      cells,
      cellSize,
      origin,
      points.length,
      columns: ((maxX - minX) / cellSize).floor() + 1,
      rows: ((maxY - minY) / cellSize).floor() + 1,
    );
  }

  static int _keyFor(Offset p, Offset origin, double cellSize) {
    final cx = ((p.dx - origin.dx) / cellSize).floor();
    final cy = ((p.dy - origin.dy) / cellSize).floor();
    return _hash(cx, cy);
  }

  /// Packs two cell coordinates into one int key.
  ///
  /// Dart ints are 64-bit on the VM but 53-bit on web; 21 bits per axis stays
  /// safe on both and covers a grid far larger than any vineyard image.
  static int _hash(int cx, int cy) => (cx & 0x1FFFFF) << 21 | (cy & 0x1FFFFF);

  /// Every point whose position falls inside [rect].
  ///
  /// The canvas calls this each frame with the visible rectangle. Painting all
  /// 3,000 plants when 40 are on screen is the difference between 60fps and a
  /// visible stutter while panning.
  List<IndexedPoint> inRect(Rect rect) {
    if (count == 0) return const [];

    final minCx = math.max(_cellOf(rect.left, _origin.dx), 0);
    final maxCx = math.min(_cellOf(rect.right, _origin.dx), _lastCx);
    final minCy = math.max(_cellOf(rect.top, _origin.dy), 0);
    final maxCy = math.min(_cellOf(rect.bottom, _origin.dy), _lastCy);

    final results = <IndexedPoint>[];
    for (var cx = minCx; cx <= maxCx; cx++) {
      for (var cy = minCy; cy <= maxCy; cy++) {
        final cell = _cells[_hash(cx, cy)];
        if (cell == null) continue;
        for (final p in cell) {
          if (rect.contains(p.position)) results.add(p);
        }
      }
    }
    return results;
  }

  /// The cell coordinate of [value] on one axis.
  ///
  /// Computed in doubles and clamped before converting, because a viewport
  /// zoomed far out divided by a one-pixel cell is a number `floor()` would
  /// happily turn into something past what an int key can pack. Anything off
  /// the grid is clamped by the caller anyway, so ±(a little past the grid) is
  /// as good as the true value.
  int _cellOf(double value, double origin) {
    final cell = ((value - origin) / _cellSize).floorToDouble();
    final limit = (math.max(_lastCx, _lastCy) + 1).toDouble();
    return cell.clamp(-1.0, limit).toInt();
  }

  /// The nearest point to [target] within [maxDistance], or null.
  ///
  /// [maxDistance] should come from the tap target size in *layout* units --
  /// the caller divides the finger-sized radius by the current zoom, so the
  /// tolerance stays constant on screen rather than growing as you zoom in.
  IndexedPoint? nearest(Offset target, {required double maxDistance}) {
    if (count == 0) return null;

    // Search outward a ring of cells at a time. Stopping as soon as a hit is
    // found inside the searched radius avoids scanning the whole grid when the
    // tap lands on a dense area.
    final centreCx = _cellOf(target.dx, _origin.dx);
    final centreCy = _cellOf(target.dy, _origin.dy);
    // No ring wider than the distance to the grid's far corner can reach
    // anything new, however generous [maxDistance] is. Uncapped, a tight
    // cluster's sub-pixel cells made a 1,000px search tens of thousands of
    // rings wide.
    final toFarEdge = [
      centreCx,
      _lastCx - centreCx,
      centreCy,
      _lastCy - centreCy,
    ].reduce(math.max);
    final maxRings = math.min(
      math.max(1, (maxDistance / _cellSize).ceil()),
      math.max(1, toFarEdge),
    );

    IndexedPoint? best;
    var bestDistance = maxDistance;

    for (var ring = 0; ring <= maxRings; ring++) {
      // Clamped to the grid for the same reason as [inRect]: the shell of a
      // ring centred outside the grid is mostly cells that cannot exist.
      final loCx = math.max(centreCx - ring, 0);
      final hiCx = math.min(centreCx + ring, _lastCx);
      final loCy = math.max(centreCy - ring, 0);
      final hiCy = math.min(centreCy + ring, _lastCy);
      for (var cx = loCx; cx <= hiCx; cx++) {
        for (var cy = loCy; cy <= hiCy; cy++) {
          // Only the outer shell is new on each ring.
          final onShell =
              (cx - centreCx).abs() == ring || (cy - centreCy).abs() == ring;
          if (ring > 0 && !onShell) continue;

          final cell = _cells[_hash(cx, cy)];
          if (cell == null) continue;
          for (final p in cell) {
            final d = (p.position - target).distance;
            if (d <= bestDistance) {
              bestDistance = d;
              best = p;
            }
          }
        }
      }
      // A hit inside the rings already searched cannot be beaten by a further
      // ring, since anything out there is at least ring*cellSize away.
      if (best != null && bestDistance <= ring * _cellSize) break;
    }

    return best;
  }
}
