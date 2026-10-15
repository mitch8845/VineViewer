import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';
import 'package:vine_viewer/features/canvas/plant_colouring.dart';

FieldDef field(FieldType type) {
  final at = DateTime.utc(2026);
  return FieldDef(
    id: 'f',
    projectId: 'p',
    name: 'Health',
    type: type,
    role: FieldRole.attribute,
    isContainer: false,
    isStatic: false,
    sortOrder: 0,
    createdAt: at,
    updatedAt: at,
  );
}

/// The filter hides plants by legend entry -- from the picture and from every
/// way of selecting them.
void main() {
  group('which legend entry each plant falls under', () {
    test('choices, with counts and the unrecorded', () {
      final c = PlantColouring.build(
        field: field(FieldType.categorical),
        config: const FieldConfig(options: ['1', '2', 'Dead']),
        values: {'a': 'Dead', 'b': 'Dead', 'c': '2', 'd': null},
      );
      expect(c.keyOf, {
        'a': 'Dead',
        'b': 'Dead',
        'c': '2',
        'd': PlantColouring.notRecorded,
      });
      expect(c.counts, {'Dead': 2, '2': 1, PlantColouring.notRecorded: 1});
      expect(c.visible({'Dead'}), {'c', 'd'});
    });

    test('a rating filters on exact scores', () {
      final c = PlantColouring.build(
        field: field(FieldType.rating),
        config: const FieldConfig(scaleMin: 1, scaleMax: 5),
        values: {'a': '1', 'b': '3', 'c': '5'},
      );
      expect(c.keyOf, {'a': '1', 'b': '3', 'c': '5'});
    });

    test('free numbers fall under the nearest legend step', () {
      final c = PlantColouring.build(
        field: field(FieldType.integer),
        config: const FieldConfig(min: 0, max: 100),
        values: {'a': '2', 'b': '49', 'c': '98'},
      );
      final labels = {for (final l in c.legend) l.label};
      expect(labels.containsAll(c.keyOf.values), isTrue);
      expect(c.keyOf['a'], '0');
      expect(c.keyOf['c'], '100');
    });

    test('a few distinct dates get an entry each', () {
      final c = PlantColouring.build(
        field: field(FieldType.date),
        config: FieldConfig.empty,
        values: {'a': '2026-05-01', 'b': '2026-05-01', 'c': '2026-06-10'},
      );
      expect(c.legend.map((l) => l.label), ['2026-06-10', '2026-05-01']);
      expect(c.counts['2026-05-01'], 2);
    });

    test('many dates are banded, every plant in a listed band', () {
      final c = PlantColouring.build(
        field: field(FieldType.date),
        config: FieldConfig.empty,
        values: {
          for (var i = 1; i <= 28; i++)
            'p$i': '2026-02-${i.toString().padLeft(2, '0')}',
        },
      );
      final labels = {for (final l in c.legend) l.label};
      expect(c.legend, hasLength(6));
      expect(labels.containsAll(c.keyOf.values), isTrue);
    });
  });

  test('a filtered map leaves hidden plants out of the index', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final projectId = await container
        .read(projectsDaoProvider)
        .create(name: 'Five Sisters');
    final fields = container.read(fieldDefsDaoProvider);
    final rowField =
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
    final health =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Health',
                  type: FieldType.categorical,
                  config: const FieldConfig(options: ['Good', 'Dead']),
                ))
                as FieldDefSaved)
            .id;
    final layout = container.read(layoutDaoProvider);
    final row = await layout.createObject(
      projectId: projectId,
      fieldDefId: rowField,
      label: '1',
      geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(100, 0)])),
    );
    final plants = await layout.placePlantsAlongCarrier(
      carrierId: row,
      offsets: const [0, 10, 20],
    );
    final events = container.read(fieldEventsDaoProvider);
    await events.record(plantId: plants[0], fieldDefId: health, value: 'Dead');
    await events.record(plantId: plants[1], fieldDefId: health, value: 'Good');

    container.read(activeProjectIdProvider.notifier).state = projectId;
    container.read(colorByFieldProvider.notifier).state = health;
    final snap = container.listen(mapSnapshotProvider, (_, _) {});
    final colouring = container.listen(plantColouringProvider, (_, _) {});
    addTearDown(snap.close);
    addTearDown(colouring.close);
    for (var i = 0; i < 6; i++) {
      await pumpEventQueue();
    }
    expect(snap.read().positions, hasLength(3));

    // Show only the dead ones.
    container.read(legendFilterProvider.notifier).state = (
      fieldId: health,
      hidden: {'Good', PlantColouring.notRecorded},
    );
    final filtered = snap.read();
    expect(filtered.positions.keys, [plants[0]]);
    // A marquee over the whole row finds only what is showing.
    final swept = filtered.index.inRect(const Rect.fromLTRB(-5, -5, 105, 5));
    expect(swept.map((p) => p.id), [plants[0]]);

    // A filter set on another field is ignored.
    container.read(legendFilterProvider.notifier).state = (
      fieldId: 'some-other-field',
      hidden: {'Good'},
    );
    expect(snap.read().positions, hasLength(3));
  });
}
