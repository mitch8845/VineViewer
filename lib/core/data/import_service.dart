import 'package:uuid/uuid.dart';

import '../db/daos/field_defs_dao.dart';
import '../db/daos/field_events_dao.dart';
import '../db/database.dart';
import '../import/table_reader.dart';
import '../models/enums.dart';
import '../models/field_value.dart';
import 'label_service.dart';

/// One cell that will not be written, and why.
typedef ImportProblem = ({String plantId, String value, String message});

/// What an import would write to one field.
class ImportColumn {
  const ImportColumn({
    required this.field,
    required this.header,
    required this.values,
    required this.rejected,
    required this.unchanged,
    required this.alreadyHeld,
  });

  final FieldDef field;
  final String header;

  /// Validated values to write, stored form, by plant id. Excludes cells that
  /// already hold exactly this value -- re-importing the same sheet writes
  /// nothing rather than doubling every plant's history.
  final Map<String, String> values;

  /// Cells refused by the field's rules, by plant identifier text.
  final List<ImportProblem> rejected;

  /// Plants whose current value already equals the sheet's.
  final int unchanged;

  /// For write-once fields: plants in [values] that already hold a
  /// *different* value. The user decides whether those are overwritten.
  final Set<String> alreadyHeld;
}

/// Everything an import would do, worked out before anything is written.
class ImportPlan {
  const ImportPlan({
    required this.rowCount,
    required this.idHeader,
    required this.matchedRows,
    required this.unknownIds,
    required this.duplicateIds,
    required this.columns,
    required this.ignoredHeaders,
    required this.identifierHeaders,
  });

  final int rowCount;
  final String idHeader;
  final int matchedRows;

  /// IDs in the sheet with no living plant of that name in the project.
  final List<String> unknownIds;

  /// IDs appearing on more than one row. Only the first row is used.
  final List<String> duplicateIds;

  final List<ImportColumn> columns;

  /// Headers that match no recordable field -- position columns like Block
  /// and Row, or anything the project does not record.
  final List<String> ignoredHeaders;

  /// Headers naming a field that is part of the plant ID. Refused outright:
  /// importing them would rename plants, and that gets counted and confirmed
  /// one change at a time, not slipped in with a spreadsheet.
  final List<String> identifierHeaders;

  int get writeCount => columns.fold(0, (n, c) => n + c.values.length);
  bool get hasWrites => writeCount > 0;
  bool get hasWriteOnceConflicts =>
      columns.any((c) => c.alreadyHeld.isNotEmpty);
}

/// The outcome of [ImportService.apply].
class ImportResult {
  const ImportResult({required this.written, required this.skippedHeld});
  final int written;
  final int skippedHeld;
}

