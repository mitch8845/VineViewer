import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/row_generation.dart';

/// A 100px horizontal line.
Polyline get straight => Polyline([const Offset(0, 0), const Offset(100, 0)]);

/// An L: 100px right, then 100px down. Total 200px, one hard turn -- the shape
/// a real row makes when it changes direction at a stake.
Polyline get elbow => Polyline([
  const Offset(0, 0),
  const Offset(100, 0),
  const Offset(100, 100),
]);

void main() {
  group('Polyline length and bounds', () {
    test('measures a straight line', () {
      expect(straight.length, 100);
    });

    test('sums segments across a turn', () {
      expect(elbow.length, 200);
    });

    test('bounds cover every point', () {
      expect(elbow.bounds.left, 0);
      expect(elbow.bounds.top, 0);
      expect(elbow.bounds.right, 100);
      expect(elbow.bounds.bottom, 100);
    });

    test('rejects fewer than two points', () {
      expect(() => Polyline([const Offset(0, 0)]), throwsAssertionError);
    });
  });

  group('pointAt', () {
    test('walks a straight line', () {
      expect(straight.pointAt(0), const Offset(0, 0));
      expect(straight.pointAt(50), const Offset(50, 0));
      expect(straight.pointAt(100), const Offset(100, 0));
    });

    test('follows the path around a turn', () {
      // 150 along the elbow is 100 across, then 50 down.
      expect(elbow.pointAt(150), const Offset(100, 50));
    });

    test('lands exactly on the corner', () {
      expect(elbow.pointAt(100), const Offset(100, 0));
    });

    test('clamps rather than throwing when past the end', () {
      // A row that was shortened leaves plants holding offsets beyond its
      // length. Parking them at the end keeps them visible and fixable;
      // throwing would take the whole canvas down.
      expect(straight.pointAt(500), const Offset(100, 0));
      expect(straight.pointAt(-50), const Offset(0, 0));
    });

    test('survives a repeated point', () {
      // Double-tapping while drawing produces a zero-length segment.
      final degenerate = Polyline([
        const Offset(0, 0),
        const Offset(0, 0),
        const Offset(100, 0),
      ]);
      expect(degenerate.length, 100);
      expect(degenerate.pointAt(50), const Offset(50, 0));
    });
  });

  group('closestTo', () {
    test('projects onto a straight line', () {
      final result = straight.closestTo(const Offset(50, 20));
      expect(result.offset, 50);
      expect(result.distance, 20);
      expect(result.point, const Offset(50, 0));
    });

    test('clamps beyond the ends rather than extending the line', () {
      final result = straight.closestTo(const Offset(200, 0));
      expect(result.offset, 100);
      expect(result.point, const Offset(100, 0));
    });

    test('picks the nearest segment across a turn', () {
      // Nearer the vertical leg than the horizontal one.
      final result = elbow.closestTo(const Offset(120, 60));
      expect(result.point, const Offset(100, 60));
      expect(result.offset, 160);
      expect(result.distance, 20);
    });

    test('handles a point exactly on the path', () {
      final result = straight.closestTo(const Offset(30, 0));
      expect(result.distance, 0);
      expect(result.offset, 30);
    });
  });

  group('reversed', () {
    // Numbering direction is implemented by storing the row the other way
    // round, so that position_idx always follows path order. Nothing downstream
    // has to consult a flag, and renumberRow -- which sorts by path_offset --
    // keeps agreeing with what is on the ground.
    test('walks the same shape from the other end', () {
      final back = elbow.reversed;
      expect(back.points, elbow.points.reversed.toList());
      expect(back.points.first, elbow.points.last);
    });

    test('is the same length', () {
      expect(elbow.reversed.length, closeTo(elbow.length, 1e-9));
    });

    test('offset zero moves to the far end', () {
      expect(elbow.reversed.pointAt(0), elbow.points.last);
      expect(elbow.reversed.pointAt(elbow.length), elbow.points.first);
    });

    test('reversing twice is the original', () {
      expect(elbow.reversed.reversed.points, elbow.points);
    });

    test('plant one lands where the user said it should', () {
      // The whole point of the toggle: plant 1 sits at the end they picked.
      final offsets = RowGeneration.byCount(elbow.reversed, 5);
      expect(elbow.reversed.pointAt(offsets.first), elbow.points.last);
    });
  });

  group('JSON round trip', () {
    test('survives encoding and decoding', () {
      final restored = Polyline.tryParse(elbow.toJson())!;
      expect(restored.points, elbow.points);
      expect(restored.length, elbow.length);
    });

    test('malformed input yields null rather than throwing', () {
      // A row with an unreadable path should render as undrawn and stay
      // editable, not stop the project opening.
      for (final bad in [
        null,
        '',
        '   ',
        'not json',
        '{}',
        '[]',
        '[[0,0]]', // only one point
        '[[0,0],[1]]', // short pair
        '[[0,0],["a","b"]]', // non-numeric
        '[[0,0],[null,2]]',
      ]) {
        expect(Polyline.tryParse(bad), isNull, reason: 'input: $bad');
      }
    });

    test('rejects non-finite coordinates', () {
      // NaN would poison every distance computation downstream and show up as
      // plants that silently fail to render.
      expect(Polyline.tryParse('[[0,0],[1e999,0]]'), isNull);
    });
  });

  group('RowGeneration.byCount', () {
    test('places the first at the start and last at the end', () {
      final offsets = RowGeneration.byCount(straight, 5);
      expect(offsets, [0, 25, 50, 75, 100]);
    });

    test('a single plant goes at the start', () {
      expect(RowGeneration.byCount(straight, 1), [0]);
    });

    test('zero or negative yields nothing', () {
      expect(RowGeneration.byCount(straight, 0), isEmpty);
      expect(RowGeneration.byCount(straight, -3), isEmpty);
    });

    test('spreads across a turn by arc length, not straight-line distance', () {
      final offsets = RowGeneration.byCount(elbow, 3);
      expect(offsets, [0, 100, 200]);
      expect(elbow.pointAt(offsets[1]), const Offset(100, 0));
    });
  });

  group('RowGeneration.bySpacing', () {
    test('steps along the row', () {
      expect(RowGeneration.bySpacing(straight, 25), [0, 25, 50, 75, 100]);
    });

    test('never places past the end', () {
      // 100px row at 30px spacing: 0, 30, 60, 90 -- the last 10px stays empty,
      // which is how a row actually gets planted.
      expect(RowGeneration.bySpacing(straight, 30), [0, 30, 60, 90]);
    });

    test('rejects nonsensical spacing', () {
      expect(RowGeneration.bySpacing(straight, 0), isEmpty);
      expect(RowGeneration.bySpacing(straight, -5), isEmpty);
      expect(RowGeneration.bySpacing(straight, double.nan), isEmpty);
    });

    test('caps pathological spacing instead of hanging', () {
      // A fat-fingered 0.001 spacing would otherwise try to place millions of
      // plants on the UI thread.
      final offsets = RowGeneration.bySpacing(straight, 0.001);
      expect(offsets.length, lessThanOrEqualTo(5000));
    });

    test('countForSpacing agrees with bySpacing', () {
      for (final spacing in [10.0, 25.0, 30.0, 7.5]) {
        expect(
          RowGeneration.countForSpacing(straight, spacing),
          RowGeneration.bySpacing(straight, spacing).length,
          reason: 'spacing $spacing',
        );
      }
    });
  });

  group('ScaleCalibration', () {
    test('uncalibrated works in pixels', () {
      const cal = ScaleCalibration.uncalibrated;
      expect(cal.isCalibrated, isFalse);
      expect(cal.toPixels(50), 50);
      expect(cal.format(2412, decimals: 0), '2412 px');
    });

    test('converts once calibrated', () {
      // 500px measured across something 100ft long -> 5 px per ft.
      final cal = ScaleCalibration.fromProject(
        refPixels: 500,
        refLength: 100,
        unit: 'ft',
      );
      expect(cal.isCalibrated, isTrue);
      expect(cal.toPixels(6), 30);
      expect(cal.toReal(30), 6);
      expect(cal.format(150, decimals: 0), '30 ft');
    });

    test('falls back to pixels on incomplete or nonsensical input', () {
      // Half-finished calibration must not produce infinite or zero scales
      // that silently place every plant on top of each other.
      for (final args in [
        (null, 100.0, 'ft'),
        (500.0, null, 'ft'),
        (500.0, 100.0, null),
        (0.0, 100.0, 'ft'),
        (500.0, 0.0, 'ft'),
        (-500.0, 100.0, 'ft'),
        (double.infinity, 100.0, 'ft'),
      ]) {
        expect(
          ScaleCalibration.fromProject(
            refPixels: args.$1,
            refLength: args.$2,
            unit: args.$3,
          ),
          ScaleCalibration.uncalibrated,
          reason: '$args',
        );
      }
    });

    test('spacing in real units becomes the right pixel spacing', () {
      // The whole point of calibration: "a plant every 6 ft" on a 500px row
      // calibrated at 5px/ft should place one every 30px.
      final cal = ScaleCalibration.fromProject(
        refPixels: 500,
        refLength: 100,
        unit: 'ft',
      );
      final row = Polyline([const Offset(0, 0), const Offset(500, 0)]);
      final offsets = RowGeneration.bySpacing(row, cal.toPixels(6));

      expect(offsets.first, 0);
      expect(offsets[1], 30);
      expect(offsets.length, 17); // 0 to 480 inclusive
    });
  });
}
