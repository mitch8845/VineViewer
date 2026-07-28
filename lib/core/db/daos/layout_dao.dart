import 'dart:ui' show Offset;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/label_service.dart';
import '../../geometry/polyline.dart';
import '../../models/enums.dart';
import '../database.dart';

/// Creates and edits the physical layout: blocks, rows, and vine positions.
///
/// **The invariant this class exists to maintain:** a vine with a non-null
/// `rowId` is physically on that row. Its `x`/`y` is always
/// `polyline.pointAt(pathOffset)`, never anything else. Every operation that
/// could break that -- reshaping a row, moving a row, dragging a vine --
/// restores it before returning.
///
/// Addresses are not this class's concern; [LabelService] owns those. Layout
/// moves things, labelling names them.
class LayoutDao {
  LayoutDao(this._db, this._labels, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final LabelService _labels;
  final Uuid _uuid;

  // ------------------------------------------------------------------ blocks

  Future<String> createBlock({
    required String projectId,
    required String label,
    DateTime? now,
  }) async {
    final problem = LabelService.problemWithLabel(label);
    if (problem != null) throw ArgumentError(problem);

    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();
    await _db
        .into(_db.blocks)
        .insert(
          BlocksCompanion.insert(
            id: id,
            projectId: projectId,
            label: label.trim(),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    return id;
  }

  // -------------------------------------------------------------------- rows

  Future<String> createRow({
    required String projectId,
    required String label,
    String? blockId,
    Polyline? path,
    DateTime? now,
  }) async {
    final problem = LabelService.problemWithLabel(label);
    if (problem != null) throw ArgumentError(problem);

    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();
    await _db
        .into(_db.vineRows)
        .insert(
          VineRowsCompanion.insert(
            id: id,
            projectId: projectId,
            blockId: Value(blockId),
            label: label.trim(),
            path: Value(path?.toJson()),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    return id;
  }

  /// The row's shape, or null if it has not been drawn yet.
  Future<Polyline?> pathOf(String rowId) async {
    final row =
        await (_db.select(_db.vineRows)
              ..where((r) => r.id.equals(rowId) & r.deletedAt.isNull()))
            .getSingleOrNull();
    return Polyline.tryParse(row?.path);
  }

  /// Replaces a row's shape and slides its vines onto the new one.
  ///
  /// Vines keep their arc-length offset, so extending the far end of a row
  /// leaves every existing vine exactly where it was. Re-projecting their x/y
  /// onto the new path instead would nudge each one slightly on every edit,
  /// and the drift compounds.
  Future<void> updateRowPath(
    String rowId,
    Polyline path, {
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();

    await _db.transaction(() async {
      await (_db.update(_db.vineRows)..where((r) => r.id.equals(rowId))).write(
        VineRowsCompanion(
          path: Value(path.toJson()),
          updatedAt: Value(timestamp),
        ),
      );
      await _repositionVinesOn(rowId, path, timestamp);
    });
  }

  /// Translates a row and everything on it.
  Future<void> moveRow(String rowId, Offset delta, {DateTime? now}) async {
    final path = await pathOf(rowId);
    if (path == null) return;

    final moved = Polyline([for (final p in path.points) p + delta]);
    // Offsets are unchanged by a translation, so the vines follow exactly.
    await updateRowPath(rowId, moved, now: now);
  }

  /// Recomputes x/y for every snapped vine from its stored offset.
  Future<void> _repositionVinesOn(
    String rowId,
    Polyline path,
    DateTime timestamp,
  ) async {
    final vines = await (_db.select(
      _db.vines,
    )..where((v) => v.rowId.equals(rowId) & v.deletedAt.isNull())).get();

    for (final vine in vines) {
      // A vine with no offset yet -- placed before the row was drawn -- gets
      // one by projecting its current position onto the path.
      final offset =
          vine.pathOffset ??
          (vine.x != null && vine.y != null
              ? path.closestTo(Offset(vine.x!, vine.y!)).offset
              : 0.0);

      final point = path.pointAt(offset);
      await (_db.update(_db.vines)..where((v) => v.id.equals(vine.id))).write(
        VinesCompanion(
          pathOffset: Value(offset),
          x: Value(point.dx),
          y: Value(point.dy),
          updatedAt: Value(timestamp),
        ),
      );
    }
  }

  // ------------------------------------------------------------------- vines

  /// Places a free-standing vine at a point.
  Future<String> createVine({
    required String projectId,
    required Offset position,
    String? blockId,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db.transaction(() async {
      final plant = await _labels.nextPlantNumber(
        projectId: projectId,
        blockId: blockId,
      );
      await _db
          .into(_db.vines)
          .insert(
            VinesCompanion.insert(
              id: id,
              projectId: projectId,
              blockId: Value(blockId),
              positionIdx: plant,
              x: Value(position.dx),
              y: Value(position.dy),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
    });

    return id;
  }

  /// Creates vines along a row at the given arc-length offsets.
  ///
  /// This is what the row-by-count and row-by-spacing tools call, with offsets
  /// from `RowGeneration`. Numbering follows path order, so plant 1 is at the
  /// end the user started drawing from.
  Future<List<String>> placeVinesAlongRow({
    required String rowId,
    required List<double> offsets,
    DateTime? now,
  }) async {
    if (offsets.isEmpty) return const [];

    final path = await pathOf(rowId);
    if (path == null) {
      throw StateError('Row $rowId has no path; draw it before placing vines.');
    }

    final row = await (_db.select(
      _db.vineRows,
    )..where((r) => r.id.equals(rowId))).getSingle();

    final timestamp = now ?? DateTime.now();
    final ids = <String>[];

    await _db.transaction(() async {
      // Existing vines keep their numbers; new ones fill from the lowest free
      // number upward, so re-running the tool on a partly planted row does not
      // renumber what is already there.
      final used = <int>{
        for (final v in await (_db.select(
          _db.vines,
        )..where((v) => v.rowId.equals(rowId) & v.deletedAt.isNull())).get())
          v.positionIdx,
      };

      var next = 1;
      final sorted = [...offsets]..sort();

      for (final offset in sorted) {
        while (used.contains(next)) {
          next++;
        }
        used.add(next);

        final point = path.pointAt(offset);
        final id = _uuid.v4();
        ids.add(id);

        await _db
            .into(_db.vines)
            .insert(
              VinesCompanion.insert(
                id: id,
                projectId: row.projectId,
                rowId: Value(rowId),
                blockId: Value(row.blockId),
                positionIdx: next,
                x: Value(point.dx),
                y: Value(point.dy),
                pathOffset: Value(offset),
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            );
      }
    });

    return ids;
  }

  /// Attaches a vine to a row, sliding it onto the nearest point.
  ///
  /// Returns the distance it moved, so a tool can decline to snap something
  /// the user was not aiming at.
  Future<double> snapVineToRow({
    required String vineId,
    required String rowId,
    DateTime? now,
  }) async {
    final path = await pathOf(rowId);
    if (path == null) {
      throw StateError('Row $rowId has no path to snap to.');
    }

    final vine = await _requireVine(vineId);
    final from = Offset(vine.x ?? 0, vine.y ?? 0);
    final nearest = path.closestTo(from);
    final timestamp = now ?? DateTime.now();

    // Address first, so the vine is numbered in its new row before it moves.
    await _labels.assignToRow(vineId: vineId, rowId: rowId, now: timestamp);

    await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
      VinesCompanion(
        pathOffset: Value(nearest.offset),
        x: Value(nearest.point.dx),
        y: Value(nearest.point.dy),
        updatedAt: Value(timestamp),
      ),
    );

    return nearest.distance;
  }

  /// Detaches a vine from its row, leaving it where it is on screen.
  Future<void> unsnapVine(String vineId, {DateTime? now}) =>
      _labels.detachFromRow(vineId: vineId, now: now);

  /// Moves a vine.
  ///
  /// A **snapped** vine slides along its row to the nearest point, keeping the
  /// invariant that it is physically on the row. Dragging it sideways moves it
  /// along the row rather than off it; detaching is an explicit action, so a
  /// clumsy drag can never silently break the row's membership.
  ///
  /// A **free** vine goes exactly where it is put.
  Future<void> moveVine(String vineId, Offset position, {DateTime? now}) async {
    final vine = await _requireVine(vineId);
    final timestamp = now ?? DateTime.now();

    if (vine.rowId == null) {
      await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
        VinesCompanion(
          x: Value(position.dx),
          y: Value(position.dy),
          updatedAt: Value(timestamp),
        ),
      );
      return;
    }

    final path = await pathOf(vine.rowId!);
    if (path == null) {
      // Snapped to a row that was never drawn: nothing to slide along, so
      // treat it as free rather than refusing to move.
      await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
        VinesCompanion(
          x: Value(position.dx),
          y: Value(position.dy),
          updatedAt: Value(timestamp),
        ),
      );
      return;
    }

    final nearest = path.closestTo(position);
    await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
      VinesCompanion(
        pathOffset: Value(nearest.offset),
        x: Value(nearest.point.dx),
        y: Value(nearest.point.dy),
        updatedAt: Value(timestamp),
      ),
    );
  }

  /// Retires a vine, keeping its history (decision D7).
  Future<void> retireVine(
    String vineId, {
    required VineStatusChange change,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
      VinesCompanion(
        status: Value(change.status),
        endedAt: Value(timestamp),
        updatedAt: Value(timestamp),
      ),
    );
  }

  /// Every vine in a project, for the canvas to index and paint.
  Future<List<Vine>> vinesInProject(String projectId) {
    return (_db.select(_db.vines)
          ..where((v) => v.projectId.equals(projectId) & v.deletedAt.isNull()))
        .get();
  }

  /// Live-updating vines, so the canvas follows edits without manual refresh.
  Stream<List<Vine>> watchVinesInProject(String projectId) {
    return (_db.select(_db.vines)
          ..where((v) => v.projectId.equals(projectId) & v.deletedAt.isNull()))
        .watch();
  }

  Future<List<VineRow>> rowsInProject(String projectId) {
    return (_db.select(_db.vineRows)
          ..where((r) => r.projectId.equals(projectId) & r.deletedAt.isNull())
          ..orderBy([(r) => OrderingTerm.asc(r.sortOrder)]))
        .get();
  }

  Stream<List<VineRow>> watchRowsInProject(String projectId) {
    return (_db.select(_db.vineRows)
          ..where((r) => r.projectId.equals(projectId) & r.deletedAt.isNull())
          ..orderBy([(r) => OrderingTerm.asc(r.sortOrder)]))
        .watch();
  }

  Future<Vine> _requireVine(String vineId) async {
    final vine =
        await (_db.select(_db.vines)
              ..where((v) => v.id.equals(vineId) & v.deletedAt.isNull()))
            .getSingleOrNull();
    if (vine == null) throw StateError('Vine $vineId does not exist.');
    return vine;
  }
}

/// How a vine leaves active service, per plan section 6.4.
enum VineStatusChange {
  /// Died or was pulled. The position stays as an empty slot, available for a
  /// replant.
  removed(VineStatus.removed),

  /// The position exists in the layout but has never held a vine.
  missing(VineStatus.missing);

  const VineStatusChange(this.status);
  final VineStatus status;
}
