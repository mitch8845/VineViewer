import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/identifier_template.dart';
import '../../core/providers.dart';

/// What each part of the plant ID is called -- `['Block', 'Row', 'Plant']` --
/// so "1.12.7" can be read out as "Block 1 · Row 12 · Plant 7".
///
/// An empty name means a part the ID format no longer knows the field for;
/// callers show the bare value.
Future<List<String>> loadPartNames(WidgetRef ref, String projectId) async {
  final template = await ref.read(labelServiceProvider).templateFor(projectId);
  final names = {
    for (final f in await ref.read(fieldDefsDaoProvider).forProject(projectId))
      f.id: f.name,
  };
  return [
    for (final part in template.parts)
      switch (part) {
        FieldPart(:final fieldDefId) => names[fieldDefId] ?? '',
        PlantPart() => 'Plant',
      },
  ];
}

/// "Block 1 · Row 12" from `['1', '12']` and the part names.
String describeParts(List<String> values, List<String> names) => [
  for (var i = 0; i < values.length; i++)
    i < names.length && names[i].isNotEmpty
        ? '${names[i]} ${values[i]}'
        : values[i],
].join(' · ');
