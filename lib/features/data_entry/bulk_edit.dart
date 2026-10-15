import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/label_service.dart';
import '../../core/data/plant_data_service.dart';
import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_value.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/tools/identifier_change_prompt.dart';
import 'value_editor_sheet.dart';

/// Sets one field to one value across a selection of plants.
///
/// The service and the batched write existed from the start; this is the
/// missing front end, and the step the array tools' "draw the rows, then set
/// their attributes with multi-select" workflow was waiting on.
///
/// Goes through the same gates as a single-plant edit, so the answer cannot
/// differ by route:
///
///  * **Identifier fields** are checked for collisions and the rename is
///    counted, exactly as in the inspector.
///  * **Write-once fields** are not overwritten in silence. The service skips
///    that check for speed, so it lives here: the user is told how many already
///    hold a value, and chooses between overwriting them and filling only the
///    gaps -- the second being what "set the planting date on this row" almost
///    always means.
///
/// One press of undo reverts the lot.
Future<void> bulkSetValue(BuildContext context, Set<String> plantIds) async {
  // The container rather than a WidgetRef: this runs across several sheets
  // and dialogs, and the widget that started it is not guaranteed to outlive
  // them.
  final read = ProviderScope.containerOf(context, listen: false).read;
  final projectId = read(activeProjectIdProvider);
  if (projectId == null || plantIds.isEmpty) return;

  final fieldDefs = read(fieldDefsDaoProvider);
  final fields = [
    for (final f in await fieldDefs.forProject(projectId))
      if (f.role == FieldRole.attribute) f,
  ];
  if (!context.mounted) return;

  if (fields.isEmpty) {
    _say(context, 'There are no fields to set yet. Add one under Fields.');
    return;
  }

  final field = await showModalBottomSheet<FieldDef>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _FieldPicker(fields: fields, count: plantIds.length),
  );
  if (field == null || !context.mounted) return;

  final config = fieldDefs.configOf(field);
  final edit = await showValueEditor(
    context,
    field: field,
    config: config,
    title: 'Set ${field.name} on ${_plants(plantIds.length)}',
  );
  if (edit == null || !context.mounted) return;

  // Validated up front so a bad value is refused before any question is asked
  // about it, and so the confirmation can show the value as it will be stored.
  final encoded = FieldValueCodec.encode(
    type: field.type,
    input: edit.value,
    config: config,
  );
  final String? stored;
  switch (encoded) {
    case FieldValueRejected(:final message):
      _say(context, '${field.name}: $message');
      return;
    case FieldValueAccepted(stored: final s):
      stored = s;
  }

  // Which of the selection already holds something, for write-once fields.
  var holding = const <String>{};
  if (field.isStatic) {
    final current = await read(
      fieldEventsDaoProvider,
    ).currentValuesForField(field.id);
    holding = {
      for (final id in plantIds)
        if (current[id]?.value != null) id,
    };
    if (!context.mounted) return;
  }

  final shown =
      FieldValueCodec.display(
        type: field.type,
        stored: stored,
        config: config,
      ) ??
      'nothing (cleared)';

  final decision = await showDialog<_BulkDecision>(
    context: context,
    builder: (context) => _ConfirmDialog(
      field: field,
      shown: shown,
      count: plantIds.length,
      holding: holding.length,
    ),
  );
  if (decision == null || !context.mounted) return;

  final targets = decision.onlyEmpty ? plantIds.difference(holding) : plantIds;
  if (targets.isEmpty) {
    _say(context, 'Every one of them already has a ${field.name}.');
    return;
  }

  final labels = read(labelServiceProvider);
  final isIdPart = await labels.isIdentifierPart(
    projectId: projectId,
    fieldDefId: field.id,
  );
  if (!context.mounted) return;

  if (isIdPart) {
    if (stored != null) {
      final template = await labels.templateFor(projectId);
      final problem = LabelService.problemWithIdentifierValue(
        value: stored,
        delimiter: template.delimiter,
        blankPlaceholder: field.blankPlaceholder,
      );
      if (problem != null) {
        if (context.mounted) {
          _say(context, '${field.name} is part of the plant ID. $problem');
        }
        return;
      }
    }
    final change = await labels.previewAttributeChange(
      projectId: projectId,
      fieldDefId: field.id,
      plantIds: targets,
      value: stored,
    );
    if (!context.mounted) return;
    final ok = await confirmIdentifierChange(
      context,
      change: change,
      action: 'Set ${field.name} on ${_plants(targets.length)}',
      proceedLabel: 'Set it',
      refusalAdvice:
          '${field.name} is part of the plant ID, and these plants would only '
          'be told apart by it. Set it on fewer plants, or add a part to the '
          'ID format that tells them apart.',
    );
    if (!ok || !context.mounted) return;
  }

  final WriteResult result;
  try {
    result = await read(operationRecorderProvider).run(
      projectId: projectId,
      kind: 'bulk_set_value',
      description: 'Set ${field.name} on ${_plants(targets.length)}',
      body: () => read(plantDataServiceProvider).setValueForSelection(
        plantIds: targets,
        fieldDefId: field.id,
        input: edit.value,
        observedAt: decision.observedAt,
      ),
    );
  } catch (e) {
    // One batch in one transaction, so a failure wrote nothing.
    if (context.mounted) _say(context, 'Nothing was changed: $e');
    return;
  }
  if (!context.mounted) return;

  switch (result) {
    case WriteBulkSucceeded(:final plantCount):
      _say(
        context,
        stored == null
            ? 'Cleared ${field.name} on ${_plants(plantCount)}.'
            : 'Set ${field.name} to $shown on ${_plants(plantCount)}.',
      );
    case WriteRejected(:final message):
      _say(context, message);
    case WriteUnknownField():
      _say(context, 'That field no longer exists.');
    case WriteSucceeded():
    case WriteLocked():
      break;
  }
}

