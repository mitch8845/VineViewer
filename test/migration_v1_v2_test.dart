import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// Proves the v1 -> v2 upgrade against a database that already holds data.
///
/// This matters more than the usual migration test. Version 1 shipped: it is on
/// a tablet right now with a vineyard in it. A migration that has only ever run
/// against a fresh database is a guess, and the specific thing being guessed at
/// here is nasty -- if the capture triggers were installed in `onCreate` alone,
/// every test in the suite would still pass while undo silently captured
/// nothing on the one device that matters.
///
/// **How v1 is simulated.** The upgrade is purely additive: v2 adds three
/// tables and eighteen triggers and changes nothing about the original six. So
/// a faithful v1 file is the current schema with the journal removed and
/// `user_version` wound back, which is what [_makeVersion1Database] does. That
/// is exactly the state a real v1 file is in.
void main() {
  setUp(() {
    // Each handle below is closed before the next opens; reopening the same
    // file is the whole point of the test.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDown(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vineviewer_migration');
    file = File('${directory.path}/v1.sqlite');
  });

  tearDown(() => directory.delete(recursive: true));

  /// Leaves [file] holding a populated version-1 database.
  Future<String> makeVersion1Database() async {
    final db = AppDatabase(NativeDatabase(file));

    final projectId = await ProjectsDao(db).create(name: 'Five Sisters');

    await db.customStatement('DROP TABLE IF EXISTS operation_rows');
    await db.customStatement('DROP TABLE IF EXISTS operations');
    await db.customStatement('DROP TABLE IF EXISTS undo_context');
    for (final table in db.journaledTables) {
      for (final suffix in ['insert', 'update', 'delete']) {
        await db.customStatement(
          'DROP TRIGGER IF EXISTS jr_${table.actualTableName}_$suffix',
        );
      }
    }
    await db.customStatement('PRAGMA user_version = 1');

    await db.close();
    return projectId;
  }

  test('upgrading installs the journal and keeps the data', () async {
    final projectId = await makeVersion1Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // The vineyard survived.
    final project = await ProjectsDao(db).byId(projectId);
    expect(project, isNotNull);
    expect(project!.name, 'Five Sisters');

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.first, 2);
  });

  test('the triggers fire on an upgraded database, not just a new one', () async {
    // The bug this exists to catch. Creating triggers only in `onCreate` leaves
    // an upgraded device with tables but no capture: undo appears installed and
    // reverses nothing.
    final projectId = await makeVersion1Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final projects = ProjectsDao(db);
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
    expect((await projects.byId(projectId))!.name, 'Five Sisters');
  });

  test('the context row exists after an upgrade', () async {
    // A missing undo_context row makes every trigger a silent no-op, which is
    // indistinguishable from undo being switched off.
    await makeVersion1Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await db.select(db.undoContext).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, 1);
    expect(rows.single.operationId, isNull);
  });

  test('label history reads back across the upgrade', () async {
    // Journal-derived history only starts at the upgrade -- there is no record
    // of what happened under v1, and pretending otherwise would be worse than
    // saying so.
    final projectId = await makeVersion1Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await LabelService(db).historyOf('nonexistent-vine'), isEmpty);
    expect((await UndoService(db).availability(projectId)).canUndo, isFalse);
  });
}
