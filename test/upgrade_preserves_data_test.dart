import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
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

/// The upgrade every tablet in the field takes, run against a vineyard built
/// the way Five Sisters was: containers, a Block.Row.Plant ID, write-once and
/// choice fields, an import, hand edits, and an undone change in the journal.
///
/// Every row of every table is compared before and after. Nothing may differ
/// except the one column the upgrade adds.
void main() {
  late Directory dir;
  late File file;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('vv_upgrade_');
    file = File('${dir.path}/app.sqlite');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const tables = [
    'projects',
    'field_defs',
    'map_objects',
    'plants',
    'plant_memberships',
    'field_events',
    'operations',
    'operation_rows',
  ];

  /// Every row of every table, as text, in a stable order.
  Map<String, List<String>> dump(Database raw) => {
    for (final t in tables)
      t: [
        for (final row in raw.select('SELECT * FROM $t ORDER BY rowid'))
          [
            for (final e in row.entries)
              if (e.key != 'discarded_at') '${e.key}=${e.value}',
          ].join('|'),
      ],
  };

  test(
    'a Five Sisters-shaped vineyard comes through the upgrade untouched',
    () async {
      final db = AppDatabase(NativeDatabase(file));
      final labels = LabelService(db);
      final layout = LayoutDao(db, labels, MembershipService(db));
      final fields = FieldDefsDao(db);
      final events = FieldEventsDao(db);
      final recorder = OperationRecorder(db);
      final projects = ProjectsDao(db);

      final projectId = await projects.create(name: 'Five Sisters');
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
                    blankPlaceholder: container ? '0' : null,
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
      final block = await make(
        'Block',
        FieldType.text,
        role: FieldRole.object,
        draw: DrawType.polygon,
        container: true,
      );
      await make(
        'Variety',
        FieldType.categorical,
        isStatic: true,
        config: const FieldConfig(options: ['Pinot Noir', 'Teroldego']),
      );
      await make(
        'Clone',
        FieldType.categorical,
        isStatic: true,
        config: const FieldConfig(options: ['667', '37', '2A', 'Teroldego']),
      );
      final health = await make(
        'Health',
        FieldType.categorical,
        config: const FieldConfig(
          options: ['1', '2', '3', '4', '5', 'Dead', 'Rootstock'],
        ),
      );
      await projects.setIdentifierTemplate(
        projectId,
        IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart(block), FieldPart(row), const PlantPart()],
        ),
      );

      // Three blocks of rows, planted.
      var label = 1;
      for (var b = 0; b < 3; b++) {
        final top = b * 120.0;
        await layout.createObject(
          projectId: projectId,
          fieldDefId: block,
          label: '${b + 1}',
          geometry: PolygonShape([
            Offset(0, top),
            Offset(200, top),
            Offset(200, top + 100),
            Offset(0, top + 100),
          ]),
        );
        for (var r = 0; r < 4; r++) {
          final y = top + 10 + r * 20;
          final carrier = await layout.createObject(
            projectId: projectId,
            fieldDefId: row,
            label: '${label++}',
            geometry: PolylineShape(Polyline([Offset(10, y), Offset(190, y)])),
          );
          await layout.placePlantsAlongCarrier(
            carrierId: carrier,
            offsets: [for (var o = 0.0; o <= 170; o += 10) o],
          );
        }
      }

      // An import, as the tablet's was.
      final ids = await labels.identifiersForProject(projectId);
      final import = ImportService(
        fieldDefs: fields,
        events: events,
        labels: labels,
      );
      final sheet = TableData(
        headers: const ['ID', 'Variety', 'Clone', 'Health'],
        rows: [
          for (final (i, id) in ids.values.indexed)
            [
              id.text,
              i == 0 ? 'Teroldego' : 'Pinot Noir',
              ['667', '37', '2A'][i % 3],
              ['2', '4', 'Dead', '3', 'Rootstock'][i % 5],
            ],
        ],
      );
      final plan = await import.plan(projectId, sheet);
      await recorder.run(
        projectId: projectId,
        kind: 'import',
        description: 'Import',
        body: () => import.apply(plan, overwriteWriteOnce: false),
      );

      // Hand edits, one of them undone and left redoable.
      final someone = ids.keys.first;
      await recorder.run(
        projectId: projectId,
        kind: 'set_value',
        description: 'Set Health to 5',
        body: () =>
            events.record(plantId: someone, fieldDefId: health, value: '5'),
      );
      await recorder.run(
        projectId: projectId,
        kind: 'set_value',
        description: 'Set Health to 1',
        body: () =>
            events.record(plantId: someone, fieldDefId: health, value: '1'),
      );
      await UndoService(db).undo(projectId);

      final idsBefore = {
        for (final e in (await labels.identifiersForProject(projectId)).entries)
          e.key: e.value.text,
      };
      final valuesBefore = await events.currentValuesForPlant(someone);
      await db.close();

      // Wind it back to exactly what 0.9.0 and earlier have on disk.
      var raw = sqlite3.open(file.path);
      raw.execute('ALTER TABLE operations DROP COLUMN discarded_at');
      raw.execute('DROP TABLE walk_orders'); // v6
      raw.execute('PRAGMA user_version = 4');
      final before = dump(raw);
      raw.close();

      // Open it with this build.
      final upgraded = AppDatabase(NativeDatabase(file));
      final upgradedLabels = LabelService(upgraded);
      final upgradedEvents = FieldEventsDao(upgraded);
      final idsAfter = {
        for (final e in (await upgradedLabels.identifiersForProject(
          projectId,
        )).entries)
          e.key: e.value.text,
      };
      final valuesAfter = await upgradedEvents.currentValuesForPlant(someone);
      final available = await UndoService(upgraded).availability(projectId);
      await upgraded.close();

      raw = sqlite3.open(file.path);
      final after = dump(raw);
      final version = raw.select('PRAGMA user_version').first.values.first;
      raw.close();

      expect(version, 6);
      for (final t in tables) {
        expect(after[t], before[t], reason: '$t changed in the upgrade');
      }
      expect(before['plants'], hasLength(216));
      expect(idsAfter, idsBefore);
      expect(
        {for (final e in valuesAfter.entries) e.key: e.value.value},
        {for (final e in valuesBefore.entries) e.key: e.value.value},
      );
      // The undone edit is still one press of redo away.
      expect(available.redo?.description, 'Set Health to 1');
    },
  );
}
