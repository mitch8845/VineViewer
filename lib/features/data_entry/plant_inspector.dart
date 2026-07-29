import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/label_service.dart';
import '../../core/data/plant_data_service.dart';
import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';
import '../../core/models/identifier_template.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/tools/identifier_change_prompt.dart';
import '../schema/field_editor_screen.dart';

/// Panel for the selected plant: its address and every field, editable.
///
/// Sits over the canvas rather than replacing it, so the plant stays visible
/// while its values are being read or changed -- in the field you are looking
/// at the plant and the screen at the same time.
class PlantInspector extends ConsumerWidget {
  const PlantInspector({super.key, required this.plantId});

  final String plantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = ref.watch(fieldDefsProvider).valueOrNull ?? const [];
    final identifier = ref.watch(_identifierProvider(plantId)).valueOrNull;
    final containers =
        ref.watch(_containersProvider(plantId)).valueOrNull ?? const {};
    final values = ref.watch(_valuesProvider(plantId)).valueOrNull ?? const {};

    return Card(
      margin: const EdgeInsets.all(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420, maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(
                identifier?.text ?? '...',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              // Container values are worked out from where the plant sits, so
              // they are shown rather than offered: the way to change one is to
              // move the plant or the boundary.
              subtitle: Text(
                containers.isEmpty
                    ? 'Not inside anything'
                    : [
                        for (final e in containers.entries)
                          '${e.key} ${e.value}',
                      ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'ID history',
                    icon: const Icon(Icons.history),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (context) =>
                          _LabelHistorySheet(plantId: plantId),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        ref.read(selectionProvider.notifier).state = const {},
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: fields.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No fields defined yet. Add one to start recording '
                        'observations about this plant.',
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: fields.length,
                      itemBuilder: (context, i) {
                        final field = fields[i];
                        return _FieldRow(
                          plantId: plantId,
                          field: field,
                          event: values[field.id],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

final _identifierProvider = FutureProvider.family<PlantIdentifier?, String>((
  ref,
  plantId,
) async {
  // Depends on the layout so a snap, a renumber, or a boundary edit that
  // changes containment all refresh what is shown.
  ref.watch(layoutSnapshotProvider);
  return ref.watch(labelServiceProvider).identifierOf(plantId);
});

/// Which containers hold this plant, as field name to object name.
///
/// Read-only by nature: these are derived from geometry, so the way to change
/// one is to move the plant or move the boundary.
final _containersProvider = FutureProvider.family<Map<String, String>, String>((
  ref,
  plantId,
) async {
  ref.watch(layoutSnapshotProvider);
  return ref.watch(labelServiceProvider).containersOf(plantId);
});

/// The plant's current values, live.
///
/// A watched query rather than a one-shot read plus a refresh counter. Undo
/// writes to the event log directly, so anything that refreshed on the
/// inspector's own bookkeeping would sit there showing a value that had already
/// been reverted.
final _valuesProvider = StreamProvider.family<Map<String, FieldEvent>, String>((
  ref,
  plantId,
) {
  return ref.watch(fieldEventsDaoProvider).watchCurrentValuesForPlant(plantId);
});

final _historyProvider =
    FutureProvider.family<List<IdentifierChangeRecord>, String>((
      ref,
      plantId,
    ) async {
      ref.watch(layoutSnapshotProvider);
      return ref.watch(labelServiceProvider).historyOf(plantId);
    });

/// Every label this plant has carried.
///
/// The point is reconciling paper: a 2025 notebook saying "3.12.7 looks weak"
/// is guesswork once numbers have been reused or shifted, and this is what
/// turns it back into a fact.
class _LabelHistorySheet extends ConsumerWidget {
  const _LabelHistorySheet({required this.plantId});

  final String plantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider(plantId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: history.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Text('$e'),
          data: (changes) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ID history', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final change in changes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    change == changes.last
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  title: Text(
                    change.identifier.text,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    change.at == null
                        // Honest about the limit: the journal records what
                        // changed a label, never when it was first given.
                        ? 'as far back as the record goes'
                        : '${_date(change.at!)}'
                              '${change.reason == null ? '' : ' -- ${change.reason}'}',
                  ),
                ),
              if (changes.length == 1)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'This plant has never been renamed.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _date(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}

class _FieldRow extends ConsumerWidget {
  const _FieldRow({
    required this.plantId,
    required this.field,
    required this.event,
  });

  final String plantId;
  final FieldDef field;
  final FieldEvent? event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.read(fieldDefsDaoProvider).configOf(field);
    final display = FieldValueCodec.display(
      type: field.type,
      stored: event?.value,
      config: config,
    );

    final swatch = config.optionColors[event?.value];
    final colour = swatch == null ? null : _parseHex(swatch);

    return ListTile(
      dense: true,
      leading: colour == null
          ? null
          : Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
            ),
      title: Text(field.name),
      subtitle: Text(
        display ?? '--',
        style: TextStyle(
          fontWeight: display == null ? FontWeight.normal : FontWeight.bold,
          color: display == null ? Colors.grey : null,
        ),
      ),
      trailing: field.isStatic && event?.value != null
          // Signals write-once before the user taps and gets refused.
          ? const Icon(Icons.lock_outline, size: 18)
          : const Icon(Icons.edit_outlined, size: 18),
      onTap: () => _edit(context, ref, config),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    FieldConfig config,
  ) async {
    final value = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ValueEditorSheet(
        field: field,
        config: config,
        current: event?.value,
      ),
    );
    // Distinguishes "cancelled" from "cleared": the sheet returns the sentinel
    // for a deliberate clear, and null when dismissed.
    if (value == _cancelled) return;
    if (!context.mounted) return;

    final resolved = value == _clear ? null : value;
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    // Gated here rather than inside [_write], which retries itself with
    // `force: true` after a write-once override. Gating there would ask the same
    // question twice for one decision.
    final cleared = await _clearedIdentifierGate(
      context,
      ref,
      projectId,
      resolved,
    );
    if (!cleared || !context.mounted) return;

    await _write(context, ref, resolved);
  }

  /// The gate for a field that is part of the plant's identifier.
  ///
  /// Returns true to go ahead. For the overwhelming majority of fields this
  /// costs one cheap query and returns true immediately -- health scores are not
  /// addresses. But when Clone *is* part of the ID, correcting a clone
  /// readdresses the plant, and until now it did so in silence.
  ///
  /// Two separate checks, because they fail for different reasons:
  ///
  ///  * The value itself may be unusable as an ID part -- containing the
  ///    delimiter, or equal to the placeholder that means "no value here". A
  ///    clone genuinely called `none` would make `12.none.7` ambiguous between a
  ///    real clone and a missing one.
  ///  * The resulting identifiers may collide, which is refused outright.
  Future<bool> _clearedIdentifierGate(
    BuildContext context,
    WidgetRef ref,
    String projectId,
    Object? value,
  ) async {
    final labels = ref.read(labelServiceProvider);
    if (!await labels.isIdentifierPart(
      projectId: projectId,
      fieldDefId: field.id,
    )) {
      return true;
    }

    final template = await labels.templateFor(projectId);
    final text = value?.toString();
    if (text != null) {
      final problem = LabelService.problemWithIdentifierValue(
        value: text,
        delimiter: template.delimiter,
        blankPlaceholder: field.blankPlaceholder,
      );
      if (problem != null) {
        if (!context.mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${field.name} is part of the plant ID. $problem'),
          ),
        );
        return false;
      }
    }

    final change = await labels.previewAttributeChange(
      projectId: projectId,
      fieldDefId: field.id,
      plantIds: [plantId],
      value: text,
    );
    if (!context.mounted) return false;

    return confirmIdentifierChange(
      context,
      change: change,
      action: 'Change ${field.name}',
      proceedLabel: 'Change it',
      refusalAdvice:
          '${field.name} is part of the plant ID. Pick a different value, or '
          'add a part to the ID format that tells these plants apart.',
    );
  }

  Future<void> _write(
    BuildContext context,
    WidgetRef ref,
    Object? value, {
    bool force = false,
  }) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    // One press of undo puts the old value back, and because undo replays the
    // journal rather than appending a correction, the mistaken entry does not
    // linger in this plant's history.
    final result = await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'set_value',
          description: 'Set ${field.name}',
          body: () => ref
              .read(plantDataServiceProvider)
              .setValue(
                plantId: plantId,
                fieldDefId: field.id,
                input: value,
                force: force,
              ),
        );

    if (!context.mounted) return;

    switch (result) {
      case WriteSucceeded():
      case WriteBulkSucceeded():
        // Nothing to do: the values are a watched query, so the write that just
        // landed refreshes the panel on its own.
        break;

      case WriteRejected(:final message):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));

      case WriteLocked(:final message, :final existing):
        // The lock stops a stray tap clobbering a plant date; it is not meant
        // to make a typo permanent, so the override is offered right here.
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Write-once field'),
            content: Text(
              '$message\n\nOverwrite it? The previous value stays in this '
              "plant's history.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Keep "${existing.value}"'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Overwrite'),
              ),
            ],
          ),
        );
        if (overwrite == true && context.mounted) {
          await _write(context, ref, value, force: true);
        }

      case WriteUnknownField():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That field no longer exists.')),
        );
    }
  }
}

