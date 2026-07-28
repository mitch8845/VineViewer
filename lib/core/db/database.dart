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
  tables: [Projects, Blocks, VineRows, Vines, FieldDefs, FieldEvents],
)
class AppDatabase extends _$AppDatabase {
  /// Pass an executor for tests (`NativeDatabase.memory()`); omit it in the app
  /// to open the on-device file.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'vineviewer'));

  /// Still 1: no build has ever opened this database, so there is no data
  /// anywhere to migrate. `main.dart` does not construct AppDatabase yet.
  ///
  /// **That ends with the first release that opens it.** From then on every
  /// schema change needs a numbered migration step below and a fixture proving
  /// it works against real prior-version data.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (m, from, to) async {
      // No migrations yet. When the first one lands, add a numbered step here
      // and a corresponding schema fixture under test/ -- a migration that has
      // never been executed against real prior-version data is a guess.
    },
    beforeOpen: (details) async {
      // Must be enabled per connection: SQLite defaults foreign keys OFF, so
      // without this the references declared in tables.dart are inert and
      // orphaned rows accumulate silently.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

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
