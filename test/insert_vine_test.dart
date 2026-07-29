import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';

/// Inserting a vine mid-row, and the choice it puts to the user.
///
/// Plan section 6.3 recommended a suffix (`3.12.6a`) so nothing downstream
/// moved. That is superseded: plant numbers are integers, so the two options
/// that actually exist are "shift everything down" and "reuse a gap", and which
/// is right depends on whether there is a printed map in somebody's pocket.
/// The app asks rather than guessing.
void main() {
  late AppDatabase db;
  late LabelService labels;
  late LayoutDao layout;

  late String projectId;
  late String rowId;
  late List<String> vineIds;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    layout = LayoutDao(db, labels);

    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    final blockId = await layout.createBlock(projectId: projectId, label: '3');
    rowId = await layout.createRow(
      projectId: projectId,
      label: '12',
      blockId: blockId,
      path: Polyline([const Offset(0, 0), const Offset(400, 0)]),
    );
    vineIds = await layout.placeVinesAlongRow(
      rowId: rowId,
      offsets: [for (var i = 0; i < 8; i++) i * 50.0],
    );
  });

  tearDown(() async => db.close());

  Future<String> freeVine() =>
      layout.createVine(projectId: projectId, position: const Offset(275, 0));

  Future<List<int>> numbersInRow() async {
    final rows =
        await (db.select(db.vines)
              ..where((v) => v.rowId.equals(rowId))
              ..orderBy([(v) => OrderingTerm.asc(v.positionIdx)]))
            .get();
    return [for (final v in rows) v.positionIdx];
  }

  group('shift', () {
    test('the new vine takes the next number and the rest move up', () async {
      final vine = await freeVine();
      final plant = await labels.insertAfter(
        vineId: vine,
        rowId: rowId,
        afterPositionIdx: 6,
        shift: true,
      );

      expect(plant, 7);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect((await labels.labelOf(vine))!.text, '3.12.7');
    });

    test('vines before the insertion point are untouched', () async {
      final before = await labels.labelOf(vineIds[2]);
      await labels.insertAfter(
        vineId: await freeVine(),
        rowId: rowId,
        afterPositionIdx: 6,
        shift: true,
      );
      expect(await labels.labelOf(vineIds[2]), before);
    });

    test('every vine after it shifts by exactly one', () async {
      await labels.insertAfter(
        vineId: await freeVine(),
        rowId: rowId,
        afterPositionIdx: 6,
        shift: true,
      );
      // 3.12.7 became 3.12.8, and 3.12.8 became 3.12.9.
      expect((await labels.labelOf(vineIds[6]))!.text, '3.12.8');
      expect((await labels.labelOf(vineIds[7]))!.text, '3.12.9');
    });

    test('inserting at the end shifts nothing', () async {
      final vine = await freeVine();
      final plant = await labels.insertAfter(
        vineId: vine,
        rowId: rowId,
        afterPositionIdx: 8,
        shift: true,
      );
      expect(plant, 9);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('the row stays free of duplicates', () async {
      await labels.insertAfter(
        vineId: await freeVine(),
        rowId: rowId,
        afterPositionIdx: 3,
        shift: true,
      );
      expect(await labels.findDuplicateLabels(projectId), isEmpty);
    });

    test('the vine inherits the row block', () async {
      final vine = await freeVine();
      await labels.insertAfter(
        vineId: vine,
        rowId: rowId,
        afterPositionIdx: 2,
        shift: true,
      );
      expect((await labels.labelOf(vine))!.block, '3');
    });
  });

  group('gap fill', () {
    test('reuses the number a removed vine left behind', () async {
      // Vine 3 was pulled years ago. Its slot is the obvious home for a
      // replant, and using it renames nothing.
      await db.customStatement('DELETE FROM vines WHERE id = ?', [vineIds[2]]);
      expect(await numbersInRow(), [1, 2, 4, 5, 6, 7, 8]);

      final vine = await freeVine();
      final plant = await labels.insertAfter(
        vineId: vine,
        rowId: rowId,
        afterPositionIdx: 6,
        shift: false,
      );

      expect(plant, 3);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('appends when the row is full', () async {
      final vine = await freeVine();
      final plant = await labels.insertAfter(
        vineId: vine,
        rowId: rowId,
        afterPositionIdx: 4,
        shift: false,
      );

      expect(plant, 9);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('renames nothing', () async {
      final before = {
        for (final id in vineIds) id: (await labels.labelOf(id))!.text,
      };

      await labels.insertAfter(
        vineId: await freeVine(),
        rowId: rowId,
        afterPositionIdx: 4,
        shift: false,
      );

      for (final entry in before.entries) {
        expect((await labels.labelOf(entry.key))!.text, entry.value);
      }
    });
  });

  group('the prompt has a number to show', () {
    test('counts the vines a shift would rename', () async {
      expect(
        await labels.countAffectedByShift(rowId: rowId, afterPositionIdx: 6),
        2,
      );
      expect(
        await labels.countAffectedByShift(rowId: rowId, afterPositionIdx: 0),
        8,
      );
      expect(
        await labels.countAffectedByShift(rowId: rowId, afterPositionIdx: 8),
        0,
      );
    });

    test('the count matches what actually changes', () async {
      final predicted = await labels.countAffectedByShift(
        rowId: rowId,
        afterPositionIdx: 3,
      );

      final before = {
        for (final id in vineIds) id: (await labels.labelOf(id))!.text,
      };
      await labels.insertAfter(
        vineId: await freeVine(),
        rowId: rowId,
        afterPositionIdx: 3,
        shift: true,
      );

      var changed = 0;
      for (final entry in before.entries) {
        if ((await labels.labelOf(entry.key))!.text != entry.value) changed++;
      }
      expect(changed, predicted);
    });
  });
}
