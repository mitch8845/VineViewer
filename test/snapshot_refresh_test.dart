import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';

/// The canvas must follow every table it draws from, not just `plants`.
///
/// It used to rebuild only when a plant row changed, so drawing a block, an
/// unplanted line or a post -- or renaming or reshaping something with no
/// plants on it -- showed nothing until an unrelated plant edit came along.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String projectId;
  late String rowField;
  late String blockField;
  late String healthField;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    projectId = await container
        .read(projectsDaoProvider)
        .create(name: 'Five Sisters');
    final fields = container.read(fieldDefsDaoProvider);
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
    healthField =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Health',
                  type: FieldType.rating,
                ))
                as FieldDefSaved)
            .id;
    container.read(activeProjectIdProvider.notifier).state = projectId;
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Keeps [provider] alive and returns a way to read its latest value.
  T Function() listen<T>(ProviderListenable<AsyncValue<T>> provider) {
    final sub = container.listen(provider, (_, _) {}, fireImmediately: true);
    addTearDown(sub.close);
    return () => sub.read().requireValue;
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
    }
  }

  LayoutDao layout() => container.read(layoutDaoProvider);

  test('a block with no plants appears as soon as it is drawn', () async {
    final snapshot = listen(layoutSnapshotProvider);
    await settle();
    expect(snapshot().objects, isEmpty);

    await layout().createObject(
      projectId: projectId,
      fieldDefId: blockField,
      label: '1',
      geometry: PolygonShape(const [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
      ]),
    );
    await settle();

    expect(snapshot().objects.map((o) => o.label), ['1']);
  });

  test('renaming an empty object shows the new name', () async {
    final id = await layout().createObject(
      projectId: projectId,
      fieldDefId: rowField,
      label: '1',
      geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(50, 0)])),
    );
    final snapshot = listen(layoutSnapshotProvider);
    await settle();

    await layout().renameObject(id, '7');
    await settle();

    expect(snapshot().objects.single.label, '7');
  });

  test('retired plants are slots, not selectable plants', () async {
    final carrier = await layout().createObject(
      projectId: projectId,
      fieldDefId: rowField,
      label: '1',
      geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(100, 0)])),
    );
    final plants = await layout().placePlantsAlongCarrier(
      carrierId: carrier,
      offsets: const [0, 50],
    );
    final snapshot = listen(layoutSnapshotProvider);
    await settle();
    expect(snapshot().positions.length, 2);

    await layout().retirePlant(plants.first, change: PlantStatusChange.removed);
    await settle();

    expect(snapshot().positions.keys, [plants.last]);
    expect(snapshot().retired.keys, [plants.first]);
    // A marquee over the whole row finds only the living plant.
    final swept = snapshot().index.inRect(
      const Rect.fromLTRB(-10, -10, 110, 10),
    );
    expect(swept.map((p) => p.id), [plants.last]);
  });

  test(
    'IDs refresh when an object is renamed, with no plant row written',
    () async {
      final carrier = await layout().createObject(
        projectId: projectId,
        fieldDefId: rowField,
        label: '12',
        geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(100, 0)])),
      );
      await layout().placePlantsAlongCarrier(
        carrierId: carrier,
        offsets: const [0],
      );
      final labels = container.listen(labelsProvider, (_, _) {});
      addTearDown(labels.close);
      final revision = listen(identityRevisionProvider);
      await settle();

      final before = revision();
      await layout().renameObject(carrier, '13');
      await settle();

      expect(revision(), greaterThan(before));
    },
  );

  test('colouring follows a value as soon as it is recorded', () async {
    final carrier = await layout().createObject(
      projectId: projectId,
      fieldDefId: rowField,
      label: '1',
      geometry: PolylineShape(Polyline(const [Offset(0, 0), Offset(100, 0)])),
    );
    final plants = await layout().placePlantsAlongCarrier(
      carrierId: carrier,
      offsets: const [0, 50],
    );
    listen(layoutSnapshotProvider);
    container.read(colorByFieldProvider.notifier).state = healthField;
    final colouring = listen(plantColouringProvider);
    await settle();
    expect(colouring()!.colors, isEmpty);

    await container
        .read(fieldEventsDaoProvider)
        .record(plantId: plants.first, fieldDefId: healthField, value: '5');
    await settle();

    expect(colouring()!.colors.keys, [plants.first]);
    expect(colouring()!.legend.last.label, 'Not recorded');
  });
}
