import 'package:flutter_test/flutter_test.dart';

import 'package:vine_viewer/main.dart';

void main() {
  testWidgets('renders the app name on launch', (WidgetTester tester) async {
    await tester.pumpWidget(const VineViewerApp());

    // Only the first frame. PackageInfo needs platform channels that aren't
    // available here, so the version stays at its placeholder -- pumpAndSettle
    // would hang waiting on it.
    expect(find.text('VineViewer'), findsOneWidget);
  });
}