/// Imports values from a spreadsheet into a project's plants.
///
/// Rows are matched to plants by **identifier** -- the `3.12.7` the app
/// shows -- and columns to fields by **name**, which is what the field
/// editor's "Import matches spreadsheet columns to this name" has promised
/// since the start. Every cell goes through the same validation as a value
/// typed into the inspector, so a spreadsheet cannot put anything into the
/// project that a person could not.
class ImportService {
  ImportService({
    required this.fieldDefs,
    required this.events,
    required this.labels,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final FieldDefsDao fieldDefs;
  final FieldEventsDao events;
  final LabelService labels;
  final Uuid _uuid;

  static const _idHeaders = {'id', 'plant id', 'plantid', 'identifier'};

  Future<ImportPlan> plan(String projectId, TableData table) async {
    String norm(String s) => s.trim().toLowerCase();

    final idColumn = table.headers.indexWhere(
      (h) => _idHeaders.contains(norm(h)),
    );
    if (idColumn < 0) {
      throw const TableReadException(
        'No ID column. Name the column holding plant IDs "ID".',
      );
    }

    // Living plants only: a retired plant can share its ID with the
    // replacement standing where it was, and the sheet means the living one.
    final byText = <String, String>{};
    for (final e in (await labels.identifiersForProject(projectId)).entries) {
      if (e.value.retired) continue;
      byText[e.value.text] = e.key;
    }

    final template = await labels.templateFor(projectId);
    final fields = {
      for (final f in await fieldDefs.forProject(projectId)) norm(f.name): f,
    };

    final columns = <int, FieldDef>{};
    final ignored = <String>[];
    final identifierHeaders = <String>[];
    for (var c = 0; c < table.headers.length; c++) {
      if (c == idColumn) continue;
      final header = table.headers[c];
      if (header.isEmpty) continue;
      final field = fields[norm(header)];
      if (field == null || field.role != FieldRole.attribute) {
        ignored.add(header);
      } else if (template.fieldIds.contains(field.id)) {
        identifierHeaders.add(header);
      } else {
        columns[c] = field;
      }
    }

    // Rows to plants, first occurrence wins.
    final rowFor = <String, List<String?>>{};
    final unknown = <String>[];
    final duplicates = <String>{};
    final seen = <String>{};
    for (final row in table.rows) {
      final id = table.cell(row, idColumn)?.trim();
      if (id == null || id.isEmpty) continue;
      if (!seen.add(id)) {
        duplicates.add(id);
        continue;
      }
      final plantId = byText[id];
      if (plantId == null) {
        unknown.add(id);
      } else {
        rowFor[plantId] = row;
      }
    }
    final idOf = {for (final e in byText.entries) e.value: e.key};

    final planned = <ImportColumn>[];
    for (final entry in columns.entries) {
      final field = entry.value;
      final config = fieldDefs.configOf(field);
      final current = await events.currentValuesForField(field.id);
      final values = <String, String>{};
      final rejected = <ImportProblem>[];
      final held = <String>{};
      var unchanged = 0;

      for (final row in rowFor.entries) {
        final raw = table.cell(row.value, entry.key)?.trim();
        // Blank means "nothing to say", never "clear it": an empty cell in a
        // half-filled sheet must not erase what was recorded on the tablet.
        if (raw == null || raw.isEmpty) continue;

        final result = FieldValueCodec.encode(
          type: field.type,
          input: _dateFromSerial(field.type, raw) ?? raw,
          config: config,
        );
        switch (result) {
          case FieldValueRejected(:final message):
            rejected.add((
              plantId: idOf[row.key] ?? row.key,
              value: raw,
              message: message,
            ));
          case FieldValueAccepted(:final stored):
            if (stored == null) continue;
            final existing = current[row.key]?.value;
            if (existing == stored) {
              unchanged++;
              continue;
            }
            values[row.key] = stored;
            if (field.isStatic && existing != null) held.add(row.key);
        }
      }

      planned.add(
        ImportColumn(
          field: field,
          header: table.headers[entry.key],
          values: values,
          rejected: rejected,
          unchanged: unchanged,
          alreadyHeld: held,
        ),
      );
    }

    return ImportPlan(
      rowCount: table.rows.length,
      idHeader: table.headers[idColumn],
      matchedRows: rowFor.length,
      unknownIds: unknown,
      duplicateIds: duplicates.toList(),
      columns: planned,
      ignoredHeaders: ignored,
      identifierHeaders: identifierHeaders,
    );
  }

  /// Writes a plan. Wrap in an operation so it is one press of undo.
  ///
  /// Values are written as bulk batches, one per field and value, all sharing
  /// one batch id and marked as an import -- so the whole import can also be
  /// told apart from hand entry in each plant's history.
  Future<ImportResult> apply(
    ImportPlan plan, {
    required bool overwriteWriteOnce,
    DateTime? now,
  }) async {
    final batchId = _uuid.v4();
    final timestamp = now ?? DateTime.now();
    var written = 0;
    var skipped = 0;

    for (final column in plan.columns) {
      final byValue = <String, List<String>>{};
      for (final e in column.values.entries) {
        if (!overwriteWriteOnce && column.alreadyHeld.contains(e.key)) {
          skipped++;
          continue;
        }
        (byValue[e.value] ??= []).add(e.key);
      }
      for (final e in byValue.entries) {
        await events.recordBulk(
          plantIds: e.value,
          fieldDefId: column.field.id,
          value: e.key,
          source: EventSource.import,
          batchId: batchId,
          now: timestamp,
        );
        written += e.value.length;
      }
    }
    return ImportResult(written: written, skippedHeld: skipped);
  }

  /// An Excel date arrives as a day count since 1899-12-30. Turned into a
  /// date only for date fields, and only when it looks like one.
  static DateTime? _dateFromSerial(FieldType type, String raw) {
    if (type != FieldType.date && type != FieldType.datetime) return null;
    final serial = double.tryParse(raw);
    if (serial == null || serial < 1 || serial > 120000) return null;
    final days = serial.floor();
    final ms = ((serial - days) * Duration.millisecondsPerDay).round();
    // Counted in UTC, which has no daylight saving: adding days to a local
    // date across a clock change lands an hour short, on the previous day.
    final u = DateTime.utc(
      1899,
      12,
      30,
    ).add(Duration(days: days, milliseconds: ms));
    return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
  }
}
