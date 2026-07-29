import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/label_service.dart';
import '../../../core/geometry/row_generation.dart';
import '../../../core/providers.dart';
import '../canvas_controller.dart';
import '../vineyard_canvas.dart';
import 'identifier_change_prompt.dart';

/// What can be done to a drawn object.
///
/// The home for every action that is about the *thing drawn* rather than about
/// the plants on it: rename it, plant more into it, reshape it, delete it. Its
/// plants are one further tap away, which is how "everything on this row" is
/// expressed.
class ObjectActionsSheet extends ConsumerWidget {
  const ObjectActionsSheet({
    super.key,
    required this.objectId,
    required this.label,
    required this.fieldName,
    required this.isLine,
  });

  final String objectId;
  final String label;
  final String fieldName;

  /// Only a line can carry plants, so only a line can be planted into.
  final bool isLine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '$fieldName $label',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.select_all),
            title: const Text('Select its plants'),
            subtitle: const Text('Then bulk-edit or number them'),
            onTap: () => _selectPlants(context, ref),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename'),
            subtitle: const Text('Changes the ID of every plant inside it'),
            onTap: () async {
              Navigator.pop(context);
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) => _RenameSheet(
                  objectId: objectId,
                  label: label,
                  fieldName: fieldName,
                ),
              );
            },
          ),
          if (isLine)
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('Plant more along it'),
              subtitle: const Text(
                'For a line interrupted by an obstacle: plant one side, then '
                'the other. The numbers stay contiguous.',
              ),
              onTap: () async {
                Navigator.pop(context);
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) =>
                      _PlantMoreSheet(objectId: objectId, label: label),
                );
              },
            ),
          ListTile(
            leading: const Icon(Icons.timeline),
            title: const Text('Reshape'),
            subtitle: const Text('Drag a corner. Two fingers still pan.'),
            onTap: () {
              ref.read(activeToolProvider.notifier).state = CanvasTool.reshape;
              Navigator.pop(context);
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            subtitle: const Text(
              'Its plants stay where they are and simply stop belonging to it',
            ),
            onTap: () => _delete(context, ref),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Future<void> _selectPlants(BuildContext context, WidgetRef ref) async {
    final plants = await ref
        .read(plantsDaoProvider)
        .resolveSelection(objectIds: [objectId]);
    if (!context.mounted) return;

    Navigator.pop(context);
    if (plants.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$fieldName $label has no plants on it yet.')),
      );
      return;
    }
    ref.read(selectionProvider.notifier).state = plants;
    ref.read(selectedObjectProvider.notifier).state = null;
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final layout = ref.read(layoutDaoProvider);

    // Deleting a container is a boundary edit in the limit: every plant inside
    // it loses that part of its identifier at once. Same all-or-nothing rule.
    final change = await layout.previewGeometryChange(objectId: objectId);
    if (!context.mounted) return;

    final ok = await confirmIdentifierChange(
      context,
      change: change,
      action: 'Delete $fieldName $label',
      proceedLabel: 'Delete it',
      refusalAdvice:
          'Give the plants inside it something else that tells them apart '
          'first, then delete it.',
    );
    if (!ok || !context.mounted) return;

    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'delete_object',
          description: 'Delete $fieldName $label',
          body: () => layout.deleteObject(objectId),
        );

    if (context.mounted) {
      Navigator.pop(context);
      ref.read(selectedObjectProvider.notifier).state = null;
    }
  }
}

/// Renames an object, naming what that costs first.
class _RenameSheet extends ConsumerStatefulWidget {
  const _RenameSheet({
    required this.objectId,
    required this.label,
    required this.fieldName,
  });

  final String objectId;
  final String label;
  final String fieldName;

