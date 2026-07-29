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

/// A vineyard. Each has its own image, schema, and plants (decision D10).
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
  /// plants -- so the new photo is dragged and scaled into alignment instead,
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

  /// How a plant's identifier is composed, as JSON:
  /// `{"delimiter":".","parts":[{"field":"<uuid>"},{"plant":true}]}`
  ///
  /// Null means the project has not composed one yet, and identifiers fall back
  /// to the bare plant number -- so a half-configured project is still usable
  /// rather than showing nothing.
  ///
  /// `projects` is already journaled, so changing this is undoable and shows up
  /// in label history without any extra machinery.
  TextColumn get identifierTemplate => text().nullable()();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// One drawn thing: a row, a block, a road, a post.
///
/// Replaces the `blocks` and `vine_rows` tables. Both were the same idea with
/// different geometry, and hardcoding them fixed the hierarchy at
/// `block.row.plant` -- which is one vineyard's convention, not a law. An
/// instance's kind comes from its [fieldDefId]: the field carries the draw
/// type, whether it is a container, and its name.
@DataClassName('MapObject')
class MapObjects extends Table {
  TextColumn get id => text()();

  /// Always set. The field is nullable-free too, but a project reference means
  /// an object drawn before anything else still has somewhere to belong.
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  /// Which object field this is an instance of -- Row, Block, Road.
  TextColumn get fieldDefId =>
      text().references(FieldDefs, #id, onDelete: KeyAction.cascade)();

  /// This instance's name: `12` for a row, `north gate` for a point. Not unique
  /// by constraint -- renumbering flows pass through transient duplicates.
  TextColumn get label => text().withLength(min: 1, max: 100)();

  /// JSON `[[x,y], ...]` in image pixel coordinates. No georeferencing.
  ///
  /// One point for a point, at least two for a polyline, at least three for a
  /// polygon, which is implicitly closed. Null until drawn -- an object can be
  /// named before it has a shape, the same reason `vine_rows.path` was
  /// nullable.
  TextColumn get geometry => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();
  IntColumn get deletedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// Which container objects a plant falls inside, derived from geometry.
///
/// **Stored rather than computed at read time**, for three reasons that all
/// matter:
///
///  * This table is journaled, so the capture triggers record every membership
///    change for free. That is what lets label history answer "what was this
///    called in 2025?" after a boundary edit swept a plant into another block.
///  * Undo replays membership changes generically, with no inverse code.
///  * Reads stay a join. Point-in-polygon per plant per frame is not a budget.
///
/// Distinct from `plants.carrierId`, which is the **one** polyline a plant is
/// physically snapped to. Membership is many: a plant can be in Row 12 and
/// Terrace 3 at once while sliding along only Row 12.
class PlantMemberships extends Table {
  /// Required even though a composite key would do: the capture triggers
  /// reference `NEW.id` on every journaled table.
  TextColumn get id => text()();

  TextColumn get plantId =>
      text().references(Plants, #id, onDelete: KeyAction.cascade)();
  TextColumn get objectId =>
      text().references(MapObjects, #id, onDelete: KeyAction.cascade)();

  /// Denormalised from the object, because every read asks "this plant's value
  /// for this field" and the join to find it would be on the hot path.
  TextColumn get fieldDefId =>
      text().references(FieldDefs, #id, onDelete: KeyAction.cascade)();

  IntColumn get createdAt => integer().map(const DateTimeMsConverter())();
  IntColumn get updatedAt => integer().map(const DateTimeMsConverter())();

  /// **No `deletedAt`**, deliberately breaking this file's convention.
  ///
  /// Memberships are derived: any device can recompute them from geometry, so
  /// a tombstone carries nothing a sync would need. And a boundary edit that
  /// sweeps 400 plants would otherwise leave 400 tombstones behind, every
  /// time.
  @override
  Set<Column> get primaryKey => {id};
}

/// An individual plant.
///
/// **Invariant: `id` never changes.** Only `positionIdx` and the identifier
/// rendered from it change. Every field event references this UUID, so
/// renumbering can never orphan or misattribute data (plan section 6.3).
///
/// Called a *plant* rather than a vine throughout: nothing in the engine is
/// specific to grapes, and the name is the only thing that would have had to
/// change to use this for an orchard.
class Plants extends Table {
  TextColumn get id => text()();

  /// Always set, because both parents below are nullable and a plant must still
  /// belong somewhere. Without this an unassigned plant would be unreachable.
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  /// The polyline this plant is physically snapped to, and the only thing
  /// [pathOffset] is measured along. **At most one.**
  ///
  /// Non-null means the plant really is on that line: there is no separate flag
  /// that could disagree with reality. Clearing it detaches the plant, which
  /// then keeps its own x/y.
  ///
  /// Container membership is a *different relationship* and may be many -- see
  /// [PlantMemberships]. A plant can be inside Block 2 and on Terrace 3 while
  /// sliding along only Row 12.
  ///
  /// `setNull` on delete rather than cascade: deleting a line should orphan its
  /// plants, not destroy them along with their entire recorded history.
  TextColumn get carrierId => text().nullable().references(
    MapObjects,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// The plant's own number, and usually the last part of its identifier.
  ///
  /// Unique within its carrier's scope, including the carrier-less scope, but
  /// **not** enforced by a database constraint: inserting a plant mid-line
  /// shifts subsequent indices, and the intermediate states would violate a
  /// unique index. Enforced in application code inside a transaction instead.
  IntColumn get positionIdx => integer()();

  RealColumn get x => real().nullable()();
  RealColumn get y => real().nullable()();

  /// Distance along the row's path from its start, when snapped.
  ///
  /// Reshaping or moving a row repositions its plants from this rather than by
  /// re-projecting their x/y onto the new path. Re-projection loses a little
  /// accuracy every time and drifts visibly after a few edits; an offset is
  /// exact and lets a plant keep its place when the far end of a row is
  /// extended.
  RealColumn get pathOffset => real().nullable()();

  TextColumn get status =>
      textEnum<PlantStatus>().withDefault(const Constant('active'))();

  IntColumn get plantedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  /// Set when the plant is retired. Its history is retained (decision D7).
  IntColumn get endedAt =>
      integer().nullable().map(const DateTimeMsConverter())();

  /// The plant this one replaced, if it is a replant. Self-referencing.
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
/// A gesture is not a DAO call: "Replace with New Plant" retires one plant,
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

  /// Machine-readable operation type, e.g. `move_plant`, `delete_row`.
  TextColumn get kind => text()();

  /// The text on the undo button: "Delete row 12 (40 plants)".
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

  /// Named `targetTable` rather than the obvious `tableName`: drift declares a
  /// [Table.tableName] getter on every table, and a column of that name would
  /// shadow it.
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
  ///
  /// Always [FieldType.text] for an object field -- object labels are text.
  TextColumn get type => textEnum<FieldType>()();

  /// Whether this field is a value on a plant or something drawn on the map.
  TextColumn get role =>
      textEnum<FieldRole>().withDefault(const Constant('attribute'))();

  /// Null for attributes.
  ///
  /// **Immutable once created**, like [type] and for the same reason: changing
  /// a polyline field to a polygon would invalidate every geometry already
  /// drawn against it.
  TextColumn get drawType => textEnum<DrawType>().nullable()();

  /// Objects only. A container puts a value on **every** plant, blank or not,
  /// derived from which of its instances the plant falls inside. A
  /// non-container touches plants not at all -- draw a road, and no plant
  /// gains a field or changes in any way.
  BoolColumn get isContainer => boolean().withDefault(const Constant(false))();

  /// What an identifier renders where this field has no value.
  ///
  /// The generic form of the old reserved `"0"`, now chosen per field: `0` for
  /// Row, `none` for Clone. A real value equal to this is refused, or `0.12.7`
  /// becomes ambiguous between a genuine address and an unassigned one -- the
  /// exact trap the hardcoded version documented.
  TextColumn get blankPlaceholder => text().nullable()();

  /// Polyline containers only: how close a plant must be, in layout pixels, to
  /// count as on the line. Null uses `MembershipService.defaultTolerance`.
  ///
  /// Needed because a polygon has an interior and a line does not: "inside" is
  /// exact, "on" is a judgement about how accurately someone tapped.
  RealColumn get tolerance => real().nullable()();

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
  TextColumn get plantId =>
      text().references(Plants, #id, onDelete: KeyAction.cascade)();
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
