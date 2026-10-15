import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/geometry/row_generation.dart';
import '../../core/geometry/shapes.dart';
import '../../core/geometry/spatial_index.dart';
import '../../core/models/enums.dart';
import '../../core/providers.dart';
import 'plant_colouring.dart';
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

/// How strongly the aerial photo shows, 0 to 1.
final aerialOpacityProvider = StateProvider<double>((ref) => 1);

/// Whether the frame-timing readout is on.
final showFrameStatsProvider = StateProvider<bool>((ref) => false);

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
  LayoutSnapshot({
    required this.positions,
    required this.index,
    required this.objects,
    required this.bounds,
    this.retired = const {},
    SpatialIndex? retiredIndex,
  }) : retiredIndex = retiredIndex ?? SpatialIndex.empty;

  static final empty = LayoutSnapshot(
    positions: const {},
    index: SpatialIndex.empty,
    objects: const [],
    bounds: ui.Rect.zero,
  );

  /// Living plants. Everything that selects, numbers or measures works from
  /// these.
  final Map<String, ui.Offset> positions;
  final SpatialIndex index;

  /// Retired plants: the "empty slots" the plan describes.
  ///
  /// Kept apart from [index] so a marquee over a row cannot sweep the dead into
  /// a bulk edit, and so a tap on a replanted position finds the successor
  /// rather than whichever of the two sorted first. A slot is still reachable
  /// on its own -- tapping one where no living plant is near selects it, which
  /// is how you get to "Replace with a new plant" for a gap.
  final Map<String, ui.Offset> retired;
  final SpatialIndex retiredIndex;

  /// Everything drawn, whatever its kind.
  final List<DrawnObject> objects;

  /// Extent of everything, for fitting the view.
  final ui.Rect bounds;
}

/// Re-runs [build] whenever [triggers] fires, coalescing bursts.
///
/// A gesture can touch the same table many times; a reshape writes the object,
/// forty plants, and their memberships. Rebuilding once per notification would
/// queue forty rebuilds of a 4,000-plant snapshot behind each other. Instead,
/// a notification arriving mid-build just marks the result stale, and one more
/// build runs when the current one finishes.
Stream<T> rebuildOn<T>(
  Ref ref,
  Stream<Object?> triggers,
  Future<T> Function() build,
) {
  final out = StreamController<T>();
  var running = false;
  var dirty = false;

  Future<void> run() async {
    if (running) {
      dirty = true;
      return;
    }
    running = true;
    do {
      dirty = false;
      try {
        final value = await build();
        if (!out.isClosed) out.add(value);
      } catch (e, s) {
        if (!out.isClosed) out.addError(e, s);
      }
    } while (dirty && !out.isClosed);
    running = false;
  }

  final subscription = triggers.listen((_) => run());
  ref.onDispose(() {
    subscription.cancel();
    out.close();
  });
  run();
  return out.stream;
}

/// Watches the plants and objects of the active project and assembles a
/// snapshot.
///
/// Driven by the **plants, objects and field definitions** tables together.
/// It used to follow the plants table alone, so anything that wrote no plant
/// row -- drawing a block, an unplanted line or a post, renaming or reshaping
/// an object with nothing on it, and undoing any of those -- did not appear
/// until some unrelated plant edit happened to dislodge it.
final layoutSnapshotProvider = StreamProvider<LayoutSnapshot>((ref) {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return Stream.value(LayoutSnapshot.empty);

  final db = ref.watch(databaseProvider);
  final layout = ref.watch(layoutDaoProvider);
  final fieldDefs = ref.watch(fieldDefsDaoProvider);

  return rebuildOn(
    ref,
    db.tableUpdates(
      TableUpdateQuery.onAllTables([db.plants, db.mapObjects, db.fieldDefs]),
    ),
    () async {
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
      final retired = <String, ui.Offset>{};
      final retiredPoints = <IndexedPoint>[];
      for (final plant in await layout.plantsInProject(projectId)) {
        if (plant.x == null || plant.y == null) continue;
        final position = ui.Offset(plant.x!, plant.y!);
        if (plant.status == PlantStatus.active) {
          positions[plant.id] = position;
          points.add((id: plant.id, position: position));
        } else {
          retired[plant.id] = position;
          retiredPoints.add((id: plant.id, position: position));
        }
      }

      return LayoutSnapshot(
        positions: positions,
        index: SpatialIndex.build(points),
        objects: drawn,
        bounds: _boundsOf([...points, ...retiredPoints], drawn),
        retired: retired,
        retiredIndex: SpatialIndex.build(retiredPoints),
      );
    },
  );
});

