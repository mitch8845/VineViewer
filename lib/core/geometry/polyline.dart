import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// A row's shape: straight segments between points, in image pixel space.
///
/// Not a spline. Vines are trained on stakes, so a row that changes direction
/// does so at a hard angle; curve fitting would add control points and
/// arc-length integration to model something the vineyard does not contain.
///
/// Arc-length prefix sums are computed once in the constructor. Placing 72
/// vines along a row would otherwise walk the segment list 72 times, and the
/// canvas rebuilds these while dragging.
class Polyline {
  Polyline(List<Offset> points)
    : assert(points.length >= 2, 'a polyline needs at least two points'),
      points = List.unmodifiable(points),
      _cumulative = _prefixSums(points);

  final List<Offset> points;

  /// `_cumulative[i]` is the distance from the start to `points[i]`.
  /// Length is `points.length`, first element always 0.
  final List<double> _cumulative;

  static List<double> _prefixSums(List<Offset> points) {
    final sums = List<double>.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      sums[i] = sums[i - 1] + (points[i] - points[i - 1]).distance;
    }
    return sums;
  }

  /// Total length along the path.
  double get length => _cumulative.last;

  /// Axis-aligned bounds, for viewport culling and fitting the view.
  Rect get bounds {
    var minX = points.first.dx, maxX = points.first.dx;
    var minY = points.first.dy, maxY = points.first.dy;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// The point at [offset] along the path, clamped to the ends.
  ///
  /// Clamping rather than throwing: a vine can legitimately hold an offset
  /// beyond the current length after a row is shortened, and dropping it off
  /// the map would be worse than parking it at the end where it is visible and
  /// can be dealt with.
  Offset pointAt(double offset) {
    if (offset <= 0 || length == 0) return points.first;
    if (offset >= length) return points.last;

    final i = _segmentIndexFor(offset);
    final segmentStart = _cumulative[i];
    final segmentLength = _cumulative[i + 1] - segmentStart;
    if (segmentLength == 0) return points[i];

    final t = (offset - segmentStart) / segmentLength;
    return Offset.lerp(points[i], points[i + 1], t)!;
  }

  /// Index of the segment containing [offset], by binary search.
  int _segmentIndexFor(double offset) {
    var lo = 0, hi = _cumulative.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) ~/ 2;
      if (_cumulative[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Nearest point on the path to [target].
  ///
  /// Returns where it lies along the path, how far away it is, and the point
  /// itself. Used to snap a vine to a row and to hit-test a row tap.
  ({double offset, double distance, Offset point}) closestTo(Offset target) {
    var bestOffset = 0.0;
    var bestDistanceSq = double.infinity;
    var bestPoint = points.first;

    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final ab = b - a;
      final segmentLengthSq = ab.dx * ab.dx + ab.dy * ab.dy;

      // A repeated point makes a zero-length segment; projecting onto it
      // divides by zero.
      final t = segmentLengthSq == 0
          ? 0.0
          : (((target - a).dx * ab.dx + (target - a).dy * ab.dy) /
                    segmentLengthSq)
                .clamp(0.0, 1.0);

      final projected = a + ab * t;
      final d = target - projected;
      final distanceSq = d.dx * d.dx + d.dy * d.dy;

      if (distanceSq < bestDistanceSq) {
        bestDistanceSq = distanceSq;
        bestPoint = projected;
        bestOffset = _cumulative[i] + math.sqrt(segmentLengthSq) * t;
      }
    }

    return (
      offset: bestOffset,
      distance: math.sqrt(bestDistanceSq),
      point: bestPoint,
    );
  }

  /// The same shape walked from the other end.
  ///
  /// This is how numbering direction is implemented. A vine's `position_idx`
  /// follows path order -- `renumberRow` sorts by `path_offset` to decide what
  /// is plant 1 -- so "number from the other end" means storing the row
  /// reversed, not carrying a flag that every read would have to consult and
  /// one read would eventually forget.
  Polyline get reversed => Polyline(points.reversed.toList());

  /// JSON `[[x,y], ...]`, as stored in `vine_rows.path`.
  String toJson() => jsonEncode([
    for (final p in points) [p.dx, p.dy],
  ]);

  /// Parses stored JSON, returning null for anything malformed.
  ///
  /// Null rather than throwing: a row with an unreadable path should render as
  /// undrawn and stay editable, not make the whole project fail to open.
  static Polyline? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.length < 2) return null;

      final points = <Offset>[];
      for (final entry in decoded) {
        if (entry is! List || entry.length < 2) return null;
        final x = entry[0], y = entry[1];
        if (x is! num || y is! num) return null;
        if (!x.isFinite || !y.isFinite) return null;
        points.add(Offset(x.toDouble(), y.toDouble()));
      }
      return Polyline(points);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() =>
      'Polyline(${points.length} points, ${length.toStringAsFixed(1)}px)';
}
