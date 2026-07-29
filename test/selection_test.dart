import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/daos/plants_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Flattening a mixed selection into the plants it covers.
///
/// Every bulk write funnels through this, which is why field events attach to
/// plants and never to objects: a selection of three plants from one row plus
/// all of another has no single entity to attach an event to.
void main() {
  late AppDatabase db;

  late LayoutDao layout;

  late PlantsDao plants;

  late String projectId;

  late String rowField;

  late String blockField;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    layout = LayoutDao(db, LabelService(db), MembershipService(db));
    plants = PlantsDao(db);

    final fields = FieldDefsDao(db);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
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

  Future<String> lineAt(String label, double y) => layout.createObject(
    projectId: projectId,
    fieldDefId: rowField,
    label: label,
    geometry: PolylineShape(Polyline([Offset(0, y), Offset(400, y)])),
  );

  Future<String> blockCovering(String label, double size) =>
      layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: label,
        geometry: PolygonShape([
          const Offset(-10, -10),
          Offset(size, -10),
          Offset(size, size),
          Offset(-10, size),
        ]),
      );

  test('an empty selection resolves to nothing', () async {
    expect(await plants.resolveSelection(), isEmpty);
  });

  test('individual plants resolve to themselves', () async {
    final row = await lineAt('12', 0);

    final ids = await layout.placePlantsAlongCarrier(
      carrierId: row,
      offsets: [0, 100, 200],
    );
    expect(await plants.resolveSelection(plantIds: [ids.first, ids.last]), {
      ids.first,
      ids.last,
    });
  });

  test('selecting a line resolves to the plants it carries', () async {
    final row = await lineAt('12', 0);

    final ids = await layout.placePlantsAlongCarrier(
      carrierId: row,
      offsets: [0, 100, 200],
    );
    await lineAt('13', 300);
    expect(await plants.resolveSelection(objectIds: [row]), ids.toSet());
  });

  test('selecting a block resolves through membership', () async {
    // The plant is inside the polygon but carried by nothing, so only the
    // membership half of the union can find it.
    final block = await blockCovering('1', 200);

    final loose = await layout.createPlant(
      projectId: projectId,
      position: const Offset(50, 50),
    );
    expect(await plants.resolveSelection(objectIds: [block]), {loose});
  });

  test('a carried plant with no membership is still found', () async {
    // A plant snapped to a *non-container* line has no membership row at all.
    // An object selection that only consulted memberships would silently drop
    // it -- leaving plants visibly on the line that no bulk edit could touch.
    final fields = FieldDefsDao(db);

    final fence =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Fence',
                  type: FieldType.text,
                  role: FieldRole.object,
                  drawType: DrawType.polyline,
                ))
                as FieldDefSaved)
            .id;

    final line = await layout.createObject(
      projectId: projectId,
      fieldDefId: fence,
      label: 'north',
      geometry: PolylineShape(
        Polyline([const Offset(0, 500), const Offset(400, 500)]),
      ),
    );

    final ids = await layout.placePlantsAlongCarrier(
      carrierId: line,
      offsets: [0, 50],
    );
    expect(await db.select(db.plantMemberships).get(), isEmpty);
    expect(await plants.resolveSelection(objectIds: [line]), ids.toSet());
  });

  test('mixing plants and objects unions them', () async {
    final row = await lineAt('12', 0);

    final onRow = await layout.placePlantsAlongCarrier(
      carrierId: row,
      offsets: [0, 100],
    );

    final loose = await layout.createPlant(
      projectId: projectId,
      position: const Offset(900, 900),
    );
    expect(await plants.resolveSelection(plantIds: [loose], objectIds: [row]), {
      ...onRow,
      loose,
    });
  });

  test('the same plant selected twice appears once', () async {
    final row = await lineAt('12', 0);

    final ids = await layout.placePlantsAlongCarrier(
      carrierId: row,
      offsets: [0],
    );
    expect(
      await plants.resolveSelection(plantIds: ids, objectIds: [row]),
      hasLength(1),
    );
  });

  group('inactive plants', () {
    test('are excluded by default', () async {
      // Spraying a plant that is not there records an observation that never
      // happened.
      final row = await lineAt('12', 0);

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: row,
        offsets: [0, 100],
      );
      await layout.retirePlant(ids.first, change: PlantStatusChange.removed);
      expect(await plants.resolveSelection(objectIds: [row]), {ids.last});
    });

    test('are included when asked for', () async {
      final row = await lineAt('12', 0);

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: row,
        offsets: [0, 100],
      );
      await layout.retirePlant(ids.first, change: PlantStatusChange.removed);
      expect(
        await plants.resolveSelection(objectIds: [row], includeInactive: true),
        ids.toSet(),
      );
    });
  });

  test('plantsOnCarrier returns planting order', () async {
    final row = await lineAt('12', 0);
    await layout.placePlantsAlongCarrier(
      carrierId: row,
      offsets: [200, 0, 100],
    );

    final ordered = await plants.plantsOnCarrier(row);
    expect([for (final v in ordered) v.positionIdx], [1, 2, 3]);
    expect([for (final v in ordered) v.x], [0, 100, 200]);
  });
}
