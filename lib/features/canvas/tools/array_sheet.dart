import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/label_service.dart';
import '../../../core/db/database.dart';
import '../../../core/geometry/array_generation.dart';
import '../../../core/geometry/polyline.dart';
import '../../../core/geometry/row_generation.dart';
import '../../../core/geometry/shapes.dart';
import '../../../core/providers.dart';
import '../canvas_controller.dart';

/// What the user decided about a parallel array.
class ArrayPlan {
  const ArrayPlan({required this.lines, required this.offsets});

  /// The lines to create, the first of which is the seed as drawn.
  final List<Polyline> lines;

  /// Arc-length positions for plants along **each** line. Empty leaves them
  /// unplanted.
  final List<double> offsets;
}

/// Copies one drawn line into a parallel run, and plants each copy the same way.
///
/// The tool exists for block 2's 24 near-identical rows and block 3's 26 -- one
/// gesture instead of fifty. Two constraints from the amended plan shape it:
///
///  * **The generated lines are independent from the moment they exist.** No
///    parent link, no re-flow. Each is written as an ordinary object, so dragging
///    one line's endpoint later leaves the other 23 exactly where they are.
///  * **It creates geometry and plants, never attribute values.** Container
///    values derive from geometry as everywhere else; anything else is set
///    afterwards through multi-select and bulk edit. The tool lays out, it does
///    not decide what things are.
class ArraySheet extends ConsumerStatefulWidget {
  const ArraySheet({
    super.key,
    required this.field,
    required this.seed,
    this.calibration,
  });

  final FieldDef field;
  final Polyline seed;
  final ScaleCalibration? calibration;

  @override
  ConsumerState<ArraySheet> createState() => _ArraySheetState();
}

class _ArraySheetState extends ConsumerState<ArraySheet> {
  final _rows = TextEditingController(text: '10');
  final _gap = TextEditingController(text: '8');
  final _count = TextEditingController(text: '30');
  final _spacing = TextEditingController(text: '6');

  bool _flip = false;
  bool _plantThem = true;
  bool _byCount = true;
  bool _checking = false;

  /// What the run would collide with, if anything. Named, because "this
  /// overlaps something" is not actionable.
  String? _overlap;

  /// The labels the new lines would take, worked out once so the sheet can show
  /// them and the caller can reuse them.
  List<String> _labels = const [];

  ScaleCalibration get _calibration =>
      widget.calibration ?? ScaleCalibration.uncalibrated;

  @override
  void initState() {
    super.initState();
    _suggestLabels();
  }

  @override
  void dispose() {
    _rows.dispose();
    _gap.dispose();
    _count.dispose();
    _spacing.dispose();
    super.dispose();
  }

  /// Sequential free labels, starting from the lowest unused integer.
  ///
  /// Names are not attribute values -- an object has to be called something --
  /// but they are still the array's only naming decision, so it takes the most
  /// boring one available and shows the result.
  Future<void> _suggestLabels() async {
    final next = await ref
        .read(labelServiceProvider)
        .nextObjectLabel(widget.field.id);
    if (!mounted) return;
    setState(() => _labels = _labelsFrom(next));
  }

  List<String> _labelsFrom(int start) => [
    for (var i = 0; i < _rowCount; i++) '${start + i}',
  ];

  int get _rowCount => (int.tryParse(_rows.text) ?? 0).clamp(0, 500);

  List<Polyline> get _lines => ArrayGeneration.parallel(
    seed: widget.seed,
    spacing: _calibration.toPixels(double.tryParse(_gap.text) ?? 0),
    count: _rowCount,
    flip: _flip,
  );

  List<double> get _offsets {
    if (!_plantThem) return const [];
    if (_byCount) {
      return RowGeneration.byCount(widget.seed, int.tryParse(_count.text) ?? 0);
    }
    return RowGeneration.bySpacing(
      widget.seed,
      _calibration.toPixels(double.tryParse(_spacing.text) ?? 0),
    );
  }

