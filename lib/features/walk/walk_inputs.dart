import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/db/database.dart';
import '../../core/format.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';
import '../canvas/plant_colouring.dart';

/// One field's entry during a walk: the biggest buttons the space allows.
///
/// Every field type gets a one-tap path where one exists -- options, ratings,
/// yes/no, a small whole-number range, today's date -- and a large keypad or
/// text box where it cannot. Whatever is tapped goes straight to [onValue];
/// there is no Save step to forget.
///
/// Keyed by plant by its caller, so a half-typed number never carries over to
/// the next plant.
class WalkFieldInput extends StatefulWidget {
  const WalkFieldInput({
    super.key,
    required this.field,
    required this.config,
    required this.current,
    required this.entered,
    required this.onValue,
    this.recent = const [],
    this.fill = true,
  });

  final FieldDef field;
  final FieldConfig config;

  /// The plant's value before this visit, or null for none.
  final FieldEvent? current;

  /// Whether a value has been given here on this visit.
  final bool entered;

  /// Receives input as [PlantDataService.setValue] takes it.
  final ValueChanged<Object?> onValue;

  /// Text fields only: values used elsewhere in the vineyard, most common
  /// first, offered as buttons.
  final List<String> recent;

  /// Whether the buttons stretch to fill the space. True when this is the
  /// only field on screen; with several, each gets a fixed-height band.
  final bool fill;

  @override
  State<WalkFieldInput> createState() => _WalkFieldInputState();
}

class _WalkFieldInputState extends State<WalkFieldInput> {
  final _typed = TextEditingController();
  late final Set<String> _picked = {
    ...?FieldValueCodec.decodeMultiSelect(widget.current?.value),
  };

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  FieldDef get _field => widget.field;
  FieldConfig get _config => widget.config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.current;
    final shown = FieldValueCodec.display(
      type: _field.type,
      stored: current?.value,
      config: _config,
    );

    final header = Row(
      children: [
        Text(
          _field.name,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (widget.entered) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_circle, color: theme.colorScheme.primary),
        ],
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            textAlign: TextAlign.end,
            shown == null
                ? 'Nothing recorded'
                : 'Last: $shown · ${isoDate(current!.observedAt)}',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );

