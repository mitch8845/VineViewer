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

  /// How the image is placed beneath the layout.
  ///
  /// **The layout is authoritative; the image moves to fit it.** Replacing an
  /// aerial with a newer one framed slightly differently must not shift 3,000
  /// vines -- so the new photo is dragged and scaled into alignment instead,
  /// and every stored coordinate stays valid.
  RealColumn get imageOffsetX => real().withDefault(const Constant(0))();
  RealColumn get imageOffsetY => real().withDefault(const Constant(0))();

  /// Separate axes so an off-angle photo can be stretched to match. Rotation
  /// is in radians.
  RealColumn get imageScaleX => real().withDefault(const Constant(1))();
  RealColumn get imageScaleY => real().withDefault(const Constant(1))();
  RealColumn get imageRotation => real().withDefault(const Constant(0))();

  /// Optional real-world scale. The user draws a line over something of known
  /// length and types that length; these record the pixel length and the real
  /// length, giving pixels-per-unit.
  ///
  /// All null means uncalibrated, and every tool works in pixels. Calibration
  /// is never required -- the plan's accuracy target is "good enough to
  /// recognise the vineyard", not survey-grade.
  RealColumn get scaleRefPx => real().nullable()();
  RealColumn get scaleRefLength => real().nullable()();

  /// 'ft' or 'm'. Stored rather than assumed so exports can label numbers.
  TextColumn get scaleUnit => text().nullable()();

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

/// A row of vines, optionally within a block.
///
/// Named `vine_rows` rather than `rows`: ROWS is a keyword in SQLite's window
/// function syntax, and an unquoted reference in any hand-written statement
/// would be a parse error. Not worth the ambiguity for four characters.
@DataClassName('VineRow')
class VineRows extends Table {
  @override
  String get tableName => 'vine_rows';

  TextColumn get id => text()();

  /// Always set, for the same reason vines carry one: the block is nullable,
  /// so a row drawn before it is assigned to a block -- and before it has any
  /// vines -- would otherwise have no path to a project and would vanish from
  /// the canvas that just drew it.
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  /// Nullable: a row can exist before it is assigned to a block, which is what
  /// makes the label `0.1.1` -- no block, row 1 -- expressible.
  TextColumn get blockId =>
      text().nullable().references(Blocks, #id, onDelete: KeyAction.setNull)();

  TextColumn get label => text().withLength(min: 1, max: 100)();

  /// The row's shape, as JSON `[[x,y], ...]` in image pixel coordinates.
  /// At least two points.
  ///
  /// A polyline of straight segments, not a curve. Vines are trained on
  /// stakes, so a row that changes direction does so at a hard angle -- a
  /// spline would add arc-length maths and control-point UI to model something
  /// that does not exist in the vineyard.
  ///
  /// Null until the row has been drawn.
  TextColumn get path => text().nullable()();

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

  /// Always set, because both parents below are nullable and a vine must still
  /// belong somewhere. Without this an unassigned vine would be unreachable.
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  /// **Non-null means the vine is physically snapped to that row.** That is
  /// the whole snap model: there is no separate flag that could disagree with
  /// reality. Clearing it detaches the vine, which then keeps its own x/y.
  ///
  /// `setNull` on delete rather than cascade: deleting a row should orphan its
  /// vines, not destroy them along with their entire recorded history.
  TextColumn get rowId => text().nullable().references(
    VineRows,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// The vine's block, held directly rather than derived through its row.
  ///
  /// A vine can have a block but no row -- the label `1.0.1` -- so the block
  /// cannot be looked up via the row. When a vine is snapped to a row this is
  /// kept equal to that row's block.
  TextColumn get blockId =>
      text().nullable().references(Blocks, #id, onDelete: KeyAction.setNull)();

  /// The "plant" segment of the label. Unique within its (block, row) scope,
  /// including the unassigned scope, but **not** enforced by a database
  /// constraint: inserting a vine mid-row shifts subsequent indices, and the
  /// intermediate states of that operation would violate a unique index.
  /// LabelService enforces it inside a transaction instead.
  IntColumn get positionIdx => integer()();

  RealColumn get x => real().nullable()();
  RealColumn get y => real().nullable()();

  /// Distance along the row's path from its start, when snapped.
  ///
  /// Reshaping or moving a row repositions its vines from this rather than by
  /// re-projecting their x/y onto the new path. Re-projection loses a little
  /// accuracy every time and drifts visibly after a few edits; an offset is
  /// exact and lets a vine keep its place when the far end of a row is
  /// extended.
  RealColumn get pathOffset => real().nullable()();

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

// --------------------------------------------------------------- undo journal
//
// Three tables implementing durable undo. Undo has to survive the app being
// killed: an Android tablet carried around a vineyard gets backgrounded and
// reaped by the OS routinely, and an in-memory undo stack would be gone by the
// time the user noticed the mistake.
//
// These three deliberately break two conventions stated at the top of this
// file, for one reason: **the journal is device-local and is never synced.**
// It describes edits made on this device to this database file.
//
//  * Integer autoincrement keys, not UUIDs. There is no cross-device collision
//    to avoid, and the key doubles as the replay order for free -- SQLite's
//    rowid increases monotonically per insert.
//  * No soft deletes. Pruning the journal is meant to reclaim space; a
//    `deleted_at` that kept the rows would defeat the entire point.

/// One user gesture. The unit of undo.
///
/// A gesture is not a DAO call: "Replace with New Vine" retires one vine,
/// creates another, and copies its static fields -- three writes, one row here,
/// one press of undo.
class Operations extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Plain text, deliberately **not** a foreign key to [Projects].
  ///
  /// A cascade here would be self-defeating: purging a project would delete the
  /// journal rows describing that purge, so the operation could never be
  /// replayed. Purge is documented as irreversible and clears the project's
  /// journal explicitly instead.
  TextColumn get projectId => text()();

  /// Machine-readable operation type, e.g. `move_vine`, `delete_row`.
  TextColumn get kind => text()();

  /// The text on the undo button: "Delete row 12 (40 vines)".
  ///
  /// Composed when the operation is recorded, while the labels it names are
  /// still current. Deriving it at undo time would describe the vineyard as it
  /// is now rather than as it was when the mistake was made.
  TextColumn get description => text()();

  /// Null while applied; set when undone, which also makes it redoable.
  IntColumn get undoneAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
}

/// One touched database row, captured before and after.
///
/// Written by the triggers in `database.dart`, never by Dart. Undo replays
/// these in descending [id] restoring [before]; redo ascends applying [after].
class OperationRows extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get operationId =>
      integer().references(Operations, #id, onDelete: KeyAction.cascade)();

  /// Named `targetTable` rather than the obvious `tableName`: drift's own
  /// [Table.tableName] getter is what `VineRows` overrides above, and a column
  /// of that name would shadow it.
  TextColumn get targetTable => text()();

  TextColumn get rowId => text()();

  /// The row as JSON before the change. Null means it did not exist -- so
  /// undoing this entry deletes the row.
  TextColumn get before => text().nullable()();

  /// The row as JSON after. Null means it was deleted.
  TextColumn get after => text().nullable()();
}

/// Single row (`id` is always 1) naming the operation currently being recorded.
///
/// The capture triggers read this and do nothing when it is null. That null is
/// the escape hatch for writes that own their rollback and must not be
/// journaled: XLSX import (which rolls back by `batchId`), test seeding, and
/// undo's own replay -- without the last, undo would record its own inverse and
/// recurse forever.
class UndoContext extends Table {
  IntColumn get id => integer()();
  IntColumn get operationId => integer().nullable()();

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
