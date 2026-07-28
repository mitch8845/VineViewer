import 'dart:convert';

import 'enums.dart';
import 'field_config.dart';

/// Outcome of validating a value against a field definition.
///
/// Modelled as a result rather than an exception because the busiest caller is
/// the XLSX importer, where a bad cell must be reported and skipped without
/// aborting the other 3,999 rows (plan section 7.1). Exceptions would push
/// every caller into try/catch around a loop.
sealed class FieldValueResult {
  const FieldValueResult();

  bool get isAccepted => this is FieldValueAccepted;
}

/// The value passed validation. [stored] is what goes in `field_events.value`;
/// null means the field was explicitly cleared.
class FieldValueAccepted extends FieldValueResult {
  const FieldValueAccepted(this.stored);
  final String? stored;

  @override
  String toString() => 'Accepted(${stored ?? 'cleared'})';
}

/// The value failed validation. [message] is user-facing and names the field's
/// rule, so an import report reads like "health: 7 is above the maximum of 5"
/// rather than "invalid value".
class FieldValueRejected extends FieldValueResult {
  const FieldValueRejected(this.message);
  final String message;

  @override
  String toString() => 'Rejected($message)';
}

/// Converts between user input, stored text, and typed values.
///
/// Everything is stored as TEXT (plan section 5.3). SQLite would happily store
/// mixed types in one column, but the event log holds values for every field
/// type in a single `value` column -- a uniform text encoding is what keeps
/// export, import, and future sync from having to know each row's type before
/// they can read it.
abstract final class FieldValueCodec {
  /// Validates [input] against [type] and [config], returning the text to
  /// store.
  ///
  /// A null or blank input is accepted as **cleared** (stored null). Callers
  /// that must distinguish "leave alone" from "clear" -- notably the importer,
  /// where an empty cell means no event at all -- check for that before
  /// calling.
  static FieldValueResult encode({
    required FieldType type,
    required Object? input,
    FieldConfig config = FieldConfig.empty,
  }) {
    if (input == null) return const FieldValueAccepted(null);
    if (input is String && input.trim().isEmpty) {
      return const FieldValueAccepted(null);
    }

    return switch (type) {
      FieldType.text => _text(input, config),
      FieldType.integer => _integer(input, config),
      FieldType.decimal => _decimal(input, config),
      FieldType.boolean => _boolean(input, config),
      FieldType.date => _date(input, config, dateOnly: true),
      FieldType.datetime => _date(input, config, dateOnly: false),
      FieldType.categorical => _categorical(input, config),
      FieldType.multiSelect => _multiSelect(input, config),
      FieldType.rating => _rating(input, config),
    };
  }

  /// Renders a stored value for display, applying configured labels.
  ///
  /// Returns null when nothing is recorded, so the caller decides how to show
  /// an absent value.
  static String? display({
    required FieldType type,
    required String? stored,
    FieldConfig config = FieldConfig.empty,
  }) {
    if (stored == null) return null;

    return switch (type) {
      FieldType.boolean =>
        stored == '1'
            ? (config.trueLabel ?? 'Yes')
            : (config.falseLabel ?? 'No'),
      FieldType.rating || FieldType.integer => config.labels[stored] ?? stored,
      FieldType.multiSelect => _decodeList(stored)?.join(', ') ?? stored,
      _ => stored,
    };
  }

  /// Parses a stored multi-select value back into its options.
  static List<String>? decodeMultiSelect(String? stored) =>
      stored == null ? null : _decodeList(stored);

