import 'dart:convert';

import '../models/identifier_template.dart';
import 'walk_order.dart';

/// A stretch of the walk: one block, one piece of a row, or one plant.
///
/// [start] and [end] index into [WalkPlan.order], end exclusive. Sections are
/// derived from the order every time rather than stored -- the order is the
/// only truth, and a stored section list would be a second one to disagree
/// with it.
typedef WalkSection = ({int start, int end, List<String> key});

/// How deep a section goes into the plant ID.
enum WalkLevel { blocks, rows, plants }

/// A walking order: every living plant, in sequence, with some switched off.
///
/// Immutable. Every edit returns a new plan, which is what makes the editor's
/// own undo a list of plans and nothing more.
class WalkPlan {
  WalkPlan({
    required List<String> order,
    Set<String> excluded = const {},
    Set<String> breaks = const {},
  }) : order = List.unmodifiable(order),
       excluded = Set.unmodifiable(excluded),
       breaks = Set.unmodifiable(breaks);

  final List<String> order;

  /// Plants the walk passes over.
  final Set<String> excluded;

  /// Plants that start a new section although the plant before them is in the
  /// same row: the cuts in a row that has been split.
  final Set<String> breaks;

  /// Plant ID order, back and forth -- what a field walks before anyone has
  /// arranged it.
  factory WalkPlan.standard(Map<String, PlantIdentifier> identifiers) =>
      WalkPlan(order: defaultWalkOrder(identifiers));

  /// The plants to visit, in order.
  List<String> get walk => [
    for (final id in order)
      if (!excluded.contains(id)) id,
  ];

  // ------------------------------------------------------------ persistence

  String get orderJson => jsonEncode(order);
  String get excludedJson => jsonEncode(excluded.toList());
  String get breaksJson => jsonEncode(breaks.toList());

