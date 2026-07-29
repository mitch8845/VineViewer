import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Geometry for the generic object model.
///
/// These predicates decide two things a user notices immediately: whether a
/// plant is inside a block, and whether the app lets them draw two blocks on
/// top of each other. Both are pure functions and are tested without a
/// database, which is the whole reason they live in their own file.
void main() {
  final square = [
    const Offset(0, 0),
    const Offset(100, 0),
    const Offset(100, 100),
    const Offset(0, 100),
  ];

  /// The shape of block 1: a rectangle with a bite taken out of the left side,
  /// which is what the rock outcrop does to rows 11-18 in the real vineyard.
  final notched = [
    const Offset(0, 0),
    const Offset(100, 0),
    const Offset(100, 100),
    const Offset(0, 100),
    const Offset(0, 70),
    const Offset(60, 70),
    const Offset(60, 30),
    const Offset(0, 30),
  ];

  group('Shape parsing', () {
    test('each draw type round-trips through JSON', () {
      final shapes = <Shape>[
        const PointShape(Offset(12, 34)),
        PolylineShape(Polyline([const Offset(0, 0), const Offset(10, 10)])),
        PolygonShape(square),
      ];

      for (final shape in shapes) {
        final restored = Shape.tryParse(shape.toJson(), shape.drawType);
        expect(restored, isNotNull, reason: '${shape.drawType} failed');
        expect(restored!.points, shape.points);
        expect(restored.drawType, shape.drawType);
      }
    });

    test('malformed input yields null rather than throwing', () {
      for (final bad in [
        null,
        '',
        '   ',
        'not json',
        '{}',
        '[]',
        '[[0]]',
        '[["a","b"]]',
        '[[0,null]]',
      ]) {
        expect(
          Shape.tryParse(bad, DrawType.polyline),
          isNull,
          reason: 'accepted $bad',
        );
      }
    });

    test('too few points for the declared type is null, not half a shape', () {
      // A polygon needs three vertices. Rendering two as a shape would be worse
      // than treating the object as undrawn.
      expect(Shape.tryParse('[[0,0],[1,1]]', DrawType.polygon), isNull);
      expect(Shape.tryParse('[[0,0]]', DrawType.polyline), isNull);
    });

    test('a polyline stores exactly what vine_rows.path stored', () {
      // v2 compatibility of the serialised form, so the format is unchanged
      // even though the table is not.
      final path = Polyline([const Offset(1, 2), const Offset(3, 4)]);
      expect(PolylineShape(path).toJson(), path.toJson());
    });

    test('bounds cover every point', () {
      expect(PolygonShape(square).bounds, Rect.fromLTRB(0, 0, 100, 100));
      expect(const PointShape(Offset(5, 5)).bounds, Rect.fromLTRB(5, 5, 5, 5));
    });
  });

  group('pointInPolygon', () {
    test('inside and outside a convex shape', () {
      expect(pointInPolygon(const Offset(50, 50), square), isTrue);
      expect(pointInPolygon(const Offset(150, 50), square), isFalse);
      expect(pointInPolygon(const Offset(-1, 50), square), isFalse);
    });

    test('a concave notch really is outside', () {
      // The case a convex-only implementation passes wrongly. (30,50) sits in
      // the bite, so it is inside the bounding box and outside the polygon.
      expect(pointInPolygon(const Offset(30, 50), notched), isFalse);
      expect(pointInPolygon(const Offset(80, 50), notched), isTrue);
      expect(pointInPolygon(const Offset(30, 10), notched), isTrue);
      expect(pointInPolygon(const Offset(30, 90), notched), isTrue);
    });

    test('a ray grazing a vertex is not counted twice', () {
      // A point level with a vertex would flip the parity twice under a naive
      // test and report inside as outside.
      final diamond = [
        const Offset(50, 0),
        const Offset(100, 50),
        const Offset(50, 100),
        const Offset(0, 50),
      ];
      expect(pointInPolygon(const Offset(50, 50), diamond), isTrue);
      // (10,50) is genuinely inside -- at y=50 the diamond spans x 0..100 --
      // so the outside case has to be a corner of the bounding box.
      expect(pointInPolygon(const Offset(10, 10), diamond), isFalse);
    });
  });

  group('segmentsProperlyCross', () {
    test('a plain crossing', () {
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 10),
          const Offset(0, 10),
          const Offset(10, 0),
        ),
        isTrue,
      );
    });

    test('parallel segments never touch', () {
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 0),
          const Offset(0, 5),
          const Offset(10, 5),
        ),
        isFalse,
      );
    });

    test('a shared endpoint is touching, not crossing', () {
      // Splitting a row produces exactly this. If it counted as an overlap the
      // split tool would produce a state the app refuses to accept.
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 10),
          const Offset(10, 10),
          const Offset(20, 0),
        ),
        isFalse,
      );
    });

    test('a T-junction is touching, not crossing', () {
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 0),
          const Offset(5, 0),
          const Offset(5, 10),
        ),
        isFalse,
      );
    });

    test('collinear overlap over a positive length does count', () {
      // Two rows lying along the same stretch of ground is the real mistake.
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 0),
          const Offset(5, 0),
          const Offset(15, 0),
        ),
        isTrue,
      );
    });

    test('collinear meeting at exactly one point does not', () {
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 0),
          const Offset(10, 0),
          const Offset(20, 0),
        ),
        isFalse,
      );
    });

    test('collinear and disjoint does not', () {
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(10, 0),
          const Offset(20, 0),
          const Offset(30, 0),
        ),
        isFalse,
      );
    });

    test('vertical collinear overlap is measured on the right axis', () {
      // Projecting onto x would collapse both segments to a single coordinate
      // and report every vertical pair as overlapping.
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(0, 10),
          const Offset(0, 5),
          const Offset(0, 15),
        ),
        isTrue,
      );
      expect(
        segmentsProperlyCross(
          const Offset(0, 0),
          const Offset(0, 10),
          const Offset(0, 20),
          const Offset(0, 30),
        ),
        isFalse,
      );
    });
  });

  group('polygonsOverlap', () {
    test('crossing edges', () {
      final shifted = [
        const Offset(50, 50),
        const Offset(150, 50),
        const Offset(150, 150),
        const Offset(50, 150),
      ];
      expect(polygonsOverlap(square, shifted), isTrue);
    });

    test('one fully inside the other, with no edge crossing at all', () {
      // The case edge-intersection alone misses, and the exact mistake a user
      // makes by drawing a sub-block inside a block.
      final inner = [
        const Offset(20, 20),
        const Offset(40, 20),
        const Offset(40, 40),
        const Offset(20, 40),
      ];
      expect(polygonsOverlap(square, inner), isTrue);
      expect(polygonsOverlap(inner, square), isTrue);
    });

    test('separate polygons do not overlap', () {
      final far = [
        const Offset(200, 200),
        const Offset(300, 200),
        const Offset(300, 300),
        const Offset(200, 300),
      ];
      expect(polygonsOverlap(square, far), isFalse);
    });

    test('two blocks abutting along a shared edge are allowed', () {
      // The normal case in a vineyard: block 1 ends where block 2 begins.
      // Refusing this would make it impossible to draw adjacent blocks, which
      // is a far worse failure than the ambiguity it would prevent -- a plant
      // exactly on a shared boundary.
      final adjacent = [
        const Offset(100, 0),
        const Offset(200, 0),
        const Offset(200, 100),
        const Offset(100, 100),
      ];
      expect(polygonsOverlap(square, adjacent), isFalse);
    });

    test('identical polygons overlap', () {
      expect(polygonsOverlap(square, [...square]), isTrue);
    });

    test('a shared corner alone is allowed', () {
      final diagonal = [
        const Offset(100, 100),
        const Offset(200, 100),
        const Offset(200, 200),
        const Offset(100, 200),
      ];
      expect(polygonsOverlap(square, diagonal), isFalse);
    });
  });

  group('findOverlap', () {
    ShapeRef line(String id, Offset a, Offset b) =>
        (id: id, label: id, shape: PolylineShape(Polyline([a, b])));

    test('two rows crossing in an X are refused', () {
      final candidate = PolylineShape(
        Polyline([const Offset(0, 0), const Offset(100, 100)]),
      );
      final hit = findOverlap(candidate, [
        line('r1', const Offset(0, 100), const Offset(100, 0)),
      ]);
      expect(hit?.objectId, 'r1');
    });

    test('two rows that get close but never touch are fine', () {
      final candidate = PolylineShape(
        Polyline([const Offset(0, 0), const Offset(100, 0)]),
      );
      expect(
        findOverlap(candidate, [
          line('r1', const Offset(0, 1), const Offset(100, 1)),
        ]),
        isNull,
      );
    });

    test('it names the object it collided with', () {
      final candidate = PolygonShape(square);
      final hit = findOverlap(candidate, [
        (id: 'b1', label: 'Block 1', shape: PolygonShape(square)),
      ]);
      expect(hit?.label, 'Block 1');
    });

    test('points are exempt in both directions', () {
      // Two posts in the same spot are redundant, not contradictory.
      const post = PointShape(Offset(5, 5));
      expect(
        findOverlap(post, [
          (id: 'p1', label: 'p1', shape: const PointShape(Offset(5, 5))),
        ]),
        isNull,
      );
      expect(
        findOverlap(PolygonShape(square), [
          (id: 'p1', label: 'p1', shape: const PointShape(Offset(50, 50))),
        ]),
        isNull,
      );
    });

    test('an empty field has nothing to collide with', () {
      expect(findOverlap(PolygonShape(square), const []), isNull);
    });

    test('it returns the first collision, not all of them', () {
      final candidate = PolygonShape(square);
      final hit = findOverlap(candidate, [
        (
          id: 'far',
          label: 'far',
          shape: PolygonShape([
            const Offset(500, 500),
            const Offset(600, 500),
            const Offset(600, 600),
          ]),
        ),
        (id: 'near', label: 'near', shape: PolygonShape(square)),
      ]);
      expect(hit?.objectId, 'near');
    });
  });

  group('withPointMoved', () {
    test('moves one polyline vertex and leaves the rest', () {
      final line = PolylineShape(
        Polyline([
          const Offset(0, 0),
          const Offset(50, 0),
          const Offset(100, 0),
        ]),
      );
      final moved = line.withPointMoved(1, const Offset(50, 40));

      expect(moved.points, [
        const Offset(0, 0),
        const Offset(50, 40),
        const Offset(100, 0),
      ]);
      expect(moved, isA<PolylineShape>());
    });

    test('keeps a polygon a polygon', () {
      final polygon = PolygonShape(square);
      final moved = polygon.withPointMoved(0, const Offset(-20, -20));

      expect(moved, isA<PolygonShape>());
      expect(moved.points.first, const Offset(-20, -20));
      expect(moved.points.length, square.length);
    });

    test('a point shape moves wholesale', () {
      final moved = const PointShape(
        Offset(5, 5),
      ).withPointMoved(0, const Offset(9, 9));
      expect(moved.points, [const Offset(9, 9)]);
    });

    test('an out-of-range index changes nothing rather than throwing', () {
      // The index comes from a hit test against a list a concurrent edit could
      // have shortened, and throwing mid-drag would take the canvas down.
      final polygon = PolygonShape(square);
      expect(polygon.withPointMoved(99, Offset.zero).points, square);
      expect(polygon.withPointMoved(-1, Offset.zero).points, square);
    });

    test('survives a JSON round trip', () {
      final moved = PolygonShape(square).withPointMoved(2, const Offset(7, 8));
      final restored = Shape.tryParse(moved.toJson(), DrawType.polygon);
      expect(restored!.points, moved.points);
    });
  });
}
