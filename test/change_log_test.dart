import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/change_log.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// The change log is read straight off the undo journal.
void main() {
  late AppDatabase db;
  late OperationRecorder recorder;
  late ChangeLog log;
  late String projectId;
  late String health;
  late FieldEventsDao events;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    recorder = OperationRecorder(db);
    log = ChangeLog(db);
    events = FieldEventsDao(db);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    health =
        ((await FieldDefsDao(db).create(
                  projectId: projectId,
                  name: 'Health',
                  type: FieldType.integer,
                ))
                as FieldDefSaved)
            .id;
    for (final id in ['a', 'b', 'c']) {
      await db.customStatement(
        'INSERT INTO plants (id, project_id, position_idx, status, '
        'created_at, updated_at) VALUES (?, ?, 1, ?, 0, 0)',
        [id, projectId, 'active'],
      );
    }
  });

  tearDown(() => db.close());

  Future<void> setHealth(String description, String value) => recorder.run(
    projectId: projectId,
    kind: 'bulk_set_value',
    description: description,
    body: () => events.recordBulk(
      plantIds: ['a', 'b', 'c'],
      fieldDefId: health,
      value: value,
    ),
  );

  test('every change, newest first, with what it touched', () async {
    await setHealth('Set Health on 3 plants', '4');
    await recorder.run(
      projectId: projectId,
      kind: 'rename_project',
      description: 'Rename vineyard',
      body: () => ProjectsDao(db).rename(projectId, 'Five Sisters Vineyard'),
    );

    final entries = await log.entries(projectId);
    expect(entries.map((e) => e.description), [
      'Rename vineyard',
      'Set Health on 3 plants',
    ]);
    final bulk = entries.last;
    expect(bulk.values, 3);
    expect(bulk.created, 3);
    expect(entries.first.updated, 1);
    expect(entries.every((e) => !e.isUndone), isTrue);
  });

  test('undone changes stay in the log, redoable until abandoned', () async {
    await setHealth('First', '4');
    await UndoService(db).undo(projectId);

    var first = (await log.entries(projectId)).single;
    expect(first.isUndone, isTrue);
    expect(first.canRedo, isTrue);

    await setHealth('Second', '2');
    final entries = await log.entries(projectId);
    expect(entries.map((e) => e.description), ['Second', 'First']);
    first = entries.last;
    expect(first.isUndone, isTrue);
    expect(first.canRedo, isFalse);
  });

  test('the log is per project', () async {
    final other = await ProjectsDao(db).create(name: 'Elsewhere');
    await recorder.run(
      projectId: other,
      kind: 'rename_project',
      description: 'Rename the other one',
      body: () => ProjectsDao(db).rename(other, 'X'),
    );
    expect(await log.entries(projectId), isEmpty);
  });
}
