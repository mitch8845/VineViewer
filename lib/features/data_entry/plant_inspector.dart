import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/label_service.dart';
import '../../core/data/plant_data_service.dart';
import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/models/field_value.dart';
import '../../core/models/identifier_template.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/tools/identifier_change_prompt.dart';
import '../canvas/tools/plant_actions_sheet.dart';
import 'bulk_edit.dart';
import '../schema/field_editor_screen.dart';
import 'value_editor_sheet.dart';
import '../canvas/map_chrome.dart';

/// Panel for the selected plant: its address and every field, editable.
///
/// Docked at the side of the map rather than replacing it, so the plant stays
/// visible while its values are being read or changed -- in the field you are
/// looking at the plant and the screen at the same time.
class PlantInspector extends ConsumerWidget {
  const PlantInspector({super.key, required this.plantId});

  final String plantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Attributes only. A container's value is derived from geometry and shown
    // as a chip; a non-container object has nothing to do with plants. Listing
    // Row here offered an edit that wrote an event nothing reads.
    final fields = [
      for (final f in ref.watch(fieldDefsProvider).valueOrNull ?? const [])
        if (f.role == FieldRole.attribute) f,
    ];
    final identifier = ref.watch(_identifierProvider(plantId)).valueOrNull;
    final holders =
        ref.watch(_holdersProvider(plantId)).valueOrNull ?? const [];
    final values = ref.watch(_valuesProvider(plantId)).valueOrNull ?? const {};
    final plant = ref.watch(_plantProvider(plantId)).valueOrNull;
    final retired = plant != null && plant.status != PlantStatus.active;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return MapPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PLANT',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        identifier?.text ?? '...',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'History',
                  icon: const Icon(Icons.history),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => _HistorySheet(plantId: plantId),
                  ),
                ),
                // Retire and replace live in the plant actions sheet, which
                // was only reachable from the multi-plant bar -- so the one
                // case "Replace with a new plant" exists for, a single plant,
                // could never get to it.
                IconButton(
                  tooltip: 'Actions',
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () async {
                    final action = await showModalBottomSheet<String>(
                      context: context,
                      isScrollControlled: true,
                      builder: (context) => PlantActionsSheet(
                        selection: {plantId},
                        retired: retired,
                      ),
                    );
                    if (action == PlantActionsSheet.setValue &&
                        context.mounted) {
                      await bulkSetValue(context, {plantId});
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      ref.read(selectionProvider.notifier).state = const {},
                ),
              ],
            ),
          ),
          // Container values are worked out from where the plant sits, so
          // they are not edited here: the way to change one is to move the
          // plant or the boundary. Tapping one selects everything in it --
          // the quickest way to a whole row, since a row's own line is
          // mostly hidden under its plants.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                // Said first and plainly: a slot looks like a plant in this
                // panel otherwise, and recording a reading against the dead
                // one is an easy mistake.
                if (retired)
                  _Tag(
                    icon: Icons.remove_circle_outline,
                    text:
                        'Removed${plant.endedAt == null ? '' : ' ${_LabelHistorySheet._date(plant.endedAt!)}'}',
                    background: scheme.errorContainer,
                    foreground: scheme.onErrorContainer,
                  ),
                if (holders.isEmpty)
                  _Tag(
                    text: 'Not inside anything',
                    background: scheme.surfaceContainerHighest,
                    foreground: scheme.onSurfaceVariant,
                  )
                else
                  for (final h in holders)
                    _Tag(
                      icon: Icons.select_all,
                      text: '${h.field} ${h.label}',
                      tooltip: 'Select every plant in ${h.field} ${h.label}',
                      background: scheme.secondaryContainer,
                      foreground: scheme.onSecondaryContainer,
                      onTap: () => selectPlantsOf(ref, h.objectId),
                    ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: fields.isEmpty
                ? _NoFields()
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: fields.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    itemBuilder: (context, i) {
                      final field = fields[i];
                      return _FieldRow(
                        plantId: plantId,
                        field: field,
                        event: values[field.id],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.text,
    required this.background,
    required this.foreground,
    this.icon,
    this.onTap,
    this.tooltip,
  });

  final String text;
  final Color background;
  final Color foreground;
  final IconData? icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: foreground),
          ),
        ],
      ),
    );
    if (onTap == null) return tag;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: tag,
        ),
      ),
    );
  }
}

