import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../models/identifier_template.dart';

/// Composes and resolves plant identifiers.
///
/// v2 built `block.row.plant` in SQL. v3 renders whatever the project's
/// template says, from container memberships, attribute values, and the plant's
/// own number.
///
/// **`plants.id` still never changes.** Only the human-facing identifier moves,
/// so renumbering, renaming an object, or editing the template cannot orphan a
/// single field event.
///
/// Uniqueness is enforced here rather than by a database constraint, because
/// renumbering passes through states where two plants briefly share a number
/// and an index would reject the operation halfway through. The rule that
/// replaces the constraint is absolute: **any operation that would produce two
/// plants with the same identifier is refused**, never warned about.
class LabelService {
  LabelService(this._db);

  final AppDatabase _db;

  // ------------------------------------------------------------- rendering

  /// The project's template, or [IdentifierTemplate.plantOnly] if it has none.
  ///
  /// A project that skipped the wizard still shows plain numbers rather than
  /// nothing, which is what makes the wizard skippable.
  Future<IdentifierTemplate> templateFor(String projectId) async {
    final row = await (_db.select(
      _db.projects,
    )..where((p) => p.id.equals(projectId))).getSingleOrNull();

    return IdentifierTemplate.parse(row?.identifierTemplate) ??
        IdentifierTemplate.plantOnly;
  }

  /// Everything needed to render a project's identifiers, fetched once.
  ///
  /// Deliberately separate from rendering. Holding the raw values lets the
  /// "this renames 34 plants" prompt exist at all: fetch once, render under the
  /// current template and under the proposed one, and diff -- without writing
  /// anything.
  Future<IdentifierData> dataFor(String projectId) async {
    final plants = await _db
        .customSelect(
          'SELECT id, position_idx FROM plants '
          'WHERE project_id = ?1 AND deleted_at IS NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.plants},
        )
        .get();

    // One query for every container value in the project, rather than one per
    // plant. 3,000 round trips per repaint is not a budget, it is a freeze --
    // the same reason v2 used a single join.
    final containers = await _db
        .customSelect(
          'SELECT m.plant_id AS plant_id, m.field_def_id AS field_def_id, '
          '       o.label AS label '
          'FROM plant_memberships m '
          'JOIN map_objects o ON o.id = m.object_id AND o.deleted_at IS NULL '
          'JOIN plants v ON v.id = m.plant_id '
          'WHERE v.project_id = ?1 AND v.deleted_at IS NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.plantMemberships, _db.mapObjects, _db.plants},
        )
        .get();

    // Latest value per plant per attribute field, by the same window-function
    // shape FieldEventsDao uses. Scoped to the whole project rather than to the
    // template's fields, so the caller can render a *proposed* template that
    // names a field the current one does not.
    final attributes = await _db
        .customSelect(
          'SELECT plant_id, field_def_id, value FROM ('
          '  SELECT e.plant_id AS plant_id, e.field_def_id AS field_def_id, '
          '         e.value AS value, ROW_NUMBER() OVER ('
          '    PARTITION BY e.plant_id, e.field_def_id '
          '    ORDER BY e.observed_at DESC, e.recorded_at DESC, e.rowid DESC'
          '  ) AS rn '
          '  FROM field_events e '
          '  JOIN plants v ON v.id = e.plant_id '
          '  WHERE v.project_id = ?1 AND v.deleted_at IS NULL '
          '    AND e.deleted_at IS NULL'
          ') WHERE rn = 1',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.fieldEvents, _db.plants},
        )
        .get();

    final numbers = <String, int>{};
    for (final r in plants) {
      numbers[r.read<String>('id')] = r.read<int>('position_idx');
    }

    final values = <String, Map<String, String>>{};
    for (final r in containers) {
      (values[r.read<String>('plant_id')] ??= {})[r.read<String>(
        'field_def_id',
      )] = r.read<String>(
        'label',
      );
    }
    for (final r in attributes) {
      final value = r.readNullable<String>('value');
      if (value == null) continue; // cleared, so the placeholder applies
      (values[r.read<String>('plant_id')] ??= {})[r.read<String>(
            'field_def_id',
          )] =
          value;
    }

