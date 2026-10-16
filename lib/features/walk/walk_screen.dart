import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/plant_data_service.dart';
import '../../core/db/database.dart';
import '../../core/format.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';
import '../../core/models/identifier_template.dart';
import '../../core/models/enums.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/plant_colouring.dart';
import '../canvas/viewport.dart';
import '../canvas/vineyard_painter.dart';
import 'walk_inputs.dart';
import 'walk_labels.dart';
import 'walk_session.dart';
import 'walk_setup_screen.dart';

/// Walking the vineyard: one plant at a time, entered with big buttons.
///
/// Every value is an ordinary journaled write, exactly as the plant panel
/// makes it -- the same history, change log line and undo -- so nothing about
/// a walk needs saving at the end. Leaving early loses nothing but your place,
/// and that is bookmarked after every step too.
class WalkScreen extends ConsumerStatefulWidget {
  const WalkScreen({
    super.key,
    required this.projectId,
    required this.fields,
    required this.order,
    required this.identifiers,
    this.startIndex = 0,
    this.subset,
    this.orderId,
  });

  final String projectId;
  final List<FieldDef> fields;
  final List<String> order;
  final Map<String, PlantIdentifier> identifiers;
  final int startIndex;

  /// Kept for the bookmark, so a resumed walk covers the same plants.
  final List<String>? subset;

  /// Kept for the bookmark, so a resumed walk follows the same route.
  final String? orderId;

  @override
  ConsumerState<WalkScreen> createState() => _WalkScreenState();
}

class _WalkScreenState extends ConsumerState<WalkScreen> {
  late final WalkSession _session = WalkSession(
    order: widget.order,
    fieldIds: [for (final f in widget.fields) f.id],
    index: widget.startIndex,
  );

  final Map<String, FieldConfig> _configs = {};

  FieldConfig _configOf(FieldDef f) => _configs.putIfAbsent(
    f.id,
    () => ref.read(fieldDefsDaoProvider).configOf(f),
  );

  /// "Block 1 · Row 12 · Plant 7", built from the ID format.
  List<String> _partNames = const [];

  /// Text fields: what has been typed elsewhere, most common first.
  Map<String, List<String>> _recent = const {};

  /// True while a write is in flight. A second tap in that window would land
  /// on the plant the first one is moving away from.
  bool _writing = false;

  String? _valuesFor;
  Stream<Map<String, FieldEvent>>? _values;

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  Future<void> _loadContext() async {
    final partNames = await loadPartNames(ref, widget.projectId);
    final events = ref.read(fieldEventsDaoProvider);
    final recent = <String, List<String>>{};
    for (final f in widget.fields) {
      if (f.type != FieldType.text) continue;
      final counts = <String, int>{};
      for (final e in (await events.currentValuesForField(f.id)).values) {
        final v = e.value;
        if (v != null) counts[v] = (counts[v] ?? 0) + 1;
      }
      recent[f.id] = counts.keys.toList()
        ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    }
    if (!mounted) return;
    setState(() {
      _partNames = partNames;
      _recent = recent;
    });
  }

  Stream<Map<String, FieldEvent>> _valuesOf(String plantId) {
    if (_valuesFor != plantId) {
      _valuesFor = plantId;
      _values = ref
          .read(fieldEventsDaoProvider)
          .watchCurrentValuesForPlant(plantId);
    }
    return _values!;
  }

  String _name(String plantId) => widget.identifiers[plantId]?.text ?? '?';

  Future<void> _bookmark() {
    final bookmarks = ref.read(walkBookmarksProvider);
    if (_session.finished) return bookmarks.clear(widget.projectId);
    return bookmarks.save(
      widget.projectId,
      WalkBookmark(
        fieldIds: _session.fieldIds,
        plantId: _session.current,
        index: _session.index,
        subset: widget.subset,
        orderId: widget.orderId,
      ),
    );
  }

