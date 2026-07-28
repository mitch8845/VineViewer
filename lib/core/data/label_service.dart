import 'package:drift/drift.dart';

import '../db/database.dart';

/// A vine's `block.row.plant` address.
///
/// Always present. An unassigned block or row reads as `0`, so `0.0.1` is a
/// vine belonging to nothing yet and `1.0.7` is one placed in a block but not
/// on a row.
class VineLabel {
  const VineLabel({
    required this.block,
    required this.row,
    required this.plant,
  });

  /// The label reserved for "not assigned". Users cannot name a block or row
  /// this, or `0.0.1` would become ambiguous between a real address and an
  /// unassigned one.
  static const unassigned = '0';

  final String block;
  final String row;
  final int plant;

  String get text => '$block.$row.$plant';

  bool get hasBlock => block != unassigned;
  bool get hasRow => row != unassigned;

  @override
  String toString() => text;

  @override
  bool operator ==(Object other) =>
      other is VineLabel &&
      other.block == block &&
      other.row == row &&
      other.plant == plant;

  @override
  int get hashCode => Object.hash(block, row, plant);
}

/// Assigns and resolves vine labels.
///
/// Labels are **mutable but unique**. The UUID in `vines.id` never changes, so
/// renumbering cannot orphan a single field event; only the human-facing
/// address moves.
///
/// Uniqueness is enforced here inside transactions rather than by a database
/// constraint. Inserting a vine mid-row passes through states where two vines
/// briefly share a number, and a unique index would reject the operation
/// halfway through.
class LabelService {
  LabelService(this._db);

  final AppDatabase _db;

