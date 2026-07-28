import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry/polyline.dart';
import '../../core/geometry/row_generation.dart';
import '../../core/geometry/spatial_index.dart';
import '../../core/providers.dart';
import 'vineyard_canvas.dart';

/// Which project the canvas is showing. Null until one is opened.
final activeProjectIdProvider = StateProvider<String?>((ref) => null);

/// The active tool.
final activeToolProvider = StateProvider<CanvasTool>(
  (ref) => CanvasTool.select,
);

/// Currently selected vine ids.
final selectionProvider = StateProvider<Set<String>>((ref) => const {});

/// Whether to draw `block.row.plant` labels.
final showLabelsProvider = StateProvider<bool>((ref) => false);

/// Points being collected while drawing a row, before it is committed.
final pendingRowProvider = StateProvider<List<ui.Offset>>((ref) => const []);

/// The layout as the canvas needs it: positions, rows, and a built index.
///
/// Rebuilt whenever the underlying tables change, not per frame. Building the
/// spatial index here rather than in the painter means it happens once per
/// edit instead of sixty times a second.
class LayoutSnapshot {
  const LayoutSnapshot({
    required this.positions,
    required this.index,
    required this.rows,
    required this.bounds,
  });

  static final empty = LayoutSnapshot(
    positions: const {},
    index: SpatialIndex.empty,
    rows: const [],
    bounds: ui.Rect.zero,
  );

  final Map<String, ui.Offset> positions;
  final SpatialIndex index;
  final List<Polyline> rows;

  /// Extent of everything, for fitting the view.
  final ui.Rect bounds;
}

/// Watches the vines and rows of the active project and assembles a snapshot.
final layoutSnapshotProvider = StreamProvider<LayoutSnapshot>((ref) async* {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) {
    yield LayoutSnapshot.empty;
    return;
  }

  final layout = ref.watch(layoutDaoProvider);

  await for (final vines in layout.watchVinesInProject(projectId)) {
    final rows = await layout.rowsInProject(projectId);

    final positions = <String, ui.Offset>{};
    final points = <IndexedPoint>[];
    for (final vine in vines) {
      if (vine.x == null || vine.y == null) continue;
      final position = ui.Offset(vine.x!, vine.y!);
      positions[vine.id] = position;
      points.add((id: vine.id, position: position));
    }

    // Rows that have not been drawn yet simply have no polyline to paint.
    final polylines = [for (final row in rows) ?Polyline.tryParse(row.path)];

    yield LayoutSnapshot(
      positions: positions,
      index: SpatialIndex.build(points),
      rows: polylines,
      bounds: _boundsOf(points, polylines),
    );
  }
});

ui.Rect _boundsOf(List<IndexedPoint> points, List<Polyline> rows) {
  if (points.isEmpty && rows.isEmpty) return ui.Rect.zero;

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
  for (final row in rows) {
    for (final p in row.points) {
      include(p.dx, p.dy);
    }
  }

  return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Labels for the active project, refreshed when the layout changes.
final labelsProvider = FutureProvider<Map<String, String>>((ref) async {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return const {};

  // Depend on the layout so a renumber or a new vine refreshes the labels.
  ref.watch(layoutSnapshotProvider);

  final labels = await ref
      .watch(labelServiceProvider)
      .labelsForProject(projectId);
  return {for (final e in labels.entries) e.key: e.value.text};
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
    // the project down. The vines are the data; the photo is backdrop, and an
    // aerial that moved on disk should not cost you access to 3,000 records.
    return null;
  }
});
