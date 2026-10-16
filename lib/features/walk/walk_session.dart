import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where a walk is, and what it has recorded so far.
///
/// Pure bookkeeping -- no database, no widgets. The screen writes each value
/// through the operation recorder and then tells this what happened, so the
/// rule for when to move on lives in one testable place.
class WalkSession {
  WalkSession({required this.order, required this.fieldIds, int index = 0})
    : _index = index.clamp(0, order.length);

  /// Plant ids, in walking order.
  final List<String> order;

  /// The fields being entered, in the order they are shown.
  final List<String> fieldIds;

  int _index;

  /// Position in [order]. Equal to its length once the walk is finished.
  int get index => _index;

  /// Fields given a value at the current plant on this visit.
  final Set<String> _enteredHere = {};

  /// Every value recorded on this walk, oldest first: what undo walks back
  /// through.
  final List<({int index, String fieldId})> _taps = [];

  bool get finished => _index >= order.length;

  String? get current => finished ? null : order[_index];

  Set<String> get enteredHere => Set.unmodifiable(_enteredHere);

  int get recordedCount => _taps.length;

  bool get canUndo => _taps.isNotEmpty;

  /// Notes a value recorded at the current plant. Returns whether the walk
  /// moved on.
  ///
  /// **It moves on as soon as every field has a value here** -- so a walk of
  /// one field is one tap per plant, which is the entire point of the tool.
  /// With several fields it waits for the rest, or for [next].
  bool recorded(String fieldId) {
    if (finished) return false;
    _taps.add((index: _index, fieldId: fieldId));
    _enteredHere.add(fieldId);
    if (fieldIds.every(_enteredHere.contains)) {
      next();
      return true;
    }
    return false;
  }

  /// On to the next plant, whatever is or is not entered here.
  void next() {
    if (finished) return;
    _index++;
    _enteredHere.clear();
  }

  /// Back one plant, recording nothing and undoing nothing.
  void back() {
    if (_index == 0) return;
    _index--;
    _enteredHere.clear();
  }

  /// Returns to the plant the most recent value was recorded on, and forgets
  /// it. The caller undoes the write itself; this only puts the walk back
  /// where that write was made, so the next tap re-enters it.
  ({int index, String fieldId})? undo() {
    if (_taps.isEmpty) return null;
    final tap = _taps.removeLast();
    _index = tap.index;
    _enteredHere
      ..clear()
      ..addAll([
        for (final t in _taps)
          if (t.index == tap.index) t.fieldId,
      ]);
    return tap;
  }
}

/// A walk to pick up again: which fields, which plants, and where it stopped.
///
/// Kept per project in a small file rather than the database. It is a
/// bookmark on this device, not vineyard data -- nothing about it belongs in
/// the undo journal or in a future sync.
class WalkBookmark {
  const WalkBookmark({
    required this.fieldIds,
    required this.plantId,
    required this.index,
    this.subset,
    this.orderId,
  });

  final List<String> fieldIds;

  /// The plant to resume at. Looked up in the rebuilt order rather than
  /// trusting [index], since plants may have been added or retired since.
  final String? plantId;

  /// Where it was, for when [plantId] is no longer in the walk.
  final int index;

  /// The plants the walk was limited to, or null for every plant.
  final List<String>? subset;

  /// The saved walk order it followed, or null for plant ID order.
  final String? orderId;

  Map<String, dynamic> toJson() => {
    'fields': fieldIds,
    'plant': plantId,
    'index': index,
    if (subset != null) 'subset': subset,
    if (orderId != null) 'order': orderId,
  };

  static WalkBookmark? fromJson(Object? json) {
    if (json is! Map) return null;
    final fields = json['fields'];
    if (fields is! List || fields.isEmpty) return null;
    final subset = json['subset'];
    return WalkBookmark(
      fieldIds: fields.map((f) => '$f').toList(),
      plantId: json['plant'] as String?,
      index: (json['index'] as num?)?.toInt() ?? 0,
      subset: subset is List ? subset.map((p) => '$p').toList() : null,
      orderId: json['order'] as String?,
    );
  }

  /// Where to start in [order]: the bookmarked plant if it is still there.
  int resumeIndex(List<String> order) {
    final at = plantId == null ? -1 : order.indexOf(plantId!);
    return at >= 0 ? at : index.clamp(0, order.length);
  }
}

/// Reads and writes [WalkBookmark]s.
///
/// Every failure reads as "no bookmark": losing your place is an
/// inconvenience, and must never stop a walk from starting.
class WalkBookmarks {
  WalkBookmarks({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file(String projectId) async =>
      File('${(await _directory()).path}/walks/$projectId.json');

  Future<WalkBookmark?> load(String projectId) async {
    try {
      final file = await _file(projectId);
      if (!file.existsSync()) return null;
      return WalkBookmark.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String projectId, WalkBookmark bookmark) async {
    try {
      final file = await _file(projectId);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(bookmark.toJson()), flush: true);
    } catch (_) {
      // See the class comment.
    }
  }

  Future<File> _lastOrderFile(String projectId) async =>
      File('${(await _directory()).path}/walks/$projectId.order');

  /// The walk order chosen last time, offered first next time: an order
  /// arranged by hand is the one you walk, walk after walk. Empty for plant
  /// ID order, null if nothing has been chosen yet.
  Future<String?> lastOrder(String projectId) async {
    try {
      final file = await _lastOrderFile(projectId);
      if (!file.existsSync()) return null;
      return (await file.readAsString()).trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLastOrder(String projectId, String? orderId) async {
    try {
      final file = await _lastOrderFile(projectId);
      await file.parent.create(recursive: true);
      await file.writeAsString(orderId ?? '', flush: true);
    } catch (_) {
      // See the class comment.
    }
  }

  Future<void> clear(String projectId) async {
    try {
      final file = await _file(projectId);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // See the class comment.
    }
  }
}
