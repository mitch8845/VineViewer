// drift exports isNull/isNotNull as SQL expression builders, which collide with
// matcher's. We want the matchers here; Value is the only drift symbol needed.
import 'package:drift/drift.dart' show Value;
// Also re-exports SqliteException.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Fixed timestamps so ordering assertions are exact rather than
/// wall-clock-dependent.
final _jan = DateTime.utc(2026, 1, 15, 9);
final _jun = DateTime.utc(2026, 6, 15, 9);
final _sep = DateTime.utc(2026, 9, 15, 9);

void main() {
  late AppDatabase db;
  late FieldEventsDao dao;
  const plantId = 'plant-1';
  const otherPlantId = 'plant-2';
  const healthId = 'field-health';
  const varietyId = 'field-variety';

  /// Minimum hierarchy needed to satisfy foreign keys.
  Future<void> seed() async {
    final now = DateTime.utc(2026, 1, 1);
    await db
        .into(db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: 'p1',
            name: 'Home Block',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: 'f_row',
            projectId: 'p1',
            name: 'Row',
            type: FieldType.text,
            role: const Value(FieldRole.object),
            drawType: const Value(DrawType.polyline),
            isContainer: const Value(true),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.mapObjects)
        .insert(
          MapObjectsCompanion.insert(
            id: 'r1',
            projectId: 'p1',
            fieldDefId: 'f_row',
            label: '12',
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final id in [plantId, otherPlantId]) {
      await db
          .into(db.plants)
          .insert(
            PlantsCompanion.insert(
              id: id,
              projectId: 'p1',
              carrierId: const Value('r1'),
              positionIdx: id == plantId ? 6 : 7,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    for (final f in [
      (healthId, 'health', FieldType.rating, false),
      (varietyId, 'variety', FieldType.text, true),
    ]) {
      await db
          .into(db.fieldDefs)
          .insert(
            FieldDefsCompanion.insert(
              id: f.$1,
              projectId: 'p1',
              name: f.$2,
              type: f.$3,
              isStatic: Value(f.$4),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = FieldEventsDao(db);
    await seed();
  });

  tearDown(() async => db.close());

  group('recording and current value', () {
    test('a recorded value becomes current', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: '4',
        observedAt: _jun,
      );
      expect(await dao.currentValue(plantId, healthId), '4');
    });

    test('no events yields null', () async {
      expect(await dao.currentValue(plantId, healthId), isNull);
    });

    test('the latest observation wins regardless of insert order', () async {
      // Deliberately inserted newest-first: current value must follow
      // observed_at, not row order or insertion order.
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'september',
        observedAt: _sep,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'january',
        observedAt: _jan,
      );
      expect(await dao.currentValue(plantId, healthId), 'september');
    });

    test('events are isolated per plant and per field', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'mine',
        observedAt: _jun,
      );
      expect(await dao.currentValue(otherPlantId, healthId), isNull);
      expect(await dao.currentValue(plantId, varietyId), isNull);
    });
  });

  group('tie-breaking', () {
    test('same observed_at resolves to the most recently recorded', () async {
      // The real scenario: a bulk edit stamps one observed_at across many
      // plants, then the user notices a mistake and corrects it. Both events
      // share observed_at. Without the recorded_at tie-break the winner is
      // whatever SQLite returns first -- so the correction might not stick,
      // and the value could even differ between two reads.
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'typo',
        observedAt: _jun,
        now: DateTime.utc(2026, 6, 20, 10),
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'corrected',
        observedAt: _jun,
        now: DateTime.utc(2026, 6, 20, 11),
      );

      expect(await dao.currentValue(plantId, healthId), 'corrected');
    });

    test('identical timestamps resolve to the later insert', () async {
      // REGRESSION: two writes inside the same millisecond tie on observed_at
      // AND recorded_at. With only those two ordering terms SQLite returns
      // whichever row it likes, so a correction made immediately after an
      // entry could silently lose -- reading, in the field, as "I fixed that
      // and it didn't save".
      //
      // This is not a contrived case: it is what happens when a user notices a
      // typo the moment they enter it. It passed on a slower machine and
      // failed consistently on a faster one, which is exactly how an
      // intermittent data bug hides.
      //
      // Both writes share one explicit timestamp so the tie is guaranteed
      // rather than dependent on how fast the host is.
      final sameInstant = DateTime.utc(2026, 6, 15, 10, 30, 0, 0);

      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'typo',
        observedAt: sameInstant,
        now: sameInstant,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'corrected',
        observedAt: sameInstant,
        now: sameInstant,
      );

      expect(await dao.currentValue(plantId, healthId), 'corrected');
    });

    test('identical timestamps order consistently in bulk reads too', () async {
      final sameInstant = DateTime.utc(2026, 6, 15, 10, 30);
      for (final value in ['first', 'second', 'third']) {
        await dao.record(
          plantId: plantId,
          fieldDefId: healthId,
          value: value,
          observedAt: sameInstant,
          now: sameInstant,
        );
      }

      // Every read path must agree on which event is current, or the map and
      // the inspector would show different values for the same plant.
      expect(await dao.currentValue(plantId, healthId), 'third');
      expect(
        (await dao.currentValuesForPlant(plantId))[healthId]!.value,
        'third',
      );
      expect(
        (await dao.currentValuesForField(healthId))[plantId]!.value,
        'third',
      );
      expect((await dao.history(plantId, healthId)).first.value, 'third');
    });

    test('resolution is finer than one second', () async {
      // drift's built-in dateTime() stores whole seconds, which would make
      // these two events tie. Hence the millisecond converter.
      final base = DateTime.utc(2026, 6, 20, 10, 0, 0);
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'first',
        observedAt: _jun,
        now: base,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'second',
        observedAt: _jun,
        now: base.add(const Duration(milliseconds: 40)),
      );

      expect(await dao.currentValue(plantId, healthId), 'second');
    });
  });

  group('cleared vs never recorded', () {
    test('a cleared value is a real event, not an absence', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: '4',
        observedAt: _jan,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: null,
        observedAt: _jun,
      );

      // Both read as null through currentValue...
      expect(await dao.currentValue(plantId, healthId), isNull);
      // ...but the event exists, which is how "we looked and found nothing"
      // stays distinguishable from "we never looked".
      final event = await dao.currentEvent(plantId, healthId);
      expect(event, isNotNull);
      expect(event!.value, isNull);
      expect(await dao.history(plantId, healthId), hasLength(2));
    });
  });

  group('historical queries', () {
    setUp(() async {
      for (final (value, at) in [('1', _jan), ('3', _jun), ('5', _sep)]) {
        await dao.record(
          plantId: plantId,
          fieldDefId: healthId,
          value: value,
          observedAt: at,
        );
      }
    });

    test('asOf returns the value in force at that moment', () async {
      expect(
        await dao.currentValue(plantId, healthId, asOf: DateTime.utc(2026, 3)),
        '1',
      );
      expect(
        await dao.currentValue(plantId, healthId, asOf: DateTime.utc(2026, 7)),
        '3',
      );
      expect(await dao.currentValue(plantId, healthId), '5');
    });

    test('asOf before any observation yields null', () async {
      expect(
        await dao.currentValue(plantId, healthId, asOf: DateTime.utc(2025)),
        isNull,
      );
    });

    test('asOf is inclusive of an exact timestamp match', () async {
      expect(await dao.currentValue(plantId, healthId, asOf: _jun), '3');
    });

    test('history returns every event newest first', () async {
      final history = await dao.history(plantId, healthId);
      expect(history.map((e) => e.value), ['5', '3', '1']);
    });
  });

  group('bulk reads', () {
    test('currentValuesForPlant returns one entry per field', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'old',
        observedAt: _jan,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'new',
        observedAt: _sep,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: varietyId,
        value: 'Cabernet Franc',
        observedAt: _jan,
      );

      final values = await dao.currentValuesForPlant(plantId);
      expect(values, hasLength(2));
      expect(values[healthId]!.value, 'new');
      expect(values[varietyId]!.value, 'Cabernet Franc');
    });

    test('currentValuesForField returns one entry per plant', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: '2',
        observedAt: _jan,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: '4',
        observedAt: _sep,
      );
      await dao.record(
        plantId: otherPlantId,
        fieldDefId: healthId,
        value: '5',
        observedAt: _jun,
      );

      final values = await dao.currentValuesForField(healthId);
      expect(values, hasLength(2));
      expect(values[plantId]!.value, '4');
      expect(values[otherPlantId]!.value, '5');
    });

    test('bulk reads honour asOf', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'early',
        observedAt: _jan,
      );
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'late',
        observedAt: _sep,
      );

      final values = await dao.currentValuesForPlant(
        plantId,
        asOf: DateTime.utc(2026, 3),
      );
      expect(values[healthId]!.value, 'early');
    });
  });

  group('soft delete', () {
    test('deleting the latest event restores the previous value', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'keep',
        observedAt: _jan,
      );
      final mistakeId = await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'mistake',
        observedAt: _sep,
      );

      expect(await dao.currentValue(plantId, healthId), 'mistake');
      await dao.softDelete(mistakeId);
      expect(await dao.currentValue(plantId, healthId), 'keep');
    });

    test('soft-deleted events are excluded from history', () async {
      final id = await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'gone',
        observedAt: _jan,
      );
      await dao.softDelete(id);
      expect(await dao.history(plantId, healthId), isEmpty);
    });

    test('soft-deleted events are excluded from bulk reads', () async {
      final id = await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'gone',
        observedAt: _jan,
      );
      await dao.softDelete(id);
      expect(await dao.currentValuesForPlant(plantId), isEmpty);
      expect(await dao.currentValuesForField(healthId), isEmpty);
    });
  });

  group('import batches', () {
    Future<void> importThree(String batchId) async {
      for (final plant in [plantId, otherPlantId]) {
        await dao.record(
          plantId: plant,
          fieldDefId: healthId,
          value: 'imported',
          observedAt: _jun,
          source: EventSource.import,
          batchId: batchId,
        );
      }
    }

    test('an import batch can be reverted as a unit', () async {
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: 'manual',
        observedAt: _jan,
      );
      await importThree('batch-1');

      expect(await dao.currentValue(plantId, healthId), 'imported');

      final reverted = await dao.undoBatch('batch-1');
      expect(reverted, 2);

      // The pre-import value is intact -- the point of undoable imports.
      expect(await dao.currentValue(plantId, healthId), 'manual');
      expect(await dao.currentValue(otherPlantId, healthId), isNull);
    });

    test('undo does not touch other batches or manual events', () async {
      await importThree('batch-1');
      await dao.record(
        plantId: plantId,
        fieldDefId: varietyId,
        value: 'keep me',
        observedAt: _jun,
        source: EventSource.import,
        batchId: 'batch-2',
      );

      await dao.undoBatch('batch-1');
      expect(await dao.currentValue(plantId, varietyId), 'keep me');
    });

    test('undoing twice reverts nothing the second time', () async {
      await importThree('batch-1');
      expect(await dao.undoBatch('batch-1'), 2);
      expect(await dao.undoBatch('batch-1'), 0);
    });

    test('events carry their source', () async {
      await importThree('batch-1');
      final event = await dao.currentEvent(plantId, healthId);
      expect(event!.source, EventSource.import);
      expect(event.batchId, 'batch-1');
    });
  });

  group('transfer', () {});

  group('referential integrity', () {
    test('an event cannot reference a nonexistent plant', () async {
      expect(
        () => dao.record(
          plantId: 'no-such-plant',
          fieldDefId: healthId,
          value: '1',
          observedAt: _jun,
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('an event cannot reference a nonexistent field', () async {
      expect(
        () => dao.record(
          plantId: plantId,
          fieldDefId: 'no-such-field',
          value: '1',
          observedAt: _jun,
        ),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  group('timestamp handling', () {
    test('timestamps survive a round trip at millisecond precision', () async {
      final precise = DateTime.utc(2026, 6, 15, 9, 30, 45, 123);
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: '1',
        observedAt: precise,
      );

      final event = await dao.currentEvent(plantId, healthId);
      expect(event!.observedAt, precise);
      expect(event.observedAt.millisecond, 123);
    });

    test('local times are normalised to UTC', () async {
      // Storing local time would shift every historical reading the first time
      // the device crosses a DST boundary.
      final local = DateTime(2026, 6, 15, 9, 30);
      await dao.record(
        plantId: plantId,
        fieldDefId: healthId,
        value: '1',
        observedAt: local,
      );

      final event = await dao.currentEvent(plantId, healthId);
      expect(event!.observedAt.isUtc, isTrue);
      expect(
        event.observedAt.millisecondsSinceEpoch,
        local.millisecondsSinceEpoch,
      );
    });
  });
}
