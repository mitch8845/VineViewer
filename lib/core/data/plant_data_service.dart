import '../db/daos/field_defs_dao.dart';
import '../db/daos/field_events_dao.dart';
import '../db/database.dart';
import '../models/enums.dart';
import '../models/field_value.dart';

/// Outcome of writing a value to a plant.
sealed class WriteResult {
  const WriteResult();
}

class WriteSucceeded extends WriteResult {
  const WriteSucceeded(this.eventId);
  final String eventId;
}

class WriteBulkSucceeded extends WriteResult {
  const WriteBulkSucceeded({required this.batchId, required this.plantCount});
  final String batchId;
  final int plantCount;
}

/// The value failed validation for the field's type. [message] names the rule.
class WriteRejected extends WriteResult {
  const WriteRejected(this.message);
  final String message;

  @override
  String toString() => 'Rejected($message)';
}

/// The field is static and already holds a value (decision D6).
///
/// Carries the existing event so the UI can show what is already there, and
/// callers can retry with `force: true` to overwrite deliberately.
class WriteLocked extends WriteResult {
  const WriteLocked({required this.message, required this.existing});
  final String message;
  final FieldEvent existing;
}

/// The field definition does not exist, or belongs to another project.
class WriteUnknownField extends WriteResult {
  const WriteUnknownField(this.fieldDefId);
  final String fieldDefId;
}

/// Validated writes to the event log.
///
/// Every user-initiated value change goes through here rather than straight to
/// [FieldEventsDao]. The DAO is deliberately unpoliced -- import and archive
/// restore need to write whatever the source says -- so the type and
/// write-once rules live at this layer, where a user is on the other end and
/// can be told what went wrong.
class PlantDataService {
  PlantDataService({required this.fieldDefs, required this.events});

  final FieldDefsDao fieldDefs;
  final FieldEventsDao events;

  /// Records a value for one plant.
  ///
  /// Set [force] to overwrite a static field that already holds a value. The
  /// lock exists to stop a plant date being clobbered by a stray tap, not to
  /// make a typo permanent -- so there is an escape hatch, and it is explicit.
  Future<WriteResult> setValue({
    required String plantId,
    required String fieldDefId,
    required Object? input,
    DateTime? observedAt,
    String? note,
    bool force = false,
    EventSource source = EventSource.manual,
    DateTime? now,
  }) async {
    final def = await fieldDefs.byId(fieldDefId);
    if (def == null) return WriteUnknownField(fieldDefId);

    if (def.isStatic && !force) {
      final existing = await events.currentEvent(plantId, fieldDefId);
      // A cleared static field is writable again -- clearing is the deliberate
      // act of unlocking it.
      if (existing != null && existing.value != null) {
        return WriteLocked(
          message:
              '"${def.name}" is a static field and already holds '
              '"${existing.value}". Static fields are write-once.',
          existing: existing,
        );
      }
    }

    final config = fieldDefs.configOf(def);
    final validated = FieldValueCodec.encode(
      type: def.type,
      input: input,
      config: config,
    );

    switch (validated) {
      case FieldValueRejected(:final message):
        return WriteRejected('${def.name}: $message');
      case FieldValueAccepted(:final stored):
        final id = await events.record(
          plantId: plantId,
          fieldDefId: fieldDefId,
          value: stored,
          observedAt: observedAt,
          source: source,
          note: note,
          now: now,
        );
        return WriteSucceeded(id);
    }
  }

  /// Records the same value across a resolved selection of plants.
  ///
  /// Validation happens once -- the value is identical for every plant, so
  /// validating per plant would repeat identical work thousands of times for a
  /// block-wide edit.
  ///
  /// Static fields are **not** individually checked here. Doing so would mean
  /// a query per plant, and a partial result where some plants took the value
  /// and others silently did not is worse than either outcome. Callers doing a
  /// bulk write to a static field should confirm with the user first; the
  /// batch is undoable either way.
  Future<WriteResult> setValueForSelection({
    required Iterable<String> plantIds,
    required String fieldDefId,
    required Object? input,
    DateTime? observedAt,
    String? note,
    DateTime? now,
  }) async {
    final def = await fieldDefs.byId(fieldDefId);
    if (def == null) return WriteUnknownField(fieldDefId);

    final config = fieldDefs.configOf(def);
    final validated = FieldValueCodec.encode(
      type: def.type,
      input: input,
      config: config,
    );

    switch (validated) {
      case FieldValueRejected(:final message):
        return WriteRejected('${def.name}: $message');
      case FieldValueAccepted(:final stored):
        final ids = plantIds.toList();
        final batchId = await events.recordBulk(
          plantIds: ids,
          fieldDefId: fieldDefId,
          value: stored,
          observedAt: observedAt,
          note: note,
          now: now,
        );
        return WriteBulkSucceeded(batchId: batchId, plantCount: ids.length);
    }
  }

  /// Current values for one plant, rendered for display.
  ///
  /// Keyed by field id, with labels and formatting already applied, so the
  /// inspector does not need the config to show a row.
  Future<Map<String, String?>> displayValues(
    String projectId,
    String plantId, {
    DateTime? asOf,
  }) async {
    final defs = await fieldDefs.forProject(projectId);
    final current = await events.currentValuesForPlant(plantId, asOf: asOf);

    return {
      for (final def in defs)
        def.id: FieldValueCodec.display(
          type: def.type,
          stored: current[def.id]?.value,
          config: fieldDefs.configOf(def),
        ),
    };
  }
}
