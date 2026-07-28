/// Schema for the vineyard data core (plan section 5.2).
///
/// Conventions applied throughout, each load-bearing for a stated goal:
///
/// * **UUID text primary keys.** Two devices can create rows offline without
///   colliding, which is what makes the deferred sync in section 8 possible at
///   all. Autoincrement integers would foreclose it.
/// * **Soft deletes** (`deletedAt`). A hard delete cannot propagate to another
///   device -- the absence of a row is indistinguishable from never having
///   seen it. Also makes "recoverable from trash" cheap.
/// * **`updatedAt` on every mutable row**, so a future sync has a
///   last-write-wins baseline without extra bookkeeping.
/// * **Timestamps in UTC milliseconds** -- see [DateTimeMsConverter].
library;

import 'package:drift/drift.dart';

import '../models/enums.dart';
import 'converters.dart';

/// A vineyard. Each has its own image, schema, and vines (decision D10).
class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 200)();

  /// Filesystem path to the aerial image. Images are never stored as BLOBs;
  /// a multi-megabyte blob would be read into memory on every row fetch.
  TextColumn get imagePath => text().nullable()();
  IntColumn get imageWidth => integer().nullable()();
  IntColumn get imageHeight => integer().nullable()();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// Top level of the `block.row.plant` hierarchy (decision D9).
class Blocks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  /// The "block" segment of the label. Not unique by constraint -- renumbering
  /// flows move through transient duplicate states.
  TextColumn get label => text().withLength(min: 1, max: 100)();

  /// JSON polygon in image pixel coordinates. No georeferencing (non-goal).
  TextColumn get boundary => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// A row of vines within a block.
///
/// Named `vine_rows` rather than `rows`: ROWS is a keyword in SQLite's window
/// function syntax, and an unquoted reference in any hand-written statement
/// would be a parse error. Not worth the ambiguity for four characters.
@DataClassName('VineRow')
class VineRows extends Table {
  @override
  String get tableName => 'vine_rows';

  TextColumn get id => text()();
  TextColumn get blockId =>
      text().references(Blocks, #id, onDelete: KeyAction.cascade)();
  TextColumn get label => text().withLength(min: 1, max: 100)();

  /// Endpoints in image pixel coordinates.
  RealColumn get startX => real().nullable()();
  RealColumn get startY => real().nullable()();
  RealColumn get endX => real().nullable()();
  RealColumn get endY => real().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// An individual vine.
///
/// **Invariant: `id` never changes.** Only `positionIdx` and the derived
/// `block.row.plant` label change. Every field event references this UUID, so
/// renumbering a row can never orphan or misattribute data (plan section 6.3).
class Vines extends Table {
  TextColumn get id => text()();
  TextColumn get rowId =>
      text().references(VineRows, #id, onDelete: KeyAction.cascade)();

  /// The "plant" segment of the label. Not unique by constraint: inserting a
  /// vine mid-row shifts subsequent indices, and the intermediate states of
  /// that operation would violate a unique index.
  IntColumn get positionIdx => integer()();

  RealColumn get x => real().nullable()();
  RealColumn get y => real().nullable()();

  TextColumn get status =>
      textEnum<VineStatus>().withDefault(const Constant('active'))();

  IntColumn get plantedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  /// Set when the vine is retired. Its history is retained (decision D7).
  IntColumn get endedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  /// The vine this one replaced, if it is a replant. Self-referencing.
  TextColumn get predecessorId => text().nullable()();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// A user-defined field definition.
class FieldDefs extends Table {
  TextColumn get id => text()();
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// Immutable once created (decision D5).
  TextColumn get type => textEnum<FieldType>()();

  /// Static = write-once and then locked (variety, rootstock, plant date).
  /// Tracked = full event history (health, spray, water). Decision D6.
  BoolColumn get isStatic => boolean().withDefault(const Constant(false))();

  /// Type-specific JSON: option lists, min/max, colour ramps, labels.
  TextColumn get config => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// **The event log.** Every field write, ever (decision D4).
///
/// Append-only by intent: a correction is a new event, not an edit. That is
/// what makes year-over-year comparison possible, and it is also why a future
/// sync merges trivially -- two devices adding observations simply union.
class FieldEvents extends Table {
  TextColumn get id => text()();
  TextColumn get vineId =>
      text().references(Vines, #id, onDelete: KeyAction.cascade)();
  TextColumn get fieldDefId =>
      text().references(FieldDefs, #id, onDelete: KeyAction.cascade)();

  /// Serialized per the field's type. NULL means the value was **cleared**,
  /// which is distinct from no event existing at all.
  TextColumn get value => text().nullable()();

  /// When the observation was TRUE. User-editable.
  IntColumn get observedAt => integer().map(const DateTimeMsConverter())();

  /// When it was ENTERED. System-set, never user-editable.
  ///
  /// Both matter: a winemaker sprays on Monday and records it Thursday.
  /// `observedAt` orders the history; `recordedAt` breaks ties deterministically
  /// and answers "what did we believe on date X".
  IntColumn get recordedAt => integer().map(const DateTimeMsConverter())();

  TextColumn get source =>
      textEnum<EventSource>().withDefault(const Constant('manual'))();

  /// Groups an import so it can be rolled back as a unit. Non-null only for
  /// events written by an import (plan section 7.1).
  TextColumn get batchId => text().nullable()();

  TextColumn get note => text().nullable()();

  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}