  static WalkPlan? fromJson({
    required String order,
    required String excluded,
    required String breaks,
  }) {
    try {
      List<String> list(String s) =>
          (jsonDecode(s) as List).map((e) => '$e').toList();
      return WalkPlan(
        order: list(order),
        excluded: list(excluded).toSet(),
        breaks: list(breaks).toSet(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Brings a saved plan up to date with the plants that exist now.
  ///
  /// Plants that are gone drop out. A plant that is new since the plan was
  /// saved goes in **beside its neighbour** -- after the plant before it in
  /// plant ID order -- so a replant in row 12 is walked in row 12, not
  /// tacked onto the end of the vineyard.
  WalkPlan reconcile(Map<String, PlantIdentifier> identifiers) {
    final standard = defaultWalkOrder(identifiers);
    final living = standard.toSet();
    final kept = [
      for (final id in order)
        if (living.contains(id)) id,
    ];
    final present = kept.toSet();
    if (present.length == living.length) {
      return WalkPlan(
        order: kept,
        excluded: excluded.intersection(living),
        breaks: breaks.intersection(living),
      );
    }

    // Natural order, not the back-and-forth one, decides who the neighbour
    // is: plant 6's neighbour is plant 5 whichever way row 12 is walked.
    final natural = [...standard]
      ..sort(
        (a, b) => _compareParts(identifiers[a]!.parts, identifiers[b]!.parts),
      );
    final result = [...kept];
    for (var i = 0; i < natural.length; i++) {
      final id = natural[i];
      if (present.contains(id)) continue;
      final before = i > 0 ? natural[i - 1] : null;
      final at = before == null ? -1 : result.indexOf(before);
      result.insert(at + 1, id);
      present.add(id);
    }
    return WalkPlan(
      order: result,
      excluded: excluded.intersection(living),
      breaks: breaks.intersection(living),
    );
  }

  // ---------------------------------------------------------------- reading

  /// The sections at [level]: consecutive plants sharing a block, a row, or
  /// (for plants) nothing.
  ///
  /// A block or row that the order visits twice -- row 12 split, half walked
  /// now and half later -- is two sections, because that is two separate
  /// stretches of walking.
  List<WalkSection> sections(
    WalkLevel level,
    Map<String, PlantIdentifier> identifiers,
  ) {
    List<String> keyOf(String id) {
      final parts = identifiers[id]?.parts ?? const <String>[];
      final depth = switch (level) {
        WalkLevel.blocks => parts.length > 2 ? 1 : 0,
        WalkLevel.rows => parts.isEmpty ? 0 : parts.length - 1,
        WalkLevel.plants => parts.length,
      };
      return parts.sublist(0, depth);
    }

    final out = <WalkSection>[];
    var start = 0;
    List<String>? key;
    for (var i = 0; i < order.length; i++) {
      final k = keyOf(order[i]);
      final cut =
          level == WalkLevel.plants ||
          key == null ||
          !_same(k, key) ||
          (level == WalkLevel.rows && breaks.contains(order[i]));
      if (cut && key != null) {
        out.add((start: start, end: i, key: key));
        start = i;
      }
      key = k;
    }
    if (key != null) out.add((start: start, end: order.length, key: key));
    return out;
  }

  // ---------------------------------------------------------------- editing

  /// Moves the plants in [ranges] (each a section's start and end) so they
  /// sit immediately before order index [before], keeping their own order.
  ///
  /// Index [before] is in the plan as it stands, and may be the length of the
  /// order to move to the end.
  WalkPlan move(
    List<(int, int)> ranges,
    int before,
    Map<String, PlantIdentifier> identifiers,
  ) {
    final picked = <int>{
      for (final (s, e) in ranges)
        for (var i = s; i < e; i++) i,
    };
    final moving = [
      for (var i = 0; i < order.length; i++)
        if (picked.contains(i)) order[i],
    ];
    final rest = <String>[];
    var insertAt = 0;
    for (var i = 0; i < order.length; i++) {
      if (i == before) insertAt = rest.length;
      if (!picked.contains(i)) rest.add(order[i]);
    }
    if (before >= order.length) insertAt = rest.length;

    final next = [...rest]..insertAll(insertAt, moving);
    final newBreaks = {...breaks};
    // Each moved range stays its own stretch where it lands, even beside
    // another piece of the same row.
    for (final (s, e) in ranges) {
      final first = order[s];
      final last = order[e - 1];
      final at = next.indexOf(first);
      final end = next.indexOf(last) + 1;
      _cut(next, newBreaks, at, identifiers);
      _cut(next, newBreaks, end, identifiers);
    }
    return WalkPlan(order: next, excluded: excluded, breaks: newBreaks);
  }

  /// Reverses one stretch: a row piece walked from the other end.
  WalkPlan flip(int start, int end, Map<String, PlantIdentifier> identifiers) {
    final next = [...order];
    final reversed = next.sublist(start, end).reversed.toList();
    next.replaceRange(start, end, reversed);
    final newBreaks = {...breaks}..removeAll(reversed);
    _cut(next, newBreaks, start, identifiers);
    _cut(next, newBreaks, end, identifiers);
    return WalkPlan(order: next, excluded: excluded, breaks: newBreaks);
  }

  /// Switches plants on or off.
  WalkPlan include(Iterable<String> plantIds, bool on) => WalkPlan(
    order: order,
    excluded: on
        ? ({...excluded}..removeAll(plantIds))
        : ({...excluded, ...plantIds}),
    breaks: breaks,
  );

  /// Cuts a row in two before order index [at].
  WalkPlan split(int at) => at <= 0 || at >= order.length
      ? this
      : WalkPlan(
          order: order,
          excluded: excluded,
          breaks: {...breaks, order[at]},
        );

  /// Undoes a [split] at order index [at]: the stretch joins the one before.
  WalkPlan join(int at) => at <= 0 || at >= order.length
      ? this
      : WalkPlan(
          order: order,
          excluded: excluded,
          breaks: {...breaks}..remove(order[at]),
        );

  /// Marks order index [at] as the start of a stretch if the plant before it
  /// is in the same row -- otherwise the two would read as one.
  static void _cut(
    List<String> order,
    Set<String> breaks,
    int at,
    Map<String, PlantIdentifier> identifiers,
  ) {
    if (at <= 0 || at >= order.length) return;
    List<String> row(String id) {
      final parts = identifiers[id]?.parts ?? const <String>[];
      return parts.isEmpty ? parts : parts.sublist(0, parts.length - 1);
    }

    if (_same(row(order[at]), row(order[at - 1]))) breaks.add(order[at]);
  }
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _compareParts(List<String> a, List<String> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final c = compareNatural(a[i], b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}
