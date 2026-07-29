import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../models/enums.dart';
import '../../models/field_config.dart';
import '../database.dart';

/// Outcome of creating or updating a field definition.
///
/// User-facing problems (a duplicate name, an inverted range) come back as a
/// result so the field editor can show them inline. Attempting to change a
/// field's *type* throws instead -- see [FieldDefsDao.update].
sealed class FieldDefResult {
  const FieldDefResult();
}

class FieldDefSaved extends FieldDefResult {
  const FieldDefSaved(this.id);
  final String id;
}

class FieldDefInvalid extends FieldDefResult {
  const FieldDefInvalid(this.problems);
  final List<String> problems;

  @override
  String toString() => 'Invalid(${problems.join('; ')})';
}

/// CRUD for user-defined field definitions.
class FieldDefsDao {
  FieldDefsDao(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  Future<FieldDefResult> create({
    required String projectId,
    required String name,
    required FieldType type,
    FieldRole role = FieldRole.attribute,
    DrawType? drawType,
    bool isContainer = false,
    String? blankPlaceholder,
    double? tolerance,
    bool isStatic = false,
    FieldConfig config = FieldConfig.empty,
    int? sortOrder,
    DateTime? now,
  }) async {
    final trimmed = name.trim();
    final problems = <String>[
      if (trimmed.isEmpty) 'Name cannot be empty.',
      ...config.problemsFor(type),
      ...problemsWithRole(
        role: role,
        type: type,
        drawType: drawType,
        isContainer: isContainer,
      ),
    ];

    if (trimmed.isNotEmpty && await nameExists(projectId, trimmed)) {
      problems.add('A field named "$trimmed" already exists.');
    }

    if (problems.isNotEmpty) return FieldDefInvalid(problems);

    final timestamp = now ?? DateTime.now();
    final id = _uuid.v4();

    await _db
        .into(_db.fieldDefs)
        .insert(
          FieldDefsCompanion.insert(
            id: id,
            projectId: projectId,
            name: trimmed,
            type: type,
            role: Value(role),
            drawType: Value(drawType),
            isContainer: Value(isContainer),
            blankPlaceholder: Value(blankPlaceholder),
            tolerance: Value(tolerance),
            isStatic: Value(isStatic),
            config: Value(config.toJson()),
            sortOrder: Value(sortOrder ?? await _nextSortOrder(projectId)),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );

    return FieldDefSaved(id);
  }

  /// Whether a role, type, draw type and container flag hang together.
  ///
  /// Returned as problems rather than thrown because the field editor offers
  /// these controls and a user can genuinely produce an invalid combination --
  /// unlike changing a type, which the UI must never offer at all.
  static List<String> problemsWithRole({
    required FieldRole role,
    required FieldType type,
    required DrawType? drawType,
    required bool isContainer,
  }) {
    return switch (role) {
      FieldRole.object => [
        // An object's value is its name, and names are text.
        if (type != FieldType.text) 'A drawable object must be a text field.',
        if (drawType == null) 'Choose how this object is drawn.',
        // A point has no interior, so there is nothing for it to contain.
        if (isContainer && drawType == DrawType.point)
          'A point cannot contain plants.',
      ],
      FieldRole.attribute => [
        if (drawType != null) 'An attribute is not drawn, so it has no shape.',
        if (isContainer) 'Only a drawable object can contain plants.',
      ],
    };
  }

  /// The project's drawable object fields.
  Future<List<FieldDef>> objectFieldsForProject(String projectId) async {
    final all = await forProject(projectId);
    return [
      for (final f in all)
        if (f.role == FieldRole.object) f,
    ];
  }

  /// The project's container fields -- the ones that put a value on every plant.
  Future<List<FieldDef>> containerFieldsForProject(String projectId) async {
    final all = await forProject(projectId);
    return [
      for (final f in all)
        if (f.isContainer) f,
    ];
  }

  /// Whether a field with this name already exists in the project.
  ///
  /// Case-insensitive. XLSX import matches columns to fields by name, so
  /// "Health" and "health" coexisting would make an import column ambiguous
  /// with no way for the user to disambiguate it.
  Future<bool> nameExists(
    String projectId,
    String name, {
    String? excludingId,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM field_defs '
          'WHERE project_id = ?1 AND deleted_at IS NULL '
          'AND LOWER(name) = LOWER(?2) '
          '${excludingId != null ? 'AND id != ?3' : ''} '
          'LIMIT 1',
          variables: [
            Variable<String>(projectId),
            Variable<String>(name.trim()),
            if (excludingId != null) Variable<String>(excludingId),
          ],
          readsFrom: {_db.fieldDefs},
        )
        .get();

    return rows.isNotEmpty;
  }

  Future<int> _nextSortOrder(String projectId) async {
    final rows = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM field_defs '
          'WHERE project_id = ?1 AND deleted_at IS NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.fieldDefs},
        )
        .getSingle();

    return rows.read<int>('next');
  }

  Stream<List<FieldDef>> watchForProject(String projectId) {
    return (_db.select(_db.fieldDefs)
          ..where((f) => f.projectId.equals(projectId) & f.deletedAt.isNull())
          ..orderBy([(f) => OrderingTerm.asc(f.sortOrder)]))
        .watch();
  }

  Future<List<FieldDef>> forProject(String projectId) {
    return (_db.select(_db.fieldDefs)
          ..where((f) => f.projectId.equals(projectId) & f.deletedAt.isNull())
          ..orderBy([(f) => OrderingTerm.asc(f.sortOrder)]))
        .get();
  }

  Future<FieldDef?> byId(String id) {
    return (_db.select(
      _db.fieldDefs,
    )..where((f) => f.id.equals(id) & f.deletedAt.isNull())).getSingleOrNull();
  }

  /// Looks a field up by name, as XLSX import does for each column header.
  Future<FieldDef?> byName(String projectId, String name) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM field_defs '
          'WHERE project_id = ?1 AND deleted_at IS NULL '
          'AND LOWER(name) = LOWER(?2) LIMIT 1',
          variables: [
            Variable<String>(projectId),
            Variable<String>(name.trim()),
          ],
          readsFrom: {_db.fieldDefs},
        )
        .get();

