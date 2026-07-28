import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/label_service.dart';
import '../../core/data/vine_data_service.dart';
import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../schema/field_editor_screen.dart';

/// Panel for the selected vine: its address and every field, editable.
///
/// Sits over the canvas rather than replacing it, so the vine stays visible
/// while its values are being read or changed -- in the field you are looking
/// at the plant and the screen at the same time.
class VineInspector extends ConsumerWidget {
  const VineInspector({super.key, required this.vineId});

  final String vineId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = ref.watch(fieldDefsProvider).valueOrNull ?? const [];
    final label = ref.watch(_labelProvider(vineId)).valueOrNull;
    final values = ref.watch(_valuesProvider(vineId)).valueOrNull ?? const {};

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
                label?.text ?? '...',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                label == null
                    ? ''
                    : [
                        if (!label.hasBlock) 'no block',
                        if (!label.hasRow) 'not on a row',
                      ].join(' · '),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () =>
                    ref.read(selectionProvider.notifier).state = const {},
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: fields.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No fields defined yet. Add one to start recording '
                        'observations about this vine.',
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: fields.length,
                      itemBuilder: (context, i) {
                        final field = fields[i];
                        return _FieldRow(
                          vineId: vineId,
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

final _labelProvider = FutureProvider.family<VineLabel?, String>((
  ref,
  vineId,
) async {
  // Depend on the layout so a snap or renumber refreshes the label shown.
  ref.watch(layoutSnapshotProvider);
  return ref.watch(labelServiceProvider).labelOf(vineId);
});

final _valuesProvider =
    FutureProvider.family<Map<String, FieldEvent>, String>((ref, vineId) async {
      ref.watch(_valuesRevisionProvider);
      return ref.watch(fieldEventsDaoProvider).currentValuesForVine(vineId);
    });

/// Bumped after a write so the inspector re-reads.
///
/// The event log is append-only and written through a service rather than a
/// watched query, so nothing else would tell the panel its value changed.
final _valuesRevisionProvider = StateProvider<int>((ref) => 0);

class _FieldRow extends ConsumerWidget {
  const _FieldRow({
    required this.vineId,
    required this.field,
    required this.event,
  });

  final String vineId;
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

    await _write(context, ref, value == _clear ? null : value);
  }

  Future<void> _write(
    BuildContext context,
    WidgetRef ref,
    Object? value, {
    bool force = false,
  }) async {
    final result = await ref
        .read(vineDataServiceProvider)
        .setValue(
          vineId: vineId,
          fieldDefId: field.id,
          input: value,
          force: force,
        );

    if (!context.mounted) return;

    switch (result) {
      case WriteSucceeded():
      case WriteBulkSucceeded():
        ref.read(_valuesRevisionProvider.notifier).update((n) => n + 1);

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
              "vine's history.",
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