  @override
  ConsumerState<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends ConsumerState<_RenameSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.label,
  );

  String? _problem;
  bool _working = false;

  /// How many plants the name currently typed would rename, or null while
  /// unknown. Shown live: the whole point is that the cost is visible before
  /// the button is pressed.
  int? _affected;

  @override
  void initState() {
    super.initState();
    _name.addListener(_check);
    _check();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final typed = _name.text;
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final labels = ref.read(labelServiceProvider);
    final object = await ref
        .read(layoutDaoProvider)
        .objectById(widget.objectId);
    final field = object == null
        ? null
        : await ref.read(fieldDefsDaoProvider).byId(object.fieldDefId);
    if (field == null) return;

    final template = await labels.templateFor(projectId);
    final problem = LabelService.problemWithObjectLabel(
      label: typed,
      delimiter: template.delimiter,
      blankPlaceholder: field.blankPlaceholder,
    );

    if (problem == null) {
      final free = await labels.isObjectLabelFree(
        fieldDefId: object!.fieldDefId,
        label: typed,
        ignoringObjectId: widget.objectId,
      );
      if (!free) {
        if (mounted && _name.text == typed) {
          setState(() {
            _problem = '${widget.fieldName} ${typed.trim()} already exists.';
            _affected = null;
          });
        }
        return;
      }
    }

    final affected = problem != null
        ? null
        : (await labels.previewObjectRename(
            objectId: widget.objectId,
            label: typed,
          )).changed;

    // The field may have moved on while the queries ran.
    if (!mounted || _name.text != typed) return;
    setState(() {
      _problem = problem;
      _affected = affected;
    });
  }

  Future<void> _save() async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;
    setState(() => _working = true);

    final labels = ref.read(labelServiceProvider);
    final change = await labels.previewObjectRename(
      objectId: widget.objectId,
      label: _name.text,
    );
    if (!mounted) return;

    final ok = await confirmIdentifierChange(
      context,
      change: change,
      action: 'Rename ${widget.fieldName} ${widget.label}',
      refusalAdvice:
          'Pick a different name, or add a part to the ID format that tells '
          'these plants apart.',
    );
    if (!ok) {
      if (mounted) setState(() => _working = false);
      return;
    }
    if (!mounted) return;

    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'rename_object',
          description:
              'Rename ${widget.fieldName} ${widget.label} to '
              '${_name.text.trim()}',
          body: () => ref
              .read(layoutDaoProvider)
              .renameObject(widget.objectId, _name.text),
        );

    if (mounted) Navigator.pop(context);
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
            'Rename ${widget.fieldName} ${widget.label}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '${widget.fieldName} name',
              errorText: _problem,
            ),
          ),
          const SizedBox(height: 12),
          Text(switch (_affected) {
            null => ' ',
            0 =>
              'No plant IDs change -- this name is not part of the ID format.',
            final n =>
              'Renames $n ${n == 1 ? 'plant' : 'plants'}. Their old IDs stay '
                  'in each plant\'s history.',
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
                onPressed: _problem != null || _working ? null : _save,
                child: const Text('Rename'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Plants a further stretch of an existing line.
///
/// The rock case, from the amended plan: draw the line straight through the
/// obstacle, plant the near side, plant the far side. One row, contiguous
/// numbers, a visible gap in space.
///
/// `placePlantsAlongCarrier` already fills from the lowest free number upward
/// and leaves existing plants alone, so this sheet only has to decide *where*.
class _PlantMoreSheet extends ConsumerStatefulWidget {
  const _PlantMoreSheet({required this.objectId, required this.label});

  final String objectId;
  final String label;

  @override
  ConsumerState<_PlantMoreSheet> createState() => _PlantMoreSheetState();
}

class _PlantMoreSheetState extends ConsumerState<_PlantMoreSheet> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _count = TextEditingController(text: '10');
  final _spacing = TextEditingController(text: '6');

  bool _byCount = true;
  bool _loading = true;
  bool _working = false;

  double _length = 0;
  List<double> _occupied = const [];

  ScaleCalibration get _calibration =>
      ref.read(calibrationProvider).valueOrNull ??
      ScaleCalibration.uncalibrated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _count.dispose();
    _spacing.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final layout = ref.read(layoutDaoProvider);
    final path = await layout.carrierPathOf(widget.objectId);
    final occupied = await layout.plantedOffsetsOn(widget.objectId);
    if (!mounted || path == null) return;

    final calibration = _calibration;
    // Default to the stretch beyond the last plant, which is the common case:
    // you planted as far as the rock and are now past it.
    final start = occupied.isEmpty ? 0.0 : occupied.last;

    setState(() {
      _length = path.length;
      _occupied = occupied;
      _loading = false;
      _from.text = calibration.toReal(start).toStringAsFixed(1);
      _to.text = calibration.toReal(path.length).toStringAsFixed(1);
    });
  }

  /// Offsets in **layout pixels**, converted from whatever the user typed.
  List<double> get _offsets {
    final calibration = _calibration;
    final from = calibration.toPixels(double.tryParse(_from.text) ?? 0);
    final to = calibration.toPixels(double.tryParse(_to.text) ?? 0);

    if (_byCount) {
      return RowGeneration.byCountBetween(
        from: from,
        to: to,
        count: int.tryParse(_count.text) ?? 0,
      );
    }
    return RowGeneration.bySpacingBetween(
      from: from,
      to: to,
      spacing: calibration.toPixels(double.tryParse(_spacing.text) ?? 0),
    );
  }

  Future<void> _plant() async {
    final projectId = ref.read(activeProjectIdProvider);
    final offsets = _offsets;
    if (projectId == null || offsets.isEmpty) return;

    setState(() => _working = true);
    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'plant_more',
          description: 'Plant ${offsets.length} more along ${widget.label}',
          body: () => ref
              .read(layoutDaoProvider)
              .placePlantsAlongCarrier(
                carrierId: widget.objectId,
                offsets: offsets,
              ),
        );

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final calibration = _calibration;
    final offsets = _offsets;
    final unit = calibration.unit;

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
              'Plant more along ${widget.label}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              _occupied.isEmpty
                  ? 'Nothing planted yet. Length ${calibration.format(_length)}.'
                  : '${_occupied.length} '
                        '${_occupied.length == 1 ? 'plant' : 'plants'} already '
                        'on it, out to ${calibration.format(_occupied.last)} of '
                        '${calibration.format(_length)}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _from,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: 'From ($unit)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _to,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: 'To ($unit)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Measured along the line from the end plant 1 is on.',
              style: Theme.of(context).textTheme.bodySmall,
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
                  helperText: 'Spread evenly across the stretch above',
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
                  helperText: calibration.isCalibrated
                      ? "Measured against this project's scale"
                      : 'No scale set, so this is in pixels',
                ),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: 16),
            Text(
              offsets.isEmpty
                  ? 'Nothing to place -- check the stretch and the count.'
                  : 'Will place ${offsets.length} more '
                        '${offsets.length == 1 ? 'plant' : 'plants'}, numbered '
                        'into the gaps and then on from the end.',
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
                  onPressed: offsets.isEmpty || _working ? null : _plant,
                  child: const Text('Plant them'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
