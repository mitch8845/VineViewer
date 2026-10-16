import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/walk_plan.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/daos/walk_orders_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';

/// Plant ids are their own identifiers here -- "1.2.3" is block 1, row 2,
/// plant 3 -- so every expectation reads as the walk it describes.
Map<String, PlantIdentifier> vineyard({
  int blocks = 1,
  int rows = 2,
  int plants = 3,
}) => {
  for (var b = 1; b <= blocks; b++)
    for (var r = 1; r <= rows; r++)
      for (var p = 1; p <= plants; p++)
        '$b.$r.$p': PlantIdentifier(parts: ['$b', '$r', '$p'], delimiter: '.'),
};

List<String> labels(
  WalkPlan plan,
  WalkLevel level,
  Map<String, PlantIdentifier> ids,
) => [
  for (final s in plan.sections(level, ids))
    '${plan.order[s.start]}..${plan.order[s.end - 1]}',
];

void main() {
  group('sections', () {
    final ids = vineyard(blocks: 2, rows: 2, plants: 2);
    final plan = WalkPlan.standard(ids);

    test('the standard order goes back and forth', () {
      expect(plan.order, [
        '1.1.1', '1.1.2', '1.2.2', '1.2.1', //
        '2.1.1', '2.1.2', '2.2.2', '2.2.1',
      ]);
    });

    test('blocks, rows and plants', () {
      expect(labels(plan, WalkLevel.blocks, ids), [
        '1.1.1..1.2.1',
        '2.1.1..2.2.1',
      ]);
      expect(labels(plan, WalkLevel.rows, ids), [
        '1.1.1..1.1.2',
        '1.2.2..1.2.1',
        '2.1.1..2.1.2',
        '2.2.2..2.2.1',
      ]);
      expect(plan.sections(WalkLevel.plants, ids), hasLength(8));
    });

    test('an ID without blocks is one block', () {
      final rowsOnly = {
        for (final id in ['1.1', '1.2', '2.1'])
          id: PlantIdentifier(parts: id.split('.'), delimiter: '.'),
      };
      final p = WalkPlan.standard(rowsOnly);
      expect(p.sections(WalkLevel.blocks, rowsOnly), hasLength(1));
      expect(p.sections(WalkLevel.rows, rowsOnly), hasLength(2));
    });
  });

  group('editing', () {
    final ids = vineyard(rows: 3, plants: 3);
    final plan = WalkPlan.standard(ids);
    WalkSection row(WalkPlan p, int i) => p.sections(WalkLevel.rows, ids)[i];

    test('moving row 3 to the front', () {
      final r3 = row(plan, 2);
      final moved = plan.move([(r3.start, r3.end)], 0, ids);
      expect(labels(moved, WalkLevel.rows, ids), [
        '1.3.1..1.3.3',
        '1.1.1..1.1.3',
        '1.2.3..1.2.1',
      ]);
    });

    test('moving a row down past the next one', () {
      final r1 = row(plan, 0);
      final r2 = row(plan, 1);
      final moved = plan.move([(r1.start, r1.end)], r2.end, ids);
      expect(labels(moved, WalkLevel.rows, ids).first, '1.2.3..1.2.1');
      expect(labels(moved, WalkLevel.rows, ids)[1], '1.1.1..1.1.3');
    });

    test('flipping a row', () {
      final r1 = row(plan, 0);
      final flipped = plan.flip(r1.start, r1.end, ids);
      expect(flipped.order.take(3), ['1.1.3', '1.1.2', '1.1.1']);
    });

    test('splitting a row, and joining it again', () {
      final split = plan.split(1);
      expect(labels(split, WalkLevel.rows, ids).take(2), [
        '1.1.1..1.1.1',
        '1.1.2..1.1.3',
      ]);
      expect(split.join(1).order, plan.order);
      expect(split.join(1).breaks, isEmpty);
    });

    test('a piece moved beside the rest of its row stays a piece', () {
      // Cut row 1 after plant 1, then put plant 1's piece after the rest.
      final split = plan.split(1);
      final first = row(split, 0);
      final second = row(split, 1);
      final moved = split.move([(first.start, first.end)], second.end, ids);
      expect(labels(moved, WalkLevel.rows, ids).take(2), [
        '1.1.2..1.1.3',
        '1.1.1..1.1.1',
      ]);
    });

    test('switching plants off leaves them in the order but off the walk', () {
      final off = plan.include(['1.1.2', '1.2.2'], false);
      expect(off.order, plan.order);
      expect(off.walk, isNot(contains('1.1.2')));
      expect(off.walk, hasLength(7));
      expect(off.include(['1.1.2'], true).walk, contains('1.1.2'));
    });

    test('edits never change the original plan', () {
      plan.flip(0, 3, ids);
      plan.include(['1.1.1'], false);
      expect(plan.order, WalkPlan.standard(ids).order);
      expect(plan.excluded, isEmpty);
    });
  });

  group('reconcile', () {
    test('plants that are gone drop out', () {
      final ids = vineyard(rows: 1, plants: 3);
      final plan = WalkPlan.standard(ids).include(['1.1.2'], false);
      ids.remove('1.1.2');
      final now = plan.reconcile(ids);
      expect(now.order, ['1.1.1', '1.1.3']);
      expect(now.excluded, isEmpty);
    });

    test('a new plant goes in beside its neighbour, not at the end', () {
      final ids = vineyard(rows: 2, plants: 3);
      // Row 1 moved after row 2 by hand.
      var plan = WalkPlan.standard(ids);
      final r1 = plan.sections(WalkLevel.rows, ids).first;
      plan = plan.move([(r1.start, r1.end)], plan.order.length, ids);

      ids['1.1.4'] = const PlantIdentifier(
        parts: ['1', '1', '4'],
        delimiter: '.',
      );
      final now = plan.reconcile(ids);
      expect(now.order.indexOf('1.1.4'), now.order.indexOf('1.1.3') + 1);
      expect(now.order.last, '1.1.4');
    });

    test('a retired plant is not walked', () {
      final ids = vineyard(rows: 1, plants: 2);
      final plan = WalkPlan.standard(ids);
      ids['1.1.2'] = const PlantIdentifier(
        parts: ['1', '1', '2'],
        delimiter: '.',
        retired: true,
      );
      expect(plan.reconcile(ids).order, ['1.1.1']);
    });
  });

  test('saved by name, copied, renamed and deleted', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    final dao = WalkOrdersDao(db);

    final id = await dao.create(
      projectId: projectId,
      name: 'Terrace walk',
      plan: WalkPlan(order: ['a', 'b', 'c'], excluded: {'b'}, breaks: {'c'}),
    );
    final loaded = (await dao.load(id))!;
    expect(loaded.name, 'Terrace walk');
    expect(loaded.plan.order, ['a', 'b', 'c']);
    expect(loaded.plan.excluded, {'b'});
    expect(loaded.plan.breaks, {'c'});

    // A copy is its own order from then on: changing it leaves the original.
    final copyId = (await dao.copy(id, 'Terrace walk, top first'))!;
    await dao.update(copyId, WalkPlan(order: ['c', 'b', 'a']));
    expect((await dao.load(id))!.plan.order, ['a', 'b', 'c']);
    expect((await dao.load(copyId))!.plan.order, ['c', 'b', 'a']);
    expect((await dao.load(copyId))!.plan.excluded, isEmpty);

    await dao.rename(id, 'Bottom first');
    expect(
      [for (final o in await dao.forProject(projectId)) o.name],
      ['Bottom first', 'Terrace walk, top first'],
    );

    await dao.delete(id);
    expect(await dao.load(id), isNull);
    expect(await dao.forProject(projectId), hasLength(1));

    // Not tied to any field, but gone with the vineyard.
    await ProjectsDao(db).purge(projectId);
    expect(await dao.load(copyId), isNull);
  });
}
