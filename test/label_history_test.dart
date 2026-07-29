import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';

void main() {
  late AppDatabase db;
  late LabelService labels;
  late LayoutDao layout;
  late OperationRecorder recorder;

  late String projectId;
  late String blockId;
  late String rowId;
  late List<String> vineIds;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    layout = LayoutDao(db, labels);
    recorder = OperationRecorder(db);

    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    blockId = await layout.createBlock(projectId: projectId, label: '3');
    rowId = await layout.createRow(
      projectId: projectId,
      label: '12',
      blockId: blockId,
      path: Polyline([const Offset(0, 0), const Offset(400, 0)]),
    );
    vineIds = await layout.placeVinesAlongRow(
      rowId: rowId,
      offsets: [for (var i = 0; i < 8; i++) i * 50.0],
    );
  });

  tearDown(() async => db.close());

  Future<T> gesture<T>(String description, Future<T> Function() body) =>
      recorder.run(
        projectId: projectId,
        kind: 'test',
        description: description,
        body: body,
      );

  test('a vine that has never moved reports just its current label', () async {
    final history = await labels.historyOf(vineIds[6]);
    expect(history, hasLength(1));
    expect(history.single.label.text, '3.12.7');
    // Nothing in the journal explains it, and saying "since 1970" would be a
    // fabrication.
    expect(history.single.at, isNull);
  });

  test('an unknown vine has no history', () async {
    expect(await labels.historyOf('not-a-vine'), isEmpty);
  });

  test(
    'a shift insert is visible in the history of the vines it moved',
    () async {
      // 3.12.7 is about to become 3.12.8. This is exactly the case that makes a
      // 2025 paper note ambiguous without a record.
      final moved = vineIds[6];
      expect((await labels.labelOf(moved))!.text, '3.12.7');

      final inserted = await layout.createVine(
        projectId: projectId,
        position: const Offset(275, 0),
      );
      await gesture(
        'Insert vine in row 12',
        () => labels.insertAfter(
          vineId: inserted,
          rowId: rowId,
          afterPositionIdx: 6,
          shift: true,
        ),
      );

      expect((await labels.labelOf(moved))!.text, '3.12.8');

      final history = await labels.historyOf(moved);
      expect(history.map((c) => c.label.text), ['3.12.7', '3.12.8']);
      expect(history.last.reason, 'Insert vine in row 12');
      expect(history.last.at, isNotNull);
    },
  );

  test('renaming the row rewrites the label of every vine on it', () async {
    await gesture(
      'Rename row 12 to 13',
      () => db.customStatement(
        "UPDATE vine_rows SET label = '13' WHERE id = ?",
        [rowId],
      ),
    );

    final history = await labels.historyOf(vineIds.first);
    expect(history.map((c) => c.label.text), ['3.12.1', '3.13.1']);
    expect(history.last.reason, 'Rename row 12 to 13');
  });

  test('renaming the block rewrites it too', () async {
    await gesture(
      'Rename block 3 to 4',
      () => db.customStatement("UPDATE blocks SET label = '4' WHERE id = ?", [
        blockId,
      ]),
    );

    final history = await labels.historyOf(vineIds.first);
    expect(history.map((c) => c.label.text), ['3.12.1', '4.12.1']);
  });

  test('detaching a vine records it leaving the row', () async {
    await gesture(
      'Detach vine from row 12',
      () => labels.detachFromRow(vineId: vineIds[3]),
    );

    final history = await labels.historyOf(vineIds[3]);
    expect(history.first.label.text, '3.12.4');
    expect(history.last.label.hasRow, isFalse);
    expect(history.last.label.text, startsWith('3.0.'));
  });

  test('moving a vine without renaming it adds no entry', () async {
    // Most operations touch a vine without touching its address. Listing them
    // would bury the renames that are the point of this list.
    await gesture(
      'Move vine',
      () => layout.moveVine(vineIds.first, const Offset(120, 0)),
    );

    final history = await labels.historyOf(vineIds.first);
    expect(history, hasLength(1));
    expect(history.single.label.text, '3.12.1');
  });

  test('undoing a renumber removes it from the history as well', () async {
    final moved = vineIds[6];
    final inserted = await layout.createVine(
      projectId: projectId,
      position: const Offset(275, 0),
    );
    await gesture(
      'Insert vine in row 12',
      () => labels.insertAfter(
        vineId: inserted,
        rowId: rowId,
        afterPositionIdx: 6,
        shift: true,
      ),
    );
    expect(await labels.historyOf(moved), hasLength(2));

    await UndoService(db).undo(projectId);

    // Undo means it did not happen, matching the decision that undoing a data
    // write erases it. The alternative -- 3.12.7, then 3.12.8, then 3.12.7
    // again -- is technically truthful and useless to read.
    expect((await labels.labelOf(moved))!.text, '3.12.7');
    final history = await labels.historyOf(moved);
    expect(history, hasLength(1));
    expect(history.single.label.text, '3.12.7');
  });

  test('history is ordered oldest first', () async {
    await gesture(
      'Rename row 12 to 13',
      () => db.customStatement(
        "UPDATE vine_rows SET label = '13' WHERE id = ?",
        [rowId],
      ),
    );
    await gesture(
      'Rename row 13 to 14',
      () => db.customStatement(
        "UPDATE vine_rows SET label = '14' WHERE id = ?",
        [rowId],
      ),
    );

    final history = await labels.historyOf(vineIds.first);
    expect(history.map((c) => c.label.text), ['3.12.1', '3.13.1', '3.14.1']);
  });
}
