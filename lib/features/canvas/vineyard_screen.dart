import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry/polyline.dart';
import '../../core/geometry/row_generation.dart';
import '../../core/providers.dart';
import 'canvas_controller.dart';
import '../data_entry/vine_inspector.dart';
import '../schema/field_editor_screen.dart';
import 'frame_stats_overlay.dart';
import 'undo_controls.dart';
import 'viewport.dart';
import 'vineyard_canvas.dart';
import 'vineyard_painter.dart';

/// The map screen: canvas, toolbar, and the row-drawing flow.
class VineyardScreen extends ConsumerStatefulWidget {
  const VineyardScreen({super.key, required this.projectName});

  final String projectName;

  @override
  ConsumerState<VineyardScreen> createState() => _VineyardScreenState();
}

class _VineyardScreenState extends ConsumerState<VineyardScreen> {
  final _canvasKey = GlobalKey<VineyardCanvasState>();
  CanvasViewport _viewport = CanvasViewport.identity;
  bool _fittedOnce = false;
  bool _showStats = false;

  /// Finger-sized tap target, converted to layout units so the tolerance stays
  /// constant on screen at any zoom.
  static const _tapRadiusScreenPx = 24.0;

  String? get _projectId => ref.read(activeProjectIdProvider);

  /// Runs a write as one undoable gesture.
  ///
  /// Every path in this screen that touches the database goes through here.
  /// The unit of undo is what the user did, not what the DAO did -- planting a
  /// row is one press of undo even though it writes a row and forty vines.
  Future<T?> _gesture<T>(
    String kind,
    String description,
    Future<T> Function() body,
  ) async {
    final projectId = _projectId;
    if (projectId == null) return null;

    return ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: kind,
          description: description,
          body: body,
        );
  }

  Future<void> _onTap(ui.Offset layoutPoint) async {
    final tool = ref.read(activeToolProvider);
    switch (tool) {
      case CanvasTool.select:
        _selectAt(layoutPoint);
      case CanvasTool.placeVine:
        await _placeVineAt(layoutPoint);
      case CanvasTool.insertVine:
        await _insertVineAt(layoutPoint);
      case CanvasTool.drawRow:
        ref
            .read(pendingRowProvider.notifier)
            .update((points) => [...points, layoutPoint]);
      case CanvasTool.move:
        _selectAt(layoutPoint);
    }
  }

  void _selectAt(ui.Offset layoutPoint) {
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;
    if (snapshot == null) return;

    final hit = snapshot.index.nearest(
      layoutPoint,
      maxDistance: _viewport.screenToLayoutDistance(_tapRadiusScreenPx),
    );

    ref.read(selectionProvider.notifier).state = hit == null
        // Tapping empty ground deselects. Keeping the selection would make it
        // impossible to clear one without finding something else to tap.
        ? const {}
        : {hit.id};
  }

  Future<void> _placeVineAt(ui.Offset layoutPoint) async {
    final projectId = _projectId;
    if (projectId == null) return;
    await _gesture(
      'place_vine',
      'Place vine',
      () => ref
          .read(layoutDaoProvider)
          .createVine(projectId: projectId, position: layoutPoint),
    );
  }

  /// Inserts a vine into an existing row, asking how to renumber.
  ///
  /// Plan section 6.3 recommended defaulting to a suffix (`3.12.6a`) so nothing
  /// downstream moved. That is superseded -- plant numbers are integers -- so
  /// the real choice is between shifting every label after the insertion point
  /// and reusing a gap left by a vine that was pulled. Only the user knows
  /// whether a printed map is in somebody's pocket, so the app asks and names
  /// the cost.
  Future<void> _insertVineAt(ui.Offset layoutPoint) async {
    final projectId = _projectId;
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;
    if (projectId == null || snapshot == null) return;

    final neighbour = snapshot.index.nearest(
      layoutPoint,
      maxDistance: _viewport.screenToLayoutDistance(_tapRadiusScreenPx * 3),
    );
    if (neighbour == null) {
      _say('Tap next to a vine in the row you want to insert into.');
      return;
    }

    final layout = ref.read(layoutDaoProvider);
    final labels = ref.read(labelServiceProvider);
    final anchor = await layout.vineById(neighbour.id);
    final rowId = anchor?.rowId;
    if (anchor == null || rowId == null) {
      _say('That vine is not on a row, so there is nothing to insert into.');
      return;
    }

    final anchorLabel = await labels.labelOf(anchor.id);
    final affected = await labels.countAffectedByShift(
      rowId: rowId,
      afterPositionIdx: anchor.positionIdx,
    );
    if (!mounted) return;

    final shift = await showDialog<bool>(
      context: context,
      builder: (context) => _RenumberDialog(
        affected: affected,
        after: anchorLabel?.text ?? 'the vine you tapped',
      ),
    );
    if (shift == null || !mounted) return;

    await _gesture(
      'insert_vine',
      'Insert vine in row ${anchorLabel?.row ?? ''}'.trimRight(),
      () async {
        final vineId = await layout.createVine(
          projectId: projectId,
          position: layoutPoint,
        );
        await labels.insertAfter(
          vineId: vineId,
          rowId: rowId,
          afterPositionIdx: anchor.positionIdx,
          shift: shift,
        );
        // Put it on the row properly: insertAfter owns the address, snapping owns
        // the geometry, and a vine with a row must physically be on it.
        await layout.snapVineToRowKeepingNumber(vineId: vineId, rowId: rowId);
        return vineId;
      },
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _finishRow() async {
    final points = ref.read(pendingRowProvider);
    final projectId = _projectId;
    if (projectId == null || points.length < 2) return;

    final path = Polyline(points);
    final label = await _nextRowLabel(projectId);
    final rowId = await _gesture(
      'draw_row',
      'Draw row $label',
      () => ref
          .read(layoutDaoProvider)
          .createRow(projectId: projectId, label: label, path: path),
    );
    if (rowId == null) return;

    ref.read(pendingRowProvider.notifier).state = const [];
    if (!mounted) return;

    await _promptForVines(rowId: rowId, path: path);
  }

  /// Lowest unused row number **in the row's block**.
  ///
  /// Rows are drawn before their block is decided, so this is normally the
  /// unassigned scope. It used to allocate project-wide, which numbered the
  /// first row drawn in a second block 26 rather than 1 -- not how the vineyard
  /// counts, where every block restarts at row 1.
  Future<String> _nextRowLabel(String projectId, {String? blockId}) async {
    final number = await ref
        .read(labelServiceProvider)
        .nextRowNumber(projectId: projectId, blockId: blockId);
    return '$number';
  }

  Future<void> _promptForVines({
    required String rowId,
    required Polyline path,
  }) async {
    final calibration =
        ref.read(calibrationProvider).valueOrNull ??
        ScaleCalibration.uncalibrated;

    final result = await showModalBottomSheet<List<double>>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _PlaceVinesSheet(path: path, calibration: calibration),
    );

    if (result == null || result.isEmpty) return;
    await _gesture(
      'plant_row',
      'Plant ${result.length} vines',
      () => ref
          .read(layoutDaoProvider)
          .placeVinesAlongRow(rowId: rowId, offsets: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot =
        ref.watch(layoutSnapshotProvider).valueOrNull ?? LayoutSnapshot.empty;
    final tool = ref.watch(activeToolProvider);
    final selection = ref.watch(selectionProvider);
    final labels = ref.watch(labelsProvider).valueOrNull ?? const {};
    final showLabels = ref.watch(showLabelsProvider);
    final image = ref.watch(backgroundImageProvider).valueOrNull;
    final pending = ref.watch(pendingRowProvider);

    // Fit the view once the layout has something in it.
    if (!_fittedOnce && !snapshot.bounds.isEmpty) {
      _fittedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _canvasKey.currentState?.fitTo(snapshot.bounds);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.projectName),
        actions: [
          const UndoControls(),
          IconButton(
            tooltip: 'Fields',
            icon: const Icon(Icons.list_alt),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FieldListScreen()),
            ),
          ),
          IconButton(
            tooltip: _showStats ? 'Hide frame stats' : 'Show frame stats',
            icon: Icon(_showStats ? Icons.speed : Icons.speed_outlined),
            onPressed: () => setState(() => _showStats = !_showStats),
          ),
          IconButton(
            tooltip: showLabels ? 'Hide labels' : 'Show labels',
            icon: Icon(showLabels ? Icons.label : Icons.label_outline),
            onPressed: () =>
                ref.read(showLabelsProvider.notifier).update((v) => !v),
          ),
          IconButton(
            tooltip: 'Fit to layout',
            icon: const Icon(Icons.fit_screen),
            onPressed: () => _canvasKey.currentState?.fitTo(snapshot.bounds),
          ),
        ],
      ),
      body: Stack(
        children: [
          VineyardCanvas(
            key: _canvasKey,
            scene: VineyardScene(
              vines: snapshot.positions,
              index: snapshot.index,
              rows: [
                ...snapshot.rows,
                // The row being drawn, previewed live.
                if (pending.length >= 2) Polyline(pending),
              ],
              image: image,
              selection: selection,
              labels: labels,
              showLabels: showLabels,
            ),
            tool: tool,
            onTapLayout: _onTap,
            onViewportChanged: (v) => _viewport = v,
          ),
          if (tool == CanvasTool.drawRow) _drawRowBanner(pending),
          if (_showStats)
            const Positioned(top: 8, right: 8, child: FrameStatsOverlay()),
          // Anchored bottom-left, clear of the toolbar, so the selected vine
          // stays visible while its values are read or changed -- in the field
          // you are looking at the plant and the screen at the same time.
          if (selection.length == 1)
            Positioned(
              left: 0,
              bottom: 90,
              child: VineInspector(vineId: selection.first),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _Toolbar(
              active: tool,
              onChanged: (t) {
                // Abandon a half-drawn row when switching away, rather than
                // leaving invisible state that reappears later.
                if (t != CanvasTool.drawRow) {
                  ref.read(pendingRowProvider.notifier).state = const [];
                }
                ref.read(activeToolProvider.notifier).state = t;
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawRowBanner(List<ui.Offset> pending) {
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  pending.isEmpty
                      ? 'Tap to place the start of the row.'
                      : 'Tap to add points. ${pending.length} placed. '
                            'Rows turn at hard angles, so add a point at each turn.',
                ),
              ),
              if (pending.isNotEmpty)
                TextButton(
                  onPressed: () => ref
                      .read(pendingRowProvider.notifier)
                      .update((p) => p.sublist(0, p.length - 1)),
                  child: const Text('Undo point'),
                ),
              FilledButton(
                onPressed: pending.length >= 2 ? _finishRow : null,
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.active, required this.onChanged});

  final CanvasTool active;
  final ValueChanged<CanvasTool> onChanged;

  static const _tools = [
    (CanvasTool.select, Icons.touch_app, 'Select'),
    (CanvasTool.placeVine, Icons.add_circle_outline, 'Vine'),
    (CanvasTool.insertVine, Icons.playlist_add, 'Insert'),
    (CanvasTool.drawRow, Icons.timeline, 'Row'),
    (CanvasTool.move, Icons.open_with, 'Move'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (tool, icon, label) in _tools)
                // Large targets: this gets used outdoors, possibly with gloves,
                // and a mis-tap in a drawing tool creates data.
                InkWell(
                  onTap: () => onChanged(tool),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          color: tool == active
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: tool == active
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: tool == active
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks whether inserting a vine should renumber the rest of the row.
///
/// Both options are legitimate and the app cannot tell which is right, so it
/// names the cost of each instead of picking. The shift count is the whole
/// point: "this renames 34 vines" is a decision, "labels will change" is a
/// shrug.
class _RenumberDialog extends StatelessWidget {
  const _RenumberDialog({required this.affected, required this.after});

  final int affected;
  final String after;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Insert a vine'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Placing a vine after $after.'),
          const SizedBox(height: 16),
          Text(
            affected == 0
                // Nothing downstream, so the two options do the same thing and
                // offering a choice would be noise.
                ? 'It goes on the end of the row, so nothing is renamed.'
                : 'Shifting renames $affected '
                      '${affected == 1 ? 'vine' : 'vines'} further along the '
                      'row. Any printed map showing their old numbers will be '
                      'out of date.',
          ),
          if (affected > 0) ...[
            const SizedBox(height: 12),
            const Text(
              'Filling a gap instead renames nothing, but the new vine takes '
              'the lowest free number rather than one matching where it sits.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (affected > 0)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Fill a gap'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(affected == 0 ? 'Insert' : 'Shift the rest'),
        ),
      ],
    );
  }
}

/// Asks how to fill a freshly drawn row, previewing the count live.
class _PlaceVinesSheet extends StatefulWidget {
  const _PlaceVinesSheet({required this.path, required this.calibration});

  final Polyline path;
  final ScaleCalibration calibration;

  @override
  State<_PlaceVinesSheet> createState() => _PlaceVinesSheetState();
}

class _PlaceVinesSheetState extends State<_PlaceVinesSheet> {
  bool _byCount = true;
  final _countController = TextEditingController(text: '20');
  final _spacingController = TextEditingController(text: '6');

  @override
  void dispose() {
    _countController.dispose();
    _spacingController.dispose();
    super.dispose();
  }

  List<double> get _offsets {
    if (_byCount) {
      final count = int.tryParse(_countController.text) ?? 0;
      return RowGeneration.byCount(widget.path, count);
    }
    final spacing = double.tryParse(_spacingController.text) ?? 0;
    return RowGeneration.bySpacing(
      widget.path,
      widget.calibration.toPixels(spacing),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offsets = _offsets;
    final unit = widget.calibration.unit;

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
          Text('Plant this row', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Row length ${widget.calibration.format(widget.path.length)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
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
              controller: _countController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Number of vines',
                helperText: 'Spread evenly, first and last at the ends',
              ),
              onChanged: (_) => setState(() {}),
            )
          else
            TextField(
              controller: _spacingController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Spacing ($unit)',
                helperText: widget.calibration.isCalibrated
                    ? 'Measured against this project\'s scale'
                    : 'No scale set for this project, so this is in pixels',
              ),
              onChanged: (_) => setState(() {}),
            ),
          const SizedBox(height: 16),
          Text(
            offsets.isEmpty
                ? 'Nothing to place'
                : 'Will place ${offsets.length} vines',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Leave empty'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: offsets.isEmpty
                    ? null
                    : () => Navigator.pop(context, offsets),
                child: const Text('Plant'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
