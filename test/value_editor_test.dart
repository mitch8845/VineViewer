import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/features/data_entry/value_editor_sheet.dart';

FieldDef field(FieldType type) {
  final at = DateTime.utc(2026);
  return FieldDef(
    id: 'f',
    projectId: 'p',
    name: 'Disease',
    type: type,
    role: FieldRole.attribute,
    isContainer: false,
    isStatic: false,
    sortOrder: 0,
    createdAt: at,
    updatedAt: at,
  );
}

/// Opens the editor and returns a handle on what it eventually returns.
Future<Future<ValueEdit?>> open(
  WidgetTester tester, {
  required FieldType type,
  FieldConfig config = FieldConfig.empty,
  String? current,
}) async {
  late Future<ValueEdit?> result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showValueEditor(
              context,
              field: field(type),
              config: config,
              current: current,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('tapping outside the sheet is a cancel, never a clear', (
    tester,
  ) async {
    // The bug: dismissal returned null, null meant "clear", and a swipe down
    // erased the value the sheet was showing.
    final result = await open(
      tester,
      type: FieldType.text,
      current: 'Chardonnay',
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });

  testWidgets('Clear is an explicit edit holding null', (tester) async {
    final result = await open(tester, type: FieldType.text, current: 'x');
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    final edit = await result;
    expect(edit, isNotNull);
    expect(edit!.isClear, isTrue);
  });

  testWidgets('multi-select keeps every ticked option', (tester) async {
    // Tapping one option used to save just that option, so the field could
    // never hold more than one.
    final result = await open(
      tester,
      type: FieldType.multiSelect,
      config: const FieldConfig(options: ['Mildew', 'Rot', 'Phylloxera']),
    );
    await tester.tap(find.text('Mildew'));
    await tester.pump();
    await tester.tap(find.text('Rot'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await result)!.value, ['Mildew', 'Rot']);
  });

  testWidgets('multi-select opens with the stored options ticked', (
    tester,
  ) async {
    final result = await open(
      tester,
      type: FieldType.multiSelect,
      config: const FieldConfig(options: ['Mildew', 'Rot']),
      current: '["Rot"]',
    );
    await tester.tap(find.text('Mildew'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await result)!.value, unorderedEquals(['Rot', 'Mildew']));
  });

  testWidgets('"allow other" offers a box for a value off the list', (
    tester,
  ) async {
    final result = await open(
      tester,
      type: FieldType.categorical,
      config: const FieldConfig(options: ['Chardonnay'], allowOther: true),
    );
    await tester.enterText(find.byType(TextField), 'Albariño');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect((await result)!.value, 'Albariño');
  });
}
