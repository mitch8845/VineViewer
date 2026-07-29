import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/label_service.dart';
import 'data/membership_service.dart';
import 'data/numbering_service.dart';
import 'data/operation_recorder.dart';
import 'data/undo_service.dart';
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

/// Derives which containers hold each plant, from geometry.
final membershipServiceProvider = Provider(
  (ref) => MembershipService(ref.watch(databaseProvider)),
);

/// Numbers a selection of plants, refusing anything that would collide.
final numberingServiceProvider = Provider(
  (ref) => NumberingService(
    ref.watch(databaseProvider),
    ref.watch(labelServiceProvider),
  ),
);

final layoutDaoProvider = Provider(
  (ref) => LayoutDao(
    ref.watch(databaseProvider),
    ref.watch(labelServiceProvider),
    ref.watch(membershipServiceProvider),
  ),
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

/// Wraps a user gesture so it can be undone as one thing.
///
/// Called from the feature layer, never from inside a DAO -- a DAO cannot know
/// where a gesture begins or ends.
final operationRecorderProvider = Provider(
  (ref) => OperationRecorder(ref.watch(databaseProvider)),
);

final undoServiceProvider = Provider(
  (ref) => UndoService(ref.watch(databaseProvider)),
);

/// Live list of projects for the project picker.
final projectListProvider = StreamProvider(
  (ref) => ref.watch(projectsDaoProvider).watchAll(),
);
