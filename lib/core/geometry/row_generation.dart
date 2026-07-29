import 'polyline.dart';

/// Where to place plants along a row.
///
/// Returns arc-length offsets rather than points: `plants.path_offset` is what
/// gets stored, and x/y is derived from it. Handing back offsets keeps the one
/// authoritative value in one place.
abstract final class RowGeneration {
  /// [count] plants spread evenly, first at the start and last at the end.
  ///
  /// Endpoints inclusive because the user drew the row from the first plant to
  /// the last. Placing the first plant slightly inside the line they drew would
  /// look like the tool ignoring them.
  static List<double> byCount(Polyline row, int count) {
    if (count <= 0) return const [];
    if (count == 1) return [0];

    final step = row.length / (count - 1);
    return [for (var i = 0; i < count; i++) i * step];
  }

  /// A plant every [spacing] units, starting at the row's start.
  ///
  /// The final plant lands at or before the end; the tool never places one past
  /// the line the user drew. If the row does not divide evenly the remainder is
  /// simply left empty, which matches how a row is actually planted.
  ///
  /// [spacing] is in the same units as the polyline -- pixels unless the caller
  /// has already converted using the project's scale calibration.
  static List<double> bySpacing(Polyline row, double spacing) {
    if (spacing <= 0 || !spacing.isFinite) return const [];

    final offsets = <double>[];
    // Guard against pathological input generating millions of entries: a
    // spacing of 0.001px on a 5,000px row would otherwise try to place five
    // million plants and hang the UI thread.
    const maxPlantsPerRow = 5000;

    for (
      var offset = 0.0;
      offset <= row.length && offsets.length < maxPlantsPerRow;
      offset += spacing
    ) {
      offsets.add(offset);
    }
    return offsets;
  }

  /// How many plants [bySpacing] would place, without building the list.
  ///
  /// Lets the tool preview "≈ 47 plants" while the user drags, without
  /// allocating on every pointer move.
  static int countForSpacing(Polyline row, double spacing) {
    if (spacing <= 0 || !spacing.isFinite) return 0;
    return (row.length / spacing).floor() + 1;
  }
}

/// Converts between real-world units and image pixels.
///
/// Created from a project's calibration, or [uncalibrated] when the user has
/// not measured anything. Every distance the user types passes through here, so
/// an uncalibrated project simply works in pixels rather than refusing input.
class ScaleCalibration {
  const ScaleCalibration._({required this.pixelsPerUnit, required this.unit});

  /// No calibration: distances are pixels and are labelled "px".
  static const uncalibrated = ScaleCalibration._(pixelsPerUnit: 1, unit: 'px');

  final double pixelsPerUnit;
  final String unit;

  bool get isCalibrated => this != uncalibrated;

  /// Builds from stored project values, falling back to [uncalibrated] if any
  /// part is missing or nonsensical.
  static ScaleCalibration fromProject({
    double? refPixels,
    double? refLength,
    String? unit,
  }) {
    if (refPixels == null ||
        refLength == null ||
        unit == null ||
        refPixels <= 0 ||
        refLength <= 0 ||
        !refPixels.isFinite ||
        !refLength.isFinite) {
      return uncalibrated;
    }
    return ScaleCalibration._(pixelsPerUnit: refPixels / refLength, unit: unit);
  }

  /// Real-world distance to image pixels.
  double toPixels(double realDistance) => realDistance * pixelsPerUnit;

  /// Image pixels to real-world distance.
  double toReal(double pixelDistance) => pixelDistance / pixelsPerUnit;

  /// Formats a pixel distance for display, e.g. "312 ft" or "2412 px".
  String format(double pixelDistance, {int decimals = 1}) {
    final value = toReal(pixelDistance);
    return '${value.toStringAsFixed(decimals)} $unit';
  }

  @override
  bool operator ==(Object other) =>
      other is ScaleCalibration &&
      other.pixelsPerUnit == pixelsPerUnit &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(pixelsPerUnit, unit);
}