    final body = _body(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
      children: [
        header,
        const SizedBox(height: 10),
        if (widget.fill) Expanded(child: body) else body,
      ],
    );
  }

  Widget _body(BuildContext context) {
    switch (_field.type) {
      case FieldType.categorical:
        return _choices([
          for (final o in _config.options) (input: o, stored: o, label: o),
          if (_config.allowOther)
            (input: _other, stored: null, label: 'Other…'),
        ]);

      case FieldType.boolean:
        return _choices([
          (input: true, stored: '1', label: _config.trueLabel ?? 'Yes'),
          (input: false, stored: '0', label: _config.falseLabel ?? 'No'),
        ]);

      case FieldType.rating:
        return _choices([
          for (
            var v = _config.effectiveScaleMin;
            v <= _config.effectiveScaleMax;
            v++
          )
            (input: v, stored: '$v', label: '$v'),
        ]);

      case FieldType.integer when _smallRange != null:
        final (lo, hi) = _smallRange!;
        return _choices([
          for (var v = lo; v <= hi; v++) (input: v, stored: '$v', label: '$v'),
        ]);

      case FieldType.integer:
      case FieldType.decimal:
        return _Keypad(
          decimal: _field.type == FieldType.decimal,
          fill: widget.fill,
          onEnter: widget.onValue,
        );

      case FieldType.date:
      case FieldType.datetime:
        final withTime = _field.type == FieldType.datetime;
        return _choices([
          (
            input: withTime ? _stamp(DateTime.now()) : _day(DateTime.now()),
            stored: null,
            label: withTime ? 'Now' : 'Today',
          ),
          (input: _pickDate, stored: null, label: 'Another date…'),
        ]);

      case FieldType.text:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
          children: [
            TextField(
              controller: _typed,
              style: const TextStyle(fontSize: 22),
              decoration: InputDecoration(
                hintText: 'Type, then Enter',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  iconSize: 32,
                  icon: const Icon(Icons.keyboard_return),
                  onPressed: _submitTyped,
                ),
              ),
              onSubmitted: (_) => _submitTyped(),
            ),
            if (widget.recent.isNotEmpty) ...[
              const SizedBox(height: 10),
              _sized(
                _choices([
                  for (final r in widget.recent.take(8))
                    (input: r, stored: r, label: r),
                ]),
              ),
            ],
          ],
        );

      case FieldType.multiSelect:
        return _choices([
          for (final o in {..._config.options, ..._picked})
            (input: _toggle(o), stored: null, label: o),
          (input: _submitPicked, stored: null, label: 'Done'),
        ], picked: _picked);
    }
  }

  Widget _sized(Widget child) => widget.fill ? Expanded(child: child) : child;

  /// For an integer field bounded to a dozen values or fewer, buttons beat a
  /// keypad: a vine count of 0-6 is one tap rather than two.
  (int, int)? get _smallRange {
    final lo = _config.min, hi = _config.max;
    if (lo == null || hi == null) return null;
    final (a, b) = (lo.ceil(), hi.floor());
    return b >= a && b - a <= 11 ? (a, b) : null;
  }

  /// Colours by stored value, built exactly as the map's colour-by builds
  /// them -- so a button is the colour of the dot it produces.
  Map<String, Color> _coloursFor(Iterable<String> stored) =>
      PlantColouring.build(
        field: _field,
        config: _config,
        values: {for (final s in stored) s: s},
      ).colors;

  Widget _choices(
    List<({Object? input, String? stored, String label})> choices, {
    Set<String>? picked,
  }) {
    final colours = _coloursFor([
      for (final c in choices)
        if (c.stored != null) c.stored!,
    ]);
    final buttons = [
      for (final c in choices)
        _BigButton(
          label: c.label,
          colour: c.stored == null ? null : colours[c.stored],
          // The plant's current value is outlined, so "same as last time"
          // is visible without reading.
          marked: picked != null
              ? picked.contains(c.label)
              : c.stored != null && c.stored == widget.current?.value,
          onTap: () => switch (c.input) {
            // Async actions (a picker) match here too: their result is
            // delivered through onValue when they finish.
            final void Function() action => action(),
            final input => widget.onValue(input),
          },
        ),
    ];
    return _BigGrid(fill: widget.fill, children: buttons);
  }

  VoidCallback _toggle(String option) =>
      () => setState(
        () => _picked.contains(option)
            ? _picked.remove(option)
            : _picked.add(option),
      );

  void _submitPicked() =>
      widget.onValue(_picked.isEmpty ? null : _picked.toList(growable: false));

  void _submitTyped() {
    final text = _typed.text.trim();
    if (text.isEmpty) return;
    widget.onValue(text);
  }

  Future<void> _other() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(_field.name),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(fontSize: 22),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Enter'),
            ),
          ],
        );
      },
    );
    if (value != null && value.trim().isNotEmpty) widget.onValue(value.trim());
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final first = _config.minDate ?? DateTime(1900);
    final last = _config.maxDate ?? DateTime(now.year + 50);
    var initial = now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (date == null) return;
    widget.onValue(
      _field.type == FieldType.datetime
          ? _stamp(
              DateTime(date.year, date.month, date.day, now.hour, now.minute),
            )
          : _day(date),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static String _stamp(DateTime d) =>
      '${_day(d)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// Lays buttons out in as few, as even rows as the width allows.
///
/// Filling: the rows share the height, so seven Health buttons on a tablet
/// are each a hand's width. Not filling: fixed-height rows, so several fields
/// can stack.
class _BigGrid extends StatelessWidget {
  const _BigGrid({required this.children, required this.fill, this.columns});

  final List<Widget> children;
  final bool fill;

  /// Fixes the column count, for a keypad that must read as one.
  final int? columns;

  static const _minWidth = 150.0;
  static const _bandHeight = 84.0;
  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = children.length;
        if (n == 0) return const SizedBox.shrink();
        final maxColumns = math.max(
          1,
          ((constraints.maxWidth + _gap) / (_minWidth + _gap)).floor(),
        );
        final rows = (n / (this.columns ?? maxColumns)).ceil();
        final columns = this.columns ?? (n / rows).ceil();

        Widget row(int r) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) const SizedBox(width: _gap),
              Expanded(
                child: r * columns + c < n
                    ? children[r * columns + c]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        );

        return Column(
          mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var r = 0; r < rows; r++) ...[
              if (r > 0) const SizedBox(height: _gap),
              if (fill)
                Expanded(child: row(r))
              else
                SizedBox(height: _bandHeight, child: row(r)),
            ],
          ],
        );
      },
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.onTap,
    this.colour,
    this.marked = false,
  });

  final String label;
  final VoidCallback onTap;
  final Color? colour;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = colour ?? scheme.surfaceContainerHighest;
    final foreground =
        ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: marked
            ? BorderSide(color: scheme.onSurface, width: 5)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground,
                  fontSize: label.length <= 3 ? 44 : 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A calculator-sized number pad. The system keyboard covers half the screen
/// and its keys are a fingertip wide.
class _Keypad extends StatefulWidget {
  const _Keypad({
    required this.decimal,
    required this.fill,
    required this.onEnter,
  });

  final bool decimal;
  final bool fill;
  final ValueChanged<Object?> onEnter;

  @override
  State<_Keypad> createState() => _KeypadState();
}

class _KeypadState extends State<_Keypad> {
  String _text = '';

  void _press(String key) => setState(() {
    switch (key) {
      case '⌫':
        if (_text.isNotEmpty) _text = _text.substring(0, _text.length - 1);
      case '-':
        _text = _text.startsWith('-') ? _text.substring(1) : '-$_text';
      case '.':
        if (!_text.contains('.')) _text = _text.isEmpty ? '0.' : '$_text.';
      default:
        _text += key;
    }
  });

  @override
  Widget build(BuildContext context) {
    final keys = [
      '7', '8', '9', //
      '4', '5', '6',
      '1', '2', '3',
      widget.decimal ? '.' : '-', '0', '⌫',
    ];
    final display = Container(
      height: 64,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(_text, style: const TextStyle(fontSize: 36)),
    );
    final pad = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: _BigGrid(
            fill: widget.fill,
            columns: 3,
            children: [
              for (final k in keys)
                _BigButton(label: k, onTap: () => _press(k)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _BigButton(
            label: 'Enter',
            colour: Theme.of(context).colorScheme.primary,
            onTap: () {
              if (_text.isEmpty || _text == '-') return;
              widget.onEnter(_text);
            },
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
      children: [
        display,
        const SizedBox(height: 10),
        if (widget.fill)
          Expanded(child: pad)
        else
          SizedBox(height: 4 * 84 + 3 * 10, child: pad),
      ],
    );
  }
}