  /// Whether a user-supplied block or row label is acceptable.
  ///
  /// Returns null if fine, or the reason it is not.
  static String? problemWithLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return 'Label cannot be empty.';
    if (trimmed == VineLabel.unassigned) {
      return '"0" is reserved for blocks and rows that are not assigned.';
    }
    if (trimmed.contains('.')) {
      return 'Labels cannot contain a dot -- it separates block, row, '
          'and plant.';
    }
    return null;
  }

  /// The lowest unused positive plant number in a scope.
  ///
  /// Lowest-unused rather than highest-plus-one, so a gap left by a removed
  /// vine gets reused instead of the numbers climbing forever while the row
  /// stays the same length.
  Future<int> nextPlantNumber({
    required String projectId,
    String? blockId,
    String? rowId,
  }) async {
    final used = await _usedNumbersIn(
      projectId: projectId,
      blockId: blockId,
      rowId: rowId,
    );

    var candidate = 1;
    while (used.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }

  Future<Set<int>> _usedNumbersIn({
    required String projectId,
    String? blockId,
    String? rowId,
  }) async {
    // Scope: a vine on a row is numbered against that row. A vine with no row
    // is numbered against its block, so 1.0.1 and 2.0.1 coexist. A vine with
    // neither shares one project-wide unassigned scope, giving 0.0.1, 0.0.2...
    //
    // Placeholders are numbered from the list as it is built, rather than
    // written literally. Hand-numbered `?3` against a conditionally-built list
    // silently refers to the wrong parameter, or to one that was never bound.
    final variables = <Variable<Object>>[Variable<String>(projectId)];
    final where = StringBuffer('project_id = ?1 AND deleted_at IS NULL');

    if (rowId != null) {
      variables.add(Variable<String>(rowId));
      where.write(' AND row_id = ?${variables.length}');
      // A row determines the block, so constraining it again would be
      // redundant and would break if the two ever disagreed.
    } else {
      // `x = NULL` is never true in SQL, so the unassigned scopes need IS NULL.
      // Getting this wrong makes every free vine look like it has no siblings,
      // and they all end up numbered 1.
      where.write(' AND row_id IS NULL');
      if (blockId != null) {
        variables.add(Variable<String>(blockId));
        where.write(' AND block_id = ?${variables.length}');
      } else {
        where.write(' AND block_id IS NULL');
      }
    }

    final rows = await _db
        .customSelect(
          'SELECT position_idx FROM vines WHERE $where',
          variables: variables,
          readsFrom: {_db.vines},
        )
        .get();

    return rows.map((r) => r.read<int>('position_idx')).toSet();
  }

  /// Labels for every vine in a project, keyed by vine id.
  ///
  /// One query with joins rather than a lookup per vine. The canvas draws
  /// labels for whatever is on screen, and 3,000 round trips per frame is not
  /// a budget, it is a freeze.
  Future<Map<String, VineLabel>> labelsForProject(String projectId) async {
    final rows = await _db
        .customSelect(
          'SELECT v.id AS id, v.position_idx AS plant, '
          '       b.label AS block_label, r.label AS row_label '
          'FROM vines v '
          'LEFT JOIN vine_rows r ON r.id = v.row_id AND r.deleted_at IS NULL '
          'LEFT JOIN blocks b ON b.id = v.block_id AND b.deleted_at IS NULL '
          'WHERE v.project_id = ?1 AND v.deleted_at IS NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.vines, _db.vineRows, _db.blocks},
        )
        .get();

    return {
      for (final r in rows)
        r.read<String>('id'): VineLabel(
          block: r.readNullable<String>('block_label') ?? VineLabel.unassigned,
          row: r.readNullable<String>('row_label') ?? VineLabel.unassigned,
          plant: r.read<int>('plant'),
        ),
    };
  }

  /// The label for one vine, or null if it does not exist.
  Future<VineLabel?> labelOf(String vineId) async {
    final rows = await _db
        .customSelect(
          'SELECT v.position_idx AS plant, '
          '       b.label AS block_label, r.label AS row_label '
          'FROM vines v '
          'LEFT JOIN vine_rows r ON r.id = v.row_id AND r.deleted_at IS NULL '
          'LEFT JOIN blocks b ON b.id = v.block_id AND b.deleted_at IS NULL '
          'WHERE v.id = ?1 AND v.deleted_at IS NULL',
          variables: [Variable<String>(vineId)],
          readsFrom: {_db.vines, _db.vineRows, _db.blocks},
        )
        .get();

    if (rows.isEmpty) return null;
    final r = rows.first;
    return VineLabel(
      block: r.readNullable<String>('block_label') ?? VineLabel.unassigned,
      row: r.readNullable<String>('row_label') ?? VineLabel.unassigned,
      plant: r.read<int>('plant'),
    );
  }

  /// Moves a vine into a row, renumbering it to the next free number there.
  ///
  /// The vine's block follows the row's, keeping the two consistent. Its old
  /// number is released for reuse.
  ///
  /// Does **not** touch position -- snapping the vine geometrically is the
  /// layout DAO's job. This only owns the address.
  Future<VineLabel> assignToRow({
    required String vineId,
    required String rowId,
    DateTime? now,
  }) async {
    return _db.transaction(() async {
      final vine = await _requireVine(vineId);
      final row =
          await (_db.select(_db.vineRows)
                ..where((r) => r.id.equals(rowId) & r.deletedAt.isNull()))
              .getSingleOrNull();

      if (row == null) {
        throw StateError('Row $rowId does not exist.');
      }

      final plant = await nextPlantNumber(
        projectId: vine.projectId,
        blockId: row.blockId,
        rowId: rowId,
      );

      await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
        VinesCompanion(
          rowId: Value(rowId),
          blockId: Value(row.blockId),
          positionIdx: Value(plant),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

      return (await labelOf(vineId))!;
    });
  }

  /// Assigns a vine to a block without putting it on a row -- the `1.0.x` case.
  Future<VineLabel> assignToBlock({
    required String vineId,
    required String? blockId,
    DateTime? now,
  }) async {
    return _db.transaction(() async {
      final vine = await _requireVine(vineId);

      // Leaving it on a row while changing its block would make the vine's
      // block disagree with its row's -- two sources for one fact.
      final plant = await nextPlantNumber(
        projectId: vine.projectId,
        blockId: blockId,
        rowId: null,
      );

      await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
        VinesCompanion(
          blockId: Value(blockId),
          rowId: const Value(null),
          pathOffset: const Value(null),
          positionIdx: Value(plant),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

      return (await labelOf(vineId))!;
    });
  }

  /// Detaches a vine from its row, keeping its block.
  ///
  /// The vine keeps its current x/y -- it stays where it is on screen and
  /// simply stops belonging to the row.
  Future<VineLabel> detachFromRow({
    required String vineId,
    DateTime? now,
  }) async {
    return _db.transaction(() async {
      final vine = await _requireVine(vineId);

      final plant = await nextPlantNumber(
        projectId: vine.projectId,
        blockId: vine.blockId,
        rowId: null,
      );

      await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
        VinesCompanion(
          rowId: const Value(null),
          pathOffset: const Value(null),
          positionIdx: Value(plant),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

      return (await labelOf(vineId))!;
    });
  }

  /// Renumbers a row's vines to 1..n in path order, closing any gaps.
  ///
  /// The explicit "Renumber Row" tool from plan section 6.2, for when the user
  /// wants clean sequential numbering and accepts that printed maps referring
  /// to the old numbers are now wrong.
  Future<void> renumberRow(String rowId, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();

    await _db.transaction(() async {
      final vines =
          await (_db.select(_db.vines)
                ..where((v) => v.rowId.equals(rowId) & v.deletedAt.isNull())
                ..orderBy([
                  // Path order, falling back to the existing number for vines
                  // that have no offset yet.
                  (v) => OrderingTerm.asc(v.pathOffset),
                  (v) => OrderingTerm.asc(v.positionIdx),
                ]))
              .get();

      for (var i = 0; i < vines.length; i++) {
        await (_db.update(
          _db.vines,
        )..where((v) => v.id.equals(vines[i].id))).write(
          VinesCompanion(
            positionIdx: Value(i + 1),
            updatedAt: Value(timestamp),
          ),
        );
      }
    });
  }

  /// Finds duplicate labels in a project.
  ///
  /// Uniqueness is maintained in application code, not by a constraint, so it
  /// is worth being able to prove it holds -- especially after an import or an
  /// archive restore, which write rows without going through this service.
  Future<List<String>> findDuplicateLabels(String projectId) async {
    final labels = await labelsForProject(projectId);
    final seen = <String, int>{};
    for (final label in labels.values) {
      seen.update(label.text, (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      for (final entry in seen.entries)
        if (entry.value > 1) entry.key,
    ]..sort();
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
