import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/array_generation.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/row_generation.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// Splitting one line into two, and joining two into one.
///
/// **Neither tool touches numbering, and that is the whole reason they exist at
/// all.** They were cut from an earlier plan because "which half keeps the
/// sequence" and "which direction wins on merge" had no good answer. Once
/// numbering became its own tool the question dissolved: these move plants
/// between carriers and leave every number alone, so there is no wrong answer
/// left to embed.
///
/// The one thing they must still refuse is a duplicate identifier, which merging
/// genuinely produces -- two rows each starting at plant 1 become one row with
/// two plant 1s.
void main() {
  late AppDatabase db;
  late LabelService labels;
  late MembershipService memberships;
  late LayoutDao layout;
  late String projectId;
  late String rowField;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    memberships = MembershipService(db);
    layout = LayoutDao(db, labels, memberships);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');

    rowField =
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
  });

  tearDown(() async => db.close());

  Future<void> useRowTemplate() => ProjectsDao(db).setIdentifierTemplate(
    projectId,
    IdentifierTemplate(
      delimiter: '.',
      parts: [FieldPart(rowField), const PlantPart()],
    ),
  );

  Future<String> row(String label, List<Offset> points) => layout.createObject(
    projectId: projectId,
    fieldDefId: rowField,
    label: label,
    geometry: PolylineShape(Polyline(points)),
  );

  Future<List<int>> numbersOn(String carrierId) async {
    final offsets = <double, int>{};
    for (final plant in await layout.plantsInProject(projectId)) {
      if (plant.carrierId == carrierId) {
        offsets[plant.pathOffset ?? 0] = plant.positionIdx;
      }
    }
    final keys = offsets.keys.toList()..sort();
    return [for (final k in keys) offsets[k]!];
  }

  group('split', () {
    test('the near half keeps the id and the label', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 50, 150, 200],
      );

      final newId = await layout.splitCarrier(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );

      expect(newId, isNotNull);
      final near = await layout.objectById(rowId);
      expect(near!.label, '12');
      final far = await layout.objectById(newId!);
      expect(far!.label, '13');
    });

    test('each half spans its own stretch, meeting at the cut', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      final newId = await layout.splitCarrier(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );

      final near = (await layout.carrierPathOf(rowId))!;
      final far = (await layout.carrierPathOf(newId!))!;
      expect(near.points, [const Offset(0, 0), const Offset(100, 0)]);
      expect(far.points, [const Offset(100, 0), const Offset(200, 0)]);
      expect(near.length + far.length, 200);
    });

    test('plants beyond the cut move, with offsets rebased', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 50, 150, 200],
      );

      final newId = await layout.splitCarrier(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );

      // Offsets 150 and 200 become 50 and 100 on a half that starts at the cut.
      final third = await layout.plantById(plants[2]);
      expect(third!.carrierId, newId);
      expect(third.pathOffset, 50);
      expect(third.x, 150, reason: 'it must not have moved on screen');

      final first = await layout.plantById(plants[0]);
      expect(first!.carrierId, rowId);
      expect(first.pathOffset, 0);
    });

    test('numbering is untouched', () async {
      // The far half keeps 3 and 4 rather than restarting at 1. That reads odd,
      // and fixing it is the numbering tool's job -- deliberately not this one's.
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 50, 150, 200],
      );

      final newId = await layout.splitCarrier(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );

      expect(await numbersOn(rowId), [1, 2]);
      expect(await numbersOn(newId!), [3, 4]);
    });

    test('a cut at or past an end is refused, not clamped', () async {
      // A "split" producing one line and one nothing is a rename with extra
      // steps.
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);

      for (final offset in [0.0, 200.0, 400.0, -10.0, double.nan]) {
        expect(
          await layout.splitCarrier(
            objectId: rowId,
            atOffset: offset,
            newLabel: '13',
          ),
          isNull,
          reason: 'offset $offset',
        );
      }
      // And nothing was created along the way.
      expect(await layout.objectsInProject(projectId), hasLength(1));
    });

    test('a cut on a vertex does not leave a duplicated point', () async {
      // The stored JSON would otherwise gain a zero-length segment that survives
      // every future round trip.
      final rowId = await row('12', [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100),
      ]);
      final newId = await layout.splitCarrier(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );

      expect((await layout.carrierPathOf(rowId))!.points, [
        const Offset(0, 0),
        const Offset(100, 0),
      ]);
      expect((await layout.carrierPathOf(newId!))!.points, [
        const Offset(100, 0),
        const Offset(100, 100),
      ]);
    });

    test('the plant on the seam goes to the half it was assigned to', () async {
      // The halves touch at the cut, so a plant there is within tolerance of
      // both. Without the carrier tie-break its Row value would be decided by
      // whichever object the query returned last.
      await useRowTemplate();
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 100, 200],
      );

      await layout.splitCarrier(objectId: rowId, atOffset: 100, newLabel: '13');

      // Offset exactly 100 is `<= atOffset`, so it stays on the near half.
      final seam = await layout.plantById(plants[1]);
      expect(seam!.carrierId, rowId);
      expect(
        (await labels.identifierOf(plants[1]))!.text,
        '12.2',
        reason: 'the carrier decides, not the object sort order',
      );
      expect((await labels.identifierOf(plants[2]))!.text, '13.3');
    });

    test('is one press of undo', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 150],
      );

      await OperationRecorder(db).run(
        projectId: projectId,
        kind: 'split_object',
        description: 'Split Row 12',
        body: () =>
            layout.splitCarrier(objectId: rowId, atOffset: 100, newLabel: '13'),
      );
      expect(await layout.objectsInProject(projectId), hasLength(2));

      await UndoService(db).undo(projectId);

      expect(await layout.objectsInProject(projectId), hasLength(1));
      expect((await layout.plantById(plants[1]))!.carrierId, rowId);
      expect((await layout.carrierPathOf(rowId))!.length, 200);
    });

    test('previewSplit counts the plants that change address', () async {
      await useRowTemplate();
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 50, 150, 200],
      );

      final change = await layout.previewSplit(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );
      expect(change.changed, 2, reason: 'the two beyond the cut');
      expect(change.isSafe, isTrue);

      // And it predicts the right count: the two far plants really do end up
      // called 13.something.
      await layout.splitCarrier(objectId: rowId, atOffset: 100, newLabel: '13');
      expect((await labels.identifierOf(plants[2]))!.text, '13.3');
      expect((await labels.identifierOf(plants[0]))!.text, '12.1');
    });

    test(
      'previewSplit counts nothing when the field is not an ID part',
      () async {
        // No template, so identifiers are bare plant numbers and a split moves
        // plants without readdressing any of them.
        final rowId = await row('12', [
          const Offset(0, 0),
          const Offset(200, 0),
        ]);
        await layout.placePlantsAlongCarrier(
          carrierId: rowId,
          offsets: [0, 150],
        );

        final change = await layout.previewSplit(
          objectId: rowId,
          atOffset: 100,
          newLabel: '13',
        );
        expect(change.changed, 0);
      },
    );
  });

  group('merge', () {
    /// Two collinear rows, `12` running 0-100 and `13` running 100-200.
    Future<({String a, String b, List<String> plantsA, List<String> plantsB})>
    twoRows({List<double>? offsetsB}) async {
      final a = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      final b = await row('13', [const Offset(100, 0), const Offset(200, 0)]);
      final plantsA = await layout.placePlantsAlongCarrier(
        carrierId: a,
        offsets: [0, 50],
      );
      final plantsB = await layout.placePlantsAlongCarrier(
        carrierId: b,
        offsets: offsetsB ?? [0, 50],
      );
      return (a: a, b: b, plantsA: plantsA, plantsB: plantsB);
    }

    test('joins end to end into one path', () async {
      final scene = await twoRows();
      final plan = await layout.planMerge(
        intoObjectId: scene.a,
        fromObjectId: scene.b,
      );

      expect(plan, isNotNull);
      expect(plan!.shape.path.length, 200);
      expect(plan.shape.path.points, [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(200, 0),
      ]);
    });

    test(
      'picks the nearest pair of ends whichever way they were drawn',
      () async {
        // `13` drawn backwards, from 200 back to 100. Its start is now the far
        // end, and the user should not have to think about that.
        final a = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
        final b = await row('13', [const Offset(200, 0), const Offset(100, 0)]);
        final plants = await layout.placePlantsAlongCarrier(
          carrierId: b,
          offsets: [0],
        );

        final plan = (await layout.planMerge(
          intoObjectId: a,
          fromObjectId: b,
        ))!;
        expect(plan.shape.path.points.last, const Offset(200, 0));
        // That plant was at offset 0 of a backwards line, i.e. at x=200, so on the
        // merged path it belongs at 200 -- not at 100.
        expect(plan.offsets[plants.single], 200);
      },
    );

    test('the surviving row moves too when it has to be reversed', () async {
      // Reversing a half invalidates its offsets. The plants on the object that
      // *survives* are affected just as much as the ones that move across.
      final a = await row('12', [const Offset(100, 0), const Offset(0, 0)]);
      final b = await row('13', [const Offset(100, 0), const Offset(200, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: a,
        offsets: [0],
      );

      final plan = (await layout.planMerge(intoObjectId: a, fromObjectId: b))!;
      expect(plan.firstIsReversedFor(plants.single), 100);
    });

    test('applying it moves the plants and retires the other object', () async {
      final scene = await twoRows(offsetsB: [0, 50]);
      // Renumber `13`'s plants so a plain merge does not collide.
      await db.customStatement(
        'UPDATE plants SET position_idx = position_idx + 10 '
        'WHERE carrier_id = ?',
        [scene.b],
      );

      final plan = await layout.planMerge(
        intoObjectId: scene.a,
        fromObjectId: scene.b,
      );
      await layout.applyMerge(plan!);

      expect(await layout.objectsInProject(projectId), hasLength(1));
      for (final id in scene.plantsB) {
        expect((await layout.plantById(id))!.carrierId, scene.a);
      }
      expect((await layout.carrierPathOf(scene.a))!.length, 200);
      // Offsets 0 and 50 on `13` become 100 and 150 on the merged line.
      expect(await layout.plantedOffsetsOn(scene.a), [0, 50, 100, 150]);
    });

    test('numbering is untouched by default', () async {
      final scene = await twoRows();
      await db.customStatement(
        'UPDATE plants SET position_idx = position_idx + 10 '
        'WHERE carrier_id = ?',
        [scene.b],
      );

      final plan = await layout.planMerge(
        intoObjectId: scene.a,
        fromObjectId: scene.b,
      );
      await layout.applyMerge(plan!);

      expect(await numbersOn(scene.a), [1, 2, 11, 12]);
    });

    test('would collide when both rows start at plant 1', () async {
      // The common case, and the reason merge has to be refusable: both plant 1s
      // become `12.1` once `13`'s label is gone.
      await useRowTemplate();
      final scene = await twoRows();

      final plan = await layout.planMerge(
        intoObjectId: scene.a,
        fromObjectId: scene.b,
      );
      final change = await layout.previewMerge(plan!);

      expect(change.isSafe, isFalse);
      expect(change.duplicates, containsAll(['12.1', '12.2']));
    });

    test('renumbering along the path resolves it, when asked for', () async {
      // Offered as an explicit choice, never taken silently -- the tool still
      // makes no numbering decision of its own.
      await useRowTemplate();
      final scene = await twoRows();

      final plan = await layout.planMerge(
        intoObjectId: scene.a,
        fromObjectId: scene.b,
      );
      await layout.applyMerge(plan!, renumberAlongPath: true);

      expect(await numbersOn(scene.a), [1, 2, 3, 4]);
      expect(await labels.findDuplicateIdentifiers(projectId), isEmpty);
    });

    test('numbers follow the path, not the screen', () async {
      // An elbow runs both across and down, so any x/y ordering would number it
      // wrongly at the corner.
      final a = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      final b = await row('13', [const Offset(100, 0), const Offset(100, 100)]);
      final down = await layout.placePlantsAlongCarrier(
        carrierId: b,
        offsets: [100, 50],
      );
      final across = await layout.placePlantsAlongCarrier(
        carrierId: a,
        offsets: [0],
      );

      final plan = await layout.planMerge(intoObjectId: a, fromObjectId: b);
      await layout.applyMerge(plan!, renumberAlongPath: true);

      expect((await layout.plantById(across.single))!.positionIdx, 1);
      // The plant at the far end of the downward leg must be last.
      final numbers = {
        for (final id in down) id: (await layout.plantById(id))!.positionIdx,
      };
      expect(numbers.values.reduce((a, b) => a > b ? a : b), 3);
    });

    test('refuses two objects of different fields', () async {
      final blockField =
          ((await FieldDefsDao(db).create(
                    projectId: projectId,
                    name: 'Terrace',
                    type: FieldType.text,
                    role: FieldRole.object,
                    drawType: DrawType.polyline,
                    isContainer: true,
                  ))
                  as FieldDefSaved)
              .id;
      final a = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      final b = await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: 'upper',
        geometry: PolylineShape(
          Polyline([const Offset(100, 0), const Offset(200, 0)]),
        ),
      );

      expect(
        await layout.planMerge(intoObjectId: a, fromObjectId: b),
        isNull,
        reason: 'a Row joined to a Terrace is not an instance of either',
      );
    });

    test('refuses to merge something with itself', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      expect(
        await layout.planMerge(intoObjectId: rowId, fromObjectId: rowId),
        isNull,
      );
    });

    test('joins across a gap rather than pretending it is not there', () async {
      // Two rows with 50px between them. The joining segment is deliberate:
      // merging them gives one line that spans the gap.
      final a = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      final b = await row('13', [const Offset(150, 0), const Offset(250, 0)]);

      final plan = (await layout.planMerge(intoObjectId: a, fromObjectId: b))!;
      expect(plan.shape.path.length, 250);
      expect(plan.shape.path.points, hasLength(4));
    });

    test('is one press of undo', () async {
      final scene = await twoRows();
      await db.customStatement(
        'UPDATE plants SET position_idx = position_idx + 10 '
        'WHERE carrier_id = ?',
        [scene.b],
      );

      final plan = await layout.planMerge(
        intoObjectId: scene.a,
        fromObjectId: scene.b,
      );
      await OperationRecorder(db).run(
        projectId: projectId,
        kind: 'merge_objects',
        description: 'Merge Row 13 into Row 12',
        body: () => layout.applyMerge(plan!),
      );
      expect(await layout.objectsInProject(projectId), hasLength(1));

      await UndoService(db).undo(projectId);

      expect(await layout.objectsInProject(projectId), hasLength(2));
      expect((await layout.plantById(scene.plantsB.first))!.carrierId, scene.b);
      expect((await layout.carrierPathOf(scene.a))!.length, 100);
    });

    test('split then merge returns the line to where it started', () async {
      // The round trip that proves the offset arithmetic in both directions.
      final rowId = await row('12', [const Offset(0, 0), const Offset(200, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 50, 150, 200],
      );

      final newId = await layout.splitCarrier(
        objectId: rowId,
        atOffset: 100,
        newLabel: '13',
      );
      final plan = await layout.planMerge(
        intoObjectId: rowId,
        fromObjectId: newId!,
      );
      await layout.applyMerge(plan!);

      expect((await layout.carrierPathOf(rowId))!.length, 200);
      expect(await layout.plantedOffsetsOn(rowId), [0, 50, 150, 200]);
      expect(await numbersOn(rowId), [1, 2, 3, 4]);
      for (final id in plants) {
        expect((await layout.plantById(id))!.carrierId, rowId);
      }
    });
  });

  group('the carrier tie-break', () {
    test('does not touch a plant held by two *different* fields', () async {
      // Block 2 and Terrace 3 over one plant is two fields and entirely correct.
      final terraceField =
          ((await FieldDefsDao(db).create(
                    projectId: projectId,
                    name: 'Terrace',
                    type: FieldType.text,
                    role: FieldRole.object,
                    drawType: DrawType.polyline,
                    isContainer: true,
                  ))
                  as FieldDefSaved)
              .id;
      final rowId = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      await layout.createObject(
        projectId: projectId,
        fieldDefId: terraceField,
        label: 'upper',
        geometry: PolylineShape(
          Polyline([const Offset(0, 0), const Offset(100, 0)]),
        ),
      );
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [50],
      );

      final containers = await labels.containersOf(plants.single);
      expect(containers.keys, containsAll(['Row', 'Terrace']));
    });
  });

  group('an array of lines', () {
    // Plan verification #8: generate a run, drag one line's endpoint, and
    // confirm the others do not move. There is no parent link by design -- each
    // line is an ordinary object -- and this is what proves it.
    Future<List<String>> writeRun({int count = 24}) async {
      final lines = ArrayGeneration.parallel(
        seed: Polyline([const Offset(0, 0), const Offset(200, 0)]),
        spacing: 20,
        count: count,
      );

      final ids = <String>[];
      for (var i = 0; i < lines.length; i++) {
        ids.add(
          await layout.createObject(
            projectId: projectId,
            fieldDefId: rowField,
            label: '${i + 1}',
            geometry: PolylineShape(lines[i]),
          ),
        );
      }
      return ids;
    }

    test(
      'reshaping one line leaves the other 23 exactly where they were',
      () async {
        final ids = await writeRun();
        expect(ids, hasLength(24));

        final before = <String, List<Offset>>{
          for (final id in ids)
            id: (await layout.carrierPathOf(id))!.points.toList(),
        };

        // Drag line 5's far end well out of place.
        final target = ids[4];
        final original = (await layout.carrierPathOf(target))!;
        await layout.updateObjectGeometry(
          target,
          PolylineShape(
            original.withPointMovedForTest(1, const Offset(900, 900)),
          ),
        );

        for (final id in ids) {
          final now = (await layout.carrierPathOf(id))!.points;
          if (id == target) {
            expect(now.last, const Offset(900, 900));
          } else {
            expect(now, before[id], reason: 'line $id must not have moved');
          }
        }
      },
    );

    test('each line is planted independently', () async {
      final ids = await writeRun(count: 3);
      for (final id in ids) {
        await layout.placePlantsAlongCarrier(carrierId: id, offsets: [0, 100]);
      }

      // Numbering is per carrier, so every line starts at 1 of its own accord.
      for (final id in ids) {
        expect(await numbersOn(id), [1, 2]);
      }
      expect(await layout.plantsInProject(projectId), hasLength(6));
    });

    test('a run of parallel lines does not overlap itself', () async {
      // The overlap rule is what the array sheet checks before writing, and a
      // parallel run at a positive gap must pass it.
      final ids = await writeRun(count: 5);
      for (final id in ids) {
        final shape = PolylineShape((await layout.carrierPathOf(id))!);
        expect(
          await layout.checkOverlap(
            fieldDefId: rowField,
            shape: shape,
            ignoringObjectId: id,
          ),
          isNull,
        );
      }
    });
  });

  group('a throwaway guide', () {
    // Plan verification #9: array points along a temporary guide and confirm no
    // object was created for the guide itself.
    test('leaves nothing behind', () async {
      final guide = Polyline([const Offset(0, 0), const Offset(100, 0)]);
      final offsets = RowGeneration.byCount(guide, 5);

      final before = (await layout.objectsInProject(projectId)).length;
      for (final offset in offsets) {
        await layout.createPlant(
          projectId: projectId,
          position: guide.pointAt(offset),
        );
      }

      expect(
        await layout.objectsInProject(projectId),
        hasLength(before),
        reason: 'the guide must not have become an object',
      );
      final plants = await layout.plantsInProject(projectId);
      expect(plants, hasLength(5));
      // Free-standing: there is no line left for a carrier to point at.
      for (final plant in plants) {
        expect(plant.carrierId, isNull);
      }
    });

    test('point objects placed along it are ordinary objects', () async {
      final postField =
          ((await FieldDefsDao(db).create(
                    projectId: projectId,
                    name: 'Post',
                    type: FieldType.text,
                    role: FieldRole.object,
                    drawType: DrawType.point,
                  ))
                  as FieldDefSaved)
              .id;

      final guide = Polyline([const Offset(0, 0), const Offset(100, 0)]);
      for (final offset in RowGeneration.bySpacing(guide, 25)) {
        await layout.createObject(
          projectId: projectId,
          fieldDefId: postField,
          label: '${offset.toInt()}',
          geometry: PointShape(guide.pointAt(offset)),
        );
      }

      final posts = [
        for (final o in await layout.objectsInProject(projectId))
          if (o.fieldDefId == postField) o,
      ];
      expect(posts, hasLength(5));
      // And the guide is not among them.
      expect(await layout.objectsInProject(projectId), hasLength(5));
    });
  });
}

/// Test-only vertex move, so the array-independence test can reshape one line
/// without reaching for the canvas.
extension on Polyline {
  Polyline withPointMovedForTest(int index, Offset to) =>
      Polyline([...points]..[index] = to);
}

/// Test-only reach into a plan's offsets, for the reversal case.
extension on MergePlan {
  double? firstIsReversedFor(String plantId) => offsets[plantId];
}
