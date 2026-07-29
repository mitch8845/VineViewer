import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import '../models/enums.dart';
import 'polyline.dart';

/// The geometry of one drawn object, tagged by how it is drawn.
///
/// Wraps [Polyline] rather than replacing it: arc-length prefix sums,
/// `pointAt`, `closestTo` and `reversed` are what plants slide along, and none
/// of that changes because rows stopped being a table.
///
/// Every variant serialises to the same `[[x,y], ...]` JSON that
/// `vine_rows.path` used, so a polyline's stored form is byte-identical to what
/// it was before v3.
sealed class Shape {
  const Shape();

  DrawType get drawType;

  /// Every defining point, in order. A polygon's closing edge is implicit.
  List<Offset> get points;

  /// Axis-aligned bounds, for viewport culling, fit-to-layout, and the
  /// cheap pre-filter in [findOverlap].
  Rect get bounds;

  String toJson() => jsonEncode([
    for (final p in points) [p.dx, p.dy],
  ]);

  /// Parses stored JSON as [type], returning null for anything malformed.
  ///
  /// Null rather than throwing, matching [Polyline.tryParse] and for the same
  /// reason: an object with an unreadable geometry should render as undrawn and
  /// stay editable, not stop the whole project opening.
  static Shape? tryParse(String? raw, DrawType type) {
    final points = _parsePoints(raw);
    if (points == null) return null;

    return switch (type) {
      DrawType.point when points.length == 1 => PointShape(points.first),
      DrawType.polyline when points.length >= 2 => PolylineShape(
        Polyline(points),
      ),
      DrawType.polygon when points.length >= 3 => PolygonShape(points),
      // Right JSON, wrong number of points for the kind of object this is
      // meant to be. Treating it as undrawn is better than half-drawing it.
      _ => null,
    };
  }

  static List<Offset>? _parsePoints(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;

      final points = <Offset>[];
      for (final entry in decoded) {
        if (entry is! List || entry.length < 2) return null;
        final x = entry[0], y = entry[1];
        if (x is! num || y is! num) return null;
        if (!x.isFinite || !y.isFinite) return null;
        points.add(Offset(x.toDouble(), y.toDouble()));
      }
      return points;
    } on FormatException {
      return null;
    }
  }
}

/// A line. The only shape that carries plants.
final class PolylineShape extends Shape {
  const PolylineShape(this.path);

  final Polyline path;

  @override
  DrawType get drawType => DrawType.polyline;

  @override
  List<Offset> get points => path.points;

  @override
  Rect get bounds => path.bounds;
}

/// A closed area. Contains plants; never carries them.
final class PolygonShape extends Shape {
  PolygonShape(List<Offset> vertices)
    : assert(vertices.length >= 3, 'a polygon needs at least three vertices'),
      vertices = List.unmodifiable(vertices);

  /// Implicitly closed -- the last vertex joins the first, and the closing edge
  /// is never stored. Storing it would make every round trip either grow the
  /// list or have to detect and strip a duplicate.
  final List<Offset> vertices;

  @override
  DrawType get drawType => DrawType.polygon;

  @override
  List<Offset> get points => vertices;

  @override
  Rect get bounds => _boundsOf(vertices);
}

/// A single position: a post, a gate, a well.
final class PointShape extends Shape {
  const PointShape(this.at);

  final Offset at;

  @override
  DrawType get drawType => DrawType.point;

  @override
  List<Offset> get points => [at];

  @override
  Rect get bounds => Rect.fromLTRB(at.dx, at.dy, at.dx, at.dy);
}

