import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// The calendar reads the event log, so these are its whole data layer.
void main() {
  late AppDatabase db;
  late FieldEventsDao events;
  late String projectId;
  late String otherProject;
  late String health;
  late String spray;

  Future<void> plant(String id, String project) => db.customStatement(
    'INSERT INTO plants (id, project_id, position_idx, status, '
    'created_at, updated_at) VALUES (?, ?, 1, ?, 0, 0)',
    [id, project, 'active'],
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    events = FieldEventsDao(db);
    final projects = ProjectsDao(db);
    projectId = await projects.create(name: 'Five Sisters');
    otherProject = await projects.create(name: 'Elsewhere');
    final fields = FieldDefsDao(db);
    health =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Health',
                  type: FieldType.integer,
                ))
                as FieldDefSaved)
            .id;
    spray =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Sprayed',
                  type: FieldType.boolean,
                ))
                as FieldDefSaved)
            .id;
    await plant('a', projectId);
    await plant('b', projectId);
    await plant('x', otherProject);
  });

  tearDown(() => db.close());

  // Local times, as the calendar groups by the device's own days.
  final mon = DateTime(2026, 10, 12, 9);
  final monNight = DateTime(2026, 10, 12, 23, 30);
  final tue = DateTime(2026, 10, 13, 8);

  test('activity is counted per local day and field', () async {
    await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: '4',
      observedAt: mon,
    );
    await events.record(
      plantId: 'b',
      fieldDefId: health,
      value: '3',
      observedAt: monNight,
    );
    await events.record(
      plantId: 'a',
      fieldDefId: spray,
      value: '1',
      observedAt: tue,
    );

    final activity = await events.activityBetween(
      projectId,
      DateTime(2026, 10),
      DateTime(2026, 11),
    );
    final byKey = {
      for (final a in activity) '${a.day.day}/${a.fieldDefId}': a.count,
    };
    // 23:30 on Monday is still Monday, wherever the device is.
    expect(byKey, {'12/$health': 2, '13/$spray': 1});
  });

  test('another project\'s readings never show up', () async {
    await events.record(
      plantId: 'x',
      fieldDefId: health,
      value: '1',
      observedAt: mon,
    );
    final activity = await events.activityBetween(
      projectId,
      DateTime(2026, 10),
      DateTime(2026, 11),
    );
    expect(activity, isEmpty);
  });

  test('a day\'s events, and only that day\'s', () async {
    await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: '4',
      observedAt: mon,
    );
    await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: '5',
      observedAt: tue,
    );
    final day = await events.eventsBetween(
      projectId,
      DateTime(2026, 10, 12),
      DateTime(2026, 10, 13),
    );
    expect(day.map((e) => e.value), ['4']);
  });

  test('an undone reading drops off the calendar', () async {
    final id = await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: '4',
      observedAt: mon,
    );
    await events.softDelete(id);
    expect(
      await events.activityBetween(
        projectId,
        DateTime(2026, 10),
        DateTime(2026, 11),
      ),
      isEmpty,
    );
  });

  test('last recorded per field', () async {
    await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: '4',
      observedAt: mon,
    );
    await events.record(
      plantId: 'b',
      fieldDefId: health,
      value: '2',
      observedAt: tue,
    );
    final last = await events.lastObserved(projectId);
    expect(last[health], tue);
    expect(last.containsKey(spray), isFalse);
  });

  test('a plant\'s history is every field, newest first', () async {
    await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: '4',
      observedAt: mon,
    );
    await events.record(
      plantId: 'a',
      fieldDefId: spray,
      value: '1',
      observedAt: tue,
    );
    await events.record(
      plantId: 'a',
      fieldDefId: health,
      value: null,
      observedAt: tue,
    );
    await events.record(
      plantId: 'b',
      fieldDefId: health,
      value: '1',
      observedAt: tue,
    );

    final history = await events.historyForPlant('a');
    expect(history.map((e) => e.value), [null, '1', '4']);
  });
}
