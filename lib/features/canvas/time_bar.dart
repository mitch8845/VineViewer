import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import 'canvas_controller.dart';
import 'map_chrome.dart';

/// Steps the map through time: the colour-by field as it stood at the end
/// of each day something was recorded, up to now.
///
/// The stops are those days and nothing else -- between them nothing about
/// the field changed, so a continuous slider would mostly move without
/// anything happening. Play steps through them on its own, to watch a
/// field change across a season.
class TimeBar extends ConsumerStatefulWidget {
  const TimeBar({super.key, required this.fieldName});

  final String fieldName;

  @override
  ConsumerState<TimeBar> createState() => _TimeBarState();
}

class _TimeBarState extends ConsumerState<TimeBar> {
  Timer? _playing;

  static const _playStep = Duration(milliseconds: 900);

  @override
  void dispose() {
    _playing?.cancel();
    super.dispose();
  }

  /// Stop [i] of [days]; one past the last is now.
  void _goTo(List<DateTime> days, int i) {
    ref.read(asOfDayProvider.notifier).state = i >= days.length
        ? null
        : days[i.clamp(0, days.length - 1)];
  }

  int _position(List<DateTime> days, DateTime? asOf) {
    if (asOf == null) return days.length;
    // The last stop on or before the day shown.
    var at = 0;
    for (var i = 0; i < days.length; i++) {
      if (!days[i].isAfter(asOf)) at = i;
    }
    return at;
  }

  void _togglePlay(List<DateTime> days) {
    if (_playing != null) {
      setState(() {
        _playing!.cancel();
        _playing = null;
      });
      return;
    }
    if (days.isEmpty) return;
    // From the start if already at now: there is nothing after it to play.
    if (ref.read(asOfDayProvider) == null) _goTo(days, 0);
    setState(() {
      _playing = Timer.periodic(_playStep, (_) {
        final days = ref.read(colourDaysProvider).valueOrNull ?? const [];
        final next = _position(days, ref.read(asOfDayProvider)) + 1;
        _goTo(days, next);
        if (next >= days.length) {
          _playing?.cancel();
          if (mounted) setState(() => _playing = null);
        }
      });
    });
  }

  void _close() {
    _playing?.cancel();
    ref.read(asOfDayProvider.notifier).state = null;
    ref.read(timeSliderProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = ref.watch(colourDaysProvider).valueOrNull ?? const [];
    final asOf = ref.watch(asOfDayProvider);
    final at = _position(days, asOf);
    final past = asOf != null;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: MapSurface(
        color: past ? scheme.tertiaryContainer : null,
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        child: Row(
          children: [
            IconButton(
              tooltip: _playing == null ? 'Play' : 'Pause',
              icon: Icon(_playing == null ? Icons.play_arrow : Icons.pause),
              onPressed: days.isEmpty ? null : () => _togglePlay(days),
            ),
            IconButton(
              tooltip: 'Earlier',
              icon: const Icon(Icons.chevron_left),
              onPressed: at > 0 ? () => _goTo(days, at - 1) : null,
            ),
            SizedBox(
              width: 132,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    past ? isoDate(asOf) : 'Now',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    past ? '${widget.fieldName} as it was' : widget.fieldName,
                    style: theme.textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Later',
              icon: const Icon(Icons.chevron_right),
              onPressed: at < days.length ? () => _goTo(days, at + 1) : null,
            ),
            Expanded(
              child: days.isEmpty
                  ? Text(
                      'Nothing recorded for ${widget.fieldName} yet.',
                      style: theme.textTheme.bodySmall,
                    )
                  : Slider(
                      value: at.toDouble(),
                      max: days.length.toDouble(),
                      divisions: days.length,
                      label: at >= days.length ? 'Now' : isoDate(days[at]),
                      onChanged: (v) => _goTo(days, v.round()),
                    ),
            ),
            if (days.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${groupDigits(at >= days.length ? days.length : at + 1)}'
                  ' / ${groupDigits(days.length)}',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            IconButton(
              tooltip: 'Back to now',
              icon: const Icon(Icons.close),
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }
}
