import 'dart:ui' show Offset, Rect;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../geometry/shapes.dart';
import '../models/enums.dart';

/// Works out which container objects each plant falls inside, and records it.
///
/// A container field puts a value on **every** plant, blank or not, and that
/// value comes from geometry rather than from anything the user types: a plant
/// inside Block 2's polygon is in Block 2. That is what makes the map and the
/// data incapable of disagreeing.
///
/// **Membership is not the carrier.** `plants.carrierId` is the one polyline a
/// plant is physically snapped to and the only thing `pathOffset` is measured
/// along. Membership is many, and a plant can be inside Block 2 and within
/// tolerance of Terrace 3 while sliding along only Row 12.
class MembershipService {
  MembershipService(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  /// Layout pixels. How close a plant must be to a container polyline to count
  /// as on it. Overridable per field via `field_defs.tolerance`.
  ///
  /// A polygon has an interior, so "inside" is exact. A line does not, so "on"
  /// is a judgement about how accurately somebody tapped -- hence a tolerance
  /// for one and not the other.
  static const defaultTolerance = 8.0;

  /// Recomputes memberships and writes only what changed.
  ///
  /// **Call inside a gesture**, never outside. The capture triggers turn the
  /// diff into undo, so a reconcile run outside an operation is silently
  /// unundoable -- a boundary edit whose membership changes could not be taken
  /// back.
  ///
  /// Narrow it with [plantIds] or [objectIds] when the caller knows what moved;
  /// null means everything. Returns how many membership rows changed.
  Future<int> reconcile({
    required String projectId,
    Set<String>? plantIds,
    Set<String>? objectIds,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();

    final containers = await _containersIn(projectId, objectIds);
    // Every plant still has to be considered even when no container exists:
    // deleting the last block must clear the memberships it created.
    final plants = await _plantsIn(projectId, plantIds);
    if (plants.isEmpty) return 0;

    final wanted = _derive(plants, containers);
    final existing = await _existingFor(
      projectId,
      plantIds: plantIds,
      objectIds: objectIds,
    );

    var changed = 0;

    // Written as a diff rather than delete-all-then-reinsert. An unchanged
    // membership must produce no journal row, or dragging one plant would
    // capture 3,000 no-op captures and bury the operation that mattered.
    for (final key in wanted.difference(existing.keys.toSet())) {
      await _db
          .into(_db.plantMemberships)
          .insert(
            PlantMembershipsCompanion.insert(
              id: _uuid.v4(),
              plantId: key.plantId,
              objectId: key.objectId,
              fieldDefId: key.fieldDefId,
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      changed++;
    }

    for (final entry in existing.entries) {
      if (wanted.contains(entry.key)) continue;
      await (_db.delete(
        _db.plantMemberships,
      )..where((m) => m.id.equals(entry.value))).go();
      changed++;
    }

    return changed;
  }

  /// Container values as geometry would have them, **without writing**.
  ///
  /// Returns plant id -> field id -> the holding object's name, which is exactly
  /// the container half of `IdentifierData.values`. Feed it to
  /// `LabelService.dataFor(containerValues: ...)` to render identifiers for a
  /// world that does not exist yet.
  ///
  /// [geometryOverride] answers the question that makes a boundary-edit prompt
  /// possible: *if this block's outline moved here, what would every plant be
  /// called?* An entry mapping to null takes the object out of consideration
  /// entirely, which is how deleting one is previewed.
  ///
  /// [positionOverride] asks the same question from the other side -- *if this
  /// plant were dragged there, would it end up in a different block?* Both are
  /// needed together for one common gesture: dragging a line translates its
  /// shape **and** carries its plants, and each half can change containment
  /// independently of the other.
  ///
  /// Deliberately not a reconcile with a rollback. Rolling back would still fire
  /// the capture triggers, so a preview the user then cancelled would sit in the
  /// undo journal as an operation that happened -- and in label history as a
  /// rename that never took place.
  Future<Map<String, Map<String, String>>> previewContainerValues({
    required String projectId,
    Map<String, Shape?> geometryOverride = const {},
    Map<String, Offset> positionOverride = const {},
  }) async {
    final containers = await _containersIn(
      projectId,
      null,
      geometryOverride: geometryOverride,
    );
    final plants = [
      for (final plant in await _plantsIn(projectId, null))
        positionOverride.containsKey(plant.id)
            ? _Plant(plant.id, positionOverride[plant.id]!)
            : plant,
    ];

    final labels = {for (final c in containers) c.id: c.label};
    final values = <String, Map<String, String>>{};
    for (final key in _derive(plants, containers)) {
      final label = labels[key.objectId];
      if (label != null) (values[key.plantId] ??= {})[key.fieldDefId] = label;
    }
    return values;
  }

  /// The container objects to test against, with their geometry resolved.
  Future<List<_Container>> _containersIn(
    String projectId,
    Set<String>? objectIds, {
    Map<String, Shape?> geometryOverride = const {},
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT o.id AS id, o.field_def_id AS field_def_id, '
          '       o.label AS label, o.geometry AS geometry, '
          '       f.draw_type AS draw_type, f.tolerance AS tolerance '
          'FROM map_objects o '
          'JOIN field_defs f ON f.id = o.field_def_id '
          'WHERE o.project_id = ?1 '
          '  AND o.deleted_at IS NULL AND f.deleted_at IS NULL '
          // Non-containers contribute nothing: a road crossing the vineyard
          // must not put a field on a single plant.
          '  AND f.is_container = 1',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.mapObjects, _db.fieldDefs},
        )
        .get();

    final containers = <_Container>[];
    for (final r in rows) {
      final id = r.read<String>('id');
      if (objectIds != null && !objectIds.contains(id)) continue;

      final drawType = DrawType.values.asNameMap()[r.read<String>('draw_type')];
      // A point contains nothing, so it is never a container. FieldDefsDao
      // refuses the combination; this is the belt to that pair of braces.
      if (drawType == null || drawType == DrawType.point) continue;

      // `containsKey` rather than a null check, so an override *to* null means
      // "pretend this object covers nothing" instead of "no override given".
      // An object with no geometry at all is skipped by the same line, which is
      // why the SQL above no longer filters on it.
      final shape = geometryOverride.containsKey(id)
          ? geometryOverride[id]
          : Shape.tryParse(r.readNullable<String>('geometry'), drawType);
      if (shape == null) continue;

      final tolerance = r.readNullable<double>('tolerance') ?? defaultTolerance;
      containers.add(
        _Container(
          id: id,
          fieldDefId: r.read<String>('field_def_id'),
          label: r.read<String>('label'),
          shape: shape,
          tolerance: tolerance,
          // Inflated by the tolerance so the cheap rejection below cannot
          // discard a plant that is within reach of the line.
          reach: shape.bounds.inflate(tolerance),
        ),
      );
    }
    return containers;
  }

  Future<List<_Plant>> _plantsIn(
    String projectId,
    Set<String>? plantIds,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT id, x, y FROM plants '
          'WHERE project_id = ?1 AND deleted_at IS NULL '
          '  AND x IS NOT NULL AND y IS NOT NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.plants},
        )
        .get();

    return [
      for (final r in rows)
        if (plantIds == null || plantIds.contains(r.read<String>('id')))
          _Plant(
            r.read<String>('id'),
            Offset(r.read<double>('x'), r.read<double>('y')),
          ),
    ];
  }

  /// The memberships geometry says should exist.
  Set<_Key> _derive(List<_Plant> plants, List<_Container> containers) {
    final wanted = <_Key>{};

    for (final container in containers) {
      for (final plant in plants) {
        // Bounds first. At 3,025 plants against 75 lines this is the
        // difference between near-linear and ~900k segment evaluations.
        if (!container.reach.contains(plant.at)) continue;
        if (!container.holds(plant.at)) continue;

        wanted.add(
          _Key(
            plantId: plant.id,
            objectId: container.id,
            fieldDefId: container.fieldDefId,
          ),
        );
      }
    }
    return wanted;
  }

  /// Membership rows already stored, keyed the same way, mapped to their ids.
  Future<Map<_Key, String>> _existingFor(
    String projectId, {
    Set<String>? plantIds,
    Set<String>? objectIds,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT m.id AS id, m.plant_id AS plant_id, m.object_id AS object_id, '
          '       m.field_def_id AS field_def_id '
          'FROM plant_memberships m '
          'JOIN plants v ON v.id = m.plant_id '
          'WHERE v.project_id = ?1',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.plantMemberships, _db.plants},
        )
        .get();

    final existing = <_Key, String>{};
    for (final r in rows) {
      final key = _Key(
        plantId: r.read<String>('plant_id'),
        objectId: r.read<String>('object_id'),
        fieldDefId: r.read<String>('field_def_id'),
      );
      // Scoped the same way the derivation was, or a narrow reconcile would
      // delete memberships it never recomputed.
      if (plantIds != null && !plantIds.contains(key.plantId)) continue;
      if (objectIds != null && !objectIds.contains(key.objectId)) continue;
      existing[key] = r.read<String>('id');
    }
    return existing;
  }
}

class _Plant {
  const _Plant(this.id, this.at);
  final String id;
  final Offset at;
}

class _Container {
  const _Container({
    required this.id,
    required this.fieldDefId,
    required this.label,
    required this.shape,
    required this.tolerance,
    required this.reach,
  });

  final String id;
  final String fieldDefId;

  /// Carried so a preview can report the *value* a plant would take, not just
  /// which object would hold it.
  final String label;

  final Shape shape;
  final double tolerance;
  final Rect reach;

  bool holds(Offset point) => switch (shape) {
    final PolygonShape polygon => pointInPolygon(point, polygon.vertices),
    // Deliberately *not* "is this my carrier". A plant near a container
    // polyline belongs to it whether or not it slides along it, which is what
    // lets Row and Terrace both hold the same plant.
    final PolylineShape line =>
      line.path.closestTo(point).distance <= tolerance,
    PointShape() => false,
  };
}

/// A membership, identified by what it relates rather than by its row id.
class _Key {
  const _Key({
    required this.plantId,
    required this.objectId,
    required this.fieldDefId,
  });

  final String plantId;
  final String objectId;
  final String fieldDefId;

  @override
  bool operator ==(Object other) =>
      other is _Key &&
      other.plantId == plantId &&
      other.objectId == objectId &&
      other.fieldDefId == fieldDefId;

  @override
  int get hashCode => Object.hash(plantId, objectId, fieldDefId);
}