    return IdentifierData(
      plantNumbers: numbers,
      values: values,
      placeholders: await _placeholders(projectId),
    );
  }

  Future<Map<String, String>> _placeholders(String projectId) async {
    final rows = await _db
        .customSelect(
          'SELECT id, blank_placeholder FROM field_defs '
          'WHERE project_id = ?1 AND deleted_at IS NULL',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.fieldDefs},
        )
        .get();

    return {
      for (final r in rows)
        r.read<String>('id'):
            r.readNullable<String>('blank_placeholder') ?? defaultPlaceholder,
    };
  }

  /// What an identifier shows where a field has no value.
  ///
  /// The generic form of v2's reserved `"0"`. Per-field in the schema; this is
  /// only the fallback for a field that never chose one.
  static const defaultPlaceholder = '0';

  /// Renders every plant's identifier. **Pure** -- no database, no writes.
  ///
  /// This is what makes change counting possible before committing: render
  /// under the old template and the new one and compare.
  static Map<String, PlantIdentifier> render(
    IdentifierData data,
    IdentifierTemplate template,
  ) {
    final out = <String, PlantIdentifier>{};

    for (final entry in data.plantNumbers.entries) {
      final plantId = entry.key;
      final parts = <String>[];

      for (final part in template.parts) {
        switch (part) {
          case PlantPart():
            parts.add('${entry.value}');
          case FieldPart(:final fieldDefId):
            parts.add(
              data.values[plantId]?[fieldDefId] ??
                  data.placeholders[fieldDefId] ??
                  defaultPlaceholder,
            );
        }
      }

      out[plantId] = PlantIdentifier(
        parts: parts,
        delimiter: template.delimiter,
      );
    }
    return out;
  }

  /// Every plant's identifier in the project, keyed by plant id.
  Future<Map<String, PlantIdentifier>> identifiersForProject(
    String projectId,
  ) async => render(await dataFor(projectId), await templateFor(projectId));

  /// One plant's identifier, or null if it does not exist.
  Future<PlantIdentifier?> identifierOf(String plantId) async {
    final plant =
        await (_db.select(_db.plants)
              ..where((v) => v.id.equals(plantId) & v.deletedAt.isNull()))
            .getSingleOrNull();
    if (plant == null) return null;

    return (await identifiersForProject(plant.projectId))[plantId];
  }

  // -------------------------------------------------------------- checking

  /// How a proposed set of identifiers differs from the current one.
  ///
  /// Callers build [after] however they need -- a new template, a renamed
  /// object, a numbering plan -- and this reports the blast radius and any
  /// collisions. Nothing is written.
  static IdentifierChange compare(
    Map<String, PlantIdentifier> before,
    Map<String, PlantIdentifier> after,
  ) {
    var changed = 0;
    for (final entry in after.entries) {
      if (before[entry.key]?.text != entry.value.text) changed++;
    }

    final seen = <String, int>{};
    for (final id in after.values) {
      seen.update(id.text, (n) => n + 1, ifAbsent: () => 1);
    }

    return IdentifierChange(
      changed: changed,
      duplicates: [
        for (final e in seen.entries)
          if (e.value > 1) e.key,
      ]..sort(),
    );
  }

  /// Whether an object label is acceptable for its field.
  ///
  /// Returns null if fine, or the reason it is not. Replaces v2's
  /// `problemWithLabel`, which could hardcode its three rules because the
  /// delimiter and the blank value were themselves hardcoded.
  static String? problemWithObjectLabel({
    required String label,
    required String delimiter,
    String? blankPlaceholder,
  }) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return 'Name cannot be empty.';

    final blank = blankPlaceholder ?? defaultPlaceholder;
    if (trimmed == blank) {
      return '"$blank" is reserved for plants that have no value here.';
    }
    if (delimiter.isNotEmpty && trimmed.contains(delimiter)) {
      return 'Cannot contain "$delimiter" -- it separates the parts of an ID.';
    }
    return null;
  }

  /// The same three rules for an attribute value that is an identifier part.
  ///
  /// The Clone-is-`none` case: if Clone is in the template, recording a clone
  /// literally called `none` would make the identifier ambiguous between a real
  /// value and a missing one.
  static String? problemWithIdentifierValue({
    required String value,
    required String delimiter,
    String? blankPlaceholder,
  }) => problemWithObjectLabel(
    label: value,
    delimiter: delimiter,
    blankPlaceholder: blankPlaceholder,
  );

  /// Identifiers held by more than one plant.
  ///
  /// Uniqueness is maintained in application code rather than by a constraint,
  /// so it is worth being able to prove it holds -- especially after an import,
  /// which writes rows without going through any of this.
  Future<List<String>> findDuplicateIdentifiers(String projectId) async {
    final identifiers = await identifiersForProject(projectId);
    final seen = <String, int>{};
    for (final id in identifiers.values) {
      seen.update(id.text, (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      for (final e in seen.entries)
        if (e.value > 1) e.key,
    ]..sort();
  }

  // --------------------------------------------------------------- history

  /// Every identifier this plant has carried, oldest first.
  ///
  /// Answers "what was 3.12.7 in 2025?" -- the question that makes a shelf of
  /// paper notebooks worth keeping. Identifiers are mutable and reused, so the
  /// same text genuinely does mean different plants at different times.
  ///
  /// Derived from the undo journal rather than a table of its own, so there is
  /// one source of truth rather than two that can disagree. v2 merged three
  /// journals; v3 merges four, because containment moved out of the plant:
  ///
  ///  * `plants` -- the plant's own number
  ///  * `plant_memberships` -- containment gained or lost, which is how a
  ///    boundary edit that swept the plant into another block appears here
  ///  * `map_objects` -- an object renamed, which changes every identifier on
  ///    it without touching a single plant
  ///  * `field_events` -- an attribute that is an identifier part changing
  ///
  /// **Three limits, all deliberate.** History begins where the journal begins.
  /// Undone operations are excluded, so undo means a rename did not happen.
  /// And the walk renders under the *current* template: changing the template
  /// rewrites how past identifiers read, which is the honest answer given the
  /// parts themselves are what was recorded.
  Future<List<IdentifierChangeRecord>> historyOf(String plantId) async {
    final plant = await (_db.select(
      _db.plants,
    )..where((v) => v.id.equals(plantId))).getSingleOrNull();
    if (plant == null) return const [];

    final template = await templateFor(plant.projectId);
    final data = await dataFor(plant.projectId);

    // Everything the journal remembers about this plant, and about the objects
    // it has ever belonged to.
    final own = await _journal(table: 'plants', rowIds: {plantId});
    final memberships = await _journal(
      table: 'plant_memberships',
      plantId: plantId,
    );

    // Which objects to watch for renames. **Both** the ones the journal
    // mentions and the ones holding this plant right now: containment usually
    // predates any recorded operation -- reconcile ran when the block was
    // drawn -- so the journal alone names nothing at all in the common case.
    final currentHolders = await _currentHolders(plantId);
    final objectIds = <String>{
      ...currentHolders.values,
      for (final e in memberships) ...[
        ?e.before?['object_id'] as String?,
        ?e.after?['object_id'] as String?,
      ],
    };
    final renames = await _journal(table: 'map_objects', rowIds: objectIds);

    final attributeIds = template.fieldIds.toSet();
    final events = attributeIds.isEmpty
        ? <_JournalEntry>[]
        : await _journal(table: 'field_events', plantId: plantId);

    final merged = [...own, ...memberships, ...renames, ...events]
      ..sort((a, b) => a.id.compareTo(b.id));

    // Starting state: what the plant looked like before the first operation
    // that touched it, or -- if none ever did -- what it looks like now.
    var number = own.isNotEmpty
        ? (own.first.before?['position_idx'] as int? ?? plant.positionIdx)
        : plant.positionIdx;

    // field id -> value, rewound to the start by undoing every recorded change.
    final values = <String, String>{...?data.values[plantId]};
    final labels = <String, String>{}; // object id -> label
    final holders = <String, String>{}; // field id -> object id

    // Start from what is true now, then walk backwards undoing every recorded
    // change to reach the state the journal opens on.
    //
    // Starting from the present rather than from the journal is what makes this
    // work at all: a plant's containment almost always predates the first
    // operation that touched it -- reconcile ran when the block was drawn, long
    // before whatever is being asked about now -- so there is nothing in the
    // journal to build the initial state *from*.
    holders.addAll(currentHolders);
    labels.addAll(await _currentLabels(objectIds));

    // Which of the template's fields are containers, so `record` knows whether
    // an absent value means "no container holds it" or "no value recorded".
    final containerFields = await _containerFieldIds(plant.projectId);

    for (final entry in merged.reversed) {
      switch (entry.table) {
        case 'plant_memberships':
          final gained = entry.after;
          final lost = entry.before;
          if (gained != null && lost == null) {
            // Undoing a gain: before this, the plant was not in it.
            holders.remove(gained['field_def_id'] as String);
          } else if (lost != null && gained == null) {
            // Undoing a loss: before this, the plant was in it.
            holders[lost['field_def_id'] as String] =
                lost['object_id'] as String;
          }
        case 'map_objects':
          final before = entry.before;
          if (before != null) {
            labels[entry.rowId] = before['label'] as String;
          }
        case 'field_events':
          final before = entry.before;
          final field = (before ?? entry.after)?['field_def_id'] as String?;
          if (field != null && attributeIds.contains(field)) {
            final value = before?['value'] as String?;
            if (value == null) {
              values.remove(field);
            } else {
              values[field] = value;
            }
          }
      }
    }

    final history = <IdentifierChangeRecord>[];

    void record(DateTime? at, String? reason) {
      // Container values are *composed*, never carried: a container field's
      // value is whatever its holding object was called at this point in the
      // walk. Recomputing here rather than patching `values` on every event is
      // what makes a rename and a membership change impossible to get out of
      // step -- both feed the same two maps.
      final composed = <String, String>{...values};
      for (final held in holders.entries) {
        final label = labels[held.value];
        if (label != null) composed[held.key] = label;
      }
      for (final field in containerFields) {
        if (!holders.containsKey(field)) composed.remove(field);
      }

      final rendered = render(
        IdentifierData(
          plantNumbers: {plantId: number},
          values: {plantId: composed},
          placeholders: data.placeholders,
        ),
        template,
      )[plantId]!;

      // Only transitions matter. Most operations touch a plant without moving
      // its address, and listing those would bury the renames that are the
      // whole point of this list.
      if (history.isNotEmpty && history.last.identifier == rendered) return;
      history.add(
        IdentifierChangeRecord(identifier: rendered, at: at, reason: reason),
      );
    }

    // The starting identifier carries no date: the journal records what changed
    // an identifier, never when it was first given.
    record(null, null);

    for (final entry in merged) {
      switch (entry.table) {
        case 'plants':
          final after = entry.after;
          if (after != null) number = after['position_idx'] as int;
        case 'plant_memberships':
          final gained = entry.after;
          final lost = entry.before;
          if (gained != null) {
            holders[gained['field_def_id'] as String] =
                gained['object_id'] as String;
          } else if (lost != null) {
            holders.remove(lost['field_def_id'] as String);
          }
        case 'map_objects':
          // A rename changes every identifier on that object without touching
          // a single plant -- the generic form of v2's row-rename fold. Nothing
          // else is needed here because `record` recomposes from `labels`.
          final after = entry.after;
          if (after != null) labels[entry.rowId] = after['label'] as String;
        case 'field_events':
          final after = entry.after;
          if (after == null) continue;
          final field = after['field_def_id'] as String;
          if (!attributeIds.contains(field)) continue;
          final value = after['value'] as String?;
          if (value == null) {
            values.remove(field);
          } else {
            values[field] = value;
          }
      }
      record(entry.at, entry.description);
    }

    // Anything that bypassed the journal -- an import, a restored archive --
    // leaves the walk disagreeing with reality. Reality wins.
    final current = (await identifiersForProject(plant.projectId))[plantId];
    if (current != null &&
        (history.isEmpty || history.last.identifier != current)) {
      history.add(IdentifierChangeRecord(identifier: current));
    }

    return history;
  }

  /// The project's container-object fields.
  Future<Set<String>> _containerFieldIds(String projectId) async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM field_defs '
          'WHERE project_id = ?1 AND deleted_at IS NULL AND is_container = 1',
          variables: [Variable<String>(projectId)],
          readsFrom: {_db.fieldDefs},
        )
        .get();
    return {for (final r in rows) r.read<String>('id')};
  }

  /// Which containers hold this plant, as field name to object name.
  ///
  /// What the inspector shows under the identifier. Read-only by nature: these
  /// are derived from geometry, so the way to change one is to move the plant or
  /// move the boundary.
  Future<Map<String, String>> containersOf(String plantId) async {
    final rows = await _db
        .customSelect(
          'SELECT f.name AS field, o.label AS label '
          'FROM plant_memberships m '
          'JOIN map_objects o ON o.id = m.object_id AND o.deleted_at IS NULL '
          'JOIN field_defs f ON f.id = m.field_def_id AND f.deleted_at IS NULL '
          'WHERE m.plant_id = ?1 '
          'ORDER BY f.sort_order',
          variables: [Variable<String>(plantId)],
          readsFrom: {_db.plantMemberships, _db.mapObjects, _db.fieldDefs},
        )
        .get();

    return {
      for (final r in rows) r.read<String>('field'): r.read<String>('label'),
    };
  }

  /// Which object currently holds each container field for this plant.
  Future<Map<String, String>> _currentHolders(String plantId) async {
    final rows = await _db
        .customSelect(
          'SELECT field_def_id, object_id FROM plant_memberships '
          'WHERE plant_id = ?1',
          variables: [Variable<String>(plantId)],
          readsFrom: {_db.plantMemberships},
        )
        .get();
    return {
      for (final r in rows)
        r.read<String>('field_def_id'): r.read<String>('object_id'),
    };
  }

  Future<Map<String, String>> _currentLabels(Set<String> objectIds) async {
    if (objectIds.isEmpty) return const {};

    final variables = <Variable<Object>>[];
    final placeholders = <String>[];
    for (final id in objectIds) {
      variables.add(Variable<String>(id));
      placeholders.add('?${variables.length}');
    }

    final rows = await _db
        .customSelect(
          'SELECT id, label FROM map_objects '
          'WHERE id IN (${placeholders.join(',')})',
          variables: variables,
          readsFrom: {_db.mapObjects},
        )
        .get();
    return {
      for (final r in rows) r.read<String>('id'): r.read<String>('label'),
    };
  }

  /// Journal entries for one table, either by row id or by the plant they
  /// concern.
  Future<List<_JournalEntry>> _journal({
    required String table,
    Set<String>? rowIds,
    String? plantId,
  }) async {
    if (rowIds != null && rowIds.isEmpty) return const [];

    final variables = <Variable<Object>>[Variable<String>(table)];
    final where = StringBuffer('r.target_table = ?1');

    if (rowIds != null) {
      final placeholders = <String>[];
      for (final id in rowIds) {
        variables.add(Variable<String>(id));
        placeholders.add('?${variables.length}');
      }
      where.write(' AND r.row_id IN (${placeholders.join(',')})');
    }

    final rows = await _db
        .customSelect(
          'SELECT r.id AS id, r.row_id AS row_id, r.before AS before, '
          '       r.after AS after, o.created_at AS created_at, '
          '       o.description AS description '
          'FROM operation_rows r '
          'JOIN operations o ON o.id = r.operation_id '
          // Undone operations are excluded, so undo means the rename did not
          // happen rather than happened-and-was-reversed.
          'WHERE o.undone_at IS NULL AND $where '
          'ORDER BY r.id',
          variables: variables,
          readsFrom: {_db.operationRows, _db.operations},
        )
        .get();

    final entries = [
      for (final r in rows)
        _JournalEntry(
          id: r.read<int>('id'),
          table: table,
          rowId: r.read<String>('row_id'),
          before: _decode(r.readNullable<String>('before')),
          after: _decode(r.readNullable<String>('after')),
          at: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('created_at'),
            isUtc: true,
          ).toLocal(),
          description: r.read<String>('description'),
        ),
    ];

    // Membership and event rows are found by the plant they name rather than
    // by their own id, which the SQL above cannot express generically.
    if (plantId == null) return entries;
    return [
      for (final e in entries)
        if ((e.before ?? e.after)?['plant_id'] == plantId) e,
    ];
  }

  static Map<String, dynamic>? _decode(String? json) =>
      json == null ? null : jsonDecode(json) as Map<String, dynamic>;

  // ------------------------------------------------------------- numbering

  /// The lowest unused plant number on a carrier, or among plants with none.
  ///
  /// Lowest-unused rather than highest-plus-one, so a gap left by a removed
  /// plant is reused instead of the numbers climbing forever while the line
  /// stays the same length.
  Future<int> nextPlantNumber({
    required String projectId,
    String? carrierId,
  }) async {
    // `IS` rather than `=`, so the carrier-less scope works: `carrier_id =
    // NULL` is never true, which would make every free plant look like the only
    // one and number them all 1.
    final rows = await _db
        .customSelect(
          'SELECT position_idx FROM plants '
          'WHERE project_id = ?1 AND deleted_at IS NULL AND carrier_id IS ?2',
          variables: [Variable<String>(projectId), Variable<String>(carrierId)],
          readsFrom: {_db.plants},
        )
        .get();

    final used = {for (final r in rows) r.read<int>('position_idx')};
    var candidate = 1;
    while (used.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }

  /// Numbers a plant being inserted into a carrier at a chosen point.
  ///
  /// With [shift] true the plant takes `afterPositionIdx + 1` and everything
  /// beyond it moves up one. With [shift] false it takes the lowest free number
  /// on that carrier, appending if there are no gaps, and no existing plant is
  /// touched -- at the cost of the number not matching where the plant sits.
  ///
  /// The app asks rather than defaulting: only the user knows whether a printed
  /// map is in somebody's pocket.
  Future<int> insertAfter({
    required String plantId,
    required String carrierId,
    required int afterPositionIdx,
    required bool shift,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();

    return _db.transaction(() async {
      final plant = await (_db.select(
        _db.plants,
      )..where((v) => v.id.equals(plantId))).getSingle();

      if (!shift) {
        final number = await nextPlantNumber(
          projectId: plant.projectId,
          carrierId: carrierId,
        );
        await _place(plantId, carrierId, number, timestamp);
        return number;
      }

      // A single statement rather than descending updates. `position_idx` has
      // no unique index precisely so renumbering can pass through duplicate
      // states, and one statement is far cheaper on a 72-plant line.
      await _db.customStatement(
        'UPDATE plants SET position_idx = position_idx + 1, updated_at = ?1 '
        'WHERE carrier_id = ?2 AND deleted_at IS NULL AND position_idx > ?3',
        [timestamp.toUtc().millisecondsSinceEpoch, carrierId, afterPositionIdx],
      );

      final number = afterPositionIdx + 1;
      await _place(plantId, carrierId, number, timestamp);
      return number;
    });
  }

  /// How many plants [insertAfter] would renumber if asked to shift.
  ///
  /// The prompt has to name this. "This renames 34 plants" is a decision;
  /// "labels after this point will change" is a shrug.
  Future<int> countAffectedByShift({
    required String carrierId,
    required int afterPositionIdx,
  }) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM plants '
          'WHERE carrier_id = ?1 AND deleted_at IS NULL AND position_idx > ?2',
          variables: [
            Variable<String>(carrierId),
            Variable<int>(afterPositionIdx),
          ],
          readsFrom: {_db.plants},
        )
        .getSingle();
    return row.read<int>('n');
  }

  Future<void> _place(
    String plantId,
    String carrierId,
    int number,
    DateTime timestamp,
  ) async {
    await (_db.update(_db.plants)..where((v) => v.id.equals(plantId))).write(
      PlantsCompanion(
        carrierId: Value(carrierId),
        positionIdx: Value(number),
        updatedAt: Value(timestamp),
      ),
    );
  }

  /// The lowest unused integer label among one object field's instances.
  ///
  /// Replaces v2's `nextRowNumber`, which scoped rows inside blocks. That rule
  /// is gone: numbering is now something the user does with the numbering tool,
  /// not something the hierarchy imposes. A label that is not a number occupies
  /// no number -- a row called "north" cannot collide with one.
  Future<int> nextObjectLabel(String fieldDefId) async {
    final rows = await _db
        .customSelect(
          'SELECT label FROM map_objects '
          'WHERE field_def_id = ?1 AND deleted_at IS NULL',
          variables: [Variable<String>(fieldDefId)],
          readsFrom: {_db.mapObjects},
        )
        .get();

    final used = {for (final r in rows) ?int.tryParse(r.read<String>('label'))};
    var candidate = 1;
    while (used.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }

  /// Whether [label] is free among an object field's instances.
  Future<bool> isObjectLabelFree({
    required String fieldDefId,
    required String label,
    String? ignoringObjectId,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM map_objects '
          'WHERE field_def_id = ?1 AND deleted_at IS NULL AND label = ?2',
          variables: [
            Variable<String>(fieldDefId),
            Variable<String>(label.trim()),
          ],
          readsFrom: {_db.mapObjects},
        )
        .get();

    // An object does not collide with itself when being renamed in place.
    return rows.every((r) => r.read<String>('id') == ignoringObjectId);
  }
}

