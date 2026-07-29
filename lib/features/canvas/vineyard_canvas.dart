import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'viewport.dart';
import 'vineyard_painter.dart';

/// What a single pointer does, decided by the active tool.
enum CanvasTool {
  /// Tap selects one plant or an object; drag marquee-selects.
  select,

  /// Drag encloses plants in a freehand loop.
  lasso,

  /// Tap places a free-standing plant.
  placePlant,

  /// Tap inserts a plant into the nearest line, between its neighbours.
  ///
  /// Distinct from [placePlant] because it renumbers: the app has to ask
  /// whether to shift every number downstream or reuse a gap, and that question
  /// only makes sense for a plant going *into* an existing sequence.
  insertPlant,

  /// Tap adds a point to the object being drawn.
  ///
  /// Which kind of object comes from `activeObjectFieldProvider`, not from the
  /// tool: rows, blocks and roads are all drawn the same way and differ only in
  /// what field they instantiate.
  drawObject,

  /// Drag moves the plant or object under the pointer.
  move,

  /// Drag moves one *corner* of an object, leaving the rest where it is.
  ///
  /// Distinct from [move], which translates the whole shape. Both exist because
  /// they are the two different things you do to a boundary that is wrong:
  /// it is in the wrong place, or it is the wrong shape.
  reshape,
}

/// The interactive map.
///
/// Gesture model, per the interaction decisions:
///
/// * **One pointer** -- finger, stylus, or mouse -- does whatever the active
///   tool says.
/// * **Two pointers always pan and zoom**, whatever the tool. There is always
///   a way to navigate without first putting a tool away, which matters when
///   laying out a vineyard is mostly navigating.
/// * **Stylus and finger behave identically.** The app has to be fully usable
///   without the pen, so the pen is precision, never a requirement.
///
/// The transform is held here rather than delegated to `InteractiveViewer`,
/// which would consume single-pointer drags that the tools need. Owning it
/// also means the painter and hit-testing share one [CanvasViewport] and
/// cannot disagree about where things are.
class VineyardCanvas extends StatefulWidget {
  const VineyardCanvas({
    super.key,
    required this.scene,
    required this.tool,
    this.onTapLayout,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onViewportChanged,
    this.minScale = 0.05,
    this.maxScale = 20,
  });

  final VineyardScene scene;
  final CanvasTool tool;

  /// A single-pointer tap, in layout coordinates.
  final void Function(Offset layoutPoint)? onTapLayout;

  /// Single-pointer drag, in layout coordinates.
  final void Function(Offset layoutPoint)? onDragStart;
  final void Function(Offset layoutPoint)? onDragUpdate;
  final void Function(Offset layoutPoint)? onDragEnd;

  final void Function(CanvasViewport)? onViewportChanged;

  final double minScale;
  final double maxScale;

  @override
  State<VineyardCanvas> createState() => VineyardCanvasState();
}

class VineyardCanvasState extends State<VineyardCanvas> {
  double _scale = 1;
  Offset _translation = Offset.zero;
  Size _size = Size.zero;

  // Gesture bookkeeping.
  double _scaleAtGestureStart = 1;
  Offset _translationAtGestureStart = Offset.zero;
  Offset _focalAtGestureStart = Offset.zero;
  bool _draggingWithTool = false;

  CanvasViewport get viewport => CanvasViewport(
    scale: _scale,
    translation: _translation,
    size: Offset.zero & _size,
  );

  /// Centres the view on a layout rectangle, e.g. after loading a project.
  void fitTo(Rect layoutBounds, {double padding = 40}) {
    if (_size.isEmpty || layoutBounds.isEmpty) return;

    final scaleX = (_size.width - padding * 2) / layoutBounds.width;
    final scaleY = (_size.height - padding * 2) / layoutBounds.height;
    final scale = scaleX
        .clamp(widget.minScale, widget.maxScale)
        .clamp(widget.minScale, scaleY.clamp(widget.minScale, widget.maxScale));

    setState(() {
      _scale = scale;
      _translation =
          Offset(_size.width / 2, _size.height / 2) -
          layoutBounds.center * scale;
    });
    widget.onViewportChanged?.call(viewport);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _scaleAtGestureStart = _scale;
    _translationAtGestureStart = _translation;
    _focalAtGestureStart = details.localFocalPoint;

    // One pointer always belongs to the tool -- including select, where the
    // drag is a marquee. Two or more is navigation, handled in the update.
    _draggingWithTool = details.pointerCount == 1;
    if (_draggingWithTool) {
      widget.onDragStart?.call(viewport.toLayout(details.localFocalPoint));
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // A second finger arriving always takes over as navigation, even mid-drag.
    // Without this, starting a marquee and then pinching would fight itself.
    if (details.pointerCount >= 2) {
      if (_draggingWithTool) {
        _draggingWithTool = false;
        widget.onDragEnd?.call(viewport.toLayout(details.localFocalPoint));
        // Rebase so the view does not jump when navigation takes over.
        _scaleAtGestureStart = _scale;
        _translationAtGestureStart = _translation;
        _focalAtGestureStart = details.localFocalPoint;
      }
      _applyNavigation(details);
      return;
    }

    if (_draggingWithTool) {
      widget.onDragUpdate?.call(viewport.toLayout(details.localFocalPoint));
    }
  }

  void _applyNavigation(ScaleUpdateDetails details) {
    final newScale = (_scaleAtGestureStart * details.scale).clamp(
      widget.minScale,
      widget.maxScale,
    );

    // Keep the point under the fingers fixed while zooming; anything else
    // feels like the map sliding away from you.
    final focalLayout =
        (_focalAtGestureStart - _translationAtGestureStart) /
        _scaleAtGestureStart;

    setState(() {
      _scale = newScale;
      _translation = details.localFocalPoint - focalLayout * newScale;
    });
    widget.onViewportChanged?.call(viewport);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_draggingWithTool) {
      _draggingWithTool = false;
      widget.onDragEnd?.call(viewport.toLayout(_focalAtGestureStart));
    }
  }

  void _onTapUp(TapUpDetails details) {
    widget.onTapLayout?.call(viewport.toLayout(details.localPosition));
  }

  /// Desktop scroll-wheel zoom, anchored under the cursor.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    final newScale = (_scale * (event.scrollDelta.dy > 0 ? 0.9 : 1.1)).clamp(
      widget.minScale,
      widget.maxScale,
    );
    final focalLayout = (event.localPosition - _translation) / _scale;

    setState(() {
      _scale = newScale;
      _translation = event.localPosition - focalLayout * newScale;
    });
    widget.onViewportChanged?.call(viewport);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size) {
          _size = size;
          // After the frame, so the parent is not rebuilt mid-layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onViewportChanged?.call(viewport);
          });
        }

        return Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: CustomPaint(
              size: size,
              isComplex: true,
              willChange: true,
              painter: VineyardPainter(scene: widget.scene, viewport: viewport),
            ),
          ),
        );
      },
    );
  }
}
