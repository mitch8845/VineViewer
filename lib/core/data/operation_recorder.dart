import 'package:drift/drift.dart';

import '../db/database.dart';

/// Wraps a user gesture so it can be undone as one thing.
///
/// **The unit of undo is a gesture, not a DAO call.** "Replace with New Vine"
/// retires one vine, creates another, and copies its static fields: three
/// writes, one entry in the undo stack, one press of undo. So [run] is called
/// from the feature layer -- the inspector, the canvas tool handlers, the field
/// editor -- and never from inside a DAO, which cannot know where a gesture
/// begins or ends.
///
/// Capture itself is not this class's job. SQLite triggers (see
/// `AppDatabase._captureTriggers`) record every touched row while an operation
/// is open, which is why none of the ~31 existing mutating entry points needed
/// changing to become undoable.
class OperationRecorder {
  OperationRecorder(this._db);

  final AppDatabase _db;

  /// Runs [body] as a single undoable operation.
  ///
  /// [description] is what the undo button will say, and is taken as a value
  /// rather than a callback because it must be composed *before* the body runs,
  /// while the labels it names are still current. "Delete row 12" describes the
  /// vineyard as it was when the mistake was made; deriving it at undo time
  /// would describe the vineyard the mistake produced.
  ///
  /// Nested calls are passed straight through to [body]. The outermost caller
  /// owns the gesture, so a service that wraps its own work does not split a
  /// user action into two undo steps.
  Future<T> run<T>({
    required String projectId,
    required String kind,
    required String description,
    required Future<T> Function() body,
    DateTime? now,
  }) async {
    if (await _openOperationId() != null) return body();

    return _db.transaction(() async {
      // A fresh action invalidates anything that was undone, as everywhere
      // else. Done before the context is set so this housekeeping is not
      // itself captured.
      await _clearRedoStack(projectId);

      final operationId = await _db
          .into(_db.operations)
          .insert(
            OperationsCompanion.insert(
              projectId: projectId,
              kind: kind,
              description: description,
              createdAt: now ?? DateTime.now(),
            ),
          );

      await _setContext(operationId);
      final result = await body();
      await _setContext(null);

      // A gesture that changed nothing -- a rejected validation, a drag that
      // ended where it started -- must not leave an undo step that does
      // nothing when pressed.
      await _discardIfEmpty(operationId);

      return result;
    });
    // No `finally` clearing the context: if [body] throws, the transaction
    // rolls back, and undo_context is an ordinary table inside it. The rollback
    // restores it to NULL for us, which is both simpler and more correct than
    // trying to write to a transaction that is already unwinding.
  }

  /// The operation currently being recorded, or null.
  Future<int?> _openOperationId() async {
    final row = await _db
        .customSelect(
          'SELECT operation_id FROM undo_context WHERE id = 1',
          readsFrom: {_db.undoContext},
        )
        .getSingleOrNull();
    return row?.readNullable<int>('operation_id');
  }

  Future<void> _setContext(int? operationId) => _db.customStatement(
    'UPDATE undo_context SET operation_id = ? WHERE id = 1',
    [operationId],
  );

  Future<void> _clearRedoStack(String projectId) async {
    await (_db.delete(
          _db.operations,
        )..where((o) => o.projectId.equals(projectId) & o.undoneAt.isNotNull()))
        .go();
  }

  Future<void> _discardIfEmpty(int operationId) async {
    final captured =
        await (_db.select(_db.operationRows)
              ..where((r) => r.operationId.equals(operationId))
              ..limit(1))
            .getSingleOrNull();
    if (captured != null) return;

    await (_db.delete(
      _db.operations,
    )..where((o) => o.id.equals(operationId))).go();
  }
}
