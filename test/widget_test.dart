import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/providers.dart';
import 'package:vine_viewer/main.dart';

/// Builds a Project row without touching the database.
///
/// The shell tests override [projectListProvider] directly rather than running
/// against a real drift database. Cancelling a drift stream schedules a
/// zero-duration timer, and flutter_test asserts no timers are pending the
/// instant the test body returns -- before any teardown can pump it out. The
/// DAOs are already covered by their own tests against a real database; what
/// is worth checking here is only that the screen renders what it is given.
Project project(String name) {
  final now = DateTime.utc(2026, 1, 1);
  return Project(
    id: name,
    name: name,
    imageOffsetX: 0,
    imageOffsetY: 0,
    imageScaleX: 1,
    imageScaleY: 1,
    imageRotation: 0,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> pumpShell(WidgetTester tester, List<Project> projects) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectListProvider.overrideWith((ref) => Stream.value(projects)),
      ],
      child: const PlantViewerApp(),
    ),
  );
  // Not pumpAndSettle: the loading state spins a CircularProgressIndicator
  // forever, so pumpAndSettle would never return.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  testWidgets('launches to the project list', (tester) async {
    await pumpShell(tester, const []);

    expect(find.text('PlantViewer'), findsOneWidget);
    expect(find.text('New vineyard'), findsOneWidget);
  });

  testWidgets('an empty install offers the performance test vineyard', (
    tester,
  ) async {
    // The 4,000-plant gate needs a layout at realistic scale long before anyone
    // has drawn one by hand, so seeding is reachable from a cold start.
    await pumpShell(tester, const []);

    expect(find.text('No vineyards yet.'), findsOneWidget);
    expect(find.text('Create 4,000-plant test vineyard'), findsOneWidget);
  });

  testWidgets('projects are listed once they exist', (tester) async {
    await pumpShell(tester, [project('Home Block'), project('River Block')]);

    expect(find.text('Home Block'), findsOneWidget);
    expect(find.text('River Block'), findsOneWidget);
    expect(find.text('No vineyards yet.'), findsNothing);
  });

  testWidgets('a project without an image says so', (tester) async {
    await pumpShell(tester, [project('Home Block')]);
    expect(find.text('No aerial image'), findsOneWidget);
  });
}
