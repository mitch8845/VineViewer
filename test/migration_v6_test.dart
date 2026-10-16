import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/seed_service.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/data/walk_plan.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/daos/walk_orders_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// v5 -> v6 adds the walk-order table. Every tablet is on v5 holding the real
/// Five Sisters, so this upgrades exactly that: the bundled seed, loaded and
/// then wound back to what 0.10.0 to 0.12.0 have on disk.
void main() {
  late Directory dir;
  late File file;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vv_v6_');
    file = File('${dir.path}/app.sqlite');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const tables = [
    'projects',
    'field_defs',
    'map_objects',
    'plants',
    'plant_memberships',
    'field_events',
    'operations',
    'operation_rows',
    'undo_context',
  ];

  Map<String, List<String>> dump(Database raw) => {
    for (final t in tables)
      t: [
        for (final row in raw.select('SELECT * FROM $t ORDER BY 1'))
          row.values.join('|'),
      ],
  };

  test('upgrading Five Sisters from v5 keeps every row', () async {
    var db = AppDatabase(NativeDatabase(file));
    final projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    await OperationRecorder(db).run(
      projectId: projectId,
      kind: 'load_seed',
      description: 'Start from the Five Sisters seed',
      body: () => SeedService(db).load(
        projectId,
        ProjectSeed.decode(
          File('assets/seeds/five_sisters.json.gz').readAsBytesSync(),
          schemaVersion: db.schemaVersion,
        ),
      ),
    );
    final idsBefore = {
      for (final e in (await LabelService(
        db,
      ).identifiersForProject(projectId)).entries)
        e.key: e.value.text,
    };
    await db.close();

    var raw = sqlite3.open(file.path);
    raw.execute('DROP TABLE walk_orders');
    raw.execute('PRAGMA user_version = 5');
    final before = dump(raw);
    raw.close();

    db = AppDatabase(NativeDatabase(file));
    final idsAfter = {
      for (final e in (await LabelService(
        db,
      ).identifiersForProject(projectId)).entries)
        e.key: e.value.text,
    };

    // The new table works on the upgraded file.
    final dao = WalkOrdersDao(db);
    final orderId = await dao.create(
      projectId: projectId,
      name: 'Terrace walk',
      plan: WalkPlan(order: idsAfter.keys.toList()),
    );
    expect((await dao.load(orderId))!.plan.order, hasLength(3025));
    await dao.delete(orderId);

    // And the journal still undoes across it.
    final available = await UndoService(db).availability(projectId);
    expect(available.undo?.description, 'Start from the Five Sisters seed');
    await db.close();

    raw = sqlite3.open(file.path);
    final after = dump(raw);
    final version = raw.select('PRAGMA user_version').first.values.first;
    raw.close();

    expect(version, 6);
    for (final t in tables) {
      expect(after[t], before[t], reason: '$t changed in the upgrade');
    }
    expect(before['plants'], hasLength(3025));
    expect(idsAfter, idsBefore);
  });
}
