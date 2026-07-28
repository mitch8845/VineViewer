import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/geometry/spatial_index.dart';

/// A grid of vines resembling the real vineyard: 75 rows, variable length,
/// 3,025 total.
List<IndexedPoint> realisticVineyard() {
  final points = <IndexedPoint>[];
  final random = math.Random(42); // fixed seed: failures must be reproducible
  var id = 0;
  for (var row = 0; row < 75; row++) {
    final vinesInRow = 9 + random.nextInt(64); // 9..72, as in the real data
    for (var i = 0; i < vinesInRow; i++) {
      points.add((
        id: 'v${id++}',
        position: Offset(100.0 + i * 12, 100.0 + row * 40),
      ));
    }
  }
  return points;
}

void main() {
  group('build', () {
    test('an empty layout is handled', () {
      final index = SpatialIndex.build([]);
      expect(index.count, 0);
      expect(index.inRect(const Rect.fromLTWH(0, 0, 100, 100)), isEmpty);
      expect(index.nearest(Offset.zero, maxDistance: 50), isNull);
    });

    test('a single point', () {
      final index = SpatialIndex.build([
        (id: 'a', position: const Offset(50, 50)),
      ]);
      expect(index.count, 1);
      expect(index.nearest(const Offset(52, 52), maxDistance: 10)?.id, 'a');
    });

    test('coincident points do not collapse', () {
      // Two vines can share a position while one is being dragged onto
      // another; the index must not lose one.
      final index = SpatialIndex.build([
        (id: 'a', position: const Offset(10, 10)),
        (id: 'b', position: const Offset(10, 10)),
      ]);
      expect(index.count, 2);
      expect(index.inRect(const Rect.fromLTWH(0, 0, 20, 20)), hasLength(2));
    });
  });

  group('inRect', () {
    late SpatialIndex index;
    setUp(() => index = SpatialIndex.build(realisticVineyard()));

    test('a small viewport returns only what is inside it', () {
      final visible = index.inRect(const Rect.fromLTWH(100, 100, 200, 100));
      expect(visible, isNotEmpty);
      for (final p in visible) {
        expect(p.position.dx, inInclusiveRange(100, 300));
        expect(p.position.dy, inInclusiveRange(100, 200));
      }
    });

    test('culling actually culls', () {
      // The whole point of the index: painting 40 vines instead of 3,000 is
      // the difference between 60fps and a stutter while panning.
      final visible = index.inRect(const Rect.fromLTWH(100, 100, 300, 200));
      expect(visible.length, lessThan(index.count ~/ 10));
    });

    test('a viewport covering everything returns everything', () {
      final all = index.inRect(const Rect.fromLTWH(-1e6, -1e6, 2e6, 2e6));
      expect(all.length, index.count);
    });

    test('a viewport outside the layout returns nothing', () {
      expect(
        index.inRect(const Rect.fromLTWH(-5000, -5000, 100, 100)),
        isEmpty,
      );
    });

    test('agrees with a brute-force scan', () {
      // The index is an optimisation; if it ever disagrees with the naive
      // answer it is worse than useless, because taps would select the wrong
      // vine and nobody would suspect the index.
      final points = realisticVineyard();
      final built = SpatialIndex.build(points);
      const rect = Rect.fromLTWH(250, 300, 400, 350);

      final fromIndex = built.inRect(rect).map((p) => p.id).toSet();
      final bruteForce = points
          .where((p) => rect.contains(p.position))
          .map((p) => p.id)
          .toSet();

      expect(fromIndex, bruteForce);
    });
  });

  group('nearest', () {
    late List<IndexedPoint> points;
    late SpatialIndex index;
    setUp(() {
      points = realisticVineyard();
      index = SpatialIndex.build(points);
    });

    test('finds the vine under a tap', () {
      final target = points[500].position;
      expect(index.nearest(target, maxDistance: 20)?.id, points[500].id);
    });

    test('respects the distance limit', () {
      // Tapping empty ground must deselect, not grab the nearest vine three
      // rows away.
      expect(index.nearest(const Offset(-500, -500), maxDistance: 20), isNull);
    });

    test('agrees with a brute-force nearest', () {
      // 60 trials rather than 200: each one brute-forces all 3,000 points, and
      // the extra 140 cost ~20s on every CI run without covering a new case.
      final random = math.Random(7);
      for (var trial = 0; trial < 60; trial++) {
        final target = Offset(
          random.nextDouble() * 1200,
          random.nextDouble() * 3200,
        );
        const maxDistance = 30.0;

        final fromIndex = index.nearest(target, maxDistance: maxDistance);

        IndexedPoint? expected;
        var bestDistance = maxDistance;
        for (final p in points) {
          final d = (p.position - target).distance;
          if (d <= bestDistance) {
            bestDistance = d;
            expected = p;
          }
        }

        if (expected == null) {
          expect(fromIndex, isNull, reason: 'target $target');
        } else {
          // Ties are possible in a regular grid, so compare distance rather
          // than identity.
          expect(fromIndex, isNotNull, reason: 'target $target');
          expect(
            (fromIndex!.position - target).distance,
            closeTo(bestDistance, 1e-9),
            reason: 'target $target',
          );
        }
      }
    });
  });

  group('scale', () {
    test('handles the full vineyard', () {
      final points = realisticVineyard();
      final index = SpatialIndex.build(points);
      expect(index.count, greaterThan(2000));

      // A representative viewport at working zoom.
      final visible = index.inRect(const Rect.fromLTWH(200, 400, 800, 600));
      expect(visible, isNotEmpty);
      expect(visible.length, lessThan(index.count));
    });
  });
}
