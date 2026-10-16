import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/walk_plan.dart';
import '../database.dart';

/// A walking order saved under a name.
///
/// [plan] is as saved: callers reconcile it against the plants that exist
/// now.
typedef SavedWalkOrder = ({
  String id,
  String name,
  WalkPlan plan,
  DateTime updatedAt,
});

/// Saved walking orders: presets chosen when a walk is set up.
class WalkOrdersDao {
  WalkOrdersDao(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  /// A project's saved orders, by name.
  Future<List<SavedWalkOrder>> forProject(String projectId) async {
    final rows =
        await (_db.select(_db.walkOrders)
              ..where((w) => w.projectId.equals(projectId))
              ..orderBy([(w) => OrderingTerm.asc(w.name)]))
            .get();
    return [for (final r in rows) ?_decode(r)];
  }

  /// One saved order, or null if it has been deleted.
  Future<SavedWalkOrder?> load(String id) async {
    final row = await (_db.select(
      _db.walkOrders,
    )..where((w) => w.id.equals(id))).getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  SavedWalkOrder? _decode(WalkOrderRow row) {
    final plan = WalkPlan.fromJson(
      order: row.plantIds,
      excluded: row.excluded,
      breaks: row.breaks,
    );
    if (plan == null) return null;
    return (id: row.id, name: row.name, plan: plan, updatedAt: row.updatedAt);
  }

  /// Saves [plan] as a new order called [name]; returns its id.
  Future<String> create({
    required String projectId,
    required String name,
    required WalkPlan plan,
    DateTime? now,
  }) async {
    final id = _uuid.v4();
    await _db
        .into(_db.walkOrders)
        .insert(
          WalkOrdersCompanion.insert(
            id: id,
            projectId: projectId,
            name: name.trim(),
            plantIds: plan.orderJson,
            excluded: Value(plan.excludedJson),
            breaks: Value(plan.breaksJson),
            updatedAt: now ?? DateTime.now(),
          ),
        );
    return id;
  }

  /// Replaces the plants of an existing order, keeping its name.
  Future<void> update(String id, WalkPlan plan, {DateTime? now}) =>
      (_db.update(_db.walkOrders)..where((w) => w.id.equals(id))).write(
        WalkOrdersCompanion(
          plantIds: Value(plan.orderJson),
          excluded: Value(plan.excludedJson),
          breaks: Value(plan.breaksJson),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

  Future<void> rename(String id, String name) =>
      (_db.update(_db.walkOrders)..where((w) => w.id.equals(id))).write(
        WalkOrdersCompanion(name: Value(name.trim())),
      );

  /// Saves a copy of order [id] as [name]; returns the copy's id, or null if
  /// the original is gone.
  Future<String?> copy(String id, String name) async {
    final row = await (_db.select(
      _db.walkOrders,
    )..where((w) => w.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final copyId = _uuid.v4();
    await _db
        .into(_db.walkOrders)
        .insert(
          row.copyWith(
            id: copyId,
            name: name.trim(),
            updatedAt: DateTime.now(),
          ),
        );
    return copyId;
  }

  Future<void> delete(String id) =>
      (_db.delete(_db.walkOrders)..where((w) => w.id.equals(id))).go();
}
