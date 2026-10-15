import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/format.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_value.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';

// ------------------------------------------------------------------ data

/// What a calendar day holds.
class DayMarks {
  /// Observations recorded that day.
  int recorded = 0;

  /// Plants whose date fields hold this day -- a planting date, or a date
  /// set in the future, which is how the calendar shows what is coming up.
  int dated = 0;
}

typedef _MonthKey = ({String projectId, DateTime month, String? fieldId});
typedef _DayKey = ({String projectId, DateTime day, String? fieldId});

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

bool _isDateField(FieldDef f) =>
    f.role == FieldRole.attribute &&
    (f.type == FieldType.date || f.type == FieldType.datetime);

/// The local day a stored date-field value names, or null if unreadable.
DateTime? _storedDay(FieldDef field, String? stored) {
  if (stored == null) return null;
  final parsed = DateTime.tryParse(stored);
  if (parsed == null) return null;
  // A `date` is a calendar date written as such; a `datetime` is a UTC
  // instant, which falls on whatever local day it lands on here.
  return field.type == FieldType.date
      ? _dayOf(parsed)
      : _dayOf(parsed.toLocal());
}

final _monthProvider = FutureProvider.autoDispose
    .family<Map<DateTime, DayMarks>, _MonthKey>((ref, key) async {
      ref.watch(identityRevisionProvider);
      final events = ref.watch(fieldEventsDaoProvider);
      final fields = await ref
          .watch(fieldDefsDaoProvider)
          .forProject(key.projectId);
      final start = key.month;
      final end = DateTime(start.year, start.month + 1);

      final marks = <DateTime, DayMarks>{};
      for (final a in await events.activityBetween(key.projectId, start, end)) {
        if (key.fieldId != null && a.fieldDefId != key.fieldId) continue;
        (marks[a.day] ??= DayMarks()).recorded += a.count;
      }
      for (final field in fields.where(_isDateField)) {
        if (key.fieldId != null && field.id != key.fieldId) continue;
        final current = await events.currentValuesForField(field.id);
        for (final e in current.values) {
          final day = _storedDay(field, e.value);
          if (day == null || day.isBefore(start) || !day.isBefore(end)) {
            continue;
          }
          (marks[day] ??= DayMarks()).dated++;
        }
      }
      return marks;
    });

/// One field's activity on one day: which values, on which plants.
class _Recorded {
  _Recorded(this.field);
  final FieldDef field;

  /// Display value (null for a clear) to the plants that got it.
  final byValue = <String?, Set<String>>{};
  final sources = <EventSource>{};

  int get count => byValue.values.fold(0, (n, s) => n + s.length);
  Set<String> get plants => {for (final s in byValue.values) ...s};
}

class _DayDetail {
  const _DayDetail({required this.recorded, required this.dated});
  final List<_Recorded> recorded;

  /// Date fields holding this day, with the plants holding it.
  final List<({FieldDef field, Set<String> plants})> dated;

  bool get isEmpty => recorded.isEmpty && dated.isEmpty;
}

final _dayProvider = FutureProvider.autoDispose.family<_DayDetail, _DayKey>((
  ref,
  key,
) async {
  ref.watch(identityRevisionProvider);
  final dao = ref.watch(fieldDefsDaoProvider);
  final events = ref.watch(fieldEventsDaoProvider);
  final fields = {for (final f in await dao.forProject(key.projectId)) f.id: f};

  final byField = <String, _Recorded>{};
  for (final e in await events.eventsBetween(
    key.projectId,
    key.day,
    DateTime(key.day.year, key.day.month, key.day.day + 1),
  )) {
    final field = fields[e.fieldDefId];
    if (field == null) continue;
    if (key.fieldId != null && field.id != key.fieldId) continue;
    final group = byField[field.id] ??= _Recorded(field);
    final shown = FieldValueCodec.display(
      type: field.type,
      stored: e.value,
      config: dao.configOf(field),
    );
    (group.byValue[shown] ??= <String>{}).add(e.plantId);
    group.sources.add(e.source);
  }

  final dated = <({FieldDef field, Set<String> plants})>[];
  for (final field in fields.values.where(_isDateField)) {
    if (key.fieldId != null && field.id != key.fieldId) continue;
    final plants = <String>{
      for (final e in (await events.currentValuesForField(field.id)).entries)
        if (_storedDay(field, e.value.value) == key.day) e.key,
    };
    if (plants.isNotEmpty) dated.add((field: field, plants: plants));
  }

  return _DayDetail(
    recorded: [for (final f in fields.values) ?byField[f.id]],
    dated: dated,
  );
});

