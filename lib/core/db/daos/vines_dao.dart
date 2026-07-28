import 'package:drift/drift.dart';

import '../database.dart';

/// Reads over the vine hierarchy, including selection resolution.
class VinesDao {
  VinesDao(this._db);

  final AppDatabase _db;

  /// Flattens a mixed selection into the set of vines it covers.
  ///
  /// The user selects any combination -- individual vines, whole rows, whole
  /// blocks -- and every write path funnels through this. That is why field
  /// events attach to vines and never to rows (question Q6): a selection of
  /// three vines from one row plus all of another has no single entity to
  /// attach an event to, so there is nothing for a row-level event to
  /// reference. Resolving to vines makes every selection shape identical
  /// downstream.
  ///
  /// Removed and missing vines are excluded by default -- spraying a vine that
  /// is not there records an observation that never happened. Pass
  /// [includeInactive] for operations that legitimately target them, such as
  /// correcting historical data.
  Future<Set<String>> resolveSelection({
    Iterable<String> vineIds = const [],
    Iterable<String> rowIds = const [],
    Iterable<String> blockIds = const [],
    bool includeInactive = false,
  }) async {
    final vines = vineIds.toList();
    final rows = rowIds.toList();
    final blocks = blockIds.toList();

    if (vines.isEmpty && rows.isEmpty && blocks.isEmpty) return {};

    // Built dynamically because `IN ()` with an empty list is a syntax error,
    // and any of the three may legitimately be empty.
    final clauses = <String>[];
    final variables = <Variable<Object>>[];

    void addIn(String column, List<String> values) {
      if (values.isEmpty) return;
      final placeholders = List.filled(values.length, '?').join(', ');
      clauses.add('$column IN ($placeholders)');
      variables.addAll(values.map(Variable<String>.new));
    }

    addIn('v.id', vines);
    addIn('v.row_id', rows);
    addIn('r.block_id', blocks);

    final activeOnly = includeInactive ? '' : "AND v.status = 'active' ";

    final result = await _db
        .customSelect(
          'SELECT DISTINCT v.id AS id FROM vines v '
          'JOIN vine_rows r ON r.id = v.row_id '
          'WHERE v.deleted_at IS NULL AND r.deleted_at IS NULL '
          '$activeOnly'
          'AND (${clauses.join(' OR ')})',
          variables: variables,
          readsFrom: {_db.vines, _db.vineRows},
        )
        .get();

    return result.map((r) => r.read<String>('id')).toSet();
  }

  /// Every vine in a row, in planting order.
  Future<List<Vine>> vinesInRow(String rowId, {bool includeInactive = false}) {
    final query = _db.select(_db.vines)
      ..where((v) => v.rowId.equals(rowId) & v.deletedAt.isNull())
      ..orderBy([(v) => OrderingTerm.asc(v.positionIdx)]);
    return query.get().then(
      (vines) => includeInactive
          ? vines
          : vines.where((v) => v.status.name == 'active').toList(),
    );
  }
}
