import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry/polyline.dart';
import '../../core/geometry/shapes.dart';
import '../../core/models/enums.dart';
import '../../core/providers.dart';
import '../data_entry/plant_inspector.dart';
import '../schema/field_editor_screen.dart';
import '../schema/identifier_template_editor.dart';
import 'canvas_controller.dart';
import 'frame_stats_overlay.dart';
import 'tools/new_object_sheet.dart';
import 'tools/plant_actions_sheet.dart';
import 'tools/renumber_dialog.dart';
import 'undo_controls.dart';
import 'viewport.dart';
import 'vineyard_canvas.dart';
import 'vineyard_painter.dart';

/// The map screen: canvas, toolbar, and the drawing flows.
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

  /// Where a drag started, in layout units.
  ui.Offset? _dragOrigin;

  /// What the move tool grabbed: a plant id, or an object id.
  String? _draggingPlant;
  String? _draggingObject;

  /// Finger-sized tap target, converted to layout units so the tolerance stays
  /// constant on screen at any zoom.
  static const _tapRadiusScreenPx = 24.0;

  String? get _projectId => ref.read(activeProjectIdProvider);

  /// Runs a write as one undoable gesture.
  ///
  /// Every path in this screen that touches the database goes through here. The
  /// unit of undo is what the user did, not what the DAO did -- drawing a
  /// planted row is one press of undo even though it writes an object, forty
  /// plants and their memberships.
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

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------- taps

  Future<void> _onTap(ui.Offset layoutPoint) async {
    switch (ref.read(activeToolProvider)) {
      case CanvasTool.select:
        _selectAt(layoutPoint);
      case CanvasTool.lasso:
        // A tap with the lasso is just a select; nothing was enclosed.
        _selectAt(layoutPoint);
      case CanvasTool.placePlant:
        await _placePlantAt(layoutPoint);
      case CanvasTool.insertPlant:
        await _insertPlantAt(layoutPoint);
      case CanvasTool.drawObject:
        ref
            .read(pendingShapeProvider.notifier)
            .update((points) => [...points, layoutPoint]);
      case CanvasTool.move:
        _selectAt(layoutPoint);
    }
  }

  /// Selects the plant under the tap, or failing that the object under it.
  void _selectAt(ui.Offset layoutPoint) {
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;
    if (snapshot == null) return;

    final tolerance = _viewport.screenToLayoutDistance(_tapRadiusScreenPx);
    final hit = snapshot.index.nearest(layoutPoint, maxDistance: tolerance);
    if (hit != null) {
      ref.read(selectionProvider.notifier).state = {hit.id};
      return;
    }

    // Nothing plant-shaped there. An object is the next most likely target, and
    // selecting one is how "everything on this row" is expressed.
    final object = _objectAt(layoutPoint, tolerance, snapshot);
    if (object != null) {
      _selectObject(object);
      return;
    }

    // Tapping empty ground deselects. Keeping the selection would make it
    // impossible to clear one without finding something else to tap.
    ref.read(selectionProvider.notifier).state = const {};
  }

  DrawnObject? _objectAt(
    ui.Offset point,
    double tolerance,
    LayoutSnapshot snapshot,
  ) {
    for (final object in snapshot.objects) {
      switch (object.shape) {
        case final PolylineShape line:
          if (line.path.closestTo(point).distance <= tolerance) return object;
        case final PolygonShape polygon:
          if (pointInPolygon(point, polygon.vertices)) return object;
        case final PointShape p:
          if ((p.at - point).distance <= tolerance) return object;
      }
    }
    return null;
  }

  Future<void> _selectObject(DrawnObject object) async {
    final plants = await ref
        .read(plantsDaoProvider)
        .resolveSelection(objectIds: [object.id]);

    if (!mounted) return;
    if (plants.isEmpty) {
      _say('${object.label} has no plants on it yet.');
      return;
    }
    ref.read(selectionProvider.notifier).state = plants;
  }

  Future<void> _placePlantAt(ui.Offset layoutPoint) async {
    final projectId = _projectId;
    if (projectId == null) return;
    await _gesture(
      'place_plant',
      'Place plant',
      () => ref
          .read(layoutDaoProvider)
          .createPlant(projectId: projectId, position: layoutPoint),
    );
  }

  /// Inserts a plant into an existing line, asking how to renumber.
  ///
  /// Plan section 6.3 recommended defaulting to a suffix (`3.12.6a`) so nothing
  /// downstream moved. That is superseded -- plant numbers are integers -- so
  /// the real choice is between shifting every number after the insertion point
  /// and reusing a gap left by a plant that was pulled. Only the user knows
  /// whether a printed map is in somebody's pocket, so the app asks and names
  /// the cost.
  Future<void> _insertPlantAt(ui.Offset layoutPoint) async {
    final projectId = _projectId;
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;
    if (projectId == null || snapshot == null) return;

    final neighbour = snapshot.index.nearest(
      layoutPoint,
      maxDistance: _viewport.screenToLayoutDistance(_tapRadiusScreenPx * 3),
    );
    if (neighbour == null) {
      _say('Tap next to a plant on the line you want to insert into.');
      return;
    }

    final layout = ref.read(layoutDaoProvider);
    final labels = ref.read(labelServiceProvider);
    final anchor = await layout.plantById(neighbour.id);
    final carrierId = anchor?.carrierId;
    if (anchor == null || carrierId == null) {
      _say('That plant is not on a line, so there is nothing to insert into.');
      return;
    }

    final anchorId = await labels.identifierOf(anchor.id);
    final affected = await labels.countAffectedByShift(
      carrierId: carrierId,
      afterPositionIdx: anchor.positionIdx,
    );
    if (!mounted) return;

    final shift = await showDialog<bool>(
      context: context,
      builder: (context) => RenumberDialog(
        affected: affected,
        after: anchorId?.text ?? 'the plant you tapped',
      ),
    );
    if (shift == null || !mounted) return;

    await _gesture('insert_plant', 'Insert plant', () async {
      final plantId = await layout.createPlant(
        projectId: projectId,
        position: layoutPoint,
      );
      await labels.insertAfter(
        plantId: plantId,
        carrierId: carrierId,
        afterPositionIdx: anchor.positionIdx,
        shift: shift,
      );
      // insertAfter owns the number; snapping owns the geometry. A plant with a
      // carrier has to physically be on it.
      await layout.snapPlantToCarrierKeepingNumber(
        plantId: plantId,
        carrierId: carrierId,
      );
      return plantId;
    });
  }

  // ------------------------------------------------------------------ drags

  void _onDragStart(ui.Offset layoutPoint) {
    _dragOrigin = layoutPoint;
    final tool = ref.read(activeToolProvider);
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;

    switch (tool) {
      case CanvasTool.select:
        ref.read(marqueeProvider.notifier).state = ui.Rect.fromPoints(
          layoutPoint,
          layoutPoint,
        );
      case CanvasTool.lasso:
        ref.read(lassoProvider.notifier).state = [layoutPoint];
      case CanvasTool.move:
        if (snapshot == null) return;
        final tolerance = _viewport.screenToLayoutDistance(_tapRadiusScreenPx);
        _draggingPlant = snapshot.index
            .nearest(layoutPoint, maxDistance: tolerance)
            ?.id;
        // Only reach for an object if no plant was grabbed: plants are what the
        // user is usually aiming at, and they sit on top of the lines.
        _draggingObject = _draggingPlant != null
            ? null
            : _objectAt(layoutPoint, tolerance, snapshot)?.id;
      case CanvasTool.placePlant:
      case CanvasTool.insertPlant:
      case CanvasTool.drawObject:
        break;
    }
  }

  void _onDragUpdate(ui.Offset layoutPoint) {
    final origin = _dragOrigin;
    if (origin == null) return;

    switch (ref.read(activeToolProvider)) {
      case CanvasTool.select:
        ref.read(marqueeProvider.notifier).state = ui.Rect.fromPoints(
          origin,
          layoutPoint,
        );
      case CanvasTool.lasso:
        ref.read(lassoProvider.notifier).update((p) => [...p, layoutPoint]);
      case CanvasTool.move:
      case CanvasTool.placePlant:
      case CanvasTool.insertPlant:
      case CanvasTool.drawObject:
        break;
    }
  }

  Future<void> _onDragEnd(ui.Offset layoutPoint) async {
    final origin = _dragOrigin;
    _dragOrigin = null;
    if (origin == null) return;

    final tool = ref.read(activeToolProvider);
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;

    switch (tool) {
      case CanvasTool.select:
        final rect = ref.read(marqueeProvider);
        ref.read(marqueeProvider.notifier).state = null;
        if (rect == null || snapshot == null) return;
        // SpatialIndex.inRect is exactly this query and already exists -- it
        // has only ever been used for viewport culling.
        ref.read(selectionProvider.notifier).state = {
          for (final p in snapshot.index.inRect(rect)) p.id,
        };

      case CanvasTool.lasso:
        final path = ref.read(lassoProvider);
        ref.read(lassoProvider.notifier).state = const [];
        if (path.length < 3 || snapshot == null) return;
        // Bounds first, then the exact test: point-in-polygon over 3,000 plants
        // against a 200-point lasso is worth avoiding.
        final bounds = _boundsOfPath(path);
        ref.read(selectionProvider.notifier).state = {
          for (final p in snapshot.index.inRect(bounds))
            if (pointInPolygon(p.position, path)) p.id,
        };

      case CanvasTool.move:
        final plant = _draggingPlant;
        final object = _draggingObject;
        _draggingPlant = null;
        _draggingObject = null;

        final layout = ref.read(layoutDaoProvider);
        if (plant != null) {
          // One operation per drag, not per pointer event: dragging a plant
          // across the map must be one press of undo.
          await _gesture(
            'move_plant',
            'Move plant',
            () => layout.movePlant(plant, layoutPoint),
          );
        } else if (object != null) {
          await _gesture(
            'move_object',
            'Move object',
            () => layout.moveObject(object, layoutPoint - origin),
          );
        }

      case CanvasTool.placePlant:
      case CanvasTool.insertPlant:
      case CanvasTool.drawObject:
        break;
    }
  }

  ui.Rect _boundsOfPath(List<ui.Offset> points) {
    var minX = points.first.dx, maxX = points.first.dx;
    var minY = points.first.dy, maxY = points.first.dy;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // --------------------------------------------------------- drawing objects

  /// Turns the drawn points into a named object, planted if it is a line.
  Future<void> _finishObject() async {
    final points = ref.read(pendingShapeProvider);
    final projectId = _projectId;
    final fieldId = ref.read(activeObjectFieldProvider);
    if (projectId == null || fieldId == null) return;

    final field = await ref.read(fieldDefsDaoProvider).byId(fieldId);
    final drawType = field?.drawType;
    if (field == null || drawType == null) return;

    final shape = switch (drawType) {
      DrawType.point when points.isNotEmpty => PointShape(points.first),
      DrawType.polyline when points.length >= 2 => PolylineShape(
        Polyline(points),
      ),
      DrawType.polygon when points.length >= 3 => PolygonShape(points),
      _ => null,
    };
    if (shape == null) {
      _say(switch (drawType) {
        DrawType.polygon => 'An area needs at least three points.',
        DrawType.polyline => 'A line needs at least two points.',
        DrawType.point => 'Tap once to place it.',
      });
      return;
    }

    if (!mounted) return;
    final plan = await showModalBottomSheet<NewObject>(
      context: context,
      isScrollControlled: true,
      builder: (context) => NewObjectSheet(
        field: field,
        shape: shape,
        calibration: ref.read(calibrationProvider).valueOrNull,
      ),
    );
    if (plan == null || !mounted) return;

    ref.read(pendingShapeProvider.notifier).state = const [];

    final layout = ref.read(layoutDaoProvider);
    await _gesture('draw_object', 'Draw ${field.name} ${plan.label}', () async {
      final objectId = await layout.createObject(
        projectId: projectId,
        fieldDefId: fieldId,
        label: plan.label,
        geometry: plan.shape,
      );
      if (plan.offsets.isNotEmpty) {
        await layout.placePlantsAlongCarrier(
          carrierId: objectId,
          offsets: plan.offsets,
        );
      }
      return objectId;
    });
  }

  /// Picks which object field the draw tool creates.
  Future<void> _chooseObjectField() async {
    final projectId = _projectId;
    if (projectId == null) return;

    final fields = await ref
        .read(fieldDefsDaoProvider)
        .objectFieldsForProject(projectId);
    if (!mounted) return;

    if (fields.isEmpty) {
      // "Want neither, get neither" cuts both ways: with no object fields there
      // is nothing to draw, and the honest response is to say so and offer the
      // place that fixes it.
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nothing to draw yet'),
          content: const Text(
            'Rows and blocks are not built in -- you define what this vineyard '
            'has. Create a field, mark it as something drawn, and pick a '
            'shape.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Set one up'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FieldListScreen()),
        );
      }
      return;
    }

    if (fields.length == 1) {
      ref.read(activeObjectFieldProvider.notifier).state = fields.first.id;
      return;
    }

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final field in fields)
              ListTile(
                leading: Icon(switch (field.drawType!) {
                  DrawType.polyline => Icons.timeline,
                  DrawType.polygon => Icons.pentagon_outlined,
                  DrawType.point => Icons.place_outlined,
                }),
                title: Text(field.name),
                subtitle: Text(
                  field.isContainer
                      ? 'Plants belong to it'
                      : 'Nothing to do with the plants',
                ),
                onTap: () => Navigator.pop(context, field.id),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      ref.read(activeObjectFieldProvider.notifier).state = chosen;
    }
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
    final pending = ref.watch(pendingShapeProvider);
    final activeField = ref.watch(activeObjectFieldProvider);

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
            tooltip: 'Plant ID format',
            icon: const Icon(Icons.tag),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const IdentifierTemplateEditor(),
              ),
            ),
          ),
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
            tooltip: showLabels ? 'Hide IDs' : 'Show IDs',
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
              plants: snapshot.positions,
              index: snapshot.index,
              objects: [
                ...snapshot.objects,
                // The shape being drawn, previewed live.
                ?_previewOf(pending, activeField),
              ],
              image: image,
              selection: selection,
              labels: labels,
              showLabels: showLabels,
              marquee: ref.watch(marqueeProvider),
              lasso: ref.watch(lassoProvider),
            ),
            tool: tool,
            onTapLayout: _onTap,
            onDragStart: _onDragStart,
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEnd,
            onViewportChanged: (v) => _viewport = v,
          ),
          if (tool == CanvasTool.drawObject) _drawBanner(pending, activeField),
          if (_showStats)
            const Positioned(top: 8, right: 8, child: FrameStatsOverlay()),
          // Anchored bottom-left, clear of the toolbar, so the selected plant
          // stays visible while its values are read or changed -- in the field
          // you are looking at the plant and the screen at the same time.
          if (selection.length == 1)
            Positioned(
              left: 0,
              bottom: 90,
              child: PlantInspector(plantId: selection.first),
            ),
          if (selection.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90,
              child: _BulkBar(selection: selection),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _Toolbar(
              active: tool,
              onChanged: (t) async {
                // Abandon a half-drawn shape when switching away, rather than
                // leaving invisible state that reappears later.
                if (t != CanvasTool.drawObject) {
                  ref.read(pendingShapeProvider.notifier).state = const [];
                }
                ref.read(activeToolProvider.notifier).state = t;
                if (t == CanvasTool.drawObject) await _chooseObjectField();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The in-progress shape, as an object the painter can draw.
  DrawnObject? _previewOf(List<ui.Offset> points, String? fieldId) {
    if (fieldId == null || points.isEmpty) return null;
    final shape = points.length >= 2
        ? PolylineShape(Polyline(points))
        : PointShape(points.first);
    return (
      id: '__preview',
      fieldDefId: fieldId,
      label: '',
      shape: shape,
      isContainer: false,
    );
  }

  Widget _drawBanner(List<ui.Offset> pending, String? fieldId) {
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
                  fieldId == null
                      ? 'Pick what you are drawing first.'
                      : pending.isEmpty
                      ? 'Tap to place the first point.'
                      : '${pending.length} placed. Lines and areas turn at hard '
                            'angles, so add a point at each corner.',
                ),
              ),
              if (pending.isNotEmpty)
                TextButton(
                  onPressed: () => ref
                      .read(pendingShapeProvider.notifier)
                      .update((p) => p.sublist(0, p.length - 1)),
                  child: const Text('Undo point'),
                ),
              FilledButton(
                onPressed: pending.isEmpty ? null : _finishObject,
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Actions available on a multi-plant selection.
class _BulkBar extends ConsumerWidget {
  const _BulkBar({required this.selection});

  final Set<String> selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Text(
              '${selection.length} plants',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) => PlantActionsSheet(selection: selection),
              ),
              child: const Text('Actions'),
            ),
            IconButton(
              tooltip: 'Clear selection',
              icon: const Icon(Icons.close),
              onPressed: () =>
                  ref.read(selectionProvider.notifier).state = const {},
            ),
          ],
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
    (CanvasTool.lasso, Icons.gesture, 'Lasso'),
    (CanvasTool.placePlant, Icons.add_circle_outline, 'Plant'),
    (CanvasTool.insertPlant, Icons.playlist_add, 'Insert'),
    (CanvasTool.drawObject, Icons.timeline, 'Draw'),
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
                      horizontal: 12,
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
