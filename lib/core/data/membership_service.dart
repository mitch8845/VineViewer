import 'dart:math' as math;
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

    // Every container is loaded even for a narrow reconcile. The object scope
    // decides which *plants* are recomputed, not which containers they are
    // tested against -- see below.
    final containers = await _containersIn(projectId, null);
    // Every plant still has to be considered even when no container exists:
    // deleting the last block must clear the memberships it created.
    var plants = await _plantsIn(projectId, plantIds);
    if (plants.isEmpty) return 0;

    final Set<_Key> wanted;
    final Map<_Key, String> existing;

    if (objectIds == null) {
      wanted = _derive(plants, containers);
      existing = await _existingFor(projectId, plantIds: plantIds);
    } else {
      // **An object-scoped reconcile cannot look at the scoped objects alone.**
      //
      // The carrier-wins tie-break is a judgement *between* same-field lines,
      // so deriving against Row 2 by itself sees no contest and hands Row 2
      // every plant within its tolerance -- including the ones snapped to Row 1
      // six pixels away, which then hold two Row values. The reverse happens
      // too: a plant leaving Row 2 may now uncontestedly belong to Row 1, which
      // a Row-2-only pass would never add.
      //
      // So the scope becomes *plants and fields* rather than objects: every
      // plant the scoped objects hold now or held before, recomputed against
      // every container of the scoped objects' fields. That is exactly what a
      // project-wide reconcile would decide for those memberships, at a cost
      // proportional to the plants touched rather than to the project.
      final scoped = [
        for (final c in containers)
          if (objectIds.contains(c.id)) c,
      ];
      final stored = await _existingFor(projectId, plantIds: plantIds);

      final affected = <String>{
        for (final key in _deriveRaw(plants, scoped)) key.plantId,
        for (final key in stored.keys)
          if (objectIds.contains(key.objectId)) key.plantId,
      };
      // The field of an object that is not a container -- or no longer exists
      // -- is still in scope, so its leftover memberships are cleared.
      final fields = <String>{
        for (final c in scoped) c.fieldDefId,
        for (final key in stored.keys)
          if (objectIds.contains(key.objectId)) key.fieldDefId,
      };

      plants = [
        for (final p in plants)
          if (affected.contains(p.id)) p,
      ];
      wanted = _derive(plants, [
        for (final c in containers)
          if (fields.contains(c.fieldDefId)) c,
      ]);
      existing = {
        for (final e in stored.entries)
          if (affected.contains(e.key.plantId) &&
              fields.contains(e.key.fieldDefId))
            e.key: e.value,
      };
    }

    // Written as a diff rather than delete-all-then-reinsert. An unchanged
    // membership must produce no journal row, or dragging one plant would
    // capture 3,000 no-op captures and bury the operation that mattered.
    final gained = wanted.difference(existing.keys.toSet());
    final lost = [
      for (final entry in existing.entries)
        if (!wanted.contains(entry.key)) entry.value,
    ];
    if (gained.isEmpty && lost.isEmpty) return 0;

    // **Batched, in two statements rather than a few thousand.**
    //
    // A boundary edit that sweeps a whole block is thousands of membership
    // changes, and issuing them one at a time measured 446ms for 3,000 rows on a
    // desktop -- seconds on the tablet, for dragging one corner. Nearly all of it
    // was per-statement overhead rather than work.
    //
    // The capture triggers still fire **per row**, because SQLite triggers are
    // FOR EACH ROW. That is the point: the operation stays undoable in full, and
    // batching changes only how the statements are delivered.
    await _db.batch((batch) {
      if (gained.isNotEmpty) {
        batch.insertAll(_db.plantMemberships, [
          for (final key in gained)
            PlantMembershipsCompanion.insert(
              id: _uuid.v4(),
              plantId: key.plantId,
              objectId: key.objectId,
              fieldDefId: key.fieldDefId,
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
        ]);
      }
      // Chunked, because SQLite caps the number of variables in one statement
      // (999 by default) and a full-block sweep is well past that.
      for (var i = 0; i < lost.length; i += _deleteChunk) {
        final chunk = lost.sublist(i, math.min(i + _deleteChunk, lost.length));
        batch.deleteWhere(_db.plantMemberships, (m) => m.id.isIn(chunk));
      }
    });

    return gained.length + lost.length;
  }

  /// Ids per `DELETE ... WHERE id IN (...)`, kept clear of SQLite's default
  /// 999-variable limit.
  static const _deleteChunk = 500;

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
  ///
  /// [fieldOverride] asks it of the schema: *if Block stopped being a
  /// container, or Row's tolerance doubled, what would every plant be called?*
  /// Keyed by field id; a field absent from the map keeps its stored settings.
  Future<Map<String, Map<String, String>>> previewContainerValues({
    required String projectId,
    Map<String, Shape?> geometryOverride = const {},
    Map<String, Offset> positionOverride = const {},
    Map<String, ContainerSettings> fieldOverride = const {},
  }) async {
    final containers = await _containersIn(
      projectId,
      null,
      geometryOverride: geometryOverride,
      fieldOverride: fieldOverride,
    );
    final plants = [
      for (final plant in await _plantsIn(projectId, null))
        positionOverride.containsKey(plant.id)
            // The carrier is carried through: it is what breaks a same-field tie,
            // and a preview that dropped it would disagree with the reconcile it
            // is meant to be predicting.
            ? _Plant(
                plant.id,
                positionOverride[plant.id]!,
                carrierId: plant.carrierId,
              )
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
    Map<String, ContainerSettings> fieldOverride = const {},
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT o.id AS id, o.field_def_id AS field_def_id, '
          '       o.label AS label, o.geometry AS geometry, '
          '       f.draw_type AS draw_type, f.tolerance AS tolerance, '
          '       f.is_container AS is_container '
          'FROM map_objects o '
          'JOIN field_defs f ON f.id = o.field_def_id '
          'WHERE o.project_id = ?1 '
          '  AND o.deleted_at IS NULL AND f.deleted_at IS NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.mapObjects, _db.fieldDefs},
        )
        .get();

    final containers = <_Container>[];
    for (final r in rows) {
      final id = r.read<String>('id');
      if (objectIds != null && !objectIds.contains(id)) continue;

      final fieldDefId = r.read<String>('field_def_id');
      final override = fieldOverride[fieldDefId];
      // Non-containers contribute nothing: a road crossing the vineyard must
      // not put a field on a single plant. Filtered here rather than in SQL so
      // a preview can ask about a field that is not a container *yet*.
      if (!(override?.isContainer ?? r.read<bool>('is_container'))) continue;

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

      final tolerance =
          (override != null
              ? override.tolerance
              : r.readNullable<double>('tolerance')) ??
          defaultTolerance;
      containers.add(
        _Container(
          id: id,
          fieldDefId: fieldDefId,
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
          'SELECT id, x, y, carrier_id FROM plants '
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
            carrierId: r.readNullable<String>('carrier_id'),
          ),
    ];
  }

  /// The memberships geometry says should exist.
  Set<_Key> _derive(List<_Plant> plants, List<_Container> containers) =>
      _carrierWins(_deriveRaw(plants, containers), plants);

  /// Every container each plant falls inside, before any tie is broken.
  Set<_Key> _deriveRaw(List<_Plant> plants, List<_Container> containers) {
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

  /// Resolves a plant held by two container **lines of the same field**.
  ///
  /// Normally impossible: two instances of one field may not overlap. But
  /// splitting a line produces two halves that *touch* at the cut, and touching
  /// is legal by design -- so a plant sitting on the seam is within tolerance of
  /// both halves, and its Row value would be decided by whichever object the
  /// query happened to return last.
  ///
  /// **The carrier wins.** A plant snapped to a line is unambiguously on that
  /// line -- `carrier_id` was written deliberately, not derived -- so when the
  /// derivation cannot tell two same-field lines apart, the one the plant is
  /// actually attached to is the answer. Splitting a row now puts the seam plant
  /// on the half it was assigned to rather than on a coin toss.
  ///
  /// Only same-field collisions are touched. A plant in Block 2 *and* on
  /// Terrace 3 is two different fields and entirely correct.
  Set<_Key> _carrierWins(Set<_Key> wanted, List<_Plant> plants) {
    final carriers = {
      for (final plant in plants)
        if (plant.carrierId != null) plant.id: plant.carrierId!,
    };
    if (carriers.isEmpty) return wanted;

    // Only pairs that actually conflict are worth resolving, and conflicts are
    // rare enough that finding them first keeps this off the hot path.
    final counts = <({String plantId, String fieldDefId}), int>{};
    for (final key in wanted) {
      final scope = (plantId: key.plantId, fieldDefId: key.fieldDefId);
      counts[scope] = (counts[scope] ?? 0) + 1;
    }
    if (!counts.values.any((n) => n > 1)) return wanted;

    return {
      for (final key in wanted)
        if (!_isLosingDuplicate(key, counts, carriers)) key,
    };
  }

  bool _isLosingDuplicate(
    _Key key,
    Map<({String plantId, String fieldDefId}), int> counts,
    Map<String, String> carriers,
  ) {
    final contested =
        (counts[(plantId: key.plantId, fieldDefId: key.fieldDefId)] ?? 0) > 1;
    if (!contested) return false;

    final carrier = carriers[key.plantId];
    // No carrier to appeal to, so both stay and the last one read wins as
    // before. Keeping both is honest about the ambiguity rather than dropping a
    // membership arbitrarily.
    if (carrier == null) return false;

    return key.objectId != carrier;
  }

  /// Membership rows already stored, keyed the same way, mapped to their ids.
  Future<Map<_Key, String>> _existingFor(
    String projectId, {
    Set<String>? plantIds,
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
      // delete memberships it never recomputed. The object scope is applied by
      // the caller, which widens it to whole fields first.
      if (plantIds != null && !plantIds.contains(key.plantId)) continue;
      existing[key] = r.read<String>('id');
    }
    return existing;
  }
}

/// A container field's settings as a preview would have them.
///
/// Both together, because they are only meaningful together: a tolerance on a
/// field that is not a container decides nothing. A null [tolerance] means
/// [MembershipService.defaultTolerance], exactly as a null column does.
class ContainerSettings {
  const ContainerSettings({required this.isContainer, this.tolerance});

  final bool isContainer;
  final double? tolerance;
}

class _Plant {
  const _Plant(this.id, this.at, {this.carrierId});
  final String id;
  final Offset at;

  /// The line this plant is snapped to, if any. Carried only so that
  /// [MembershipService._carrierWins] can break a same-field tie.
  final String? carrierId;
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
