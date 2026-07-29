import 'dart:ui' show Offset;

import 'polyline.dart';

/// Laying out repeated copies of a shape.
///
/// The justification is narrow and worth stating, because the tool this feeds
/// was nearly cut: drawing Five Sisters by hand is about six interactions per
/// row and roughly an hour in total, which is not a crisis. What *is* worth
/// automating is block 2's 24 near-identical parallel rows and block 3's 26 --
/// one gesture instead of fifty.
///
/// Two rules constrain everything here, both from the amended plan:
///
///  * **Generated lines are independent from the moment they exist.** No parent
///    link, no re-flow. Dragging one line's endpoint must leave the other 23
///    exactly where they are, so this returns plain geometry and the caller
///    writes plain, unrelated objects.
///  * **The array creates geometry and plants, never attribute values.**
///    Container values derive from geometry as everywhere else; anything else is
///    set afterwards with multi-select and bulk edit. The tool lays out, it does
///    not decide what things are.
abstract final class ArrayGeneration {
  /// [count] copies of [seed], each [spacing] further along its perpendicular.
  ///
  /// **The first copy is the seed itself**, unmoved. The user drew one row and
  /// asked for twenty-four; they mean twenty-four rows in total, not
  /// twenty-five.
  ///
  /// Perpendicular to the line's *overall* direction -- first point to last --
  /// rather than per segment. Vineyard rows are parallel, so a row that doglegs
  /// at a stake should be copied doglegs and all; offsetting each segment by its
  /// own normal would instead fan the copies apart and change the shape.
  ///
  /// [flip] chooses which side. There is no way to guess it: the perpendicular
  /// of a line drawn left-to-right points one way and the same line drawn
  /// right-to-left points the other, and the user is not thinking about the
  /// direction they happened to drag in.
  static List<Polyline> parallel({
    required Polyline seed,
    required double spacing,
    required int count,
    bool flip = false,
  }) {
    if (count <= 0 || !spacing.isFinite) return const [];
    if (count == 1) return [seed];

    final normal = perpendicularOf(seed);
    if (normal == null) return [seed];

    final step = normal * spacing * (flip ? -1.0 : 1.0);
    return [
      for (var i = 0; i < count; i++)
        if (i == 0)
          seed
        else
          Polyline([for (final p in seed.points) p + step * i.toDouble()]),
    ];
  }

  /// The unit vector at right angles to [line]'s overall direction.
  ///
  /// Null when the line has no direction to speak of -- every point identical, or
  /// a loop whose ends coincide. Returning null rather than picking arbitrarily
  /// lets the caller say "that line does not have a side" instead of silently
  /// producing twenty-four copies stacked on top of each other.
  static Offset? perpendicularOf(Polyline line) {
    var direction = line.points.last - line.points.first;

    // A closed or near-closed line has no overall direction, but its first real
    // segment does, and copying parallel to that is the sensible reading.
    if (direction.distance < _epsilon) {
      for (var i = 1; i < line.points.length; i++) {
        final segment = line.points[i] - line.points[i - 1];
        if (segment.distance >= _epsilon) {
          direction = segment;
          break;
        }
      }
    }

    final length = direction.distance;
    if (length < _epsilon || !length.isFinite) return null;

    // Rotate a quarter turn. Which of the two normals this is does not matter --
    // `flip` exposes both, and neither is more correct than the other.
    return Offset(-direction.dy / length, direction.dx / length);
  }

  /// Below this, a segment is a repeated point rather than a direction. Chosen
  /// against layout pixels, where anything under a thousandth of a pixel is a
  /// double-tap while drawing rather than a real segment.
  static const _epsilon = 1e-9;
}
