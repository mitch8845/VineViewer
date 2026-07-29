import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/numbering_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

void main() {
  late AppDatabase db;
  late ProjectsDao projects;
  late LabelService labels;
  late LayoutDao layout;
  late FieldDefsDao fieldDefs;
  late FieldEventsDao events;
  late OperationRecorder recorder;
  late UndoService undo;

  late String projectId;
  late String rowField;
  late String rowId;
  late List<String> plantIds;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectsDao(db);
    labels = LabelService(db);
    layout = LayoutDao(db, labels, MembershipService(db));
    fieldDefs = FieldDefsDao(db);
    events = FieldEventsDao(db);
    recorder = OperationRecorder(db);
    undo = UndoService(db);

    // Seeded outside any operation, so the fixture itself is not undoable and
    // every test starts from a clean stack.
    projectId = await projects.create(name: 'Five Sisters');
    rowField =
        ((await fieldDefs.create(
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

  /// Every journaled table, row by row, for exact before/after comparison.
  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in db.journaledTables) {
      final rows = await db
          .customSelect('SELECT * FROM ${table.actualTableName} ORDER BY id')
          .get();
      result[table.actualTableName] = [for (final r in rows) r.data];
    }
    return result;
  }

  /// Runs [gesture] as one operation and asserts undo returns the database to
  /// exactly its prior state.
  ///
  /// This is the test that proves the trigger approach genuinely covers an
  /// operation rather than appearing to: it compares every column of every row
  /// of every journaled table, so a restored-but-subtly-wrong field fails here.
  Future<void> expectUndoable(
    String kind,
    Future<void> Function() gesture,
  ) async {
    final before = await snapshot();

    await recorder.run(
      projectId: projectId,
      kind: kind,
      description: kind,
      body: gesture,
    );

    // A gesture that changed nothing would make the undo assertion below pass
    // vacuously, which is the most comfortable way to ship a broken undo.
    expect(
      await snapshot(),
      isNot(before),
      reason: '$kind wrote nothing, so undoing it proves nothing',
    );

    expect(await undo.undo(projectId), isNotNull);
    expect(await snapshot(), before, reason: '$kind did not undo cleanly');
  }

  group('layout operations undo cleanly', () {
    test('createPlant', () async {
      await expectUndoable(
        'create_plant',
        () => layout.createPlant(
          projectId: projectId,
          position: const Offset(500, 500),
        ),
      );
    });

    test('movePlant along its row', () async {
      await expectUndoable(
        'move_plant',
        () => layout.movePlant(plantIds.first, const Offset(220, 5)),
      );
    });

    test('updateRowPath, which repositions every plant on it', () async {
      await expectUndoable(
        'reshape_row',
        () => layout.updateObjectGeometry(
          rowId,
          PolylineShape(
            Polyline([
              const Offset(0, 0),
              const Offset(200, 0),
              const Offset(200, 300),
            ]),
          ),
        ),
      );
    });

    test('moveRow', () async {
      await expectUndoable(
        'move_row',
        () => layout.moveObject(rowId, const Offset(30, 40)),
      );
    });

    test('placePlantsAlongRow', () async {
      await expectUndoable(
        'place_plants',
        () => layout.placePlantsAlongCarrier(
          carrierId: rowId,
          offsets: [410, 460],
        ),
      );
    });

    test('snapPlantToRow', () async {
      final free = await layout.createPlant(
        projectId: projectId,
        position: const Offset(180, 60),
      );
      await expectUndoable(
        'snap_plant',
        () => layout.snapPlantToCarrier(plantId: free, carrierId: rowId),
      );
    });

    test('unsnapPlant', () async {
      await expectUndoable(
        'unsnap_plant',
        () => layout.unsnapPlant(plantIds.last),
      );
    });

    test('retirePlant', () async {
      await expectUndoable(
        'retire_plant',
        () =>
            layout.retirePlant(plantIds[2], change: PlantStatusChange.removed),
      );
    });

    test('createObject', () async {
      await expectUndoable(
        'create_object',
        () => layout.createObject(
          projectId: projectId,
          fieldDefId: rowField,
          label: '13',
        ),
      );
    });

    test('deleting a row, which foreign-key-detaches its plants', () async {
      // The interesting one. Deleting the row fires ON DELETE SET NULL against
      // eight plants, and those updates are captured too -- so undo has to put
      // the row back *and* re-attach every plant. Restoring in reverse order is
      // what makes the foreign key hold at each step.
      await expectUndoable(
        'delete_row',
        () async =>
            db.customStatement('DELETE FROM map_objects WHERE id = ?', [rowId]),
      );
    });
  });

  group('carrier and numbering operations undo cleanly', () {
    test('snapping a free plant onto a carrier', () async {
      final free = await layout.createPlant(
        projectId: projectId,
        position: const Offset(900, 900),
      );
      await expectUndoable(
        'snap',
        () => layout.snapPlantToCarrier(plantId: free, carrierId: rowId),
      );
    });

    test('detaching a plant from its carrier', () async {
      await expectUndoable('detach', () => layout.unsnapPlant(plantIds[3]));
    });

    test('inserting with a shift', () async {
      final free = await layout.createPlant(
        projectId: projectId,
        position: const Offset(275, 0),
      );
      await expectUndoable(
        'insert',
        () => labels.insertAfter(
          plantId: free,
          carrierId: rowId,
          afterPositionIdx: 4,
          shift: true,
        ),
      );
    });

    test('numbering a selection', () async {
      await expectUndoable('renumber', () async {
        final plan = await NumberingService(db, labels).plan(
          plantIds: plantIds.toSet(),
          startAt: 20,
          order: NumberingOrder.rightToLeft,
        );
        await NumberingService(db, labels).apply(plan, projectId: projectId);
      });
    });
  });

  group('schema and data operations undo cleanly', () {
    test('field definition create', () async {
      await expectUndoable(
        'create_field',
        () => fieldDefs.create(
          projectId: projectId,
          name: 'Health',
          type: FieldType.rating,
        ),
      );
    });

    test('a single field event', () async {
      final field = await fieldDefs.create(
        projectId: projectId,
        name: 'Health',
        type: FieldType.integer,
      );
      final fieldId = (field as FieldDefSaved).id;

      await expectUndoable(
        'record_value',
        () => events.record(
          plantId: plantIds.first,
          fieldDefId: fieldId,
          value: '3',
        ),
      );
    });

    test('a bulk field write across every plant', () async {
      final field = await fieldDefs.create(
        projectId: projectId,
        name: 'Sprayed',
        type: FieldType.boolean,
      );
      final fieldId = (field as FieldDefSaved).id;

      await expectUndoable(
        'bulk_write',
        () => events.recordBulk(
          plantIds: plantIds,
          fieldDefId: fieldId,
          value: 'true',
        ),
      );
    });

    test('project rename', () async {
      await expectUndoable(
        'rename_project',
        () => projects.rename(projectId, 'South Slope'),
      );
    });
  });

  group('undoing a data write erases it', () {
    test('the undone event does not appear in the plant history', () async {
      final field = await fieldDefs.create(
        projectId: projectId,
        name: 'Health',
        type: FieldType.integer,
      );
      final fieldId = (field as FieldDefSaved).id;

      await events.record(
        plantId: plantIds.first,
        fieldDefId: fieldId,
        value: '4',
        observedAt: DateTime.utc(2025, 8, 1),
      );

      await recorder.run(
        projectId: projectId,
        kind: 'record_value',
        description: 'Set Health',
        body: () => events.record(
          plantId: plantIds.first,
          fieldDefId: fieldId,
          value: '1',
          observedAt: DateTime.utc(2026, 7, 1),
        ),
      );
      expect(await events.currentValue(plantIds.first, fieldId), '1');

      await undo.undo(projectId);

      // Erased, not tombstoned. This is the one deliberate exception to the
      // append-only rule, and the decision was that a fumbled entry should not
      // clutter a plant's record forever.
      expect(await events.currentValue(plantIds.first, fieldId), '4');
      final history = await events.history(plantIds.first, fieldId);
      expect(history, hasLength(1));
      expect(history.single.value, '4');
    });
  });

  group('the undo stack behaves', () {
    Future<void> move(double x) => recorder.run(
      projectId: projectId,
      kind: 'move_plant',
      description: 'Move plant to $x',
      body: () => layout.movePlant(plantIds.first, Offset(x, 0)),
    );

    Future<double?> plantX() async {
      final plant = await (db.select(
        db.plants,
      )..where((v) => v.id.equals(plantIds.first))).getSingle();
      return plant.x;
    }

    test('undo walks back and redo walks forward', () async {
      await move(100);
      await move(200);
      expect(await plantX(), 200);

      await undo.undo(projectId);
      expect(await plantX(), 100);
      await undo.undo(projectId);
      expect(await plantX(), 0);

      await undo.redo(projectId);
      expect(await plantX(), 100);
      await undo.redo(projectId);
      expect(await plantX(), 200);
    });

    test('undo stops when there is nothing left', () async {
      await move(100);
      expect(await undo.undo(projectId), isNotNull);
      expect(await undo.undo(projectId), isNull);
    });

    test('a new operation clears the redo stack', () async {
      await move(100);
      await move(200);
      await undo.undo(projectId);
      expect((await undo.availability(projectId)).canRedo, isTrue);

      await move(300);
      expect((await undo.availability(projectId)).canRedo, isFalse);
      expect(await plantX(), 300);
    });

    test('the description recorded is what the button will say', () async {
      await move(100);
      final available = await undo.availability(projectId);
      expect(available.undo!.description, 'Move plant to 100.0');
    });

    test('a gesture that writes nothing leaves no undo step', () async {
      await recorder.run(
        projectId: projectId,
        kind: 'noop',
        description: 'Did nothing',
        body: () async {},
      );
      expect((await undo.availability(projectId)).canUndo, isFalse);
    });

    test('a failed gesture rolls back and leaves no undo step', () async {
      await expectLater(
        recorder.run<void>(
          projectId: projectId,
          kind: 'boom',
          description: 'Explodes halfway',
          body: () async {
            await layout.movePlant(plantIds.first, const Offset(77, 0));
            throw StateError('boom');
          },
        ),
        throwsStateError,
      );

      expect(await plantX(), 0);
      expect((await undo.availability(projectId)).canUndo, isFalse);
    });

    test('nested runs collapse into one undo step', () async {
      await recorder.run(
        projectId: projectId,
        kind: 'replace_plant',
        description: 'Replace plant 3.12.1',
        body: () async {
          await layout.retirePlant(
            plantIds.first,
            change: PlantStatusChange.removed,
          );
          // An inner recorder call, as a service might make. It must not become
          // a second entry -- the user made one gesture.
          await recorder.run(
            projectId: projectId,
            kind: 'create_plant',
            description: 'Place plant',
            body: () => layout.createPlant(
              projectId: projectId,
              position: const Offset(0, 0),
            ),
          );
        },
      );

      final window = await db.select(db.operations).get();
      expect(window, hasLength(1));
      expect(window.single.description, 'Replace plant 3.12.1');
    });

    test('undo notifies watchers, so the canvas repaints', () async {
      // Replay writes go through customStatement, which drift cannot attribute
      // to a table by itself. Without an explicit notifyUpdates the database is
      // correct and the map is stale -- plants sit where undo just moved them
      // from. That failure is invisible to every other test here, because they
      // all read the database directly rather than through a stream.
      final seen = <double?>[];
      final subscription = layout
          .watchPlantsInProject(projectId)
          .listen(
            (plants) =>
                seen.add(plants.firstWhere((v) => v.id == plantIds.first).x),
          );
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      await move(250);
      await pumpEventQueue();
      final afterMove = seen.length;
      expect(seen.last, 250);

      await undo.undo(projectId);
      await pumpEventQueue();

      expect(
        seen.length,
        greaterThan(afterMove),
        reason: 'undo produced no new emission, so the canvas never repainted',
      );
      expect(seen.last, 0);
    });

    test('operations are scoped to their project', () async {
      final other = await projects.create(name: 'Elsewhere');
      await move(100);

      expect((await undo.availability(other)).canUndo, isFalse);
      expect(await undo.undo(other), isNull);
      expect(await plantX(), 100);
    });
  });

  group('durability', () {
    test('undo survives the database being closed and reopened', () async {
      // The behaviour the whole design exists for: a tablet backgrounded in a
      // vineyard and reaped by Android. An in-memory stack would be gone here.
      //
      // Opening the same file twice is the entire point, and each handle is
      // closed before the next opens, so drift's race warning does not apply.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
      );

      final directory = await Directory.systemTemp.createTemp('plantviewer');
      final file = File('${directory.path}/durability.sqlite');

      var reopened = AppDatabase(NativeDatabase(file));
      final localProjects = ProjectsDao(reopened);
      final localLayout = LayoutDao(
        reopened,
        LabelService(reopened),
        MembershipService(reopened),
      );

      final id = await localProjects.create(name: 'Five Sisters');
      final plant = await localLayout.createPlant(
        projectId: id,
        position: const Offset(10, 10),
      );
      await OperationRecorder(reopened).run(
        projectId: id,
        kind: 'move_plant',
        description: 'Move plant',
        body: () => localLayout.movePlant(plant, const Offset(900, 900)),
      );
      await reopened.close();

      reopened = AppDatabase(NativeDatabase(file));
      addTearDown(() async {
        await reopened.close();
        await directory.delete(recursive: true);
      });

      final service = UndoService(reopened);
      final available = await service.availability(id);
      expect(available.canUndo, isTrue);
      expect(available.undo!.description, 'Move plant');

      await service.undo(id);
      final restored = await (reopened.select(
        reopened.plants,
      )..where((v) => v.id.equals(plant))).getSingle();
      expect(restored.x, 10);
      expect(restored.y, 10);
    });
  });
}
