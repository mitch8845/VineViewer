import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/change_log.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// Deleting a plant made by mistake: gone from everything, one change in the
/// log, and undoable while it is still in the undo history.
void main() {
  late AppDatabase db;
  late LayoutDao layout;
  late LabelService labels;
  late FieldEventsDao events;
  late OperationRecorder recorder;
  late String projectId;
  late String health;
  late List<String> plants;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    labels = LabelService(db);
    layout = LayoutDao(db, labels, MembershipService(db));
    events = FieldEventsDao(db);
    recorder = OperationRecorder(db);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    final fields = FieldDefsDao(db);
    final row =
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
    health =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Health',
                  type: FieldType.integer,
                ))
                as FieldDefSaved)
            .id;
    final carrier = await layout.createObject(
      projectId: projectId,
      fieldDefId: row,
      label: '1',
      geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(100, 0)])),
    );
    plants = await layout.placePlantsAlongCarrier(
      carrierId: carrier,
      offsets: const [0, 10, 20],
    );
    await events.record(plantId: plants[1], fieldDefId: health, value: '3');
  });

  tearDown(() => db.close());

  Future<void> delete(Set<String> ids) => recorder.run(
    projectId: projectId,
    kind: 'delete_plants',
    description: 'Delete a plant',
    body: () => layout.deletePlants(ids),
  );

  test(
    'a deleted plant is gone from the map, the IDs and the values',
    () async {
      await delete({plants[1]});

      expect(
        (await layout.plantsInProject(projectId)).map((p) => p.id),
        isNot(contains(plants[1])),
      );
      expect(
        (await labels.identifiersForProject(projectId)).keys,
        isNot(contains(plants[1])),
      );
      expect(await events.currentValue(plants[1], health), isNull);
      expect(
        await events.activityBetween(projectId, DateTime(2000), DateTime(2100)),
        isEmpty,
      );
    },
  );

  test('it is one change in the log, and undo brings it all back', () async {
    await delete({plants[1]});
    final log = await ChangeLog(db).entries(projectId);
    expect(log.first.kind, 'delete_plants');
    expect(log.first.plants, 1);

    await UndoService(db).undo(projectId);
    expect(
      (await layout.plantsInProject(projectId)).map((p) => p.id),
      contains(plants[1]),
    );
    expect(await events.currentValue(plants[1], health), '3');
    expect((await labels.identifierOf(plants[1]))?.text, '2');
  });

  test('its number is free for the next plant on that row', () async {
    await delete({plants[1]});
    final ids = await labels.identifiersForProject(projectId);
    expect(ids.values.map((i) => i.text).toSet(), {'1', '3'});
  });
}
