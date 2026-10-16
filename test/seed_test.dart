import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/operation_recorder.dart';
import 'package:vine_viewer/core/data/seed_service.dart';
import 'package:vine_viewer/core/data/undo_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';

/// The bundled Five Sisters seed: loads whole, renders the same identifiers
/// and values it had on the tablet, and can start more than one vineyard.
void main() {
  late AppDatabase db;
  late ProjectsDao projects;
  late SeedService seeds;
  late OperationRecorder recorder;
  late ProjectSeed seed;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectsDao(db);
    seeds = SeedService(db);
    recorder = OperationRecorder(db);
    // The real asset, not a fixture: what is tested is what ships.
    seed = ProjectSeed.decode(
      File('assets/seeds/five_sisters.json.gz').readAsBytesSync(),
      schemaVersion: db.schemaVersion,
    );
  });

  tearDown(() => db.close());

  Future<String> loadNamed(String name) async {
    final id = await projects.create(name: name);
    await recorder.run(
      projectId: id,
      kind: 'load_seed',
      description: 'Start from the ${seed.name} seed',
      body: () => seeds.load(id, seed, imagePath: '/aerial.img'),
    );
    return id;
  }

  Future<int> count(String sql, String projectId) async =>
      (await db.customSelect(sql, variables: [Variable(projectId)]).getSingle())
          .read<int>('n');

  test('loads every plant, drawing and value under the new name', () async {
    final id = await loadNamed('Five Sisters 2027');

    final project = (await projects.byId(id))!;
    expect(project.name, 'Five Sisters 2027');
    expect(project.imagePath, '/aerial.img');
    expect((project.imageWidth, project.imageHeight), (874, 763));

    expect(
      await count('SELECT COUNT(*) AS n FROM plants WHERE project_id = ?', id),
      3025,
    );
    expect(
      await count(
        'SELECT COUNT(*) AS n FROM map_objects WHERE project_id = ?',
        id,
      ),
      78,
    );
    expect(
      await count(
        'SELECT COUNT(*) AS n FROM field_events e JOIN plants p '
        'ON p.id = e.plant_id WHERE p.project_id = ?',
        id,
      ),
      12800,
    );
    expect(
      (await FieldDefsDao(db).forProject(id)).map((f) => f.name),
      containsAll(['Row', 'Block', 'Variety', 'Clone', 'Health']),
    );
  });

  test('identifiers render through the remapped template', () async {
    final id = await loadNamed('Copy');
    final labels = LabelService(db);

    final identifiers = await labels.identifiersForProject(id);
    expect(identifiers, hasLength(3025));
    expect(await labels.findDuplicateIdentifiers(id), isEmpty);

    // Block 1, row 12, plant 7 -- Pinot Noir on the tablet.
    final plant = identifiers.entries
        .singleWhere((e) => e.value.text == '1.12.7')
        .key;
    final variety = (await FieldDefsDao(
      db,
    ).forProject(id)).singleWhere((f) => f.name == 'Variety');
    final values = await FieldEventsDao(db).currentValuesForPlant(plant);
    expect(values[variety.id]?.value, 'Pinot Noir');
  });

  test('one seed starts two vineyards that share no rows', () async {
    final a = await loadNamed('A');
    final b = await loadNamed('B');

    for (final table in [
      'field_defs',
      'map_objects',
      'plants',
      'plant_memberships',
      'field_events',
    ]) {
      final rows = await db
          .customSelect(
            'SELECT COUNT(*) AS n, COUNT(DISTINCT id) AS d FROM $table',
          )
          .getSingle();
      expect(rows.read<int>('n'), rows.read<int>('d'), reason: table);
    }
    expect(
      await count('SELECT COUNT(*) AS n FROM plants WHERE project_id = ?', b),
      await count('SELECT COUNT(*) AS n FROM plants WHERE project_id = ?', a),
    );
    expect(
      (await projects.byId(a))!.identifierTemplate,
      isNot((await projects.byId(b))!.identifierTemplate),
    );
  });

  test('the load is one undo step', () async {
    final id = await loadNamed('Undo me');
    await UndoService(db).undo(id);
    expect(
      await count('SELECT COUNT(*) AS n FROM plants WHERE project_id = ?', id),
      0,
    );
    expect(await projects.byId(id), isNotNull);
  });

  test('refuses a seed from a newer database', () {
    expect(
      () => ProjectSeed.decode(
        File('assets/seeds/five_sisters.json.gz').readAsBytesSync(),
        schemaVersion: 4,
      ),
      throwsFormatException,
    );
  });
}