class _NoFields extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.edit_note,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            'No fields defined yet. Add one to start recording observations '
            'about this plant.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FieldListScreen()),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add a field'),
          ),
        ],
      ),
    );
  }
}

/// The plant row itself, for its lifecycle status.
final _plantProvider = FutureProvider.autoDispose.family<Plant?, String>((
  ref,
  plantId,
) async {
  ref.watch(identityRevisionProvider);
  return ref.watch(layoutDaoProvider).plantById(plantId);
});

final _identifierProvider = FutureProvider.autoDispose
    .family<PlantIdentifier?, String>((ref, plantId) async {
      // Depends on the layout so a snap, a renumber, or a boundary edit that
      // changes containment all refresh what is shown.
      ref.watch(identityRevisionProvider);
      return ref.watch(labelServiceProvider).identifierOf(plantId);
    });

/// The objects holding this plant, with ids, so a chip can select them.
final _holdersProvider = FutureProvider.autoDispose
    .family<List<({String objectId, String field, String label})>, String>((
      ref,
      plantId,
    ) async {
      ref.watch(identityRevisionProvider);
      return ref.watch(labelServiceProvider).holdersOf(plantId);
    });

/// The plant's current values, live.
///
/// A watched query rather than a one-shot read plus a refresh counter. Undo
/// writes to the event log directly, so anything that refreshed on the
/// inspector's own bookkeeping would sit there showing a value that had already
/// been reverted.
///
/// Auto-disposed: a family that never let go kept one live query running for
/// every plant inspected in the session, all of them re-run on every write.
final _valuesProvider = StreamProvider.autoDispose
    .family<Map<String, FieldEvent>, String>((ref, plantId) {
      return ref
          .watch(fieldEventsDaoProvider)
          .watchCurrentValuesForPlant(plantId);
    });

final _historyProvider = FutureProvider.autoDispose
    .family<List<IdentifierChangeRecord>, String>((ref, plantId) async {
      ref.watch(identityRevisionProvider);
      return ref.watch(labelServiceProvider).historyOf(plantId);
    });

/// Every label this plant has carried.
///
/// The point is reconciling paper: a 2025 notebook saying "3.12.7 looks weak"
/// is guesswork once numbers have been reused or shifted, and this is what
/// turns it back into a fact.
/// Every value this plant has had, newest first.
final _valueHistoryProvider = FutureProvider.autoDispose
    .family<List<FieldEvent>, String>((ref, plantId) async {
      ref.watch(identityRevisionProvider);
      return ref.watch(fieldEventsDaoProvider).historyForPlant(plantId);
    });

/// A plant's history: its readings, and the IDs it has carried.
///
/// The readings are the point of keeping an event log at all -- "was this
/// vine weaker last year?" -- and until now the only way to see one was the
/// current value. Every reading is here, with the day it was true and how it
/// got in.
class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.plantId});
  final String plantId;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  bool _values = true;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.edit_note),
                    label: Text('Values'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.tag),
                    label: Text('IDs'),
                  ),
                ],
                selected: {_values},
                onSelectionChanged: (s) => setState(() => _values = s.first),
              ),
            ),
            Flexible(
              child: _values
                  ? _ValueHistory(plantId: widget.plantId)
                  : SingleChildScrollView(
                      child: _LabelHistorySheet(plantId: widget.plantId),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueHistory extends ConsumerWidget {
  const _ValueHistory({required this.plantId});
  final String plantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = MaterialLocalizations.of(context);
    final dao = ref.read(fieldDefsDaoProvider);
    final fields = {
      for (final f in ref.watch(fieldDefsProvider).valueOrNull ?? <FieldDef>[])
        f.id: f,
    };
    final events = ref.watch(_valueHistoryProvider(plantId));

    return events.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) =>
          Padding(padding: const EdgeInsets.all(20), child: Text('$e')),
      data: (list) {
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Text(
              'Nothing has been recorded for this plant yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          );
        }
        // Grouped by day, newest first: a season reads as a timeline.
        final days = <DateTime, List<FieldEvent>>{};
        for (final e in list) {
          final t = e.observedAt.toLocal();
          (days[DateTime(t.year, t.month, t.day)] ??= []).add(e);
        }
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            for (final day in days.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(
                  l10n.formatMediumDate(day.key),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final e in day.value)
                if (fields[e.fieldDefId] case final field?)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          switch (e.source) {
                            EventSource.import => Icons.upload_file,
                            EventSource.bulk => Icons.select_all,
                            EventSource.manual => Icons.touch_app_outlined,
                          },
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 110,
                          child: Text(
                            field.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            FieldValueCodec.display(
                                  type: field.type,
                                  stored: e.value,
                                  config: dao.configOf(field),
                                ) ??
                                'cleared',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: e.value == null
                                  ? FontWeight.normal
                                  : FontWeight.w600,
                              fontStyle: e.value == null
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ],
        );
      },
    );
  }
}

