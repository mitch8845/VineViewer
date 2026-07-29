import 'dart:ui' show Offset;

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Deriving which containers a plant falls inside.
///
/// This is what makes a container field's value impossible to disagree with the
/// map: nobody types it, geometry decides it. The tests below are written
/// against the raw database rather than a DAO, because the DAOs do not exist in
/// their v3 form yet and this layer does not need them.
void main() {
  late AppDatabase db;
  late MembershipService memberships;
  late String projectId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    memberships = MembershipService(db);
    projectId = 'p1';
    await db.customStatement(
      'INSERT INTO projects (id, name, image_offset_x, image_offset_y, '
      'image_scale_x, image_scale_y, image_rotation, created_at, updated_at) '
      "VALUES (?, 'Five Sisters', 0, 0, 1, 1, 0, 0, 0)",
      [projectId],
    );
  });

  tearDown(() async => db.close());

  Future<String> field({
    required String id,
    required String name,
    required DrawType drawType,
    bool container = true,
    double? tolerance,
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
            isContainer: Value(container),
            tolerance: Value(tolerance),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
    return id;
  }

  Future<String> object({
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

  Future<String> plant(String id, Offset at) async {
    await db
        .into(db.vines)
        .insert(
          VinesCompanion.insert(
            id: id,
            projectId: projectId,
            positionIdx: 1,
            x: Value(at.dx),
            y: Value(at.dy),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
    return id;
  }

  Future<Set<String>> objectsHolding(String vineId) async {
    final rows = await db
        .customSelect(
          'SELECT object_id FROM plant_memberships WHERE vine_id = ?',
          variables: [Variable<String>(vineId)],
        )
        .get();
    return {for (final r in rows) r.read<String>('object_id')};
  }

  Shape squareAt(double left, double top, double size) => PolygonShape([
    Offset(left, top),
    Offset(left + size, top),
    Offset(left + size, top + size),
    Offset(left, top + size),
  ]);

  group('polygons', () {
    test('a plant inside belongs, one outside does not', () async {
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await object(
        id: 'b1',
        fieldDefId: block,
        label: '1',
        shape: squareAt(0, 0, 100),
      );
      await plant('inside', const Offset(50, 50));
      await plant('outside', const Offset(500, 500));

      await memberships.reconcile(projectId: projectId);

      expect(await objectsHolding('inside'), {'b1'});
      expect(await objectsHolding('outside'), isEmpty);
    });

    test('a concave notch excludes the plants in the bite', () async {
      // Block 1's rock outcrop, which is why rows 11-18 are short.
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await object(
        id: 'b1',
        fieldDefId: block,
        label: '1',
        shape: PolygonShape([
          const Offset(0, 0),
          const Offset(100, 0),
          const Offset(100, 100),
          const Offset(0, 100),
          const Offset(0, 70),
          const Offset(60, 70),
          const Offset(60, 30),
          const Offset(0, 30),
        ]),
      );
      await plant('in_rock', const Offset(30, 50));
      await plant('in_block', const Offset(80, 50));

      await memberships.reconcile(projectId: projectId);

      expect(await objectsHolding('in_rock'), isEmpty);
      expect(await objectsHolding('in_block'), {'b1'});
    });
  });

  group('polylines', () {
    test('a plant on the line belongs, one well off it does not', () async {
      final row = await field(
        id: 'f_row',
        name: 'Row',
        drawType: DrawType.polyline,
      );
      await object(
        id: 'r1',
        fieldDefId: row,
        label: '12',
        shape: PolylineShape(
          Polyline([const Offset(0, 0), const Offset(100, 0)]),
        ),
      );
      await plant('on', const Offset(50, 2));
      await plant('off', const Offset(50, 40));

      await memberships.reconcile(projectId: projectId);

      expect(await objectsHolding('on'), {'r1'});
      expect(await objectsHolding('off'), isEmpty);
    });

    test('tolerance is per field', () async {
      final row = await field(
        id: 'f_row',
        name: 'Row',
        drawType: DrawType.polyline,
        tolerance: 30,
      );
      await object(
        id: 'r1',
        fieldDefId: row,
        label: '12',
        shape: PolylineShape(
          Polyline([const Offset(0, 0), const Offset(100, 0)]),
        ),
      );
      // 20px away: outside the 8px default, inside this field's 30.
      await plant('near', const Offset(50, 20));

      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('near'), {'r1'});
    });
  });

  group('what does not produce memberships', () {
    test('a non-container object touches nothing', () async {
      // A road crossing the vineyard must not put a field on a single plant.
      final road = await field(
        id: 'f_road',
        name: 'Road',
        drawType: DrawType.polyline,
        container: false,
      );
      await object(
        id: 'road1',
        fieldDefId: road,
        label: 'main',
        shape: PolylineShape(
          Polyline([const Offset(0, 0), const Offset(100, 0)]),
        ),
      );
      await plant('beside', const Offset(50, 1));

      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('beside'), isEmpty);
    });

    test('a point object contains nothing', () async {
      final post = await field(
        id: 'f_post',
        name: 'Post',
        drawType: DrawType.point,
      );
      await object(
        id: 'post1',
        fieldDefId: post,
        label: 'NW',
        shape: const PointShape(Offset(50, 50)),
      );
      await plant('right_there', const Offset(50, 50));

      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('right_there'), isEmpty);
    });

    test('an object with no geometry yet holds nothing', () async {
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await db
          .into(db.mapObjects)
          .insert(
            MapObjectsCompanion.insert(
              id: 'b1',
              projectId: projectId,
              fieldDefId: block,
              label: '1',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          );
      await plant('somewhere', const Offset(50, 50));

      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('somewhere'), isEmpty);
    });
  });

  test('a plant can be in two containers of different fields at once', () async {
    // Q1's answer in practice: membership is many. The carrier -- the one line
    // the plant slides along -- is a different relationship entirely.
    final block = await field(
      id: 'f_block',
      name: 'Block',
      drawType: DrawType.polygon,
    );
    final row = await field(
      id: 'f_row',
      name: 'Row',
      drawType: DrawType.polyline,
    );
    final terrace = await field(
      id: 'f_terrace',
      name: 'Terrace',
      drawType: DrawType.polyline,
    );

    await object(
      id: 'b1',
      fieldDefId: block,
      label: '1',
      shape: squareAt(0, 0, 100),
    );
    await object(
      id: 'r12',
      fieldDefId: row,
      label: '12',
      shape: PolylineShape(
        Polyline([const Offset(0, 50), const Offset(100, 50)]),
      ),
    );
    await object(
      id: 't3',
      fieldDefId: terrace,
      label: '3',
      shape: PolylineShape(
        Polyline([const Offset(50, 0), const Offset(50, 100)]),
      ),
    );

    await plant('crossing', const Offset(50, 50));
    await memberships.reconcile(projectId: projectId);

    expect(await objectsHolding('crossing'), {'b1', 'r12', 't3'});
  });

  group('reconcile writes only differences', () {
    test('running twice changes nothing the second time', () async {
      // An unchanged membership must produce no journal row, or dragging one
      // plant would bury the operation under thousands of no-op captures.
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await object(
        id: 'b1',
        fieldDefId: block,
        label: '1',
        shape: squareAt(0, 0, 100),
      );
      for (var i = 0; i < 20; i++) {
        await plant('v$i', Offset(10.0 + i, 50));
      }

      expect(await memberships.reconcile(projectId: projectId), 20);
      expect(await memberships.reconcile(projectId: projectId), 0);
    });

    test('reshaping a boundary sweeps plants in and out', () async {
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await object(
        id: 'b1',
        fieldDefId: block,
        label: '1',
        shape: squareAt(0, 0, 100),
      );
      await plant('stays', const Offset(50, 50));
      await plant('joins', const Offset(150, 50));

      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('joins'), isEmpty);

      // Widen the block to take in the second plant.
      await db.customStatement(
        'UPDATE map_objects SET geometry = ? WHERE id = ?',
        [squareAt(0, 0, 200).toJson(), 'b1'],
      );
      await memberships.reconcile(projectId: projectId);

      expect(await objectsHolding('stays'), {'b1'});
      expect(await objectsHolding('joins'), {'b1'});
    });

    test('deleting the last container clears what it created', () async {
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await object(
        id: 'b1',
        fieldDefId: block,
        label: '1',
        shape: squareAt(0, 0, 100),
      );
      await plant('inside', const Offset(50, 50));
      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('inside'), {'b1'});

      await db.customStatement(
        'UPDATE map_objects SET deleted_at = 1 WHERE id = ?',
        ['b1'],
      );
      await memberships.reconcile(projectId: projectId);
      expect(await objectsHolding('inside'), isEmpty);
    });

    test('a scoped reconcile leaves other plants alone', () async {
      final block = await field(
        id: 'f_block',
        name: 'Block',
        drawType: DrawType.polygon,
      );
      await object(
        id: 'b1',
        fieldDefId: block,
        label: '1',
        shape: squareAt(0, 0, 100),
      );
      await plant('a', const Offset(50, 50));
      await plant('b', const Offset(60, 60));
      await memberships.reconcile(projectId: projectId);

      // Move a out, then reconcile only b. a's stale membership must survive:
      // a narrow reconcile that deleted rows it never recomputed would be worse
      // than one that is merely incomplete.
      await db.customStatement("UPDATE vines SET x = 500 WHERE id = 'a'");
      await memberships.reconcile(projectId: projectId, vineIds: {'b'});

      expect(await objectsHolding('a'), {'b1'});
      expect(await objectsHolding('b'), {'b1'});
    });
  });
}
