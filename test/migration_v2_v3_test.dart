import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// The v2 to v3 upgrade, which **wipes**.
///
/// v3 is a fresh schema rather than surgery on v2: `blocks` and `vine_rows` do
/// not map onto `map_objects` without inventing the object fields they would be
/// instances of, the container flags, the placeholders and a template. Both v2
/// projects in existence were throwaway, so writing that migration would have
/// cost more than redrawing them.
///
/// What still has to be true afterwards is that the database *works*: the new
/// tables exist, the undo context row is seeded, and -- the specific bug the
/// v1 to v2 test existed to catch -- **the capture triggers fire on an upgraded
/// file, not only on a fresh one**.
///
/// The next migration will be the first one written against data anyone wants
/// to keep. That one needs a fixture with real rows in it.
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
    directory = await Directory.systemTemp.createTemp('vineviewer_v3');
    file = File('${directory.path}/v2.sqlite');
  });

  tearDown(() => directory.delete(recursive: true));

  /// Leaves [file] holding a populated version-2 database.
  ///
  /// The v2 schema is written out by hand because the Dart definitions for
  /// `blocks` and `vine_rows` no longer exist -- which is exactly the situation
  /// a migration fixture is for.
  Future<void> makeVersion2Database() async {
    // Built with sqlite3 directly rather than through drift: the Dart
    // definitions for blocks and vine_rows no longer exist, which is exactly
    // the situation a migration fixture has to cope with.
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
    run('''
      CREATE TABLE operations (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL, kind TEXT NOT NULL,
        description TEXT NOT NULL, undone_at INTEGER,
        created_at INTEGER NOT NULL)''');
    run('''
      CREATE TABLE operation_rows (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        operation_id INTEGER NOT NULL, target_table TEXT NOT NULL,
        row_id TEXT NOT NULL, before TEXT, after TEXT)''');
    run('''
      CREATE TABLE undo_context (
        id INTEGER NOT NULL PRIMARY KEY, operation_id INTEGER)''');
    run('INSERT INTO undo_context (id, operation_id) VALUES (1, NULL)');

    // A v2 trigger, so the drop-by-name step has something to drop. Leaving one
    // behind naming a vanished table is a trap for the *next* migration.
    run('''
      CREATE TRIGGER jr_blocks_insert AFTER INSERT ON blocks BEGIN
        INSERT INTO operation_rows (operation_id, target_table, row_id,
                                    before, after)
        SELECT (SELECT operation_id FROM undo_context WHERE id = 1),
               'blocks', NEW.id, NULL, NULL
        WHERE (SELECT operation_id FROM undo_context WHERE id = 1) IS NOT NULL;
      END''');

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

  test('upgrading leaves a working v3 database', () async {
    await makeVersion2Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.first, 3);

    // The v2 tables are gone, and the v3 ones are usable.
    final projectId = await ProjectsDao(db).create(name: 'Fresh');
    expect(await ProjectsDao(db).byId(projectId), isNotNull);
    expect(await db.select(db.mapObjects).get(), isEmpty);
    expect(await db.select(db.plantMemberships).get(), isEmpty);
  });

  test('the wipe really does drop the old data', () async {
    // Stated plainly because it is a deliberate loss, not an accident.
    await makeVersion2Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await ProjectsDao(db).all(), isEmpty);
  });

  test('old triggers do not survive as dangling definitions', () async {
    await makeVersion2Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final triggers = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'")
        .get();
    final names = {for (final r in triggers) r.read<String>('name')};

    expect(names, isNot(contains('jr_blocks_insert')));
    expect(names, contains('jr_map_objects_insert'));
    expect(names, contains('jr_plant_memberships_insert'));
  });

  test('the context row exists after an upgrade', () async {
    // A missing undo_context row makes every trigger a silent no-op, which is
    // indistinguishable from undo being switched off.
    await makeVersion2Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await db.select(db.undoContext).get();
    expect(rows, hasLength(1));
    expect(rows.single.operationId, isNull);
  });

  test(
    'the triggers fire on the upgraded file, not just a fresh one',
    () async {
      // The specific bug this file inherits from the v1 to v2 test: triggers
      // created only in onCreate leave an upgraded device with tables but no
      // capture, so undo appears installed and reverses nothing.
      await makeVersion2Database();

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
}