class _LabelHistorySheet extends ConsumerWidget {
  const _LabelHistorySheet({required this.plantId});

  final String plantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider(plantId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: history.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Text('$e'),
          data: (changes) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ID history', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final change in changes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    change == changes.last
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  title: Text(
                    change.identifier.text,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    change.at == null
                        // Honest about the limit: the journal records what
                        // changed a label, never when it was first given.
                        ? 'as far back as the record goes'
                        : '${_date(change.at!)}'
                              '${change.reason == null ? '' : ' -- ${change.reason}'}',
                  ),
                ),
              if (changes.length == 1)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'This plant has never been renamed.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _date(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}

class _FieldRow extends ConsumerWidget {
  const _FieldRow({
    required this.plantId,
    required this.field,
    required this.event,
  });

  final String plantId;
  final FieldDef field;
  final FieldEvent? event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.read(fieldDefsDaoProvider).configOf(field);
    final current = event?.value;
    final display = FieldValueCodec.display(
      type: field.type,
      stored: current,
      config: config,
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locked = field.isStatic && current != null;

    final swatch = config.optionColors[current];
    final colour = swatch == null ? null : _parseHex(swatch);

    final quick = _quickChoices(config);

    return InkWell(
      // The full editor is always one tap away, quick buttons or not: it is
      // where Clear lives, and where anything off the quick list is entered.
      onTap: () => _edit(context, ref, config),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    field.name,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (locked)
                  // Signals write-once before the user taps and gets refused.
                  Tooltip(
                    message: 'Write-once',
                    child: Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (quick == null)
              Row(
                children: [
                  if (colour != null) ...[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: colour,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      display ?? 'Not recorded',
                      style: display == null
                          ? theme.textTheme.bodyLarge?.copyWith(
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.7,
                              ),
                              fontStyle: FontStyle.italic,
                            )
                          : theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final choice in quick)
                      _QuickChoice(
                        label: choice.label,
                        colour: choice.colour,
                        selected: choice.stored == current,
                        onTap: choice.stored == current
                            ? null
                            : () => _commit(context, ref, choice.input),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One-tap answers for fields whose whole range fits on screen.
  ///
  /// A health survey is tap the plant, tap a score, next plant. Going through
  /// a sheet for every one of three thousand plants is two taps and a slide
  /// animation each, which is the difference between a morning and a day.
  /// Null for fields that need the full editor.
  List<({String label, String stored, Object input, Color? colour})>?
  _quickChoices(FieldConfig config) {
    switch (field.type) {
      case FieldType.rating:
        final lo = config.effectiveScaleMin;
        final hi = config.effectiveScaleMax;
        if (hi - lo > 9) return null;
        return [
          for (var v = lo; v <= hi; v++)
            (label: '$v', stored: '$v', input: v, colour: null),
        ];
      case FieldType.boolean:
        return [
          (
            label: config.trueLabel ?? 'Yes',
            stored: '1',
            input: true,
            colour: null,
          ),
          (
            label: config.falseLabel ?? 'No',
            stored: '0',
            input: false,
            colour: null,
          ),
        ];
      case FieldType.categorical:
        if (config.options.isEmpty || config.options.length > 6) return null;
        return [
          for (final o in config.options)
            (
              label: o,
              stored: o,
              input: o,
              colour: _parseHex(config.optionColors[o] ?? ''),
            ),
        ];
      case FieldType.text:
      case FieldType.integer:
      case FieldType.decimal:
      case FieldType.date:
      case FieldType.datetime:
      case FieldType.multiSelect:
        return null;
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    FieldConfig config,
  ) async {
    final edit = await showValueEditor(
      context,
      field: field,
      config: config,
      current: event?.value,
      offerClear: event?.value != null,
    );
    // Null is a dismissal -- Cancel, a swipe, a tap outside. A deliberate
    // clear comes back as an edit holding null.
    if (edit == null || !context.mounted) return;
    await _commit(context, ref, edit.value);
  }

  /// Gates and writes one value -- the single path for both the full editor
  /// and the quick buttons, so neither can skip the identifier check or the
  /// write-once lock.
  Future<void> _commit(
    BuildContext context,
    WidgetRef ref,
    Object? resolved,
  ) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    // Gated here rather than inside [_write], which retries itself with
    // `force: true` after a write-once override. Gating there would ask the same
    // question twice for one decision.
    final cleared = await _clearedIdentifierGate(
      context,
      ref,
      projectId,
      resolved,
    );
    if (!cleared || !context.mounted) return;

    await _write(context, ref, resolved);
  }

  /// The gate for a field that is part of the plant's identifier.
  ///
  /// Returns true to go ahead. For the overwhelming majority of fields this
  /// costs one cheap query and returns true immediately -- health scores are not
  /// addresses. But when Clone *is* part of the ID, correcting a clone
  /// readdresses the plant, and until now it did so in silence.
  ///
  /// Two separate checks, because they fail for different reasons:
  ///
  ///  * The value itself may be unusable as an ID part -- containing the
  ///    delimiter, or equal to the placeholder that means "no value here". A
  ///    clone genuinely called `none` would make `12.none.7` ambiguous between a
  ///    real clone and a missing one.
  ///  * The resulting identifiers may collide, which is refused outright.
  Future<bool> _clearedIdentifierGate(
    BuildContext context,
    WidgetRef ref,
    String projectId,
    Object? value,
  ) async {
    final labels = ref.read(labelServiceProvider);
    if (!await labels.isIdentifierPart(
      projectId: projectId,
      fieldDefId: field.id,
    )) {
      return true;
    }

    final template = await labels.templateFor(projectId);
    final text = value?.toString();
    if (text != null) {
      final problem = LabelService.problemWithIdentifierValue(
        value: text,
        delimiter: template.delimiter,
        blankPlaceholder: field.blankPlaceholder,
      );
      if (problem != null) {
        if (!context.mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${field.name} is part of the plant ID. $problem'),
          ),
        );
        return false;
      }
    }

    final change = await labels.previewAttributeChange(
      projectId: projectId,
      fieldDefId: field.id,
      plantIds: [plantId],
      value: text,
    );
    if (!context.mounted) return false;

    return confirmIdentifierChange(
      context,
      change: change,
      action: 'Change ${field.name}',
      proceedLabel: 'Change it',
      refusalAdvice:
          '${field.name} is part of the plant ID. Pick a different value, or '
          'add a part to the ID format that tells these plants apart.',
    );
  }

  Future<void> _write(
    BuildContext context,
    WidgetRef ref,
    Object? value, {
    bool force = false,
  }) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    // One press of undo puts the old value back, and because undo replays the
    // journal rather than appending a correction, the mistaken entry does not
    // linger in this plant's history.
    final result = await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'set_value',
          description: 'Set ${field.name}',
          body: () => ref
              .read(plantDataServiceProvider)
              .setValue(
                plantId: plantId,
                fieldDefId: field.id,
                input: value,
                force: force,
              ),
        );

    if (!context.mounted) return;

    switch (result) {
      case WriteSucceeded():
      case WriteBulkSucceeded():
        // Nothing to do: the values are a watched query, so the write that just
        // landed refreshes the panel on its own.
        break;

      case WriteRejected(:final message):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));

      case WriteLocked(:final message, :final existing):
        // The lock stops a stray tap clobbering a plant date; it is not meant
        // to make a typo permanent, so the override is offered right here.
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Write-once field'),
            content: Text(
              '$message\n\nOverwrite it? The previous value stays in this '
              "plant's history.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Keep "${existing.value}"'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Overwrite'),
              ),
            ],
          ),
        );
        if (overwrite == true && context.mounted) {
          await _write(context, ref, value, force: true);
        }

      case WriteUnknownField():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That field no longer exists.')),
        );
    }
  }
}

Color? _parseHex(String hex) {
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// One quick-entry answer: big enough to hit with a gloved thumb.
class _QuickChoice extends StatelessWidget {
  const _QuickChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.colour,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final short = label.length <= 2;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide.none
            : BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: short ? 48 : 64, minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (colour != null) ...[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colour,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? scheme.onPrimary : Colors.transparent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: short ? 17 : 14,
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
