import 'package:flutter/material.dart';

import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';

/// What the user decided in a [ValueEditorSheet].
///
/// A wrapper rather than the raw value, because the sheet has three outcomes
/// and a nullable return can only express two. The old inspector used `null`
/// for "dismissed" and a sentinel for "cleared" -- and a swipe down, which
/// Flutter also reports as `null`, then went through as a **clear**. Swiping
/// the sheet away erased the value it was showing.
class ValueEdit {
  const ValueEdit(this.value);

  /// The new input, unvalidated. Null means clear the field.
  final Object? value;

  bool get isClear => value == null;
}

/// Opens the editor for [field]. Returns null when dismissed without a
/// decision -- by Cancel, by swiping down, or by tapping outside.
Future<ValueEdit?> showValueEditor(
  BuildContext context, {
  required FieldDef field,
  required FieldConfig config,
  String? current,
  String? title,
  bool offerClear = true,
}) {
  return showModalBottomSheet<ValueEdit>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ValueEditorSheet(
      field: field,
      config: config,
      current: current,
      title: title,
      offerClear: offerClear,
    ),
  );
}

/// Type-appropriate entry for one field.
///
/// Shared by the single-plant inspector and the bulk editor, so a field type
/// cannot be enterable one way and not the other.
class ValueEditorSheet extends StatefulWidget {
  const ValueEditorSheet({
    super.key,
    required this.field,
    required this.config,
    required this.current,
    this.title,
    this.offerClear = true,
  });

  final FieldDef field;
  final FieldConfig config;

  /// The stored value being edited, or null for none.
  final String? current;

  /// Overrides the heading, which is otherwise the field name.
  final String? title;

  /// Whether to show Clear. The bulk editor always offers it -- clearing a
  /// value across a row is a real thing to want -- but there is nothing to
  /// clear on a single plant with no value.
  final bool offerClear;

  @override
  State<ValueEditorSheet> createState() => _ValueEditorSheetState();
}

class _ValueEditorSheetState extends State<ValueEditorSheet> {
  late final TextEditingController _text = TextEditingController(
    text: _initialText(),
  );

  /// Ticked options, for multi-select.
  late final Set<String> _picked = {
    ...?FieldValueCodec.decodeMultiSelect(widget.current),
  };

  String _initialText() {
    final current = widget.current;
    if (current == null) return '';
    // A datetime is stored as UTC ISO-8601. Shown as the local wall-clock time
    // it was entered as, or editing it would mean doing timezone arithmetic in
    // your head.
    if (widget.field.type == FieldType.datetime) {
      final parsed = DateTime.tryParse(current);
      if (parsed != null) return _formatDateTime(parsed.toLocal());
    }
    return current;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done(Object? value) => Navigator.pop(context, ValueEdit(value));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title ?? widget.field.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            ..._editor(),
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.offerClear)
                  TextButton(
                    onPressed: () => _done(null),
                    child: const Text('Clear'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle _bigButton({bool highlighted = false}) =>
      OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18),
        backgroundColor: highlighted
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
      );

