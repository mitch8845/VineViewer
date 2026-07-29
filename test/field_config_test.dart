import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/models/field_config.dart';

/// Round-tripping a field's configuration.
///
/// The bug this file exists for: the field editor rebuilt `FieldConfig` from
/// scratch on save, carrying only the two values it had controls for. Opening a
/// rating field and changing its name silently erased its scale; a decimal
/// field lost its bounds and precision; a colour ramp vanished. Nothing failed
/// and nothing was reported -- the values were simply gone the next time the
/// field was read.
void main() {
  /// A config using every field, so a dropped one shows up.
  final full = FieldConfig(
    maxLength: 120,
    pattern: r'^\d+$',
    min: 0,
    max: 10,
    precision: 2,
    minDate: DateTime.utc(2020),
    maxDate: DateTime.utc(2030),
    options: const ['good', 'poor'],
    allowOther: true,
    scaleMin: -1,
    scaleMax: 5,
    colorRamp: const {'1': '#FF0000', '5': '#00FF00'},
    optionColors: const {'good': '#2E7D32', 'poor': '#D32F2F'},
    labels: const {'-1': 'Rootstock', '5': 'Excellent'},
    trueLabel: 'Sprayed',
    falseLabel: 'Not sprayed',
    interpolate: false,
    dateOnlyObservation: true,
  );

  group('copyWith', () {
    test('changing the options keeps everything else', () {
      // Exactly what the field editor does on save.
      final saved = full.copyWith(
        options: const ['good', 'fair', 'poor'],
        optionColors: const {'fair': '#FBC02D'},
      );

      expect(saved.options, const ['good', 'fair', 'poor']);
      expect(saved.optionColors, const {'fair': '#FBC02D'});

      // The twelve that used to disappear.
      expect(saved.maxLength, 120);
      expect(saved.pattern, r'^\d+$');
      expect(saved.min, 0);
      expect(saved.max, 10);
      expect(saved.precision, 2);
      expect(saved.scaleMin, -1);
      expect(saved.scaleMax, 5);
      expect(saved.colorRamp, full.colorRamp);
      expect(saved.labels, full.labels);
      expect(saved.trueLabel, 'Sprayed');
      expect(saved.falseLabel, 'Not sprayed');
      expect(saved.allowOther, isTrue);
      expect(saved.interpolate, isFalse);
      expect(saved.dateOnlyObservation, isTrue);
    });

    test('changing nothing changes nothing', () {
      expect(full.copyWith().toMap(), full.toMap());
    });

    test('a rating scale survives an unrelated edit', () {
      // The concrete case: -1 is rootstock in this vineyard, and losing the
      // scale would make that value unenterable.
      const rating = FieldConfig(scaleMin: -1, scaleMax: 5);
      expect(rating.copyWith(options: const ['x']).scaleMin, -1);
      expect(rating.copyWith(options: const ['x']).scaleMax, 5);
    });

    test('an empty config gains only what is passed', () {
      final grown = FieldConfig.empty.copyWith(options: const ['a']);
      expect(grown.options, const ['a']);
      expect(grown.scaleMin, isNull);
      expect(grown.maxLength, isNull);
    });
  });

  group('JSON round trip', () {
    test('survives encoding and decoding intact', () {
      final restored = FieldConfig.parse(full.toJson());

      expect(restored.maxLength, full.maxLength);
      expect(restored.pattern, full.pattern);
      expect(restored.precision, full.precision);
      expect(restored.options, full.options);
      expect(restored.allowOther, full.allowOther);
      expect(restored.scaleMin, full.scaleMin);
      expect(restored.scaleMax, full.scaleMax);
      expect(restored.colorRamp, full.colorRamp);
      expect(restored.optionColors, full.optionColors);
      expect(restored.labels, full.labels);
      expect(restored.trueLabel, full.trueLabel);
      expect(restored.falseLabel, full.falseLabel);
      expect(restored.interpolate, full.interpolate);
      expect(restored.dateOnlyObservation, full.dateOnlyObservation);
    });

    test('an edit-then-save cycle loses nothing', () {
      // The full path the bug travelled: parse what is stored, edit one thing,
      // serialise it back.
      final stored = full.toJson();
      final edited = FieldConfig.parse(
        stored,
      ).copyWith(options: const ['changed']).toJson();
      final reloaded = FieldConfig.parse(edited);

      expect(reloaded.options, const ['changed']);
      expect(reloaded.scaleMax, 5);
      expect(reloaded.precision, 2);
      expect(reloaded.colorRamp, full.colorRamp);
    });
  });
}
