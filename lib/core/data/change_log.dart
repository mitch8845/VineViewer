import 'package:drift/drift.dart';

import '../db/database.dart';

/// One change to a project, as the change log shows it.
class ChangeEntry {
  const ChangeEntry({
    required this.id,
    required this.kind,
    required this.description,
    required this.at,
    required this.undoneAt,
    required this.discardedAt,
    required this.created,
    required this.updated,
    required this.deleted,
    required this.plants,
    required this.values,
    required this.objects,
  });

  final int id;
  final String kind;
  final String description;
  final DateTime at;
  final DateTime? undoneAt;

  /// Set when the change was undone and then abandoned by a later edit.
  final DateTime? discardedAt;

  /// Rows the change created, updated and deleted, across every table.
  final int created;
  final int updated;
  final int deleted;

  /// Distinct plants, observations and drawn objects it touched.
  final int plants;
  final int values;
  final int objects;

  bool get isUndone => undoneAt != null;

  /// Undone, and still one press of redo away.
  bool get canRedo => undoneAt != null && discardedAt == null;
}

/// Every change made to a project, newest first.
///
/// Read from the undo journal, which every edit already goes through -- so
/// the log cannot miss a change the app knows how to undo, and needs no
/// bookkeeping of its own that could drift from what actually happened.
/// Undone changes stay listed and say so: something done and taken back is
/// still part of what happened to the vineyard.
class ChangeLog {
  ChangeLog(this._db);

  final AppDatabase _db;

  Selectable<ChangeEntry> _query(String projectId, int limit) {
    return _db
        .customSelect(
          'SELECT o.id, o.kind, o.description, o.created_at, o.undone_at, '
          '  o.discarded_at, '
          '  SUM(r.before IS NULL AND r.after IS NOT NULL) AS created, '
          '  SUM(r.before IS NOT NULL AND r.after IS NOT NULL) AS updated, '
          '  SUM(r.before IS NOT NULL AND r.after IS NULL) AS deleted, '
          "  COUNT(DISTINCT CASE WHEN r.target_table = 'plants' "
          '    THEN r.row_id END) AS plants, '
          "  COUNT(DISTINCT CASE WHEN r.target_table = 'field_events' "
          '    THEN r.row_id END) AS vals, '
          "  COUNT(DISTINCT CASE WHEN r.target_table = 'map_objects' "
          '    THEN r.row_id END) AS objects '
          'FROM operations o '
          'LEFT JOIN operation_rows r ON r.operation_id = o.id '
          'WHERE o.project_id = ?1 '
          'GROUP BY o.id '
          'ORDER BY o.id DESC '
          'LIMIT ?2',
          variables: [Variable<String>(projectId), Variable<int>(limit)],
          readsFrom: {_db.operations, _db.operationRows},
        )
        .map((r) {
          DateTime? time(String column) {
            final ms = r.readNullable<int>(column);
            return ms == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    ms,
                    isUtc: true,
                  ).toLocal();
          }

          return ChangeEntry(
            id: r.read<int>('id'),
            kind: r.read<String>('kind'),
            description: r.read<String>('description'),
            at: time('created_at')!,
            undoneAt: time('undone_at'),
            discardedAt: time('discarded_at'),
            created: r.readNullable<int>('created') ?? 0,
            updated: r.readNullable<int>('updated') ?? 0,
            deleted: r.readNullable<int>('deleted') ?? 0,
            plants: r.read<int>('plants'),
            values: r.read<int>('vals'),
            objects: r.read<int>('objects'),
          );
        });
  }

  Future<List<ChangeEntry>> entries(String projectId, {int limit = 500}) =>
      _query(projectId, limit).get();

  /// Live: an edit, an undo or a redo appears without reopening the log.
  Stream<List<ChangeEntry>> watch(String projectId, {int limit = 500}) =>
      _query(projectId, limit).watch();
}