/// Date-field values from today on: what is scheduled.
final _upcomingProvider = FutureProvider.autoDispose
    .family<
      List<({FieldDef field, DateTime day, int plants})>,
      ({String projectId, String? fieldId})
    >((ref, key) async {
      ref.watch(identityRevisionProvider);
      final events = ref.watch(fieldEventsDaoProvider);
      final today = _dayOf(DateTime.now());
      final out = <({FieldDef field, DateTime day, int plants})>[];
      for (final field
          in (await ref.watch(fieldDefsDaoProvider).forProject(key.projectId))
              .where(_isDateField)) {
        if (key.fieldId != null && field.id != key.fieldId) continue;
        final counts = <DateTime, int>{};
        for (final e in (await events.currentValuesForField(field.id)).values) {
          final day = _storedDay(field, e.value);
          if (day == null || day.isBefore(today)) continue;
          counts[day] = (counts[day] ?? 0) + 1;
        }
        for (final c in counts.entries) {
          out.add((field: field, day: c.key, plants: c.value));
        }
      }
      out.sort((a, b) => a.day.compareTo(b.day));
      return out.take(12).toList();
    });

/// When each value field was last recorded, and how many plants hold one.
final _lastProvider = FutureProvider.autoDispose
    .family<List<({FieldDef field, DateTime? last, int holding})>, String>((
      ref,
      projectId,
    ) async {
      ref.watch(identityRevisionProvider);
      final events = ref.watch(fieldEventsDaoProvider);
      final last = await events.lastObserved(projectId);
      return [
        for (final field
            in await ref.watch(fieldDefsDaoProvider).forProject(projectId))
          if (field.role == FieldRole.attribute)
            (
              field: field,
              last: last[field.id],
              holding: (await events.currentValuesForField(
                field.id,
              )).values.where((e) => e.value != null).length,
            ),
      ];
    });

// -------------------------------------------------------------- screen

/// A month of the vineyard: what was recorded each day, and which dates the
/// date fields hold -- past ones like planting, future ones as a schedule.
///
/// Built on the event log, which has kept every observation with the day it
/// was true since the first build. Nothing here is stored separately, so it
/// cannot disagree with the plants it describes, and undoing an edit takes it
/// off the calendar too.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _selected = _dayOf(DateTime.now());
  String? _fieldId;

  void _go(DateTime day) => setState(() {
    _selected = _dayOf(day);
    _month = DateTime(day.year, day.month);
  });

  /// Selects [plants] on the map and goes back to it.
  void _showOnMap(Set<String> plants) {
    final living = ref.read(layoutSnapshotProvider).valueOrNull?.positions;
    final selection = living == null
        ? plants
        : {
            for (final p in plants)
              if (living.containsKey(p)) p,
          };
    final messenger = ScaffoldMessenger.of(context);
    ref.read(selectedObjectProvider.notifier).state = null;
    ref.read(selectionProvider.notifier).state = selection;
    Navigator.of(context).pop();
    if (selection.length < plants.length) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${plants.length - selection.length} of them have since been '
            'removed, so ${groupDigits(selection.length)} are selected.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = [
      for (final f
          in ref.watch(_fieldsProvider(widget.projectId)).valueOrNull ??
              const <FieldDef>[])
        if (f.role == FieldRole.attribute) f,
    ];
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    final month = _MonthCard(
      month: _month,
      selected: _selected,
      marks:
          ref
              .watch(
                _monthProvider((
                  projectId: widget.projectId,
                  month: _month,
                  fieldId: _fieldId,
                )),
              )
              .valueOrNull ??
          const {},
      onMonth: (m) => setState(() => _month = m),
      onDay: _go,
    );

    final side = [
      _DayCard(
        day: _selected,
        detail: ref.watch(
          _dayProvider((
            projectId: widget.projectId,
            day: _selected,
            fieldId: _fieldId,
          )),
        ),
        onShow: _showOnMap,
      ),
      const SizedBox(height: 16),
      _UpcomingCard(
        items:
            ref
                .watch(
                  _upcomingProvider((
                    projectId: widget.projectId,
                    fieldId: _fieldId,
                  )),
                )
                .valueOrNull ??
            const [],
        onTap: _go,
      ),
      const SizedBox(height: 16),
      _LastCard(
        items:
            ref.watch(_lastProvider(widget.projectId)).valueOrNull ?? const [],
        onTap: _go,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          TextButton.icon(
            onPressed: () => _go(DateTime.now()),
            icon: const Icon(Icons.today),
            label: const Text('Today'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
              children: [
                ChoiceChip(
                  label: const Text('All fields'),
                  selected: _fieldId == null,
                  onSelected: (_) => setState(() => _fieldId = null),
                ),
                for (final f in fields)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      avatar: _isDateField(f)
                          ? const Icon(Icons.event, size: 18)
                          : null,
                      label: Text(f.name),
                      selected: _fieldId == f.id,
                      onSelected: (_) => setState(() => _fieldId = f.id),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: wide
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: month),
                        const SizedBox(width: 20),
                        Expanded(flex: 2, child: ListView(children: side)),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [month, const SizedBox(height: 16), ...side],
                  ),
          ),
        ],
      ),
    );
  }
}

