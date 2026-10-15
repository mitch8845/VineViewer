import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/db/database.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/features/canvas/plant_colouring.dart';

/// Colour-by-field is pure mapping from stored value to colour, so it is tested
/// without a canvas: the ramps and the fallbacks are where it would quietly lie.
FieldDef field(FieldType type, {String name = 'Health'}) {
  final at = DateTime.utc(2026);
  return FieldDef(
    id: 'f',
    projectId: 'p',
    name: name,
    type: type,
    role: FieldRole.attribute,
    isContainer: false,
    isStatic: false,
    sortOrder: 0,
    createdAt: at,
    updatedAt: at,
  );
}

void main() {
  test('categorical uses the colours chosen for each option', () {
    final c = PlantColouring.build(
      field: field(FieldType.categorical),
      config: const FieldConfig(
        options: ['Good', 'Poor'],
        optionColors: {'Good': '#00FF00', 'Poor': '#FF0000'},
      ),
      values: {'a': 'Good', 'b': 'Poor'},
    );
    expect(c.colors['a'], const Color(0xFF00FF00));
    expect(c.colors['b'], const Color(0xFFFF0000));
    expect(c.legend.map((e) => e.label), ['Good', 'Poor']);
  });

  test('a plant with nothing recorded is absent and listed as a gap', () {
    // Absent from the map so the painter's grey fallback applies: a gap in a
    // survey must not pass for the default healthy green.
    final c = PlantColouring.build(
      field: field(FieldType.categorical),
      config: const FieldConfig(options: ['Good']),
      values: {'a': 'Good', 'b': null},
    );
    expect(c.colors.containsKey('b'), isFalse);
    expect(c.legend.last.label, 'Not recorded');
    expect(c.legend.last.color, PlantColouring.noValue);
  });

  test('no gap entry when every plant has a value', () {
    final c = PlantColouring.build(
      field: field(FieldType.boolean),
      config: FieldConfig.empty,
      values: {'a': '1', 'b': '0'},
    );
    expect(c.legend.map((e) => e.label), ['Yes', 'No']);
    expect(c.colors['a'], isNot(c.colors['b']));
  });

  test('a rating runs from red at the bottom to green at the top', () {
    final c = PlantColouring.build(
      field: field(FieldType.rating),
      config: const FieldConfig(scaleMin: 1, scaleMax: 5),
      values: {'low': '1', 'mid': '3', 'high': '5'},
    );
    final low = c.colors['low']!;
    final high = c.colors['high']!;
    expect(low.r, greaterThan(low.g));
    expect(high.g, greaterThan(high.r));
    // Legend reads top-down, best first, one row per score.
    expect(c.legend.first.label, startsWith('5'));
    expect(c.legend.length, 5);
  });

  test('a configured colour ramp wins over the default', () {
    final c = PlantColouring.build(
      field: field(FieldType.integer),
      config: const FieldConfig(
        colorRamp: {'0': '#000000', '10': '#FFFFFF'},
        interpolate: true,
      ),
      values: {'a': '0', 'b': '5', 'c': '10'},
    );
    expect(c.colors['a'], const Color(0xFF000000));
    expect(c.colors['c'], const Color(0xFFFFFFFF));
    final mid = c.colors['b']!;
    expect(mid.r, closeTo(0.5, 0.02));
  });

  test('a stepped ramp does not blend between stops', () {
    final c = PlantColouring.build(
      field: field(FieldType.integer),
      config: const FieldConfig(
        colorRamp: {'0': '#000000', '10': '#FFFFFF'},
        interpolate: false,
      ),
      values: {'b': '5'},
    );
    expect(c.colors['b'], const Color(0xFF000000));
  });

  test('numbers with no bounds use the spread that was observed', () {
    // A ramp from zero to infinity would paint everything the same colour.
    final c = PlantColouring.build(
      field: field(FieldType.decimal),
      config: FieldConfig.empty,
      values: {'a': '12.5', 'b': '14.5'},
    );
    expect(c.colors['a'], isNot(c.colors['b']));
  });

  test(
    'more categories than colours fold into "Other" instead of repeating',
    () {
      final values = {for (var i = 0; i < 14; i++) 'p$i': 'clone $i'};
      final c = PlantColouring.build(
        field: field(FieldType.text, name: 'Clone'),
        config: FieldConfig.empty,
        values: values,
      );
      final distinct = c.colors.values.toSet();
      expect(distinct.length, PlantColouring.palette.length + 1);
      expect(c.legend.last.label, 'Other');
    },
  );

  test('a multi-select plant takes the colour of its first option', () {
    final c = PlantColouring.build(
      field: field(FieldType.multiSelect),
      config: const FieldConfig(
        options: ['Mildew', 'Rot'],
        optionColors: {'Mildew': '#123456', 'Rot': '#654321'},
      ),
      values: {'a': '["Rot","Mildew"]'},
    );
    expect(c.colors['a'], const Color(0xFF654321));
  });

  test('dates run from oldest to newest', () {
    final c = PlantColouring.build(
      field: field(FieldType.date, name: 'Planted'),
      config: FieldConfig.empty,
      values: {'old': '2001-04-01', 'new': '2024-04-01'},
    );
    expect(c.legend.first.label, '2024-04-01');
    expect(c.legend.last.label, '2001-04-01');
    expect(c.colors['old'], isNot(c.colors['new']));
  });
}
