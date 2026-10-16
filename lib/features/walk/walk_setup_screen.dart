import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/walk_plan.dart';
import '../../core/db/daos/walk_orders_dao.dart';
import '../../core/db/database.dart';
import '../../core/format.dart';
import '../../core/models/enums.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import 'walk_order_screen.dart';
import 'walk_screen.dart';
import 'walk_session.dart';

/// Device-wide, so a test can point bookmarks at a temporary directory.
final walkBookmarksProvider = Provider((ref) => WalkBookmarks());

/// Before a walk: which fields, which plants, which order -- or pick up where
/// you stopped.
///
/// Only the chosen fields appear while walking. Every field on screen is a
/// row of buttons to look past, three thousand times.
class WalkSetupScreen extends ConsumerStatefulWidget {
  const WalkSetupScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<WalkSetupScreen> createState() => _WalkSetupScreenState();
}

typedef _Setup = ({
  List<FieldDef> fields,
  Set<String> identifierFields,
  WalkBookmark? bookmark,
});

class _WalkSetupScreenState extends ConsumerState<WalkSetupScreen> {
  late final Future<_Setup> _setup = _load();

  /// Chosen fields, in the order they were ticked.
  final List<String> _chosen = [];

  bool _onlySelected = false;
  bool _starting = false;

  /// Saved walk orders, refreshed after the editor.
  List<SavedWalkOrder>? _orders;

  /// The chosen order; empty for plant ID order.
  String _orderId = '';

