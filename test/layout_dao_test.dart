import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/membership_service.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/layout_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/daos/vines_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/models/enums.dart';

/// The layout DAO against the generic object model.
///
/// **The invariant under test throughout:** a plant with a non-null carrier is
/// physically on that line, and its x/y is always `path.pointAt(pathOffset)`.
void main() {
  late AppDatabase db;

  late LayoutDao layout;

  late FieldDefsDao fields;

  late String projectId;

  late String rowField;

  late String blockField;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());

    final labels = LabelService(db);
    layout = LayoutDao(db, labels, MembershipService(db));
    fields = FieldDefsDao(db);
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

  Shape lineFrom(Offset a, Offset b) => PolylineShape(Polyline([a, b]));

  Shape squareAt(double left, double top, double size) => PolygonShape([
    Offset(left, top),
    Offset(left + size, top),
    Offset(left + size, top + size),
    Offset(left, top + size),
  ]);

  Future<String> row(String label, {Shape? shape}) => layout.createObject(
    projectId: projectId,
    fieldDefId: rowField,
    label: label,
    geometry: shape ?? lineFrom(const Offset(0, 0), const Offset(400, 0)),
  );

  Future<Vine> reload(String vineId) async => (await layout.plantById(vineId))!;

  group('objects', () {
    test('a drawn object round-trips its shape', () async {
      final id = await row('12');

      final shape = await layout.shapeOf(id);
      expect(shape, isA<PolylineShape>());
      expect(shape!.points.last, const Offset(400, 0));
    });

    test('an object can exist before it is drawn', () async {
      final id = await layout.createObject(
        projectId: projectId,
        fieldDefId: rowField,
        label: '13',
      );
      expect(await layout.shapeOf(id), isNull);
      expect(await layout.carrierPathOf(id), isNull);
    });

    test('carrierPathOf is null for a polygon', () async {
      final id = await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: '1',
        geometry: squareAt(0, 0, 100),
      );
      expect(await layout.shapeOf(id), isA<PolygonShape>());
      expect(await layout.carrierPathOf(id), isNull);
    });
  });

  group('planting', () {
    test('plants land on the line at their offsets', () async {
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0, 100, 200],
      );
      expect(ids, hasLength(3));

      final first = await reload(ids.first);
      expect(first.carrierId, id);
      expect(first.x, 0);
      expect(first.pathOffset, 0);

      final last = await reload(ids.last);
      expect(last.x, 200);
      expect(last.positionIdx, 3);
    });

    test('a second pass continues the numbering', () async {
      // The obstacle case: plant the near side, then the far side. Contiguous
      // numbers, a gap in space.
      final id = await row('12');
      await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0, 50, 100],
      );

      final second = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [300, 350],
      );

      final numbers = [
        for (final v in await VinesDao(db).plantsOnCarrier(id)) v.positionIdx,
      ];
      expect(numbers, [1, 2, 3, 4, 5]);
      expect((await reload(second.first)).x, 300);
    });

    test('planting an undrawn object throws rather than guessing', () async {
      final id = await layout.createObject(
        projectId: projectId,
        fieldDefId: rowField,
        label: '13',
      );
      expect(
        () => layout.placePlantsAlongCarrier(carrierId: id, offsets: [0]),
        throwsStateError,
      );
    });
  });

  group('the carrier invariant', () {
    test('reshaping slides plants by offset, not by projection', () async {
      // Extending the far end must leave every existing plant exactly where it
      // was. Re-projecting x/y would nudge each one on every edit and the drift
      // compounds.
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0, 100],
      );
      await layout.updateObjectGeometry(
        id,
        lineFrom(const Offset(0, 0), const Offset(900, 0)),
      );

      final second = await reload(ids[1]);
      expect(second.pathOffset, 100);
      expect(second.x, 100);
    });

    test('moving an object carries its plants exactly', () async {
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0, 100],
      );
      await layout.moveObject(id, const Offset(10, 20));

      final first = await reload(ids.first);
      expect(first.x, 10);
      expect(first.y, 20);
      expect(first.pathOffset, 0);
    });

    test('dragging a carried plant slides it along, never off', () async {
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0],
      );
      // Dropped well above the line: it must land on it.
      await layout.movePlant(ids.first, const Offset(150, 90));

      final moved = await reload(ids.first);
      expect(moved.carrierId, id);
      expect(moved.y, 0);
      expect(moved.x, 150);
    });

    test('a free plant goes exactly where it is put', () async {
      final id = await layout.createPlant(
        projectId: projectId,
        position: const Offset(10, 10),
      );
      await layout.movePlant(id, const Offset(77, 88));

      final moved = await reload(id);
      expect(moved.carrierId, isNull);
      expect(moved.x, 77);
      expect(moved.y, 88);
    });
  });

  group('snapping', () {
    test('snapping renumbers into the carrier sequence', () async {
      final id = await row('12');
      await layout.placePlantsAlongCarrier(carrierId: id, offsets: [0, 100]);

      final free = await layout.createPlant(
        projectId: projectId,
        position: const Offset(200, 40),
      );

      final distance = await layout.snapPlantToCarrier(
        vineId: free,
        carrierId: id,
      );
      expect(distance, 40);

      final snapped = await reload(free);
      expect(snapped.carrierId, id);
      expect(snapped.y, 0);
      expect(snapped.positionIdx, 3);
    });

    test('keeping the number does not renumber', () async {
      // Insert numbers the plant deliberately; snapping must not undo that.
      final id = await row('12');
      await layout.placePlantsAlongCarrier(carrierId: id, offsets: [0, 100]);

      final free = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 40),
      );
      await db.customStatement(
        'UPDATE vines SET position_idx = 99 WHERE id = ?',
        [free],
      );
      await layout.snapPlantToCarrierKeepingNumber(vineId: free, carrierId: id);
      expect((await reload(free)).positionIdx, 99);
    });

    test('unsnapping leaves the plant where it is on screen', () async {
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [100],
      );
      await layout.unsnapPlant(ids.first);

      final loose = await reload(ids.first);
      expect(loose.carrierId, isNull);
      expect(loose.pathOffset, isNull);
      expect(loose.x, 100);
    });
  });

  group('deleting an object', () {
    test('orphans its plants rather than destroying them', () async {
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0, 100],
      );
      await layout.deleteObject(id);
      for (final vineId in ids) {
        final plant = await reload(vineId);
        expect(plant.carrierId, isNull);
        expect(plant.deletedAt, isNull, reason: 'the plant must survive');
      }
      expect(await layout.shapeOf(id), isNull);
    });

    test('clears the memberships it created', () async {
      final block = await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: '1',
        geometry: squareAt(0, 0, 500),
      );

      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0],
      );

      final before = await db.select(db.plantMemberships).get();
      expect(before.where((m) => m.objectId == block), isNotEmpty);
      await layout.deleteObject(block);

      final after = await db.select(db.plantMemberships).get();
      expect(after.where((m) => m.objectId == block), isEmpty);
      expect(await reload(ids.first), isNotNull);
    });
  });

  group('overlap', () {
    test('it finds a same-field object in the way', () async {
      await row(
        '12',
        shape: lineFrom(const Offset(0, 0), const Offset(100, 0)),
      );

      final hit = await layout.checkOverlap(
        fieldDefId: rowField,
        shape: lineFrom(const Offset(50, -50), const Offset(50, 50)),
      );
      expect(hit?.label, '12');
    });

    test('a contained polygon is caught even with no crossing edges', () async {
      await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: '1',
        geometry: squareAt(0, 0, 100),
      );

      final hit = await layout.checkOverlap(
        fieldDefId: blockField,
        shape: squareAt(20, 20, 20),
      );
      expect(hit?.label, '1');
    });

    test('an object being reshaped does not overlap itself', () async {
      final id = await row('12');

      final hit = await layout.checkOverlap(
        fieldDefId: rowField,
        shape: lineFrom(const Offset(0, 0), const Offset(400, 0)),
        ignoringObjectId: id,
      );
      expect(hit, isNull);
    });

    test('a row crossing a block is not an overlap', () async {
      // Different fields entirely -- the normal case, and refusing it would
      // make the model unusable.
      await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: '1',
        geometry: squareAt(0, 0, 100),
      );

      final hit = await layout.checkOverlap(
        fieldDefId: rowField,
        shape: lineFrom(const Offset(-50, 50), const Offset(150, 50)),
      );
      expect(hit, isNull);
    });
  });

  group('replacing a plant', () {
    test('the successor inherits position and number, not identity', () async {
      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [100],
      );

      final old = ids.first;

      final replacement = await layout.replacePlant(vineId: old);

      final dead = await (db.select(
        db.vines,
      )..where((v) => v.id.equals(old))).getSingle();

      final fresh = await reload(replacement);
      expect(dead.status, VineStatus.removed);
      expect(dead.endedAt, isNotNull);
      expect(fresh.positionIdx, dead.positionIdx);
      expect(fresh.carrierId, dead.carrierId);
      expect(fresh.pathOffset, dead.pathOffset);
      expect(fresh.predecessorId, old);
      expect(fresh.id, isNot(old));
    });

    test('only the named static fields are copied forward', () async {
      final variety =
          ((await fields.create(
                    projectId: projectId,
                    name: 'Variety',
                    type: FieldType.text,
                    isStatic: true,
                  ))
                  as FieldDefSaved)
              .id;

      final planted =
          ((await fields.create(
                    projectId: projectId,
                    name: 'Planted',
                    type: FieldType.text,
                    isStatic: true,
                  ))
                  as FieldDefSaved)
              .id;

      final id = await row('12');

      final old = (await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0],
      )).first;
      for (final pair in [(variety, 'Pinot Noir'), (planted, '2019')]) {
        await db
            .into(db.fieldEvents)
            .insert(
              FieldEventsCompanion.insert(
                id: 'e_${pair.$1}',
                vineId: old,
                fieldDefId: pair.$1,
                value: Value(pair.$2),
                observedAt: DateTime.utc(2026),
                recordedAt: DateTime.utc(2026),
              ),
            );
      }
      // Variety carries forward; the old plant's planting date does not belong
      // to the new one.
      final replacement = await layout.replacePlant(
        vineId: old,
        inheritFieldIds: {variety},
      );

      final events = await (db.select(
        db.fieldEvents,
      )..where((e) => e.vineId.equals(replacement))).get();
      expect(events, hasLength(1));
      expect(events.single.fieldDefId, variety);
      expect(events.single.value, 'Pinot Noir');
    });
  });

  group('membership follows geometry', () {
    test('planting inside a block joins it', () async {
      final block = await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: '1',
        geometry: squareAt(-50, -50, 200),
      );

      final id = await row('12');

      final ids = await layout.placePlantsAlongCarrier(
        carrierId: id,
        offsets: [0],
      );

      final held = await db.select(db.plantMemberships).get();
      expect(
        held.where((m) => m.vineId == ids.first && m.objectId == block),
        hasLength(1),
      );
    });

    test('moving a plant out of a block leaves it', () async {
      final block = await layout.createObject(
        projectId: projectId,
        fieldDefId: blockField,
        label: '1',
        geometry: squareAt(0, 0, 100),
      );

      final plant = await layout.createPlant(
        projectId: projectId,
        position: const Offset(50, 50),
      );
      expect(await db.select(db.plantMemberships).get(), hasLength(1));
      await layout.movePlant(plant, const Offset(500, 500));

      final after = await db.select(db.plantMemberships).get();
      expect(after.where((m) => m.objectId == block), isEmpty);
    });
  });
}
