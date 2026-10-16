import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/data/label_service.dart';
import 'package:vine_viewer/core/data/seed_service.dart';
import 'package:vine_viewer/core/data/walk_plan.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/daos/walk_orders_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';
import 'package:vine_viewer/features/walk/walk_order_screen.dart';
import 'package:vine_viewer/features/walk/walk_session.dart';
import 'package:vine_viewer/features/walk/walk_setup_screen.dart';

/// The order editor on the real Five Sisters: what is arranged and saved
/// under a name is what a walk that picks that name then follows.
void main() {
  late AppDatabase db;
  late String projectId;
  late WalkOrdersDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = WalkOrdersDao(db);
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    await SeedService(db).load(
      projectId,
      ProjectSeed.decode(
        File('assets/seeds/five_sisters.json.gz').readAsBytesSync(),
        schemaVersion: db.schemaVersion,
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// A saved order: plant ID order with row 1 switched off.
  Future<String> saveRowOneOff(String name) async {
    final ids = await LabelService(db).identifiersForProject(projectId);
    final standard = WalkPlan.standard(ids);
    final row1 = standard.sections(WalkLevel.rows, ids).first;
    return dao.create(
      projectId: projectId,
      name: name,
      plan: standard.include(
        standard.order.sublist(row1.start, row1.end),
        false,
      ),
    );
  }

  Future<void> open(WidgetTester tester, {String? orderId}) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeProjectIdProvider.overrideWith((ref) => projectId),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => WalkOrderScreen(
                        projectId: projectId,
                        orderId: orderId,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.tap(find.text('Rows'));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }

  Future<void> name(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await settle(tester);
  }

  testWidgets('a new order is named when it is first saved', (tester) async {
    await tester.runAsync(() async {
      await open(tester);
      expect(find.text('New walk order'), findsOneWidget);

      await tester.tap(find.text('Block 1 · Row 1'));
      await settle(tester);
      await tester.tap(find.text('Down'));
      await settle(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(find.text('Name this walk order'), findsOneWidget);
      await name(tester, 'Row 2 first');

      expect(find.text('Walk order: Row 2 first'), findsOneWidget);
      final saved = (await dao.forProject(projectId)).single;
      expect(saved.name, 'Row 2 first');
      final ids = await LabelService(db).identifiersForProject(projectId);
      final rows = saved.plan.sections(WalkLevel.rows, ids);
      expect(rows[0].key, ['1', '2']);
      expect(rows[1].key, ['1', '1']);
      expect(saved.plan.walk, hasLength(3025));
      await finish(tester);
    });
  });

  testWidgets('a row switched off is left out of the walk', (tester) async {
    await tester.runAsync(() async {
      await open(tester);
      final rowOneSwitch = find.descendant(
        of: find
            .ancestor(
              of: find.text('Block 1 · Row 1'),
              matching: find.byType(Material),
            )
            .first,
        matching: find.byType(Switch),
      );
      await tester.tap(rowOneSwitch);
      await settle(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      await name(tester, 'No row 1');

      final plan = (await dao.forProject(projectId)).single.plan;
      expect(plan.order, hasLength(3025));
      expect(plan.walk.length, lessThan(3025));
      expect(plan.excluded, isNotEmpty);
      await finish(tester);
    });
  });

  testWidgets('a name already used is refused', (tester) async {
    await tester.runAsync(() async {
      await saveRowOneOff('Terrace walk');
      await open(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Terrace walk');
      await settle(tester);
      expect(
        find.text('There is already a walk order called that'),
        findsOneWidget,
      );
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save').last,
      );
      expect(save.onPressed, isNull);
      await finish(tester);
    });
  });

  testWidgets('leaving with changes asks first; Discard saves nothing', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final id = await saveRowOneOff('Terrace walk');
      final before = (await dao.load(id))!.plan.order;
      await open(tester, orderId: id);
      await tester.tap(find.text('Block 1 · Row 2'));
      await settle(tester);
      await tester.tap(find.text('Flip'));
      await settle(tester);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.text('Save the walk order?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await settle(tester);

      expect(find.text('open'), findsOneWidget);
      expect((await dao.load(id))!.plan.order, before);
      await finish(tester);
    });
  });

  testWidgets('a new order left untouched does not ask', (tester) async {
    await tester.runAsync(() async {
      await open(tester);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.text('open'), findsOneWidget);
      expect(await dao.forProject(projectId), isEmpty);
      await finish(tester);
    });
  });

  testWidgets('Save as a copy leaves the original as it was', (tester) async {
    await tester.runAsync(() async {
      final id = await saveRowOneOff('Terrace walk');
      final before = (await dao.load(id))!.plan.order;
      await open(tester, orderId: id);
      await tester.tap(find.text('Block 1 · Row 2'));
      await settle(tester);
      await tester.tap(find.text('Flip'));
      await settle(tester);
      await tester.tap(find.byTooltip('More'));
      await settle(tester);
      await tester.tap(find.text('Save as a copy…'));
      await settle(tester);
      await name(tester, 'Terrace walk, row 2 flipped');

      final orders = await dao.forProject(projectId);
      expect(
        [for (final o in orders) o.name],
        ['Terrace walk', 'Terrace walk, row 2 flipped'],
      );
      expect((await dao.load(id))!.plan.order, before);
      expect(orders.last.plan.order, isNot(before));
      expect(orders.last.plan.excluded, orders.first.plan.excluded);
      await finish(tester);
    });
  });

  group('walk setup', () {
    late Directory dir;
    late WalkBookmarks bookmarks;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('walk_setup_order');
      bookmarks = WalkBookmarks(directory: () async => dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> openSetup(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1500, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            activeProjectIdProvider.overrideWith((ref) => projectId),
            walkBookmarksProvider.overrideWithValue(bookmarks),
          ],
          child: MaterialApp(home: WalkSetupScreen(projectId: projectId)),
        ),
      );
      await settle(tester);
    }

    testWidgets('a walk follows the order picked, for any field', (
      tester,
    ) async {
      await tester.runAsync(() async {
        // Row 1 switched off, so the walk starts on row 2 -- at its far end,
        // since row 2 is walked back.
        final id = await saveRowOneOff('Terrace walk');
        await openSetup(tester);
        expect(find.text('Plant ID order'), findsOneWidget);
        await tester.tap(find.text('Terrace walk'));
        await tester.tap(find.text('Health'));
        await settle(tester);
        await tester.tap(find.text('Start walking'));
        await settle(tester);

        expect(find.text('1.2.43'), findsOneWidget);
        expect(find.textContaining('of 2,983'), findsOneWidget);
        expect(await bookmarks.lastOrder(projectId), id);
        await finish(tester);
      });
    });

    testWidgets('the order used last time is picked already', (tester) async {
      await tester.runAsync(() async {
        final id = await saveRowOneOff('Terrace walk');
        await bookmarks.saveLastOrder(projectId, id);
        await openSetup(tester);
        await tester.tap(find.text('Health'));
        await settle(tester);
        await tester.tap(find.text('Start walking'));
        await settle(tester);
        expect(find.text('1.2.43'), findsOneWidget);
        await finish(tester);
      });
    });

    testWidgets('an unfinished walk can be discarded', (tester) async {
      await tester.runAsync(() async {
        final health = (await FieldDefsDao(
          db,
        ).forProject(projectId)).firstWhere((f) => f.name == 'Health');
        await bookmarks.save(
          projectId,
          WalkBookmark(fieldIds: [health.id], plantId: null, index: 40),
        );
        await openSetup(tester);
        expect(find.textContaining('Unfinished walk'), findsOneWidget);
        expect(find.text('Start a new walk'), findsOneWidget);

        await tester.tap(find.text('Discard'));
        await settle(tester);
        expect(find.text('Discard the unfinished walk?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
        await settle(tester);

        expect(find.textContaining('Unfinished walk'), findsNothing);
        expect(find.text('Start walking'), findsOneWidget);
        expect(await bookmarks.load(projectId), isNull);
        await finish(tester);
      });
    });

    testWidgets('copying an order from the list', (tester) async {
      await tester.runAsync(() async {
        await saveRowOneOff('Terrace walk');
        await openSetup(tester);
        await tester.tap(find.byTooltip('Walk order options'));
        await settle(tester);
        await tester.tap(find.text('Copy…'));
        await settle(tester);
        await name(tester, 'Terrace walk for Vigour');

        expect(find.text('Terrace walk for Vigour'), findsOneWidget);
        final orders = await dao.forProject(projectId);
        expect(orders, hasLength(2));
        expect(orders.last.plan.walk, orders.first.plan.walk);
        await finish(tester);
      });
    });
  });
}