String _plants(int n) => n == 1 ? '1 plant' : '$n plants';

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _FieldPicker extends StatelessWidget {
  const _FieldPicker({required this.fields, required this.count});

  final List<FieldDef> fields;
  final int count;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Set a value on ${_plants(count)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final field in fields)
              ListTile(
                leading: Icon(
                  field.isStatic ? Icons.lock_outline : Icons.edit_note,
                ),
                title: Text(field.name),
                subtitle: Text(
                  field.isStatic
                      ? 'Write-once -- you will be asked about plants that '
                            'already have one'
                      : 'Recorded as a new observation on each plant',
                ),
                onTap: () => Navigator.pop(context, field),
              ),
          ],
        ),
      ),
    );
  }
}

class _BulkDecision {
  const _BulkDecision({required this.onlyEmpty, required this.observedAt});
  final bool onlyEmpty;
  final DateTime? observedAt;
}

/// The last look before writing to many plants at once.
///
/// Also where the observation date is set. A spray done on Monday and entered
/// on Thursday is a Monday observation, and with forty plants to cover there
/// is no other moment to say so.
class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.field,
    required this.shown,
    required this.count,
    required this.holding,
  });

  final FieldDef field;
  final String shown;
  final int count;

  /// How many of the selection already hold a value. Only counted for
  /// write-once fields.
  final int holding;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  late bool _onlyEmpty = widget.holding > 0;
  DateTime? _observedOn;

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final observed = _observedOn;

    return AlertDialog(
      title: Text('Set ${field.name} on ${_plants(widget.count)}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${field.name}: '),
                TextSpan(
                  text: widget.shown,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          if (widget.holding > 0) ...[
            const SizedBox(height: 16),
            Text(
              '${widget.holding} of them already '
              '${widget.holding == 1 ? 'has' : 'have'} a ${field.name}, and '
              'it is a write-once field.',
            ),
            RadioGroup<bool>(
              groupValue: _onlyEmpty,
              onChanged: (v) => setState(() => _onlyEmpty = v ?? _onlyEmpty),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    title: Text(
                      'Only the ${widget.count - widget.holding} without one',
                    ),
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: Text('Overwrite all ${widget.count}'),
                    subtitle: const Text('Old values stay in the history'),
                  ),
                ],
              ),
            ),
          ],
          if (!field.isStatic) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    observed == null
                        ? 'Observed: now'
                        : 'Observed: ${observed.year}-'
                              '${observed.month.toString().padLeft(2, '0')}-'
                              '${observed.day.toString().padLeft(2, '0')}',
                  ),
                ),
                TextButton(
                  onPressed: _pickObserved,
                  child: const Text('Change'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'One press of undo reverts all of it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _BulkDecision(
              onlyEmpty: widget.holding > 0 && _onlyEmpty,
              observedAt: observed,
            ),
          ),
          child: const Text('Set it'),
        ),
      ],
    );
  }

  Future<void> _pickObserved() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _observedOn ?? now,
      firstDate: DateTime(now.year - 30),
      // An observation cannot be from the future.
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    // Today means now, to the minute -- not midnight, which would sort a
    // reading taken this afternoon behind one taken this morning.
    final isToday =
        picked.year == now.year &&
        picked.month == now.month &&
        picked.day == now.day;
    // Noon for a past day, so no timezone shift can move it onto a
    // neighbouring date.
    setState(
      () => _observedOn = isToday
          ? null
          : DateTime(picked.year, picked.month, picked.day, 12),
    );
  }
}