final _fieldsProvider = FutureProvider.autoDispose
    .family<List<FieldDef>, String>(
      (ref, projectId) => ref.watch(fieldDefsDaoProvider).forProject(projectId),
    );

// ------------------------------------------------------------ month card

class _MonthCard extends StatelessWidget {
  const _MonthCard({
    required this.month,
    required this.selected,
    required this.marks,
    required this.onMonth,
    required this.onDay,
  });

  final DateTime month;
  final DateTime selected;
  final Map<DateTime, DayMarks> marks;
  final ValueChanged<DateTime> onMonth;
  final ValueChanged<DateTime> onDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = MaterialLocalizations.of(context);
    final firstWeekday = l10n.firstDayOfWeekIndex; // 0 = Sunday
    final today = _dayOf(DateTime.now());

    // Leading blanks so the 1st lands under its weekday.
    final lead = (month.weekday % 7 - firstWeekday) % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final cells = lead + days;
    final weeks = (cells / 7).ceil();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () =>
                      onMonth(DateTime(month.year, month.month - 1)),
                ),
                Expanded(
                  child: Text(
                    l10n.formatMonthYear(month),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () =>
                      onMonth(DateTime(month.year, month.month + 1)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Text(
                      l10n.narrowWeekdays[(firstWeekday + i) % 7],
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (var w = 0; w < weeks; w++)
              Row(
                children: [
                  for (var d = 0; d < 7; d++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final index = w * 7 + d - lead + 1;
                          if (index < 1 || index > days) {
                            return const AspectRatio(
                              aspectRatio: 1.15,
                              child: SizedBox(),
                            );
                          }
                          final day = DateTime(month.year, month.month, index);
                          return _DayCell(
                            day: day,
                            marks: marks[day],
                            isToday: day == today,
                            isSelected: day == selected,
                            isFuture: day.isAfter(today),
                            onTap: () => onDay(day),
                          );
                        },
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              children: [
                _Key(colour: scheme.primary, text: 'Recorded'),
                _Key(colour: scheme.secondary, text: 'Date set to this day'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.colour, required this.text});
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.marks,
    required this.isToday,
    required this.isSelected,
    required this.isFuture,
    required this.onTap,
  });

  final DateTime day;
  final DayMarks? marks;
  final bool isToday;
  final bool isSelected;
  final bool isFuture;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = marks;

    return AspectRatio(
      aspectRatio: 1.15,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: isSelected
              ? scheme.primaryContainer
              : (m != null ? scheme.surfaceContainerHigh : Colors.transparent),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: isSelected
                ? BorderSide(color: scheme.primary, width: 2)
                : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: isToday
                        ? BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          )
                        : null,
                    child: Text(
                      '${day.day}',
                      style: TextStyle(
                        fontWeight: isToday || isSelected
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: isToday
                            ? scheme.onPrimary
                            : (isFuture
                                  ? scheme.onSurfaceVariant
                                  : scheme.onSurface),
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (m != null && m.recorded > 0)
                    _Pill(
                      colour: scheme.primary,
                      text: _compact(m.recorded),
                      icon: Icons.edit_note,
                    ),
                  if (m != null && m.dated > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: _Pill(
                        colour: scheme.secondary,
                        text: _compact(m.dated),
                        icon: Icons.event,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _compact(int n) =>
      n >= 10000 ? '${(n / 1000).round()}k' : groupDigits(n);
}

class _Pill extends StatelessWidget {
  const _Pill({required this.colour, required this.text, required this.icon});
  final Color colour;
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- day card

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.detail,
    required this.onShow,
  });

  final DateTime day;
  final AsyncValue<_DayDetail> detail;
  final ValueChanged<Set<String>> onShow;

  static String _source(EventSource s) => switch (s) {
    EventSource.manual => 'By hand',
    EventSource.bulk => 'Set on many',
    EventSource.import => 'Imported',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = MaterialLocalizations.of(context);
    final value = detail.valueOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.formatFullDate(day),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            if (value == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (value.isEmpty)
              Text(
                'Nothing recorded, and no dates set to this day.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (value != null)
              for (final group in value.recorded) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.edit_note, size: 20, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${group.field.name} -- '
                        '${groupDigits(group.count)} recorded',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => onShow(group.plants),
                      child: const Text('Show on map'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e
                          in (group.byValue.entries.toList()..sort(
                            (a, b) => b.value.length.compareTo(a.value.length),
                          )))
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            '${e.key ?? 'cleared'}  ×${groupDigits(e.value.length)}',
                          ),
                          tooltip: 'Show these on the map',
                          onPressed: () => onShow(e.value),
                        ),
                      for (final s in group.sources)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(switch (s) {
                            EventSource.import => Icons.upload_file,
                            EventSource.bulk => Icons.select_all,
                            EventSource.manual => Icons.touch_app_outlined,
                          }, size: 16),
                          label: Text(_source(s)),
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                    ],
                  ),
                ),
              ],
            if (value != null)
              for (final d in value.dated) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.event, size: 20, color: scheme.secondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${d.field.name} -- ${groupDigits(d.plants.length)} '
                        '${d.plants.length == 1 ? 'plant' : 'plants'}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => onShow(d.plants),
                      child: const Text('Show on map'),
                    ),
                  ],
                ),
              ],
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------- side cards