  List<Widget> _editor() {
    switch (widget.field.type) {
      case FieldType.categorical:
        // Big tappable options rather than a dropdown: this is the most-used
        // entry path in the field, often one-handed and possibly gloved.
        return [
          for (final option in widget.config.options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: _bigButton(highlighted: option == widget.current),
                  onPressed: () => _done(option),
                  child: Text(option, style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
          if (widget.config.allowOther) ..._otherEntry(),
        ];

      case FieldType.multiSelect:
        // Tick several, then save. Tapping one option used to save just that
        // option, so a multi-select field could only ever hold one value.
        return [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in {
                ...widget.config.options,
                // Values entered under "allow other" stay tickable.
                ..._picked,
              })
                FilterChip(
                  label: Text(option, style: const TextStyle(fontSize: 16)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  selected: _picked.contains(option),
                  onSelected: (on) => setState(
                    () => on ? _picked.add(option) : _picked.remove(option),
                  ),
                ),
            ],
          ),
          if (widget.config.allowOther) ..._otherEntry(addToPicked: true),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () =>
                _done(_picked.isEmpty ? null : _picked.toList(growable: false)),
            child: const Text('Save'),
          ),
        ];

      case FieldType.boolean:
        return [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _bigButton(highlighted: widget.current == '1'),
                  onPressed: () => _done(true),
                  child: Text(widget.config.trueLabel ?? 'Yes'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  style: _bigButton(highlighted: widget.current == '0'),
                  onPressed: () => _done(false),
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
            runSpacing: 8,
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
                    onPressed: () => _done(v),
                    child: Text('$v', style: const TextStyle(fontSize: 18)),
                  ),
                ),
            ],
          ),
          if (widget.config.labels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              [
                for (var v = min; v <= max; v++)
                  if (widget.config.labels['$v'] != null)
                    '$v = ${widget.config.labels['$v']}',
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ];

      case FieldType.date:
      case FieldType.datetime:
        final withTime = widget.field.type == FieldType.datetime;
        return [
          TextField(
            controller: _text,
            decoration: InputDecoration(
              labelText: withTime ? 'Date and time' : 'Date',
              hintText: withTime ? 'YYYY-MM-DD HH:MM' : 'YYYY-MM-DD',
              suffixIcon: IconButton(
                tooltip: 'Pick from a calendar',
                icon: const Icon(Icons.calendar_month),
                onPressed: () => _pickDate(withTime: withTime),
              ),
            ),
            onSubmitted: _done,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => _done(
                  withTime
                      ? _formatDateTime(DateTime.now())
                      : _formatDate(DateTime.now()),
                ),
                child: Text(withTime ? 'Now' : 'Today'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _done(_text.text),
                child: const Text('Save'),
              ),
            ],
          ),
        ];

      case FieldType.text:
      case FieldType.integer:
      case FieldType.decimal:
        final numeric = widget.field.type != FieldType.text;
        final hint = _rangeHint();
        return [
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: numeric
                ? TextInputType.numberWithOptions(
                    decimal: widget.field.type == FieldType.decimal,
                    signed: true,
                  )
                : TextInputType.text,
            decoration: InputDecoration(labelText: 'Value', helperText: hint),
            onSubmitted: _done,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _done(_text.text),
            child: const Text('Save'),
          ),
        ];
    }
  }

  /// Free entry under the option buttons, for fields that allow values off the
  /// list. Without it "allow other" was a setting with no way to use it.
  List<Widget> _otherEntry({bool addToPicked = false}) => [
    const SizedBox(height: 8),
    TextField(
      controller: _text,
      decoration: InputDecoration(
        labelText: 'Something else',
        suffixIcon: IconButton(
          icon: Icon(addToPicked ? Icons.add : Icons.check),
          onPressed: () => _submitOther(addToPicked),
        ),
      ),
      onSubmitted: (_) => _submitOther(addToPicked),
    ),
  ];

  void _submitOther(bool addToPicked) {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    if (addToPicked) {
      setState(() {
        _picked.add(value);
        _text.clear();
      });
    } else {
      _done(value);
    }
  }

  String? _rangeHint() {
    final c = widget.config;
    if (c.min != null && c.max != null) return 'From ${c.min} to ${c.max}';
    if (c.min != null) return 'At least ${c.min}';
    if (c.max != null) return 'At most ${c.max}';
    return null;
  }

  Future<void> _pickDate({required bool withTime}) async {
    final existing = DateTime.tryParse(_text.text.trim());
    final now = DateTime.now();
    final first = widget.config.minDate ?? DateTime(1900);
    final last = widget.config.maxDate ?? DateTime(now.year + 50);
    // The picker asserts its initial date is in range, and "today" is outside
    // the range of a field bounded to last season.
    var initial = existing ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (date == null || !mounted) return;

    if (!withTime) {
      setState(() => _text.text = _formatDate(date));
      return;
    }

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(existing ?? now),
    );
    if (!mounted) return;
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    );
    setState(() => _text.text = _formatDateTime(picked));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _formatDateTime(DateTime d) =>
      '${_formatDate(d)} ${_two(d.hour)}:${_two(d.minute)}';
}
