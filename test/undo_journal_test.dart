import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Tests for the capture layer itself -- the SQLite triggers, exercised through
/// raw statements rather than through [OperationRecorder].
///
/// Kept separate from the recorder's own tests on purpose: if capture breaks,
/// this file says so directly instead of every undo test failing at once with
/// no indication of which half is at fault.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  /// Opens an operation by hand, the way OperationRecorder will.
  Future<int> openOperation({String projectId = 'p1'}) async {
    final id = await db
        .into(db.operations)
        .insert(
          OperationsCompanion.insert(
            projectId: projectId,
            kind: 'test',
            description: 'test operation',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await db.customStatement(
      'UPDATE undo_context SET operation_id = ? WHERE id = 1',
      [id],
    );
    return id;
  }

  Future<void> closeOperation() => db.customStatement(
    'UPDATE undo_context SET operation_id = NULL WHERE id = 1',
  );

  Future<List<OperationRow>> journal() => db.select(db.operationRows).get();

  Future<String> insertProject(String id) async {
    await db
        .into(db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: id,
            name: 'Home Block',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    return id;
  }

  test('the JSON1 functions the triggers rely on are available', () async {
    // json_object is compiled into SQLite by default from 3.38 onward, but the
    // whole capture mechanism rests on it, so prove it rather than assume it.
    final row = await db
        .customSelect("SELECT json_object('a', 1, 'b', NULL) AS j")
        .getSingle();
    expect(jsonDecode(row.read<String>('j')), {'a': 1, 'b': null});
  });

  test('nothing is captured while no operation is open', () async {
    await insertProject('p1');
    expect(await journal(), isEmpty);
  });

  test('an insert is captured with a null before', () async {
    await openOperation();
    await insertProject('p1');
    await closeOperation();

    final rows = await journal();
    expect(rows, hasLength(1));
    expect(rows.single.targetTable, 'projects');
    expect(rows.single.rowId, 'p1');
    expect(rows.single.before, isNull);
    expect(jsonDecode(rows.single.after!), containsPair('name', 'Home Block'));
  });

  test('an update is captured with both sides', () async {
    await insertProject('p1');

    final operationId = await openOperation();
    await (db.update(db.projects)..where((p) => p.id.equals('p1'))).write(
      ProjectsCompanion(
        name: const Value('South Slope'),
        updatedAt: Value(DateTime.utc(2026, 2, 1)),
      ),
    );
    await closeOperation();

    final rows = await journal();
    expect(rows, hasLength(1));
    expect(rows.single.operationId, operationId);
    expect(jsonDecode(rows.single.before!), containsPair('name', 'Home Block'));
    expect(jsonDecode(rows.single.after!), containsPair('name', 'South Slope'));
  });

  test('a delete is captured with a null after', () async {
    await insertProject('p1');

    await openOperation();
    await (db.delete(db.projects)..where((p) => p.id.equals('p1'))).go();
    await closeOperation();

    final rows = await journal();
    expect(rows, hasLength(1));
    expect(rows.single.after, isNull);
    expect(jsonDecode(rows.single.before!), containsPair('id', 'p1'));
  });

  test('captured JSON carries every column the table has', () async {
    // The triggers are generated from drift's table metadata precisely so that
    // adding a column cannot silently stop capturing it. This is the test that
    // would fail if that generation regressed to a hand-written column list.
    await openOperation();
    await insertProject('p1');
    await closeOperation();

    final captured = jsonDecode((await journal()).single.after!) as Map;
    final expected = db.projects.$columns.map((c) => c.name).toSet();
    expect(captured.keys.toSet(), expected);
  });

  test('every journaled table has its three triggers installed', () async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'")
        .get();
    final installed = rows.map((r) => r.read<String>('name')).toSet();

    for (final table in db.journaledTables) {
      for (final suffix in ['insert', 'update', 'delete']) {
        expect(
          installed,
          contains('jr_${table.actualTableName}_$suffix'),
          reason: '${table.actualTableName} is missing its $suffix trigger',
        );
      }
    }
  });

  test('bulk writes are captured row by row', () async {
    // recordBulk and the seeding path both go through drift's batch(), which
    // still reaches SQLite as ordinary statements -- so the triggers fire and
    // a 3,000-vine operation is undoable. Proving it here because "batched"
    // sounds like it might bypass them.
    await insertProject('p1');
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: 'f1',
            projectId: 'p1',
            name: 'Row',
            type: FieldType.text,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
    await openOperation();
    await db.batch((b) {
      b.insertAll(db.mapObjects, [
        for (var i = 1; i <= 5; i++)
          MapObjectsCompanion.insert(
            id: 'o$i',
            projectId: 'p1',
            fieldDefId: 'f1',
            label: '$i',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
      ]);
    });
    await closeOperation();

    expect(await journal(), hasLength(5));
  });
}
