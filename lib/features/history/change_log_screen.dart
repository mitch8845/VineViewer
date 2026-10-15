import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/change_log.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';

final changeLogProvider = Provider(
  (ref) => ChangeLog(ref.watch(databaseProvider)),
);

final _entriesProvider = StreamProvider.autoDispose
    .family<List<ChangeEntry>, String>(
      (ref, projectId) => ref.watch(changeLogProvider).watch(projectId),
    );

/// Every change made to the vineyard: what, when, and how much it touched.
class ChangeLogScreen extends ConsumerStatefulWidget {
  const ChangeLogScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ChangeLogScreen> createState() => _ChangeLogScreenState();
}

class _ChangeLogScreenState extends ConsumerState<ChangeLogScreen> {
  bool _showUndone = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = MaterialLocalizations.of(context);
    final entries = ref.watch(_entriesProvider(widget.projectId));
    final project = ref.watch(activeProjectProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Change log'),
        actions: [
          FilterChip(
            label: const Text('Show undone'),
            selected: _showUndone,
            onSelected: (v) => setState(() => _showUndone = v),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not read the log: $e')),
        data: (all) {
          final shown = [
            for (final e in all)
              if (_showUndone || !e.isUndone) e,
          ];
          // Grouped by local day, newest first.
          final days = <DateTime, List<ChangeEntry>>{};
          for (final e in shown) {
            (days[DateTime(e.at.year, e.at.month, e.at.day)] ??= []).add(e);
          }

          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                children: [
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No changes yet.',
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  for (final day in days.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                      child: Text(
                        l10n.formatFullDate(day.key),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Card(
                      child: Column(
                        children: [
                          for (final (i, e) in day.value.indexed) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                indent: 72,
                                color: theme.colorScheme.outlineVariant,
                              ),
                            _EntryTile(entry: e),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (project != null && all.length < 500)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
                      child: Row(
                        children: [
                          Icon(
                            Icons.flag_outlined,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Vineyard created ${l10n.formatMediumDate(project.createdAt.toLocal())}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (all.length >= 500)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Showing the 500 most recent changes.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final ChangeEntry entry;

  static IconData iconFor(String kind) => switch (kind) {
    'draw_object' || 'setup_objects' => Icons.polyline_outlined,
    'array_objects' => Icons.view_week_outlined,
    'array_points' || 'array_plants' || 'plant_more' => Icons.more_horiz,
    'place_plant' || 'insert_plant' => Icons.add_circle_outline,
    'move_plant' || 'move_object' => Icons.open_with,
    'reshape_object' => Icons.format_shapes,
    'split_object' => Icons.content_cut,
    'merge_objects' => Icons.call_merge,
    'delete_object' => Icons.delete_outline,
    'delete_plants' => Icons.delete_forever_outlined,
    'rename_object' || 'rename_project' => Icons.drive_file_rename_outline,
    'set_value' || 'bulk_set_value' => Icons.edit_note,
    'import' => Icons.upload_file,
    'renumber' => Icons.format_list_numbered,
    'retire_plants' => Icons.remove_circle_outline,
    'replace_plant' => Icons.autorenew,
    'create_field' || 'edit_field' => Icons.list_alt,
    'set_identifier' => Icons.tag,
    'set_image' => Icons.image_outlined,
    'delete_project' => Icons.delete_outline,
    'restore_project' => Icons.restore_from_trash_outlined,
    'seed_demo' => Icons.science_outlined,
    _ => Icons.history,
  };

  String _summary() {
    final parts = [
      if (entry.plants > 0)
        '${groupDigits(entry.plants)} ${entry.plants == 1 ? 'plant' : 'plants'}',
      if (entry.values > 0)
        '${groupDigits(entry.values)} ${entry.values == 1 ? 'value' : 'values'}',
      if (entry.objects > 0)
        '${groupDigits(entry.objects)} drawn ${entry.objects == 1 ? 'object' : 'objects'}',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = MaterialLocalizations.of(context);
    final undone = entry.isUndone;
    final time = l10n.formatTimeOfDay(TimeOfDay.fromDateTime(entry.at));
    final summary = _summary();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: undone
              ? scheme.surfaceContainerHighest
              : scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          iconFor(entry.kind),
          color: undone ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
        ),
      ),
      title: Text(
        entry.description,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          decoration: undone ? TextDecoration.lineThrough : null,
          color: undone ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: Text([time, if (summary.isNotEmpty) summary].join(' · ')),
      trailing: !undone
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: entry.canRedo
                    ? scheme.tertiaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                entry.canRedo ? 'Undone · can redo' : 'Undone',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: entry.canRedo
                      ? scheme.onTertiaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
    );
  }
}
