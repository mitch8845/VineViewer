import 'dart:ui';

import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';

/// One row of the map legend.
typedef LegendEntry = ({String label, Color color});

/// Per-plant colours for one field, and the legend that explains them.
class PlantColouring {
  const PlantColouring({
    required this.fieldName,
    required this.colors,
    required this.legend,
  });

  final String fieldName;
  final Map<String, Color> colors;
  final List<LegendEntry> legend;

  /// Plants with nothing recorded. Grey rather than the default green, so a gap
  /// in the survey is visible as a gap rather than passing for a healthy plant.
  static const noValue = Color(0xFFB0B0B0);

  /// Builds the colouring from each plant's current stored value.
  ///
  /// Pure, so the mapping from value to colour is testable without a canvas or
  /// a database -- the parts most likely to be subtly wrong are the ramps.
  static PlantColouring build({
    required FieldDef field,
    required FieldConfig config,
    required Map<String, String?> values,
  }) {
    final present = {
      for (final e in values.entries)
        if (e.value != null) e.key: e.value!,
    };
    final colouring = switch (field.type) {
      FieldType.boolean => _boolean(present, config),
      FieldType.categorical || FieldType.multiSelect => _options(
        present,
        config,
        multi: field.type == FieldType.multiSelect,
      ),
      FieldType.rating => _numeric(
        present,
        config,
        lo: config.effectiveScaleMin.toDouble(),
        hi: config.effectiveScaleMax.toDouble(),
        labelOf: (v) {
          final key = '${v.round()}';
          final label = config.labels[key];
          return label == null ? key : '$key  $label';
        },
        steps: config.effectiveScaleMax - config.effectiveScaleMin + 1,
      ),
      FieldType.integer || FieldType.decimal => _numeric(
        present,
        config,
        lo: config.min?.toDouble(),
        hi: config.max?.toDouble(),
        labelOf: (v) =>
            field.type == FieldType.integer ? '${v.round()}' : _trim(v),
      ),
      FieldType.date || FieldType.datetime => _dates(present),
      FieldType.text => _categories(present.values.toSet().toList()..sort(), {
        for (final e in present.entries) e.key: e.value,
      }),
    };

    final hasGaps = values.length > present.length;
    return PlantColouring(
      fieldName: field.name,
      colors: colouring.colors,
      legend: [
        ...colouring.legend,
        if (hasGaps) (label: 'Not recorded', color: noValue),
      ],
    );
  }

  /// Distinct, colour-blind-tolerable hues for unordered categories (the Tol
  /// "muted" set). Ordered so the first few are the most distinguishable,
  /// since most fields have only a handful of options.
  static const palette = [
    Color(0xFF332288),
    Color(0xFF117733),
    Color(0xFFDDCC77),
    Color(0xFFCC6677),
    Color(0xFF88CCEE),
    Color(0xFF882255),
    Color(0xFF44AA99),
    Color(0xFF999933),
    Color(0xFFAA4499),
    Color(0xFF6699CC),
  ];

  /// Low-to-high ramp for ordered values: poor reads red, good reads green,
  /// which is how every health and vigour scale in the vineyard runs.
  static const _ramp = [
    Color(0xFFD7191C),
    Color(0xFFFDAE61),
    Color(0xFF1A9641),
  ];

  static Color _rampAt(double t) {
    final c = t.clamp(0.0, 1.0);
    return c < 0.5
        ? Color.lerp(_ramp[0], _ramp[1], c * 2)!
        : Color.lerp(_ramp[1], _ramp[2], (c - 0.5) * 2)!;
  }

  static _Partial _boolean(Map<String, String> present, FieldConfig config) {
    const yes = Color(0xFF1A9641);
    const no = Color(0xFFD7191C);
    return _Partial(
      colors: {
        for (final e in present.entries) e.key: e.value == '1' ? yes : no,
      },
      legend: [
        (label: config.trueLabel ?? 'Yes', color: yes),
        (label: config.falseLabel ?? 'No', color: no),
      ],
    );
  }

  static _Partial _options(
    Map<String, String> present,
    FieldConfig config, {
    required bool multi,
  }) {
    // A multi-select plant is coloured by its first ticked option. Blending
    // would produce colours that mean nothing; first-ticked is at least
    // predictable, and the inspector shows the rest.
    final valueOf = <String, String>{
      for (final e in present.entries)
        e.key: multi
            ? (FieldValueCodec.decodeMultiSelect(e.value)?.firstOrNull ?? '')
            : e.value,
    }..removeWhere((_, v) => v.isEmpty);

    final order = [
      ...config.options,
      // Values entered under "allow other", after the configured ones.
      ...({...valueOf.values}.difference(config.options.toSet()).toList()
        ..sort()),
    ];
    final custom = {
      for (final o in order) o: ?_parseHex(config.optionColors[o]),
    };
    return _categories(order, valueOf, custom: custom);
  }

