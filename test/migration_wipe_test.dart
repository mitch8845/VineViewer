import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// Upgrading to v4 from every version that has ever existed, all of which
/// **wipe**.
///
/// Two fixtures, because two shapes of old file exist in the world:
///
///  * **v2** -- `blocks` and `vine_rows` as hardcoded tables. These do not map
///    onto `map_objects` without inventing the object fields they would be
///    instances of, the container flags, the placeholders and a template.
///  * **v3** -- the generic engine, but with the table still called `vines` and
///    the event log keyed by `vine_id`. This one is a pure rename and *could*
///    have been an `ALTER TABLE`; it is a wipe only because nothing real was
///    ever drawn against v3.
///
/// v3 is the version actually on the tablet, so it is the path that matters
/// most and the one a v2-only fixture would have left untested.
///
/// What has to be true afterwards is that the database *works*: the new tables
/// exist, the undo context row is seeded, no trigger survives naming a table
/// that is gone, and -- the specific bug the v1-to-v2 test existed to catch --
/// **the capture triggers fire on an upgraded file, not only on a fresh one**.
///
/// The next migration will be the first one written against data anyone wants
/// to keep. That one needs a fixture with real rows in it that are still there
/// at the end.
void main() {
  setUp(() {
    // Each handle is closed before the next opens; reopening the same file is
    // the whole point of the test.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDown(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vineviewer_migration');
    file = File('${directory.path}/old.sqlite');
  });

  tearDown(() => directory.delete(recursive: true));

  /// The journal tables, identical in v2, v3 and v4.
  const journalSchema = [
    '''
      CREATE TABLE operations (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL, kind TEXT NOT NULL,
        description TEXT NOT NULL, undone_at INTEGER,
        created_at INTEGER NOT NULL)''',
    '''
      CREATE TABLE operation_rows (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        operation_id INTEGER NOT NULL, target_table TEXT NOT NULL,
        row_id TEXT NOT NULL, before TEXT, after TEXT)''',
    '''
      CREATE TABLE undo_context (
        id INTEGER NOT NULL PRIMARY KEY, operation_id INTEGER)''',
    'INSERT INTO undo_context (id, operation_id) VALUES (1, NULL)',
  ];

  /// A capture trigger on [table], as the version being faked would have left
  /// one behind. The body does not matter; its *existence* is what the
  /// drop-by-name step has to deal with, since a trigger outliving its table
  /// breaks the migration after this one rather than this one.
  String captureTrigger(String table) =>
      '''
      CREATE TRIGGER jr_${table}_insert AFTER INSERT ON $table BEGIN
        INSERT INTO operation_rows (operation_id, target_table, row_id,
                                    before, after)
        SELECT (SELECT operation_id FROM undo_context WHERE id = 1),
               '$table', NEW.id, NULL, NULL
        WHERE (SELECT operation_id FROM undo_context WHERE id = 1) IS NOT NULL;
      END''';

  /// Leaves [file] holding a populated version-2 database.
  ///
  /// Written out as literal SQL because the Dart definitions for `blocks`,
  /// `vine_rows` and `vines` no longer exist -- which is exactly the situation a
  /// migration fixture is for.
  Future<void> makeVersion2Database() async {
    final raw = sqlite3.open(file.path);
    void run(String sql) => raw.execute(sql);

    run('''
      CREATE TABLE projects (
        id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL,
        image_path TEXT, image_width INTEGER, image_height INTEGER,
        image_offset_x REAL NOT NULL DEFAULT 0,
        image_offset_y REAL NOT NULL DEFAULT 0,
        image_scale_x REAL NOT NULL DEFAULT 1,
        image_scale_y REAL NOT NULL DEFAULT 1,
        image_rotation REAL NOT NULL DEFAULT 0,
        scale_ref_px REAL, scale_ref_length REAL, scale_unit TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE blocks (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        label TEXT NOT NULL, boundary TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE vine_rows (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        block_id TEXT, label TEXT NOT NULL, path TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE vines (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        row_id TEXT, block_id TEXT, position_idx INTEGER NOT NULL,
        x REAL, y REAL, path_offset REAL,
        status TEXT NOT NULL DEFAULT 'active',
        planted_at INTEGER, ended_at INTEGER, predecessor_id TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE field_defs (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        name TEXT NOT NULL, type TEXT NOT NULL,
        is_static INTEGER NOT NULL DEFAULT 0, config TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE field_events (
        id TEXT NOT NULL PRIMARY KEY, vine_id TEXT NOT NULL,
        field_def_id TEXT NOT NULL, value TEXT,
        observed_at INTEGER NOT NULL, recorded_at INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual', batch_id TEXT, note TEXT,
        deleted_at INTEGER)''');
    for (final statement in journalSchema) {
      run(statement);
    }
    run(captureTrigger('blocks'));
    run(captureTrigger('vines'));

    run(
      "INSERT INTO projects (id, name, created_at, updated_at) "
      "VALUES ('p1', 'Old vineyard', 0, 0)",
    );
    run(
      "INSERT INTO blocks (id, project_id, label, created_at, updated_at) "
      "VALUES ('b1', 'p1', '3', 0, 0)",
    );
    run(
      "INSERT INTO vines (id, project_id, block_id, position_idx, "
      "created_at, updated_at) VALUES ('v1', 'p1', 'b1', 1, 0, 0)",
    );
    run('PRAGMA user_version = 2');
    raw.close();
  }

  /// Leaves [file] holding a populated version-3 database.
  ///
  /// The generic engine, one rename short of v4: the table is `vines` and the
  /// event log's foreign key is `vine_id`. This is the file that shipped as
  /// 0.4.0.
  Future<void> makeVersion3Database() async {
    final raw = sqlite3.open(file.path);
    void run(String sql) => raw.execute(sql);

    run('''
      CREATE TABLE projects (
        id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL,
        image_path TEXT, image_width INTEGER, image_height INTEGER,
        image_offset_x REAL NOT NULL DEFAULT 0,
        image_offset_y REAL NOT NULL DEFAULT 0,
        image_scale_x REAL NOT NULL DEFAULT 1,
        image_scale_y REAL NOT NULL DEFAULT 1,
        image_rotation REAL NOT NULL DEFAULT 0,
        scale_ref_px REAL, scale_ref_length REAL, scale_unit TEXT,
        identifier_template TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE map_objects (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        field_def_id TEXT NOT NULL, label TEXT NOT NULL, geometry TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE plant_memberships (
        id TEXT NOT NULL PRIMARY KEY, vine_id TEXT NOT NULL,
        object_id TEXT NOT NULL, field_def_id TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''');
    run('''
      CREATE TABLE vines (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        carrier_id TEXT, position_idx INTEGER NOT NULL,
        x REAL, y REAL, path_offset REAL,
        status TEXT NOT NULL DEFAULT 'active',
        planted_at INTEGER, ended_at INTEGER, predecessor_id TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE field_defs (
        id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL,
        name TEXT NOT NULL, type TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'attribute', draw_type TEXT,
        is_container INTEGER NOT NULL DEFAULT 0,
        blank_placeholder TEXT, tolerance REAL,
        is_static INTEGER NOT NULL DEFAULT 0, config TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        deleted_at INTEGER)''');
    run('''
      CREATE TABLE field_events (
        id TEXT NOT NULL PRIMARY KEY, vine_id TEXT NOT NULL,
        field_def_id TEXT NOT NULL, value TEXT,
        observed_at INTEGER NOT NULL, recorded_at INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual', batch_id TEXT, note TEXT,
        deleted_at INTEGER)''');
    for (final statement in journalSchema) {
      run(statement);
    }
    run(captureTrigger('map_objects'));
    run(captureTrigger('plant_memberships'));
    run(captureTrigger('vines'));

    run(
      "INSERT INTO projects (id, name, created_at, updated_at) "
      "VALUES ('p1', 'Five Sisters', 0, 0)",
    );
    run(
      "INSERT INTO field_defs (id, project_id, name, type, role, draw_type, "
      "is_container, created_at, updated_at) VALUES "
      "('f1', 'p1', 'Row', 'text', 'object', 'polyline', 1, 0, 0)",
    );
    run(
      "INSERT INTO map_objects (id, project_id, field_def_id, label, "
      "created_at, updated_at) VALUES ('o1', 'p1', 'f1', '12', 0, 0)",
    );
    run(
      "INSERT INTO vines (id, project_id, carrier_id, position_idx, "
      "created_at, updated_at) VALUES ('v1', 'p1', 'o1', 1, 0, 0)",
    );
    run(
      "INSERT INTO plant_memberships (id, vine_id, object_id, field_def_id, "
      "created_at, updated_at) VALUES ('m1', 'v1', 'o1', 'f1', 0, 0)",
    );
    run('PRAGMA user_version = 3');
    raw.close();
  }

  /// Every assertion is made against both fixtures, so neither upgrade path can
  /// rot while the other keeps passing.
  final fixtures = <String, Future<void> Function()>{
    'v2': makeVersion2Database,
    'v3': makeVersion3Database,
  };

  for (final fixture in fixtures.entries) {
    group('upgrading from ${fixture.key}', () {
      test('leaves a working v4 database', () async {
        await fixture.value();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        final version = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.data.values.first, 4);

        // The old tables are gone and the v4 ones are usable.
        final projectId = await ProjectsDao(db).create(name: 'Fresh');
        expect(await ProjectsDao(db).byId(projectId), isNotNull);
        expect(await db.select(db.mapObjects).get(), isEmpty);
        expect(await db.select(db.plantMemberships).get(), isEmpty);
        expect(await db.select(db.plants).get(), isEmpty);
      });

      test('really does drop the old data', () async {
        // Stated plainly because it is a deliberate loss, not an accident.
        await fixture.value();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        expect(await ProjectsDao(db).all(), isEmpty);
      });

      test('the table under its old name is gone', () async {
        // The rename sweep's specific hazard: `vines` has no Dart definition
        // any more, so the drop list has to name it as a literal string.
        // Tidying that string into `plants` would leave the real table in
        // place, and the symptom would be a v4 database quietly carrying a dead
        // v3 table around forever.
        await fixture.value();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        final tables = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get();
        final names = {for (final r in tables) r.read<String>('name')};

        expect(names, isNot(contains('vines')));
        expect(names, isNot(contains('vine_rows')));
        expect(names, isNot(contains('blocks')));
        expect(names, contains('plants'));
      });

      test('old triggers do not survive as dangling definitions', () async {
        await fixture.value();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        final triggers = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'trigger'",
            )
            .get();
        final names = {for (final r in triggers) r.read<String>('name')};

        expect(names, isNot(contains('jr_vines_insert')));
        expect(names, isNot(contains('jr_blocks_insert')));
        expect(names, contains('jr_plants_insert'));
        expect(names, contains('jr_map_objects_insert'));
        expect(names, contains('jr_plant_memberships_insert'));
      });

      test('the context row exists afterwards', () async {
        // A missing undo_context row makes every trigger a silent no-op, which
        // is indistinguishable from undo being switched off.
        await fixture.value();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        final rows = await db.select(db.undoContext).get();
        expect(rows, hasLength(1));
        expect(rows.single.operationId, isNull);
      });

      test(
        'the triggers fire on the upgraded file, not just a fresh one',
        () async {
          // The specific bug this file inherits from the v1-to-v2 test: triggers
          // created only in onCreate leave an upgraded device with tables but no
          // capture, so undo appears installed and reverses nothing.
          await fixture.value();

          final db = AppDatabase(NativeDatabase(file));
          addTearDown(db.close);

          final projects = ProjectsDao(db);
          final projectId = await projects.create(name: 'Fresh');

          await OperationRecorder(db).run(
            projectId: projectId,
            kind: 'rename_project',
            description: 'Rename to South Slope',
            body: () => projects.rename(projectId, 'South Slope'),
          );
          expect((await projects.byId(projectId))!.name, 'South Slope');

          final undo = UndoService(db);
          expect((await undo.availability(projectId)).canUndo, isTrue);
          await undo.undo(projectId);
          expect((await projects.byId(projectId))!.name, 'Fresh');
        },
      );
    });
  }
}