/// Ticks whenever anything a plant identifier is made of changes.
///
/// An identifier is assembled from the template (projects), container
/// membership (memberships, objects, fields), the plant's own number (plants)
/// and any attribute in the template (field events). Watching the layout
/// snapshot alone missed the last three: renaming Row 12 or correcting a clone
/// that is part of the ID left the old IDs on the map and in the inspector.
final identityRevisionProvider = StreamProvider<int>((ref) async* {
  final db = ref.watch(databaseProvider);
  var revision = 0;
  // Starts with a value, so a dependant is never left loading until the
  // first edit happens to arrive.
  yield revision;
  await for (final _ in db.tableUpdates(
    TableUpdateQuery.onAllTables([
      db.projects,
      db.plants,
      db.mapObjects,
      db.plantMemberships,
      db.fieldDefs,
      db.fieldEvents,
    ]),
  )) {
    yield ++revision;
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

/// Plant identifiers for the active project, refreshed when anything they are
/// made of changes.
final labelsProvider = FutureProvider<Map<String, String>>((ref) async {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return const {};

  ref.watch(identityRevisionProvider);

  final identifiers = await ref
      .watch(labelServiceProvider)
      .identifiersForProject(projectId);
  return {for (final e in identifiers.entries) e.key: e.value.text};
});

/// The active project's row, live -- so a rename shows in the title bar
/// without leaving the map.
final activeProjectProvider = StreamProvider<Project?>((ref) {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return Stream.value(null);
  final db = ref.watch(databaseProvider);
  return (db.select(
    db.projects,
  )..where((p) => p.id.equals(projectId))).watchSingleOrNull();
});

/// Which attribute field colours the plants, or null for plain green.
final colorByFieldProvider = StateProvider<String?>((ref) => null);

/// Per-plant colours and a legend for [colorByFieldProvider].
///
/// Live on the event log, so recording a health score recolours that plant
/// immediately -- the whole point of colouring a survey as you walk it.
final plantColouringProvider = StreamProvider<PlantColouring?>((ref) {
  final fieldId = ref.watch(colorByFieldProvider);
  if (fieldId == null) return Stream.value(null);

  final db = ref.watch(databaseProvider);
  final fieldDefs = ref.watch(fieldDefsDaoProvider);
  final events = ref.watch(fieldEventsDaoProvider);
  // Every living plant, so the ones with nothing recorded can be greyed
  // rather than left looking like the default.
  final plantIds = ref.watch(
    layoutSnapshotProvider.select((s) => s.valueOrNull?.positions.keys.toSet()),
  );

  return rebuildOn(
    ref,
    db.tableUpdates(
      TableUpdateQuery.onAllTables([db.fieldEvents, db.fieldDefs]),
    ),
    () async {
      final field = await fieldDefs.byId(fieldId);
      if (field == null || field.deletedAt != null) return null;
      final current = await events.currentValuesForField(fieldId);
      return PlantColouring.build(
        field: field,
        config: fieldDefs.configOf(field),
        values: {
          for (final id in plantIds ?? current.keys) id: current[id]?.value,
        },
      );
    },
  );
});

/// Clears everything that belongs to the project being left.
///
/// The selection, the tool, the half-drawn shape and the chosen draw field are
/// global providers, and nothing reset them between projects: a plant selected
/// in one vineyard stayed selected in the next -- its edits landing on the old
/// project's plant while being journaled under the new one -- and the Draw
/// tool kept the old project's Row field, creating objects against a field
/// that did not exist there.
void resetProjectScopedState(WidgetRef ref) {
  ref.read(selectionProvider.notifier).state = const {};
  ref.read(selectedObjectProvider.notifier).state = null;
  ref.read(activeToolProvider.notifier).state = CanvasTool.select;
  ref.read(activeObjectFieldProvider.notifier).state = null;
  ref.read(pendingShapeProvider.notifier).state = const [];
  ref.read(reshapeDraftProvider.notifier).state = null;
  ref.read(marqueeProvider.notifier).state = null;
  ref.read(lassoProvider.notifier).state = const [];
  ref.read(colorByFieldProvider.notifier).state = null;
}

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
