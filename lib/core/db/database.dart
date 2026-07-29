import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

// database.g.dart is a `part` of this library, so it resolves types against
// these imports rather than against tables.dart's. The enums and the converter
// look unused here, but the generated companions reference them directly.
import '../models/enums.dart';
import 'converters.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Projects,
    MapObjects,
    PlantMemberships,
    Vines,
    FieldDefs,
    FieldEvents,
    Operations,
    OperationRows,
    UndoContext,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// Pass an executor for tests (`NativeDatabase.memory()`); omit it in the app
  /// to open the on-device file.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'vineviewer'));

  /// **Version 1 has shipped and is on real devices**, holding real vineyards.
  ///
  /// (An earlier comment here claimed nothing had ever opened this database.
  /// That stopped being true the moment `ProjectListScreen` went in -- it
  /// watches `projectListProvider`, which opens the file on app start.)
  ///
  /// So every schema change from here needs a numbered step in [migration]
  /// below *and* a fixture proving it against real prior-version data. A
  /// migration that has never been executed against a version-1 file is a
  /// guess, and the cost of being wrong is somebody's vineyard.
  ///
  /// * v2 -- the undo journal: `operations`, `operation_rows`, `undo_context`,
  ///   and the capture triggers.
  /// * v3 -- the generic data engine. `blocks` and `vine_rows` become
  ///   `map_objects` instances of user-defined object fields, containment moves
  ///   to `plant_memberships`, and the identifier becomes a template. **This
  ///   one wipes.** See [migration].
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      // Creates every table including the three journal ones, so only the
      // trigger-and-seed half of the journal setup is needed after it.
      await m.createAll();
      await _createIndexes();
      await _installUndoJournal();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(operations);
        await m.createTable(operationRows);
        await m.createTable(undoContext);
        await _installUndoJournal();
      }
      if (from < 3) await _wipeToV3(m);
    },
    beforeOpen: (details) async {
      // Must be enabled per connection: SQLite defaults foreign keys OFF, so
      // without this the references declared in tables.dart are inert and
      // orphaned rows accumulate silently.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Drops everything and rebuilds at v3.
  ///
  /// **This destroys all data, deliberately.** v3 is a fresh schema rather than
  /// surgery on v2: `blocks` and `vine_rows` do not map onto `map_objects`
  /// without inventing the object fields they are instances of, the container
  /// flags, the blank placeholders, and an identifier template. Both v2
  /// projects in existence were throwaway -- one seeded by a button, one
  /// holding a single row drawn as a check -- so writing that migration would
  /// have cost more than redrawing them.
  ///
  /// **The next migration will be the first one written against data anyone
  /// wants to keep.** That one needs a real fixture and a real test; this one
  /// only needs to leave a working empty database behind.
  Future<void> _wipeToV3(Migrator m) async {
    // Off while dropping, or the cascades fire in an order SQLite objects to
    // as tables disappear out from under their references.
    await customStatement('PRAGMA foreign_keys = OFF');

    // Triggers first. `DROP TABLE` leaves a trigger naming a vanished table in
    // sqlite_master as a dangling definition, which then breaks the *next*
    // migration rather than this one -- the worst place for it to surface.
    for (final table in ['blocks', 'vine_rows', 'vines', 'field_events',
                         'field_defs', 'projects']) {
      for (final suffix in ['insert', 'update', 'delete']) {
        await customStatement('DROP TRIGGER IF EXISTS jr_${table}_$suffix');
      }
    }

    for (final table in [
      'operation_rows',
      'operations',
      'undo_context',
      'field_events',
      'field_defs',
      'vines',
      'vine_rows',
      'blocks',
      'projects',
    ]) {
      await customStatement('DROP TABLE IF EXISTS $table');
    }

    await m.createAll();
    await _createIndexes();
    await _installUndoJournal();
    await customStatement('PRAGMA foreign_keys = ON');
  }

  /// Tables whose every change is captured for undo.
  ///
  /// Note what is absent: the three journal tables themselves. Capturing the
  /// journal in the journal would recurse.
  List<TableInfo<Table, dynamic>> get journaledTables => [
    projects,
    mapObjects,
    // Memberships are derived, but journaling them is what makes a boundary
    // edit undoable and what lets label history explain why a plant's
    // identifier changed when the plant itself was never touched.
    plantMemberships,
    vines,
    fieldDefs,
    fieldEvents,
  ];

  /// Seeds the context row, indexes the journal, and installs the triggers.
  ///
  /// Called from **both** `onCreate` and `onUpgrade`. Installing triggers only
  /// on create is the classic version of this bug: every test passes against a
  /// fresh database while the undo button on an upgraded device never lights
  /// up, because nothing is ever captured.
  Future<void> _installUndoJournal() async {
    // The single context row. Its absence would make every trigger a silent
    // no-op, which looks exactly like undo being broken.
    await customStatement(
      'INSERT OR IGNORE INTO undo_context (id, operation_id) VALUES (1, NULL)',
    );

    // The undo stack: newest applied operation for a project.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_operations_stack '
      'ON operations (project_id, id DESC)',
    );
    // Replaying one operation reads its rows in id order.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_operation_rows_op '
      'ON operation_rows (operation_id, id)',
    );
    // Label history asks for one vine's whole past.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_operation_rows_row '
      'ON operation_rows (row_id, id)',
    );

    for (final table in journaledTables) {
      for (final statement in _captureTriggers(table)) {
        await customStatement(statement);
      }
    }
  }

  /// Builds the three capture triggers for one table.
  ///
  /// The column list is read from drift's own table metadata rather than
  /// written out by hand. Eighteen hand-maintained trigger bodies would be a
  /// standing invitation to add a column and silently stop capturing it -- and
  /// the symptom would be an undo that restores a row with one field quietly
  /// wrong, which is worse than an undo that fails outright.
  List<String> _captureTriggers(TableInfo<Table, dynamic> table) {
    final name = table.actualTableName;
    final columns = table.$columns.map((c) => c.name).toList();

    String jsonOf(String alias) =>
        'json_object(${columns.map((c) => "'$c', $alias.$c").join(', ')})';

    // Read twice per statement rather than joined: undo_context holds exactly
    // one row, so this is two constant-time lookups.
    const active = '(SELECT operation_id FROM undo_context WHERE id = 1)';

    String body(String rowRef, String before, String after) =>
        'INSERT INTO operation_rows '
        '(operation_id, target_table, row_id, before, after) '
        "SELECT $active, '$name', $rowRef, $before, $after "
        'WHERE $active IS NOT NULL;';

    return [
      'CREATE TRIGGER IF NOT EXISTS jr_${name}_insert '
          'AFTER INSERT ON $name BEGIN '
          '${body('NEW.id', 'NULL', jsonOf('NEW'))} END',
      'CREATE TRIGGER IF NOT EXISTS jr_${name}_update '
          'AFTER UPDATE ON $name BEGIN '
          '${body('OLD.id', jsonOf('OLD'), jsonOf('NEW'))} END',
      'CREATE TRIGGER IF NOT EXISTS jr_${name}_delete '
          'AFTER DELETE ON $name BEGIN '
          '${body('OLD.id', jsonOf('OLD'), 'NULL')} END',
    ];
  }

  Future<void> _createIndexes() async {
    // The hot path: resolving a vine's current value for one field.
    // Ordering matches the query exactly (observed desc, then recorded desc)
    // so SQLite can satisfy it from the index without a sort.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_events_lookup '
      'ON field_events (vine_id, field_def_id, observed_at DESC, recorded_at DESC)',
    );

    // Rolling back an import means finding every event it wrote.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_events_batch '
      'ON field_events (batch_id) WHERE batch_id IS NOT NULL',
    );

    // Plants along one line, in order: what numbering and insertion both walk.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_vines_carrier '
      'ON vines (carrier_id, position_idx)',
    );

    // The canvas loads every vine in a project at once, so this is the single
    // most-used index in the app.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_vines_project ON vines (project_id)',
    );

    // Drawing and painting both ask for a project's objects, and the canvas
    // asks for one field's instances when a draw tool is active.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_objects_project '
      'ON map_objects (project_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_objects_field '
      'ON map_objects (field_def_id)',
    );

    // Rendering an identifier asks "this plant's value for this field", which
    // is the whole reason field_def_id is denormalised onto the membership.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_membership_vine '
      'ON plant_memberships (vine_id, field_def_id)',
    );
    // Reconciliation after a geometry edit asks the other direction.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_membership_object '
      'ON plant_memberships (object_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_field_defs_project ON field_defs (project_id)',
    );
  }
}
