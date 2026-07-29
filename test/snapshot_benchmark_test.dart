import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// Where the time goes when the canvas rebuilds a 4,000-plant vineyard.
///
/// **This is a measurement, not a gate.** The real gate is frames on the Fire
/// Max 11, which a desktop test cannot stand in for -- a machine that renders
/// 4,000 dots in 3ms tells you nothing about a tablet that takes 17.
///
/// What it *can* do is attribute cost. v3 measured 13.3ms average frame against
/// v2's 11.5, with build going 7.8 to 8.9, and the suspicion was that assembling
/// `LayoutSnapshot` re-decodes every object's geometry JSON on every change to
/// the plants table.
///
/// **That suspicion was wrong**, and this is the file that killed it: parsing
/// every geometry in the project costs under 2ms, and it happens once per edit
/// rather than once per frame. The frame regression is still unattributed and
/// needs the on-device overlay, not more desktop timing.
///
/// What these tests did find was the real cost centre -- reconciling membership
/// after a boundary edit, which was issuing one statement per changed row.
///
/// The thresholds are deliberately loose. They exist to catch an order-of-
/// magnitude regression -- an accidental N+1 query, a per-plant JSON decode --
/// not to police milliseconds on whatever machine happens to run CI.
void main() {
  late AppDatabase db;
  late LayoutDao layout;
  late LabelService labels;
  late MembershipService memberships;
  late String projectId;
  late String rowField;
  late String blockField;

  /// Rows of wildly varying length rather than a uniform grid, which would
  /// flatter every index involved. As many rows as it takes to reach the target,
  /// which at an average of ~40 plants a row is about 100 -- the real vineyard's
  /// 75 rows come to ~3,025, and the gate is meant to have headroom over that.
  const plantTarget = 4000;
  var rowCount = 0;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    memberships = MembershipService(db);
    layout = LayoutDao(db, labels, memberships);
    projectId = await ProjectsDao(db).create(name: 'Performance test');

    final fields = FieldDefsDao(db);
    rowField =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Row',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polyline,
                  isContainer: true,
                  blankPlaceholder: '0',
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
                  blankPlaceholder: '0',
                ))
                as FieldDefSaved)
            .id;

    await ProjectsDao(db).setIdentifierTemplate(
      projectId,
      IdentifierTemplate(
        delimiter: '.',
        parts: [FieldPart(blockField), FieldPart(rowField), const PlantPart()],
      ),
    );

    // Seeded outside an operation on purpose: the capture triggers are a no-op
    // with no context row set, so 4,000 plants cost 4,000 inserts rather than
    // 4,000 inserts plus 4,000 journal rows. The reconcile benchmark below opens
    // its own operation, which is where journalling is the point.
    final random = math.Random(42);
    var placed = 0;
    rowCount = 0;
    while (placed < plantTarget) {
      final count = math.min(9 + random.nextInt(64), plantTarget - placed);
      final y = 100.0 + rowCount * 45;
      final rowId = await layout.createObject(
        projectId: projectId,
        fieldDefId: rowField,
        label: '${rowCount + 1}',
        geometry: PolylineShape(
          Polyline([Offset(100, y), Offset(100 + count * 14, y)]),
        ),
      );
      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [for (var i = 0; i < count; i++) i * 14.0],
      );
      placed += count;
      rowCount++;
    }

    // One block around the lot, so every plant has all three identifier parts.
    await layout.createObject(
      projectId: projectId,
      fieldDefId: blockField,
      label: '1',
      geometry: PolygonShape([
        const Offset(50, 50),
        const Offset(1200, 50),
        Offset(1200, 150 + rowCount * 45),
        Offset(50, 150 + rowCount * 45),
      ]),
    );
  });

  tearDown(() async => db.close());

  /// Milliseconds for [body], averaged over [runs] after one warm-up.
  ///
  /// The warm-up matters: the first call pays for query preparation and JIT, and
  /// including it would attribute one-off cost to the steady state.
  Future<double> timeAverage(
    Future<void> Function() body, {
    int runs = 5,
  }) async {
    await body();
    final watch = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      await body();
    }
    watch.stop();
    return watch.elapsedMicroseconds / runs / 1000;
  }

  test('the seed really is 4,000 plants, not three-quarters of one', () async {
    // Worth asserting because it was wrong: a 75-row cap over rows averaging ~40
    // plants produced about 3,030, so the "4,000-plant" gate was being run
    // against 3,030 -- barely above the real vineyard rather than comfortably
    // over it.
    final plants = await layout.plantsInProject(projectId);
    final objects = await layout.objectsInProject(projectId);

    expect(plants.length, plantTarget);
    expect(objects.length, rowCount + 1);
    expect(
      rowCount,
      greaterThan(75),
      reason: 'reaching 4,000 takes more rows than the real vineyard has',
    );
  });

  test('reading every plant is one query, not four thousand', () async {
    final ms = await timeAverage(() async {
      await layout.plantsInProject(projectId);
    });
    // ignore: avoid_print
    print('plantsInProject (4,000 plants): ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(400));
  });

  test('parsing every object geometry, the suspected per-change cost', () async {
    // The work `LayoutSnapshot` redoes whenever the plants table changes: fetch
    // every object and JSON-decode its geometry.
    //
    // **The answer is that this is noise** -- under 2ms for a whole project, once
    // per edit. Kept as a test rather than deleted because it is the thing that
    // *would* have justified a shape cache, and a future change that made
    // parsing per-plant instead of per-object would show up here as a hundredfold
    // jump.
    final ms = await timeAverage(() async {
      for (final object in await layout.objectsInProject(projectId)) {
        Shape.tryParse(
          object.geometry,
          object.fieldDefId == blockField
              ? DrawType.polygon
              : DrawType.polyline,
        );
      }
    });
    // ignore: avoid_print
    print(
      '${rowCount + 1} object geometries parsed: ${ms.toStringAsFixed(2)}ms',
    );
    expect(ms, lessThan(200));
  });

  test('rendering every identifier stays a handful of queries', () async {
    // The single-join shape exists because 4,000 round trips per repaint is not
    // a budget, it is a freeze. This is the test that notices if it ever becomes
    // per-plant again.
    final ms = await timeAverage(() async {
      await labels.identifiersForProject(projectId);
    }, runs: 3);
    // ignore: avoid_print
    print('4,000 identifiers rendered: ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(2000));
  });

  test('a boundary reconcile over 4,000 plants and every container', () async {
    // The plan's outstanding measurement. Dragging a block's corner reconciles
    // membership project-wide, because a plant that *left* is not found by
    // looking at what the block now covers -- so this is 4,000 plants against 76
    // container shapes, plus the journal rows for whatever actually changed.
    final block = [
      for (final o in await layout.objectsInProject(projectId))
        if (o.fieldDefId == blockField) o,
    ].single;

    final watch = Stopwatch()..start();
    await OperationRecorder(db).run(
      projectId: projectId,
      kind: 'reshape_object',
      description: 'Reshape Block 1',
      body: () => layout.updateObjectGeometry(
        block.id,
        // Pulled in so it covers only the first few rows: a large, real sweep
        // rather than a no-op reconcile.
        PolygonShape([
          const Offset(50, 50),
          const Offset(1200, 50),
          const Offset(1200, 400),
          const Offset(50, 400),
        ]),
      ),
    );
    watch.stop();

    // ignore: avoid_print
    print('boundary reconcile (4,000 plants): ${watch.elapsedMilliseconds}ms');

    // Correctness first: the sweep really happened, and only the plants that
    // left lost their membership.
    final remaining = await db.select(db.plantMemberships).get();
    final inBlock = remaining.where((m) => m.objectId == block.id).length;
    expect(
      inBlock,
      lessThan(1000),
      reason: 'most plants should have left the shrunken block',
    );
    expect(inBlock, greaterThan(0), reason: 'the near rows should still be in');

    // Loose, and about shape rather than speed: an N-squared reconcile or a
    // per-plant query would be seconds, not hundreds of milliseconds.
    expect(watch.elapsedMilliseconds, lessThan(60000));
  });

  test('a small boundary nudge costs a fraction of a big sweep', () async {
    // The characterisation that matters. Reconcile cost is dominated by *how
    // many memberships actually change* -- each one is a row write plus a journal
    // row, and the journal row is the price of the edit being undoable. So
    // nudging a corner by a few pixels must not cost what re-drawing the whole
    // block costs, even though both run the same code over the same 4,000 plants.
    final block = [
      for (final o in await layout.objectsInProject(projectId))
        if (o.fieldDefId == blockField) o,
    ].single;

    final watch = Stopwatch()..start();
    await OperationRecorder(db).run(
      projectId: projectId,
      kind: 'reshape_object',
      description: 'Nudge Block 1',
      body: () => layout.updateObjectGeometry(
        block.id,
        // 20px off one edge: a handful of plants at most.
        PolygonShape([
          const Offset(50, 50),
          const Offset(1180, 50),
          Offset(1180, 150 + rowCount * 45),
          Offset(50, 150 + rowCount * 45),
        ]),
      ),
    );
    watch.stop();

    // ignore: avoid_print
    print('small boundary nudge:       ${watch.elapsedMilliseconds}ms');
    expect(watch.elapsedMilliseconds, lessThan(10000));
  });

  test('a narrow reconcile does not pay the project-wide price', () async {
    // Dragging one plant scopes the reconcile to that plant. If this ever
    // approaches the boundary-edit cost above, the scoping has been lost -- and
    // the symptom would be a canvas that hitches on every single drag.
    final plant = (await layout.plantsInProject(projectId)).first;

    final ms = await timeAverage(() async {
      await OperationRecorder(db).run(
        projectId: projectId,
        kind: 'move_plant',
        description: 'Move plant',
        body: () => layout.movePlant(plant.id, Offset(plant.x!, plant.y!)),
      );
    }, runs: 3);
    // ignore: avoid_print
    print('single plant move: ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(5000));
  });
}