  Future<void> _create() async {
    final lines = _lines;
    if (lines.isEmpty) return;
    setState(() => _checking = true);

    // Every line checked against everything already drawn of this field, and
    // against the others in the run. Checked here rather than per line as they
    // are written, so a run that would half-succeed is refused whole.
    final layout = ref.read(layoutDaoProvider);
    final drawn = <ShapeRef>[];
    for (var i = 0; i < lines.length; i++) {
      final shape = PolylineShape(lines[i]);
      final hit = await layout.checkOverlap(
        fieldDefId: widget.field.id,
        shape: shape,
      );
      final internal = findOverlap(shape, drawn);
      if (!mounted) return;

      if (hit != null || internal != null) {
        setState(() {
          _checking = false;
          _overlap = hit != null
              ? 'Line ${i + 1} of the run would overlap '
                    '${widget.field.name} ${hit.label}. Two of the same cannot '
                    'share ground.'
              : 'Line ${i + 1} of the run would overlap line '
                    '${internal!.label} of the same run. Widen the gap.';
        });
        return;
      }
      drawn.add((id: 'run-$i', label: '${i + 1}', shape: shape));
    }

    if (!mounted) return;
    Navigator.pop(context, ArrayPlan(lines: lines, offsets: _offsets));
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final offsets = _offsets;
    final unit = _calibration.unit;
    final labels = _labelsFrom(
      _labels.isEmpty ? 1 : int.tryParse(_labels.first) ?? 1,
    );

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
              'A run of ${widget.field.name.toLowerCase()}s',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'The line you drew is the first one. Each copy keeps its shape, '
              'and every one is editable on its own afterwards.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rows,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'How many ${widget.field.name.toLowerCase()}s',
                    ),
                    onChanged: (_) => setState(() => _overlap = null),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _gap,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: 'Gap ($unit)'),
                    onChanged: (_) => setState(() => _overlap = null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('This side')),
                ButtonSegment(value: true, label: Text('The other side')),
              ],
              selected: {_flip},
              onSelectionChanged: (s) => setState(() {
                _flip = s.first;
                _overlap = null;
              }),
            ),
            const SizedBox(height: 8),
            Text(
              'Which way the copies go. There is no way to guess it from the '
              'direction you happened to draw in.',
              style: Theme.of(context).textTheme.bodySmall,
            ),

            const SizedBox(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _plantThem,
              onChanged: (v) => setState(() => _plantThem = v),
              title: const Text('Plant them as well'),
              subtitle: const Text('The same spacing on every line'),
            ),
            if (_plantThem) ...[
              const SizedBox(height: 8),
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
                    labelText: 'Plants per line',
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
                    labelText: 'Plant spacing ($unit)',
                    helperText: _calibration.isCalibrated
                        ? "Measured against this project's scale"
                        : 'No scale set, so this is in pixels',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
            ],

            const SizedBox(height: 16),
            Text(
              lines.isEmpty
                  ? 'Nothing to create -- check the count.'
                  : '${lines.length} '
                        '${lines.length == 1 ? widget.field.name.toLowerCase() : '${widget.field.name.toLowerCase()}s'}'
                        '${labels.isEmpty ? '' : ', named ${labels.first} to ${labels.last}'}'
                        '${offsets.isEmpty ? ', unplanted' : ', ${offsets.length * lines.length} plants in total'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (offsets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'No other values are set. Select them afterwards and bulk-edit '
                  'to say what they are.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),

            if (_overlap != null) ...[
              const SizedBox(height: 16),
              Text(
                _overlap!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 4),
              const Text(
                'Nothing was created. The line you drew is still here.',
                style: TextStyle(fontSize: 12),
              ),
            ],

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: lines.isEmpty || _checking ? null : _create,
                  child: const Text('Create them'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the user decided about a point array.
class PointArrayPlan {
  const PointArrayPlan({required this.offsets, required this.field});

  /// Arc-length positions along the guide.
  final List<double> offsets;

  /// The point-typed field being placed -- possibly Plant.
  final FieldDef? field;

  /// Null field means Plant, which is a point but not a field.
  bool get isPlant => field == null;
}

/// Writes a point array's instances as one undoable gesture.
///
/// A free function rather than a method, because two callers need it and they are
/// not in the same widget tree: the throwaway-guide tool on the canvas, and the
/// "space points along it" action on a selected object. They differ only in
/// whether there is a real line for plants to be carried by.
Future<void> writePointArray(
  WidgetRef ref, {
  required String projectId,
  required Polyline guide,
  required PointArrayPlan plan,
  required String? carrierId,
}) async {
  final layout = ref.read(layoutDaoProvider);
  final labels = ref.read(labelServiceProvider);
  final field = plan.field;

  await ref
      .read(operationRecorderProvider)
      .run(
        projectId: projectId,
        kind: plan.isPlant ? 'array_plants' : 'array_points',
        description: plan.isPlant
            ? 'Place ${plan.offsets.length} plants'
            : 'Place ${plan.offsets.length} ${field!.name} points',
        body: () async {
          if (plan.isPlant) {
            // Carried when there is a real line to carry them, free-standing
            // when the guide was a throwaway -- there would be nothing left for
            // a carrier to point at.
            if (carrierId != null) {
              await layout.placePlantsAlongCarrier(
                carrierId: carrierId,
                offsets: plan.offsets,
              );
            } else {
              for (final offset in plan.offsets) {
                await layout.createPlant(
                  projectId: projectId,
                  position: guide.pointAt(offset),
                );
              }
            }
            return;
          }

          // Labels resolved one at a time inside the operation, so each is free
          // against the ones just written rather than against a stale snapshot.
          for (final offset in plan.offsets) {
            final label = await labels.nextObjectLabel(field!.id);
            await layout.createObject(
              projectId: projectId,
              fieldDefId: field.id,
              label: '$label',
              geometry: PointShape(guide.pointAt(offset)),
            );
          }
        },
      );
}

/// Places evenly spaced instances along a line.
///
/// The guide is **either an existing object or a throwaway line the user drew for
/// the purpose**, and in the second case it is never persisted -- it is a
/// construction aid, gone the moment the array runs. Sometimes the line you want
/// to measure against is not a thing the vineyard contains.
///
/// One tool covers both readings of "points" by asking which point-typed field to
/// place: a run of posts, or plants placed evenly with no line to carry them.
/// **Plant is a privileged point** and appears in the same list.
class PointArraySheet extends ConsumerStatefulWidget {
  const PointArraySheet({
    super.key,
    required this.guide,
    required this.pointFields,
    required this.guideIsThrowaway,
    this.calibration,
  });

  final Polyline guide;

  /// Point-typed object fields. Plant is offered alongside them and is not one.
  final List<FieldDef> pointFields;

  /// True when the guide was drawn for this and will be discarded.
  final bool guideIsThrowaway;

  final ScaleCalibration? calibration;

  @override
  ConsumerState<PointArraySheet> createState() => _PointArraySheetState();
}

class _PointArraySheetState extends ConsumerState<PointArraySheet> {
  final _count = TextEditingController(text: '10');
  final _spacing = TextEditingController(text: '20');

  bool _byCount = true;

  /// Null means Plant.
  FieldDef? _field;

  ScaleCalibration get _calibration =>
      widget.calibration ?? ScaleCalibration.uncalibrated;

  @override
  void dispose() {
    _count.dispose();
    _spacing.dispose();
    super.dispose();
  }

  List<double> get _offsets {
    if (_byCount) {
      return RowGeneration.byCount(
        widget.guide,
        int.tryParse(_count.text) ?? 0,
      );
    }
    return RowGeneration.bySpacing(
      widget.guide,
      _calibration.toPixels(double.tryParse(_spacing.text) ?? 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offsets = _offsets;
    final unit = _calibration.unit;

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
              'Space them along the line',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              widget.guideIsThrowaway
                  ? 'The line is a guide only. It is not saved and disappears '
                        'once these are placed. Length '
                        '${_calibration.format(widget.guide.length)}.'
                  : 'Along the object you picked. Length '
                        '${_calibration.format(widget.guide.length)}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),

            const SizedBox(height: 16),
            Text(
              'What to place',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            RadioGroup<String?>(
              groupValue: _field?.id,
              onChanged: (id) => setState(
                () => _field = id == null
                    ? null
                    : widget.pointFields.firstWhere((f) => f.id == id),
              ),
              child: Column(
                children: [
                  // Plant first and unlabelled as a field, because it is not one:
                  // it is the thing the whole app is about, and it happens to be
                  // a point.
                  const RadioListTile<String?>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: null,
                    title: Text('Plants'),
                  ),
                  for (final field in widget.pointFields)
                    RadioListTile<String?>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: field.id,
                      title: Text(field.name),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 12),
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
                  labelText: 'How many',
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
                  ? 'Nothing to place -- check the count.'
                  : _field == null
                  ? '${offsets.length} plants'
                        '${widget.guideIsThrowaway ? ', free-standing -- there is no line to carry them' : ', carried by the line you picked'}'
                  : '${offsets.length} ${_field!.name} points',
              style: Theme.of(context).textTheme.bodyMedium,
            ),

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: offsets.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          PointArrayPlan(offsets: offsets, field: _field),
                        ),
                  child: const Text('Place them'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Names the second half of a split, and says what it will cost.
class SplitSheet extends ConsumerStatefulWidget {
  const SplitSheet({
    super.key,
    required this.objectId,
    required this.label,
    required this.fieldName,
    required this.atOffset,
  });

  final String objectId;
  final String label;
  final String fieldName;
  final double atOffset;

  @override
  ConsumerState<SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends ConsumerState<SplitSheet> {
  final _name = TextEditingController();

  String? _problem;
  bool _loading = true;
  int? _affected;
  int _movedPlants = 0;

  @override
  void initState() {
    super.initState();
    _name.addListener(_check);
    _suggest();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _suggest() async {
    final layout = ref.read(layoutDaoProvider);
    final object = await layout.objectById(widget.objectId);
    if (object == null || !mounted) return;

    final next = await ref
        .read(labelServiceProvider)
        .nextObjectLabel(object.fieldDefId);
    final moved = await layout.plantsBeyond(widget.objectId, widget.atOffset);
    if (!mounted) return;

    setState(() {
      _movedPlants = moved.length;
      _loading = false;
    });
    _name.text = '$next';
  }

  Future<void> _check() async {
    final typed = _name.text;
    final projectId = ref.read(activeProjectIdProvider);
    final layout = ref.read(layoutDaoProvider);
    final object = await layout.objectById(widget.objectId);
    if (projectId == null || object == null) return;

    final field = await ref.read(fieldDefsDaoProvider).byId(object.fieldDefId);
    if (field == null) return;

    final labels = ref.read(labelServiceProvider);
    final template = await labels.templateFor(projectId);
    final problem = LabelService.problemWithObjectLabel(
      label: typed,
      delimiter: template.delimiter,
      blankPlaceholder: field.blankPlaceholder,
    );

    if (problem == null &&
        !await labels.isObjectLabelFree(
          fieldDefId: object.fieldDefId,
          label: typed,
        )) {
      if (mounted && _name.text == typed) {
        setState(() {
          _problem = '${widget.fieldName} ${typed.trim()} already exists.';
          _affected = null;
        });
      }
      return;
    }

    final affected = problem != null
        ? null
        : (await layout.previewSplit(
            objectId: widget.objectId,
            atOffset: widget.atOffset,
            newLabel: typed,
          )).changed;

    if (!mounted || _name.text != typed) return;
    setState(() {
      _problem = problem;
      _affected = affected;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

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
            'Split ${widget.fieldName} ${widget.label}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.fieldName} ${widget.label} keeps the near half and its '
            'name. $_movedPlants '
            '${_movedPlants == 1 ? 'plant moves' : 'plants move'} to the far '
            'half, keeping their numbers -- so they will not start at 1. The '
            'numbering tool fixes that if you want it fixed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Name for the far half',
              errorText: _problem,
            ),
          ),
          const SizedBox(height: 12),
          Text(switch (_affected) {
            null => ' ',
            0 => 'No plant IDs change.',
            final n =>
              'Changes the ID of $n '
                  '${n == 1 ? 'plant' : 'plants'}.',
          }, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _problem != null
                    ? null
                    : () => Navigator.pop(context, _name.text.trim()),
                child: const Text('Split it'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