  Future<void> _record(
    FieldDef field,
    Object? input, {
    bool force = false,
  }) async {
    final plantId = _session.current;
    if (plantId == null || (_writing && !force)) return;
    setState(() => _writing = true);
    try {
      final config = _configOf(field);
      final encoded = FieldValueCodec.encode(
        type: field.type,
        input: input,
        config: config,
      );
      final shown = encoded is FieldValueAccepted
          ? FieldValueCodec.display(
              type: field.type,
              stored: encoded.stored,
              config: config,
            )
          : null;
      // The same wording as the plant panel, so the change log cannot tell
      // a walk's entries from any other.
      final description = shown == null
          ? 'Clear ${field.name} on ${_name(plantId)}'
          : 'Set ${field.name} to $shown on ${_name(plantId)}';

      final result = await ref
          .read(operationRecorderProvider)
          .run(
            projectId: widget.projectId,
            kind: 'set_value',
            description: description,
            body: () => ref
                .read(plantDataServiceProvider)
                .setValue(
                  plantId: plantId,
                  fieldDefId: field.id,
                  input: input,
                  force: force,
                ),
          );
      if (!mounted) return;

      switch (result) {
        case WriteSucceeded():
        case WriteBulkSucceeded():
          setState(() => _session.recorded(field.id));
          await _bookmark();
        case WriteRejected(:final message):
          _say(message);
        case WriteLocked(:final existing):
          final overwrite = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('${field.name} is write-once'),
              content: Text(
                '${_name(plantId)} already has "${existing.value}". '
                'Overwrite it? The old value stays in its history.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep it'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Overwrite'),
                ),
              ],
            ),
          );
          if (overwrite == true && mounted) {
            await _record(field, input, force: true);
          }
        case WriteUnknownField():
          _say('${field.name} no longer exists.');
      }
    } finally {
      if (mounted && !force) setState(() => _writing = false);
    }
  }

  Future<void> _undo() async {
    if (_writing || !_session.canUndo) return;
    setState(() => _writing = true);
    try {
      final undone = await ref.read(undoServiceProvider).undo(widget.projectId);
      if (!mounted) return;
      setState(_session.undo);
      await _bookmark();
      if (undone != null) _say('Undone: ${undone.description}');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  void _move(void Function() step) {
    setState(step);
    _bookmark();
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );

  @override
  Widget build(BuildContext context) {
    final total = widget.order.length;
    final done = _session.index;
    final title = widget.fields.map((f) => f.name).join(', ');

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        leading: IconButton(
          tooltip: 'Exit — everything so far is saved',
          iconSize: 32,
          icon: const Icon(Icons.close),
          onPressed: () async {
            await _bookmark();
            if (context.mounted) Navigator.pop(context);
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Walking: $title', overflow: TextOverflow.ellipsis),
            Text(
              '${groupDigits(math.min(done + 1, total))} of ${groupDigits(total)}'
              ' · ${groupDigits(_session.recordedCount)} entered',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(140, 56),
                textStyle: const TextStyle(fontSize: 20),
              ),
              onPressed: _session.canUndo && !_writing ? _undo : null,
              icon: const Icon(Icons.undo, size: 28),
              label: const Text('Undo'),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: LinearProgressIndicator(
            value: total == 0 ? 1 : done / total,
            minHeight: 6,
          ),
        ),
      ),
      body: SafeArea(
        child: _session.finished ? _finished() : _walking(_session.current!),
      ),
    );
  }

  Widget _finished() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 96),
          const SizedBox(height: 16),
          Text(
            'Walk finished',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '${groupDigits(_session.recordedCount)} values entered on this walk.',
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: () => _move(_session.back),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to the last plant'),
              ),
              const SizedBox(width: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _walking(String plantId) {
    final next = _session.index + 1 < widget.order.length
        ? _name(widget.order[_session.index + 1])
        : null;

    final plantCard = _PlantHeading(
      name: _name(plantId),
      parts: _describe(plantId),
      next: next,
    );
    final inset = _WalkInset(plantId: plantId);
    final nav = Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 64)),
            onPressed: _session.index > 0 && !_writing
                ? () => _move(_session.back)
                : null,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back', style: TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 64)),
            onPressed: _writing ? null : () => _move(_session.next),
            icon: const Icon(Icons.arrow_forward),
            label: Text(
              widget.fields.length > 1 ? 'Next plant' : 'Skip',
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ],
    );

    final inputs = StreamBuilder<Map<String, FieldEvent>>(
      stream: _valuesOf(plantId),
      builder: (context, snapshot) {
        final values = snapshot.data ?? const {};
        final single = widget.fields.length == 1;
        final entries = [
          for (final f in widget.fields)
            WalkFieldInput(
              key: ValueKey('$plantId/${f.id}'),
              field: f,
              config: _configOf(f),
              current: values[f.id],
              entered: _session.enteredHere.contains(f.id),
              recent: _recent[f.id] ?? const [],
              fill: single,
              onValue: (v) => _record(f, v),
            ),
        ];
        return AbsorbPointer(
          absorbing: _writing,
          child: single
              ? entries.single
              : ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 32),
                  itemBuilder: (_, i) => entries[i],
                ),
        );
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 840 &&
            constraints.maxWidth > constraints.maxHeight;
        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 340,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      plantCard,
                      const SizedBox(height: 12),
                      Expanded(child: inset),
                      const SizedBox(height: 12),
                      nav,
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(child: inputs),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 150,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: plantCard),
                    const SizedBox(width: 12),
                    SizedBox(width: 150, child: inset),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(child: inputs),
              const SizedBox(height: 12),
              nav,
            ],
          ),
        );
      },
    );
  }

  String _describe(String plantId) {
    final parts = widget.identifiers[plantId]?.parts ?? const [];
    if (_partNames.length != parts.length) return '';
    return describeParts(parts, _partNames);
  }
}