  Future<_Setup> _load() async {
    final fields = await ref
        .read(fieldDefsDaoProvider)
        .forProject(widget.projectId);
    final template = await ref
        .read(labelServiceProvider)
        .templateFor(widget.projectId);
    final bookmarks = ref.read(walkBookmarksProvider);
    final bookmark = await bookmarks.load(widget.projectId);
    final orders = await ref
        .read(walkOrdersDaoProvider)
        .forProject(widget.projectId);
    final last = await bookmarks.lastOrder(widget.projectId);
    if (mounted) {
      setState(() {
        _orders = orders;
        if (last != null && orders.any((o) => o.id == last)) _orderId = last;
      });
    }
    return (
      fields: [
        for (final f in fields)
          if (f.role == FieldRole.attribute) f,
      ],
      identifierFields: template.fieldIds.toSet(),
      bookmark: bookmark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(selectionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Walk the vineyard')),
      body: FutureBuilder<_Setup>(
        future: _setup,
        builder: (context, snapshot) {
          final setup = snapshot.data;
          if (setup == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  ?_resumeCard(setup),
                  _heading('Fields to enter'),
                  const Text(
                    'Only these show while you walk. With one field, one tap '
                    'records it and moves to the next plant.',
                  ),
                  const SizedBox(height: 8),
                  if (setup.fields.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'This vineyard has no fields to record yet. Add one '
                        'under Fields.',
                      ),
                    ),
                  for (final f in setup.fields) _fieldTile(f, setup),
                  const SizedBox(height: 24),
                  _heading('Plants'),
                  RadioGroup<bool>(
                    groupValue: _onlySelected,
                    onChanged: (v) => setState(() => _onlySelected = v!),
                    child: Column(
                      children: [
                        const RadioListTile<bool>(
                          value: false,
                          title: Text('Every plant'),
                        ),
                        RadioListTile<bool>(
                          value: true,
                          enabled: selection.isNotEmpty,
                          title: Text(
                            selection.isEmpty
                                ? 'Only the selected plants'
                                : 'Only the ${groupDigits(selection.length)} '
                                      'selected plants',
                          ),
                          subtitle: selection.isEmpty
                              ? const Text(
                                  'Select rows, blocks or plants on the map '
                                  'first',
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _heading('Order'),
                  ..._order(),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(64),
                      textStyle: const TextStyle(fontSize: 20),
                    ),
                    onPressed: _chosen.isEmpty || _starting
                        ? null
                        : () => _start(setup, bookmark: null),
                    icon: const Icon(Icons.directions_walk),
                    label: Text(
                      setup.bookmark == null
                          ? 'Start walking'
                          : 'Start a new walk',
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

  Future<void> _reloadOrders({String? select}) async {
    final orders = await ref
        .read(walkOrdersDaoProvider)
        .forProject(widget.projectId);
    if (!mounted) return;
    setState(() {
      _orders = orders;
      if (select != null) _orderId = select;
      if (!orders.any((o) => o.id == _orderId)) _orderId = '';
    });
  }

  Future<void> _edit(String? orderId) async {
    final saved = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            WalkOrderScreen(projectId: widget.projectId, orderId: orderId),
      ),
    );
    await _reloadOrders(select: saved);
  }

  Set<String> _namesExcept(String? id) => {
    for (final o in _orders ?? const <SavedWalkOrder>[])
      if (o.id != id) o.name,
  };

  Future<void> _copy(SavedWalkOrder order) async {
    final name = await askWalkOrderName(
      context,
      title: 'Copy "${order.name}" as',
      initial: '${order.name} (copy)',
      taken: _namesExcept(null),
    );
    if (name == null) return;
    final id = await ref.read(walkOrdersDaoProvider).copy(order.id, name);
    await _reloadOrders(select: id);
  }

  Future<void> _rename(SavedWalkOrder order) async {
    final name = await askWalkOrderName(
      context,
      title: 'Rename walk order',
      initial: order.name,
      taken: _namesExcept(order.id),
    );
    if (name == null) return;
    await ref.read(walkOrdersDaoProvider).rename(order.id, name);
    await _reloadOrders();
  }

  Future<void> _delete(SavedWalkOrder order) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${order.name}"?'),
        content: const Text(
          'Only the walk order goes. Values entered on walks that used it '
          'stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(walkOrdersDaoProvider).delete(order.id);
    await _reloadOrders();
  }

  /// Plant ID order, then each saved order, with a menu to edit, copy,
  /// rename or delete it.
  List<Widget> _order() {
    final orders = _orders ?? const <SavedWalkOrder>[];
    return [
      RadioGroup<String>(
        groupValue: _orderId,
        onChanged: (v) => setState(() => _orderId = v ?? ''),
        child: Column(
          children: [
            const RadioListTile<String>(
              value: '',
              title: Text('Plant ID order'),
              subtitle: Text(
                'Block, then row, then plant — each row back the way the '
                'last one came',
              ),
            ),
            for (final o in orders)
              RadioListTile<String>(
                value: o.id,
                title: Text(o.name),
                subtitle: Text(
                  '${groupDigits(o.plan.walk.length)} plants · saved '
                  '${isoDate(o.updatedAt)}',
                ),
                secondary: PopupMenuButton<String>(
                  tooltip: 'Walk order options',
                  onSelected: (v) => switch (v) {
                    'edit' => _edit(o.id),
                    'copy' => _copy(o),
                    'rename' => _rename(o),
                    _ => _delete(o),
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.route),
                        title: Text('Edit'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'copy',
                      child: ListTile(
                        leading: Icon(Icons.copy),
                        title: Text('Copy…'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Rename…'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete…'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _edit(null),
          icon: const Icon(Icons.add),
          label: const Text('New walk order'),
        ),
      ),
    ];
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _fieldTile(FieldDef f, _Setup setup) {
    // A value in the plant ID re-addresses the plant, and the inspector asks
    // before doing that. A walk has no room to ask three thousand times.
    final inId = setup.identifierFields.contains(f.id);
    final position = _chosen.indexOf(f.id);
    return CheckboxListTile(
      value: position >= 0,
      enabled: !inId,
      title: Text(f.name),
      subtitle: inId
          ? const Text('Part of the plant ID — change it from the plant panel')
          : f.isStatic
          ? const Text('Write-once: plants that have a value will ask first')
          : null,
      secondary: position >= 0 && _chosen.length > 1
          ? CircleAvatar(radius: 14, child: Text('${position + 1}'))
          : null,
      onChanged: (on) =>
          setState(() => on == true ? _chosen.add(f.id) : _chosen.remove(f.id)),
    );
  }

  Widget? _resumeCard(_Setup setup) {
    final bookmark = setup.bookmark;
    if (bookmark == null) return null;
    final names = {for (final f in setup.fields) f.id: f.name};
    final fields = [
      for (final id in bookmark.fieldIds)
        if (names[id] != null) names[id]!,
    ];
    // Every field it walked has been deleted since: nothing to resume.
    if (fields.isEmpty) return null;
    final orderName = bookmark.orderId == null
        ? null
        : _orders?.where((o) => o.id == bookmark.orderId).firstOrNull?.name;
    return Card(
      margin: const EdgeInsets.only(bottom: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.bookmark_outline, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Unfinished walk: ${fields.join(', ')}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    [
                      bookmark.subset == null
                          ? 'Every plant'
                          : '${groupDigits(bookmark.subset!.length)} selected '
                                'plants',
                      ?orderName,
                      'stopped at plant ${groupDigits(bookmark.index + 1)}',
                    ].join(' · '),
                  ),
                ],
              ),
            ),
            FilledButton(
              onPressed: _starting
                  ? null
                  : () => _start(setup, bookmark: bookmark),
              child: const Text('Resume'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _start(_Setup setup, {required WalkBookmark? bookmark}) async {
    setState(() => _starting = true);
    try {
      final live = {for (final f in setup.fields) f.id: f};
      final fieldIds = [
        for (final id in bookmark?.fieldIds ?? _chosen)
          if (live.containsKey(id) && !setup.identifierFields.contains(id)) id,
      ];
      final subset =
          bookmark?.subset ??
          (_onlySelected ? ref.read(selectionProvider).toList() : null);

      final identifiers = await ref
          .read(labelServiceProvider)
          .identifiersForProject(widget.projectId);
      // A resumed walk keeps the route it started on. If that order has been
      // deleted since, it carries on in plant ID order.
      final orderId = bookmark == null
          ? (_orderId.isEmpty ? null : _orderId)
          : bookmark.orderId;
      final saved = orderId == null
          ? null
          : await ref.read(walkOrdersDaoProvider).load(orderId);
      var order =
          (saved?.plan.reconcile(identifiers) ?? WalkPlan.standard(identifiers))
              .walk;
      if (subset != null) {
        final keep = subset.toSet();
        order = [
          for (final id in order)
            if (keep.contains(id)) id,
        ];
      }
      if (order.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No plants are switched on for this walk.'),
            ),
          );
        }
        return;
      }

      // The map colours by the first field, so the inset fills in as you go
      // and the map shows the survey when you come back to it.
      ref.read(colorByFieldProvider.notifier).state = fieldIds.first;
      if (bookmark == null) {
        await ref
            .read(walkBookmarksProvider)
            .saveLastOrder(widget.projectId, saved?.id);
      }

      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => WalkScreen(
            projectId: widget.projectId,
            fields: [for (final id in fieldIds) live[id]!],
            order: order,
            startIndex: bookmark?.resumeIndex(order) ?? 0,
            subset: subset,
            orderId: saved?.id,
            identifiers: identifiers,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
