import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry/polyline.dart';
import '../../core/geometry/shapes.dart';
import '../../core/models/enums.dart';
import '../../core/providers.dart';
import '../data_entry/bulk_edit.dart';
import '../data_entry/plant_inspector.dart';
import '../projects/import_screen.dart';
import '../schema/field_editor_screen.dart';
import '../schema/identifier_template_editor.dart';
import 'canvas_controller.dart';
import '../../app_theme.dart';
import '../../core/format.dart';
import 'frame_stats_overlay.dart';
import 'map_chrome.dart';
import 'plant_colouring.dart';
import 'tools/array_sheet.dart';
import 'tools/identifier_change_prompt.dart';
import 'tools/new_object_sheet.dart';
import 'tools/object_actions_sheet.dart';
import 'tools/plant_actions_sheet.dart';
import 'tools/renumber_dialog.dart';
import 'undo_controls.dart';
import 'viewport.dart';
import 'vineyard_canvas.dart';
import 'vineyard_painter.dart';

/// The map screen: canvas, toolbar, and the drawing flows.
class VineyardScreen extends ConsumerStatefulWidget {
  const VineyardScreen({super.key});

  @override
  ConsumerState<VineyardScreen> createState() => _VineyardScreenState();
}

class _VineyardScreenState extends ConsumerState<VineyardScreen> {
  final _canvasKey = GlobalKey<VineyardCanvasState>();
  CanvasViewport _viewport = CanvasViewport.identity;
  bool _fittedOnce = false;

  /// Where a drag started, in layout units.
  ui.Offset? _dragOrigin;

  /// What the move tool grabbed: a plant id, or an object id.
  String? _draggingPlant;
  String? _draggingObject;

  /// The object whose shape the reshape tool grabbed, and its original shape --
  /// kept so a refused edit can put the boundary back exactly.
  String? _reshapingObject;
  Shape? _shapeBeforeReshape;

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

