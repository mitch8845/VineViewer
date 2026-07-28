import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/db/database.dart';

void main() {
  late AppDatabase db;
  late LabelService labels;
  const projectId = 'p1';
  final t0 = DateTime.utc(2026, 1, 1);

  Future<void> block(String id, String label) => db
      .into(db.blocks)
      .insert(
        BlocksCompanion.insert(
          id: id,
          projectId: projectId,
          label: label,
          createdAt: t0,
          updatedAt: t0,
        ),
      );

  Future<void> row(String id, String label, {String? blockId}) => db
      .into(db.vineRows)
      .insert(
        VineRowsCompanion.insert(
          id: id,
          projectId: projectId,
          blockId: Value(blockId),
          label: label,
          createdAt: t0,
          updatedAt: t0,
        ),
      );

  Future<void> vine(
    String id, {
    String? rowId,
    String? blockId,
    required int plant,
  }) => db
      .into(db.vines)
      .insert(
        VinesCompanion.insert(
          id: id,
          projectId: projectId,
          rowId: Value(rowId),
          blockId: Value(blockId),
          positionIdx: plant,
          createdAt: t0,
          updatedAt: t0,
        ),
      );

  Future<String> labelText(String vineId) async =>
      (await labels.labelOf(vineId))!.text;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    await db
        .into(db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: projectId,
            name: 'Home',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
  });

  tearDown(() async => db.close());

  group('label rendering', () {
    test('a fully assigned vine reads block.row.plant', () async {
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 7);

      expect(await labelText('v1'), '3.12.7');
    });

    test('no block and no row reads 0.0.n', () async {
      await vine('v1', plant: 1);
      expect(await labelText('v1'), '0.0.1');
    });

    test('a block but no row reads block.0.n', () async {
      await block('b1', '1');
      await vine('v1', blockId: 'b1', plant: 1);
      expect(await labelText('v1'), '1.0.1');
    });

    test('a row but no block reads 0.row.n', () async {
      await row('r1', '1');
      await vine('v1', rowId: 'r1', plant: 1);
      expect(await labelText('v1'), '0.1.1');
    });

    test('labelsForProject resolves every vine in one query', () async {
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 1);
      await vine('v2', plant: 1);

      final all = await labels.labelsForProject(projectId);
      expect(all['v1']!.text, '3.12.1');
      expect(all['v2']!.text, '0.0.1');
    });

    test('a soft-deleted row leaves its vines reading 0 for the row', () async {
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 4);

      await (db.update(db.vineRows)..where((r) => r.id.equals('r1'))).write(
        VineRowsCompanion(deletedAt: Value(t0)),
      );

      expect(await labelText('v1'), '3.0.4');
    });
  });

  group('reserved labels', () {
    test('"0" cannot be used for a block or row', () async {
      // Otherwise 0.0.1 would be ambiguous between a real address and an
      // unassigned one.
      expect(LabelService.problemWithLabel('0'), contains('reserved'));
    });

    test('dots are rejected', () async {
      expect(LabelService.problemWithLabel('3.12'), contains('dot'));
    });

    test('blank is rejected', () async {
      expect(LabelService.problemWithLabel('   '), contains('empty'));
    });

    test('ordinary labels pass', () async {
      for (final ok in ['1', '12', 'North', 'A3']) {
        expect(LabelService.problemWithLabel(ok), isNull, reason: ok);
      }
    });
  });

  group('nextPlantNumber', () {
    test('starts at 1 in an empty scope', () async {
      await row('r1', '1');
      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r1'),
        1,
      );
    });

    test('fills the lowest gap rather than appending', () async {
      // Numbers should not climb forever while the row stays the same length.
      await row('r1', '1');
      await vine('v1', rowId: 'r1', plant: 1);
      await vine('v2', rowId: 'r1', plant: 2);
      await vine('v4', rowId: 'r1', plant: 4);

      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r1'),
        3,
      );
    });

    test('appends when there is no gap', () async {
      await row('r1', '1');
      for (var i = 1; i <= 3; i++) {
        await vine('v$i', rowId: 'r1', plant: i);
      }
      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r1'),
        4,
      );
    });

    test('scopes per row, so two rows both start at 1', () async {
      await row('r1', '1');
      await row('r2', '2');
      await vine('v1', rowId: 'r1', plant: 1);

      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r2'),
        1,
      );
    });

    test('unassigned vines share one scope', () async {
      // The IS NULL case. Getting this wrong numbers every free vine 1.
      await vine('v1', plant: 1);
      await vine('v2', plant: 2);

      expect(await labels.nextPlantNumber(projectId: projectId), 3);
    });

    test('block-only vines are scoped per block', () async {
      await block('b1', '1');
      await block('b2', '2');
      await vine('v1', blockId: 'b1', plant: 1);

      // 1.0.1 exists; 2.0.1 is still free.
      expect(
        await labels.nextPlantNumber(projectId: projectId, blockId: 'b2'),
        1,
      );
      expect(
        await labels.nextPlantNumber(projectId: projectId, blockId: 'b1'),
        2,
      );
    });

    test('ignores soft-deleted vines', () async {
      await row('r1', '1');
      await vine('v1', rowId: 'r1', plant: 1);
      await (db.update(db.vines)..where((v) => v.id.equals('v1'))).write(
        VinesCompanion(deletedAt: Value(t0)),
      );

      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r1'),
        1,
      );
    });
  });

  group('assignToRow', () {
    test('renumbers into the new row and inherits its block', () async {
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('existing', rowId: 'r1', blockId: 'b1', plant: 1);
      await vine('free', plant: 1);

      final label = await labels.assignToRow(vineId: 'free', rowId: 'r1');

      expect(label.text, '3.12.2');
      final moved = await (db.select(
        db.vines,
      )..where((v) => v.id.equals('free'))).getSingle();
      expect(moved.blockId, 'b1', reason: 'block should follow the row');
    });

    test('releases the old number for reuse', () async {
      await row('r1', '1');
      await row('r2', '2');
      await vine('v1', rowId: 'r1', plant: 1);
      await vine('v2', rowId: 'r1', plant: 2);

      await labels.assignToRow(vineId: 'v1', rowId: 'r2');

      // 1 is now free in r1.
      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r1'),
        1,
      );
    });

    test('throws for a row that does not exist', () async {
      await vine('v1', plant: 1);
      expect(
        () => labels.assignToRow(vineId: 'v1', rowId: 'nope'),
        throwsStateError,
      );
    });
  });

  group('detachFromRow', () {
    test('clears the row and renumbers, keeping the block', () async {
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 5);

      final label = await labels.detachFromRow(vineId: 'v1');

      expect(label.text, '3.0.1');
      final detached = await (db.select(
        db.vines,
      )..where((v) => v.id.equals('v1'))).getSingle();
      expect(detached.rowId, isNull);
      expect(detached.blockId, 'b1');
      expect(detached.pathOffset, isNull);
    });

    test('a detached vine no longer occupies its old number', () async {
      await row('r1', '1');
      await vine('v1', rowId: 'r1', plant: 1);
      await labels.detachFromRow(vineId: 'v1');

      expect(
        await labels.nextPlantNumber(projectId: projectId, rowId: 'r1'),
        1,
      );
    });
  });

  group('assignToBlock', () {
    test('moves a vine off its row into a block', () async {
      await block('b1', '3');
      await block('b2', '4');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 5);

      final label = await labels.assignToBlock(vineId: 'v1', blockId: 'b2');

      expect(label.text, '4.0.1');
      final moved = await (db.select(
        db.vines,
      )..where((v) => v.id.equals('v1'))).getSingle();
      // Staying on the row would make the vine's block disagree with its
      // row's -- two sources for one fact.
      expect(moved.rowId, isNull);
    });

    test('passing null moves it to fully unassigned', () async {
      await block('b1', '3');
      await vine('v1', blockId: 'b1', plant: 1);

      expect(
        (await labels.assignToBlock(vineId: 'v1', blockId: null)).text,
        '0.0.1',
      );
    });
  });

  group('renumberRow', () {
    test('closes gaps, in path order', () async {
      await row('r1', '1');
      for (final (id, plant, offset) in [
        ('v1', 5, 0.0),
        ('v2', 9, 10.0),
        ('v3', 22, 20.0),
      ]) {
        await vine(id, rowId: 'r1', plant: plant);
        await (db.update(db.vines)..where((v) => v.id.equals(id))).write(
          VinesCompanion(pathOffset: Value(offset)),
        );
      }

      await labels.renumberRow('r1');

      expect(await labelText('v1'), '0.1.1');
      expect(await labelText('v2'), '0.1.2');
      expect(await labelText('v3'), '0.1.3');
    });

    test('orders by position along the row, not by old number', () async {
      // A vine inserted at the front of the row should become 1 even though it
      // was numbered last.
      await row('r1', '1');
      await vine('early', rowId: 'r1', plant: 99);
      await vine('late', rowId: 'r1', plant: 1);
      await (db.update(db.vines)..where((v) => v.id.equals('early'))).write(
        const VinesCompanion(pathOffset: Value(0)),
      );
      await (db.update(db.vines)..where((v) => v.id.equals('late'))).write(
        const VinesCompanion(pathOffset: Value(50)),
      );

      await labels.renumberRow('r1');

      expect(await labelText('early'), '0.1.1');
      expect(await labelText('late'), '0.1.2');
    });
  });

  group('uniqueness audit', () {
    test('a well-formed project has no duplicates', () async {
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 1);
      await vine('v2', rowId: 'r1', blockId: 'b1', plant: 2);

      expect(await labels.findDuplicateLabels(projectId), isEmpty);
    });

    test('detects duplicates written around the service', () async {
      // Import and archive restore write rows directly, so being able to prove
      // uniqueness afterwards matters -- it is not enforced by a constraint.
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', rowId: 'r1', blockId: 'b1', plant: 1);
      await vine('v2', rowId: 'r1', blockId: 'b1', plant: 1);

      expect(await labels.findDuplicateLabels(projectId), ['3.12.1']);
    });

    test('same plant number in different rows is not a duplicate', () async {
      await row('r1', '1');
      await row('r2', '2');
      await vine('v1', rowId: 'r1', plant: 1);
      await vine('v2', rowId: 'r2', plant: 1);

      expect(await labels.findDuplicateLabels(projectId), isEmpty);
    });
  });

  group('the full assignment lifecycle', () {
    test('a vine keeps its identity while its label changes', () async {
      // The invariant that makes renumbering safe: the UUID never moves, so
      // every field event stays attached no matter how the address changes.
      await block('b1', '3');
      await row('r1', '12', blockId: 'b1');
      await vine('v1', plant: 1);

      expect(await labelText('v1'), '0.0.1');

      await labels.assignToRow(vineId: 'v1', rowId: 'r1');
      expect(await labelText('v1'), '3.12.1');

      await labels.detachFromRow(vineId: 'v1');
      expect(await labelText('v1'), '3.0.1');

      await labels.assignToBlock(vineId: 'v1', blockId: null);
      expect(await labelText('v1'), '0.0.1');

      final stillThere = await (db.select(
        db.vines,
      )..where((v) => v.id.equals('v1'))).getSingle();
      expect(stillThere.id, 'v1');
    });
  });
}