class _PlantHeading extends StatelessWidget {
  const _PlantHeading({required this.name, required this.parts, this.next});

  final String name;
  final String parts;
  final String? next;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            name,
            style: theme.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (parts.isNotEmpty) Text(parts, style: theme.textTheme.titleMedium),
        if (next != null)
          Text(
            'Next: $next',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// A small map around the plant being entered, coloured by the first field
/// so the walk visibly fills in behind you. Tap it for the whole vineyard.
class _WalkInset extends ConsumerStatefulWidget {
  const _WalkInset({required this.plantId});

  final String plantId;

  @override
  ConsumerState<_WalkInset> createState() => _WalkInsetState();
}

class _WalkInsetState extends ConsumerState<_WalkInset> {
  bool _overview = false;

  /// How much closer than the whole vineyard the close-up is: enough to see
  /// the neighbouring rows, so you can tell which way the walk is heading.
  static const _closeUp = 5.0;

  @override
  Widget build(BuildContext context) {
    final snapshot =
        ref.watch(layoutSnapshotProvider).valueOrNull ?? LayoutSnapshot.empty;
    final colouring = ref.watch(plantColouringProvider).valueOrNull;
    final image = ref.watch(backgroundImageProvider).valueOrNull;
    final at = snapshot.positions[widget.plantId];

    return GestureDetector(
      onTap: () => setState(() => _overview = !_overview),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColoredBox(
          color: const Color(0xFF1D221E),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              final bounds = snapshot.bounds;
              if (bounds.isEmpty || at == null) return const SizedBox.expand();

              final fit =
                  math.min(
                    size.width / bounds.width,
                    size.height / bounds.height,
                  ) *
                  0.92;
              final scale = _overview ? fit : fit * _closeUp;
              final centre = _overview ? bounds.center : at;
              final viewport = CanvasViewport(
                scale: scale,
                translation: size.center(Offset.zero) - centre * scale,
                size: Offset.zero & size,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: VineyardPainter(
                      viewport: viewport,
                      scene: VineyardScene(
                        plants: snapshot.positions,
                        index: snapshot.index,
                        objects: snapshot.objects,
                        retired: snapshot.retired,
                        image: image,
                        colors: colouring?.colors ?? const {},
                        fallbackColor: colouring == null
                            ? null
                            : PlantColouring.noValue,
                        selection: {widget.plantId},
                      ),
                    ),
                  ),
                  CustomPaint(painter: _Target(viewport.toScreen(at))),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Icon(
                      _overview ? Icons.zoom_in : Icons.zoom_out_map,
                      color: Colors.white70,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A ring around the current plant, big enough to find at a glance.
class _Target extends CustomPainter {
  _Target(this.at);

  final Offset at;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      at,
      14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = Colors.black54,
    );
    canvas.drawCircle(
      at,
      14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = VineyardPainter.selectionColor,
    );
  }

  @override
  bool shouldRepaint(_Target old) => old.at != at;
}
