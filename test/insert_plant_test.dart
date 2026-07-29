import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Inserting a plant mid-row, and the choice it puts to the user.
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

  late List<String> plantIds;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    layout = LayoutDao(db, labels, MembershipService(db));
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');

    final rowField =
        ((await FieldDefsDao(db).create(
                  projectId: projectId,
                  name: 'Row',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polyline,
                  isContainer: true,
                ))
                as FieldDefSaved)
            .id;
    rowId = await layout.createObject(
      projectId: projectId,
      fieldDefId: rowField,
      label: '12',
      geometry: PolylineShape(
        Polyline([const Offset(0, 0), const Offset(400, 0)]),
      ),
    );
    plantIds = await layout.placePlantsAlongCarrier(
      carrierId: rowId,
      offsets: [for (var i = 0; i < 8; i++) i * 50.0],
    );
  });

  tearDown(() async => db.close());

  Future<String> freePlant() =>
      layout.createPlant(projectId: projectId, position: const Offset(275, 0));

  Future<List<int>> numbersInRow() async {
    final rows =
        await (db.select(db.plants)
              ..where((v) => v.carrierId.equals(rowId))
              ..orderBy([(v) => OrderingTerm.asc(v.positionIdx)]))
            .get();
    return [for (final v in rows) v.positionIdx];
  }

  group('shift', () {
    test('the new plant takes the next number and the rest move up', () async {
      final plant = await freePlant();

      final number = await labels.insertAfter(
        plantId: plant,
        carrierId: rowId,
        afterPositionIdx: 6,
        shift: true,
      );
      expect(number, 7);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      // Bare numbers: this project has no identifier template, so the plant
      // part is the whole identifier. What matters here is the numbering, not
      // how it renders.
      expect((await labels.identifierOf(plant))!.text, '7');
    });

    test('plants before the insertion point are untouched', () async {
      final before = await labels.identifierOf(plantIds[2]);
      await labels.insertAfter(
        plantId: await freePlant(),
        carrierId: rowId,
        afterPositionIdx: 6,
        shift: true,
      );
      expect(await labels.identifierOf(plantIds[2]), before);
    });

    test('every plant after it shifts by exactly one', () async {
      await labels.insertAfter(
        plantId: await freePlant(),
        carrierId: rowId,
        afterPositionIdx: 6,
        shift: true,
      );
      // Plant 7 became 8, and 8 became 9.
      expect((await labels.identifierOf(plantIds[6]))!.text, '8');
      expect((await labels.identifierOf(plantIds[7]))!.text, '9');
    });

    test('inserting at the end shifts nothing', () async {
      final plant = await freePlant();

      final number = await labels.insertAfter(
        plantId: plant,
        carrierId: rowId,
        afterPositionIdx: 8,
        shift: true,
      );
      expect(number, 9);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('the row stays free of duplicates', () async {
      await labels.insertAfter(
        plantId: await freePlant(),
        carrierId: rowId,
        afterPositionIdx: 3,
        shift: true,
      );
      expect(await labels.findDuplicateIdentifiers(projectId), isEmpty);
    });

    test('the inserted plant comes out with an identifier', () async {
      final plant = await freePlant();
      await labels.insertAfter(
        plantId: plant,
        carrierId: rowId,
        afterPositionIdx: 2,
        shift: true,
      );
      expect((await labels.identifierOf(plant))!.text, isNotEmpty);
    });
  });

  group('gap fill', () {
    test('reuses the number a removed plant left behind', () async {
      // Plant 3 was pulled years ago. Its slot is the obvious home for a
      // replant, and using it renames nothing.
      await db.customStatement('DELETE FROM plants WHERE id = ?', [
        plantIds[2],
      ]);
      expect(await numbersInRow(), [1, 2, 4, 5, 6, 7, 8]);

      final plant = await freePlant();

      final number = await labels.insertAfter(
        plantId: plant,
        carrierId: rowId,
        afterPositionIdx: 6,
        shift: false,
      );
      expect(number, 3);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('appends when the row is full', () async {
      final plant = await freePlant();

      final number = await labels.insertAfter(
        plantId: plant,
        carrierId: rowId,
        afterPositionIdx: 4,
        shift: false,
      );
      expect(number, 9);
      expect(await numbersInRow(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('renames nothing', () async {
      final before = {
        for (final id in plantIds) id: (await labels.identifierOf(id))!.text,
      };
      await labels.insertAfter(
        plantId: await freePlant(),
        carrierId: rowId,
        afterPositionIdx: 4,
        shift: false,
      );
      for (final entry in before.entries) {
        expect((await labels.identifierOf(entry.key))!.text, entry.value);
      }
    });
  });

  group('the prompt has a number to show', () {
    test('counts the plants a shift would rename', () async {
      expect(
        await labels.countAffectedByShift(
          carrierId: rowId,
          afterPositionIdx: 6,
        ),
        2,
      );
      expect(
        await labels.countAffectedByShift(
          carrierId: rowId,
          afterPositionIdx: 0,
        ),
        8,
      );
      expect(
        await labels.countAffectedByShift(
          carrierId: rowId,
          afterPositionIdx: 8,
        ),
        0,
      );
    });

    test('the count matches what actually changes', () async {
      final predicted = await labels.countAffectedByShift(
        carrierId: rowId,
        afterPositionIdx: 3,
      );

      final before = {
        for (final id in plantIds) id: (await labels.identifierOf(id))!.text,
      };
      await labels.insertAfter(
        plantId: await freePlant(),
        carrierId: rowId,
        afterPositionIdx: 3,
        shift: true,
      );
      var changed = 0;
      for (final entry in before.entries) {
        if ((await labels.identifierOf(entry.key))!.text != entry.value) {
          changed++;
        }
      }
      expect(changed, predicted);
    });
  });
}
