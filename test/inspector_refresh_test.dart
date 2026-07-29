import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// The inspector's values must follow the database, not its own bookkeeping.
///
/// Found on the tablet: change a field, press undo, and the panel kept showing
/// the old value until an unrelated edit dislodged it. The cause was a manual
/// refresh counter that only the inspector's own write path bumped -- undo
/// writes to the event log directly, so nothing told the panel to re-read.
///
/// These tests watch the same stream the panel does, so a regression to any
/// refresh mechanism that undo can bypass fails here.
void main() {
  late AppDatabase db;
  late FieldEventsDao events;
  late OperationRecorder recorder;
  late UndoService undo;

  late String projectId;
  late String vineId;
  late String fieldId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    events = FieldEventsDao(db);
    recorder = OperationRecorder(db);
    undo = UndoService(db);

    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    await db.customStatement(
      'INSERT INTO vines (id, project_id, position_idx, status, '
      'created_at, updated_at) VALUES (?, ?, 1, ?, 0, 0)',
      ['v1', projectId, 'active'],
    );
    vineId = 'v1';

    final field = await FieldDefsDao(
      db,
    ).create(projectId: projectId, name: 'Health', type: FieldType.integer);
    fieldId = (field as FieldDefSaved).id;
  });

  tearDown(() async => db.close());

  /// Collects what the inspector would render, in order.
  Future<List<String?>> watchValues(Future<void> Function() actions) async {
    final seen = <String?>[];
    final subscription = events
        .watchCurrentValuesForVine(vineId)
        .listen((values) => seen.add(values[fieldId]?.value));
    addTearDown(subscription.cancel);

    await pumpEventQueue();
    await actions();
    await pumpEventQueue();
    return seen;
  }

  Future<void> write(String? value) => recorder.run(
    projectId: projectId,
    kind: 'set_value',
    description: 'Set Health',
    body: () =>
        events.record(vineId: vineId, fieldDefId: fieldId, value: value),
  );

  test('a write pushes the new value without being told', () async {
    final seen = await watchValues(() => write('4'));
    expect(seen.first, isNull);
    expect(seen.last, '4');
  });

  test('undoing a change reverts the panel with no other edit', () async {
    // The exact sequence that failed on the tablet.
    await write('4');

    final seen = await watchValues(() async {
      await write('1');
      await pumpEventQueue();
      await undo.undo(projectId);
    });

    expect(seen.first, '4', reason: 'should start at the value already stored');
    expect(seen, contains('1'), reason: 'the edit should have been shown');
    expect(
      seen.last,
      '4',
      reason: 'undo reverted the database but the panel did not follow',
    );
  });

  test('undoing a clear brings the value back', () async {
    await write('4');

    final seen = await watchValues(() async {
      // A cleared field stores a null value, which is distinct from never
      // having been recorded -- and undoing that clear has to restore the 4.
      await write(null);
      await pumpEventQueue();
      await undo.undo(projectId);
    });

    expect(seen.first, '4');
    expect(seen.last, '4');
  });

  test('redo re-applies without an unrelated edit either', () async {
    await write('4');
    await write('1');
    await undo.undo(projectId);

    final seen = await watchValues(() => undo.redo(projectId));
    expect(seen.first, '4');
    expect(seen.last, '1');
  });
}
