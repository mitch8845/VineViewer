import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vine_viewer/core/geometry/polyline.dart';
import 'package:vine_viewer/core/geometry/shapes.dart';
import 'package:vine_viewer/core/geometry/spatial_index.dart';
import 'package:vine_viewer/features/canvas/viewport.dart';
import 'package:vine_viewer/features/canvas/vineyard_painter.dart';

/// What one frame of painting costs, split between plants and drawn objects.
///
/// **Not a gate, and it did not settle the question it was written for.** The
/// gate is frames on the Fire Max 11 and nothing on a desktop substitutes for it.
///
/// It was written to attribute v3's frame regression (13.3ms from v2's 11.5,
/// build 8.9 from 7.8) after the first hypothesis died -- re-decoding every
/// geometry per change turned out to cost under 2ms and to happen per edit, not
/// per frame. The remaining suspect was `_paintObjects`, which v2 did not have:
/// ~100 objects painted every frame.
///
/// **The desktop numbers came out too noisy to attribute anything.** Plants plus
/// objects measured *below* plants alone, which is impossible and means variance
/// swamps the signal at this scale. So the per-object `Paint` allocation was
/// removed on the grounds that it is waste -- three allocations per object per
/// frame to draw identical lines -- and **not** on the grounds that it was the
/// regression. That remains open, and the honest next step is the on-device
/// overlay rather than more timing here.
///
/// What the file is still good for is catching an order-of-magnitude change: a
/// per-plant `TextPainter`, a lost viewport cull, a selection ring drawn for
/// every plant instead of every selected one.
void main() {
  /// Plants scattered the way the real vineyard is: 75 rows of varying length,
  /// not a grid, so the spatial index is not flattered.
  List<IndexedPoint> plants(int count) {
    final random = math.Random(42);
    final points = <IndexedPoint>[];
    var row = 0;
    while (points.length < count) {
      final inRow = math.min(9 + random.nextInt(64), count - points.length);
      final y = 100.0 + row * 45;
      for (var i = 0; i < inRow; i++) {
        points.add((
          id: 'p${points.length}',
          position: Offset(100 + i * 14, y),
        ));
      }
      row++;
    }
    return points;
  }

  /// One block polygon plus [rows] row polylines -- the shape of a real project.
  List<DrawnObject> objects(int rows) {
    return [
      (
        id: 'block',
        fieldDefId: 'block-field',
        label: '1',
        shape: PolygonShape([
          const Offset(50, 50),
          const Offset(1200, 50),
          Offset(1200, 150 + rows * 45),
          Offset(50, 150 + rows * 45),
        ]),
        isContainer: true,
      ),
      for (var r = 0; r < rows; r++)
        (
          id: 'row$r',
          fieldDefId: 'row-field',
          label: '${r + 1}',
          shape: PolylineShape(
            Polyline([
              Offset(100, 100.0 + r * 45),
              Offset(1100, 100.0 + r * 45),
            ]),
          ),
          isContainer: true,
        ),
    ];
  }

  /// Milliseconds per frame, averaged over [frames] after a warm-up frame.
  ///
  /// Painted into a real `Canvas` via `PictureRecorder`, so the Skia calls
  /// actually happen. The recorder is not rasterised -- that is the GPU's job and
  /// not what this measures -- so treat these as the *build* half of a frame.
  double timePaint(VineyardScene scene, {int frames = 30}) {
    const viewport = CanvasViewport(
      scale: 1,
      translation: Offset.zero,
      size: Rect.fromLTWH(0, 0, 1200, 2000),
    );
    final painter = VineyardPainter(scene: scene, viewport: viewport);

    void once() {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(1200, 2000));
      recorder.endRecording().dispose();
    }

    once();
    final watch = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      once();
    }
    watch.stop();
    return watch.elapsedMicroseconds / frames / 1000;
  }

  VineyardScene scene({
    List<IndexedPoint> points = const [],
    List<DrawnObject> drawn = const [],
    Set<String> selection = const {},
  }) {
    return VineyardScene(
      plants: {for (final p in points) p.id: p.position},
      index: SpatialIndex.build(points),
      objects: drawn,
      selection: selection,
    );
  }

  test('4,000 plants and nothing else', () async {
    final ms = timePaint(scene(points: plants(4000)));
    // ignore: avoid_print
    print('plants only (4,000):        ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(100));
  });

  test('76 objects and nothing else', () async {
    // The v3 addition: v2 had no generic object layer to paint.
    final ms = timePaint(scene(drawn: objects(75)));
    // ignore: avoid_print
    print('objects only (76):          ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(100));
  });

  test('both together, which is what a real frame paints', () async {
    // Has measured *below* the plants-only case on this machine, which is the
    // clearest possible sign that variance dominates and these numbers cannot
    // attribute a 1ms difference. Kept for the order-of-magnitude guard only.
    final ms = timePaint(scene(points: plants(4000), drawn: objects(75)));
    // ignore: avoid_print
    print('plants + objects:           ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(200));
  });

  test('a large selection stays per-plant but bounded', () async {
    // Selection rings are drawn one at a time, deliberately: they are bounded by
    // what a person can select, not by the size of the vineyard. A whole-block
    // selection is the worst realistic case.
    final points = plants(4000);
    final ms = timePaint(
      scene(
        points: points,
        drawn: objects(75),
        selection: {for (final p in points.take(500)) p.id},
      ),
    );
    // ignore: avoid_print
    print('with 500 selected:          ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(300));
  });

  test('zoomed out past the marker threshold, plants cost nothing', () async {
    // Below `_markerVisibleScale` individual markers stop being distinguishable
    // and are skipped entirely. Worth proving, because it is what makes a
    // whole-vineyard overview cheap.
    const wideView = CanvasViewport(
      scale: 0.1,
      translation: Offset.zero,
      size: Rect.fromLTWH(0, 0, 1200, 2000),
    );
    final painter = VineyardPainter(
      scene: scene(points: plants(4000), drawn: objects(75)),
      viewport: wideView,
    );

    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(1200, 2000));
    recorder.endRecording().dispose();

    final watch = Stopwatch()..start();
    for (var i = 0; i < 30; i++) {
      final r = ui.PictureRecorder();
      painter.paint(Canvas(r), const Size(1200, 2000));
      r.endRecording().dispose();
    }
    watch.stop();

    final ms = watch.elapsedMicroseconds / 30 / 1000;
    // ignore: avoid_print
    print('zoomed out (markers off):   ${ms.toStringAsFixed(2)}ms');
    expect(ms, lessThan(100));
  });
}