/// The raw values an identifier is rendered from.
class IdentifierData {
  const IdentifierData({
    required this.plantNumbers,
    required this.values,
    required this.placeholders,
  });

  /// plant id -> `position_idx`.
  final Map<String, int> plantNumbers;

  /// plant id -> field id -> value, covering containers and attributes alike.
  /// A field absent for a plant renders as that field's placeholder.
  final Map<String, Map<String, String>> values;

  /// field id -> what to show when it has no value.
  final Map<String, String> placeholders;

  /// A copy with one field's value replaced for some plants.
  ///
  /// How a caller previews a rename before committing it: renaming Block 1 to
  /// Block 4 is this, applied to every plant in it.
  IdentifierData withValues(String fieldDefId, Map<String, String> byPlant) {
    final next = <String, Map<String, String>>{
      for (final e in values.entries) e.key: {...e.value},
    };
    for (final e in byPlant.entries) {
      (next[e.key] ??= {})[fieldDefId] = e.value;
    }
    return IdentifierData(
      plantNumbers: plantNumbers,
      values: next,
      placeholders: placeholders,
    );
  }

  /// A copy with some plants renumbered -- how a numbering plan is previewed.
  IdentifierData withNumbers(Map<String, int> byPlant) => IdentifierData(
    plantNumbers: {...plantNumbers, ...byPlant},
    values: values,
    placeholders: placeholders,
  );
}

