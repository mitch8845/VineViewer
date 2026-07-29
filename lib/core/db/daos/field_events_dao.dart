import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../models/enums.dart';
import '../database.dart';

/// Reads and writes the event log.
///
/// The log is **append-only by intent**. Correcting a value means recording a
/// new event, not editing an old one; the previous reading stays queryable.
/// That is what makes "show me last season's health scores" work, and it is
/// also why a future multi-device sync merges without conflict -- two devices
/// adding observations simply union.
class FieldEventsDao {
  FieldEventsDao(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  /// Ordering used everywhere a "latest" event is resolved.
  ///
  /// Three terms, each covering a tie the previous one leaves open:
  ///
  /// * `observed_at DESC` -- the value that was true most recently.
  /// * `recorded_at DESC` -- a bulk edit or import writes many events sharing
  ///   one `observed_at`, because the user picks a single date for the batch.
  ///   Without this, a later correction at the same observed date might not
  ///   win, so the fix would appear not to save.
  /// * `rowid DESC` -- two writes inside the same millisecond tie on
  ///   `recorded_at` as well. That is not hypothetical: correcting a value
  ///   immediately after entering it does exactly this, and it failed on a
  ///   fast machine while passing on a slow one. SQLite's implicit rowid
  ///   increases monotonically per insert, so it totally orders the remainder
  ///   at no storage cost.
  ///
  /// The result is a total order. Without the third term, the "current" value
  /// of a vine could differ between two identical reads with no write between
  /// them -- the worst kind of data bug, because it is intermittent and looks
  /// like the user misremembering.
  static const _latestFirst = 'observed_at DESC, recorded_at DESC, rowid DESC';

  /// Appends an event.
  ///
  /// A null [value] records that the field was **cleared**, which is different
  /// from having no event at all: "we looked and there is nothing" versus "we
  /// never looked".
  ///
  /// [observedAt] is when the observation was true and defaults to now;
  /// `recordedAt` is always now and is never caller-supplied.
  Future<String> record({
    required String vineId,
    required String fieldDefId,
    required String? value,
    DateTime? observedAt,
    EventSource source = EventSource.manual,
    String? batchId,
    String? note,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db
        .into(_db.fieldEvents)
        .insert(
          FieldEventsCompanion.insert(
            id: id,
            vineId: vineId,
            fieldDefId: fieldDefId,
            value: Value(value),
            observedAt: observedAt ?? timestamp,
            recordedAt: timestamp,
            source: Value(source),
            batchId: Value(batchId),
            note: Value(note),
          ),
        );

    return id;
  }

  /// Records the same value against many vines as one undoable batch.
  ///
  /// This is the write path for every multi-selection: individual vines, whole
  /// rows, whole blocks, or any mix. The caller resolves the selection to vine
  /// ids first (see `VinesDao.resolveSelection`), so this does not care what
  /// shape the selection had.
  ///
  /// All events share one `observedAt` **and** one `recordedAt` -- exactly the
  /// tie that makes the `recorded_at` tie-break in [_latestFirst] necessary.
  /// A later correction to one vine has a greater `recordedAt` and wins.
  ///
  /// Returns the batch id, so the whole edit can be reverted with [undoBatch].
  /// Bulk edits touch many vines at once and are the easiest way to do large
  /// accidental damage; making them undoable is not optional.
  Future<String> recordBulk({
    required Iterable<String> vineIds,
    required String fieldDefId,
    required String? value,
    DateTime? observedAt,
    EventSource source = EventSource.bulk,
    String? batchId,
    String? note,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final observed = observedAt ?? timestamp;
    final batch = batchId ?? _uuid.v4();

    // Single batched statement rather than a loop: a row-spray is ~40 vines
    // and a block operation can be thousands.
    await _db.batch((b) {
      b.insertAll(_db.fieldEvents, [
        for (final vineId in vineIds)
          FieldEventsCompanion.insert(
            id: _uuid.v4(),
            vineId: vineId,
            fieldDefId: fieldDefId,
            value: Value(value),
            observedAt: observed,
            recordedAt: timestamp,
            source: Value(source),
            batchId: Value(batch),
            note: Value(note),
          ),
      ]);
    });

    return batch;
  }

  /// The event holding a vine's current value for one field, or null if the
  /// field was never recorded.
  ///
  /// Pass [asOf] to ask what the value was at a past moment -- the query that
  /// makes year-over-year comparison possible.
  Future<FieldEvent?> currentEvent(
    String vineId,
    String fieldDefId, {
    DateTime? asOf,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM field_events '
          'WHERE vine_id = ?1 AND field_def_id = ?2 AND deleted_at IS NULL '
          '${asOf != null ? 'AND observed_at <= ?3 ' : ''}'
          'ORDER BY $_latestFirst LIMIT 1',
          variables: [
            Variable<String>(vineId),
            Variable<String>(fieldDefId),
            if (asOf != null)
              Variable<int>(asOf.toUtc().millisecondsSinceEpoch),
          ],
          readsFrom: {_db.fieldEvents},
        )
        .get();

    if (rows.isEmpty) return null;
    return _db.fieldEvents.map(rows.first.data);
  }

  /// Convenience wrapper around [currentEvent] returning just the value.
  ///
  /// Note this collapses two distinct states -- "never recorded" and
  /// "explicitly cleared" both yield null. Use [currentEvent] where the
  /// difference matters.
  Future<String?> currentValue(
    String vineId,
    String fieldDefId, {
    DateTime? asOf,
  }) async => (await currentEvent(vineId, fieldDefId, asOf: asOf))?.value;

  /// Every event for one vine and field, newest first.
  Future<List<FieldEvent>> history(String vineId, String fieldDefId) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM field_events '
          'WHERE vine_id = ?1 AND field_def_id = ?2 AND deleted_at IS NULL '
          'ORDER BY $_latestFirst',
          variables: [Variable<String>(vineId), Variable<String>(fieldDefId)],
          readsFrom: {_db.fieldEvents},
        )
        .get();

    return rows.map((r) => _db.fieldEvents.map(r.data)).toList();
  }

  /// Current value of every field for one vine, keyed by field definition id.
  ///
  /// One query with a window function rather than N queries. At 4,000 vines a
  /// per-field round trip is what makes a map repaint feel slow.
  Future<Map<String, FieldEvent>> currentValuesForVine(
    String vineId, {
    DateTime? asOf,
  }) async => _byFieldDef(await _valuesForVine(vineId, asOf: asOf).get());

  /// Live version of [currentValuesForVine].
  ///
  /// The inspector needs this rather than a one-shot read. Undo writes straight
  /// to the event log and notifies drift; a panel that refreshed on its own
  /// bookkeeping instead of on the table kept displaying a value undo had
  /// already removed, until some unrelated edit dislodged it. Watching the
  /// table means there is one refresh mechanism rather than two that can
  /// disagree.
  Stream<Map<String, FieldEvent>> watchCurrentValuesForVine(String vineId) =>
      _valuesForVine(vineId).watch().map(_byFieldDef);

  Selectable<QueryRow> _valuesForVine(String vineId, {DateTime? asOf}) {
    return _db.customSelect(
      'SELECT * FROM ('
      '  SELECT *, ROW_NUMBER() OVER ('
      '    PARTITION BY field_def_id ORDER BY $_latestFirst'
      '  ) AS rn'
      '  FROM field_events'
      '  WHERE vine_id = ?1 AND deleted_at IS NULL'
      '${asOf != null ? '    AND observed_at <= ?2' : ''}'
      ') WHERE rn = 1',
      variables: [
        Variable<String>(vineId),
        if (asOf != null) Variable<int>(asOf.toUtc().millisecondsSinceEpoch),
      ],
      readsFrom: {_db.fieldEvents},
    );
  }

  Map<String, FieldEvent> _byFieldDef(List<QueryRow> rows) => {
    for (final r in rows)
      r.read<String>('field_def_id'): _db.fieldEvents.map(r.data),
  };

  /// Current value of one field across every vine, keyed by vine id.
  ///
  /// This is what colour-by-field rendering needs: one query for the whole
  /// map instead of 4,000.
  Future<Map<String, FieldEvent>> currentValuesForField(
    String fieldDefId, {
    DateTime? asOf,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM ('
          '  SELECT *, ROW_NUMBER() OVER ('
          '    PARTITION BY vine_id ORDER BY $_latestFirst'
          '  ) AS rn'
          '  FROM field_events'
          '  WHERE field_def_id = ?1 AND deleted_at IS NULL'
          '${asOf != null ? '    AND observed_at <= ?2' : ''}'
          ') WHERE rn = 1',
          variables: [
            Variable<String>(fieldDefId),
            if (asOf != null)
              Variable<int>(asOf.toUtc().millisecondsSinceEpoch),
          ],
          readsFrom: {_db.fieldEvents},
        )
        .get();

    return {
      for (final r in rows)
        r.read<String>('vine_id'): _db.fieldEvents.map(r.data),
    };
  }

  /// How many observations exist across a set of plants.
  ///
  /// Section 6.4 wants the deletion prompt to name this first: retiring a plant
  /// with three seasons of readings deserves a different pause than one planted
  /// yesterday.
  Future<int> countEventsFor(Iterable<String> vineIds) async {
    final ids = vineIds.toList();
    if (ids.isEmpty) return 0;

    final placeholders = List.filled(ids.length, '?').join(', ');
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM field_events '
          'WHERE deleted_at IS NULL AND vine_id IN ($placeholders)',
          variables: [for (final id in ids) Variable<String>(id)],
          readsFrom: {_db.fieldEvents},
        )
        .getSingle();
    return row.read<int>('n');
  }

  /// Soft-deletes a single event. The prior value becomes current again.
  Future<void> softDelete(String eventId, {DateTime? now}) async {
    await (_db.update(_db.fieldEvents)..where((e) => e.id.equals(eventId)))
        .write(FieldEventsCompanion(deletedAt: Value(now ?? DateTime.now())));
  }

  /// Soft-deletes every event written by an import batch.
  ///
  /// Undoable imports are non-negotiable (plan section 7.1): a bad import can
  /// write thousands of events, and without this the only recovery is a
  /// restore from backup.
  ///
  /// Returns the number of events reverted.
  Future<int> undoBatch(String batchId, {DateTime? now}) async {
    return (_db.update(_db.fieldEvents)
          ..where((e) => e.batchId.equals(batchId) & e.deletedAt.isNull()))
        .write(FieldEventsCompanion(deletedAt: Value(now ?? DateTime.now())));
  }
}
