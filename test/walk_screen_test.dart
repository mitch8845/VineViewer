import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/daos/field_defs_dao.dart';
import 'package:vine_viewer/core/db/daos/field_events_dao.dart';
import 'package:vine_viewer/core/db/daos/projects_dao.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/core/models/identifier_template.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/features/canvas/canvas_controller.dart';
import 'package:vine_viewer/features/walk/walk_screen.dart';
import 'package:vine_viewer/features/walk/walk_session.dart';
import 'package:vine_viewer/features/walk/walk_setup_screen.dart';

/// The walk, driven through its buttons against a real database: one tap is
/// one recorded value and one plant further on, and undo takes both back.
void main() {
  late AppDatabase db;
  late Directory dir;
  late String projectId;
  late FieldDef health;

  const plants = ['a', 'b', 'c'];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('walk_screen_test');
    projectId = await ProjectsDao(db).create(name: 'Five Sisters');
    for (final (i, id) in plants.indexed) {
      await db.customStatement(
        'INSERT INTO plants (id, project_id, position_idx, x, y, status, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, 10, ?, 0, 0)',
        [id, projectId, i + 1, 10.0 * (i + 1), 'active'],
      );
    }
    final fields = FieldDefsDao(db);
    final id =
        ((await fields.create(
                  projectId: projectId,
                  name: 'Health',
                  type: FieldType.categorical,
                  config: const FieldConfig(options: ['1', '2', 'Dead']),
                ))
                as FieldDefSaved)
            .id;
    health = (await fields.byId(id))!;
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<String?> valueOf(String plantId) async =>
      (await FieldEventsDao(db).currentEvent(plantId, health.id))?.value;

  Future<void> pumpWalk(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          walkBookmarksProvider.overrideWithValue(
            WalkBookmarks(directory: () async => dir),
          ),
          activeProjectIdProvider.overrideWith((ref) => projectId),
        ],
        child: MaterialApp(
          home: WalkScreen(
            projectId: projectId,
            fields: [health],
            order: plants,
            identifiers: {
              for (final (i, id) in plants.indexed)
                id: PlantIdentifier(parts: ['R', '${i + 1}'], delimiter: '.'),
            },
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('one tap records the value and moves to the next plant', (
    tester,
  ) async {
    await tester.runAsync(() => pumpWalk(tester));
    expect(find.text('1 of 3 · 0 entered'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Dead'));
      await settle(tester);
    });

    expect(await tester.runAsync(() => valueOf('a')), 'Dead');
    expect(find.text('2 of 3 · 1 entered'), findsOneWidget);
    expect(find.text('Next: R.3'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('undo removes the value and goes back to that plant', (
    tester,
  ) async {
    await tester.runAsync(() => pumpWalk(tester));
    await tester.runAsync(() async {
      await tester.tap(find.text('2'));
      await settle(tester);
      await tester.tap(find.text('Undo'));
      await settle(tester);
    });

    expect(await tester.runAsync(() => valueOf('a')), isNull);
    expect(find.text('1 of 3 · 0 entered'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('leaving early keeps the values and bookmarks the place', (
    tester,
  ) async {
    await tester.runAsync(() => pumpWalk(tester));
    await tester.runAsync(() async {
      await tester.tap(find.text('1'));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.close));
      await settle(tester);
    });

    expect(await tester.runAsync(() => valueOf('a')), '1');
    final mark = await tester.runAsync(
      () => WalkBookmarks(directory: () async => dir).load(projectId),
    );
    expect(mark!.plantId, 'b');
    expect(mark.fieldIds, [health.id]);
    await finish(tester);
  });

  testWidgets('the last tap finishes the walk and clears the bookmark', (
    tester,
  ) async {
    await tester.runAsync(() => pumpWalk(tester));
    await tester.runAsync(() async {
      for (var i = 0; i < plants.length; i++) {
        await tester.tap(find.text('2'));
        await settle(tester);
      }
    });

    expect(find.text('Walk finished'), findsOneWidget);
    for (final id in plants) {
      expect(await tester.runAsync(() => valueOf(id)), '2');
    }
    final mark = await tester.runAsync(
      () => WalkBookmarks(directory: () async => dir).load(projectId),
    );
    expect(mark, isNull);
    await finish(tester);
  });
}

/// Takes the screen down and lets drift's stream cleanup run while the test
/// can still see it -- otherwise its zero-length timers outlive the tree and
/// the binding fails the test for them.
Future<void> finish(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });
  await tester.pump();
}

/// Lets the database's futures and streams land, then draws.
///
/// Real time rather than [WidgetTester.pumpAndSettle]: drift answers on real
/// async, which the fake clock never advances.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
}