/// What a proposed change would do to a project's identifiers.
class IdentifierChange {
  const IdentifierChange({required this.changed, required this.duplicates});

  /// How many plants would end up called something different.
  final int changed;

  /// Identifiers that would be held by more than one plant. **Non-empty means
  /// refuse**, never warn.
  final List<String> duplicates;

  bool get isSafe => duplicates.isEmpty;
}

/// An identifier this plant carried, and what gave it that identifier.
class IdentifierChangeRecord {
  const IdentifierChangeRecord({
    required this.identifier,
    this.at,
    this.reason,
  });

  final PlantIdentifier identifier;

  /// When the plant took this identifier, or null when the journal cannot say
  /// -- which is the case for whatever it was called before the journal began,
  /// and for anything written by an import.
  final DateTime? at;

  /// The description of the operation responsible, e.g. "Insert plant in
  /// row 12".
  final String? reason;

  @override
  String toString() => '${identifier.text}${at == null ? '' : ' from $at'}';
}

/// One captured row from the undo journal, decoded.
class _JournalEntry {
  const _JournalEntry({
    required this.id,
    required this.table,
    required this.rowId,
    required this.before,
    required this.after,
    required this.at,
    required this.description,
  });

  /// The journal row's own id, which is also the order things happened in.
  final int id;

  final String table;
  final String rowId;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
  final DateTime at;
  final String description;
}
