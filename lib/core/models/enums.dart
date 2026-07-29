/// Domain enums shared by the schema and the UI.
///
/// All of these are persisted **by name**, not by index, so reordering or
/// inserting a value cannot silently reinterpret existing rows. Renaming a
/// value is therefore a breaking schema change and needs a migration.
library;

/// The nine user-definable field types (plan section 5.3).
///
/// A field's type is immutable once created (decision D5). To change one, the
/// user creates a new field and imports data into it. That constraint is what
/// keeps the dynamic-schema engine tractable.
enum FieldType {
  text,
  integer,
  decimal,
  boolean,
  date,
  datetime,
  categorical,
  multiSelect,
  rating;

  /// Whether a colour ramp can be configured, which drives map colouring.
  bool get supportsColorRamp =>
      this == FieldType.integer ||
      this == FieldType.decimal ||
      this == FieldType.rating;

  /// Whether the type draws its values from a fixed option list.
  bool get hasOptions =>
      this == FieldType.categorical || this == FieldType.multiSelect;
}

/// What a field *is*.
///
/// The v3 pivot: nothing structural is built in except the plant. A vineyard
/// that wants rows creates a field named Row with role [object] and draw type
/// polyline; one that wants blocks creates Block as a polygon. One that wants
/// neither gets neither.
enum FieldRole {
  /// A value carried by a plant -- health, clone, variety, rating.
  attribute,

  /// Something drawn on the map. Instances live in `map_objects`.
  object,
}

/// How an [FieldRole.object] field is drawn.
enum DrawType {
  /// A line. **Carries plants**: they snap to it and hold an arc-length offset
  /// along it, which is what makes reshape-and-slide work.
  polyline,

  /// A closed area. Contains plants but never carries them.
  polygon,

  /// A single position. Never a container -- a point has no interior, so there
  /// is nothing for it to contain. `FieldDefsDao` enforces that.
  point,
}

/// Lifecycle state of a plant at a position.
///
/// A retired plant keeps its full history (decision D7); it is never deleted.
enum PlantStatus {
  /// Planted and alive.
  active,

  /// Retired -- died or was pulled. Position stays, shown as an empty slot.
  removed,

  /// Position exists in the layout but has never held a plant.
  missing,
}

/// How a field event came to be recorded. Lets an import be identified and
/// rolled back as a unit.
enum EventSource { manual, import, bulk }
