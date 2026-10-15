import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/import_service.dart';
import '../../core/format.dart';
import '../../core/import/table_reader.dart';
import '../../core/providers.dart';
import 'aerial_image.dart';

/// Imports plant values from a spreadsheet: pick, preview, then write.
///
/// Nothing is written until the preview has been read and the button pressed,
/// and what is written is one operation -- a wrong sheet is one press of undo
/// on the map, not three thousand corrections.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, required this.projectId, this.table});

  final String projectId;

  /// A table already read, which skips the picker. For tests and previews:
  /// the system picker cannot be driven from a widget test.
  @visibleForTesting
  final TableData? table;

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  ImportPlan? _plan;
  String? _error;
  bool _busy = true;
  bool _overwrite = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final given = widget.table;
      given == null ? _pick() : _load(given);
    });
  }

  Future<void> _load(TableData table) async {
    final plan = await ref
        .read(importServiceProvider)
        .plan(widget.projectId, table);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _busy = false;
    });
  }

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List? bytes = await pickAnyFile();
      if (!mounted) return;
      if (bytes == null) {
        // Backed out of the picker: nothing to say, nothing to show.
        if (_plan == null) Navigator.of(context).pop();
        setState(() => _busy = false);
        return;
      }
      final table = TableReader.read(bytes);
      final plan = await ref
          .read(importServiceProvider)
          .plan(widget.projectId, table);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _overwrite = false;
        _busy = false;
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _fail('Could not open the file: ${e.message}'));
      }
    } on TableReadException catch (e) {
      if (mounted) setState(() => _fail(e.message));
    } catch (e) {
      if (mounted) setState(() => _fail('Could not read that file: $e'));
    }
  }

  void _fail(String message) {
    _error = message;
    _plan = null;
    _busy = false;
  }

  Future<void> _import() async {
    final plan = _plan;
    if (plan == null || !plan.hasWrites) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(operationRecorderProvider)
          .run(
            projectId: widget.projectId,
            kind: 'import',
            description: 'Import ${groupDigits(plan.writeCount)} values',
            body: () => ref
                .read(importServiceProvider)
                .apply(plan, overwriteWriteOnce: _overwrite),
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${groupDigits(result.written)} values'
            '${result.skippedHeld == 0 ? '' : ', kept ${groupDigits(result.skippedHeld)} existing write-once values'}'
            '. One press of undo reverts it.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The import failed and nothing was changed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import from a spreadsheet'),
        actions: [
          if (!_busy)
            TextButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Choose another file'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _busy && plan == null
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 120),
                  children: [
                    if (_error != null) _ErrorCard(message: _error!),
                    if (plan != null) ..._planView(context, plan),
                    if (plan == null && _error == null) const _Hint(),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: plan == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        plan.hasWrites
                            ? '${groupDigits(_writeCount(plan))} values will be '
                                  'written in one step. Undo reverts all of it.'
                            : 'Nothing to import -- every value already '
                                  'matches or was refused.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _busy || _writeCount(plan) == 0
                          ? null
                          : _import,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_done),
                      label: const Text('Import'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  int _writeCount(ImportPlan plan) =>
      plan.writeCount -
      (_overwrite
          ? 0
          : plan.columns.fold(0, (n, c) => n + c.alreadyHeld.length));

  List<Widget> _planView(BuildContext context, ImportPlan plan) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return [
      _Section(
        title: 'Rows',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Line(
              icon: Icons.check_circle_outline,
              colour: scheme.primary,
              text:
                  '${groupDigits(plan.matchedRows)} of '
                  '${groupDigits(plan.rowCount)} rows matched a plant by '
                  '"${plan.idHeader}"',
            ),
            if (plan.unknownIds.isNotEmpty)
              _Expandable(
                icon: Icons.help_outline,
                colour: scheme.error,
                text:
                    '${groupDigits(plan.unknownIds.length)} IDs are not plants '
                    'in this vineyard -- skipped',
                items: plan.unknownIds,
              ),
            if (plan.duplicateIds.isNotEmpty)
              _Expandable(
                icon: Icons.content_copy,
                colour: scheme.tertiary,
                text:
                    '${plan.duplicateIds.length} IDs appear more than once -- '
                    'the first row of each was used',
                items: plan.duplicateIds,
              ),
          ],
        ),
      ),
      if (plan.ignoredHeaders.isNotEmpty || plan.identifierHeaders.isNotEmpty)
        _Section(
          title: 'Columns not imported',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (plan.ignoredHeaders.isNotEmpty)
                _Line(
                  icon: Icons.remove_circle_outline,
                  colour: scheme.onSurfaceVariant,
                  text:
                      '${plan.ignoredHeaders.join(', ')} -- no value field by '
                      'that name (positions like Block and Row come from the '
                      'map, not the sheet)',
                ),
              if (plan.identifierHeaders.isNotEmpty)
                _Line(
                  icon: Icons.tag,
                  colour: scheme.error,
                  text:
                      '${plan.identifierHeaders.join(', ')} -- part of the '
                      'plant ID, so changing it would rename plants. Edit '
                      'those on the map instead.',
                ),
            ],
          ),
        ),
      for (final column in plan.columns)
        _Section(
          title: column.field.name,
          trailing: Text(
            '${groupDigits(column.values.length)} to write',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Line(
                icon: Icons.edit_note,
                colour: scheme.primary,
                text: _summary(column),
              ),
              if (column.unchanged > 0)
                _Line(
                  icon: Icons.drag_handle,
                  colour: scheme.onSurfaceVariant,
                  text:
                      '${groupDigits(column.unchanged)} already hold exactly '
                      'this value -- left alone',
                ),
              if (column.alreadyHeld.isNotEmpty)
                _Line(
                  icon: Icons.lock_outline,
                  colour: scheme.tertiary,
                  text:
                      '${groupDigits(column.alreadyHeld.length)} already have a '
                      'different ${column.field.name}, and it is write-once',
                ),
              if (column.rejected.isNotEmpty)
                _Expandable(
                  icon: Icons.block,
                  colour: scheme.error,
                  text:
                      '${groupDigits(column.rejected.length)} values refused '
                      'by the field\'s rules',
                  items: [
                    for (final r in column.rejected)
                      '${r.plantId}: "${r.value}" -- ${r.message}',
                  ],
                ),
            ],
          ),
        ),
      if (plan.hasWriteOnceConflicts)
        Card(
          child: SwitchListTile(
            value: _overwrite,
            onChanged: _busy ? null : (v) => setState(() => _overwrite = v),
            title: const Text('Overwrite write-once values already set'),
            subtitle: const Text(
              'Off keeps what is on the tablet. Either way, old values stay '
              'in each plant\'s history.',
            ),
          ),
        ),
    ];
  }

  /// "Pinot Noir ×3,023 · Teroldego ×2" -- what is going in, at a glance.
  String _summary(ImportColumn column) {
    if (column.values.isEmpty) return 'Nothing new to write';
    final counts = <String, int>{};
    for (final v in column.values.values) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final shown = sorted
        .take(8)
        .map((e) => '${e.key} ×${groupDigits(e.value)}')
        .join(' · ');
    return sorted.length > 8 ? '$shown · and ${sorted.length - 8} more' : shown;
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.colour, required this.text});

  final IconData icon;
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colour),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// A line with a "show" toggle listing the specifics.
class _Expandable extends StatefulWidget {
  const _Expandable({
    required this.icon,
    required this.colour,
    required this.text,
    required this.items,
  });

  final IconData icon;
  final Color colour;
  final String text;
  final List<String> items;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool _open = false;
  static const _limit = 50;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Line(
                  icon: widget.icon,
                  colour: widget.colour,
                  text: widget.text,
                ),
              ),
              Icon(_open ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 4, 0, 4),
            child: Text(
              [
                ...widget.items.take(_limit),
                if (widget.items.length > _limit)
                  '…and ${widget.items.length - _limit} more',
              ].join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'Choose an .xlsx or .csv file. The first sheet is read; its first row '
        'names the columns. One column must be "ID", holding plant IDs exactly '
        'as the map shows them. Every other column is matched to a field of '
        'the same name.',
      ),
    );
  }
}
