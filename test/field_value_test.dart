import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/models/enums.dart';
import 'package:vine_viewer/core/models/field_config.dart';
import 'package:vine_viewer/core/models/field_value.dart';

/// Shorthand: the stored text for an accepted value, or fail loudly.
String? accepted(FieldValueResult r) {
  expect(r, isA<FieldValueAccepted>(), reason: '$r');
  return (r as FieldValueAccepted).stored;
}

String rejection(FieldValueResult r) {
  expect(r, isA<FieldValueRejected>(), reason: '$r');
  return (r as FieldValueRejected).message;
}

FieldValueResult encode(
  FieldType type,
  Object? input, [
  FieldConfig config = FieldConfig.empty,
]) => FieldValueCodec.encode(type: type, input: input, config: config);

void main() {
  group('clearing', () {
    test('null clears any type', () {
      for (final type in FieldType.values) {
        expect(accepted(encode(type, null)), isNull, reason: type.name);
      }
    });

    test('blank text clears any type', () {
      // A user emptying a text box produces "", which means "clear this",
      // not "store an empty string".
      for (final type in FieldType.values) {
        expect(accepted(encode(type, '   ')), isNull, reason: type.name);
      }
    });
  });

  group('text', () {
    test('stores as given', () {
      expect(
        accepted(encode(FieldType.text, 'leafroll suspected')),
        'leafroll suspected',
      );
    });

    test('enforces max length', () {
      final config = const FieldConfig(maxLength: 5);
      expect(accepted(encode(FieldType.text, '12345', config)), '12345');
      expect(
        rejection(encode(FieldType.text, '123456', config)),
        contains('5-character limit'),
      );
    });

    test('enforces a pattern', () {
      final config = const FieldConfig(pattern: r'^[A-Z]{2}\d{3}$');
      expect(accepted(encode(FieldType.text, 'AB123', config)), 'AB123');
      expect(
        rejection(encode(FieldType.text, 'nope', config)),
        contains('required format'),
      );
    });

    test('a broken pattern does not make the field unusable', () {
      // The bad regex is the definition's fault. Rejecting every value would
      // leave the user unable to enter anything, with no clue why.
      final config = const FieldConfig(pattern: '([unclosed');
      expect(accepted(encode(FieldType.text, 'anything', config)), 'anything');
    });
  });

  group('integer', () {
    test('accepts ints and integral doubles', () {
      expect(accepted(encode(FieldType.integer, 4)), '4');
      // Spreadsheet cells come back as doubles.
      expect(accepted(encode(FieldType.integer, 4.0)), '4');
      expect(accepted(encode(FieldType.integer, '4')), '4');
      expect(accepted(encode(FieldType.integer, -7)), '-7');
    });

    test('rejects fractional values with a specific message', () {
      expect(
        rejection(encode(FieldType.integer, 3.5)),
        contains('not a whole number'),
      );
      expect(
        rejection(encode(FieldType.integer, '3.5')),
        contains('not a whole number'),
      );
    });

    test('rejects non-numbers', () {
      expect(
        rejection(encode(FieldType.integer, 'four')),
        contains('not a number'),
      );
    });

    test('enforces range', () {
      final config = const FieldConfig(min: 0, max: 10);
      expect(accepted(encode(FieldType.integer, 0, config)), '0');
      expect(accepted(encode(FieldType.integer, 10, config)), '10');
      expect(
        rejection(encode(FieldType.integer, 11, config)),
        contains('above the maximum'),
      );
      expect(
        rejection(encode(FieldType.integer, -1, config)),
        contains('below the minimum'),
      );
    });
  });

  group('decimal', () {
    test('accepts numeric input', () {
      expect(accepted(encode(FieldType.decimal, 3.5)), '3.5');
      expect(accepted(encode(FieldType.decimal, '2.25')), '2.25');
      expect(accepted(encode(FieldType.decimal, 4)), '4.0');
    });

    test('applies configured precision', () {
      final config = const FieldConfig(precision: 2);
      expect(accepted(encode(FieldType.decimal, 3.14159, config)), '3.14');
    });

    test('rejects non-finite values', () {
      expect(
        rejection(encode(FieldType.decimal, double.nan)),
        contains('not a finite number'),
      );
      expect(
        rejection(encode(FieldType.decimal, double.infinity)),
        contains('not a finite number'),
      );
    });
  });

  group('boolean', () {
    test('accepts the usual spellings', () {
      for (final truthy in [true, 'true', 'YES', 'y', '1', 'T']) {
        expect(
          accepted(encode(FieldType.boolean, truthy)),
          '1',
          reason: '$truthy',
        );
      }
      for (final falsy in [false, 'false', 'No', 'n', '0', 'F']) {
        expect(
          accepted(encode(FieldType.boolean, falsy)),
          '0',
          reason: '$falsy',
        );
      }
    });

    test('accepts the field own labels, so export round-trips', () {
      final config = const FieldConfig(
        trueLabel: 'Grafted',
        falseLabel: 'Own-rooted',
      );
      expect(accepted(encode(FieldType.boolean, 'Grafted', config)), '1');
      expect(accepted(encode(FieldType.boolean, 'Own-rooted', config)), '0');
    });

    test('rejects anything else', () {
      expect(
        rejection(encode(FieldType.boolean, 'maybe')),
        contains('not a yes/no value'),
      );
    });

    test('displays using configured labels', () {
      final config = const FieldConfig(
        trueLabel: 'Grafted',
        falseLabel: 'Own-rooted',
      );
      expect(
        FieldValueCodec.display(
          type: FieldType.boolean,
          stored: '1',
          config: config,
        ),
        'Grafted',
      );
      expect(
        FieldValueCodec.display(type: FieldType.boolean, stored: '0'),
        'No',
      );
    });
  });

  group('date', () {
    test('stores date-only, dropping any time component', () {
      // Two records of the same day must compare equal. A retained time would
      // make them differ for no reason visible to the user.
      expect(accepted(encode(FieldType.date, '2026-06-15')), '2026-06-15');
      expect(
        accepted(encode(FieldType.date, '2026-06-15T14:30:00Z')),
        '2026-06-15',
      );
      expect(
        accepted(encode(FieldType.date, DateTime.utc(2026, 6, 15, 9))),
        '2026-06-15',
      );
    });

    test('datetime keeps full precision', () {
      final stored = accepted(
        encode(FieldType.datetime, DateTime.utc(2026, 6, 15, 14, 30)),
      );
      expect(stored, startsWith('2026-06-15T14:30'));
    });

    test('rejects unparseable input with guidance', () {
      final message = rejection(encode(FieldType.date, 'June 15th'));
      expect(message, contains('YYYY-MM-DD'));
    });

    test('enforces configured date bounds', () {
      final config = FieldConfig(
        minDate: DateTime.utc(2026, 1, 1),
        maxDate: DateTime.utc(2026, 12, 31),
      );
      expect(
        accepted(encode(FieldType.date, '2026-06-15', config)),
        '2026-06-15',
      );
      expect(
        rejection(encode(FieldType.date, '2025-12-31', config)),
        contains('Earlier than'),
      );
      expect(
        rejection(encode(FieldType.date, '2027-01-01', config)),
        contains('Later than'),
      );
    });
  });

  group('categorical', () {
    const config = FieldConfig(options: ['Healthy', 'Stressed', 'Dead']);

    test('accepts a listed option', () {
      expect(
        accepted(encode(FieldType.categorical, 'Stressed', config)),
        'Stressed',
      );
    });

    test('normalises case to the canonical spelling', () {
      // Spreadsheets are full of "healthy" where the list says "Healthy".
      expect(
        accepted(encode(FieldType.categorical, 'healthy', config)),
        'Healthy',
      );
      expect(accepted(encode(FieldType.categorical, 'DEAD', config)), 'Dead');
    });

    test('rejects unlisted values and names the options', () {
      final message = encode(FieldType.categorical, 'Vigorous', config);
      expect(rejection(message), contains('Healthy, Stressed, Dead'));
    });

    test('allow_other admits unlisted values', () {
      const open = FieldConfig(options: ['Healthy'], allowOther: true);
      expect(
        accepted(encode(FieldType.categorical, 'Whatever', open)),
        'Whatever',
      );
    });
  });

  group('multi-select', () {
    const config = FieldConfig(options: ['Mildew', 'Mites', 'Birds']);

    test('accepts a list', () {
      expect(
        accepted(encode(FieldType.multiSelect, ['Mildew', 'Birds'], config)),
        '["Mildew","Birds"]',
      );
    });

    test('accepts a comma-separated cell', () {
      expect(
        accepted(encode(FieldType.multiSelect, 'Mildew, Birds', config)),
        '["Mildew","Birds"]',
      );
    });

    test('accepts its own JSON output, so export round-trips', () {
      expect(
        accepted(encode(FieldType.multiSelect, '["Mites"]', config)),
        '["Mites"]',
      );
    });

    test('deduplicates', () {
      expect(
        accepted(encode(FieldType.multiSelect, 'Mildew, Mildew', config)),
        '["Mildew"]',
      );
    });

    test('rejects the whole value if any option is unlisted', () {
      // Partial acceptance would silently drop data the user believes was
      // saved.
      expect(
        rejection(encode(FieldType.multiSelect, 'Mildew, Locusts', config)),
        contains('Locusts'),
      );
    });

    test('decodes back to a list', () {
      expect(FieldValueCodec.decodeMultiSelect('["Mildew","Birds"]'), [
        'Mildew',
        'Birds',
      ]);
    });

    test('displays as a readable list', () {
      expect(
        FieldValueCodec.display(
          type: FieldType.multiSelect,
          stored: '["Mildew","Birds"]',
        ),
        'Mildew, Birds',
      );
    });
  });

  group('rating', () {
    test('defaults to a 1-5 scale', () {
      expect(accepted(encode(FieldType.rating, 3)), '3');
      expect(rejection(encode(FieldType.rating, 0)), contains('1-5'));
      expect(rejection(encode(FieldType.rating, 6)), contains('1-5'));
    });

    test('honours a configured scale', () {
      const tenPoint = FieldConfig(scaleMin: 1, scaleMax: 10);
      expect(accepted(encode(FieldType.rating, 9, tenPoint)), '9');
      expect(
        rejection(encode(FieldType.rating, 11, tenPoint)),
        contains('1-10'),
      );
    });

    test('rejects fractional ratings', () {
      expect(
        rejection(encode(FieldType.rating, 3.5)),
        contains('not a whole number'),
      );
    });

    test('displays a configured label', () {
      const config = FieldConfig(labels: {'1': 'Dead', '5': 'Excellent'});
      expect(
        FieldValueCodec.display(
          type: FieldType.rating,
          stored: '5',
          config: config,
        ),
        'Excellent',
      );
      // Unlabelled values fall back to the number.
      expect(
        FieldValueCodec.display(
          type: FieldType.rating,
          stored: '3',
          config: config,
        ),
        '3',
      );
    });
  });

  group('config round-tripping', () {
    test('survives a JSON round trip', () {
      const original = FieldConfig(
        options: ['A', 'B'],
        scaleMin: 1,
        scaleMax: 10,
        colorRamp: {'1': '#d32f2f', '10': '#388e3c'},
        labels: {'1': 'Dead'},
        allowOther: true,
        interpolate: false,
      );

      final restored = FieldConfig.parse(original.toJson());

      expect(restored.options, ['A', 'B']);
      expect(restored.scaleMax, 10);
      expect(restored.colorRamp['1'], '#d32f2f');
      expect(restored.labels['1'], 'Dead');
      expect(restored.allowOther, isTrue);
      expect(restored.interpolate, isFalse);
    });

    test('date bounds round-trip through the shared min/max keys', () {
      final original = FieldConfig(
        minDate: DateTime.utc(2020, 1, 1),
        maxDate: DateTime.utc(2030, 1, 1),
      );
      final restored = FieldConfig.parse(original.toJson());
      expect(restored.minDate, DateTime.utc(2020, 1, 1));
      expect(restored.maxDate, DateTime.utc(2030, 1, 1));
    });

    test('malformed config degrades to empty rather than throwing', () {
      // A corrupt config should not make the field unopenable.
      expect(FieldConfig.parse('not json').options, isEmpty);
      expect(FieldConfig.parse('[1,2,3]').options, isEmpty);
      expect(FieldConfig.parse(null).options, isEmpty);
      expect(FieldConfig.parse('').options, isEmpty);
    });

    test(
      'unknown keys are ignored, so newer projects open in older builds',
      () {
        final config = FieldConfig.parse('{"options":["A"],"future_key":42}');
        expect(config.options, ['A']);
      },
    );
  });

  group('config validation', () {
    test('flags an inverted range', () {
      expect(
        const FieldConfig(min: 10, max: 1).problemsFor(FieldType.integer),
        contains(contains('greater than maximum')),
      );
    });

    test('flags option lists that are empty or duplicated', () {
      expect(
        const FieldConfig().problemsFor(FieldType.categorical),
        contains(contains('need at least one option')),
      );
      expect(
        const FieldConfig(
          options: ['A', 'A'],
        ).problemsFor(FieldType.categorical),
        contains(contains('duplicates')),
      );
    });

    test('flags an inverted rating scale', () {
      expect(
        const FieldConfig(
          scaleMin: 5,
          scaleMax: 1,
        ).problemsFor(FieldType.rating),
        contains(contains('must be below')),
      );
    });

    test('flags an invalid regular expression', () {
      expect(
        const FieldConfig(pattern: '([unclosed').problemsFor(FieldType.text),
        contains(contains('not a valid regular expression')),
      );
    });

    test('a sane config has no problems', () {
      expect(
        const FieldConfig(
          options: ['A', 'B'],
        ).problemsFor(FieldType.categorical),
        isEmpty,
      );
    });
  });
}
