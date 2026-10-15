import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/import_service.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/import/table_reader.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// The spreadsheet import: rows by plant ID, columns by field name, every cell
/// through the same rules as hand entry, and the whole thing one undo.
void main() {
  late AppDatabase db;
  late FieldDefsDao fields;
  late FieldEventsDao events;
  late LabelService labels;
  late ImportService service;
  late OperationRecorder recorder;
  late String projectId;
  late String variety;
  late String clone;
  late String health;
  late List<String> plants; // 12.1, 12.2, 12.3

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    fields = FieldDefsDao(db);
    events = FieldEventsDao(db);
    labels = LabelService(db);
    recorder = OperationRecorder(db);
    service = ImportService(fieldDefs: fields, events: events, labels: labels);
    final layout = LayoutDao(db, labels, MembershipService(db));
    final projects = ProjectsDao(db);

    projectId = await projects.create(name: 'Five Sisters');
    Future<String> make(
      String name,
      FieldType type, {
      FieldRole role = FieldRole.attribute,
      DrawType? draw,
      bool container = false,
      bool isStatic = false,
      FieldConfig config = FieldConfig.empty,
    }) async =>
        ((await fields.create(
                  projectId: projectId,
                  name: name,
                  type: type,
                  role: role,
                  drawType: draw,
                  isContainer: container,
                  isStatic: isStatic,
                  config: config,
                ))
                as FieldDefSaved)
            .id;

    final row = await make(
      'Row',
      FieldType.text,
      role: FieldRole.object,
      draw: DrawType.polyline,
      container: true,
    );
    variety = await make(
      'Variety',
      FieldType.categorical,
      isStatic: true,
      config: const FieldConfig(options: ['Pinot Noir', 'Teroldego']),
    );
    clone = await make('Clone', FieldType.text);
    health = await make(
      'Health',
      FieldType.categorical,
      config: const FieldConfig(options: ['1', '2', '3', '4', '5', 'Dead']),
    );
    await projects.setIdentifierTemplate(
      projectId,
      IdentifierTemplate(
        delimiter: '.',
        parts: [FieldPart(row), const PlantPart()],
      ),
    );
    final carrier = await layout.createObject(
      projectId: projectId,
      fieldDefId: row,
      label: '12',
      geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(100, 0)])),
    );
    plants = await layout.placePlantsAlongCarrier(
      carrierId: carrier,
      offsets: const [0, 10, 20],
    );
  });

  tearDown(() => db.close());

  TableData sheet(List<List<String?>> rows) =>
      TableData(headers: rows.first.cast<String>(), rows: rows.sublist(1));

  final standard = [
    ['Block', 'Row', 'Plant', 'ID', 'Variety', 'Clone', 'Health'],
    ['1', '12', '1', '12.1', 'Pinot Noir', '667', '4'],
    ['1', '12', '2', '12.2', 'Pinot Noir', '2A', 'Dead'],
    ['1', '12', '3', '12.3', 'Teroldego', 'Teroldego', '2'],
  ];

  Future<ImportResult> run(ImportPlan plan, {bool overwrite = false}) =>
      recorder.run(
        projectId: projectId,
        kind: 'import',
        description: 'Import',
        body: () => service.apply(plan, overwriteWriteOnce: overwrite),
      );

  test('matches rows by plant ID and columns by field name', () async {
    final plan = await service.plan(projectId, sheet(standard));
    expect(plan.matchedRows, 3);
    expect(plan.unknownIds, isEmpty);
    expect(plan.columns.map((c) => c.field.name), [
      'Variety',
      'Clone',
      'Health',
    ]);
    // Row is drawn, not recorded; Block and Plant are not fields at all.
    expect(plan.ignoredHeaders, ['Block', 'Row', 'Plant']);

    final result = await run(plan);
    expect(result.written, 9);
    final v = await events.currentValuesForField(variety);
    expect(v[plants[2]]!.value, 'Teroldego');
    expect(
      (await events.currentValuesForField(health))[plants[1]]!.value,
      'Dead',
    );
    expect(v[plants[0]]!.source, EventSource.import);
  });

  test('IDs that are not plants here are reported, not guessed at', () async {
    final plan = await service.plan(
      projectId,
      sheet([
        ['ID', 'Health'],
        ['12.1', '4'],
        ['99.9', '3'],
        ['12.1', '5'],
      ]),
    );
    expect(plan.matchedRows, 1);
    expect(plan.unknownIds, ['99.9']);
    expect(plan.duplicateIds, ['12.1']);
    // First occurrence wins.
    expect(plan.columns.single.values.values.single, '4');
  });

  test('a value off the option list is refused, the rest go in', () async {
    final plan = await service.plan(
      projectId,
      sheet([
        ['ID', 'Health'],
        ['12.1', '4'],
        ['12.2', 'Rootstock'],
      ]),
    );
    final column = plan.columns.single;
    expect(column.values.keys, [plants[0]]);
    expect(column.rejected.single.plantId, '12.2');
    expect(column.rejected.single.value, 'Rootstock');
  });

  test('a blank cell never clears what the tablet already has', () async {
    await events.record(plantId: plants[0], fieldDefId: clone, value: '37');
    final plan = await service.plan(
      projectId,
      sheet([
        ['ID', 'Clone'],
        ['12.1', null],
      ]),
    );
    expect(plan.hasWrites, isFalse);
    await run(plan);
    expect(await events.currentValue(plants[0], clone), '37');
  });

  test(
    'importing the same sheet twice writes nothing the second time',
    () async {
      await run(await service.plan(projectId, sheet(standard)));
      final again = await service.plan(projectId, sheet(standard));
      expect(again.hasWrites, isFalse);
      expect(again.columns.every((c) => c.unchanged == 3), isTrue);
    },
  );

  test(
    'write-once values already set are kept unless told otherwise',
    () async {
      await events.record(
        plantId: plants[0],
        fieldDefId: variety,
        value: 'Teroldego',
      );
      final plan = await service.plan(projectId, sheet(standard));
      final column = plan.columns.firstWhere((c) => c.field.id == variety);
      expect(column.alreadyHeld, {plants[0]});

      final kept = await run(plan);
      expect(kept.skippedHeld, 1);
      expect(await events.currentValue(plants[0], variety), 'Teroldego');

      await run(
        await service.plan(projectId, sheet(standard)),
        overwrite: true,
      );
      expect(await events.currentValue(plants[0], variety), 'Pinot Noir');
    },
  );

  test('a column that is part of the plant ID is refused', () async {
    await ProjectsDao(db).setIdentifierTemplate(
      projectId,
      IdentifierTemplate(
        delimiter: '.',
        parts: [FieldPart(clone), const PlantPart()],
      ),
    );
    // IDs are now Clone.Plant -- "0.1" with no clone set.
    final ids = await labels.identifiersForProject(projectId);
    final plan = await service.plan(
      projectId,
      sheet([
        ['ID', 'Clone', 'Health'],
        [ids[plants[0]]!.text, '667', '4'],
      ]),
    );
    expect(plan.identifierHeaders, ['Clone']);
    expect(plan.columns.map((c) => c.field.name), ['Health']);
  });

  test('the whole import is one press of undo', () async {
    await run(await service.plan(projectId, sheet(standard)));
    expect(await events.currentValue(plants[2], health), '2');

    await UndoService(db).undo(projectId);
    for (final p in plants) {
      expect(await events.currentValue(p, variety), isNull);
      expect(await events.currentValue(p, health), isNull);
    }
  });

  test('no ID column is a clear error', () async {
    expect(
      () => service.plan(
        projectId,
        sheet([
          ['Plant', 'Health'],
          ['1', '4'],
        ]),
      ),
      throwsA(isA<TableReadException>()),
    );
  });
}
