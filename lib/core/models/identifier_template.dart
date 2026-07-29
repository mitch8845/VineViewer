import 'dart:convert';

/// How a plant's identifier is composed.
///
/// v2 hardcoded `block.row.plant`. That is one vineyard's convention, and this
/// vineyard's own spreadsheet gives the game away: its `ID` column is not a
/// stored fact, it is `Block` + `Row` + `Plant` joined by `.`. So the shape
/// becomes data.
///
/// The parts may be container-object fields (Block, Row), attribute fields
/// (Variety, Clone), and the plant's own number -- in any order, joined by any
/// delimiter, or none at all.
library;

/// One component of an identifier.
sealed class IdPart {
  const IdPart();

  Map<String, dynamic> toMap();

  static IdPart? fromMap(Map<String, dynamic> map) {
    if (map['plant'] == true) return const PlantPart();
    final field = map['field'];
    return field is String && field.isNotEmpty ? FieldPart(field) : null;
  }
}

/// The plant's own number -- `position_idx`.
///
/// Privileged, like the plant itself: it needs no field to exist, and a project
/// that has configured nothing still has this.
class PlantPart extends IdPart {
  const PlantPart();

  @override
  Map<String, dynamic> toMap() => const {'plant': true};

  @override
  bool operator ==(Object other) => other is PlantPart;

  @override
  int get hashCode => 0;
}

/// A container object or an attribute, by field id.
class FieldPart extends IdPart {
  const FieldPart(this.fieldDefId);

  final String fieldDefId;

  @override
  Map<String, dynamic> toMap() => {'field': fieldDefId};

  @override
  bool operator ==(Object other) =>
      other is FieldPart && other.fieldDefId == fieldDefId;

  @override
  int get hashCode => fieldDefId.hashCode;
}

/// An ordered list of parts and the string between them.
class IdentifierTemplate {
  const IdentifierTemplate({required this.delimiter, required this.parts});

  /// `.`, `&`, `-`, or empty. A value containing this is refused, or the
  /// identifier stops being decomposable into the parts that built it.
  final String delimiter;

  final List<IdPart> parts;

  /// What a project uses before it has composed anything: the bare plant
  /// number.
  ///
  /// A half-configured project stays usable rather than showing nothing, which
  /// matters because the setup wizard is skippable by design.
  static const plantOnly = IdentifierTemplate(
    delimiter: '.',
    parts: [PlantPart()],
  );

  /// Every field this template names, in order, ignoring the plant part.
  List<String> get fieldIds => [
    for (final part in parts)
      if (part is FieldPart) part.fieldDefId,
  ];

  bool get isEmpty => parts.isEmpty;

  String toJson() =>
      jsonEncode({'delimiter': delimiter, 'parts': [
        for (final part in parts) part.toMap(),
      ]});

  /// Parses stored JSON, returning null for anything malformed.
  ///
  /// Null rather than throwing, and callers fall back to [plantOnly]: a corrupt
  /// template should leave a project openable with plain numbers, not
  /// unopenable.
  static IdentifierTemplate? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final rawParts = decoded['parts'];
      if (rawParts is! List) return null;

      final parts = <IdPart>[];
      for (final entry in rawParts) {
        if (entry is! Map) return null;
        final part = IdPart.fromMap(Map<String, dynamic>.from(entry));
        if (part == null) return null;
        parts.add(part);
      }
      if (parts.isEmpty) return null;

      final delimiter = decoded['delimiter'];
      return IdentifierTemplate(
        delimiter: delimiter is String ? delimiter : '.',
        parts: parts,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is IdentifierTemplate &&
      other.delimiter == delimiter &&
      other.parts.length == parts.length &&
      Iterable<int>.generate(parts.length).every(
        (i) => other.parts[i] == parts[i],
      );

  @override
  int get hashCode => Object.hash(delimiter, Object.hashAll(parts));
}

/// A rendered identifier. Replaces v2's `VineLabel`.
class PlantIdentifier {
  const PlantIdentifier({required this.parts, required this.delimiter});

  /// Already placeholder-substituted, so this never contains a hole.
  final List<String> parts;

  final String delimiter;

  String get text => parts.join(delimiter);

  @override
  String toString() => text;

  @override
  bool operator ==(Object other) =>
      other is PlantIdentifier &&
      other.delimiter == delimiter &&
      other.parts.length == parts.length &&
      Iterable<int>.generate(parts.length).every(
        (i) => other.parts[i] == parts[i],
      );

  @override
  int get hashCode => Object.hash(delimiter, Object.hashAll(parts));
}
