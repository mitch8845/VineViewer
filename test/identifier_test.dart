import 'dart:ui' show Offset;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/numbering_service.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// Composing identifiers from a user-defined template, and numbering plants.
///
/// The template replaces v2's hardcoded `block.row.plant`. These tests prove it
/// can still produce exactly that -- the vineyard's own convention has to keep
/// working -- and that it can produce things v2 could not express at all.
void main() {
  late AppDatabase db;
  late LabelService labels;
  late MembershipService memberships;
  late NumberingService numbering;
  const projectId = 'p1';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    memberships = MembershipService(db);
    numbering = NumberingService(db, labels);

    await db.customStatement(
      'INSERT INTO projects (id, name, image_offset_x, image_offset_y, '
      'image_scale_x, image_scale_y, image_rotation, created_at, updated_at) '
      "VALUES ('$projectId', 'Five Sisters', 0, 0, 1, 1, 0, 0, 0)",
    );
  });

  tearDown(() async => db.close());

  Future<String> objectField({
    required String id,
    required String name,
    required DrawType drawType,
    String? placeholder,
  }) async {
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: id,
            projectId: projectId,
            name: name,
            type: FieldType.text,
            role: const Value(FieldRole.object),
            drawType: Value(drawType),
            isContainer: const Value(true),
            blankPlaceholder: Value(placeholder),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
    return id;
  }

  Future<String> attributeField({
    required String id,
    required String name,
    String? placeholder,
  }) async {
    await db
        .into(db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: id,
            projectId: projectId,
            name: name,
            type: FieldType.text,
            blankPlaceholder: Value(placeholder),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
    return id;
  }

  Future<String> drawn({
    required String id,
    required String fieldDefId,
    required String label,
    required Shape shape,
  }) async {
    await db
        .into(db.mapObjects)
        .insert(
          MapObjectsCompanion.insert(
            id: id,
            projectId: projectId,
            fieldDefId: fieldDefId,
            label: label,
            geometry: Value(shape.toJson()),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
    return id;
  }

  Future<String> plant(String id, Offset at, {int number = 1}) async {
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
    return id;
  }

  Future<void> setTemplate(IdentifierTemplate template) => db.customStatement(
    'UPDATE projects SET identifier_template = ? WHERE id = ?',
    [template.toJson(), projectId],
  );

  Shape squareAt(double left, double top, double size) => PolygonShape([
    Offset(left, top),
    Offset(left + size, top),
    Offset(left + size, top + size),
    Offset(left, top + size),
  ]);

  /// Block 3 containing row 12, with one plant numbered 7 -- the running
  /// example throughout the design.
  Future<({String block, String row, String vine})> vineyard() async {
    final blockField = await objectField(
      id: 'f_block',
      name: 'Block',
      drawType: DrawType.polygon,
    );
    final rowField = await objectField(
      id: 'f_row',
      name: 'Row',
      drawType: DrawType.polyline,
    );
    await drawn(
      id: 'b3',
      fieldDefId: blockField,
      label: '3',
      shape: squareAt(0, 0, 100),
    );
    await drawn(
      id: 'r12',
      fieldDefId: rowField,
      label: '12',
      shape: PolylineShape(
        Polyline([const Offset(0, 50), const Offset(100, 50)]),
      ),
    );
    await plant('v7', const Offset(50, 50), number: 7);
    await memberships.reconcile(projectId: projectId);
    return (block: blockField, row: rowField, vine: 'v7');
  }

  group('templates', () {
    test('Block.Row.Plant reproduces exactly what v2 produced', () async {
      final v = await vineyard();
      await setTemplate(
        IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart(v.block), FieldPart(v.row), const PlantPart()],
        ),
      );

      expect((await labels.identifierOf('v7'))!.text, '3.12.7');
    });

    test('a different delimiter and order', () async {
      final v = await vineyard();
      await setTemplate(
        IdentifierTemplate(
          delimiter: '&',
          parts: [FieldPart(v.row), const PlantPart()],
        ),
      );

      expect((await labels.identifierOf('v7'))!.text, '12&7');
    });

    test('a bare plant number', () async {
      await vineyard();
      await setTemplate(
        const IdentifierTemplate(delimiter: '.', parts: [PlantPart()]),
      );
      expect((await labels.identifierOf('v7'))!.text, '7');
    });

    test('no template at all falls back to the plant number', () async {
      // A project that skipped the wizard still shows something, which is what
      // makes the wizard skippable.
      await vineyard();
      expect((await labels.identifierOf('v7'))!.text, '7');
    });

    test('an attribute can be part of the identifier', () async {
      final v = await vineyard();
      final variety = await attributeField(id: 'f_var', name: 'Variety');
      await db
          .into(db.fieldEvents)
          .insert(
            FieldEventsCompanion.insert(
              id: 'e1',
              vineId: 'v7',
              fieldDefId: variety,
              value: const Value('PinotNoir'),
              observedAt: DateTime.utc(2026),
              recordedAt: DateTime.utc(2026),
            ),
          );

      await setTemplate(
        IdentifierTemplate(
          delimiter: '-',
          parts: [FieldPart(variety), FieldPart(v.row), const PlantPart()],
        ),
      );
      expect((await labels.identifierOf('v7'))!.text, 'PinotNoir-12-7');
    });
  });

  group('blank placeholders', () {
    test('a plant in no block reads as the placeholder', () async {
      final v = await vineyard();
      await plant('loose', const Offset(500, 500), number: 1);
      await memberships.reconcile(projectId: projectId);

      await setTemplate(
        IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart(v.block), FieldPart(v.row), const PlantPart()],
        ),
      );
      expect((await labels.identifierOf('loose'))!.text, '0.0.1');
    });

    test('the placeholder is per field', () async {
      await objectField(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
        placeholder: 'none',
      );
      await plant('loose', const Offset(500, 500), number: 1);

      await setTemplate(
        const IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart('f_block'), PlantPart()],
        ),
      );
      expect((await labels.identifierOf('loose'))!.text, 'none.1');
    });
  });

  group('label validation', () {
    test('a label equal to the placeholder is refused', () {
      // Or "0.12.7" becomes ambiguous between a real address and an
      // unassigned one -- the exact trap v2's reserved "0" documented.
      expect(
        LabelService.problemWithObjectLabel(label: '0', delimiter: '.'),
        isNotNull,
      );
      expect(
        LabelService.problemWithObjectLabel(
          label: 'none',
          delimiter: '.',
          blankPlaceholder: 'none',
        ),
        isNotNull,
      );
    });

    test('a label containing the delimiter is refused', () {
      expect(
        LabelService.problemWithObjectLabel(label: '12.3', delimiter: '.'),
        isNotNull,
      );
      // Only the delimiter actually in use, though.
      expect(
        LabelService.problemWithObjectLabel(label: '12.3', delimiter: '&'),
        isNull,
      );
    });

    test('an empty label is refused', () {
      expect(
        LabelService.problemWithObjectLabel(label: '  ', delimiter: '.'),
        isNotNull,
      );
    });
  });

  group('change counting', () {
    test('it reports how many identifiers a new template changes', () async {
      final v = await vineyard();
      await plant('v8', const Offset(60, 50), number: 8);
      await memberships.reconcile(projectId: projectId);

      final current = IdentifierTemplate(
        delimiter: '.',
        parts: [FieldPart(v.block), FieldPart(v.row), const PlantPart()],
      );
      await setTemplate(current);

      final data = await labels.dataFor(projectId);
      final change = LabelService.compare(
        LabelService.render(data, current),
        LabelService.render(
          data,
          const IdentifierTemplate(delimiter: '.', parts: [PlantPart()]),
        ),
      );

      expect(change.changed, 2);
      expect(change.isSafe, isTrue);
    });

    test('a template that would collide is reported unsafe', () async {
      // Two plants on different rows share plant number 7, so dropping Row
      // from the template makes them the same.
      final v = await vineyard();
      final rowField = v.row;
      await drawn(
        id: 'r13',
        fieldDefId: rowField,
        label: '13',
        shape: PolylineShape(
          Polyline([const Offset(0, 80), const Offset(100, 80)]),
        ),
      );
      await plant('other7', const Offset(50, 80), number: 7);
      await memberships.reconcile(projectId: projectId);

      final data = await labels.dataFor(projectId);
      final change = LabelService.compare(
        LabelService.render(
          data,
          IdentifierTemplate(
            delimiter: '.',
            parts: [FieldPart(rowField), const PlantPart()],
          ),
        ),
        LabelService.render(
          data,
          const IdentifierTemplate(delimiter: '.', parts: [PlantPart()]),
        ),
      );

      expect(change.isSafe, isFalse);
      expect(change.duplicates, ['7']);
    });
  });

  group('numbering', () {
    Future<void> threeInARow() async {
      await plant('a', const Offset(30, 10), number: 1);
      await plant('b', const Offset(10, 10), number: 2);
      await plant('c', const Offset(20, 10), number: 3);
    }

    test('left to right', () async {
      await threeInARow();
      final plan = await numbering.plan(
        vineIds: {'a', 'b', 'c'},
        startAt: 1,
        order: NumberingOrder.leftToRight,
      );
      expect(plan.assignments, {'b': 1, 'c': 2, 'a': 3});
    });

    test('right to left', () async {
      await threeInARow();
      final plan = await numbering.plan(
        vineIds: {'a', 'b', 'c'},
        startAt: 1,
        order: NumberingOrder.rightToLeft,
      );
      expect(plan.assignments, {'a': 1, 'c': 2, 'b': 3});
    });

    test('top to bottom, and starting somewhere other than 1', () async {
      await plant('top', const Offset(0, 0), number: 1);
      await plant('bottom', const Offset(0, 100), number: 2);

      final plan = await numbering.plan(
        vineIds: {'top', 'bottom'},
        startAt: 10,
        order: NumberingOrder.topToBottom,
      );
      expect(plan.assignments, {'top': 10, 'bottom': 11});
    });

    test('ordering is deterministic when positions tie', () async {
      // A row drawn at a slight angle has plants whose coordinates differ by
      // fractions of a pixel; without a total order they reshuffle between
      // runs and the numbering is not reproducible.
      await plant('z', const Offset(5, 5), number: 1);
      await plant('a', const Offset(5, 5), number: 2);

      for (var i = 0; i < 3; i++) {
        final plan = await numbering.plan(
          vineIds: {'a', 'z'},
          startAt: 1,
          order: NumberingOrder.leftToRight,
        );
        expect(plan.assignments, {'a': 1, 'z': 2});
      }
    });

    test('applying writes the numbers', () async {
      await threeInARow();
      final plan = await numbering.plan(
        vineIds: {'a', 'b', 'c'},
        startAt: 1,
        order: NumberingOrder.leftToRight,
      );

      expect(
        await numbering.apply(plan, projectId: projectId),
        isA<NumberingApplied>(),
      );
      final after = await labels.identifiersForProject(projectId);
      expect(after['b']!.text, '1');
      expect(after['a']!.text, '3');
    });

    test('a collision is refused and writes nothing', () async {
      // Two plants with no container, so their identifiers are bare numbers.
      // Numbering one onto the other's number collides.
      await plant('keep', const Offset(0, 0), number: 1);
      await plant('move', const Offset(50, 0), number: 2);

      final plan = await numbering.plan(
        vineIds: {'move'},
        startAt: 1,
        order: NumberingOrder.leftToRight,
      );
      final result = await numbering.apply(plan, projectId: projectId);

      expect(result, isA<NumberingRefused>());
      expect((result as NumberingRefused).collisions, ['1']);

      // Nothing changed -- asserting the database, not just the return value.
      final rows = await db.select(db.vines).get();
      expect(rows.firstWhere((v) => v.id == 'move').positionIdx, 2);
    });

    test('the same number on different rows is not a collision', () async {
      // Plant 7 of row 12 and plant 7 of row 13 are different identifiers, so
      // the check has to render full identifiers rather than compare numbers.
      final v = await vineyard();
      await drawn(
        id: 'r13',
        fieldDefId: v.row,
        label: '13',
        shape: PolylineShape(
          Polyline([const Offset(0, 80), const Offset(100, 80)]),
        ),
      );
      await plant('other', const Offset(50, 80), number: 99);
      await memberships.reconcile(projectId: projectId);
      await setTemplate(
        IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart(v.row), const PlantPart()],
        ),
      );

      final plan = await numbering.plan(
        vineIds: {'other'},
        startAt: 7,
        order: NumberingOrder.leftToRight,
      );
      expect(
        await numbering.apply(plan, projectId: projectId),
        isA<NumberingApplied>(),
      );
      expect((await labels.identifierOf('other'))!.text, '13.7');
      expect((await labels.identifierOf('v7'))!.text, '12.7');
    });
  });

  group('object labels', () {
    test('nextObjectLabel skips taken numbers and ignores words', () async {
      final rowField = await objectField(
        id: 'f_row',
        name: 'Row',
        drawType: DrawType.polyline,
      );
      await drawn(
        id: 'r1',
        fieldDefId: rowField,
        label: '1',
        shape: PolylineShape(
          Polyline([const Offset(0, 0), const Offset(1, 0)]),
        ),
      );
      await drawn(
        id: 'rn',
        fieldDefId: rowField,
        label: 'north',
        shape: PolylineShape(
          Polyline([const Offset(0, 9), const Offset(1, 9)]),
        ),
      );

      // "north" occupies no number, so it cannot collide with one.
      expect(await labels.nextObjectLabel(rowField), 2);
    });

    test('an object does not collide with itself when renamed', () async {
      final rowField = await objectField(
        id: 'f_row',
        name: 'Row',
        drawType: DrawType.polyline,
      );
      await drawn(
        id: 'r1',
        fieldDefId: rowField,
        label: '1',
        shape: PolylineShape(
          Polyline([const Offset(0, 0), const Offset(1, 0)]),
        ),
      );

      expect(
        await labels.isObjectLabelFree(fieldDefId: rowField, label: '1'),
        isFalse,
      );
      expect(
        await labels.isObjectLabelFree(
          fieldDefId: rowField,
          label: '1',
          ignoringObjectId: 'r1',
        ),
        isTrue,
      );
    });
  });
}