Rect _boundsOf(List<Offset> points) {
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

// ---------------------------------------------------------------- predicates

/// Whether [p] lies inside the polygon, by even-odd ray casting.
///
/// Casts to the right and counts crossings. The `(yi > p.dy) != (yj > p.dy)`
/// test is deliberately asymmetric about the endpoints: it counts a vertex
/// exactly once rather than twice, which is what stops a ray that grazes a
/// vertex reporting the point as outside.
///
/// Points exactly on an edge are not guaranteed either way -- floating point
/// makes "on the line" unanswerable at the boundary. That is why polyline
/// containment uses a tolerance and polygons simply accept whichever side the
/// arithmetic lands on; a plant on a block boundary is genuinely ambiguous and
/// the vineyard does not care.
bool pointInPolygon(Offset p, List<Offset> vertices) {
  var inside = false;
  for (var i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
    final xi = vertices[i].dx, yi = vertices[i].dy;
    final xj = vertices[j].dx, yj = vertices[j].dy;

    if ((yi > p.dy) != (yj > p.dy) &&
        p.dx < (xj - xi) * (p.dy - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Which side of `a→b` the point `c` falls on: 1, -1, or 0 for collinear.
int _orientation(Offset a, Offset b, Offset c) {
  final v = (b.dy - a.dy) * (c.dx - b.dx) - (b.dx - a.dx) * (c.dy - b.dy);
  if (v > 0) return 1;
  if (v < 0) return -1;
  return 0;
}

/// Whether two segments cross at a point interior to both, or lie along each
/// other for a positive length.
///
/// **Merely touching does not count**, and that distinction is load-bearing in
/// both directions:
///
///  * Two adjacent blocks share a fence line. Abutting is the normal case in a
///    vineyard, and refusing it would make it impossible to draw block 1 next
///    to block 2 at all.
///  * Splitting a row produces two lines meeting at the cut. If touching were
///    an overlap, split would produce a state the app refuses to accept.
///
/// What is genuinely wrong is shared *ground*: an X crossing, or two rows lying
/// along the same stretch.
bool segmentsProperlyCross(Offset a1, Offset a2, Offset b1, Offset b2) {
  final o1 = _orientation(a1, a2, b1);
  final o2 = _orientation(a1, a2, b2);
  final o3 = _orientation(b1, b2, a1);
  final o4 = _orientation(b1, b2, a2);

  // No endpoint sits on the other segment, so any intersection is interior.
  if (o1 != 0 && o2 != 0 && o3 != 0 && o4 != 0) return o1 != o2 && o3 != o4;

  // Collinear. Sharing one endpoint is fine; sharing a stretch is not.
  if (o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0) {
    return _collinearOverlaps(a1, a2, b1, b2);
  }

  // An endpoint lies on the other segment -- a T-junction. Touching, not
  // crossing, so allowed for the same reason a shared corner is.
  return false;
}

/// Whether two collinear segments share more than a single point.
bool _collinearOverlaps(Offset a1, Offset a2, Offset b1, Offset b2) {
  // Project onto whichever axis the segments actually vary along; using x for a
  // vertical segment would collapse every point to the same coordinate.
  final horizontal = (a2.dx - a1.dx).abs() >= (a2.dy - a1.dy).abs();
  double at(Offset p) => horizontal ? p.dx : p.dy;

  final aLo = at(a1) < at(a2) ? at(a1) : at(a2);
  final aHi = at(a1) < at(a2) ? at(a2) : at(a1);
  final bLo = at(b1) < at(b2) ? at(b1) : at(b2);
  final bHi = at(b1) < at(b2) ? at(b2) : at(b1);

  final lo = aLo > bLo ? aLo : bLo;
  final hi = aHi < bHi ? aHi : bHi;
  return hi - lo > 0;
}

/// Whether two lines share ground, as opposed to merely touching.
bool polylinesCross(Polyline a, Polyline b) {
  if (!a.bounds.overlaps(b.bounds)) return false;

  for (var i = 0; i < a.points.length - 1; i++) {
    for (var j = 0; j < b.points.length - 1; j++) {
      if (segmentsProperlyCross(
        a.points[i],
        a.points[i + 1],
        b.points[j],
        b.points[j + 1],
      )) {
        return true;
      }
    }
  }
  return false;
}

/// The average of a polygon's vertices.
///
/// Not the true area centroid, which is not worth computing here: this is only
/// used as a representative interior point for the containment test below, and
/// the difference never changes the answer for the shapes a vineyard contains.
Offset _centroid(List<Offset> vertices) {
  var x = 0.0, y = 0.0;
  for (final v in vertices) {
    x += v.dx;
    y += v.dy;
  }
  return Offset(x / vertices.length, y / vertices.length);
}

/// Whether two polygons share interior ground.
///
/// Two tests, and both are needed:
///
///  * **Properly crossing edges** catches partial overlap. Using a permissive
///    intersection here instead would refuse two blocks that merely abut, which
///    is how blocks normally sit.
///  * **Containment** catches a small block drawn wholly inside a big one,
///    which has no crossing edges at all and is exactly the mistake this rule
///    exists to prevent.
///
/// Known limit: two *identical concave* polygons whose vertex average happens
/// to fall outside them both would slip through. Nothing in a vineyard is
/// shaped like that, and the consequence of being slightly permissive -- a
/// plant's container picked arbitrarily between two identical candidates -- is
/// far milder than the consequence of being too strict, which is being unable
/// to draw adjacent blocks.
bool polygonsOverlap(List<Offset> a, List<Offset> b) {
  if (!_boundsOf(a).overlaps(_boundsOf(b))) return false;

  for (var i = 0; i < a.length; i++) {
    final a1 = a[i], a2 = a[(i + 1) % a.length];
    for (var j = 0; j < b.length; j++) {
      if (segmentsProperlyCross(a1, a2, b[j], b[(j + 1) % b.length])) {
        return true;
      }
    }
  }

  return pointInPolygon(_centroid(a), b) || pointInPolygon(_centroid(b), a);
}

/// One drawn object, reduced to what an overlap check needs.
typedef ShapeRef = ({String id, String label, Shape shape});

/// The first same-type object [candidate] collides with, or null.
///
/// Callers pass only objects of the *same field*: two blocks may not overlap,
/// but a row crossing a block is the normal case and must stay legal.
///
/// **Points are exempt.** A point has no interior to be ambiguous about, so two
/// posts at the same spot are merely redundant, not contradictory.
({String objectId, String label})? findOverlap(
  Shape candidate,
  Iterable<ShapeRef> others,
) {
  if (candidate is PointShape) return null;

  for (final other in others) {
    if (other.shape is PointShape) continue;
    // Bounds first. Exact tests are cheap at 75 rows and stay cheap at ten
    // times that only because most pairs never reach them.
    if (!candidate.bounds.overlaps(other.shape.bounds)) continue;

    final collides = switch ((candidate, other.shape)) {
      (final PolylineShape a, final PolylineShape b) => polylinesCross(
        a.path,
        b.path,
      ),
      (final PolygonShape a, final PolygonShape b) => polygonsOverlap(
        a.vertices,
        b.vertices,
      ),
      // Mixed kinds cannot arise: same field means same draw type.
      _ => false,
    };

    if (collides) return (objectId: other.id, label: other.label);
  }
  return null;
}
