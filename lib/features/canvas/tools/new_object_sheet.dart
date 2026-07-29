import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/label_service.dart';
import '../../../core/db/database.dart';
import '../../../core/geometry/row_generation.dart';
import '../../../core/geometry/shapes.dart';
import '../../../core/providers.dart';
import '../canvas_controller.dart';

/// Everything the user decides about a freshly drawn object.
class NewObject {
  const NewObject({
    required this.label,
    required this.shape,
    required this.offsets,
  });

  final String label;

  /// The shape as it should be stored -- already reversed if the user chose to
  /// number from the other end, so plant 1 sits at offset zero.
  final Shape shape;

  /// Arc-length positions for plants along a line. Empty for anything else, and
  /// for a line left unplanted.
  final List<double> offsets;
}

/// Names a new object and, for a line, plants it.
///
/// One sheet rather than several prompts, because for the person drawing it
/// these are one decision. It also means the object and its plants are written
/// by a single operation, so undo takes the whole thing back instead of leaving
/// an empty row behind.
class NewObjectSheet extends ConsumerStatefulWidget {
  const NewObjectSheet({
    super.key,
    required this.field,
    required this.shape,
    this.calibration,
  });

  final FieldDef field;
  final Shape shape;
  final ScaleCalibration? calibration;

  @override
  ConsumerState<NewObjectSheet> createState() => _NewObjectSheetState();
}

class _NewObjectSheetState extends ConsumerState<NewObjectSheet> {
  final _label = TextEditingController();
  final _count = TextEditingController(text: '30');
  final _spacing = TextEditingController(text: '6');

  bool _byCount = true;

  /// False puts plant 1 at the end the user finished drawing on.
  bool _forward = true;

  String? _labelProblem;

  /// What this object would overlap, if anything. Checked on save rather than
  /// mid-stroke: refusing a stroke as it is drawn would throw away twelve taps.
  String? _overlap;

  bool _checking = true;

  ScaleCalibration get _calibration =>
      widget.calibration ?? ScaleCalibration.uncalibrated;

  bool get _isLine => widget.shape is PolylineShape;

  @override
  void initState() {
    super.initState();
    _label.addListener(_checkLabel);
    _suggestLabel();
  }

  @override
  void dispose() {
    _label.dispose();
    _count.dispose();
    _spacing.dispose();
    super.dispose();
  }

  Future<void> _suggestLabel() async {
    final labels = ref.read(labelServiceProvider);
    final next = await labels.nextObjectLabel(widget.field.id);
    if (!mounted) return;
    _label.text = '$next';
    setState(() => _checking = false);
    await _checkLabel();
  }

  /// Validates as the user types rather than on submit.
  ///
  /// Worth getting right at the moment of drawing: correcting a row's name
  /// afterwards renames every plant on it.
  Future<void> _checkLabel() async {
    final typed = _label.text;
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final labels = ref.read(labelServiceProvider);
    final template = await labels.templateFor(projectId);

    final problem = LabelService.problemWithObjectLabel(
      label: typed,
      delimiter: template.delimiter,
      blankPlaceholder: widget.field.blankPlaceholder,
    );
    if (problem != null) {
      if (mounted) setState(() => _labelProblem = problem);
      return;
    }

    final free = await labels.isObjectLabelFree(
      fieldDefId: widget.field.id,
      label: typed,
    );

    // The field may have moved on while the query ran.
    if (!mounted || _label.text != typed) return;
    setState(
      () => _labelProblem = free
          ? null
          : '${widget.field.name} $typed already exists.',
    );
  }

  Shape get _shape {
    final shape = widget.shape;
    if (shape is PolylineShape && !_forward) {
      return PolylineShape(shape.path.reversed);
    }
    return shape;
  }

  List<double> get _offsets {
    final shape = _shape;
    if (shape is! PolylineShape) return const [];
    if (_byCount) {
      return RowGeneration.byCount(shape.path, int.tryParse(_count.text) ?? 0);
    }
    return RowGeneration.bySpacing(
      shape.path,
      _calibration.toPixels(double.tryParse(_spacing.text) ?? 0),
    );
  }

  Future<void> _create() async {
    setState(() => _checking = true);

    // The overlap rule: two objects of the *same* field may not share ground. A
    // row crossing a block is the normal case and stays legal.
    final hit = await ref
        .read(layoutDaoProvider)
        .checkOverlap(fieldDefId: widget.field.id, shape: _shape);

    if (!mounted) return;
    if (hit != null) {
      setState(() {
        _checking = false;
        _overlap =
            'This overlaps ${widget.field.name} ${hit.label}. '
            'Two of the same cannot share the same ground.';
      });
      return;
    }

    Navigator.pop(
      context,
      NewObject(label: _label.text.trim(), shape: _shape, offsets: _offsets),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offsets = _offsets;
    final unit = _calibration.unit;
    final length = switch (widget.shape) {
      final PolylineShape line => line.path.length,
      _ => null,
    };

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
              'New ${widget.field.name.toLowerCase()}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (length != null) ...[
              const SizedBox(height: 4),
              Text(
                'Length ${_calibration.format(length)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                labelText: '${widget.field.name} name',
                errorText: _labelProblem,
              ),
            ),

            if (_isLine) ...[
              const SizedBox(height: 20),
              Text(
                'Which end is plant 1',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Where I started')),
                  ButtonSegment(value: false, label: Text('Where I finished')),
                ],
                selected: {_forward},
                onSelectionChanged: (s) => setState(() => _forward = s.first),
              ),
              const SizedBox(height: 20),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('By count')),
                  ButtonSegment(value: false, label: Text('By spacing')),
                ],
                selected: {_byCount},
                onSelectionChanged: (s) => setState(() => _byCount = s.first),
              ),
              const SizedBox(height: 16),
              if (_byCount)
                TextField(
                  controller: _count,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Number of plants',
                    helperText: 'Spread evenly, first and last at the ends',
                  ),
                  onChanged: (_) => setState(() {}),
                )
              else
                TextField(
                  controller: _spacing,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Spacing ($unit)',
                    helperText: _calibration.isCalibrated
                        ? "Measured against this project's scale"
                        : 'No scale set, so this is in pixels',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 16),
              Text(
                offsets.isEmpty
                    ? 'No plants -- it will be drawn empty'
                    : 'Will place ${offsets.length} plants, numbered from the '
                          'end you ${_forward ? 'started' : 'finished'} on',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],

            if (_overlap != null) ...[
              const SizedBox(height: 16),
              Text(
                _overlap!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 4),
              const Text(
                'The shape you drew is still here -- go back and move a point.',
                style: TextStyle(fontSize: 12),
              ),
            ],

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_overlap == null ? 'Cancel' : 'Edit shape'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  // An unplanted line is legitimate -- draw it now, plant it
                  // once you have walked it -- so only a bad name blocks this.
                  onPressed: _labelProblem != null || _checking
                      ? null
                      : _create,
                  child: const Text('Create'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
