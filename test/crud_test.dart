import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/plant_data_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';

void main() {
  late AppDatabase db;
  late ProjectsDao projects;
  late FieldDefsDao fieldDefs;
  late FieldEventsDao events;
  late PlantDataService service;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectsDao(db);
    fieldDefs = FieldDefsDao(db);
    events = FieldEventsDao(db);
    service = PlantDataService(fieldDefs: fieldDefs, events: events);
  });

  tearDown(() async => db.close());

  /// A project with one plant, returning (projectId, plantId).
  ///
  /// v3 has no blocks or rows table: a row is an instance of a user-defined
  /// object field. This fixture keeps the shape of the old one -- one plant on
  /// one line -- without needing containment, which these tests do not exercise.
  Future<(String, String)> seedPlant() async {
    final projectId = await projects.create(name: 'Home Block');
    final now = DateTime.utc(2026, 1, 1);
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: 'f_row',
            projectId: projectId,
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
            projectId: projectId,
            fieldDefId: 'f_row',
            label: '12',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.plants)
        .insert(
          PlantsCompanion.insert(
            id: 'v1',
            projectId: projectId,
            carrierId: const Value('r1'),
            positionIdx: 1,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (projectId, 'v1');
  }

  String idOf(FieldDefResult r) {
    expect(r, isA<FieldDefSaved>(), reason: '$r');
    return (r as FieldDefSaved).id;
  }

  group('projects', () {
    test('create and read back', () async {
      final id = await projects.create(name: '  Home Block  ');
      final project = await projects.byId(id);
      expect(project!.name, 'Home Block', reason: 'name should be trimmed');
    });

    test('rename', () async {
      final id = await projects.create(name: 'Old');
      await projects.rename(id, 'New');
      expect((await projects.byId(id))!.name, 'New');
    });

    test('image metadata is stored alongside the path', () async {
      // Dimensions are needed before the image finishes decoding, because
      // every coordinate in the project is in its pixel space.
      final id = await projects.create(name: 'P');
      await projects.setImage(
        id,
        imagePath: '/data/aerial.png',
        width: 4000,
        height: 3000,
      );
      final project = await projects.byId(id);
      expect(project!.imageWidth, 4000);
      expect(project.imageHeight, 3000);
    });

    test('soft delete hides it but keeps it restorable', () async {
      final id = await projects.create(name: 'Doomed');
      await projects.softDelete(id);

      expect(await projects.byId(id), isNull);
      expect(await projects.all(), isEmpty);
      expect(await projects.deleted(), hasLength(1));

      await projects.restore(id);
      expect(await projects.byId(id), isNotNull);
    });

    test('purge cascades to everything beneath', () async {
      final (projectId, plantId) = await seedPlant();
      final fieldId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
        ),
      );
      await events.record(plantId: plantId, fieldDefId: fieldId, value: '4');

      await projects.purge(projectId);

      // Foreign keys cascade, so no orphans remain.
      expect(await db.select(db.plants).get(), isEmpty);
      expect(await db.select(db.fieldDefs).get(), isEmpty);
      expect(await db.select(db.fieldEvents).get(), isEmpty);
    });

    test('watchAll re-emits after a write', () async {
      // The list must not go stale behind a rename or an import, so it is a
      // stream rather than a one-shot read.
      //
      // Waits on the stream reaching each expected state rather than pumping
      // the event queue a fixed number of times. Pumping assumes drift has
      // delivered by the time the pump returns, which is a race -- it passed
      // locally and failed intermittently on CI.
      final appeared = projects
          .watchAll()
          .firstWhere((list) => list.length == 1)
          .timeout(const Duration(seconds: 5));

      final id = await projects.create(name: 'New');
      expect((await appeared).single.name, 'New');

      final renamed = projects
          .watchAll()
          .firstWhere((list) => list.singleOrNull?.name == 'Renamed')
          .timeout(const Duration(seconds: 5));

      await projects.rename(id, 'Renamed');
      expect((await renamed).single.name, 'Renamed');
    });
  });

  group('field definitions', () {
    late String projectId;
    setUp(() async {
      projectId = await projects.create(name: 'P');
    });

    test('created with a config', () async {
      final id = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
          config: const FieldConfig(scaleMin: 1, scaleMax: 10),
        ),
      );

      final def = await fieldDefs.byId(id);
      expect(def!.type, FieldType.rating);
      expect(fieldDefs.configOf(def).scaleMax, 10);
    });

    test('rejects a duplicate name, case-insensitively', () async {
      // XLSX import matches columns to fields by name. "Health" and "health"
      // coexisting would make a column ambiguous with no way to disambiguate.
      await fieldDefs.create(
        projectId: projectId,
        name: 'health',
        type: FieldType.rating,
      );

      final result = await fieldDefs.create(
        projectId: projectId,
        name: 'HEALTH',
        type: FieldType.text,
      );

      expect(result, isA<FieldDefInvalid>());
      expect((result as FieldDefInvalid).problems.first, contains('already'));
    });

    test('the same name is fine in a different project', () async {
      final other = await projects.create(name: 'Other');
      await fieldDefs.create(
        projectId: projectId,
        name: 'health',
        type: FieldType.rating,
      );
      expect(
        await fieldDefs.create(
          projectId: other,
          name: 'health',
          type: FieldType.rating,
        ),
        isA<FieldDefSaved>(),
      );
    });

    test('rejects an incoherent config', () async {
      final result = await fieldDefs.create(
        projectId: projectId,
        name: 'category',
        type: FieldType.categorical,
        config: const FieldConfig(),
      );
      expect(result, isA<FieldDefInvalid>());
      expect(
        (result as FieldDefInvalid).problems.first,
        contains('at least one option'),
      );
    });

    test('rejects an empty name', () async {
      expect(
        await fieldDefs.create(
          projectId: projectId,
          name: '   ',
          type: FieldType.text,
        ),
        isA<FieldDefInvalid>(),
      );
    });

    test('assigns increasing sort order', () async {
      await fieldDefs.create(
        projectId: projectId,
        name: 'a',
        type: FieldType.text,
      );
      await fieldDefs.create(
        projectId: projectId,
        name: 'b',
        type: FieldType.text,
      );
      final defs = await fieldDefs.forProject(projectId);
      expect(defs.map((d) => d.name), ['a', 'b']);
      expect(defs.map((d) => d.sortOrder), [0, 1]);
    });

    test('reorder rewrites positions', () async {
      final a = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'a',
          type: FieldType.text,
        ),
      );
      final b = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'b',
          type: FieldType.text,
        ),
      );

      await fieldDefs.reorder([b, a]);
      final defs = await fieldDefs.forProject(projectId);
      expect(defs.map((d) => d.name), ['b', 'a']);
    });

    test('byName is how import resolves a column header', () async {
      await fieldDefs.create(
        projectId: projectId,
        name: 'spray_date',
        type: FieldType.date,
      );
      expect(
        (await fieldDefs.byName(projectId, 'SPRAY_DATE'))!.name,
        'spray_date',
      );
      expect(await fieldDefs.byName(projectId, 'nope'), isNull);
    });

    test('soft delete keeps its events for restore', () async {
      // Deleting a field by accident must not destroy a season of readings.
      final (pid, plantId) = await seedPlant();
      final fieldId = idOf(
        await fieldDefs.create(
          projectId: pid,
          name: 'health',
          type: FieldType.rating,
        ),
      );
      await events.record(plantId: plantId, fieldDefId: fieldId, value: '4');

      await fieldDefs.softDelete(fieldId);
      expect(await fieldDefs.byId(fieldId), isNull);
      expect(await events.currentValue(plantId, fieldId), '4');

      await fieldDefs.restore(fieldId);
      expect(await fieldDefs.byId(fieldId), isNotNull);
    });
  });

  group('D5 - field type is immutable', () {
    test('changing type throws rather than corrupting history', () async {
      final projectId = await projects.create(name: 'P');
      final id = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.categorical,
          config: const FieldConfig(options: ['Healthy', 'Dead']),
        ),
      );

      // The categorical value "Healthy" does not become an integer. Silently
      // reinterpreting existing events would corrupt every historical value.
      expect(
        () => fieldDefs.update(id, type: FieldType.integer),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('immutable'),
          ),
        ),
      );
    });

    test('passing the same type is a no-op, not an error', () async {
      final projectId = await projects.create(name: 'P');
      final id = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
        ),
      );
      expect(
        await fieldDefs.update(id, type: FieldType.rating, name: 'vigour'),
        isA<FieldDefSaved>(),
      );
      expect((await fieldDefs.byId(id))!.name, 'vigour');
    });
  });

  group('D6 - static fields are write-once', () {
    late String projectId;
    late String plantId;
    late String varietyId;

    setUp(() async {
      final (p, v) = await seedPlant();
      projectId = p;
      plantId = v;
      varietyId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'variety',
          type: FieldType.text,
          isStatic: true,
        ),
      );
    });

    test('the first write succeeds', () async {
      final result = await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: 'Cabernet Franc',
      );
      expect(result, isA<WriteSucceeded>());
    });

    test('a second write is locked and reports the existing value', () async {
      await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: 'Cabernet Franc',
      );

      final result = await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: 'Merlot',
      );

      expect(result, isA<WriteLocked>());
      expect((result as WriteLocked).existing.value, 'Cabernet Franc');
      expect(await events.currentValue(plantId, varietyId), 'Cabernet Franc');
    });

    test('force overwrites deliberately', () async {
      // The lock stops a stray tap clobbering a plant date. It is not meant to
      // make a typo permanent, so there is an explicit escape hatch.
      await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: 'Cabernet Franc',
      );

      final result = await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: 'Cabernet Sauvignon',
        force: true,
      );

      expect(result, isA<WriteSucceeded>());
      expect(
        await events.currentValue(plantId, varietyId),
        'Cabernet Sauvignon',
      );
    });

    test('clearing unlocks the field', () async {
      await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: 'Wrong',
        force: true,
      );
      await service.setValue(
        plantId: plantId,
        fieldDefId: varietyId,
        input: null,
        force: true,
      );

      // Clearing is a deliberate act, so the field accepts a value again
      // without needing force.
      expect(
        await service.setValue(
          plantId: plantId,
          fieldDefId: varietyId,
          input: 'Right',
        ),
        isA<WriteSucceeded>(),
      );
    });

    test('tracked fields accept repeated writes', () async {
      final healthId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
        ),
      );
      for (final v in [1, 2, 3]) {
        expect(
          await service.setValue(
            plantId: plantId,
            fieldDefId: healthId,
            input: v,
          ),
          isA<WriteSucceeded>(),
        );
      }
      expect(await events.history(plantId, healthId), hasLength(3));
    });
  });

  group('validated writes', () {
    test('an invalid value is rejected and names the field', () async {
      final (projectId, plantId) = await seedPlant();
      final healthId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
        ),
      );

      final result = await service.setValue(
        plantId: plantId,
        fieldDefId: healthId,
        input: 9,
      );

      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).message, startsWith('health:'));
      // Nothing was written.
      expect(await events.currentValue(plantId, healthId), isNull);
    });

    test('an unknown field is reported, not written', () async {
      final (_, plantId) = await seedPlant();
      expect(
        await service.setValue(
          plantId: plantId,
          fieldDefId: 'nope',
          input: '1',
        ),
        isA<WriteUnknownField>(),
      );
    });

    test('bulk write validates once and returns an undoable batch', () async {
      final (projectId, plantId) = await seedPlant();
      final healthId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
        ),
      );

      final result = await service.setValueForSelection(
        plantIds: [plantId],
        fieldDefId: healthId,
        input: 4,
      );

      expect(result, isA<WriteBulkSucceeded>());
      final batch = (result as WriteBulkSucceeded).batchId;
      expect(await events.currentValue(plantId, healthId), '4');
      await events.undoBatch(batch);
      expect(await events.currentValue(plantId, healthId), isNull);
    });

    test(
      'bulk write rejects an invalid value before touching anything',
      () async {
        final (projectId, plantId) = await seedPlant();
        final healthId = idOf(
          await fieldDefs.create(
            projectId: projectId,
            name: 'health',
            type: FieldType.rating,
          ),
        );

        expect(
          await service.setValueForSelection(
            plantIds: [plantId],
            fieldDefId: healthId,
            input: 'not a rating',
          ),
          isA<WriteRejected>(),
        );
        expect(await events.currentValue(plantId, healthId), isNull);
      },
    );

    test('displayValues renders labels for every field', () async {
      final (projectId, plantId) = await seedPlant();
      final healthId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'health',
          type: FieldType.rating,
          config: const FieldConfig(labels: {'5': 'Excellent'}),
        ),
      );
      final notesId = idOf(
        await fieldDefs.create(
          projectId: projectId,
          name: 'notes',
          type: FieldType.text,
        ),
      );

      await service.setValue(plantId: plantId, fieldDefId: healthId, input: 5);

      final values = await service.displayValues(projectId, plantId);
      expect(values[healthId], 'Excellent');
      // Fields with no value still appear, as null.
      expect(values.containsKey(notesId), isTrue);
      expect(values[notesId], isNull);
    });
  });
}
