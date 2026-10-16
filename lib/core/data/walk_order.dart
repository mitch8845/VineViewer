import '../models/identifier_template.dart';

/// The order a walk visits plants in, when nobody has said otherwise.
///
/// Follows the identifier, part by part -- for Five Sisters that is block,
/// then row, then plant -- because the identifier is the one ordering the
/// project has already declared. Hardcoding "block then row" would be one
/// vineyard's convention again; a project addressed `Terrace.Row.Plant` gets
/// terrace order for free.
///
/// **Back and forth.** Plants are grouped by everything but the last part (a
/// row, in practice), and every other group runs backwards. Walking a row to
/// its end and then starting the next row from the end you are standing at is
/// how a vineyard is actually walked; starting every row from plant 1 would
/// mean walking each one twice. The alternation runs on across blocks, for
/// the same reason: the next block starts wherever the last row finished.
///
/// Retired plants are left out. There is nothing standing there to assess.
List<String> defaultWalkOrder(Map<String, PlantIdentifier> identifiers) {
  final living = [
    for (final e in identifiers.entries)
      if (!e.value.retired) e,
  ]..sort((a, b) => _compareParts(a.value.parts, b.value.parts));

  final order = <String>[];
  var group = <String>[];
  List<String>? groupKey;
  var reversed = false;

  void flush() {
    order.addAll(reversed ? group.reversed : group);
    reversed = !reversed;
    group = [];
  }

  for (final e in living) {
    final parts = e.value.parts;
    final key = parts.isEmpty ? parts : parts.sublist(0, parts.length - 1);
    if (groupKey != null && !_sameParts(key, groupKey)) flush();
    groupKey = key;
    group.add(e.key);
  }
  if (group.isNotEmpty) flush();
  return order;
}

bool _sameParts(List<String> a, List<String> b) {
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

/// Compares labels the way a person reads them: row 2 before row 10.
///
/// Plain string order puts "10" before "2", which would send a walk from row
/// 1 to row 10 and back. Runs of digits compare as numbers; everything else
/// compares as text, case-insensitively.
int compareNatural(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern.allMatches(a).map((m) => m[0]!).toList();
  final right = pattern.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]);
    final y = int.tryParse(right[i]);
    final c = (x != null && y != null)
        ? x.compareTo(y)
        : left[i].toLowerCase().compareTo(right[i].toLowerCase());
    if (c != 0) return c;
  }
  final byLength = left.length.compareTo(right.length);
  return byLength != 0 ? byLength : a.compareTo(b);
}
