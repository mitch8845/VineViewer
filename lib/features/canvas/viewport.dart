import 'dart:ui' show Offset, Rect;

/// Maps between layout coordinates (image pixels) and screen coordinates.
///
/// Kept as a plain value rather than reading a Matrix4 out of a widget: the
/// painter needs the visible rectangle in *layout* space every frame to cull,
/// and hit-testing needs to convert a tap back the other way. Both go through
/// here, so the two can never disagree about where things are -- a mismatch
/// would show as taps landing on the wrong vine only when zoomed.
class CanvasViewport {
  const CanvasViewport({
    required this.scale,
    required this.translation,
    required this.size,
  });

  /// Layout pixels per screen pixel. 1.0 means the image is at native size.
  final double scale;

  /// Screen position of the layout origin.
  final Offset translation;

  /// Size of the viewport on screen.
  final Rect size;

  static const identity = CanvasViewport(
    scale: 1,
    translation: Offset.zero,
    size: Rect.zero,
  );

  Offset toScreen(Offset layoutPoint) => layoutPoint * scale + translation;

  Offset toLayout(Offset screenPoint) => (screenPoint - translation) / scale;

  /// The part of the layout currently visible.
  ///
  /// [padding] is in layout units and expands the rectangle, so a marker whose
  /// centre is just off screen still gets painted rather than popping in at
  /// the edge as you pan.
  Rect visibleLayoutRect({double padding = 0}) {
    final topLeft = toLayout(size.topLeft);
    final bottomRight = toLayout(size.bottomRight);
    return Rect.fromLTRB(
      topLeft.dx - padding,
      topLeft.dy - padding,
      bottomRight.dx + padding,
      bottomRight.dy + padding,
    );
  }

  /// Converts a screen distance to layout units.
  ///
  /// Used for tap tolerance: a finger is the same size on screen whatever the
  /// zoom, so the tolerance in layout units has to shrink as you zoom in. Using
  /// a fixed layout tolerance instead would make it impossible to select
  /// individual vines when zoomed out, and absurdly precise when zoomed in.
  double screenToLayoutDistance(double screenDistance) =>
      screenDistance / scale;

  @override
  bool operator ==(Object other) =>
      other is CanvasViewport &&
      other.scale == scale &&
      other.translation == translation &&
      other.size == size;

  @override
  int get hashCode => Object.hash(scale, translation, size);
}
