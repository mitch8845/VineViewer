/// Laying out parallel copies of a line.
///
/// The tool this feeds exists for one specific thing: block 2's 24
/// near-identical rows and block 3's 26. Everything below is about that being
/// one gesture instead of fifty, and about the copies being *independent* once
/// made.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/geometry/array_generation.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';

/// A 100px row running left to right.
Polyline get row => Polyline([const Offset(0, 0), const Offset(100, 0)]);

/// An L: right 100, then down 100 -- a row that doglegs at a stake.
Polyline get elbow => Polyline([
  const Offset(0, 0),
  const Offset(100, 0),
  const Offset(100, 100),
]);

void main() {
  group('parallel', () {
    test('the first copy is the seed itself, unmoved', () {
      // The user drew one row and asked for four. They mean four rows, not five.
      final lines = ArrayGeneration.parallel(seed: row, spacing: 20, count: 4);
      expect(lines.length, 4);
      expect(lines.first.points, row.points);
    });

    test('steps perpendicular to the line, by the spacing', () {
      final lines = ArrayGeneration.parallel(seed: row, spacing: 20, count: 3);
      // A horizontal row's perpendicular is vertical, so each copy is 20 down
      // (or up -- `flip` picks, and neither is more correct).
      expect(lines[1].points, [const Offset(0, 20), const Offset(100, 20)]);
      expect(lines[2].points, [const Offset(0, 40), const Offset(100, 40)]);
    });

    test('flip goes to the other side', () {
      final forward = ArrayGeneration.parallel(
        seed: row,
        spacing: 20,
        count: 2,
      );
      final flipped = ArrayGeneration.parallel(
        seed: row,
        spacing: 20,
        count: 2,
        flip: true,
      );
      expect(flipped[1].points.first, -forward[1].points.first);
    });

    test('copies keep their shape across a dogleg', () {
      // Offsetting each segment by its own normal would fan the copies apart and
      // change the shape. Vineyard rows are parallel; a row that doglegs is
      // copied doglegs and all.
      final lines = ArrayGeneration.parallel(
        seed: elbow,
        spacing: 10,
        count: 2,
      );
      final copy = lines[1];

      expect(copy.points.length, elbow.points.length);
      expect(copy.length, closeTo(elbow.length, 1e-9));
      // Every point displaced by the same vector. Compared component-wise
      // rather than by Offset equality: the normal is computed by division, so
      // exact equality would be testing the FPU rather than the translation.
      final delta = copy.points.first - elbow.points.first;
      for (var i = 0; i < elbow.points.length; i++) {
        final step = copy.points[i] - elbow.points[i];
        expect(step.dx, closeTo(delta.dx, 1e-9));
        expect(step.dy, closeTo(delta.dy, 1e-9));
      }
    });

    test('the offset is the spacing, measured perpendicular', () {
      final lines = ArrayGeneration.parallel(
        seed: elbow,
        spacing: 30,
        count: 2,
      );
      expect(
        (lines[1].points.first - elbow.points.first).distance,
        closeTo(30, 1e-9),
      );
    });

    test('one row is just the row', () {
      expect(
        ArrayGeneration.parallel(
          seed: row,
          spacing: 20,
          count: 1,
        ).single.points,
        row.points,
      );
    });

    test('zero or negative yields nothing', () {
      expect(
        ArrayGeneration.parallel(seed: row, spacing: 20, count: 0),
        isEmpty,
      );
      expect(
        ArrayGeneration.parallel(seed: row, spacing: 20, count: -5),
        isEmpty,
      );
    });

    test('nonsensical spacing yields nothing rather than NaN geometry', () {
      // NaN coordinates would poison every distance computation downstream and
      // show up as rows that silently fail to render.
      expect(
        ArrayGeneration.parallel(seed: row, spacing: double.nan, count: 4),
        isEmpty,
      );
      expect(
        ArrayGeneration.parallel(seed: row, spacing: double.infinity, count: 4),
        isEmpty,
      );
    });

    test('zero spacing stacks them, which is the honest answer', () {
      // Not a refusal: nothing is invalid about it, it just looks wrong, and the
      // preview count in the sheet is what tells the user so.
      final lines = ArrayGeneration.parallel(seed: row, spacing: 0, count: 3);
      expect(lines.length, 3);
      expect(lines[2].points, row.points);
    });

    test('a line with no direction yields only the seed', () {
      // Every point identical: there is no side to copy to, and twenty-four
      // copies stacked on each other would be worse than one honest refusal.
      final degenerate = Polyline([const Offset(5, 5), const Offset(5, 5)]);
      expect(
        ArrayGeneration.parallel(seed: degenerate, spacing: 10, count: 5),
        hasLength(1),
      );
    });

    test('a closed line falls back to its first real segment', () {
      // Ends coincide, so the overall direction is nothing -- but the first
      // segment has one, and copying parallel to that is the sensible reading.
      final loop = Polyline([
        const Offset(0, 0),
        const Offset(50, 0),
        const Offset(50, 50),
        const Offset(0, 0),
      ]);
      final lines = ArrayGeneration.parallel(seed: loop, spacing: 10, count: 2);
      expect(lines.length, 2);
      expect(lines[1].points.first, const Offset(0, 10));
    });
  });

  group('perpendicularOf', () {
    test('is a unit vector at right angles', () {
      final normal = ArrayGeneration.perpendicularOf(row)!;
      expect(normal.distance, closeTo(1, 1e-9));
      // Dot product with the line's direction is zero.
      final direction = row.points.last - row.points.first;
      expect(
        normal.dx * direction.dx + normal.dy * direction.dy,
        closeTo(0, 1e-9),
      );
    });

    test('is null when there is no direction at all', () {
      expect(
        ArrayGeneration.perpendicularOf(
          Polyline([const Offset(1, 1), const Offset(1, 1)]),
        ),
        isNull,
      );
    });
  });
}