    if (rows.isEmpty) return null;
    return _db.fieldDefs.map(rows.first.data);
  }

  /// Updates a field's name, config, static flag, or position.
  ///
  /// **[type] cannot be changed** (decision D5). Passing a different one
  /// throws rather than returning a result: the UI must never offer it, so
  /// reaching here means a bug, not user error. Reinterpreting existing
  /// events under a new type would silently corrupt every historical value --
  /// the categorical "Healthy" does not become an integer. The supported path
  /// is to create a new field and import into it.
  Future<FieldDefResult> update(
    String id, {
    String? name,
    FieldConfig? config,
    bool? isStatic,
    bool? isContainer,
    String? blankPlaceholder,
    double? tolerance,
    int? sortOrder,
    FieldType? type,
    DrawType? drawType,
    DateTime? now,
  }) async {
    final existing = await byId(id);
    if (existing == null) {
      return const FieldDefInvalid(['Field no longer exists.']);
    }

    if (type != null && type != existing.type) {
      throw StateError(
        'Field type is immutable (decision D5). Cannot change '
        '"${existing.name}" from ${existing.type.name} to ${type.name}. '
        'Create a new field and import the data into it instead.',
      );
    }

    // Immutable for the same reason and with the same consequence: every
    // geometry already drawn against this field would become unreadable.
    if (drawType != null && drawType != existing.drawType) {
      throw StateError(
        'Draw type is immutable. Cannot change "${existing.name}" from '
        '${existing.drawType?.name} to ${drawType.name} -- every shape '
        'already drawn would be invalid. Create a new field instead.',
      );
    }

    final trimmed = name?.trim();
    final problems = <String>[
      if (trimmed != null && trimmed.isEmpty) 'Name cannot be empty.',
      if (config != null) ...config.problemsFor(existing.type),
      ...problemsWithRole(
        role: existing.role,
        type: existing.type,
        drawType: existing.drawType,
        isContainer: isContainer ?? existing.isContainer,
      ),
    ];

    if (trimmed != null &&
        trimmed.isNotEmpty &&
        await nameExists(existing.projectId, trimmed, excludingId: id)) {
      problems.add('A field named "$trimmed" already exists.');
    }

    if (problems.isNotEmpty) return FieldDefInvalid(problems);

    await (_db.update(_db.fieldDefs)..where((f) => f.id.equals(id))).write(
      FieldDefsCompanion(
        name: trimmed == null ? const Value.absent() : Value(trimmed),
        config: config == null ? const Value.absent() : Value(config.toJson()),
        isStatic: isStatic == null ? const Value.absent() : Value(isStatic),
        isContainer: isContainer == null
            ? const Value.absent()
            : Value(isContainer),
        blankPlaceholder: blankPlaceholder == null
            ? const Value.absent()
            : Value(blankPlaceholder),
        tolerance: tolerance == null ? const Value.absent() : Value(tolerance),
        sortOrder: sortOrder == null ? const Value.absent() : Value(sortOrder),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );

    return FieldDefSaved(id);
  }

  /// Applies a new display order in one transaction.
  Future<void> reorder(List<String> idsInOrder, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await _db.transaction(() async {
      for (var i = 0; i < idsInOrder.length; i++) {
        await (_db.update(
          _db.fieldDefs,
        )..where((f) => f.id.equals(idsInOrder[i]))).write(
          FieldDefsCompanion(sortOrder: Value(i), updatedAt: Value(timestamp)),
        );
      }
    });
  }

  /// Soft-deletes a field definition.
  ///
  /// Its events are deliberately left in place. They still describe something
  /// that was observed, and restoring the field brings its history back intact
  /// -- deleting a field by accident should not destroy a season of readings.
  Future<void> softDelete(String id, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(_db.fieldDefs)..where((f) => f.id.equals(id))).write(
      FieldDefsCompanion(
        deletedAt: Value(timestamp),
        updatedAt: Value(timestamp),
      ),
    );
  }

  Future<void> restore(String id, {DateTime? now}) async {
    await (_db.update(_db.fieldDefs)..where((f) => f.id.equals(id))).write(
      FieldDefsCompanion(
        deletedAt: const Value(null),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Parsed config for a field.
  FieldConfig configOf(FieldDef def) => FieldConfig.parse(def.config);
}
