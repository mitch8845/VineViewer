import 'dart:convert';

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

/// A label this vine carried, and what gave it that label.
class LabelChange {
  const LabelChange({required this.label, this.at, this.reason});

  final VineLabel label;

  /// When the vine took this label, or null when the journal cannot say --
  /// which happens for the label it carries right now if that was set before
  /// the journal existed, or by something that bypasses it such as an import.
  final DateTime? at;

  /// The description of the operation responsible, e.g. "Insert vine in row 12".
  final String? reason;

  @override
  String toString() => '${label.text}${at == null ? '' : ' from $at'}';
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

  /// The lowest unused row number **within a block**.
  ///
  /// Row numbers restart in every block. That is not a preference, it is what
  /// the vineyard's own records do: block 1 has rows 1-25, block 2 has 1-24,
  /// block 3 has 1-26. So `1.12` and `2.12` are different physical rows, and
  /// allocating row numbers project-wide would number the first row drawn in
  /// block 2 as 26.
  ///
  /// A null [blockId] is the unassigned scope -- rows drawn before their block
  /// has been decided, which is the normal order of work: rows first, block
  /// boundaries after.
  Future<int> nextRowNumber({
    required String projectId,
    String? blockId,
  }) async {
    final used = await _usedRowNumbersIn(
      projectId: projectId,
      blockId: blockId,
    );

    var candidate = 1;
    while (used.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }

  /// Whether [number] is free to use as a row number in this block.
  ///
  /// Separate from [nextRowNumber] because the user types the number: the flow
  /// suggests the next free one but does not impose it, so what they type has
  /// to be checkable.
  Future<bool> isRowNumberFree({
    required String projectId,
    String? blockId,
    required String number,
    String? ignoringRowId,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT id, label FROM vine_rows '
          'WHERE project_id = ?1 AND deleted_at IS NULL '
          '  AND block_id IS ?2 AND label = ?3',
          variables: [
            Variable<String>(projectId),
            Variable<String>(blockId),
            Variable<String>(number.trim()),
          ],
          readsFrom: {_db.vineRows},
        )
        .get();

    // A row does not collide with itself when it is being renamed in place.
    return rows.every((r) => r.read<String>('id') == ignoringRowId);
  }

  Future<Set<int>> _usedRowNumbersIn({
    required String projectId,
    String? blockId,
  }) async {
    // `IS` rather than `=` so the unassigned scope works: `block_id = NULL` is
    // never true, which would make every unassigned row look like the only one
    // and number them all 1. The same trap as _usedNumbersIn below.
    final rows = await _db
        .customSelect(
          'SELECT label FROM vine_rows '
          'WHERE project_id = ?1 AND deleted_at IS NULL AND block_id IS ?2',
          variables: [Variable<String>(projectId), Variable<String>(blockId)],
          readsFrom: {_db.vineRows},
        )
        .get();

    // Row labels are free text, so a row called "north" simply does not occupy
    // a number. Skipping it is right: it cannot collide with one.
    return {for (final r in rows) ?int.tryParse(r.read<String>('label'))};
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

  /// Numbers a vine being inserted into a row at a chosen point.
  ///
  /// Plan section 6.3 recommended defaulting to a suffix (`3.12.6a`) so nothing
  /// downstream had to move. **That is superseded**: plant numbers are integers
  /// assigned next-available, and `3.12.6a` is not expressible in an
  /// `IntColumn`. The user is asked instead, per insertion, which is the honest
  /// version of the trade -- only they know whether a printed map is in a
  /// pocket somewhere.
  ///
  /// With [shift] true the new vine takes `afterPositionIdx + 1` and everything
  /// beyond it moves up one. With [shift] false it takes the lowest free number
  /// in the row, appending if there are no gaps, and no existing vine is
  /// touched -- at the cost of the number not matching where the vine sits.
  ///
  /// Returns the number given to [vineId].
  Future<int> insertAfter({
    required String vineId,
    required String rowId,
    required int afterPositionIdx,
    required bool shift,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();

    return _db.transaction(() async {
      final vine = await _requireVine(vineId);

      if (!shift) {
        final plant = await nextPlantNumber(
          projectId: vine.projectId,
          rowId: rowId,
        );
        await _place(vineId, rowId, plant, timestamp);
        return plant;
      }

      // Descending order is not required -- position_idx has no unique index,
      // precisely so renumbering can pass through duplicate states -- but a
      // single statement is one journal row per vine either way and is far
      // cheaper on a 72-vine row.
      await _db.customStatement(
        'UPDATE vines SET position_idx = position_idx + 1, updated_at = ?1 '
        'WHERE row_id = ?2 AND deleted_at IS NULL AND position_idx > ?3',
        [timestamp.toUtc().millisecondsSinceEpoch, rowId, afterPositionIdx],
      );

      final plant = afterPositionIdx + 1;
      await _place(vineId, rowId, plant, timestamp);
      return plant;
    });
  }

  /// How many labels [insertAfter] would change if asked to shift.
  ///
  /// The prompt has to name this number. "This renames 34 vines" is a decision;
  /// "labels after this point will change" is a shrug.
  Future<int> countAffectedByShift({
    required String rowId,
    required int afterPositionIdx,
  }) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM vines '
          'WHERE row_id = ?1 AND deleted_at IS NULL AND position_idx > ?2',
          variables: [Variable<String>(rowId), Variable<int>(afterPositionIdx)],
          readsFrom: {_db.vines},
        )
        .getSingle();
    return row.read<int>('n');
  }

  Future<void> _place(
    String vineId,
    String rowId,
    int plant,
    DateTime timestamp,
  ) async {
    final row = await (_db.select(
      _db.vineRows,
    )..where((r) => r.id.equals(rowId))).getSingle();

    await (_db.update(_db.vines)..where((v) => v.id.equals(vineId))).write(
      VinesCompanion(
        rowId: Value(rowId),
        blockId: Value(row.blockId),
        positionIdx: Value(plant),
        updatedAt: Value(timestamp),
      ),
    );
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

  // --------------------------------------------------------------- history

  /// Every label this vine has carried, oldest first.
  ///
  /// Answers "what was 3.12.7 in 2025?" -- the question that makes a shelf of
  /// paper notebooks worth keeping. Labels are mutable *and* reused from gaps,
  /// so the same text genuinely does mean different vines at different times,
  /// and without this reconciling an old record is guesswork.
  ///
  /// Derived from the undo journal rather than from a table of its own. The
  /// journal already records the before and after of every `position_idx`,
  /// `row_id`, and `block_id` change, so a second store would be a duplicate
  /// source of truth for the same fact -- and the two would eventually
  /// disagree. This is a per-vine query shown in the inspector, not a hot path,
  /// so the scan is the right trade.
  ///
  /// **It begins where the journal begins.** Anything that happened before the
  /// journal existed, or was written outside an operation (an import, a
  /// restored archive), is not in here. The current label is always the last
  /// entry, whether or not the journal explains how it got there.
  Future<List<LabelChange>> historyOf(String vineId) async {
    final vine = await (_db.select(
      _db.vines,
    )..where((v) => v.id.equals(vineId))).getSingleOrNull();
    final entries = await _journalFor(table: 'vines', ids: {vineId});
    if (vine == null && entries.isEmpty) return const [];

    // Which rows and blocks this vine has ever pointed at, so their renames can
    // be folded in: 3.12.7 also becomes 3.13.7 when row 12 is renamed to 13,
    // without the vine itself being touched at all.
    final rowIds = <String>{if (vine?.rowId != null) vine!.rowId!};
    final blockIds = <String>{if (vine?.blockId != null) vine!.blockId!};
    for (final entry in entries) {
      for (final state in [entry.before, entry.after]) {
        if (state == null) continue;
        final rowId = state['row_id'] as String?;
        final blockId = state['block_id'] as String?;
        if (rowId != null) rowIds.add(rowId);
        if (blockId != null) blockIds.add(blockId);
      }
    }

    final merged = [
      ...entries,
      ...await _journalFor(table: 'vine_rows', ids: rowIds),
      ...await _journalFor(table: 'blocks', ids: blockIds),
    ]..sort((a, b) => a.id.compareTo(b.id));

    // Parent labels as they stood when the journal opens, found by taking the
    // current labels and rewinding every recorded rename. A parent with no
    // journal entry has never been renamed, so its current label is also its
    // oldest one.
    final names = <String, String>{
      for (final entry in await _currentLabels('vine_rows', rowIds))
        entry.$1: entry.$2,
      for (final entry in await _currentLabels('blocks', blockIds))
        entry.$1: entry.$2,
    };
    for (final entry in merged.reversed) {
      final before = entry.before;
      if (entry.table == 'vines' || before == null) continue;
      names[entry.rowId] = before['label'] as String;
    }

    // The vine's own starting state: what it looked like before the first
    // operation that touched it, or -- if no operation ever has -- what it looks
    // like now. A null `before` on the first entry means the vine was created
    // during the journal and had no label before that.
    var state = entries.isNotEmpty
        ? entries.first.before
        : {
            'position_idx': vine!.positionIdx,
            'row_id': vine.rowId,
            'block_id': vine.blockId,
          };

    final history = <LabelChange>[];
    void record(DateTime? at, String? reason) {
      final current = state;
      if (current == null) return; // the vine did not exist yet

      final label = VineLabel(
        block: names[current['block_id']] ?? VineLabel.unassigned,
        row: names[current['row_id']] ?? VineLabel.unassigned,
        plant: current['position_idx'] as int,
      );

      // Only transitions are interesting. Most operations touch a vine without
      // moving its address at all -- a drag along a row is the common case --
      // and listing every one of those would bury the renames that matter.
      if (history.isNotEmpty && history.last.label == label) return;
      history.add(LabelChange(label: label, at: at, reason: reason));
    }

    // The starting label carries no date: the journal records what changed it,
    // never when it was first given.
    record(null, null);

    for (final entry in merged) {
      if (entry.table == 'vines') {
        state = entry.after;
      } else {
        final after = entry.after;
        if (after != null) names[entry.rowId] = after['label'] as String;
      }
      record(entry.at, entry.description);
    }

    // Anything that bypassed the journal -- an import, a restored archive --
    // leaves the walk disagreeing with reality. Reality wins.
    final current = await labelOf(vineId);
    if (current != null && (history.isEmpty || history.last.label != current)) {
      history.add(LabelChange(label: current));
    }

    return history;
  }

  Future<List<_JournalEntry>> _journalFor({
    required String table,
    required Set<String> ids,
  }) async {
    if (ids.isEmpty) return const [];

    final placeholders = List.generate(
      ids.length,
      (i) => '?${i + 2}',
    ).join(',');
    final rows = await _db
        .customSelect(
          'SELECT r.id AS id, r.row_id AS row_id, r.before AS before, '
          '       r.after AS after, o.created_at AS created_at, '
          '       o.description AS description '
          'FROM operation_rows r '
          'JOIN operations o ON o.id = r.operation_id '
          // Undone operations are excluded, so undo means the rename did not
          // happen rather than "it happened and then happened backwards". That
          // matches the decision that undoing a data write erases it: an undo
          // is a correction, not an event worth preserving.
          'WHERE o.undone_at IS NULL '
          '  AND r.target_table = ?1 AND r.row_id IN ($placeholders) '
          'ORDER BY r.id',
          variables: [
            Variable<String>(table),
            for (final id in ids) Variable<String>(id),
          ],
          readsFrom: {_db.operationRows, _db.operations},
        )
        .get();

    return [
      for (final r in rows)
        _JournalEntry(
          id: r.read<int>('id'),
          table: table,
          rowId: r.read<String>('row_id'),
          before: _decode(r.readNullable<String>('before')),
          after: _decode(r.readNullable<String>('after')),
          at: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('created_at'),
            isUtc: true,
          ).toLocal(),
          description: r.read<String>('description'),
        ),
    ];
  }

  Future<List<(String, String)>> _currentLabels(
    String table,
    Set<String> ids,
  ) async {
    if (ids.isEmpty) return const [];

    final placeholders = List.generate(
      ids.length,
      (i) => '?${i + 1}',
    ).join(',');
    final rows = await _db
        .customSelect(
          'SELECT id, label FROM $table WHERE id IN ($placeholders)',
          variables: [for (final id in ids) Variable<String>(id)],
        )
        .get();

    return [
      for (final r in rows) (r.read<String>('id'), r.read<String>('label')),
    ];
  }

  static Map<String, dynamic>? _decode(String? json) =>
      json == null ? null : jsonDecode(json) as Map<String, dynamic>;

  Future<Vine> _requireVine(String vineId) async {
    final vine =
        await (_db.select(_db.vines)
              ..where((v) => v.id.equals(vineId) & v.deletedAt.isNull()))
            .getSingleOrNull();
    if (vine == null) throw StateError('Vine $vineId does not exist.');
    return vine;
  }
}

/// One captured row from the undo journal, decoded.
class _JournalEntry {
  const _JournalEntry({
    required this.id,
    required this.table,
    required this.rowId,
    required this.before,
    required this.after,
    required this.at,
    required this.description,
  });

  /// The journal row's own id, which is also the order things happened in.
  final int id;

  final String table;
  final String rowId;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
  final DateTime at;
  final String description;
}
