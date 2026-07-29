import 'dart:ui' show Offset;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/label_service.dart';
import '../../data/membership_service.dart';
import '../../geometry/polyline.dart';
import '../../geometry/shapes.dart';
import '../../models/enums.dart';
import '../database.dart';

/// Creates and edits the physical layout: drawn objects and plant positions.
///
/// **The invariant this class exists to maintain:** a plant with a non-null
/// `carrierId` is physically on that polyline. Its `x`/`y` is always
/// `path.pointAt(pathOffset)`, never anything else. Every operation that could
/// break that -- reshaping a line, moving one, dragging a plant -- restores it
/// before returning.
///
/// Identifiers are not this class's concern; [LabelService] owns those, and
/// container membership belongs to [MembershipService]. Layout moves things.
class LayoutDao {
  LayoutDao(this._db, this._labels, this._memberships, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final LabelService _labels;
  final MembershipService _memberships;
  final Uuid _uuid;

  // ----------------------------------------------------------------- objects

  /// Draws a new instance of an object field -- a row, a block, a road.
  Future<String> createObject({
    required String projectId,
    required String fieldDefId,
    required String label,
    Shape? geometry,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db.transaction(() async {
      await _db
          .into(_db.mapObjects)
          .insert(
            MapObjectsCompanion.insert(
              id: id,
              projectId: projectId,
              fieldDefId: fieldDefId,
              label: label.trim(),
              geometry: Value(geometry?.toJson()),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      // A new container immediately claims whatever falls inside it.
      if (geometry != null) {
        await _memberships.reconcile(
          projectId: projectId,
          objectIds: {id},
          now: timestamp,
        );
      }
    });

    return id;
  }

  /// One object's geometry, or null if it has not been drawn.
  Future<Shape?> shapeOf(String objectId) async {
    final row = await _db
        .customSelect(
          'SELECT o.geometry AS geometry, f.draw_type AS draw_type '
          'FROM map_objects o '
          'JOIN field_defs f ON f.id = o.field_def_id '
          'WHERE o.id = ?1 AND o.deleted_at IS NULL',
          variables: [Variable<String>(objectId)],
          readsFrom: {_db.mapObjects, _db.fieldDefs},
        )
        .getSingleOrNull();
    if (row == null) return null;

    final drawType = DrawType.values.asNameMap()[row.read<String>('draw_type')];
    if (drawType == null) return null;
    return Shape.tryParse(row.readNullable<String>('geometry'), drawType);
  }

  /// The path of an object plants can be carried by, or null if it is not a
  /// line or has not been drawn.
  Future<Polyline?> carrierPathOf(String objectId) async {
    final shape = await shapeOf(objectId);
    return shape is PolylineShape ? shape.path : null;
  }

  /// Replaces an object's shape.
  ///
  /// Carried plants keep their arc-length offset, so extending the far end of a
  /// line leaves every existing plant exactly where it was. Re-projecting their
  /// x/y onto the new path instead would nudge each one slightly on every edit,
  /// and the drift compounds.
  Future<void> updateObjectGeometry(
    String objectId,
    Shape geometry, {
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final projectId = await _projectOf(objectId);
    if (projectId == null) return;

    await _db.transaction(() async {
      await (_db.update(
        _db.mapObjects,
      )..where((o) => o.id.equals(objectId))).write(
        MapObjectsCompanion(
          geometry: Value(geometry.toJson()),
          updatedAt: Value(timestamp),
        ),
      );

      if (geometry is PolylineShape) {
        await _repositionCarried(objectId, geometry.path, timestamp);
      }

      // Reshaping a boundary sweeps plants in and out. Scoped to the whole
      // project rather than to this object, because a plant that *left* is no
      // longer found by looking at what this object now covers.
      await _memberships.reconcile(projectId: projectId, now: timestamp);
    });
  }

  /// Translates an object and everything it carries.
  Future<void> moveObject(
    String objectId,
    Offset delta, {
    DateTime? now,
  }) async {
    final shape = await shapeOf(objectId);
    if (shape == null) return;

    final moved = switch (shape) {
      final PolylineShape s => PolylineShape(
        Polyline([for (final p in s.path.points) p + delta]),
      ),
      final PolygonShape s => PolygonShape([
        for (final v in s.vertices) v + delta,
      ]),
      final PointShape s => PointShape(s.at + delta),
    };

    // Offsets are unchanged by a translation, so carried plants follow exactly.
    await updateObjectGeometry(objectId, moved, now: now);
  }

  /// Soft-deletes an object.
  ///
  /// Plants it carried keep their x/y and simply lose their carrier -- deleting
  /// a line should orphan its plants, not destroy them along with their entire
  /// recorded history.
  Future<void> deleteObject(String objectId, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final projectId = await _projectOf(objectId);
    if (projectId == null) return;

    await _db.transaction(() async {
      await (_db.update(
        _db.mapObjects,
      )..where((o) => o.id.equals(objectId))).write(
        MapObjectsCompanion(
          deletedAt: Value(timestamp),
          updatedAt: Value(timestamp),
        ),
      );

      // Explicit rather than relying on the foreign key, because a soft delete
      // fires no cascade at all: the row is still there.
      await (_db.update(
        _db.plants,
      )..where((v) => v.carrierId.equals(objectId))).write(
        PlantsCompanion(
          carrierId: const Value(null),
          pathOffset: const Value(null),
          updatedAt: Value(timestamp),
        ),
      );

      await _memberships.reconcile(projectId: projectId, now: timestamp);
    });
  }

  /// The same-type object [shape] would overlap, or null.
  ///
  /// Called by the naming sheet before it writes, never mid-stroke: refusing a
  /// stroke as it is drawn would throw away twelve taps.
  Future<({String objectId, String label})?> checkOverlap({
    required String fieldDefId,
    required Shape shape,
    String? ignoringObjectId,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT o.id AS id, o.label AS label, o.geometry AS geometry, '
          '       f.draw_type AS draw_type '
          'FROM map_objects o '
          'JOIN field_defs f ON f.id = o.field_def_id '
          'WHERE o.field_def_id = ?1 AND o.deleted_at IS NULL '
          '  AND o.geometry IS NOT NULL',
          variables: [Variable<String>(fieldDefId)],
          readsFrom: {_db.mapObjects, _db.fieldDefs},
        )
        .get();

    final others = <ShapeRef>[];
    for (final r in rows) {
      final id = r.read<String>('id');
      // An object being reshaped does not overlap itself.
      if (id == ignoringObjectId) continue;

      final drawType = DrawType.values.asNameMap()[r.read<String>('draw_type')];
      if (drawType == null) continue;
      final other = Shape.tryParse(
        r.readNullable<String>('geometry'),
        drawType,
      );
      if (other == null) continue;

      others.add((id: id, label: r.read<String>('label'), shape: other));
    }

    return findOverlap(shape, others);
  }

  Future<List<MapObject>> objectsInProject(String projectId) {
    return (_db.select(_db.mapObjects)
          ..where((o) => o.projectId.equals(projectId) & o.deletedAt.isNull())
          ..orderBy([(o) => OrderingTerm.asc(o.sortOrder)]))
        .get();
  }

  Stream<List<MapObject>> watchObjectsInProject(String projectId) {
    return (_db.select(_db.mapObjects)
          ..where((o) => o.projectId.equals(projectId) & o.deletedAt.isNull())
          ..orderBy([(o) => OrderingTerm.asc(o.sortOrder)]))
        .watch();
  }

  Future<String?> _projectOf(String objectId) async {
    final row = await (_db.select(
      _db.mapObjects,
    )..where((o) => o.id.equals(objectId))).getSingleOrNull();
    return row?.projectId;
  }

  /// Recomputes x/y for every carried plant from its stored offset.
  Future<void> _repositionCarried(
    String objectId,
    Polyline path,
    DateTime timestamp,
  ) async {
    final plants = await (_db.select(
      _db.plants,
    )..where((v) => v.carrierId.equals(objectId) & v.deletedAt.isNull())).get();

    for (final plant in plants) {
      // A plant with no offset yet -- placed before the line was drawn -- gets
      // one by projecting its current position onto the path.
      final offset =
          plant.pathOffset ??
          (plant.x != null && plant.y != null
              ? path.closestTo(Offset(plant.x!, plant.y!)).offset
              : 0.0);

      final point = path.pointAt(offset);
      await (_db.update(_db.plants)..where((v) => v.id.equals(plant.id))).write(
        PlantsCompanion(
          pathOffset: Value(offset),
          x: Value(point.dx),
          y: Value(point.dy),
          updatedAt: Value(timestamp),
        ),
      );
    }
  }

  // ------------------------------------------------------------------ plants

  /// Places a free-standing plant at a point.
  Future<String> createPlant({
    required String projectId,
    required Offset position,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db.transaction(() async {
      final number = await _labels.nextPlantNumber(projectId: projectId);
      await _db
          .into(_db.plants)
          .insert(
            PlantsCompanion.insert(
              id: id,
              projectId: projectId,
              positionIdx: number,
              x: Value(position.dx),
              y: Value(position.dy),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await _memberships.reconcile(
        projectId: projectId,
        plantIds: {id},
        now: timestamp,
      );
    });

    return id;
  }

  /// Creates plants along a carrier at the given arc-length offsets.
  ///
  /// Existing plants keep their numbers; new ones fill from the lowest free
  /// number upward. That is what makes planting a line in two passes work --
  /// the near side of an obstacle, then the far side -- giving contiguous
  /// numbers with a gap in space rather than a gap in the numbering.
  Future<List<String>> placePlantsAlongCarrier({
    required String carrierId,
    required List<double> offsets,
    DateTime? now,
  }) async {
    if (offsets.isEmpty) return const [];

    final path = await carrierPathOf(carrierId);
    if (path == null) {
      throw StateError('Object $carrierId has no line to place plants along.');
    }

    final projectId = await _projectOf(carrierId);
    if (projectId == null) return const [];

    final timestamp = now ?? DateTime.now();
    final ids = <String>[];

    await _db.transaction(() async {
      final used = <int>{
        for (final v
            in await (_db.select(_db.plants)..where(
                  (v) => v.carrierId.equals(carrierId) & v.deletedAt.isNull(),
                ))
                .get())
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
            .into(_db.plants)
            .insert(
              PlantsCompanion.insert(
                id: id,
                projectId: projectId,
                carrierId: Value(carrierId),
                positionIdx: next,
                x: Value(point.dx),
                y: Value(point.dy),
                pathOffset: Value(offset),
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            );
      }

      await _memberships.reconcile(
        projectId: projectId,
        plantIds: ids.toSet(),
        now: timestamp,
      );
    });

    return ids;
  }

  /// Attaches a plant to a carrier, sliding it onto the nearest point and
  /// renumbering it into that carrier's sequence.
  ///
  /// Returns the distance it moved, so a tool can decline to snap something the
  /// user was not aiming at.
  Future<double> snapPlantToCarrier({
    required String plantId,
    required String carrierId,
    DateTime? now,
  }) async {
    final plant = await _requirePlant(plantId);
    final number = await _labels.nextPlantNumber(
      projectId: plant.projectId,
      carrierId: carrierId,
    );
    return _snap(plantId, carrierId, number, now);
  }

  /// Slides a plant onto a carrier it has **already been numbered into**.
  ///
  /// The geometry half of [snapPlantToCarrier] without the numbering half.
  /// Insert has to number the plant first -- the whole point is that the user
  /// chose where it goes -- and renumbering afterwards would silently undo that.
  Future<double> snapPlantToCarrierKeepingNumber({
    required String plantId,
    required String carrierId,
    DateTime? now,
  }) async {
    final plant = await _requirePlant(plantId);
    return _snap(plantId, carrierId, plant.positionIdx, now);
  }

  Future<double> _snap(
    String plantId,
    String carrierId,
    int number,
    DateTime? now,
  ) async {
    final path = await carrierPathOf(carrierId);
    if (path == null) {
      throw StateError('Object $carrierId has no line to snap to.');
    }

    final plant = await _requirePlant(plantId);
    final nearest = path.closestTo(Offset(plant.x ?? 0, plant.y ?? 0));
    final timestamp = now ?? DateTime.now();

    await _db.transaction(() async {
      await (_db.update(_db.plants)..where((v) => v.id.equals(plantId))).write(
        PlantsCompanion(
          carrierId: Value(carrierId),
          positionIdx: Value(number),
          pathOffset: Value(nearest.offset),
          x: Value(nearest.point.dx),
          y: Value(nearest.point.dy),
          updatedAt: Value(timestamp),
        ),
      );
      await _memberships.reconcile(
        projectId: plant.projectId,
        plantIds: {plantId},
        now: timestamp,
      );
    });

    return nearest.distance;
  }

  /// Detaches a plant from its carrier, leaving it where it is on screen.
  Future<void> unsnapPlant(String plantId, {DateTime? now}) async {
    final plant = await _requirePlant(plantId);
    final timestamp = now ?? DateTime.now();

    await _db.transaction(() async {
      final number = await _labels.nextPlantNumber(projectId: plant.projectId);
      await (_db.update(_db.plants)..where((v) => v.id.equals(plantId))).write(
        PlantsCompanion(
          carrierId: const Value(null),
          pathOffset: const Value(null),
          positionIdx: Value(number),
          updatedAt: Value(timestamp),
        ),
      );
    });
  }

  /// Moves a plant.
  ///
  /// A **carried** plant slides along its line to the nearest point, keeping
  /// the invariant that it is physically on it. Dragging it sideways moves it
  /// along the line rather than off it; detaching is an explicit action, so a
  /// clumsy drag can never silently break a plant's membership of its row.
  ///
  /// A **free** plant goes exactly where it is put.
  Future<void> movePlant(
    String plantId,
    Offset position, {
    DateTime? now,
  }) async {
    final plant = await _requirePlant(plantId);
    final timestamp = now ?? DateTime.now();

    final path = plant.carrierId == null
        ? null
        : await carrierPathOf(plant.carrierId!);

    await _db.transaction(() async {
      if (path == null) {
        // Free, or carried by something never drawn: nothing to slide along,
        // so put it where it was dropped rather than refusing to move it.
        await (_db.update(
          _db.plants,
        )..where((v) => v.id.equals(plantId))).write(
          PlantsCompanion(
            x: Value(position.dx),
            y: Value(position.dy),
            updatedAt: Value(timestamp),
          ),
        );
      } else {
        final nearest = path.closestTo(position);
        await (_db.update(
          _db.plants,
        )..where((v) => v.id.equals(plantId))).write(
          PlantsCompanion(
            pathOffset: Value(nearest.offset),
            x: Value(nearest.point.dx),
            y: Value(nearest.point.dy),
            updatedAt: Value(timestamp),
          ),
        );
      }

      // Moving a plant can carry it across a boundary.
      await _memberships.reconcile(
        projectId: plant.projectId,
        plantIds: {plantId},
        now: timestamp,
      );
    });
  }

  /// Retires a plant, keeping its history (decision D7).
  Future<void> retirePlant(
    String plantId, {
    required PlantStatusChange change,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(_db.plants)..where((v) => v.id.equals(plantId))).write(
      PlantsCompanion(
        status: Value(change.status),
        endedAt: Value(timestamp),
        updatedAt: Value(timestamp),
      ),
    );
  }

  /// Retires a plant and plants a successor in its place.
  ///
  /// The successor takes the same position, carrier, offset and number -- so
  /// the identifier is continuous -- and a fresh UUID, so the dead plant keeps
  /// its entire history rather than having it reattributed to a plant that was
  /// never there for it.
  ///
  /// [inheritFieldIds] names the static fields copied forward: variety yes,
  /// plant date no, rootstock ask.
  Future<String> replacePlant({
    required String plantId,
    Set<String> inheritFieldIds = const {},
    DateTime? now,
  }) async {
    final old = await _requirePlant(plantId);
    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db.transaction(() async {
      await retirePlant(
        plantId,
        change: PlantStatusChange.removed,
        now: timestamp,
      );

      await _db
          .into(_db.plants)
          .insert(
            PlantsCompanion.insert(
              id: id,
              projectId: old.projectId,
              carrierId: Value(old.carrierId),
              positionIdx: old.positionIdx,
              x: Value(old.x),
              y: Value(old.y),
              pathOffset: Value(old.pathOffset),
              plantedAt: Value(timestamp),
              predecessorId: Value(plantId),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

      for (final fieldDefId in inheritFieldIds) {
        final current = await _db
            .customSelect(
              'SELECT value FROM field_events '
              'WHERE plant_id = ?1 AND field_def_id = ?2 AND deleted_at IS NULL '
              'ORDER BY observed_at DESC, recorded_at DESC, rowid DESC LIMIT 1',
              variables: [
                Variable<String>(plantId),
                Variable<String>(fieldDefId),
              ],
              readsFrom: {_db.fieldEvents},
            )
            .getSingleOrNull();
        final value = current?.readNullable<String>('value');
        if (value == null) continue;

        await _db
            .into(_db.fieldEvents)
            .insert(
              FieldEventsCompanion.insert(
                id: _uuid.v4(),
                plantId: id,
                fieldDefId: fieldDefId,
                value: Value(value),
                observedAt: timestamp,
                recordedAt: timestamp,
              ),
            );
      }

      await _memberships.reconcile(
        projectId: old.projectId,
        plantIds: {id},
        now: timestamp,
      );
    });

    return id;
  }

  /// Every plant in a project, for the canvas to index and paint.
  Future<List<Plant>> plantsInProject(String projectId) {
    return (_db.select(_db.plants)
          ..where((v) => v.projectId.equals(projectId) & v.deletedAt.isNull()))
        .get();
  }

  /// Live-updating plants, so the canvas follows edits without manual refresh.
  Stream<List<Plant>> watchPlantsInProject(String projectId) {
    return (_db.select(_db.plants)
          ..where((v) => v.projectId.equals(projectId) & v.deletedAt.isNull()))
        .watch();
  }

  /// One plant by id, or null.
  Future<Plant?> plantById(String plantId) {
    return (_db.select(_db.plants)
          ..where((v) => v.id.equals(plantId) & v.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<Plant> _requirePlant(String plantId) async {
    final plant = await plantById(plantId);
    if (plant == null) throw StateError('Plant $plantId does not exist.');
    return plant;
  }
}

/// How a plant leaves active service, per plan section 6.4.
enum PlantStatusChange {
  /// Died or was pulled. The position stays as an empty slot, available for a
  /// replant.
  removed(PlantStatus.removed),

  /// The position exists in the layout but has never held a plant.
  missing(PlantStatus.missing);

  const PlantStatusChange(this.status);
  final PlantStatus status;
}
