import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// What a plant has been called over time.
///
/// Derived from the undo journal rather than a table of its own, so there is
/// one source of truth. The interesting cases are the ones where the plant
/// itself is never touched: renaming a block, or dragging a boundary so a plant
/// falls into a different one.
void main() {
  late AppDatabase db;

  late LabelService labels;

  late MembershipService memberships;

  late OperationRecorder recorder;

  const projectId = 'p1';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    memberships = MembershipService(db);
    recorder = OperationRecorder(db);
    await db.customStatement(
      'INSERT INTO projects (id, name, image_offset_x, image_offset_y, '
      'image_scale_x, image_scale_y, image_rotation, created_at, updated_at, '
      'identifier_template) '
      "VALUES ('$projectId', 'Five Sisters', 0, 0, 1, 1, 0, 0, 0, ?)",
      [
        const IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart('f_block'), PlantPart()],
        ).toJson(),
      ],
    );
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: 'f_block',
            projectId: projectId,
            name: 'Block',
            type: FieldType.text,
            role: const Value(FieldRole.object),
            drawType: const Value(DrawType.polygon),
            isContainer: const Value(true),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
  });

  tearDown(() async => db.close());

  Shape squareAt(double left, double size) => PolygonShape([
    Offset(left, 0),
    Offset(left + size, 0),
    Offset(left + size, 100),
    Offset(left, 100),
  ]);

  Future<void> block(String id, String label, Shape shape) async {
    await db
        .into(db.mapObjects)
        .insert(
          MapObjectsCompanion.insert(
            id: id,
            projectId: projectId,
            fieldDefId: 'f_block',
            label: label,
            geometry: Value(shape.toJson()),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
  }

  Future<void> plant(String id, Offset at, int number) async {
    await db
        .into(db.vines)
        .insert(
          VinesCompanion.insert(
            id: id,
            projectId: projectId,
            positionIdx: number,
            x: Value(at.dx),
            y: Value(at.dy),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
  }

  Future<T> gesture<T>(String description, Future<T> Function() body) =>
      recorder.run(
        projectId: projectId,
        kind: 'test',
        description: description,
        body: body,
      );

  test('a plant that has never moved reports one entry', () async {
    await block('b1', '1', squareAt(0, 100));
    await plant('v', const Offset(50, 50), 7);
    await memberships.reconcile(projectId: projectId);

    final history = await labels.historyOf('v');
    expect(history, hasLength(1));
    expect(history.single.identifier.text, '1.7');
    // Nothing in the journal explains it, and inventing a date would be a
    // fabrication.
    expect(history.single.at, isNull);
  });

  test('an unknown plant has no history', () async {
    expect(await labels.historyOf('nope'), isEmpty);
  });

  test('renaming a block rewrites every identifier on it', () async {
    // The plant is never touched, which is the whole point.
    await block('b1', '1', squareAt(0, 100));
    await plant('v', const Offset(50, 50), 7);
    await memberships.reconcile(projectId: projectId);
    await gesture(
      'Rename block 1 to 4',
      () => db.customStatement(
        "UPDATE map_objects SET label = '4' WHERE id = 'b1'",
      ),
    );

    final history = await labels.historyOf('v');
    expect(history.map((c) => c.identifier.text), ['1.7', '4.7']);
    expect(history.last.reason, 'Rename block 1 to 4');
    expect(history.last.at, isNotNull);
  });

  test('renumbering the plant shows up', () async {
    await block('b1', '1', squareAt(0, 100));
    await plant('v', const Offset(50, 50), 7);
    await memberships.reconcile(projectId: projectId);
    await gesture(
      'Renumber',
      () =>
          db.customStatement("UPDATE vines SET position_idx = 8 WHERE id='v'"),
    );
    expect((await labels.historyOf('v')).map((c) => c.identifier.text), [
      '1.7',
      '1.8',
    ]);
  });

  test('undoing a rename removes it from the history', () async {
    await block('b1', '1', squareAt(0, 100));
    await plant('v', const Offset(50, 50), 7);
    await memberships.reconcile(projectId: projectId);
    await gesture(
      'Rename block 1 to 4',
      () => db.customStatement(
        "UPDATE map_objects SET label = '4' WHERE id = 'b1'",
      ),
    );
    expect(await labels.historyOf('v'), hasLength(2));
    await UndoService(db).undo(projectId);
    // Undo means it did not happen, matching the decision that undoing a data
    // write erases it.
    final history = await labels.historyOf('v');
    expect(history, hasLength(1));
    expect(history.single.identifier.text, '1.7');
  });

  test('history is ordered oldest first', () async {
    await block('b1', '1', squareAt(0, 100));
    await plant('v', const Offset(50, 50), 7);
    await memberships.reconcile(projectId: projectId);
    await gesture(
      'Rename to 2',
      () => db.customStatement(
        "UPDATE map_objects SET label = '2' WHERE id = 'b1'",
      ),
    );
    await gesture(
      'Rename to 3',
      () => db.customStatement(
        "UPDATE map_objects SET label = '3' WHERE id = 'b1'",
      ),
    );
    expect((await labels.historyOf('v')).map((c) => c.identifier.text), [
      '1.7',
      '2.7',
      '3.7',
    ]);
  });

  test('the current identifier is always the last entry', () async {
    // Something that bypasses the journal -- an import, a restored archive --
    // leaves the walk disagreeing with reality. Reality has to win.
    await block('b1', '1', squareAt(0, 100));
    await plant('v', const Offset(50, 50), 7);
    await memberships.reconcile(projectId: projectId);
    await db.customStatement(
      "UPDATE map_objects SET label = '9' WHERE id = 'b1'",
    );

    final history = await labels.historyOf('v');
    expect(history.last.identifier.text, '9.7');
    expect(history.last.at, isNull);
  });
}