    // The operation is a transaction, so a failure leaves nothing half
    // written -- but it used to leave nothing said, either: the tap simply did
    // nothing, which on a tablet in a field is indistinguishable from a missed
    // touch.
    try {
      return await ref
          .read(operationRecorderProvider)
          .run(
            projectId: projectId,
            kind: kind,
            description: description,
            body: body,
          );
    } catch (e) {
      if (mounted) _say('$description failed, and nothing was changed: $e');
      return null;
    }
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
      case CanvasTool.array:
      case CanvasTool.pointArray:
        // All three collect points the same way and differ only in what Done
        // does, so they share the pending-shape state wholesale.
        ref
            .read(pendingShapeProvider.notifier)
            .update((points) => [...points, layoutPoint]);
      case CanvasTool.split:
        await _splitAt(layoutPoint);
      case CanvasTool.move:
      case CanvasTool.reshape:
        _selectAt(layoutPoint);
    }
  }

  /// Cuts the line under the tap at that point.
  Future<void> _splitAt(ui.Offset layoutPoint) async {
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;
    if (snapshot == null) return;

    final tolerance = _viewport.screenToLayoutDistance(_tapRadiusScreenPx);
    final object = _objectAt(layoutPoint, tolerance, snapshot);
    final shape = object?.shape;
    if (object == null || shape is! PolylineShape) {
      _say('Tap the line you want to cut, at the point you want to cut it.');
      return;
    }

    final at = shape.path.closestTo(layoutPoint);
    if (shape.path.splitAt(at.offset) == null) {
      _say('That is too close to the end -- there would be nothing to split.');
      return;
    }

    final field = await ref.read(fieldDefsDaoProvider).byId(object.fieldDefId);
    if (field == null || !mounted) return;

    final label = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SplitSheet(
        objectId: object.id,
        label: object.label,
        fieldName: field.name,
        atOffset: at.offset,
      ),
    );
    if (label == null || !mounted) return;

    await _gesture(
      'split_object',
      'Split ${field.name} ${object.label}',
      () => ref
          .read(layoutDaoProvider)
          .splitCarrier(
            objectId: object.id,
            atOffset: at.offset,
            newLabel: label,
          ),
    );
  }

  /// Selects the plant under the tap, or failing that the object under it.
  void _selectAt(ui.Offset layoutPoint) {
    final snapshot = ref.read(layoutSnapshotProvider).valueOrNull;
    if (snapshot == null) return;

    final sticky = ref.read(stickySelectProvider);
    final tolerance = _viewport.screenToLayoutDistance(_tapRadiusScreenPx);
    final hit = snapshot.index.nearest(layoutPoint, maxDistance: tolerance);
    if (hit != null) {
      ref.read(selectedObjectProvider.notifier).state = null;
      ref
          .read(selectionProvider.notifier)
          .update(
            // Toggling rather than only adding: with sticky on, the way to correct
            // an over-grab is to tap the stray plant again. An add-only mode would
            // mean starting the whole selection over.
            (current) => !sticky
                ? {hit.id}
                : current.contains(hit.id)
                ? ({...current}..remove(hit.id))
                : {...current, hit.id},
          );
      return;
    }

    // An empty slot, only when no living plant is near: a replant stands on
    // the same spot as the plant it replaced, and the tap means the living one.
    final slot = snapshot.retiredIndex.nearest(
      layoutPoint,
      maxDistance: tolerance,
    );
    if (slot != null) {
      ref.read(selectedObjectProvider.notifier).state = null;
      ref.read(selectionProvider.notifier).state = {slot.id};
      return;
    }

    // Nothing plant-shaped there. An object is the next most likely target.
    final object = _objectAt(layoutPoint, tolerance, snapshot);
    if (object != null) {
      // The object itself, not its plants. v3 selected the plants directly,
      // which quietly made the object unreachable -- and the object is what you
      // rename, reshape, plant into and delete. Its plants are one tap away in
      // the sheet.
      ref.read(selectedObjectProvider.notifier).state = object.id;
      if (!sticky) ref.read(selectionProvider.notifier).state = const {};
      return;
    }

    // Tapping empty ground deselects -- unless sticky is on, where a stray tap
    // between plants must not throw away a selection thirty taps in the making.
    ref.read(selectedObjectProvider.notifier).state = null;
    if (!sticky) ref.read(selectionProvider.notifier).state = const {};
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

  /// The vertex of a drawn object nearest a point, or null if none is close.
  ///
  /// Prefers the selected object when one is selected, so reshaping a boundary
  /// that runs under a row does not grab the row's corner instead. Without that,
  /// the two shapes that most often overlap are the two you most often cannot
  /// tell the tool apart.
  ({DrawnObject object, int vertex})? _vertexAt(
    ui.Offset point,
    double tolerance,
    LayoutSnapshot snapshot,
  ) {
    final preferred = ref.read(selectedObjectProvider);
    final candidates = [
      for (final o in snapshot.objects)
        if (o.id == preferred) o,
      for (final o in snapshot.objects)
        if (o.id != preferred) o,
    ];

    for (final object in candidates) {
      var best = -1;
      var bestDistance = double.infinity;
      final points = object.shape.points;
      for (var i = 0; i < points.length; i++) {
        final distance = (points[i] - point).distance;
        if (distance <= tolerance && distance < bestDistance) {
          best = i;
          bestDistance = distance;
        }
      }
      if (best >= 0) return (object: object, vertex: best);
    }
    return null;
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

      case CanvasTool.reshape:
        if (snapshot == null) return;
        // A generous target: corners are small, this is used outdoors, and
        // missing one costs a whole gesture.
        final grabbed = _vertexAt(
          layoutPoint,
          _viewport.screenToLayoutDistance(_tapRadiusScreenPx * 1.5),
          snapshot,
        );
        if (grabbed == null) {
          _reshapingObject = null;
          _shapeBeforeReshape = null;
          return;
        }
        _reshapingObject = grabbed.object.id;
        _shapeBeforeReshape = grabbed.object.shape;
        ref.read(reshapeDraftProvider.notifier).state = (
          objectId: grabbed.object.id,
          vertex: grabbed.vertex,
          shape: grabbed.object.shape,
        );

      case CanvasTool.placePlant:
      case CanvasTool.insertPlant:
      case CanvasTool.drawObject:
      case CanvasTool.array:
      case CanvasTool.pointArray:
      case CanvasTool.split:
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

      case CanvasTool.reshape:
        final draft = ref.read(reshapeDraftProvider);
        final original = _shapeBeforeReshape;
        if (draft == null || original == null) return;
        // Always from the *original* shape, never from the last draft. Chaining
        // moves off each other accumulates float error, and a polyline whose
        // vertex is dragged in a circle would slowly wander.
        ref.read(reshapeDraftProvider.notifier).state = (
          objectId: draft.objectId,
          vertex: draft.vertex,
          shape: original.withPointMoved(draft.vertex, layoutPoint),
        );

      case CanvasTool.move:
      case CanvasTool.placePlant:
      case CanvasTool.insertPlant:
      case CanvasTool.drawObject:
      case CanvasTool.array:
      case CanvasTool.pointArray:
      case CanvasTool.split:
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
        _applySelection({for (final p in snapshot.index.inRect(rect)) p.id});

      case CanvasTool.lasso:
        final path = ref.read(lassoProvider);
        ref.read(lassoProvider.notifier).state = const [];
        if (path.length < 3 || snapshot == null) return;
        // Bounds first, then the exact test: point-in-polygon over 3,000 plants
        // against a 200-point lasso is worth avoiding.
        final bounds = _boundsOfPath(path);
        _applySelection({
          for (final p in snapshot.index.inRect(bounds))
            if (pointInPolygon(p.position, path)) p.id,
        });

      case CanvasTool.reshape:
        final draft = ref.read(reshapeDraftProvider);
        ref.read(reshapeDraftProvider.notifier).state = null;
        final objectId = _reshapingObject;
        _reshapingObject = null;
        _shapeBeforeReshape = null;
        if (draft == null || objectId == null) return;
        // A tap with the reshape tool is a select, not a zero-length reshape.
        if (origin == layoutPoint) return;
        await _commitReshape(objectId, draft.shape);

      case CanvasTool.move:
        final plant = _draggingPlant;
        final object = _draggingObject;
        _draggingPlant = null;
        _draggingObject = null;

        if (plant != null) {
          await _commitPlantMove(plant, layoutPoint);
        } else if (object != null) {
          await _commitObjectMove(object, layoutPoint - origin);
        }

      case CanvasTool.placePlant:
      case CanvasTool.insertPlant:
      case CanvasTool.drawObject:
      case CanvasTool.array:
      case CanvasTool.pointArray:
      case CanvasTool.split:
        break;
    }
  }

  /// Throws away a drag that a second finger turned into navigation.
  ///
  /// Nothing is written: the marquee, lasso, reshape draft and grabbed plant
  /// all simply vanish, and the map is left exactly as it was.
  void _onDragCancel() {
    _dragOrigin = null;
    _draggingPlant = null;
    _draggingObject = null;
    _reshapingObject = null;
    _shapeBeforeReshape = null;
    ref.read(marqueeProvider.notifier).state = null;
    ref.read(lassoProvider.notifier).state = const [];
    ref.read(reshapeDraftProvider.notifier).state = null;
  }

  /// Applies a marquee or lasso result, respecting the sticky toggle.
  ///
  /// Union rather than replace when sticky: two marquees over two separate
  /// stands of plants is the natural way to select both, and it is the reason
  /// this mode exists at all.
  void _applySelection(Set<String> hits) {
    final sticky = ref.read(stickySelectProvider);
    ref
        .read(selectionProvider.notifier)
        .update((current) => sticky ? {...current, ...hits} : hits);
  }

  /// Writes a plant move, refusing one that would create a duplicate ID.
  ///
  /// **Refused but not confirmed**, and the asymmetry is deliberate. Dragging one
  /// plant out of Block 2 changes its ID, but that is the direct, visible
  /// consequence of the thing the user just did, and the inspector shows the new
  /// ID immediately -- a dialog every time would be noise. A *collision* is
  /// different: two plants called `11.3` makes every record naming that plant
  /// worthless, and no gesture is allowed to produce one.
  Future<void> _commitPlantMove(String plantId, ui.Offset to) async {
    final layout = ref.read(layoutDaoProvider);
    final change = await layout.previewPlantMove(
      plantId: plantId,
      position: to,
    );
    if (!mounted) return;

    if (!change.isSafe) {
      _say(
        'Moving it there would make two plants '
        '${change.duplicates.first} -- so it stayed put.',
      );
      return;
    }

    // One operation per drag, not per pointer event: dragging a plant across the
    // map must be one press of undo.
    await _gesture(
      'move_plant',
      'Move plant',
      () => layout.movePlant(plantId, to),
    );
  }

  /// Writes an object move, with the full boundary-edit treatment.
  ///
  /// Unlike a single plant, dragging a line or a block can sweep hundreds of
  /// plants across a boundary at once, so this one is counted and confirmed.
  Future<void> _commitObjectMove(String objectId, ui.Offset delta) async {
    final layout = ref.read(layoutDaoProvider);
    final object = await layout.objectById(objectId);
    final shape = await layout.shapeOf(objectId);
    if (object == null || shape == null || !mounted) return;

    final field = await ref.read(fieldDefsDaoProvider).byId(object.fieldDefId);
    if (field == null || !mounted) return;

    final moved = switch (shape) {
      final PolylineShape s => PolylineShape(
        Polyline([for (final p in s.path.points) p + delta]),
      ),
      final PolygonShape s => PolygonShape([
        for (final v in s.vertices) v + delta,
      ]),
      final PointShape s => PointShape(s.at + delta),
    };

    final overlap = await layout.checkOverlap(
      fieldDefId: object.fieldDefId,
      shape: moved,
      ignoringObjectId: objectId,
    );
    if (!mounted) return;
    if (overlap != null) {
      _say(
        'That would put ${field.name} ${object.label} over '
        '${field.name} ${overlap.label}. Two of the same cannot share ground, '
        'so it stayed put.',
      );
      return;
    }

    final change = await layout.previewGeometryChange(
      objectId: objectId,
      geometry: moved,
    );
    if (!mounted) return;

    final ok = await confirmIdentifierChange(
      context,
      change: change,
      action: 'Move ${field.name} ${object.label}',
      proceedLabel: 'Move it',
      refusalAdvice:
          'It stayed put. Plants would end up sharing an ID, so renumber them '
          'first or move it somewhere else.',
    );
    if (!ok || !mounted) return;

    await _gesture(
      'move_object',
      'Move ${field.name} ${object.label}',
      () => layout.moveObject(objectId, delta),
    );
  }

  /// Writes a reshape, after the two gates the plan requires.
  ///
  /// **Overlap first**, because it is a hard rule about the drawing rather than
  /// a question for the user: two instances of the same field may not share
  /// ground. **Then the identifier change**, which is all-or-nothing -- membership
  /// is derived from geometry, so a plant inside Block 2 *is* in Block 2, and
  /// declining per-plant would need a stored override contradicting the map.
  ///
  /// Either refusal leaves the boundary exactly where it was. Nothing partial is
  /// ever written, so there is no half-moved boundary to notice later.
  Future<void> _commitReshape(String objectId, Shape shape) async {
    final layout = ref.read(layoutDaoProvider);
    final object = await layout.objectById(objectId);
    if (object == null || !mounted) return;

    final field = await ref.read(fieldDefsDaoProvider).byId(object.fieldDefId);
    if (field == null || !mounted) return;

    final overlap = await layout.checkOverlap(
      fieldDefId: object.fieldDefId,
      shape: shape,
      ignoringObjectId: objectId,
    );
    if (!mounted) return;
    if (overlap != null) {
      _say(
        'That would put ${field.name} ${object.label} over '
        '${field.name} ${overlap.label}. Two of the same cannot share ground, '
        'so the boundary is back where it was.',
      );
      return;
    }

    final change = await layout.previewGeometryChange(
      objectId: objectId,
      geometry: shape,
    );
    if (!mounted) return;

    final ok = await confirmIdentifierChange(
      context,
      change: change,
      action: 'Reshape ${field.name} ${object.label}',
      proceedLabel: 'Move the boundary',
      refusalAdvice:
          'The boundary is back where it was. Plants would end up sharing an '
          'ID, so either move it somewhere else or renumber them first.',
    );
    if (!ok || !mounted) return;

    await _gesture(
      'reshape_object',
      'Reshape ${field.name} ${object.label}',
      () => layout.updateObjectGeometry(objectId, shape),
    );
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

  /// Turns the drawn line into a parallel run of independent objects.
  ///
  /// Each line is written as an ordinary, unrelated object -- no parent link, no
  /// re-flow -- so dragging one endpoint later leaves the rest alone. All of them
  /// go in under **one** operation, because "make me 24 rows" is one thing the
  /// user did and should be one press of undo.
  Future<void> _finishArray() async {
    final points = ref.read(pendingShapeProvider);
    final projectId = _projectId;
    final fieldId = ref.read(activeObjectFieldProvider);
    if (projectId == null || fieldId == null) return;

    if (points.length < 2) {
      _say('Draw the first line, then say how many more you want.');
      return;
    }

    final field = await ref.read(fieldDefsDaoProvider).byId(fieldId);
    if (field == null || field.drawType != DrawType.polyline) {
      _say('A run only makes sense for lines.');
      return;
    }
    if (!mounted) return;

    final plan = await showModalBottomSheet<ArrayPlan>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ArraySheet(
        field: field,
        seed: Polyline(points),
        calibration: ref.read(calibrationProvider).valueOrNull,
      ),
    );
    if (plan == null || !mounted) return;

    ref.read(pendingShapeProvider.notifier).state = const [];

    final layout = ref.read(layoutDaoProvider);
    final labels = ref.read(labelServiceProvider);
    await _gesture(
      'array_objects',
      'Create ${plan.lines.length} ${field.name.toLowerCase()}s',
      () async {
        // Labels resolved one at a time inside the operation, so each is free
        // against the ones just written rather than against a stale snapshot.
        for (final line in plan.lines) {
          final label = await labels.nextObjectLabel(fieldId);
          final objectId = await layout.createObject(
            projectId: projectId,
            fieldDefId: fieldId,
            label: '$label',
            geometry: PolylineShape(line),
          );
          if (plan.offsets.isNotEmpty) {
            await layout.placePlantsAlongCarrier(
              carrierId: objectId,
              offsets: plan.offsets,
            );
          }
        }
      },
    );
  }

  /// Places evenly spaced instances along a guide the user drew for the purpose.
  ///
  /// **The guide is never persisted.** It is a construction aid, and it is gone
  /// the moment this returns -- sometimes the line you want to measure against is
  /// not a thing the vineyard contains.
  Future<void> _finishPointArray() async {
    final points = ref.read(pendingShapeProvider);
    final projectId = _projectId;
    if (projectId == null) return;

    if (points.length < 2) {
      _say('Draw a guide line for them to sit along.');
      return;
    }

    final fields = await ref
        .read(fieldDefsDaoProvider)
        .objectFieldsForProject(projectId);
    if (!mounted) return;

    final guide = Polyline(points);
    final plan = await showModalBottomSheet<PointArrayPlan>(
      context: context,
      isScrollControlled: true,
      builder: (context) => PointArraySheet(
        guide: guide,
        pointFields: [
          for (final f in fields)
            if (f.drawType == DrawType.point) f,
        ],
        guideIsThrowaway: true,
        calibration: ref.read(calibrationProvider).valueOrNull,
      ),
    );
    if (plan == null || !mounted) return;

    // Cleared whether or not anything was created: the guide's whole contract is
    // that it does not outlive the gesture.
    ref.read(pendingShapeProvider.notifier).state = const [];

    await writePointArray(
      ref.read,
      projectId: projectId,
      guide: guide,
      plan: plan,
      // No carrier: the guide is about to stop existing, so there would be
      // nothing for one to point at.
      carrierId: null,
    );
  }

  /// Picks which object field the draw tool creates.
  ///
  /// [linesOnly] narrows the list for the array tool: a run of parallel copies
  /// only means anything for a line, and offering a polygon there would be
  /// offering something the tool then has to refuse.
  Future<void> _chooseObjectField({bool linesOnly = false}) async {
    final projectId = _projectId;
    if (projectId == null) return;

    final all = await ref
        .read(fieldDefsDaoProvider)
        .objectFieldsForProject(projectId);
    final fields = [
      for (final f in all)
        if (!linesOnly || f.drawType == DrawType.polyline) f,
    ];
    if (!mounted) return;

    if (fields.isEmpty) {
      // "Want neither, get neither" cuts both ways: with no object fields there
      // is nothing to draw, and the honest response is to say so and offer the
      // place that fixes it.
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            linesOnly ? 'Nothing line-shaped to copy' : 'Nothing to draw yet',
          ),
          content: Text(
            linesOnly
                ? 'A run of parallel copies only means anything for a line. '
                      'Create a field, mark it as something drawn, and pick '
                      'the line shape.'
                : 'Rows and blocks are not built in -- you define what this '
                      'vineyard has. Create a field, mark it as something '
                      'drawn, and pick a shape.',
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
    final opacity = ref.watch(aerialOpacityProvider);
    final pending = ref.watch(pendingShapeProvider);
    final activeField = ref.watch(activeObjectFieldProvider);
    final draft = ref.watch(reshapeDraftProvider);
    final selectedObject = ref.watch(selectedObjectProvider);
    final colouring = ref.watch(plantColouringProvider).valueOrNull;
    final showStats = ref.watch(showFrameStatsProvider);
    final fields = ref.watch(fieldDefsProvider).valueOrNull ?? const [];
    final fieldNames = {
      for (final f in fields)
        if (f.role == FieldRole.object) f.id: f.name,
    };

    // Fit the view once the layout has something in it.
    if (!_fittedOnce && !snapshot.bounds.isEmpty) {
      _fittedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _canvasKey.currentState?.fitTo(snapshot.bounds);
      });
    }

    final inspecting = selection.length == 1;
    // Side panel on a landscape tablet; bottom panel in portrait, where a
    // 384-wide column would leave a sliver of map.
    final screen = MediaQuery.sizeOf(context);
    final wide = screen.width >= 1000;
    const panelWidth = 384.0;
    final panelHeight = (screen.height * 0.42).clamp(280.0, 460.0);
    const gap = 12.0;
    // The panel's footprint, so everything on its side moves clear of it
    // rather than hiding underneath.
    final rightInset = inspecting && wide ? panelWidth + gap * 2 : gap;
    final bottomInset = inspecting && !wide ? panelHeight + gap * 2 : gap;
    const railInset = 62 + 12 + gap * 2; // rail width + padding + gaps

    final selectedDrawn = selectedObject == null
        ? null
        : snapshot.objects.where((o) => o.id == selectedObject).firstOrNull;

    final banner = _banner(tool, pending, activeField, draft);

    return Scaffold(
      backgroundColor: AppTheme.mapGround,
      body: Stack(
        children: [
          Positioned.fill(
            child: VineyardCanvas(
              key: _canvasKey,
              scene: VineyardScene(
                plants: snapshot.positions,
                index: snapshot.index,
                objects: [
                  // A vertex being dragged is shown by substituting the
                  // object, so the painter needs to know nothing about
                  // reshaping.
                  for (final object in snapshot.objects)
                    draft?.objectId == object.id
                        ? (
                            id: object.id,
                            fieldDefId: object.fieldDefId,
                            label: object.label,
                            shape: draft!.shape,
                            isContainer: object.isContainer,
                          )
                        : object,
                  // The shape being drawn, previewed live. The Space tool's
                  // guide belongs to no field, and needs drawing all the same
                  // -- it used to be invisible while tapped out, with only a
                  // counter changing.
                  ?_previewOf(
                    pending,
                    tool == CanvasTool.pointArray ? '__guide' : activeField,
                  ),
                ],
                retired: snapshot.retired,
                colors: colouring?.colors ?? const {},
                fallbackColor: colouring == null
                    ? null
                    : PlantColouring.noValue,
                image: image,
                imageOpacity: opacity,
                selection: selection,
                labels: labels,
                showLabels: showLabels,
                fieldNames: fieldNames,
                selectedObjectId: selectedObject,
                marquee: ref.watch(marqueeProvider),
                lasso: ref.watch(lassoProvider),
              ),
              tool: tool,
              onTapLayout: _onTap,
              onDragStart: _onDragStart,
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEnd,
              onDragCancel: _onDragCancel,
              onViewportChanged: (v) => _viewport = v,
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: gap,
                  left: gap,
                  right: rightInset,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: MapTopBar(
                      title:
                          ref.watch(activeProjectProvider).valueOrNull?.name ??
                          '',
                      subtitle: _summary(snapshot, fieldNames),
                      undo: const UndoControls(),
                      layersActive:
                          colouring != null || showLabels || opacity < 1,
                      onLayers: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => LayersSheet(hasImage: image != null),
                      ),
                      menu: _menu(),
                    ),
                  ),
                ),
                if (banner != null)
                  Positioned(
                    top: 76,
                    left: railInset,
                    right: rightInset,
                    child: Center(child: banner),
                  ),
                Positioned(
                  left: gap,
                  top: 76,
                  bottom: bottomInset,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ToolRail(
                      active: tool,
                      sticky: ref.watch(stickySelectProvider),
                      onToggleSticky: () => ref
                          .read(stickySelectProvider.notifier)
                          .update((v) => !v),
                      onChanged: _selectTool,
                    ),
                  ),
                ),
                if (showStats)
                  Positioned(
                    top: gap,
                    right: rightInset,
                    child: const FrameStatsOverlay(),
                  ),
                if (colouring != null)
                  Positioned(
                    left: railInset,
                    bottom: bottomInset,
                    child: MapLegend(
                      colouring: colouring,
                      onClose: () =>
                          ref.read(colorByFieldProvider.notifier).state = null,
                    ),
                  ),
                Positioned(
                  right: rightInset,
                  bottom: bottomInset,
                  child: MapControls(
                    onZoomIn: () => _canvasKey.currentState?.zoomBy(1.5),
                    onZoomOut: () => _canvasKey.currentState?.zoomBy(1 / 1.5),
                    onFit: () =>
                        _canvasKey.currentState?.fitTo(snapshot.bounds),
                  ),
                ),
                if (selection.length > 1)
                  Positioned(
                    left: railInset,
                    right: rightInset + 64,
                    bottom: gap,
                    child: Center(child: _BulkBar(selection: selection)),
                  ),
                // Only when no plants are selected. With sticky on the two can
                // coexist, and two bars in the same place is worse than one.
                if (selectedDrawn != null && selection.isEmpty)
                  Positioned(
                    left: railInset,
                    right: rightInset + 64,
                    bottom: gap,
                    child: Center(
                      child: _ObjectBar(
                        object: selectedDrawn,
                        fieldName: fieldNames[selectedDrawn.fieldDefId],
                      ),
                    ),
                  ),
                // Docked right, full height, so the selected plant stays in
                // view while its values are read or changed -- in the field
                // you are looking at the plant and the screen at once.
                if (inspecting && wide)
                  Positioned(
                    top: gap,
                    right: gap,
                    bottom: gap,
                    width: panelWidth,
                    child: PlantInspector(plantId: selection.first),
                  ),
                if (inspecting && !wide)
                  Positioned(
                    left: railInset,
                    right: gap,
                    bottom: gap,
                    height: panelHeight,
                    child: PlantInspector(plantId: selection.first),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "1,976 plants · 46 Rows · 2 Blocks" -- what this vineyard is, at a glance.
  String _summary(LayoutSnapshot snapshot, Map<String, String> fieldNames) {
    String count(int n) => groupDigits(n);

    final perField = <String, int>{};
    for (final o in snapshot.objects) {
      final name = fieldNames[o.fieldDefId];
      if (name != null) perField[name] = (perField[name] ?? 0) + 1;
    }
    final plants = snapshot.positions.length;
    return [
      '${count(plants)} ${plants == 1 ? 'plant' : 'plants'}',
      for (final e in perField.entries)
        '${count(e.value)} ${e.value == 1 ? e.key : '${e.key}s'}',
    ].join(' · ');
  }

  /// Things you set up rather than do: the fields and the ID format.
  Widget _menu() {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (choice) {
        final projectId = _projectId;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => switch (choice) {
              'fields' => const FieldListScreen(),
              'import' when projectId != null => ImportScreen(
                projectId: projectId,
              ),
              _ => const IdentifierTemplateEditor(),
            },
          ),
        );
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'fields',
          child: ListTile(
            leading: Icon(Icons.list_alt),
            title: Text('Fields'),
            subtitle: Text('What you record and draw'),
          ),
        ),
        PopupMenuItem(
          value: 'template',
          child: ListTile(
            leading: Icon(Icons.tag),
            title: Text('Plant ID format'),
            subtitle: Text('How plants are named'),
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'import',
          child: ListTile(
            leading: Icon(Icons.upload_file),
            title: Text('Import from spreadsheet'),
            subtitle: Text('Values matched by plant ID'),
          ),
        ),
      ],
    );
  }

  Future<void> _selectTool(CanvasTool t) async {
    // Abandon half-finished gesture state when switching away, rather than
    // leaving something invisible that reappears later.
    if (t != CanvasTool.drawObject &&
        t != CanvasTool.array &&
        t != CanvasTool.pointArray) {
      ref.read(pendingShapeProvider.notifier).state = const [];
    }
    if (t != CanvasTool.reshape) {
      ref.read(reshapeDraftProvider.notifier).state = null;
      _reshapingObject = null;
      _shapeBeforeReshape = null;
    }
    ref.read(activeToolProvider.notifier).state = t;
    // The point array asks in its own sheet, because Plant belongs in that
    // list and Plant is not an object field.
    if (t == CanvasTool.drawObject) {
      await _chooseObjectField();
    } else if (t == CanvasTool.array) {
      await _chooseObjectField(linesOnly: true);
    }
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

  /// What the current tool wants, or null when it explains itself.
  ///
  /// The three point-collecting tools share one banner because the gesture is
  /// identical -- tap out a shape, undo a point, press Done -- and only the
  /// wording and what Done calls differ.
  Widget? _banner(
    CanvasTool tool,
    List<ui.Offset> pending,
    String? fieldId,
    ReshapeDraft? draft,
  ) {
    switch (tool) {
      case CanvasTool.drawObject:
      case CanvasTool.array:
      case CanvasTool.pointArray:
        // Only the point array works without a chosen field: it asks in its
        // own sheet, since Plant belongs in that list and Plant is not an
        // object field.
        final needsField = tool != CanvasTool.pointArray;
        final message = needsField && fieldId == null
            ? 'Pick what you are drawing first.'
            : pending.isEmpty
            ? switch (tool) {
                CanvasTool.pointArray =>
                  'Draw a guide line for them to sit along. It is not saved.',
                CanvasTool.array => 'Draw the first line of the run.',
                _ => 'Tap to place the first point.',
              }
            : '${pending.length} placed. Add a point at each corner.';
        return MapBanner(
          icon: switch (tool) {
            CanvasTool.array => Icons.view_week_outlined,
            CanvasTool.pointArray => Icons.more_horiz,
            _ => Icons.polyline_outlined,
          },
          text: message,
          actions: [
            if (pending.isNotEmpty)
              TextButton(
                onPressed: () => ref
                    .read(pendingShapeProvider.notifier)
                    .update((p) => p.sublist(0, p.length - 1)),
                child: const Text('Undo point'),
              ),
            if (needsField && fieldId == null)
              TextButton(
                onPressed: () =>
                    _chooseObjectField(linesOnly: tool == CanvasTool.array),
                child: const Text('Choose'),
              ),
            FilledButton(
              onPressed: pending.isEmpty
                  ? null
                  : switch (tool) {
                      CanvasTool.array => _finishArray,
                      CanvasTool.pointArray => _finishPointArray,
                      _ => _finishObject,
                    },
              child: const Text('Done'),
            ),
          ],
        );
      case CanvasTool.split:
        return const MapBanner(
          icon: Icons.content_cut,
          text:
              'Tap a line where you want it cut. The near half keeps its '
              'name; you name the far half.',
        );
      case CanvasTool.reshape:
        return MapBanner(
          icon: Icons.format_shapes,
          text: draft == null
              ? 'Drag a corner to reshape. Two fingers still pan and zoom.'
              : 'Let go to place it. Anything it would rename is counted '
                    'first.',
        );
      case CanvasTool.move:
        return const MapBanner(
          icon: Icons.open_with,
          text: 'Drag a plant, or a line or area, to move it.',
        );
      case CanvasTool.placePlant:
        return const MapBanner(
          icon: Icons.add_circle_outline,
          text: 'Tap to place a plant. One press of undo takes it back.',
        );
      case CanvasTool.insertPlant:
        return const MapBanner(
          icon: Icons.playlist_add,
          text: 'Tap beside a plant on a line to insert a new one after it.',
        );
      case CanvasTool.select:
      case CanvasTool.lasso:
        return null;
    }
  }
}

