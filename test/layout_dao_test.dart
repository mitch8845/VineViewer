import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/row_generation.dart';

/// A 100px horizontal row starting at (0,0).
Polyline get straight => Polyline([const Offset(0, 0), const Offset(100, 0)]);

void main() {
  late AppDatabase db;
  late ProjectsDao projects;
  late LabelService labels;
  late LayoutDao layout;
  late String projectId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectsDao(db);
    labels = LabelService(db);
    layout = LayoutDao(db, labels);
    projectId = await projects.create(name: 'Home');
  });

  tearDown(() async => db.close());

  Future<Vine> vineById(String id) =>
      (db.select(db.vines)..where((v) => v.id.equals(id))).getSingle();

  /// The invariant this whole class exists to keep.
  Future<void> expectSnappedOnRow(String vineId) async {
    final vine = await vineById(vineId);
    expect(vine.rowId, isNotNull, reason: 'expected a snapped vine');
    final path = (await layout.pathOf(vine.rowId!))!;
    final expected = path.pointAt(vine.pathOffset!);
    expect(vine.x, closeTo(expected.dx, 1e-9));
    expect(vine.y, closeTo(expected.dy, 1e-9));
  }

  group('creating layout', () {
    test('a block rejects the reserved label', () async {
      expect(
        () => layout.createBlock(projectId: projectId, label: '0'),
        throwsArgumentError,
      );
    });

    test('a row stores its polyline', () async {
      final blockId = await layout.createBlock(
        projectId: projectId,
        label: '3',
      );
      final rowId = await layout.createRow(
        projectId: projectId,
        label: '12',
        blockId: blockId,
        path: straight,
      );

      final path = await layout.pathOf(rowId);
      expect(path!.length, 100);
    });

    test('a free vine goes exactly where it is put', () async {
      final id = await layout.createVine(
        projectId: projectId,
        position: const Offset(42, 17),
      );
      final vine = await vineById(id);
      expect(vine.x, 42);
      expect(vine.y, 17);
      expect(vine.rowId, isNull);
      expect((await labels.labelOf(id))!.text, '0.0.1');
    });
  });

  group('placing vines along a row', () {
    late String blockId;
    late String rowId;

    setUp(() async {
      blockId = await layout.createBlock(projectId: projectId, label: '3');
      rowId = await layout.createRow(
        projectId: projectId,
        label: '12',
        blockId: blockId,
        path: straight,
      );
    });

    test('by count places them evenly, numbered along the path', () async {
      final ids = await layout.placeVinesAlongRow(
        rowId: rowId,
        offsets: RowGeneration.byCount(straight, 5),
      );

      expect(ids, hasLength(5));
      final all = await labels.labelsForProject(projectId);
      expect(all[ids.first]!.text, '3.12.1');
      expect(all[ids.last]!.text, '3.12.5');

      final first = await vineById(ids.first);
      expect(first.x, 0);
      final last = await vineById(ids.last);
      expect(last.x, 100);
    });

    test('every placed vine satisfies the snap invariant', () async {
      final ids = await layout.placeVinesAlongRow(
        rowId: rowId,
        offsets: RowGeneration.bySpacing(straight, 25),
      );
      for (final id in ids) {
        await expectSnappedOnRow(id);
      }
    });

    test('re-running the tool does not renumber existing vines', () async {
      // A partly planted row is common: you lay out most of it, then come back
      // and fill in. Renumbering what is already there would invalidate any
      // printed map.
      final first = await layout.placeVinesAlongRow(
        rowId: rowId,
        offsets: [0, 50],
      );
      final firstLabels = await labels.labelsForProject(projectId);
      final before = firstLabels[first.first]!.text;

      await layout.placeVinesAlongRow(rowId: rowId, offsets: [25, 75]);

      final after = await labels.labelsForProject(projectId);
      expect(after[first.first]!.text, before);
      expect(after.length, 4);
    });

    test('refuses to place on a row that has not been drawn', () async {
      final undrawn = await layout.createRow(
        projectId: projectId,
        label: '13',
        blockId: blockId,
      );
      expect(
        () => layout.placeVinesAlongRow(rowId: undrawn, offsets: [0]),
        throwsStateError,
      );
    });

    test('placing nothing is a no-op', () async {
      expect(
        await layout.placeVinesAlongRow(rowId: rowId, offsets: []),
        isEmpty,
      );
    });
  });

  group('reshaping a row', () {
    late String rowId;
    late List<String> vineIds;

    setUp(() async {
      final blockId = await layout.createBlock(
        projectId: projectId,
        label: '3',
      );
      rowId = await layout.createRow(
        projectId: projectId,
        label: '12',
        blockId: blockId,
        path: straight,
      );
      vineIds = await layout.placeVinesAlongRow(
        rowId: rowId,
        offsets: [0, 25, 50],
      );
    });

    test(
      'extending the far end leaves existing vines exactly where they were',
      () async {
        // This is why the offset is stored rather than re-derived. Re-projecting
        // x/y onto the new path would nudge every vine slightly on each edit,
        // and the drift compounds.
        final before = [for (final id in vineIds) await vineById(id)];

        await layout.updateRowPath(
          rowId,
          Polyline([const Offset(0, 0), const Offset(500, 0)]),
        );

        for (var i = 0; i < vineIds.length; i++) {
          final after = await vineById(vineIds[i]);
          expect(after.x, closeTo(before[i].x!, 1e-9), reason: 'vine $i');
          expect(after.y, closeTo(before[i].y!, 1e-9), reason: 'vine $i');
        }
      },
    );

    test('bending the row carries its vines around the corner', () async {
      // An L: right 100, then down 100.
      await layout.updateRowPath(
        rowId,
        Polyline([
          const Offset(0, 0),
          const Offset(50, 0),
          const Offset(50, 50),
        ]),
      );

      // vineIds are at offsets 0, 25, 50. The corner of the new path is at
      // offset 50, so the third vine lands exactly on it and the second sits
      // halfway along the first leg.
      final onCorner = await vineById(vineIds[2]);
      expect(onCorner.x, closeTo(50, 1e-9));
      expect(onCorner.y, closeTo(0, 1e-9));

      final middle = await vineById(vineIds[1]);
      expect(middle.x, closeTo(25, 1e-9));
      expect(middle.y, closeTo(0, 1e-9));

      for (final id in vineIds) {
        await expectSnappedOnRow(id);
      }
    });

    test(
      'shortening past a vine parks it at the end rather than losing it',
      () async {
        await layout.updateRowPath(
          rowId,
          Polyline([const Offset(0, 0), const Offset(30, 0)]),
        );

        // The vine that was at 50 is beyond the new end.
        final stranded = await vineById(vineIds[2]);
        expect(stranded.x, 30);
        // Still visible and still on the row, so the user can see and fix it.
        expect(stranded.rowId, rowId);
      },
    );

    test('moving a row takes its vines with it', () async {
      final before = await vineById(vineIds[1]);

      await layout.moveRow(rowId, const Offset(200, 300));

      final after = await vineById(vineIds[1]);
      expect(after.x, closeTo(before.x! + 200, 1e-9));
      expect(after.y, closeTo(before.y! + 300, 1e-9));
      await expectSnappedOnRow(vineIds[1]);
    });
  });

  group('snapping', () {
    late String rowId;

    setUp(() async {
      rowId = await layout.createRow(
        projectId: projectId,
        label: '1',
        path: straight,
      );
      // Give the row a vine so it can be reached from the project.
      await layout.placeVinesAlongRow(rowId: rowId, offsets: [0]);
    });

    test('snapping slides the vine onto the nearest point', () async {
      final id = await layout.createVine(
        projectId: projectId,
        position: const Offset(60, 40),
      );

      final moved = await layout.snapVineToRow(vineId: id, rowId: rowId);

      expect(moved, closeTo(40, 1e-9));
      final vine = await vineById(id);
      expect(vine.x, closeTo(60, 1e-9));
      expect(vine.y, closeTo(0, 1e-9));
      await expectSnappedOnRow(id);
    });

    test('snapping gives the vine an address in its new row', () async {
      final id = await layout.createVine(
        projectId: projectId,
        position: const Offset(60, 40),
      );
      // 0.0.1, not 0.0.2: the vine already on the row occupies 0.1.1, which is
      // a different numbering scope. That separation is the point of scoping
      // by (block, row) rather than counting vines project-wide.
      expect((await labels.labelOf(id))!.text, '0.0.1');

      await layout.snapVineToRow(vineId: id, rowId: rowId);
      // Now it joins the row's scope, where 1 is taken.
      expect((await labels.labelOf(id))!.text, '0.1.2');
    });

    test('unsnapping leaves the vine where it is on screen', () async {
      final id = await layout.createVine(
        projectId: projectId,
        position: const Offset(60, 40),
      );
      await layout.snapVineToRow(vineId: id, rowId: rowId);
      final onRow = await vineById(id);

      await layout.unsnapVine(id);

      final free = await vineById(id);
      expect(free.rowId, isNull);
      expect(free.pathOffset, isNull);
      expect(free.x, onRow.x, reason: 'it should not jump when detached');
      expect(free.y, onRow.y);
    });
  });

  group('moving a vine', () {
    test('a free vine goes exactly where it is put', () async {
      final id = await layout.createVine(
        projectId: projectId,
        position: const Offset(10, 10),
      );

      await layout.moveVine(id, const Offset(80, 90));

      final vine = await vineById(id);
      expect(vine.x, 80);
      expect(vine.y, 90);
    });

    test('a snapped vine slides along its row instead of leaving it', () async {
      // Dragging sideways moves it along the row, never off. Detaching is an
      // explicit action, so a clumsy drag cannot silently break the row.
      final rowId = await layout.createRow(
        projectId: projectId,
        label: '1',
        path: straight,
      );
      final ids = await layout.placeVinesAlongRow(
        rowId: rowId,
        offsets: [0, 50],
      );

      await layout.moveVine(ids[1], const Offset(75, 60));

      final vine = await vineById(ids[1]);
      expect(vine.rowId, rowId, reason: 'still on the row');
      expect(vine.x, closeTo(75, 1e-9));
      expect(vine.y, closeTo(0, 1e-9), reason: 'pulled back onto the line');
      await expectSnappedOnRow(ids[1]);
    });

    test('dragging past the end clamps to the end of the row', () async {
      final rowId = await layout.createRow(
        projectId: projectId,
        label: '1',
        path: straight,
      );
      final ids = await layout.placeVinesAlongRow(rowId: rowId, offsets: [0]);

      await layout.moveVine(ids.first, const Offset(500, 0));

      final vine = await vineById(ids.first);
      expect(vine.x, closeTo(100, 1e-9));
      await expectSnappedOnRow(ids.first);
    });
  });

  group('reading back for the canvas', () {
    test('vinesInProject returns everything, snapped or not', () async {
      final rowId = await layout.createRow(
        projectId: projectId,
        label: '1',
        path: straight,
      );
      await layout.placeVinesAlongRow(rowId: rowId, offsets: [0, 50]);
      await layout.createVine(
        projectId: projectId,
        position: const Offset(500, 500),
      );

      expect(await layout.vinesInProject(projectId), hasLength(3));
    });

    test('rowsInProject includes a freshly drawn, empty row', () async {
      // Reaching rows only through their vines would hide a row the user just
      // drew but has not planted yet -- it would vanish from the canvas.
      final blockId = await layout.createBlock(
        projectId: projectId,
        label: '3',
      );
      await layout.createRow(
        projectId: projectId,
        label: '12',
        blockId: blockId,
        path: straight,
      );

      expect(await layout.rowsInProject(projectId), hasLength(1));
    });
  });
}
