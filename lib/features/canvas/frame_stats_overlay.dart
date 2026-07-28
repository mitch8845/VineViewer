import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// On-device frame timing readout.
///
/// Android's `dumpsys gfxinfo` reports nothing for a Flutter app -- Flutter
/// renders to its own surface and never goes through HWUI -- so the only
/// honest way to measure the 4,000-vine gate on the Fire Max 11 is to have the
/// app time itself while a real hand pans it.
///
/// Reports **build** and **raster** separately because they fail differently:
/// a slow build means the widget tree or scene assembly is too expensive, a
/// slow raster means the painting itself is. Conflating them into one "fps"
/// number hides which half to fix.
class FrameStatsOverlay extends StatefulWidget {
  const FrameStatsOverlay({super.key});

  @override
  State<FrameStatsOverlay> createState() => _FrameStatsOverlayState();
}

class _FrameStatsOverlayState extends State<FrameStatsOverlay> {
  static const _window = 120; // ~2 seconds at 60fps
  static const _budgetMs = 16.67;

  final _build = <double>[];
  final _raster = <double>[];
  int _janky = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!mounted) return;

    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000;
      final raster = t.rasterDuration.inMicroseconds / 1000;

      _build.add(build);
      _raster.add(raster);
      if (_build.length > _window) _build.removeAt(0);
      if (_raster.length > _window) _raster.removeAt(0);

      _total++;
      // Total frame time is what the user feels, so jank is judged on the sum
      // rather than on either phase alone.
      if (build + raster > _budgetMs) _janky++;
    }

    setState(() {});
  }

  double _avg(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

  double _worst(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);

  void _reset() {
    setState(() {
      _build.clear();
      _raster.clear();
      _janky = 0;
      _total = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final avgBuild = _avg(_build);
    final avgRaster = _avg(_raster);
    final avgTotal = avgBuild + avgRaster;
    final fps = avgTotal > 0 ? (1000 / avgTotal).clamp(0, 120) : 0.0;
    final jankPercent = _total == 0 ? 0.0 : _janky / _total * 100;
    final passing = avgTotal <= _budgetMs;

    return Card(
      color: (passing ? Colors.green : Colors.red).withValues(alpha: 0.92),
      child: InkWell(
        onTap: _reset,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${fps.toStringAsFixed(0)} fps   '
                  '${avgTotal.toStringAsFixed(1)}ms avg',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'build ${avgBuild.toStringAsFixed(1)}  '
                  'raster ${avgRaster.toStringAsFixed(1)}',
                ),
                Text(
                  'worst ${(_worst(_build) + _worst(_raster)).toStringAsFixed(1)}ms',
                ),
                Text(
                  'jank ${jankPercent.toStringAsFixed(0)}%  '
                  '($_janky/$_total)',
                ),
                const Text('tap to reset', style: TextStyle(fontSize: 10)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
