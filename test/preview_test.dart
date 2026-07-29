import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// Asking what an edit *would* do, before doing it.
///
/// Four different gestures rename plants, and three of them used to do it in
/// silence: renaming a drawn object, dragging a boundary so plants fall inside a
/// different one, and changing an attribute that is part of the identifier. The
/// prompts that fix that all rest on the previews here.
///
/// **The property every test in this file is really defending is that a preview
/// writes nothing.** The obvious implementation -- reconcile inside a
/// transaction and roll back -- looks equivalent and is not: the capture
/// triggers fire inside the transaction, so a preview the user then cancelled
/// would sit in the undo journal as an operation that happened, and in label
/// history as a rename that never did.
void main() {
  late AppDatabase db;
  late LabelService labels;
  late MembershipService memberships;
  late LayoutDao layout;
  late String projectId;

  /// Row (a container line) and Block (a container polygon).
  late String rowField;
  late String blockField;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    memberships = MembershipService(db);
    layout = LayoutDao(db, labels, memberships);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');

    final fields = FieldDefsDao(db);
    rowField =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Row',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polyline,
                  isContainer: true,
                ))
                as FieldDefSaved)
            .id;
    blockField =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Block',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polygon,
                  isContainer: true,
                ))
                as FieldDefSaved)
            .id;
  });

  tearDown(() async => db.close());

  /// `block.row.plant`, the layout this project's identifiers use.
  Future<void> useTemplate() => ProjectsDao(db).setIdentifierTemplate(
    projectId,
    IdentifierTemplate(
      delimiter: '.',
      parts: [FieldPart(blockField), FieldPart(rowField), const PlantPart()],
    ),
  );

  Future<String> block(String label, List<Offset> vertices) =>
      layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: label,
        geometry: PolygonShape(vertices),
      );

  Future<String> row(String label, List<Offset> points) => layout.createObject(
    projectId: projectId,
    fieldDefId: rowField,
    label: label,
    geometry: PolylineShape(Polyline(points)),
  );

  /// A 100x100 block at the origin, with a row of three plants inside it.
  Future<({String block, String row, List<String> plants})> oneBlock() async {
    final blockId = await block('1', [
      const Offset(0, 0),
      const Offset(100, 0),
      const Offset(100, 100),
      const Offset(0, 100),
    ]);
    final rowId = await row('12', [const Offset(10, 50), const Offset(90, 50)]);
    final plants = await layout.placePlantsAlongCarrier(
      carrierId: rowId,
      offsets: [0, 40, 80],
    );
    return (block: blockId, row: rowId, plants: plants);
  }

  Future<int> journalRowCount() async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS n FROM operation_rows')
        .getSingle();
    return row.read<int>('n');
  }

  Future<int> membershipCount() async =>
      (await db.select(db.plantMemberships).get()).length;

  group('renaming an object', () {
    test('counts every plant it holds', () async {
      await useTemplate();
      final scene = await oneBlock();

      final change = await labels.previewObjectRename(
        objectId: scene.block,
        label: '4',
      );
      expect(change.changed, 3);
      expect(change.isSafe, isTrue);
    });

    test('counts nothing when the field is not part of the ID', () async {
      // No template set, so identifiers are bare plant numbers. Renaming the
      // block a plant sits in genuinely renames nothing, and a dialog saying so
      // would be a dialog nobody needed.
      final scene = await oneBlock();

      final change = await labels.previewObjectRename(
        objectId: scene.block,
        label: '4',
      );
      expect(change.changed, 0);
    });

    test('is refused when it would collide with another object', () async {
      await useTemplate();
      // Two rows in one block, each with a plant 1. Renaming row 13 to 12 makes
      // both plants `1.12.1`.
      final blockId = await block('1', [
        const Offset(0, 0),
        const Offset(200, 0),
        const Offset(200, 200),
        const Offset(0, 200),
      ]);
      expect(blockId, isNotEmpty);
      final a = await row('12', [const Offset(10, 50), const Offset(190, 50)]);
      final b = await row('13', [
        const Offset(10, 150),
        const Offset(190, 150),
      ]);
      await layout.placePlantsAlongCarrier(carrierId: a, offsets: [0]);
      await layout.placePlantsAlongCarrier(carrierId: b, offsets: [0]);

      final change = await labels.previewObjectRename(objectId: b, label: '12');
      expect(change.isSafe, isFalse);
      expect(change.duplicates, ['1.12.1']);
    });

    test('writes nothing', () async {
      await useTemplate();
      final scene = await oneBlock();
      final before = await journalRowCount();

      await labels.previewObjectRename(objectId: scene.block, label: '4');

      expect(await journalRowCount(), before);
      expect(
        (await layout.objectById(scene.block))!.label,
        '1',
        reason: 'the preview must not have applied the rename',
      );
    });

    test('the rename itself renames, and history remembers both', () async {
      await useTemplate();
      final scene = await oneBlock();
      final plant = scene.plants.first;
      expect((await labels.identifierOf(plant))!.text, '1.12.1');

      await OperationRecorder(db).run(
        projectId: projectId,
        kind: 'rename_object',
        description: 'Rename Block 1 to 4',
        body: () => layout.renameObject(scene.block, '4'),
      );

      expect((await labels.identifierOf(plant))!.text, '4.12.1');

      // The point of journaling map_objects: not one plant row changed, yet
      // every plant in the block is called something else.
      final history = await labels.historyOf(plant);
      expect(history.map((h) => h.identifier.text), ['1.12.1', '4.12.1']);
    });
  });

  group('reshaping a boundary', () {
    test('counts the plants a shrinking block would drop', () async {
      await useTemplate();
      final scene = await oneBlock();

      // Pull the block's right edge in so only the first plant is left inside.
      final shrunk = PolygonShape([
        const Offset(0, 0),
        const Offset(20, 0),
        const Offset(20, 100),
        const Offset(0, 100),
      ]);
      final change = await layout.previewGeometryChange(
        objectId: scene.block,
        geometry: shrunk,
      );

      // Plants 2 and 3 leave the block, so their block part becomes the
      // placeholder. Plant 1 at x=10 stays.
      expect(change.changed, 2);
    });

    test('counts what deleting it would do', () async {
      await useTemplate();
      final scene = await oneBlock();

      final change = await layout.previewGeometryChange(objectId: scene.block);
      expect(change.changed, 3);
    });

    test('is refused when two plants would end up sharing an ID', () async {
      await useTemplate();
      // One block covering the near end of a long row. The near plant is inside
      // it, the far plant is outside every block and so renders the block
      // placeholder. Renumber the far one to 1 and the two are distinguished
      // *only* by the block part -- so shrinking the block off the near plant
      // makes both of them `0.12.1`.
      //
      // Built to leave a block rather than to enter another one, deliberately:
      // two blocks over one plant is prevented earlier by the same-field overlap
      // rule, so a collision constructed that way could never reach this gate.
      final blockA = await block('1', [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100),
        const Offset(0, 100),
      ]);
      final rowA = await row('12', [
        const Offset(10, 50),
        const Offset(290, 50),
      ]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowA,
        offsets: [0, 240],
      );
      expect((await labels.identifierOf(plants.first))!.text, '1.12.1');
      expect((await labels.identifierOf(plants.last))!.text, '0.12.2');

      await db.customStatement(
        'UPDATE plants SET position_idx = 1 WHERE id = ?',
        [plants.last],
      );
      expect((await labels.identifierOf(plants.last))!.text, '0.12.1');

      final change = await layout.previewGeometryChange(
        objectId: blockA,
        geometry: PolygonShape([
          const Offset(0, 0),
          const Offset(5, 0),
          const Offset(5, 5),
          const Offset(0, 5),
        ]),
      );
      expect(change.isSafe, isFalse);
      expect(change.duplicates, contains('0.12.1'));
    });

    test('accounts for the plants a moved line carries with it', () async {
      await useTemplate();
      // A row inside the block, moved bodily outside it. The block never moves,
      // yet every plant leaves it -- the second, independent way containment
      // changes, and the one a geometry-only preview would miss.
      final scene = await oneBlock();
      final path = await layout.carrierPathOf(scene.row);

      final moved = PolylineShape(
        Polyline([for (final p in path!.points) p + const Offset(0, 500)]),
      );
      final change = await layout.previewGeometryChange(
        objectId: scene.row,
        geometry: moved,
      );

      // All three lose their block part *and* their row part is unchanged, so
      // all three read differently.
      expect(change.changed, 3);
    });

    test('writes nothing -- not a membership row, not a journal row', () async {
      await useTemplate();
      final scene = await oneBlock();
      final journalBefore = await journalRowCount();
      final membershipsBefore = await membershipCount();

      await layout.previewGeometryChange(
        objectId: scene.block,
        geometry: PolygonShape([
          const Offset(0, 0),
          const Offset(5, 0),
          const Offset(5, 5),
          const Offset(0, 5),
        ]),
      );

      expect(await journalRowCount(), journalBefore);
      expect(await membershipCount(), membershipsBefore);
    });

    test('the preview matches what actually happens', () async {
      // The test that keeps the prompt honest. A count that does not match the
      // outcome is worse than no count: it teaches the user to ignore it.
      await useTemplate();
      final scene = await oneBlock();

      final shrunk = PolygonShape([
        const Offset(0, 0),
        const Offset(20, 0),
        const Offset(20, 100),
        const Offset(0, 100),
      ]);
      final predicted = await layout.previewGeometryChange(
        objectId: scene.block,
        geometry: shrunk,
      );

      final before = {
        for (final id in scene.plants)
          id: (await labels.identifierOf(id))!.text,
      };
      await OperationRecorder(db).run(
        projectId: projectId,
        kind: 'reshape_object',
        description: 'Reshape Block 1',
        body: () => layout.updateObjectGeometry(scene.block, shrunk),
      );

      var actual = 0;
      for (final entry in before.entries) {
        if ((await labels.identifierOf(entry.key))!.text != entry.value) {
          actual++;
        }
      }
      expect(actual, predicted.changed);
    });
  });

  group('moving one plant', () {
    test(
      'previews from where the plant would land, not the drop point',
      () async {
        await useTemplate();
        // A carried plant slides to the nearest point on its line, so a drop far
        // off the line must be previewed at the projection. Previewing the raw
        // point would answer a question about a place the plant never goes.
        final blockId = await block('1', [
          const Offset(0, 0),
          const Offset(100, 0),
          const Offset(100, 100),
          const Offset(0, 100),
        ]);
        expect(blockId, isNotEmpty);
        final rowId = await row('12', [
          const Offset(10, 50),
          const Offset(90, 50),
        ]);
        final plants = await layout.placePlantsAlongCarrier(
          carrierId: rowId,
          offsets: [0],
        );

        // Dropped 400px below the line, but it snaps back onto it and stays in
        // the block, so nothing is renamed.
        final change = await layout.previewPlantMove(
          plantId: plants.single,
          position: const Offset(50, 450),
        );
        expect(change.changed, 0);
      },
    );

    test('a free plant is previewed exactly where it is dropped', () async {
      await useTemplate();
      final blockId = await block('1', [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100),
        const Offset(0, 100),
      ]);
      expect(blockId, isNotEmpty);
      final plant = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 50),
      );
      expect((await labels.identifierOf(plant))!.text, '1.0.1');

      final change = await layout.previewPlantMove(
        plantId: plant,
        position: const Offset(500, 500),
      );
      expect(change.changed, 1);
    });

    test('writes nothing and leaves the plant where it was', () async {
      await useTemplate();
      final scene = await oneBlock();
      final journalBefore = await journalRowCount();
      final before = await layout.plantById(scene.plants.first);

      await layout.previewPlantMove(
        plantId: scene.plants.first,
        position: const Offset(900, 900),
      );

      final after = await layout.plantById(scene.plants.first);
      expect(after!.x, before!.x);
      expect(after.y, before.y);
      expect(await journalRowCount(), journalBefore);
    });
  });

  group('changing an identifier-part attribute', () {
    late String cloneField;

    setUp(() async {
      cloneField =
          ((await FieldDefsDao(db).create(
                    projectId: projectId,
                    name: 'Clone',
                    type: FieldType.text,
                    blankPlaceholder: 'none',
                  ))
                  as FieldDefSaved)
              .id;
      await ProjectsDao(db).setIdentifierTemplate(
        projectId,
        IdentifierTemplate(
          delimiter: '.',
          parts: [FieldPart(cloneField), const PlantPart()],
        ),
      );
    });

    test('a field outside the template is a cheap no', () async {
      final scene = await oneBlock();
      final change = await labels.previewAttributeChange(
        projectId: projectId,
        fieldDefId: rowField,
        plantIds: scene.plants,
        value: 'anything',
      );
      expect(change.changed, 0);
    });

    test('counts the plants a bulk edit would rename', () async {
      final scene = await oneBlock();
      final change = await labels.previewAttributeChange(
        projectId: projectId,
        fieldDefId: cloneField,
        plantIds: scene.plants,
        value: '76',
      );
      // Every plant goes from `none.n` to `76.n`.
      expect(change.changed, 3);
      expect(change.isSafe, isTrue);
    });

    test(
      'clearing falls back to the placeholder, which is also a rename',
      () async {
        final scene = await oneBlock();
        final plant = scene.plants.first;

        await OperationRecorder(db).run(
          projectId: projectId,
          kind: 'set_value',
          description: 'Set Clone',
          body: () => db.customStatement(
            'INSERT INTO field_events (id, plant_id, field_def_id, value, '
            'observed_at, recorded_at, source) '
            "VALUES ('e1', ?, ?, '76', 0, 0, 'manual')",
            [plant, cloneField],
          ),
        );
        expect((await labels.identifierOf(plant))!.text, '76.1');

        final change = await labels.previewAttributeChange(
          projectId: projectId,
          fieldDefId: cloneField,
          plantIds: [plant],
          value: null,
        );
        expect(
          change.changed,
          1,
          reason: 'it becomes none.1, not an empty part',
        );
      },
    );

    test('is refused when it would collide', () async {
      // Two plants distinguished only by their clone. Giving them the same one
      // makes them the same address.
      final a = await layout.createPlant(
        projectId: projectId,
        position: const Offset(10, 10),
      );
      final b = await layout.createPlant(
        projectId: projectId,
        position: const Offset(20, 20),
      );
      await db.customStatement(
        'UPDATE plants SET position_idx = 1 WHERE id IN (?, ?)',
        [a, b],
      );
      await db.customStatement(
        'INSERT INTO field_events (id, plant_id, field_def_id, value, '
        'observed_at, recorded_at, source) '
        "VALUES ('e1', ?, ?, '76', 0, 0, 'manual')",
        [a, cloneField],
      );
      expect((await labels.identifierOf(a))!.text, '76.1');
      expect((await labels.identifierOf(b))!.text, 'none.1');

      final change = await labels.previewAttributeChange(
        projectId: projectId,
        fieldDefId: cloneField,
        plantIds: [b],
        value: '76',
      );
      expect(change.isSafe, isFalse);
      expect(change.duplicates, ['76.1']);
    });

    test('isIdentifierPart answers before anything expensive runs', () async {
      expect(
        await labels.isIdentifierPart(
          projectId: projectId,
          fieldDefId: cloneField,
        ),
        isTrue,
      );
      expect(
        await labels.isIdentifierPart(
          projectId: projectId,
          fieldDefId: rowField,
        ),
        isFalse,
      );
    });
  });

  group('previewContainerValues', () {
    test('reports what geometry says, keyed by field', () async {
      final scene = await oneBlock();

      final values = await memberships.previewContainerValues(
        projectId: projectId,
      );
      expect(values[scene.plants.first]![blockField], '1');
      expect(values[scene.plants.first]![rowField], '12');
    });

    test('an override to null takes the object out of consideration', () async {
      final scene = await oneBlock();

      final values = await memberships.previewContainerValues(
        projectId: projectId,
        geometryOverride: {scene.block: null},
      );
      expect(values[scene.plants.first]!.containsKey(blockField), isFalse);
      expect(
        values[scene.plants.first]![rowField],
        '12',
        reason: 'only the overridden object should be affected',
      );
    });

    test('a position override moves the plant, not the boundary', () async {
      final scene = await oneBlock();

      final values = await memberships.previewContainerValues(
        projectId: projectId,
        positionOverride: {scene.plants.first: const Offset(900, 900)},
      );
      expect(values[scene.plants.first] ?? const {}, isEmpty);
      expect(
        values[scene.plants.last]![blockField],
        '1',
        reason: 'the other plants did not move',
      );
    });
  });

  group('plantedOffsetsOn', () {
    test('reports occupied offsets in order', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(300, 0)]);
      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [100, 0, 50],
      );

      expect(await layout.plantedOffsetsOn(rowId), [0, 50, 100]);
    });

    test('an unplanted line reports nothing', () async {
      final rowId = await row('13', [const Offset(0, 0), const Offset(300, 0)]);
      expect(await layout.plantedOffsetsOn(rowId), isEmpty);
    });
  });

  group('carriedPositionsFor', () {
    test('reports where plants would land, without moving them', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(100, 0)]);
      final plants = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 50, 100],
      );

      // The same line, shifted down 30. Offsets are unchanged by a translation.
      final positions = await layout.carriedPositionsFor(
        rowId,
        Polyline([const Offset(0, 30), const Offset(100, 30)]),
      );
      expect(positions[plants[1]], const Offset(50, 30));

      final stored = await layout.plantById(plants[1]);
      expect(stored!.y, 0, reason: 'a preview must not move anything');
    });
  });

  group('nothing breaks without a template', () {
    test(
      'every preview is a safe no-op on a project with no objects',
      () async {
        final plant = await layout.createPlant(
          projectId: projectId,
          position: const Offset(1, 1),
        );

        expect(
          (await layout.previewPlantMove(
            plantId: plant,
            position: const Offset(9, 9),
          )).changed,
          0,
        );
        expect(
          (await labels.previewAttributeChange(
            projectId: projectId,
            fieldDefId: rowField,
            plantIds: [plant],
            value: 'x',
          )).changed,
          0,
        );
      },
    );

    test('previewing an object that no longer exists is harmless', () async {
      expect(
        (await labels.previewObjectRename(
          objectId: 'gone',
          label: 'x',
        )).changed,
        0,
      );
      expect((await layout.previewGeometryChange(objectId: 'gone')).changed, 0);
    });
  });

  group('plant more along an existing line', () {
    // Plan verification #10: plant one stretch, then another on the same
    // carrier, and the numbers come out contiguous with a gap in space.
    test('keeps numbering contiguous across two passes', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(300, 0)]);

      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [for (var i = 0; i <= 14; i++) i * 10.0],
      );
      // The far side of the rock: 200 to 300, skipping 150 to 200 entirely.
      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [for (var i = 0; i <= 9; i++) 200 + i * 10.0],
      );

      final rows =
          await (db.select(db.plants)
                ..where((v) => v.carrierId.equals(rowId))
                ..orderBy([(v) => OrderingTerm.asc(v.positionIdx)]))
              .get();

      expect(
        [for (final r in rows) r.positionIdx],
        [for (var i = 1; i <= 25; i++) i],
        reason: 'contiguous numbers, not a gap mirroring the gap in space',
      );
      // And the gap really is in space: nothing between 140 and 200.
      final offsets = await layout.plantedOffsetsOn(rowId);
      expect(offsets.where((o) => o > 140 && o < 200), isEmpty);
    });

    test('the second pass leaves the first pass numbered as it was', () async {
      final rowId = await row('12', [const Offset(0, 0), const Offset(300, 0)]);
      final first = await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [0, 10, 20],
      );
      final before = {
        for (final id in first) id: (await layout.plantById(id))!.positionIdx,
      };

      await layout.placePlantsAlongCarrier(
        carrierId: rowId,
        offsets: [200, 210],
      );

      for (final entry in before.entries) {
        expect((await layout.plantById(entry.key))!.positionIdx, entry.value);
      }
    });
  });
}
