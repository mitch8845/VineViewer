import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/label_service.dart';
import 'data/vine_data_service.dart';
import 'db/daos/field_defs_dao.dart';
import 'db/daos/field_events_dao.dart';
import 'db/daos/layout_dao.dart';
import 'db/daos/projects_dao.dart';
import 'db/daos/vines_dao.dart';
import 'db/database.dart';

/// The database, opened once for the process.
///
/// Overridden in tests with an in-memory executor, which is why everything
/// downstream takes it from here rather than constructing its own.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final projectsDaoProvider = Provider(
  (ref) => ProjectsDao(ref.watch(databaseProvider)),
);

final labelServiceProvider = Provider(
  (ref) => LabelService(ref.watch(databaseProvider)),
);

final layoutDaoProvider = Provider(
  (ref) =>
      LayoutDao(ref.watch(databaseProvider), ref.watch(labelServiceProvider)),
);

final vinesDaoProvider = Provider(
  (ref) => VinesDao(ref.watch(databaseProvider)),
);

final fieldDefsDaoProvider = Provider(
  (ref) => FieldDefsDao(ref.watch(databaseProvider)),
);

final fieldEventsDaoProvider = Provider(
  (ref) => FieldEventsDao(ref.watch(databaseProvider)),
);

final vineDataServiceProvider = Provider(
  (ref) => VineDataService(
    fieldDefs: ref.watch(fieldDefsDaoProvider),
    events: ref.watch(fieldEventsDaoProvider),
  ),
);

/// Live list of projects for the project picker.
final projectListProvider = StreamProvider(
  (ref) => ref.watch(projectsDaoProvider).watchAll(),
);
