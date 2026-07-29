import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/numbering_service.dart';
import '../../../core/db/daos/layout_dao.dart';
import '../../../core/providers.dart';
import '../canvas_controller.dart';

/// What can be done to a selection of plants.
///
/// Numbering, and the two ways a plant leaves service. There is deliberately no
/// permanent delete and no trash: a plant you pulled is data, and a plant you
/// created by mistake is one press of undo.
class PlantActionsSheet extends ConsumerWidget {
  const PlantActionsSheet({super.key, required this.selection});

  final Set<String> selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${selection.length} '
                '${selection.length == 1 ? 'plant' : 'plants'} selected',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.format_list_numbered),
            title: const Text('Number them'),
            subtitle: const Text('Set where the numbers start and which way'),
            onTap: () async {
              Navigator.pop(context);
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) => _NumberingSheet(selection: selection),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline),
            title: const Text('Mark as removed'),
            subtitle: const Text(
              'Died or was pulled. History is kept and the position stays as an '
              'empty slot, ready for a replant.',
            ),
            onTap: () => _retire(context, ref),
          ),
          if (selection.length == 1)
            ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('Replace with a new plant'),
              subtitle: const Text(
                'Retires this one and plants a successor in its place, keeping '
                'the same ID.',
              ),
              onTap: () => _replace(context, ref),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Text(
              'There is no permanent delete. A plant you pulled is data worth '
              'keeping, and one created by mistake is a press of undo.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _retire(BuildContext context, WidgetRef ref) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final events = await ref
        .read(fieldEventsDaoProvider)
        .countEventsFor(selection);
    if (!context.mounted) return;

    // The observation count first, as section 6.4 specifies: retiring a plant
    // with three seasons of readings deserves a different pause than one
    // planted yesterday.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          selection.length == 1
              ? 'Mark this plant as removed?'
              : 'Mark ${selection.length} plants as removed?',
        ),
        content: Text(
          events == 0
              ? 'Nothing has been recorded against '
                    '${selection.length == 1 ? 'it' : 'them'} yet.'
              : '$events recorded '
                    '${events == 1 ? 'observation' : 'observations'} will be '
                    'kept. The '
                    '${selection.length == 1 ? 'position' : 'positions'} stay '
                    'on the map as empty slots.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark as removed'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final layout = ref.read(layoutDaoProvider);
    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'retire_plants',
          description: selection.length == 1
              ? 'Mark plant as removed'
              : 'Mark ${selection.length} plants as removed',
          body: () async {
            for (final id in selection) {
              await layout.retirePlant(id, change: PlantStatusChange.removed);
            }
          },
        );

    if (context.mounted) {
      Navigator.pop(context);
      ref.read(selectionProvider.notifier).state = const {};
    }
  }

  Future<void> _replace(BuildContext context, WidgetRef ref) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final statics = [
      for (final f
          in await ref.read(fieldDefsDaoProvider).forProject(projectId))
        if (f.isStatic) f,
    ];
    if (!context.mounted) return;

    // Which facts carry forward is a judgement only the user can make: the
    // variety almost certainly does, the planting date certainly does not.
    final inherit = <String>{};
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Replace this plant'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The old plant is retired and keeps its whole history. The new '
                'one takes its place and its ID.',
              ),
              if (statics.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'No write-once fields to carry over.',
                    style: TextStyle(fontSize: 12),
                  ),
                )
              else ...[
                const SizedBox(height: 12),
                const Text('Carry over:'),
                for (final field in statics)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: inherit.contains(field.id),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        inherit.add(field.id);
                      } else {
                        inherit.remove(field.id);
                      }
                    }),
                    title: Text(field.name),
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      ),
    );
    if (proceed != true || !context.mounted) return;

    final layout = ref.read(layoutDaoProvider);
    final replacement = await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'replace_plant',
          description: 'Replace plant',
          body: () => layout.replacePlant(
            vineId: selection.first,
            inheritFieldIds: inherit,
          ),
        );

    if (context.mounted) {
      Navigator.pop(context);
      ref.read(selectionProvider.notifier).state = {replacement};
    }
  }
}

/// Numbers a selection: where to start, and which way to walk it.
class _NumberingSheet extends ConsumerStatefulWidget {
  const _NumberingSheet({required this.selection});

  final Set<String> selection;

  @override
  ConsumerState<_NumberingSheet> createState() => _NumberingSheetState();
}

class _NumberingSheetState extends ConsumerState<_NumberingSheet> {
  final _startAt = TextEditingController(text: '1');
  NumberingOrder _order = NumberingOrder.leftToRight;
  List<String>? _collisions;
  bool _working = false;

  @override
  void dispose() {
    _startAt.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    setState(() => _working = true);
    final numbering = ref.read(numberingServiceProvider);
    final plan = await numbering.plan(
      vineIds: widget.selection,
      startAt: int.tryParse(_startAt.text) ?? 1,
      order: _order,
    );

    final result = await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'renumber',
          description: 'Number ${widget.selection.length} plants',
          body: () => numbering.apply(plan, projectId: projectId),
        );

    if (!mounted) return;
    switch (result) {
      case NumberingRefused(:final collisions):
        // Refused, not partially applied: the sheet stays open so the start
        // number can be changed rather than leaving the vineyard half done.
        setState(() {
          _working = false;
          _collisions = collisions;
        });
      case NumberingApplied():
        Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Number ${widget.selection.length} plants',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _startAt,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Start at'),
              onChanged: (_) => setState(() => _collisions = null),
            ),
            const SizedBox(height: 16),
            Text('Order', style: Theme.of(context).textTheme.titleSmall),
            // RadioGroup rather than per-tile groupValue/onChanged, both of
            // which are deprecated: the group owns the selection now.
            RadioGroup<NumberingOrder>(
              groupValue: _order,
              onChanged: (v) => setState(() {
                _order = v ?? _order;
                _collisions = null;
              }),
              child: Column(
                children: [
                  for (final order in NumberingOrder.values)
                    RadioListTile<NumberingOrder>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: order,
                      title: Text(order.description),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Plants ${int.tryParse(_startAt.text) ?? 1}'
              '-${(int.tryParse(_startAt.text) ?? 1) + widget.selection.length - 1}'
              ', ${_order.description}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),

            if (_collisions != null) ...[
              const SizedBox(height: 16),
              Text(
                'That would give the same ID to more than one plant: '
                '${_collisions!.take(4).join(', ')}'
                '${_collisions!.length > 4 ? '...' : ''}. '
                'Nothing was changed.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _working ? null : _apply,
                  child: const Text('Number them'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
