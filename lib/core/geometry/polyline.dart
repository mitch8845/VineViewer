import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// A row's shape: straight segments between points, in image pixel space.
///
/// Not a spline. Plants are trained on stakes, so a row that changes direction
/// does so at a hard angle; curve fitting would add control points and
/// arc-length integration to model something the vineyard does not contain.
///
/// Arc-length prefix sums are computed once in the constructor. Placing 72
/// plants along a row would otherwise walk the segment list 72 times, and the
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
  /// Clamping rather than throwing: a plant can legitimately hold an offset
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
  /// itself. Used to snap a plant to a row and to hit-test a row tap.
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
  /// This is how numbering direction is implemented. A plant's `position_idx`
  /// follows path order -- `renumberRow` sorts by `path_offset` to decide what
  /// is plant 1 -- so "number from the other end" means storing the row
  /// reversed, not carrying a flag that every read would have to consult and
  /// one read would eventually forget.
  Polyline get reversed => Polyline(points.reversed.toList());

  /// The path cut in two at [offset].
  ///
  /// Returns null when the cut would leave a piece with fewer than two points --
  /// a cut at or past either end. That is a refusal rather than a clamp: a
  /// "split" that produced one line and one nothing would be a rename with extra
  /// steps, and the caller can say so.
  ///
  /// The two halves **share the cut point exactly**, so they touch without
  /// crossing -- which is legal by design (see `segmentsProperlyCross`).
  ({Polyline before, Polyline after})? splitAt(double offset) {
    if (!offset.isFinite || offset <= 0 || offset >= length) return null;

    final i = _segmentIndexFor(offset);
    final cut = pointAt(offset);

    // A cut landing exactly on an existing vertex must not duplicate it: the
    // stored JSON would gain a zero-length segment that survives every future
    // round trip.
    final before = <Offset>[
      ...points.sublist(0, i + 1),
      if (points[i] != cut) cut,
    ];
    final after = <Offset>[
      if (points[i + 1] != cut) cut,
      ...points.sublist(i + 1),
    ];

    if (before.length < 2 || after.length < 2) return null;
    return (before: Polyline(before), after: Polyline(after));
  }

  /// This path joined to [other] at whichever pair of ends is closest.
  ///
  /// Merging two lines drawn in whatever direction they happened to be drawn is
  /// four possible joins, and the user should not have to think about which.
  /// Nearest-endpoints picks the one they meant.
  ///
  /// The flags matter to the caller far more than the path does: reversing a
  /// half invalidates every arc-length offset on it, so plants have to be
  /// remapped, and only the caller knows which plants those are.
  ({Polyline path, bool firstReversed, bool secondReversed, double joinOffset})
  joinedWith(Polyline other) {
    final aStart = points.first, aEnd = points.last;
    final bStart = other.points.first, bEnd = other.points.last;

    // (reverse a?, reverse b?) for each of the four ways two lines can meet.
    final options = <({bool a, bool b, double gap})>[
      (a: false, b: false, gap: (aEnd - bStart).distance),
      (a: false, b: true, gap: (aEnd - bEnd).distance),
      (a: true, b: false, gap: (aStart - bStart).distance),
      (a: true, b: true, gap: (aStart - bEnd).distance),
    ]..sort((x, y) => x.gap.compareTo(y.gap));
    final best = options.first;

    final first = best.a ? reversed : this;
    final second = best.b ? other.reversed : other;

    // Drop the duplicate at the seam when the ends actually coincide. Where they
    // do not, the joining segment is kept deliberately: merging two lines with a
    // gap between them gives one line that spans the gap.
    final joined = <Offset>[
      ...first.points,
      ...second.points.first == first.points.last
          ? second.points.sublist(1)
          : second.points,
    ];

    return (
      path: Polyline(joined),
      firstReversed: best.a,
      secondReversed: best.b,
      joinOffset: first.length,
    );
  }

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