class _UpcomingCard extends StatelessWidget {
  const _UpcomingCard({required this.items, required this.onTap});

  final List<({FieldDef field, DateTime day, int plants})> items;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = MaterialLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Coming up',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text(
                  'No future dates. A date field set to a day ahead -- '
                  '"Next spray", say -- shows here.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final item in items)
              ListTile(
                dense: true,
                leading: Icon(Icons.event, color: theme.colorScheme.secondary),
                title: Text(item.field.name),
                subtitle: Text(l10n.formatMediumDate(item.day)),
                trailing: Text(
                  '${groupDigits(item.plants)} '
                  '${item.plants == 1 ? 'plant' : 'plants'}',
                ),
                onTap: () => onTap(item.day),
              ),
          ],
        ),
      ),
    );
  }
}

class _LastCard extends StatelessWidget {
  const _LastCard({required this.items, required this.onTap});

  final List<({FieldDef field, DateTime? last, int holding})> items;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = MaterialLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Last recorded',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final item in items)
              ListTile(
                dense: true,
                leading: Icon(Icons.history, color: theme.colorScheme.primary),
                title: Text(item.field.name),
                subtitle: Text(
                  item.last == null
                      ? 'Never recorded'
                      : l10n.formatMediumDate(item.last!),
                ),
                trailing: Text(
                  '${groupDigits(item.holding)} '
                  '${item.holding == 1 ? 'plant has' : 'plants have'} a value',
                  style: theme.textTheme.bodySmall,
                ),
                onTap: item.last == null ? null : () => onTap(item.last!),
              ),
          ],
        ),
      ),
    );
  }
}
