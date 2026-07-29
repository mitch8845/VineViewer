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
    Blocks,
    VineRows,
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
  @override
  int get schemaVersion => 2;

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
    },
    beforeOpen: (details) async {
      // Must be enabled per connection: SQLite defaults foreign keys OFF, so
      // without this the references declared in tables.dart are inert and
      // orphaned rows accumulate silently.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Tables whose every change is captured for undo.
  ///
  /// Note what is absent: the three journal tables themselves. Capturing the
  /// journal in the journal would recurse.
  List<TableInfo<Table, dynamic>> get journaledTables => [
    projects,
    blocks,
    vineRows,
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

    // Hierarchy traversal, all frequent enough to matter at 4,000 vines.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_vines_row ON vines (row_id, position_idx)',
    );

    // The canvas loads every vine in a project at once, so this is the single
    // most-used index in the app.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_vines_project ON vines (project_id)',
    );

    // Label allocation asks "what numbers are taken in this scope", including
    // the unassigned scope where both parents are null.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_vines_label_scope '
      'ON vines (project_id, block_id, row_id, position_idx)',
    );

    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_rows_block ON vine_rows (block_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_blocks_project ON blocks (project_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS ix_field_defs_project ON field_defs (project_id)',
    );
  }
}
