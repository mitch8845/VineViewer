import 'package:drift/drift.dart';

import '../database.dart';

/// Reads over plants, including selection resolution.
class PlantsDao {
  PlantsDao(this._db);

  final AppDatabase _db;

  /// Flattens a mixed selection into the set of plants it covers.
  ///
  /// The user selects any combination -- individual plants, everything on a
  /// line, everything inside a block -- and every write path funnels through
  /// here. That is why field events attach to plants and never to objects
  /// (question Q6): a selection of three plants from one row plus all of
  /// another has no single entity to attach an event to. Resolving to plants
  /// makes every selection shape identical downstream.
  ///
  /// Removed and missing plants are excluded by default -- spraying a plant
  /// that is not there records an observation that never happened. Pass
  /// [includeInactive] for operations that legitimately target them, such as
  /// correcting historical data.
  Future<Set<String>> resolveSelection({
    Iterable<String> plantIds = const [],
    Iterable<String> objectIds = const [],
    bool includeInactive = false,
  }) async {
    final plants = plantIds.toList();
    final objects = objectIds.toList();
    if (plants.isEmpty && objects.isEmpty) return {};

    // Built dynamically because `IN ()` with an empty list is a syntax error,
    // and either may legitimately be empty.
    final clauses = <String>[];
    final variables = <Variable<Object>>[];

    if (plants.isNotEmpty) {
      final placeholders = List.filled(plants.length, '?').join(', ');
      clauses.add('v.id IN ($placeholders)');
      variables.addAll(plants.map(Variable<String>.new));
    }

    if (objects.isNotEmpty) {
      final placeholders = List.filled(objects.length, '?').join(', ');

      // **Union, not either alone.** Membership covers plants inside a
      // container; carrier covers plants snapped to a line. A plant on an
      // unnamed, non-container polyline has no membership row at all, and an
      // object-selection that only looked at memberships would silently drop it
      // from a select-all -- leaving plants visibly on the line that no bulk
      // edit could touch.
      clauses.add(
        'v.carrier_id IN ($placeholders) '
        'OR EXISTS (SELECT 1 FROM plant_memberships m '
        '           WHERE m.plant_id = v.id '
        '             AND m.object_id IN ($placeholders))',
      );
      // Bound twice: the same list appears in both halves of the clause.
      variables.addAll(objects.map(Variable<String>.new));
      variables.addAll(objects.map(Variable<String>.new));
    }

    final activeOnly = includeInactive ? '' : "AND v.status = 'active' ";

    final result = await _db
        .customSelect(
          'SELECT DISTINCT v.id AS id FROM plants v '
          'WHERE v.deleted_at IS NULL '
          '$activeOnly'
          'AND (${clauses.join(' OR ')})',
          variables: variables,
          readsFrom: {_db.plants, _db.plantMemberships},
        )
        .get();

    return result.map((r) => r.read<String>('id')).toSet();
  }

  /// Every plant on a carrier, in planting order.
  Future<List<Plant>> plantsOnCarrier(
    String carrierId, {
    bool includeInactive = false,
  }) {
    final query = _db.select(_db.plants)
      ..where((v) => v.carrierId.equals(carrierId) & v.deletedAt.isNull())
      ..orderBy([(v) => OrderingTerm.asc(v.positionIdx)]);
    return query.get().then(
      (plants) => includeInactive
          ? plants
          : plants.where((v) => v.status.name == 'active').toList(),
    );
  }
}
