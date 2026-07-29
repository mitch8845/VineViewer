import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry/row_generation.dart';
import '../../core/geometry/shapes.dart';
import '../../core/geometry/spatial_index.dart';
import '../../core/providers.dart';
import 'vineyard_canvas.dart';
import 'vineyard_painter.dart';

/// Which project the canvas is showing. Null until one is opened.
final activeProjectIdProvider = StateProvider<String?>((ref) => null);

/// The active tool.
final activeToolProvider = StateProvider<CanvasTool>(
  (ref) => CanvasTool.select,
);

/// Currently selected plant ids.
final selectionProvider = StateProvider<Set<String>>((ref) => const {});

/// Whether a tap adds to the selection instead of replacing it.
///
/// A sticky toggle rather than a modifier key, because the tablet has no
/// keyboard and the gesture this replaces -- hold-and-tap -- competes with the
/// long-press the OS reserves. Building a selection out of forty scattered
/// plants is a normal thing to want, and a marquee cannot express it.
final stickySelectProvider = StateProvider<bool>((ref) => false);

/// The drawn object the user has selected, if any.
///
/// Separate from [selectionProvider], which only ever holds plants. Tapping a
/// row selects *the row* -- the thing you rename, reshape, plant into or delete
/// -- and offers its plants as one further tap.
final selectedObjectProvider = StateProvider<String?>((ref) => null);

/// A vertex being dragged, holding the whole reworked shape.
///
/// The shape rather than just the moved point, so the painter can draw the
/// proposal by substitution and needs to know nothing about reshaping.
typedef ReshapeDraft = ({String objectId, int vertex, Shape shape});

final reshapeDraftProvider = StateProvider<ReshapeDraft?>((ref) => null);

/// Whether to draw `block.row.plant` labels.
final showLabelsProvider = StateProvider<bool>((ref) => false);

/// Which object field the draw tool creates instances of.
///
/// Null until the user picks one, which matters because a project may define no
/// object fields at all -- "want neither, get neither".
final activeObjectFieldProvider = StateProvider<String?>((ref) => null);

/// Points collected while drawing a shape, before it is committed.
final pendingShapeProvider = StateProvider<List<ui.Offset>>((ref) => const []);

/// The box being dragged out, in layout coordinates.
final marqueeProvider = StateProvider<ui.Rect?>((ref) => null);

/// The lasso being drawn, in layout coordinates.
final lassoProvider = StateProvider<List<ui.Offset>>((ref) => const []);

/// The layout as the canvas needs it: positions, drawn objects, and an index.
///
/// Rebuilt whenever the underlying tables change, not per frame. Building the
/// spatial index here rather than in the painter means it happens once per edit
/// instead of sixty times a second.
class LayoutSnapshot {
  const LayoutSnapshot({
    required this.positions,
    required this.index,
    required this.objects,
    required this.bounds,
  });

  static final empty = LayoutSnapshot(
    positions: const {},
    index: SpatialIndex.empty,
    objects: const [],
    bounds: ui.Rect.zero,
  );

  final Map<String, ui.Offset> positions;
  final SpatialIndex index;

  /// Everything drawn, whatever its kind.
  final List<DrawnObject> objects;

  /// Extent of everything, for fitting the view.
  final ui.Rect bounds;
}

/// Watches the plants and objects of the active project and assembles a
/// snapshot.
final layoutSnapshotProvider = StreamProvider<LayoutSnapshot>((ref) async* {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) {
    yield LayoutSnapshot.empty;
    return;
  }

  final layout = ref.watch(layoutDaoProvider);
  final fieldDefs = ref.watch(fieldDefsDaoProvider);

  await for (final plants in layout.watchPlantsInProject(projectId)) {
    // Draw types live on the field, so the objects cannot be interpreted
    // without them.
    final fields = {
      for (final f in await fieldDefs.forProject(projectId)) f.id: f,
    };
    final drawn = <DrawnObject>[];
    for (final object in await layout.objectsInProject(projectId)) {
      final field = fields[object.fieldDefId];
      final drawType = field?.drawType;
      if (drawType == null) continue;

      // An object named but not yet drawn simply has nothing to paint.
      final shape = Shape.tryParse(object.geometry, drawType);
      if (shape == null) continue;

      drawn.add((
        id: object.id,
        fieldDefId: object.fieldDefId,
        label: object.label,
        shape: shape,
        isContainer: field!.isContainer,
      ));
    }

    final positions = <String, ui.Offset>{};
    final points = <IndexedPoint>[];
    for (final plant in plants) {
      if (plant.x == null || plant.y == null) continue;
      final position = ui.Offset(plant.x!, plant.y!);
      positions[plant.id] = position;
      points.add((id: plant.id, position: position));
    }

    yield LayoutSnapshot(
      positions: positions,
      index: SpatialIndex.build(points),
      objects: drawn,
      bounds: _boundsOf(points, drawn),
    );
  }
});

/// Extent of everything drawn, so fit-to-layout frames a block as well as a
/// row.
ui.Rect _boundsOf(List<IndexedPoint> points, List<DrawnObject> objects) {
  if (points.isEmpty && objects.isEmpty) return ui.Rect.zero;

  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;

  void include(double x, double y) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }

  for (final p in points) {
    include(p.position.dx, p.position.dy);
  }
  for (final object in objects) {
    for (final p in object.shape.points) {
      include(p.dx, p.dy);
    }
  }

  return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Plant identifiers for the active project, refreshed when the layout changes.
final labelsProvider = FutureProvider<Map<String, String>>((ref) async {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return const {};

  // Depends on the layout so renumbering, a new plant, or a boundary edit that
  // changes containment all refresh what is drawn.
  ref.watch(layoutSnapshotProvider);

  final identifiers = await ref
      .watch(labelServiceProvider)
      .identifiersForProject(projectId);
  return {for (final e in identifiers.entries) e.key: e.value.text};
});

/// The active project's scale calibration, or uncalibrated.
final calibrationProvider = FutureProvider<ScaleCalibration>((ref) async {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return ScaleCalibration.uncalibrated;

  final project = await ref.watch(projectsDaoProvider).byId(projectId);
  if (project == null) return ScaleCalibration.uncalibrated;

  return ScaleCalibration.fromProject(
    refPixels: project.scaleRefPx,
    refLength: project.scaleRefLength,
    unit: project.scaleUnit,
  );
});

/// Decoded background image for the active project.
///
/// Decoded once and held, never per frame. A 4,000x3,000 aerial is ~48MB as
/// raw pixels; decoding that inside paint would drop every frame and exhaust
/// the Fire Max 11's memory budget in seconds.
final backgroundImageProvider = FutureProvider<ui.Image?>((ref) async {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return null;

  final project = await ref.watch(projectsDaoProvider).byId(projectId);
  final path = project?.imagePath;
  if (path == null) return null;

  try {
    final file = File(path);
    if (!file.existsSync()) return null;

    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    final frame = await codec.getNextFrame();
    ref.onDispose(frame.image.dispose);
    return frame.image;
  } catch (_) {
    // A missing or corrupt image leaves the layout drawable rather than taking
    // the project down. The plants are the data; the photo is backdrop, and an
    // aerial that moved on disk should not cost you access to 3,000 records.
    return null;
  }
});