/// The selected drawn object, and the way into what can be done to it.
class _ObjectBar extends ConsumerWidget {
  const _ObjectBar({required this.object, required this.fieldName});

  final DrawnObject object;
  final String? fieldName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = fieldName == null
        ? object.label
        : '$fieldName ${object.label}';
    return SelectionBar(
      leading: SelectionBadge(
        icon: switch (object.shape) {
          PolygonShape() => Icons.pentagon_outlined,
          PolylineShape() => Icons.timeline,
          PointShape() => Icons.place_outlined,
        },
        color: VineyardPainter.colourOf(object),
      ),
      title: name,
      subtitle: object.isContainer ? 'Plants belong to it' : 'Drawn on the map',
      actions: [
        FilledButton.tonalIcon(
          onPressed: () async {
            final field = await ref
                .read(fieldDefsDaoProvider)
                .byId(object.fieldDefId);
            if (field == null || !context.mounted) return;
            await showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (context) => ObjectActionsSheet(
                objectId: object.id,
                label: object.label,
                fieldName: field.name,
                isLine: object.shape is PolylineShape,
              ),
            );
          },
          icon: const Icon(Icons.tune),
          label: const Text('Actions'),
        ),
      ],
      onClose: () => ref.read(selectedObjectProvider.notifier).state = null,
    );
  }
}

/// Actions available on a multi-plant selection.
class _BulkBar extends ConsumerWidget {
  const _BulkBar({required this.selection});

  final Set<String> selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SelectionBar(
      leading: SelectionBadge(text: '${selection.length}'),
      title: 'plants selected',
      actions: [
        // The most common thing to do to a row's worth of plants, so it gets
        // its own button rather than living one sheet down.
        FilledButton.icon(
          onPressed: () => bulkSetValue(context, selection),
          icon: const Icon(Icons.edit_note),
          label: const Text('Set value'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () async {
            final action = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              builder: (context) => PlantActionsSheet(selection: selection),
            );
            if (action == PlantActionsSheet.setValue && context.mounted) {
              await bulkSetValue(context, selection);
            }
          },
          child: const Text('More'),
        ),
      ],
      onClose: () => ref.read(selectionProvider.notifier).state = const {},
    );
  }
}
