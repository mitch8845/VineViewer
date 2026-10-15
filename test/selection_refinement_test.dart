import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';
import 'package:vine_viewer/features/canvas/vineyard_painter.dart';

DrawnObject drawn(String id, Shape shape) =>
    (id: id, fieldDefId: 'f_$id', label: id, shape: shape, isContainer: true);

/// Selecting a whole row is a tap on its line, or a tap on one of its plants
/// and then its chip -- and neither used to be reliable inside a block.
void main() {
  group('what a tap on the map means', () {
    final block = drawn(
      'block',
      PolygonShape(const [
        Offset(0, 0),
        Offset(200, 0),
        Offset(200, 200),
        Offset(0, 200),
      ]),
    );
    final innerBlock = drawn(
      'inner',
      PolygonShape(const [
        Offset(50, 50),
        Offset(150, 50),
        Offset(150, 150),
        Offset(50, 150),
      ]),
    );
    final row12 = drawn(
      'row12',
      PolylineShape(Polyline(const [Offset(10, 100), Offset(190, 100)])),
    );
    final row13 = drawn(
      'row13',
      PolylineShape(Polyline(const [Offset(10, 110), Offset(190, 110)])),
    );
    final post = drawn('post', const PointShape(Offset(100, 104)));

    test('a row inside a block wins over the block, whatever the order', () {
      // The block is first in the list -- the order that used to win.
      final hit = objectAtPoint(const Offset(30, 102), 8, [block, row12]);
      expect(hit?.id, 'row12');
    });

    test('of two nearby rows, the nearer one', () {
      final hit = objectAtPoint(const Offset(30, 107), 8, [row12, row13]);
      expect(hit?.id, 'row13');
    });

    test('away from any line, the smallest area containing the tap', () {
      final hit = objectAtPoint(const Offset(60, 60), 8, [block, innerBlock]);
      expect(hit?.id, 'inner');
      final outer = objectAtPoint(const Offset(20, 20), 8, [block, innerBlock]);
      expect(outer?.id, 'block');
    });

    test('a point beats the line it sits on', () {
      final hit = objectAtPoint(const Offset(100, 102), 8, [row12, post]);
      expect(hit?.id, 'post');
    });

    test('nothing near and nothing around is nothing', () {
      expect(objectAtPoint(const Offset(500, 500), 8, [block, row12]), isNull);
    });
  });

  test('a plant knows the row and block it belongs to, by id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final labels = LabelService(db);
    final layout = LayoutDao(db, labels, MembershipService(db));
    final fields = FieldDefsDao(db);
    final projectId = await ProjectsDao(db).create(name: 'Five Sisters');

    Future<String> field(String name, DrawType draw) async =>
        ((await fields.create(
                  projectId: projectId,
                  name: name,
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: draw,
                  isContainer: true,
                ))
                as FieldDefSaved)
            .id;
    final rowField = await field('Row', DrawType.polyline);
    final blockField = await field('Block', DrawType.polygon);

    final blockId = await layout.createObject(
      projectId: projectId,
      fieldDefId: blockField,
      label: '3',
      geometry: PolygonShape(const [
        Offset(0, 0),
        Offset(200, 0),
        Offset(200, 200),
        Offset(0, 200),
      ]),
    );
    final rowId = await layout.createObject(
      projectId: projectId,
      fieldDefId: rowField,
      label: '12',
      geometry: PolylineShape(
        Polyline(const [Offset(10, 100), Offset(190, 100)]),
      ),
    );
    final plant = (await layout.placePlantsAlongCarrier(
      carrierId: rowId,
      offsets: const [20],
    )).single;

    final holders = await labels.holdersOf(plant);
    expect(
      {for (final h in holders) '${h.field} ${h.label}': h.objectId},
      {'Row 12': rowId, 'Block 3': blockId},
    );
  });
}
