import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// v4 -> v5 is the first upgrade that must keep everything: every tablet in
/// the field is on v4 with real data in it.
void main() {
  late Directory dir;
  late File file;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vv_v5_');
    file = File('${dir.path}/app.sqlite');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A real database, wound back to exactly what v4 created.
  Future<String> makeV4Database() async {
    final db = AppDatabase(NativeDatabase(file));
    final projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    await OperationRecorder(db).run(
      projectId: projectId,
      kind: 'rename',
      description: 'Rename vineyard',
      body: () => ProjectsDao(db).rename(projectId, 'Five Sisters Vineyard'),
    );
    await db.close();

    final raw = sqlite3.open(file.path);
    raw.execute('ALTER TABLE operations DROP COLUMN discarded_at');
    raw.execute('PRAGMA user_version = 4');
    raw.close();
    return projectId;
  }

  test('upgrading from v4 keeps every project and every operation', () async {
    final projectId = await makeV4Database();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.first, 5);
    expect(
      (await ProjectsDao(db).byId(projectId))?.name,
      'Five Sisters Vineyard',
    );
    final ops = await db.select(db.operations).get();
    expect(ops.single.description, 'Rename vineyard');
    expect(ops.single.discardedAt, isNull);

    // And the journal still works across the upgrade.
    await UndoService(db).undo(projectId);
    expect((await ProjectsDao(db).byId(projectId))?.name, 'Five Sisters');
  });

  test(
    'an abandoned undo is kept, not deleted, and cannot be redone',
    () async {
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final projects = ProjectsDao(db);
      final recorder = OperationRecorder(db);
      final undo = UndoService(db);
      final projectId = await projects.create(name: 'A');

      await recorder.run(
        projectId: projectId,
        kind: 'rename',
        description: 'Rename to B',
        body: () => projects.rename(projectId, 'B'),
      );
      await undo.undo(projectId);
      await recorder.run(
        projectId: projectId,
        kind: 'rename',
        description: 'Rename to C',
        body: () => projects.rename(projectId, 'C'),
      );

      final ops = await db.select(db.operations).get();
      expect(ops.map((o) => o.description), ['Rename to B', 'Rename to C']);
      expect(ops.first.undoneAt, isNotNull);
      expect(ops.first.discardedAt, isNotNull);

      final available = await undo.availability(projectId);
      expect(available.redo, isNull);
      expect(available.undo?.description, 'Rename to C');
    },
  );
}