  static _Partial _categories(
    List<String> order,
    Map<String, String> valueOf, {
    Map<String, Color> custom = const {},
  }) {
    // Past the palette, everything shares one "other" colour rather than the
    // palette repeating -- two categories in the same colour would be read as
    // the same category.
    const other = Color(0xFF5F5F5F);
    final colourOf = <String, Color>{};
    var next = 0;
    for (final value in order) {
      colourOf[value] =
          custom[value] ?? (next < palette.length ? palette[next++] : other);
    }

    final used = valueOf.values.toSet();
    final legend = <LegendEntry>[];
    var folded = false;
    for (final value in order) {
      if (!used.contains(value) && !custom.containsKey(value)) continue;
      if (colourOf[value] == other && !custom.containsKey(value)) {
        folded = true;
        continue;
      }
      legend.add((label: value, color: colourOf[value]!));
    }
    if (folded) legend.add((label: 'Other', color: other));

    return _Partial(
      colors: {for (final e in valueOf.entries) e.key: colourOf[e.value]!},
      legend: legend,
    );
  }

  static _Partial _numeric(
    Map<String, String> present,
    FieldConfig config, {
    double? lo,
    double? hi,
    required String Function(double) labelOf,
    int steps = 5,
  }) {
    final parsed = <String, double>{
      for (final e in present.entries) e.key: ?double.tryParse(e.value),
    };

    // A configured colour ramp wins outright: the user said what 3 looks like.
    final stops = <(double, Color)>[
      for (final e in config.colorRamp.entries)
        if ((double.tryParse(e.key), _parseHex(e.value)) case (
          final v?,
          final c?,
        ))
          (v, c),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    if (stops.isNotEmpty) {
      Color at(double v) {
        if (v <= stops.first.$1) return stops.first.$2;
        if (v >= stops.last.$1) return stops.last.$2;
        for (var i = 1; i < stops.length; i++) {
          final (v1, c1) = stops[i];
          if (v <= v1) {
            final (v0, c0) = stops[i - 1];
            if (!config.interpolate) return c0;
            return Color.lerp(c0, c1, (v - v0) / (v1 - v0))!;
          }
        }
        return stops.last.$2;
      }

      return _Partial(
        colors: {for (final e in parsed.entries) e.key: at(e.value)},
        legend: [for (final (v, c) in stops) (label: labelOf(v), color: c)],
      );
    }

    // Otherwise the configured bounds, or the observed spread when there are
    // none -- a ramp from 0 to infinity would paint every plant the same red.
    final values = parsed.values;
    final min = lo ?? (values.isEmpty ? 0.0 : values.reduce(_min));
    final max = hi ?? (values.isEmpty ? 1.0 : values.reduce(_max));
    final span = max - min;
    double t(double v) => span <= 0 ? 1.0 : (v - min) / span;

    final legendSteps = steps.clamp(2, 7);
    return _Partial(
      colors: {for (final e in parsed.entries) e.key: _rampAt(t(e.value))},
      legend: [
        for (var i = legendSteps - 1; i >= 0; i--)
          (
            label: labelOf(min + span * i / (legendSteps - 1)),
            color: _rampAt(i / (legendSteps - 1)),
          ),
      ],
    );
  }

  /// Dates on a cool-to-warm ramp, oldest blue and newest orange. Neither end
  /// is "bad", so the red-green ramp would suggest a judgement that is not
  /// there.
  static _Partial _dates(Map<String, String> present) {
    const old = Color(0xFF2C7BB6);
    const recent = Color(0xFFF46D43);
    final parsed = <String, DateTime>{
      for (final e in present.entries) e.key: ?DateTime.tryParse(e.value),
    };
    if (parsed.isEmpty) return const _Partial(colors: {}, legend: []);

    final ms = parsed.values.map((d) => d.millisecondsSinceEpoch);
    final first = ms.reduce((a, b) => a < b ? a : b);
    final last = ms.reduce((a, b) => a > b ? a : b);
    final span = last - first;
    Color at(DateTime d) => span == 0
        ? recent
        : Color.lerp(old, recent, (d.millisecondsSinceEpoch - first) / span)!;

    String day(int msSinceEpoch) {
      final d = DateTime.fromMillisecondsSinceEpoch(msSinceEpoch);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    return _Partial(
      colors: {for (final e in parsed.entries) e.key: at(e.value)},
      legend: [
        (label: day(last), color: recent),
        if (span > 0) (label: day(first), color: old),
      ],
    );
  }

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;

  static String _trim(double v) {
    final s = v.toStringAsFixed(2);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
  }
}

class _Partial {
  const _Partial({required this.colors, required this.legend});
  final Map<String, Color> colors;
  final List<LegendEntry> legend;
}

Color? _parseHex(String? hex) {
  if (hex == null) return null;
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}
