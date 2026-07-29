import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';

/// CRUD for vineyards. Each project owns its image, schema, and vines (D10).
class ProjectsDao {
  ProjectsDao(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  Future<String> create({
    required String name,
    String? imagePath,
    int? imageWidth,
    int? imageHeight,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db
        .into(_db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: id,
            name: name.trim(),
            imagePath: Value(imagePath),
            imageWidth: Value(imageWidth),
            imageHeight: Value(imageHeight),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );

    return id;
  }

  /// Live-updating project list, newest activity first.
  ///
  /// A stream rather than a future because drift re-emits on any write to the
  /// table, so the project list cannot go stale behind a rename or an import.
  Stream<List<Project>> watchAll() {
    return (_db.select(_db.projects)
          ..where((p) => p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.desc(p.updatedAt)]))
        .watch();
  }

  Future<List<Project>> all() {
    return (_db.select(_db.projects)
          ..where((p) => p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.desc(p.updatedAt)]))
        .get();
  }

  Future<Project?> byId(String id) {
    return (_db.select(
      _db.projects,
    )..where((p) => p.id.equals(id) & p.deletedAt.isNull())).getSingleOrNull();
  }

  Future<void> rename(String id, String name, {DateTime? now}) async {
    await (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(
      ProjectsCompanion(
        name: Value(name.trim()),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Records the background image and its pixel dimensions.
  ///
  /// Dimensions are stored rather than read from the file on demand: every
  /// coordinate in the project is in this image's pixel space, so the canvas
  /// needs them before the image itself has finished decoding.
  Future<void> setImage(
    String id, {
    required String? imagePath,
    required int? width,
    required int? height,
    DateTime? now,
  }) async {
    await (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(
      ProjectsCompanion(
        imagePath: Value(imagePath),
        imageWidth: Value(width),
        imageHeight: Value(height),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Soft-deletes. Cascading rows are left untouched -- the project can be
  /// restored intact, and a hard delete would take the vineyard's entire
  /// history with it.
  Future<void> softDelete(String id, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(
      ProjectsCompanion(
        deletedAt: Value(timestamp),
        updatedAt: Value(timestamp),
      ),
    );
  }

  Future<void> restore(String id, {DateTime? now}) async {
    await (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(
      ProjectsCompanion(
        deletedAt: const Value(null),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Projects in the trash, for a restore-or-purge screen.
  Future<List<Project>> deleted() {
    return (_db.select(_db.projects)
          ..where((p) => p.deletedAt.isNotNull())
          ..orderBy([(p) => OrderingTerm.desc(p.deletedAt)]))
        .get();
  }

  /// Permanently removes a project and everything under it.
  ///
  /// Irreversible. Foreign keys cascade, so this takes every block, row, vine,
  /// field definition, and event with it. Callers must confirm explicitly --
  /// the plan requires typed confirmation for permanent deletion.
  Future<void> purge(String id) async {
    await _db.transaction(() async {
      // The undo journal goes with it. `operations.project_id` is deliberately
      // not a foreign key -- a cascade would delete the journal rows describing
      // the purge as they were being written -- so it is cleared here instead.
      // There is nothing worth keeping: purge is irreversible by design.
      await (_db.delete(
        _db.operations,
      )..where((o) => o.projectId.equals(id))).go();
      await (_db.delete(_db.projects)..where((p) => p.id.equals(id))).go();
    });
  }
}