  static List<String>? _decodeList(String stored) {
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) return decoded.map((e) => '$e').toList();
    } on FormatException {
      // Fall through -- a hand-edited archive could contain anything.
    }
    return null;
  }

  // ---------------------------------------------------------------- per type

  static FieldValueResult _text(Object input, FieldConfig config) {
    final value = '$input';

    if (config.maxLength != null && value.length > config.maxLength!) {
      return FieldValueRejected(
        'Longer than the ${config.maxLength}-character limit '
        '(${value.length} characters).',
      );
    }

    if (config.pattern != null) {
      final RegExp regex;
      try {
        regex = RegExp(config.pattern!);
      } on FormatException {
        // A broken pattern is the field definition's fault, not the value's.
        // Rejecting every value would make the field unusable with no way to
        // tell why from the data-entry screen.
        return FieldValueAccepted(value);
      }
      if (!regex.hasMatch(value)) {
        return FieldValueRejected('Does not match the required format.');
      }
    }

    return FieldValueAccepted(value);
  }

  static FieldValueResult _integer(Object input, FieldConfig config) {
    final int value;
    switch (input) {
      case final int i:
        value = i;
      case final double d when d == d.roundToDouble():
        // Spreadsheets hand back 4.0 for a cell showing 4.
        value = d.toInt();
      case final double d:
        return FieldValueRejected('$d is not a whole number.');
      default:
        final parsed = int.tryParse('$input'.trim());
        if (parsed == null) {
          final asDouble = double.tryParse('$input'.trim());
          if (asDouble != null) {
            return FieldValueRejected('$input is not a whole number.');
          }
          return FieldValueRejected('$input is not a number.');
        }
        value = parsed;
    }

    final rangeError = _checkRange(value, config);
    if (rangeError != null) return FieldValueRejected(rangeError);

    return FieldValueAccepted('$value');
  }

  static FieldValueResult _decimal(Object input, FieldConfig config) {
    final double value;
    if (input is num) {
      value = input.toDouble();
    } else {
      final parsed = double.tryParse('$input'.trim());
      if (parsed == null) return FieldValueRejected('$input is not a number.');
      value = parsed;
    }

    if (value.isNaN || value.isInfinite) {
      return FieldValueRejected('$input is not a finite number.');
    }

    final rangeError = _checkRange(value, config);
    if (rangeError != null) return FieldValueRejected(rangeError);

    final rounded = config.precision != null
        ? double.parse(value.toStringAsFixed(config.precision!))
        : value;

    return FieldValueAccepted('$rounded');
  }

  static String? _checkRange(num value, FieldConfig config) {
    if (config.min != null && value < config.min!) {
      return '$value is below the minimum of ${config.min}.';
    }
    if (config.max != null && value > config.max!) {
      return '$value is above the maximum of ${config.max}.';
    }
    return null;
  }

  static FieldValueResult _boolean(Object input, FieldConfig config) {
    if (input is bool) return FieldValueAccepted(input ? '1' : '0');

    final text = '$input'.trim().toLowerCase();
    const truthy = {'1', 'true', 'yes', 'y', 't'};
    const falsy = {'0', 'false', 'no', 'n', 'f'};

    // Also accept whatever labels the field itself displays, so exporting and
    // re-importing a boolean column round-trips.
    if (truthy.contains(text) || text == config.trueLabel?.toLowerCase()) {
      return const FieldValueAccepted('1');
    }
    if (falsy.contains(text) || text == config.falseLabel?.toLowerCase()) {
      return const FieldValueAccepted('0');
    }

    return FieldValueRejected('$input is not a yes/no value.');
  }

  static FieldValueResult _date(
    Object input,
    FieldConfig config, {
    required bool dateOnly,
  }) {
    DateTime? parsed;
    if (input is DateTime) {
      parsed = input;
    } else {
      parsed = DateTime.tryParse('$input'.trim());
    }

    if (parsed == null) {
      return FieldValueRejected(
        '$input is not a valid ${dateOnly ? 'date' : 'date and time'}. '
        'Use YYYY-MM-DD${dateOnly ? '' : ' HH:MM'}.',
      );
    }

    final utc = parsed.isUtc ? parsed : parsed.toUtc();

    if (config.minDate != null && utc.isBefore(config.minDate!)) {
      return FieldValueRejected(
        'Earlier than the allowed minimum of '
        '${_render(config.minDate!, dateOnly: dateOnly)}.',
      );
    }
    if (config.maxDate != null && utc.isAfter(config.maxDate!)) {
      return FieldValueRejected(
        'Later than the allowed maximum of '
        '${_render(config.maxDate!, dateOnly: dateOnly)}.',
      );
    }

    return FieldValueAccepted(_render(utc, dateOnly: dateOnly));
  }

  static String _render(DateTime value, {required bool dateOnly}) {
    final iso = value.toUtc().toIso8601String();
    // Date fields store only the day: keeping a time component would make two
    // records of the same day compare unequal for no reason the user can see.
    return dateOnly ? iso.substring(0, 10) : iso;
  }

  static FieldValueResult _categorical(Object input, FieldConfig config) {
    final value = '$input'.trim();

    if (config.options.contains(value)) return FieldValueAccepted(value);

    // Case-insensitive match, then store the canonical spelling. Spreadsheets
    // are full of "healthy" where the option list says "Healthy", and
    // rejecting those makes import needlessly painful.
    final canonical = config.options.firstWhere(
      (o) => o.toLowerCase() == value.toLowerCase(),
      orElse: () => '',
    );
    if (canonical.isNotEmpty) return FieldValueAccepted(canonical);

    if (config.allowOther) return FieldValueAccepted(value);

    return FieldValueRejected(
      '"$value" is not one of: ${config.options.join(', ')}.',
    );
  }

  static FieldValueResult _multiSelect(Object input, FieldConfig config) {
    final List<String> values;
    if (input is List) {
      values = input.map((e) => '$e'.trim()).toList();
    } else {
      final text = '$input'.trim();
      final asList = _decodeList(text);
      // Accept both a JSON array and a comma-separated cell.
      values = (asList ?? text.split(','))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    if (values.isEmpty) return const FieldValueAccepted(null);

    final canonical = <String>[];
    for (final value in values) {
      final result = _categorical(value, config);
      switch (result) {
        case FieldValueAccepted(:final stored) when stored != null:
          if (!canonical.contains(stored)) canonical.add(stored);
        case FieldValueRejected(:final message):
          return FieldValueRejected(message);
        case _:
          continue;
      }
    }

    return FieldValueAccepted(jsonEncode(canonical));
  }

  static FieldValueResult _rating(Object input, FieldConfig config) {
    final asInt = _integer(input, FieldConfig.empty);
    if (asInt is FieldValueRejected) return asInt;

    final value = int.parse((asInt as FieldValueAccepted).stored!);
    final min = config.effectiveScaleMin;
    final max = config.effectiveScaleMax;

    if (value < min || value > max) {
      return FieldValueRejected('$value is outside the $min-$max scale.');
    }

    return FieldValueAccepted('$value');
  }
}
