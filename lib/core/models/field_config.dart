import 'dart:convert';

import 'enums.dart';

/// Per-type configuration for a field definition, persisted as JSON in
/// `field_defs.config`.
///
/// One class covers all nine types rather than a sealed hierarchy: the config
/// is user-authored JSON that must survive round-tripping through import,
/// export, and project archives, and a permissive shape degrades better than a
/// strict one. An unrecognised key is ignored rather than fatal, so a project
/// written by a newer build still opens in an older one.
class FieldConfig {
  const FieldConfig({
    this.maxLength,
    this.pattern,
    this.min,
    this.max,
    this.precision,
    this.minDate,
    this.maxDate,
    this.options = const [],
    this.allowOther = false,
    this.scaleMin,
    this.scaleMax,
    this.colorRamp = const {},
    this.optionColors = const {},
    this.labels = const {},
    this.trueLabel,
    this.falseLabel,
    this.interpolate = true,
    this.dateOnlyObservation,
  });

  /// text
  final int? maxLength;
  final String? pattern;

  /// integer, decimal
  final num? min;
  final num? max;
  final int? precision;

  /// date, datetime. Parsed from the same `min`/`max` JSON keys as the numeric
  /// bounds -- a field has one or the other depending on its type, so sharing
  /// the key keeps the config format flat and the import/export mapping simple.
  final DateTime? minDate;
  final DateTime? maxDate;

  /// categorical, multi_select
  final List<String> options;
  final bool allowOther;

  /// rating
  final int? scaleMin;
  final int? scaleMax;

  /// Numeric value -> colour, for map colouring. Keyed by the value as a
  /// string because JSON object keys are always strings.
  final Map<String, String> colorRamp;

  /// Option -> colour, for categorical and multi-select.
  final Map<String, String> optionColors;

  /// Value -> human label, e.g. {"1": "Dead", "5": "Excellent"}.
  final Map<String, String> labels;

  /// boolean
  final String? trueLabel;
  final String? falseLabel;

  /// Whether to interpolate between colour ramp stops.
  final bool interpolate;

  /// Whether an observation of this field is recorded to the day rather than
  /// the minute (question Q7).
  ///
  /// Storage is unaffected -- `observed_at` is always full-precision UTC
  /// milliseconds. This only tells the UI to offer a date picker instead of a
  /// datetime picker, and export to render a date. Making it a display concern
  /// rather than a storage one means changing a field's mind later costs
  /// nothing and cannot lose information already recorded.
  final bool? dateOnlyObservation;

  static const empty = FieldConfig();

  /// Parses stored JSON. Returns [empty] for null, blank, or malformed input:
  /// a corrupt config should degrade to "no extra rules", not make the field
  /// unopenable.
  static FieldConfig parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      return FieldConfig.fromMap(Map<String, dynamic>.from(decoded));
    } on FormatException {
      return empty;
    }
  }

  factory FieldConfig.fromMap(Map<String, dynamic> map) {
    List<String> stringList(Object? v) => switch (v) {
      final List<dynamic> l => l.map((e) => '$e').toList(),
      _ => const [],
    };

    Map<String, String> stringMap(Object? v) => switch (v) {
      final Map<dynamic, dynamic> m => {
        for (final e in m.entries) '${e.key}': '${e.value}',
      },
      _ => const {},
    };

    int? asInt(Object? v) => switch (v) {
      final int i => i,
      final double d => d.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };

    num? asNum(Object? v) => switch (v) {
      final num n => n,
      final String s => num.tryParse(s),
      _ => null,
    };

    // Deliberately NOT normalised to UTC here. For a `date` field the bound is
    // a calendar date, and DateTime.tryParse('2026-01-01') yields local
    // midnight -- converting that to UTC moves it a day in any zone east of
    // Greenwich. The comparison in FieldValueCodec normalises both sides
    // appropriately for the field's type instead.
    DateTime? asDate(Object? v) => v is String ? DateTime.tryParse(v) : null;

    return FieldConfig(
      maxLength: asInt(map['max_length']),
      pattern: map['pattern'] as String?,
      min: asNum(map['min']),
      max: asNum(map['max']),
      precision: asInt(map['precision']),
      minDate: asDate(map['min']),
      maxDate: asDate(map['max']),
      options: stringList(map['options']),
      allowOther: map['allow_other'] == true,
      scaleMin: asInt(map['scale_min']),
      scaleMax: asInt(map['scale_max']),
      colorRamp: stringMap(map['color_ramp']),
      optionColors: stringMap(map['option_colors']),
      labels: stringMap(map['labels']),
      trueLabel: map['true_label'] as String?,
      falseLabel: map['false_label'] as String?,
      interpolate: map['interpolate'] != false,
      dateOnlyObservation: map['date_only_observation'] as bool?,
    );
  }

  Map<String, dynamic> toMap() => {
    if (maxLength != null) 'max_length': maxLength,
    if (pattern != null) 'pattern': pattern,
    // Date bounds share the min/max keys; emit whichever this field uses.
    if (minDate != null)
      'min': minDate!.toIso8601String()
    else if (min != null)
      'min': min,
    if (maxDate != null)
      'max': maxDate!.toIso8601String()
    else if (max != null)
      'max': max,
    if (precision != null) 'precision': precision,
    if (options.isNotEmpty) 'options': options,
    if (allowOther) 'allow_other': true,
    if (scaleMin != null) 'scale_min': scaleMin,
    if (scaleMax != null) 'scale_max': scaleMax,
    if (colorRamp.isNotEmpty) 'color_ramp': colorRamp,
    if (optionColors.isNotEmpty) 'option_colors': optionColors,
    if (labels.isNotEmpty) 'labels': labels,
    if (trueLabel != null) 'true_label': trueLabel,
    if (falseLabel != null) 'false_label': falseLabel,
    if (!interpolate) 'interpolate': false,
    if (dateOnlyObservation != null)
      'date_only_observation': dateOnlyObservation,
  };

  String toJson() => jsonEncode(toMap());

  /// Effective rating bounds, defaulting to the 1-5 scale in the plan.
  int get effectiveScaleMin => scaleMin ?? 1;
  int get effectiveScaleMax => scaleMax ?? 5;

  /// Whether this config is coherent for [type]. Returned messages are shown
  /// when creating or editing a field definition.
  List<String> problemsFor(FieldType type) {
    final problems = <String>[];

    if (min != null && max != null && min! > max!) {
      problems.add('Minimum ($min) is greater than maximum ($max).');
    }

    if (type.hasOptions && options.isEmpty) {
      problems.add('${type.name} fields need at least one option.');
    }

    if (options.toSet().length != options.length) {
      problems.add('Option list contains duplicates.');
    }

    if (type == FieldType.rating && effectiveScaleMin >= effectiveScaleMax) {
      problems.add(
        'Rating scale minimum ($effectiveScaleMin) must be below '
        'maximum ($effectiveScaleMax).',
      );
    }

    if (pattern != null) {
      try {
        RegExp(pattern!);
      } on FormatException {
        problems.add('Validation pattern is not a valid regular expression.');
      }
    }

    return problems;
  }
}
