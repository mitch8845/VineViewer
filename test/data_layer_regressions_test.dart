import 'dart:ui' show Offset, Rect;

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/numbering_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/geometry/spatial_index.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// Regressions from a review of the data layer.
///
/// Each group pins one bug that was confirmed against the code before it was
/// fixed. They live together because most of them are about the same promise
/// -- **no operation may produce two plants with the same identifier, and none
/// may be refused for a duplicate it did not cause** -- seen from different
/// entry points.
void main() {
  late AppDatabase db;
  late LabelService labels;
  late MembershipService memberships;
  late LayoutDao layout;
  late FieldDefsDao fields;
  late OperationRecorder recorder;
  late String projectId;
  late String rowField;
  late String blockField;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    memberships = MembershipService(db);
    layout = LayoutDao(db, labels, memberships);
    fields = FieldDefsDao(db);
    recorder = OperationRecorder(db);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');

    rowField =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Row',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polyline,
                  isContainer: true,
                ))
                as FieldDefSaved)
            .id;
    blockField =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Block',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polygon,
                  isContainer: true,
                ))
                as FieldDefSaved)
            .id;
  });

  tearDown(() async => db.close());

  Future<void> useTemplate(List<IdPart> parts) =>
      ProjectsDao(db).setIdentifierTemplate(
        projectId,
        IdentifierTemplate(delimiter: '.', parts: parts),
      );

  Future<String> row(String label, Offset a, Offset b) => layout.createObject(
    projectId: projectId,
    fieldDefId: rowField,
    label: label,
    geometry: PolylineShape(Polyline([a, b])),
  );

  Shape squareAt(double left, double top, double size) => PolygonShape([
    Offset(left, top),
    Offset(left + size, top),
    Offset(left + size, top + size),
    Offset(left, top + size),
  ]);

  Future<String> blockAt(String label, double left) => layout.createObject(
    projectId: projectId,
    fieldDefId: blockField,
    label: label,
    geometry: squareAt(left, -50, 100),
  );

  Future<T> gesture<T>(String description, Future<T> Function() body) =>
      recorder.run(
        projectId: projectId,
        kind: 'test',
        description: description,
        body: body,
      );

  Future<Set<String>> objectsHolding(String plantId) async {
    final rows = await db
        .customSelect(
          'SELECT object_id FROM plant_memberships WHERE plant_id = ?',
          variables: [Variable<String>(plantId)],
        )
        .get();
    return {for (final r in rows) r.read<String>('object_id')};
  }

  Future<String> idOf(String plantId) async =>
      (await labels.identifierOf(plantId))!.text;

  // ---------------------------------------------------------------- item 1

  group('label history', () {
    test('a plant moving between blocks reads old then new', () async {
      // Reconcile inserts the new membership before deleting the old one. The
      // walk used to replay that delete as "no block at all", so the plant
      // appeared to pass through 0.7 on its way from 1.7 to 2.7.
      await useTemplate([FieldPart(blockField), const PlantPart()]);
      await blockAt('1', 0);
      await blockAt('2', 100);
      final v = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 0),
      );
      await db.customStatement(
        "UPDATE plants SET position_idx = 7 WHERE id = '$v'",
      );

      await gesture(
        'Move plant',
        () => layout.movePlant(v, const Offset(150, 0)),
      );

      expect((await labels.historyOf(v)).map((c) => c.identifier.text), [
        '1.7',
        '2.7',
      ]);
    });

    test('a plant created in one gesture has no intermediate ids', () async {
      // Created inside a block *and* on a row: two membership rows, and
      // recording after each journal row used to list 0.0.1 and 1.0.1 -- states
      // that never existed outside the transaction.
      await useTemplate([
        FieldPart(blockField),
        FieldPart(rowField),
        const PlantPart(),
      ]);
      await blockAt('1', 0);
      await row('12', const Offset(0, 0), const Offset(100, 0));

      final v = await gesture(
        'Add plant',
        () => layout.createPlant(
          projectId: projectId,
          position: const Offset(50, 2),
        ),
      );

      final history = await labels.historyOf(v);
      expect(history.map((c) => c.identifier.text), ['1.12.1']);
      expect(history.single.reason, 'Add plant');
    });
  });

  // ---------------------------------------------------------------- item 2

  group('retired plants', () {
    test('a replant does not block every later identifier change', () async {
      await useTemplate([FieldPart(rowField), const PlantPart()]);
      final a = await row('1', const Offset(0, 0), const Offset(400, 0));
      final b = await row('2', const Offset(0, 100), const Offset(400, 100));
      final onA = await layout.placePlantsAlongCarrier(
        carrierId: a,
        offsets: [10, 20],
      );
      final onB = await layout.placePlantsAlongCarrier(
        carrierId: b,
        offsets: [10, 20],
      );

      final successor = await layout.replacePlant(plantId: onA.first);
      expect(await idOf(successor), '1.1');
      // The dead plant keeps its historical label, and that is not a clash.
      expect(await idOf(onA.first), '1.1');
      expect(await labels.findDuplicateIdentifiers(projectId), isEmpty);

      // Something entirely unrelated, on another row.
      final numbering = NumberingService(db, labels);
      final result = await numbering.apply(
        await numbering.plan(
          plantIds: onB.toSet(),
          startAt: 1,
          order: NumberingOrder.rightToLeft,
        ),
        projectId: projectId,
      );
      expect(result, isA<NumberingApplied>());
    });

    test('a retired number is reused by the next plant on the row', () async {
      // TESTING.md: retire plant 3, plant a new one, and it becomes 3.
      final r = await row('12', const Offset(0, 0), const Offset(400, 0));
      final ids = await layout.placePlantsAlongCarrier(
        carrierId: r,
        offsets: [10, 20, 30],
      );
      await layout.retirePlant(ids[2], change: PlantStatusChange.removed);

      final added = await layout.placePlantsAlongCarrier(
        carrierId: r,
        offsets: [40],
      );
      expect((await layout.plantById(added.single))!.positionIdx, 3);
      expect(
        await labels.nextPlantNumber(projectId: projectId, carrierId: r),
        4,
      );
    });

    test('retiring twice keeps the original end date', () async {
      final r = await row('12', const Offset(0, 0), const Offset(400, 0));
      final ids = await layout.placePlantsAlongCarrier(
        carrierId: r,
        offsets: [10],
      );
      await layout.retirePlant(
        ids.single,
        change: PlantStatusChange.removed,
        now: DateTime.utc(2025),
      );
      await layout.retirePlant(
        ids.single,
        change: PlantStatusChange.missing,
        now: DateTime.utc(2026),
      );

      final plant = (await layout.plantById(ids.single))!;
      expect(plant.endedAt, DateTime.utc(2025));
      expect(plant.status, PlantStatus.removed);
    });

    test('compare reports only duplicates the change introduces', () {
      PlantIdentifier id(String t) =>
          PlantIdentifier(parts: [t], delimiter: '.');

      // a and b already collide -- an import, say. Changing c is not that
      // change's fault.
      final before = {'a': id('1'), 'b': id('1'), 'c': id('2')};
      expect(
        LabelService.compare(before, {...before, 'c': id('3')}).duplicates,
        isEmpty,
      );
      // Joining the existing collision *is* the change's fault.
      expect(
        LabelService.compare(before, {...before, 'c': id('1')}).duplicates,
        ['1'],
      );
      // So is swapping who holds it, though the count is the same.
      expect(
        LabelService.compare(before, {
          'a': id('9'),
          'b': id('1'),
          'c': id('1'),
        }).duplicates,
        ['1'],
      );
    });
  });

  // ---------------------------------------------------------------- item 3

  group('new free plants', () {
    test('a free plant near a row does not duplicate its plant 1', () async {
      await useTemplate([FieldPart(rowField), const PlantPart()]);
      final r = await row('12', const Offset(0, 0), const Offset(400, 0));
      await layout.placePlantsAlongCarrier(carrierId: r, offsets: [10, 20]);

      // Within tolerance of Row 12, so it renders as 12.<n>, but numbered from
      // the carrier-less pool -- which used to give it 1.
      final free = await layout.createPlant(
        projectId: projectId,
        position: const Offset(100, 3),
      );

      expect(await objectsHolding(free), {r});
      expect(await idOf(free), '12.3');
      expect(await labels.findDuplicateIdentifiers(projectId), isEmpty);

      // A free plant out in the open still starts the carrier-less pool at 1.
      final open = await layout.createPlant(
        projectId: projectId,
        position: const Offset(100, 300),
      );
      expect(await idOf(open), '0.1');
    });

    test('unsnapping a plant beside its row does not duplicate', () async {
      await useTemplate([FieldPart(rowField), const PlantPart()]);
      final r = await row('12', const Offset(0, 0), const Offset(400, 0));
      final ids = await layout.placePlantsAlongCarrier(
        carrierId: r,
        offsets: [10, 20, 30],
      );

      await layout.unsnapPlant(ids[1]);

      expect((await layout.plantById(ids[1]))!.carrierId, isNull);
      expect(await labels.findDuplicateIdentifiers(projectId), isEmpty);
    });
  });

  // ---------------------------------------------------------------- item 4

  group('merging across a gap', () {
    test('joinOffset includes the bridging segment', () {
      final a = Polyline([const Offset(0, 0), const Offset(100, 0)]);
      final b = Polyline([const Offset(150, 0), const Offset(250, 0)]);
      final join = a.joinedWith(b);
      expect(join.joinOffset, 150);
      expect(join.path.pointAt(join.joinOffset), const Offset(150, 0));
    });

    test('the second line\'s plants stay where they were', () async {
      final a = await row('1', const Offset(0, 0), const Offset(100, 0));
      final b = await row('2', const Offset(150, 0), const Offset(250, 0));
      final onA = await layout.placePlantsAlongCarrier(
        carrierId: a,
        offsets: [50],
      );
      final onB = await layout.placePlantsAlongCarrier(
        carrierId: b,
        offsets: [10, 90],
      );

      final plan = (await layout.planMerge(intoObjectId: a, fromObjectId: b))!;
      expect(plan.positions[onA.single], const Offset(50, 0));
      expect(plan.positions[onB[0]], const Offset(160, 0));
      expect(plan.positions[onB[1]], const Offset(240, 0));

      await layout.applyMerge(plan);
      final moved = (await layout.plantById(onB[0]))!;
      expect(Offset(moved.x!, moved.y!), const Offset(160, 0));
    });
  });

  // ---------------------------------------------------------------- item 5

  group('changing a container field', () {
    test('turning containment off and on reconciles', () async {
      final b = await blockAt('1', 0);
      final v = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 0),
      );
      expect(await objectsHolding(v), {b});

      await fields.update(blockField, isContainer: false);
      expect(await objectsHolding(v), isEmpty);

      await fields.update(blockField, isContainer: true);
      expect(await objectsHolding(v), {b});
    });

    test('widening the tolerance takes in a nearby plant', () async {
      final r = await row('12', const Offset(0, 0), const Offset(400, 0));
      final v = await layout.createPlant(
        projectId: projectId,
        position: const Offset(100, 10),
      );
      expect(await objectsHolding(v), isEmpty);

      await fields.update(rowField, tolerance: 12);
      expect(await objectsHolding(v), {r});
    });

    test('the change and its reconcile are one undo step', () async {
      final b = await blockAt('1', 0);
      final v = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 0),
      );

      await gesture(
        'Block is not a container',
        () => fields.update(blockField, isContainer: false),
      );
      expect(await objectsHolding(v), isEmpty);

      await UndoService(db).undo(projectId);
      expect(await objectsHolding(v), {b});
      expect((await fields.byId(blockField))!.isContainer, isTrue);
    });

    test('previewFieldChange counts the renames without writing', () async {
      await useTemplate([FieldPart(blockField), const PlantPart()]);
      await blockAt('1', 0);
      final v = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 0),
      );

      final change = await layout.previewFieldChange(
        fieldDefId: blockField,
        isContainer: false,
      );
      expect(change.changed, 1);
      expect(await idOf(v), '1.1');
    });
  });

  // ---------------------------------------------------------------- item 6

  group('narrow reconciles', () {
    test('a new line beside a carrier does not claim its plants', () async {
      final a = await row('1', const Offset(0, 0), const Offset(400, 0));
      final ids = await layout.placePlantsAlongCarrier(
        carrierId: a,
        offsets: [100, 200],
      );

      // 6px away: within the 8px tolerance of every plant on Row 1.
      await row('2', const Offset(0, 6), const Offset(400, 6));

      for (final id in ids) {
        expect(await objectsHolding(id), {a});
      }
    });

    test('a carrier dragged onto a neighbour keeps its plants', () async {
      final a = await row('1', const Offset(0, 0), const Offset(400, 0));
      final b = await row('2', const Offset(0, 50), const Offset(400, 50));
      final onB = await layout.placePlantsAlongCarrier(
        carrierId: b,
        offsets: [100],
      );

      // Row 2 slides to 6px from Row 1. Its plant is now within reach of both,
      // and Row 1 was never reconciled -- the carried-plant pass is.
      await layout.moveObject(b, const Offset(0, -44));
      expect(await objectsHolding(onB.single), {b});

      // And reshaping Row 1, which does not carry it, must not claim it.
      await layout.updateObjectGeometry(
        a,
        PolylineShape(Polyline([const Offset(0, 0), const Offset(410, 0)])),
      );
      expect(await objectsHolding(onB.single), {b});
    });
  });

  // ---------------------------------------------------------------- item 7

  group('spatial index', () {
    test('one plant and a huge viewport is still instant', () {
      final index = SpatialIndex.build([
        (id: 'v', position: const Offset(5, 5)),
      ]);
      final watch = Stopwatch()..start();
      final hits = index.inRect(
        const Rect.fromLTWH(-20000, -20000, 40000, 40000),
      );
      watch.stop();
      expect(hits.map((p) => p.id), ['v']);
      expect(watch.elapsedMilliseconds, lessThan(50));
    });

    test('a tight cluster is still instant to query and search', () {
      final index = SpatialIndex.build([
        for (var i = 0; i < 100; i++)
          (id: '$i', position: Offset(10 + i / 400, 10 + i / 400)),
      ]);
      final watch = Stopwatch()..start();
      expect(
        index.inRect(const Rect.fromLTWH(0, 0, 8000, 8000)),
        hasLength(100),
      );
      expect(
        index.nearest(const Offset(500, 500), maxDistance: 1000)?.id,
        '99',
      );
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(50));
    });

    test('a query wholly outside the index finds nothing', () {
      final index = SpatialIndex.build([
        (id: 'v', position: const Offset(5, 5)),
        (id: 'w', position: const Offset(50, 50)),
      ]);
      expect(index.inRect(const Rect.fromLTWH(-500, -500, 10, 10)), isEmpty);
      expect(index.inRect(const Rect.fromLTWH(4, 4, 2, 2)).single.id, 'v');
    });
  });

  // ---------------------------------------------------------------- item 8

  group('overlap pre-filter', () {
    test('two collinear horizontal lines sharing a stretch overlap', () {
      final hit = findOverlap(
        PolylineShape(Polyline([const Offset(0, 0), const Offset(100, 0)])),
        [
          (
            id: 'r',
            label: '12',
            shape: PolylineShape(
              Polyline([const Offset(50, 0), const Offset(150, 0)]),
            ),
          ),
        ],
      );
      expect(hit?.objectId, 'r');
    });

    test('two collinear vertical lines sharing a stretch overlap', () {
      expect(
        polylinesCross(
          Polyline([const Offset(0, 0), const Offset(0, 100)]),
          Polyline([const Offset(0, 50), const Offset(0, 150)]),
        ),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------- item 9

  group('operation recorder', () {
    test('an empty gesture does not destroy redo', () async {
      await gesture('Add block', () => blockAt('1', 0));
      final undo = UndoService(db);
      await undo.undo(projectId);
      expect((await undo.availability(projectId)).redo, isNotNull);

      // A rejected validation: the gesture opens and writes nothing.
      await gesture('Nothing', () async {});

      expect((await undo.availability(projectId)).redo, isNotNull);
    });

    test('a gesture that writes still clears redo', () async {
      await gesture('Add block', () => blockAt('1', 0));
      final undo = UndoService(db);
      await undo.undo(projectId);
      await gesture('Add another', () => blockAt('2', 200));
      expect((await undo.availability(projectId)).redo, isNull);
    });
  });

  // --------------------------------------------------------------- item 10

  group('numbering', () {
    test('a batched renumber is still one undoable step', () async {
      final r = await row('12', const Offset(0, 0), const Offset(400, 0));
      final ids = await layout.placePlantsAlongCarrier(
        carrierId: r,
        offsets: [10, 20, 30],
      );
      final numbering = NumberingService(db, labels);

      await gesture(
        'Reverse',
        () async => numbering.apply(
          await numbering.plan(
            plantIds: ids.toSet(),
            startAt: 1,
            order: NumberingOrder.rightToLeft,
          ),
          projectId: projectId,
        ),
      );
      Future<List<int>> numbers() async => [
        for (final id in ids) (await layout.plantById(id))!.positionIdx,
      ];
      expect(await numbers(), [3, 2, 1]);

      await UndoService(db).undo(projectId);
      expect(await numbers(), [1, 2, 3]);
    });
  });
}
