import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/geometry/spatial_index.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';
import 'package:vine_viewer/features/canvas/heatmap.dart';
import 'package:vine_viewer/features/canvas/plant_colouring.dart';

/// 20 rows of 20 vines, 1 apart, ids "x,y".
Map<String, Offset> block() => {
  for (var x = 0; x < 20; x++)
    for (var y = 0; y < 20; y++) '$x,$y': Offset(x.toDouble(), y.toDouble()),
};

double at(HeatDensity d, Offset p) {
  final x = ((p.dx - d.origin.dx) / d.cellSize).floor();
  final y = ((p.dy - d.origin.dy) / d.cellSize).floor();
  return d.values[y * d.width + x];
}

void main() {
  group('concentration', () {
    final all = block();

    test('a patch of chosen vines is hot there and cold elsewhere', () {
      // A 5x5 patch in one corner.
      final patch = {
        for (var x = 0; x < 5; x++)
          for (var y = 0; y < 5; y++) '$x,$y',
      };
      final d = HeatDensity.compute(all: all, hot: patch, radius: 3);
      expect(HeatDensity.strength(at(d, const Offset(2, 2))), greaterThan(0.9));
      expect(at(d, const Offset(15, 15)), 0);
    });

    test('the same number of vines scattered stays faint', () {
      // 25 vines, one every fourth row and column: no patch anywhere.
      final scattered = {
        for (var x = 0; x < 20; x += 4)
          for (var y = 0; y < 20; y += 4) '$x,$y',
      };
      final d = HeatDensity.compute(all: all, hot: scattered, radius: 3);
      var strongest = 0.0;
      for (final v in d.values) {
        if (HeatDensity.strength(v) > strongest) {
          strongest = HeatDensity.strength(v);
        }
      }
      expect(strongest, lessThan(0.3));
    });

    test('every vine chosen is full strength across the block', () {
      final d = HeatDensity.compute(all: all, hot: all.keys.toSet(), radius: 3);
      expect(at(d, const Offset(10, 10)), closeTo(1, 0.01));
    });

    test('nothing chosen draws nothing', () {
      final d = HeatDensity.compute(all: all, hot: const {}, radius: 3);
      expect(d.toPixels().every((b) => b == 0), isTrue);
    });

    test('the grid stays small however large the vineyard', () {
      final huge = {
        for (var i = 0; i < 4000; i++)
          '$i': Offset((i % 80) * 50.0, (i ~/ 80) * 50.0),
      };
      final d = HeatDensity.compute(all: huge, hot: {'1'}, radius: 2);
      expect(d.width, lessThanOrEqualTo(HeatDensity.maxCells));
      expect(d.height, lessThanOrEqualTo(HeatDensity.maxCells));
    });

    test('spacing is the distance to the nearest vine', () {
      final rows = {
        for (var r = 0; r < 10; r++)
          for (var p = 0; p < 30; p++) '$r.$p': Offset(p * 1.5, r * 3.0),
      };
      final index = SpatialIndex.build([
        for (final e in rows.entries) (id: e.key, position: e.value),
      ]);
      expect(typicalSpacing(rows, index), closeTo(1.5, 1e-9));
    });
  });

  test('which plants a heatmap concentrates on', () {
    const c = PlantColouring(
      fieldId: 'f',
      fieldName: 'Health',
      colors: {},
      legend: [],
      keyOf: {'a': '1', 'b': '5', 'c': PlantColouring.notRecorded},
    );
    // Nothing filtered: everything recorded, the gaps left out.
    expect(heatPlants(c, const {}), {'a', 'b'});
    // Picking entries: what is ticked, gaps included if ticked.
    expect(heatPlants(c, {'5'}), {'a', 'c'});
    expect(heatPlants(c, {'1', '5'}), {'c'});
  });

  test('the map as of a day shows the values as they were', () async {
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
      offsets: const [0, 10],
    );
    final events = container.read(fieldEventsDaoProvider);
    final spring = DateTime(2026, 4, 10, 9);
    final summer = DateTime(2026, 7, 2, 16);
    await events.record(
      plantId: plants[0],
      fieldDefId: health,
      value: 'Good',
      observedAt: spring,
    );
    await events.record(
      plantId: plants[0],
      fieldDefId: health,
      value: 'Dead',
      observedAt: summer,
    );
    // Late on a day still counts for that day.
    await events.record(
      plantId: plants[1],
      fieldDefId: health,
      value: 'Good',
      observedAt: DateTime(2026, 4, 10, 23, 59),
    );

    container.read(activeProjectIdProvider.notifier).state = projectId;
    container.read(colorByFieldProvider.notifier).state = health;
    final colouring = container.listen(plantColouringProvider, (_, _) {});
    final days = container.listen(colourDaysProvider, (_, _) {});
    addTearDown(colouring.close);
    addTearDown(days.close);
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await pumpEventQueue();
      }
    }

    await settle();
    expect(days.read().value, [DateTime(2026, 4, 10), DateTime(2026, 7, 2)]);
    expect(colouring.read().value!.keyOf, {
      plants[0]: 'Dead',
      plants[1]: 'Good',
    });

    container.read(asOfDayProvider.notifier).state = DateTime(2026, 4, 10);
    await settle();
    expect(colouring.read().value!.keyOf, {
      plants[0]: 'Good',
      plants[1]: 'Good',
    });

    container.read(asOfDayProvider.notifier).state = DateTime(2026, 4, 9);
    await settle();
    expect(colouring.read().value!.keyOf.values.toSet(), {
      PlantColouring.notRecorded,
    });
  });
}
