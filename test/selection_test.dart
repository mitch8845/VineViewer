import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/vines_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Two blocks, two rows each, three vines each -- enough to test that a
/// selection resolves across levels without over-reaching.
///
///   block-1 -> row-1 (v-1-1-1, v-1-1-2, v-1-1-3)
///           -> row-2 (v-1-2-1, v-1-2-2, v-1-2-3)
///   block-2 -> row-3 (v-2-3-1, v-2-3-2, v-2-3-3)
void main() {
  late AppDatabase db;
  late VinesDao vines;
  late FieldEventsDao events;

  final t0 = DateTime.utc(2026, 1, 1);
  const sprayField = 'field-spray';

  Future<void> seed() async {
    await db
        .into(db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: 'p1',
            name: 'Home',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
    for (final b in ['block-1', 'block-2']) {
      await db
          .into(db.blocks)
          .insert(
            BlocksCompanion.insert(
              id: b,
              projectId: 'p1',
              label: b,
              createdAt: t0,
              updatedAt: t0,
            ),
          );
    }
    for (final (row, block) in [
      ('row-1', 'block-1'),
      ('row-2', 'block-1'),
      ('row-3', 'block-2'),
    ]) {
      await db
          .into(db.vineRows)
          .insert(
            VineRowsCompanion.insert(
              id: row,
              projectId: 'p1',
              blockId: Value(block),
              label: row,
              createdAt: t0,
              updatedAt: t0,
            ),
          );
    }
    for (final (row, block, prefix) in [
      ('row-1', 'block-1', 'v-1-1'),
      ('row-2', 'block-1', 'v-1-2'),
      ('row-3', 'block-2', 'v-2-3'),
    ]) {
      for (var i = 1; i <= 3; i++) {
        await db
            .into(db.vines)
            .insert(
              VinesCompanion.insert(
                id: '$prefix-$i',
                projectId: 'p1',
                rowId: Value(row),
                blockId: Value(block),
                positionIdx: i,
                createdAt: t0,
                updatedAt: t0,
              ),
            );
      }
    }
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: sprayField,
            projectId: 'p1',
            name: 'spray',
            type: FieldType.text,
            createdAt: t0,
            updatedAt: t0,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    vines = VinesDao(db);
    events = FieldEventsDao(db);
    await seed();
  });

  tearDown(() async => db.close());

  group('selection resolution', () {
    test('an empty selection resolves to nothing', () async {
      expect(await vines.resolveSelection(), isEmpty);
    });

    test('individual vines', () async {
      final result = await vines.resolveSelection(
        vineIds: ['v-1-1-1', 'v-2-3-2'],
      );
      expect(result, {'v-1-1-1', 'v-2-3-2'});
    });

    test('a whole row expands to its vines', () async {
      final result = await vines.resolveSelection(rowIds: ['row-1']);
      expect(result, {'v-1-1-1', 'v-1-1-2', 'v-1-1-3'});
    });

    test('a whole block expands to every vine beneath it', () async {
      final result = await vines.resolveSelection(blockIds: ['block-1']);
      expect(result, hasLength(6));
      expect(result, contains('v-1-2-3'));
      expect(result, isNot(contains('v-2-3-1')));
    });

    test('mixed selection unions across levels', () async {
      // The case that decided Q6: three vines from one row plus a whole other
      // row. There is no single entity a row-level event could attach to.
      final result = await vines.resolveSelection(
        vineIds: ['v-1-1-1'],
        rowIds: ['row-3'],
      );
      expect(result, {'v-1-1-1', 'v-2-3-1', 'v-2-3-2', 'v-2-3-3'});
    });

    test('overlapping selections deduplicate', () async {
      // Selecting a row AND one of its vines must not write two events to it.
      final result = await vines.resolveSelection(
        vineIds: ['v-1-1-1', 'v-1-1-2'],
        rowIds: ['row-1'],
        blockIds: ['block-1'],
      );
      expect(result, hasLength(6));
    });

    test('removed vines are excluded by default', () async {
      await (db.update(db.vines)..where((v) => v.id.equals('v-1-1-2'))).write(
        VinesCompanion(status: Value(VineStatus.removed)),
      );

      final result = await vines.resolveSelection(rowIds: ['row-1']);
      expect(result, {'v-1-1-1', 'v-1-1-3'});
    });

    test('removed vines can be included explicitly', () async {
      await (db.update(db.vines)..where((v) => v.id.equals('v-1-1-2'))).write(
        VinesCompanion(status: Value(VineStatus.removed)),
      );

      final result = await vines.resolveSelection(
        rowIds: ['row-1'],
        includeInactive: true,
      );
      expect(result, hasLength(3));
    });

    test('soft-deleted vines are never returned', () async {
      await (db.update(db.vines)..where((v) => v.id.equals('v-1-1-2'))).write(
        VinesCompanion(deletedAt: Value(t0)),
      );

      final result = await vines.resolveSelection(
        rowIds: ['row-1'],
        includeInactive: true,
      );
      expect(result, hasLength(2));
    });
  });

  group('bulk recording', () {
    test('writes one event per selected vine', () async {
      final selection = await vines.resolveSelection(rowIds: ['row-1']);
      await events.recordBulk(
        vineIds: selection,
        fieldDefId: sprayField,
        value: 'Sulfur',
        observedAt: DateTime.utc(2026, 6, 15),
      );

      final byVine = await events.currentValuesForField(sprayField);
      expect(byVine, hasLength(3));
      expect(byVine['v-1-1-1']!.value, 'Sulfur');
      expect(byVine['v-1-1-3']!.value, 'Sulfur');
      // Untouched row is unaffected.
      expect(byVine.containsKey('v-1-2-1'), isFalse);
    });

    test('a bulk edit is undoable as one unit', () async {
      final selection = await vines.resolveSelection(blockIds: ['block-1']);
      final batchId = await events.recordBulk(
        vineIds: selection,
        fieldDefId: sprayField,
        value: 'oops',
        observedAt: DateTime.utc(2026, 6, 15),
      );

      expect(await events.currentValuesForField(sprayField), hasLength(6));
      expect(await events.undoBatch(batchId), 6);
      expect(await events.currentValuesForField(sprayField), isEmpty);
    });

    test('undo restores the value each vine had before', () async {
      await events.record(
        vineId: 'v-1-1-1',
        fieldDefId: sprayField,
        value: 'Copper',
        observedAt: DateTime.utc(2026, 5, 1),
      );

      final batchId = await events.recordBulk(
        vineIds: await vines.resolveSelection(rowIds: ['row-1']),
        fieldDefId: sprayField,
        value: 'Sulfur',
        observedAt: DateTime.utc(2026, 6, 15),
      );
      expect(await events.currentValue('v-1-1-1', sprayField), 'Sulfur');

      await events.undoBatch(batchId);
      expect(await events.currentValue('v-1-1-1', sprayField), 'Copper');
    });

    test(
      'a later correction to one vine survives the shared timestamp',
      () async {
        // Every event in a bulk write shares observed_at AND recorded_at. Without
        // the recorded_at tie-break, a subsequent single-vine correction at the
        // same observed_at could lose to the bulk value.
        final at = DateTime.utc(2026, 6, 15);
        await events.recordBulk(
          vineIds: await vines.resolveSelection(rowIds: ['row-1']),
          fieldDefId: sprayField,
          value: 'Sulfur',
          observedAt: at,
          now: DateTime.utc(2026, 6, 15, 10),
        );

        await events.record(
          vineId: 'v-1-1-2',
          fieldDefId: sprayField,
          value: 'Missed - skipped',
          observedAt: at,
          now: DateTime.utc(2026, 6, 15, 11),
        );

        final byVine = await events.currentValuesForField(sprayField);
        expect(byVine['v-1-1-1']!.value, 'Sulfur');
        expect(byVine['v-1-1-2']!.value, 'Missed - skipped');
      },
    );

    test('bulk events are marked as bulk', () async {
      await events.recordBulk(
        vineIds: await vines.resolveSelection(rowIds: ['row-1']),
        fieldDefId: sprayField,
        value: 'Sulfur',
      );
      final event = await events.currentEvent('v-1-1-1', sprayField);
      expect(event!.source, EventSource.bulk);
    });

    test(
      'an empty selection writes nothing and still returns a batch id',
      () async {
        final batchId = await events.recordBulk(
          vineIds: const [],
          fieldDefId: sprayField,
          value: 'nothing',
        );
        expect(batchId, isNotEmpty);
        expect(await events.currentValuesForField(sprayField), isEmpty);
      },
    );
  });

  group('vinesInRow', () {
    test('returns vines in planting order', () async {
      final result = await vines.vinesInRow('row-1');
      expect(result.map((v) => v.positionIdx), [1, 2, 3]);
    });
  });
}