Color? _parseHex(String hex) {
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// Returned when the sheet is dismissed without a decision.
const _cancelled = Object();

/// Returned when the user deliberately clears the value.
const _clear = Object();

/// Type-appropriate entry for one field.
class _ValueEditorSheet extends StatefulWidget {
  const _ValueEditorSheet({
    required this.field,
    required this.config,
    required this.current,
  });

  final FieldDef field;
  final FieldConfig config;
  final String? current;

  @override
  State<_ValueEditorSheet> createState() => _ValueEditorSheetState();
}

class _ValueEditorSheetState extends State<_ValueEditorSheet> {
  late final TextEditingController _text = TextEditingController(
    text: widget.current ?? '',
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.field.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          ..._editor(),
          const SizedBox(height: 20),
          Row(
            children: [
              if (widget.current != null)
                TextButton(
                  onPressed: () => Navigator.pop(context, _clear),
                  child: const Text('Clear'),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context, _cancelled),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _editor() {
    switch (widget.field.type) {
      case FieldType.categorical:
      case FieldType.multiSelect:
        // Big tappable options rather than a dropdown: this is the most-used
        // entry path in the field, often one-handed and possibly gloved.
        return [
          for (final option in widget.config.options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    backgroundColor: option == widget.current
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                  ),
                  onPressed: () => Navigator.pop(context, option),
                  child: Text(option, style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
        ];

      case FieldType.boolean:
        return [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(widget.config.trueLabel ?? 'Yes'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(widget.config.falseLabel ?? 'No'),
                ),
              ),
            ],
          ),
        ];

      case FieldType.rating:
        final min = widget.config.effectiveScaleMin;
        final max = widget.config.effectiveScaleMax;
        return [
          Wrap(
            spacing: 8,
            children: [
              for (var v = min; v <= max; v++)
                SizedBox(
                  width: 60,
                  height: 56,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: '$v' == widget.current
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                    ),
                    onPressed: () => Navigator.pop(context, v),
                    child: Text('$v', style: const TextStyle(fontSize: 18)),
                  ),
                ),
            ],
          ),
        ];

      case FieldType.date:
      case FieldType.datetime:
        return [
          TextField(
            controller: _text,
            decoration: const InputDecoration(
              labelText: 'Date',
              hintText: 'YYYY-MM-DD',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(context, _text.text),
            child: const Text('Save'),
          ),
        ];

      default:
        return [
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType:
                widget.field.type == FieldType.integer ||
                    widget.field.type == FieldType.decimal
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            decoration: const InputDecoration(labelText: 'Value'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(context, _text.text),
            child: const Text('Save'),
          ),
        ];
    }
  }
}
