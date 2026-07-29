import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/geometry/spatial_index.dart';
import 'package:vine_viewer/features/canvas/viewport.dart';
import 'package:vine_viewer/features/canvas/vineyard_canvas.dart';
import 'package:vine_viewer/features/canvas/vineyard_painter.dart';

/// A drawn object of each kind, for the painter to dispatch on.
DrawnObject objectOf(String id, Shape shape, {bool container = true}) => (
  id: id,
  fieldDefId: 'field_$id',
  label: id,
  shape: shape,
  isContainer: container,
);

VineyardScene sceneWith(
  List<IndexedPoint> points, {
  List<DrawnObject> objects = const [],
  Rect? marquee,
  List<Offset> lasso = const [],
}) {
  return VineyardScene(
    vines: {for (final p in points) p.id: p.position},
    index: SpatialIndex.build(points),
    objects: objects,
    marquee: marquee,
    lasso: lasso,
  );
}

void main() {
  group('CanvasViewport', () {
    const viewport = CanvasViewport(
      scale: 2,
      translation: Offset(100, 50),
      size: Rect.fromLTWH(0, 0, 800, 600),
    );

    test('converts layout to screen and back', () {
      const layoutPoint = Offset(30, 40);
      final screen = viewport.toScreen(layoutPoint);
      expect(screen, const Offset(160, 130));
      expect(viewport.toLayout(screen), layoutPoint);
    });

    test('round-trips at any scale', () {
      // Painting and hit-testing both go through here. If they disagreed,
      // taps would land on the wrong vine only when zoomed -- the kind of bug
      // that gets blamed on "the touchscreen".
      for (final scale in [0.05, 0.5, 1.0, 3.7, 20.0]) {
        final v = CanvasViewport(
          scale: scale,
          translation: const Offset(-17, 220),
          size: const Rect.fromLTWH(0, 0, 800, 600),
        );
        const point = Offset(123.5, -45.25);
        final back = v.toLayout(v.toScreen(point));
        expect(back.dx, closeTo(point.dx, 1e-9), reason: 'scale $scale');
        expect(back.dy, closeTo(point.dy, 1e-9), reason: 'scale $scale');
      }
    });

    test('visible rect covers what is on screen', () {
      final visible = viewport.visibleLayoutRect();
      expect(visible.left, -50);
      expect(visible.top, -25);
      expect(visible.right, 350);
      expect(visible.bottom, 275);
    });

    test('padding expands the rect so markers do not pop in at the edge', () {
      final padded = viewport.visibleLayoutRect(padding: 10);
      expect(padded.left, -60);
      expect(padded.right, 360);
    });

    test('tap tolerance shrinks as you zoom in', () {
      // A finger is the same size on screen whatever the zoom. A fixed layout
      // tolerance would make individual vines unselectable when zoomed out.
      expect(viewport.screenToLayoutDistance(20), 10);

      const zoomedOut = CanvasViewport(
        scale: 0.5,
        translation: Offset.zero,
        size: Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(zoomedOut.screenToLayoutDistance(20), 40);
    });
  });

  group('painter repaint policy', () {
    final scene = sceneWith([(id: 'a', position: const Offset(10, 10))]);
    const viewport = CanvasViewport(
      scale: 1,
      translation: Offset.zero,
      size: Rect.fromLTWH(0, 0, 100, 100),
    );

    test('does not repaint when nothing changed', () {
      // Returning true unconditionally repaints on every pointer move, which
      // silently spends the whole frame budget and is invisible without a
      // profiler.
      final a = VineyardPainter(scene: scene, viewport: viewport);
      final b = VineyardPainter(scene: scene, viewport: viewport);
      expect(b.shouldRepaint(a), isFalse);
    });

    test('repaints when the viewport moves', () {
      final a = VineyardPainter(scene: scene, viewport: viewport);
      final b = VineyardPainter(
        scene: scene,
        viewport: const CanvasViewport(
          scale: 2,
          translation: Offset.zero,
          size: Rect.fromLTWH(0, 0, 100, 100),
        ),
      );
      expect(b.shouldRepaint(a), isTrue);
    });

    test('repaints when the scene changes', () {
      final a = VineyardPainter(scene: scene, viewport: viewport);
      final b = VineyardPainter(
        scene: sceneWith([(id: 'a', position: const Offset(99, 99))]),
        viewport: viewport,
      );
      expect(b.shouldRepaint(a), isTrue);
    });
  });

  group('gestures', () {
    Future<void> pumpCanvas(
      WidgetTester tester, {
      required CanvasTool tool,
      void Function(Offset)? onTap,
      void Function(Offset)? onDragStart,
      void Function(Offset)? onDragUpdate,
      void Function(Offset)? onDragEnd,
      void Function(CanvasViewport)? onViewport,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VineyardCanvas(
              scene: sceneWith([(id: 'a', position: const Offset(50, 50))]),
              tool: tool,
              onTapLayout: onTap,
              onDragStart: onDragStart,
              onDragUpdate: onDragUpdate,
              onDragEnd: onDragEnd,
              onViewportChanged: onViewport,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a tap reports layout coordinates', (tester) async {
      Offset? tapped;
      await pumpCanvas(
        tester,
        tool: CanvasTool.placePlant,
        onTap: (p) => tapped = p,
      );

      await tester.tapAt(const Offset(120, 200));
      await tester.pump();

      // Identity viewport at start, so layout equals screen.
      expect(tapped, const Offset(120, 200));
    });

    testWidgets('one pointer drives the tool, not the camera', (tester) async {
      final updates = <Offset>[];
      CanvasViewport? lastViewport;
      await pumpCanvas(
        tester,
        tool: CanvasTool.select,
        onDragStart: updates.add,
        onDragUpdate: updates.add,
        onViewport: (v) => lastViewport = v,
      );
      final before = lastViewport;

      await tester.dragFrom(const Offset(100, 100), const Offset(60, 40));
      await tester.pumpAndSettle();

      expect(updates, isNotEmpty, reason: 'the tool should receive the drag');
      // The camera must not have moved: a one-finger drag with a tool active
      // belongs to the tool.
      expect(lastViewport?.translation, before?.translation);
    });

    testWidgets('two pointers pan regardless of the active tool', (
      tester,
    ) async {
      // The escape hatch: you can always navigate without putting the tool
      // away, which matters because laying out a vineyard is mostly navigating.
      CanvasViewport? viewport;
      await pumpCanvas(
        tester,
        tool: CanvasTool.placePlant,
        onViewport: (v) => viewport = v,
      );
      final before = viewport!.translation;

      final a = await tester.startGesture(const Offset(200, 200));
      final b = await tester.startGesture(const Offset(300, 200));
      await tester.pump();
      await a.moveBy(const Offset(50, 30));
      await b.moveBy(const Offset(50, 30));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();

      expect(viewport!.translation, isNot(before));
    });

    testWidgets('a second finger takes over mid-drag without a jump', (
      tester,
    ) async {
      // Starting a marquee then pinching must not have both fighting for the
      // same gesture.
      var dragEnded = false;
      await pumpCanvas(
        tester,
        tool: CanvasTool.select,
        onDragEnd: (_) => dragEnded = true,
      );

      final a = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      await a.moveBy(const Offset(20, 20));
      await tester.pump();

      final b = await tester.startGesture(const Offset(320, 200));
      await tester.pump();
      await a.moveBy(const Offset(30, 0));
      await b.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(dragEnded, isTrue, reason: 'the tool drag should be handed off');

      await a.up();
      await b.up();
      await tester.pumpAndSettle();
    });

    testWidgets('renders a large layout without throwing', (tester) async {
      // 3,000 vines through the real painter, as a smoke test that culling and
      // the paint path hold together at scale.
      final points = [
        for (var i = 0; i < 3000; i++)
          (
            id: 'v$i',
            position: Offset(100.0 + (i % 60) * 12, 100.0 + (i ~/ 60) * 40),
          ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VineyardCanvas(
              scene: sceneWith(points),
              tool: CanvasTool.select,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints all three kinds of object without throwing', (
      tester,
    ) async {
      // The painter dispatches on draw type, so each branch needs exercising:
      // a line, a filled area, and a point drawn as a diamond.
      final objects = [
        objectOf(
          'row',
          PolylineShape(Polyline([const Offset(0, 0), const Offset(400, 0)])),
        ),
        objectOf(
          'block',
          PolygonShape([
            const Offset(0, 0),
            const Offset(400, 0),
            const Offset(400, 400),
            const Offset(0, 400),
          ]),
        ),
        objectOf('post', const PointShape(Offset(200, 200)), container: false),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VineyardCanvas(
              scene: sceneWith(
                [(id: 'a', position: const Offset(100, 0))],
                objects: objects,
                // The transient gesture overlays paint last, over everything.
                marquee: const Rect.fromLTRB(10, 10, 90, 90),
                lasso: const [Offset(0, 0), Offset(50, 20), Offset(80, 70)],
              ),
              tool: CanvasTool.select,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
