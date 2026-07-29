import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';

/// What the undo and redo buttons should currently offer.
class UndoAvailability {
  const UndoAvailability({this.undo, this.redo});

  static const none = UndoAvailability();

  /// The operation undo would reverse, or null if there is nothing to undo.
  final Operation? undo;

  /// The operation redo would re-apply, or null.
  final Operation? redo;

  bool get canUndo => undo != null;
  bool get canRedo => redo != null;
}

/// Reverses and re-applies recorded operations.
///
/// Replay is generic: it reads the before/after JSON captured by the triggers
/// and writes it back, with no per-operation inverse code anywhere. That is the
/// whole reason the journal was built this way -- the alternative was ~40 hand
/// written inverses, each of which had to remember exactly enough prior state,
/// and each of which was a place to get it subtly wrong.
class UndoService {
  UndoService(this._db);

  final AppDatabase _db;

  /// How far back undo reaches.
  ///
  /// Older operations stay in the journal -- label history is derived from
  /// them, so deleting them would delete the answer to "what was 3.12.7 in
  /// 2025?" -- but they stop being replayable. An unbounded stack would let a
  /// stray press walk a vineyard back through a season of work.
  static const stackLimit = 100;

  /// Live undo/redo availability for the toolbar.
  Stream<UndoAvailability> watch(String projectId) {
    return (_db.select(_db.operations)
          ..where((o) => o.projectId.equals(projectId))
          ..orderBy([(o) => OrderingTerm.desc(o.id)])
          ..limit(stackLimit))
        .watch()
        .map(_availabilityOf);
  }

  Future<UndoAvailability> availability(String projectId) async {
    final window =
        await (_db.select(_db.operations)
              ..where((o) => o.projectId.equals(projectId))
              ..orderBy([(o) => OrderingTerm.desc(o.id)])
              ..limit(stackLimit))
            .get();
    return _availabilityOf(window);
  }

  /// [window] is newest first.
  UndoAvailability _availabilityOf(List<Operation> window) {
    Operation? undo;
    Operation? redo;

    for (final operation in window) {
      if (operation.undoneAt == null) {
        // The newest still-applied operation, so the first one seen.
        undo ??= operation;
      } else {
        // Undo walks newest to oldest, so redo walks back the other way: the
        // target is the *oldest* undone operation, which is the last one seen.
        redo = operation;
      }
    }

    return UndoAvailability(undo: undo, redo: redo);
  }

  /// Reverses the most recent operation. Returns it, or null if there was none.
  Future<Operation?> undo(String projectId) =>
      _replay(projectId, forward: false);

  /// Re-applies the most recently undone operation.
  Future<Operation?> redo(String projectId) =>
      _replay(projectId, forward: true);

  Future<Operation?> _replay(String projectId, {required bool forward}) async {
    final available = await availability(projectId);
    final target = forward ? available.redo : available.undo;
    if (target == null) return null;

    final touched = <String>{};

    await _db.transaction(() async {
      final rows =
          await (_db.select(_db.operationRows)
                ..where((r) => r.operationId.equals(target.id))
                // Undo unwinds in reverse, which is also the order foreign keys
                // need: a gesture that created a row and then plants on it
                // captured them in that order, so removing them backwards drops
                // the children first. Redo re-applies in the original order for
                // the same reason.
                ..orderBy([
                  (r) => forward
                      ? OrderingTerm.asc(r.id)
                      : OrderingTerm.desc(r.id),
                ]))
              .get();

      for (final row in rows) {
        touched.add(row.targetTable);
        await _restore(
          row.targetTable,
          row.rowId,
          forward ? row.after : row.before,
        );
      }

      await (_db.update(
        _db.operations,
      )..where((o) => o.id.equals(target.id))).write(
        OperationsCompanion(undoneAt: Value(forward ? null : DateTime.now())),
      );
    });

    // Replay writes go through customStatement, which drift cannot attribute to
    // a table on its own. Without this the database is correct and every
    // watching widget is stale -- the canvas keeps painting plants that undo
    // just moved back. The operations table is included so the toolbar's own
    // watch re-evaluates.
    _db.notifyUpdates({
      for (final table in _db.journaledTables)
        if (touched.contains(table.actualTableName))
          TableUpdate.onTable(table, kind: UpdateKind.update),
      TableUpdate.onTable(_db.operations, kind: UpdateKind.update),
    });

    return target;
  }

  /// Puts one row back into [table] as [json] describes it.
  ///
  /// A null [json] means the row did not exist at that point in time, so
  /// restoring it means deleting it.
  Future<void> _restore(String table, String rowId, String? json) async {
    if (json == null) {
      await _db.customStatement('DELETE FROM $table WHERE id = ?', [rowId]);
      return;
    }

    final values = (jsonDecode(json) as Map<String, dynamic>);
    final columns = values.keys.toList();

    // Update-then-insert rather than INSERT OR REPLACE. The latter resolves a
    // conflict by deleting the existing row first, which fires ON DELETE
    // CASCADE -- restoring a row would silently destroy its children.
    final assignments = columns.map((c) => '$c = ?').join(', ');
    final updated = await _db.customUpdate(
      'UPDATE $table SET $assignments WHERE id = ?',
      variables: [
        for (final column in columns) _variable(values[column]),
        Variable<String>(rowId),
      ],
    );
    if (updated > 0) return;

    final placeholders = List.filled(columns.length, '?').join(', ');
    await _db.customInsert(
      'INSERT INTO $table (${columns.join(', ')}) VALUES ($placeholders)',
      variables: [for (final column in columns) _variable(values[column])],
    );
  }

  /// Journal JSON only ever holds the three types the schema uses.
  Variable<Object> _variable(Object? value) => switch (value) {
    null => const Variable<String>(null),
    final int v => Variable<int>(v),
    final double v => Variable<double>(v),
    final String v => Variable<String>(v),
    _ => throw StateError(
      'Unexpected journal value type: ${value.runtimeType}',
    ),
  };

  /// Drops a project's journal entirely.
  ///
  /// Called when a project is purged. Purge is documented as irreversible and
  /// requires typed confirmation, so there is nothing here worth keeping -- and
  /// the journal rows describing the purge would otherwise outlive everything
  /// they refer to.
  Future<void> clearProject(String projectId) async {
    await (_db.delete(
      _db.operations,
    )..where((o) => o.projectId.equals(projectId))).go();
  }
}
