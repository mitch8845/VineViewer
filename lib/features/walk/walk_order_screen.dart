import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/walk_plan.dart';
import '../../core/format.dart';
import '../../core/models/identifier_template.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/viewport.dart';
import '../canvas/vineyard_painter.dart';
import 'walk_labels.dart';

/// Arranging a saved walk order before setting out.
///
/// Three views of one order: whole blocks, stretches of row, single plants.
/// Whatever reaches the top of the list lights up on the map beside it, so
/// scrolling through shows the walk unfolding before you are standing in it.
///
/// Nothing is saved until **Save**. Every edit can be undone here first.
/// Pops with the id of the order it saved, if any, so walk setup can pick it.
class WalkOrderScreen extends ConsumerStatefulWidget {
  const WalkOrderScreen({super.key, required this.projectId, this.orderId});

  final String projectId;

  /// The order to edit, or null for a new one starting from plant ID order.
  final String? orderId;

  @override
  ConsumerState<WalkOrderScreen> createState() => _WalkOrderScreenState();
}

class _WalkOrderScreenState extends ConsumerState<WalkOrderScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this)
    ..addListener(_tabChanged);
  final _scroll = ScrollController();

  static const _itemExtent = 76.0;

  Map<String, PlantIdentifier> _ids = const {};
  List<String> _partNames = const [];

  WalkPlan? _plan;

  /// Earlier plans, newest last: the editor's own undo.
  final List<WalkPlan> _history = [];

  /// What is saved, to know whether leaving would lose anything.
  WalkPlan? _saved;

  /// The order being edited, once it has been saved under a name.
  String? _id;
  String? _orderName;

  /// Selected sections, by their first plant -- which survives an edit that
  /// moves them, where an index would not.
  final Set<String> _selected = {};

  /// Moving the selection: waiting for a tap on where it should go.
  bool _placing = false;

  int _top = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ids = await ref
        .read(labelServiceProvider)
        .identifiersForProject(widget.projectId);
    final names = await loadPartNames(ref, widget.projectId);
    final saved = widget.orderId == null
        ? null
        : await ref.read(walkOrdersDaoProvider).load(widget.orderId!);
    final plan = saved?.plan.reconcile(ids) ?? WalkPlan.standard(ids);
    if (!mounted) return;
    setState(() {
      _ids = ids;
      _partNames = names;
      _plan = plan;
      // A new order is unsaved from the start: leaving asks first.
      _saved = saved == null ? null : plan;
      _id = saved?.id;
      _orderName = saved?.name;
    });
  }

  /// The tab whose list is showing. Follows the tab bar the moment a tab is
  /// tapped, rather than after its slide animation finishes.
  int _shown = 0;

  WalkLevel get _level => WalkLevel.values[_shown];

  List<WalkSection> get _sections => _plan!.sections(_level, _ids);

  /// Unsaved edits. A new order nobody has touched yet is not worth asking
  /// about on the way out.
  bool get _dirty =>
      _saved == null ? _history.isNotEmpty : !identical(_plan, _saved);

  void _tabChanged() {
    if (_tabs.index == _shown) return;
    setState(() {
      _shown = _tabs.index;
      _selected.clear();
      _placing = false;
      _top = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _scrolled() {
    final top = (_scroll.offset / _itemExtent).floor();
    if (top != _top) setState(() => _top = math.max(0, top));
  }

  void _edit(WalkPlan next) {
    if (identical(next, _plan)) return;
    setState(() {
      _history.add(_plan!);
      _plan = next;
    });
  }

  void _undo() {
    if (_history.isEmpty) return;
    setState(() {
      _plan = _history.removeLast();
      _placing = false;
    });
  }

  List<WalkSection> get _selectedSections => [
    for (final s in _sections)
      if (_selected.contains(_plan!.order[s.start])) s,
  ];

  // --------------------------------------------------------------- actions

  void _moveBy(int step) {
    final sections = _sections;
    final picked = _selectedSections;
    if (picked.isEmpty) return;
    // By position, not indexOf: a section's key is a fresh list every time
    // the sections are worked out, so record equality never matches.
    final first = sections.indexWhere((s) => s.start == picked.first.start);
    final last = sections.indexWhere((s) => s.start == picked.last.start);
    final int before;
    if (step < 0) {
      if (first == 0) return;
      before = sections[first - 1].start;
    } else {
      if (last == sections.length - 1) return;
      before = sections[last + 1].end;
    }
    _edit(
      _plan!.move([for (final s in picked) (s.start, s.end)], before, _ids),
    );
  }

  /// Puts the selection after [target], or at the very start for null.
  void _place(WalkSection? target) {
    final picked = _selectedSections;
    setState(() => _placing = false);
    if (picked.isEmpty) return;
    _edit(
      _plan!.move(
        [for (final s in picked) (s.start, s.end)],
        target?.end ?? 0,
        _ids,
      ),
    );
  }

  /// [to] counts positions with the dragged section already taken out.
  void _reorder(int from, int to) {
    final sections = _sections;
    final s = sections[from];
    final rest = [...sections]..removeAt(from);
    final before = to < rest.length ? rest[to].start : _plan!.order.length;
    _edit(_plan!.move([(s.start, s.end)], before, _ids));
  }

  void _flip() {
    var plan = _plan!;
    // Flipping changes where each section starts, so each is found afresh
    // by its plants rather than by a stale index.
    for (final s in _selectedSections) {
      final first = _plan!.order[s.start];
      final last = _plan!.order[s.end - 1];
      final a = plan.order.indexOf(first);
      final b = plan.order.indexOf(last);
      plan = plan.flip(math.min(a, b), math.max(a, b) + 1, _ids);
    }
    final kept = {for (final s in _selectedSections) _plan!.order[s.end - 1]};
    _edit(plan);
    setState(() {
      _selected
        ..clear()
        ..addAll(kept);
    });
  }

  void _include(bool on) {
    final plants = [
      for (final s in _selectedSections)
        ..._plan!.order.sublist(s.start, s.end),
    ];
    _edit(_plan!.include(plants, on));
  }

  void _toggle(WalkSection s, bool on) =>
      _edit(_plan!.include(_plan!.order.sublist(s.start, s.end), on));

  Future<void> _split() async {
    final picked = _selectedSections;
    if (picked.length != 1) return;
    final s = picked.single;
    final plants = _plan!.order.sublist(s.start, s.end);
    if (plants.length < 2) return;
    final at = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Start the second piece at'),
        children: [
          SizedBox(
            width: 360,
            height: math.min(480, plants.length * 56.0),
            child: ListView(
              children: [
                for (var i = 1; i < plants.length; i++)
                  ListTile(
                    title: Text(_name(plants[i])),
                    onTap: () => Navigator.pop(context, i),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (at == null) return;
    _edit(_plan!.split(s.start + at));
  }

  void _join() {
    final picked = _selectedSections;
    if (picked.length != 1) return;
    _edit(_plan!.join(picked.single.start));
  }

  /// Whether [s] continues the same row as the stretch before it -- the only
  /// case where joining means anything.
  bool _joinable(WalkSection s) {
    if (s.start == 0) return false;
    return _plan!.breaks.contains(_plan!.order[s.start]);
  }

  void _reset() {
    _edit(WalkPlan.standard(_ids));
    _say('Back to plant ID order. Save to keep it.');
  }

  /// Saves over the order being edited, or asks for a name if it is new.
  /// Returns whether it saved.
  Future<bool> _save() async {
    if (_id == null) return _saveAs();
    final plan = _plan!;
    await ref.read(walkOrdersDaoProvider).update(_id!, plan);
    if (!mounted) return true;
    setState(() => _saved = plan);
    _say('Walk order "$_orderName" saved.');
    return true;
  }

  /// Saves what is on screen as a new order, leaving any original as it was.
  /// The editor then carries on with the new one.
  Future<bool> _saveAs() async {
    final dao = ref.read(walkOrdersDaoProvider);
    final taken = {
      for (final o in await dao.forProject(widget.projectId)) o.name,
    };
    if (!mounted) return false;
    final name = await askWalkOrderName(
      context,
      title: _id == null ? 'Name this walk order' : 'Save a copy as',
      initial: _orderName == null ? '' : '$_orderName (copy)',
      taken: taken,
    );
    if (name == null) return false;
    final plan = _plan!;
    final id = await dao.create(
      projectId: widget.projectId,
      name: name,
      plan: plan,
    );
    if (!mounted) return true;
    setState(() {
      _id = id;
      _orderName = name;
      _saved = plan;
    });
    _say('Walk order "$name" saved.');
    return true;
  }

  Future<void> _rename() async {
    final id = _id;
    if (id == null) return;
    final dao = ref.read(walkOrdersDaoProvider);
    final taken = {
      for (final o in await dao.forProject(widget.projectId))
        if (o.id != id) o.name,
    };
    if (!mounted) return;
    final name = await askWalkOrderName(
      context,
      title: 'Rename walk order',
      initial: _orderName ?? '',
      taken: taken,
    );
    if (name == null) return;
    await dao.rename(id, name);
    if (mounted) setState(() => _orderName = name);
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save the walk order?'),
        content: const Text('Your changes to the order are not saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (choice == 'save') return _save();
    return choice != null;
  }

  // ---------------------------------------------------------------- display

  String _name(String plantId) => _ids[plantId]?.text ?? '?';

  String _title(WalkSection s) => switch (_level) {
    WalkLevel.plants => _name(_plan!.order[s.start]),
    _ when s.key.isEmpty => 'Whole vineyard',
    _ => describeParts(s.key, _partNames),
  };

  String _subtitle(WalkSection s) {
    final plan = _plan!;
    final count = s.end - s.start;
    final off = [
      for (var i = s.start; i < s.end; i++)
        if (plan.excluded.contains(plan.order[i])) 1,
    ].length;
    String last(String id) => _ids[id]?.parts.lastOrNull ?? '?';
    final detail = switch (_level) {
      WalkLevel.blocks => () {
        final rows = plan
            .sections(WalkLevel.rows, _ids)
            .where((r) => r.start >= s.start && r.end <= s.end)
            .length;
        return '${groupDigits(rows)} ${rows == 1 ? 'row' : 'rows'} · '
            '${groupDigits(count)} plants';
      }(),
      WalkLevel.rows =>
        '${_partNames.lastOrNull ?? 'Plant'} '
            '${last(plan.order[s.start])} → ${last(plan.order[s.end - 1])} · '
            '${groupDigits(count)} ${count == 1 ? 'plant' : 'plants'}',
      WalkLevel.plants => 'Stop ${groupDigits(s.start + 1)}',
    };
    return off == 0 ? detail : '$detail · ${groupDigits(off)} off';
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return PopScope(
      // Always handled here, to hand back the id of what was saved.
      canPop: false,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop(_id);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _orderName == null ? 'New walk order' : 'Walk order: $_orderName',
          ),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'Blocks'),
              Tab(text: 'Rows'),
              Tab(text: 'Plants'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo),
              onPressed: _history.isEmpty ? null : _undo,
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) => switch (v) {
                'copy' => _saveAs(),
                'rename' => _rename(),
                _ => _reset(),
              },
              itemBuilder: (context) => [
                if (_id != null) ...const [
                  PopupMenuItem(
                    value: 'copy',
                    child: ListTile(
                      leading: Icon(Icons.copy),
                      title: Text('Save as a copy…'),
                      subtitle: Text('Keeps this one as it was saved'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Rename…'),
                    ),
                  ),
                ],
                const PopupMenuItem(
                  value: 'reset',
                  child: ListTile(
                    leading: Icon(Icons.restart_alt),
                    title: Text('Back to plant ID order'),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: plan == null || !(_dirty || _id == null)
                    ? null
                    : () => _save(),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: plan == null
            ? const Center(child: CircularProgressIndicator())
            : _body(plan),
      ),
    );
  }

  Widget _body(WalkPlan plan) {
    final sections = _sections;
    final top = sections.isEmpty
        ? null
        : sections[math.min(_top, sections.length - 1)];
    final picked = _selectedSections;
    final highlighted = picked.isNotEmpty && !_placing ? picked : [?top];

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        [
          '${groupDigits(plan.walk.length)} of '
              '${groupDigits(plan.order.length)} plants on the walk',
          _dirty || _id == null ? 'not saved' : 'saved',
        ].join(' · '),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );

    final list = ReorderableListView.builder(
      scrollController: _scroll,
      itemExtent: _itemExtent,
      buildDefaultDragHandles: false,
      itemCount: sections.length,
      onReorderItem: _reorder,
      itemBuilder: (context, i) => _tile(sections[i], i),
    );

    final toolbar = _toolbar(picked);
    final inset = _OrderInset(plan: plan, highlighted: highlighted);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final listColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (_placing)
              MaterialBanner(
                content: const Text('Tap the item they should go after.'),
                actions: [
                  TextButton(
                    onPressed: () => _place(null),
                    child: const Text('To the start'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _placing = false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            Expanded(child: list),
            ?toolbar,
          ],
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: listColumn),
              Expanded(
                flex: 2,
                child: Padding(padding: const EdgeInsets.all(16), child: inset),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: constraints.maxHeight * 0.34,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: inset,
              ),
            ),
            Expanded(child: listColumn),
          ],
        );
      },
    );
  }

  Widget _tile(WalkSection s, int i) {
    final plan = _plan!;
    final first = plan.order[s.start];
    final selected = _selected.contains(first);
    final allOff = Iterable.generate(
      s.end - s.start,
      (k) => plan.order[s.start + k],
    ).every(plan.excluded.contains);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      key: ValueKey('${_level.name}/$first'),
      color: selected
          ? scheme.secondaryContainer
          : i == _top
          ? scheme.surfaceContainerHigh
          : scheme.surface,
      child: InkWell(
        onTap: () {
          if (_placing) {
            if (!selected) _place(s);
            return;
          }
          setState(
            () => selected ? _selected.remove(first) : _selected.add(first),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: _placing
                    ? null
                    : (v) => setState(
                        () => v == true
                            ? _selected.add(first)
                            : _selected.remove(first),
                      ),
              ),
              Expanded(
                child: Opacity(
                  opacity: allOff ? 0.45 : 1,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title(s),
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _subtitle(s),
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              Switch(
                value: !allOff,
                onChanged: _placing ? null : (on) => _toggle(s, on),
              ),
              ReorderableDragStartListener(
                index: i,
                enabled: !_placing,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _toolbar(List<WalkSection> picked) {
    if (picked.isEmpty || _placing) return null;
    final rows = _level == WalkLevel.rows;
    final one = picked.length == 1;
    Widget action(IconData icon, String label, VoidCallback? onTap) =>
        TextButton.icon(onPressed: onTap, icon: Icon(icon), label: Text(label));
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('  ${picked.length} selected  '),
              action(Icons.arrow_upward, 'Up', () => _moveBy(-1)),
              action(Icons.arrow_downward, 'Down', () => _moveBy(1)),
              action(
                Icons.low_priority,
                'Move to…',
                () => setState(() => _placing = true),
              ),
              if (rows) action(Icons.swap_vert, 'Flip', _flip),
              if (rows && one) action(Icons.content_cut, 'Split', _split),
              if (rows && one && _joinable(picked.single))
                action(Icons.merge, 'Join', _join),
              action(
                Icons.visibility_off_outlined,
                'Off',
                () => _include(false),
              ),
              action(Icons.visibility_outlined, 'On', () => _include(true)),
              action(Icons.close, 'Clear', () => setState(_selected.clear)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The whole vineyard, with the walk drawn through it and the current
/// section lit up -- an arrow from where it starts to where it ends.
class _OrderInset extends ConsumerWidget {
  const _OrderInset({required this.plan, required this.highlighted});

  final WalkPlan plan;
  final List<WalkSection> highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot =
        ref.watch(layoutSnapshotProvider).valueOrNull ?? LayoutSnapshot.empty;
    final image = ref.watch(backgroundImageProvider).valueOrNull;
    final lit = {
      for (final s in highlighted) ...plan.order.sublist(s.start, s.end),
    };
    final off = {for (final id in plan.excluded) id: const Color(0xFF555555)};

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: const Color(0xFF1D221E),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final bounds = snapshot.bounds;
            if (bounds.isEmpty) return const SizedBox.expand();
            final scale =
                math.min(
                  size.width / bounds.width,
                  size.height / bounds.height,
                ) *
                0.92;
            final viewport = CanvasViewport(
              scale: scale,
              translation: size.center(Offset.zero) - bounds.center * scale,
              size: Offset.zero & size,
            );
            Offset? at(String id) {
              final p = snapshot.positions[id];
              return p == null ? null : viewport.toScreen(p);
            }

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
                      imageOpacity: 0.6,
                      colors: off,
                      selection: lit,
                    ),
                  ),
                ),
                CustomPaint(
                  painter: _RoutePainter(
                    route: [for (final id in plan.walk) ?at(id)],
                    arrows: [
                      for (final s in highlighted)
                        if ((at(plan.order[s.start]), at(plan.order[s.end - 1]))
                            case (final Offset a, final Offset b))
                          (a, b),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The walk as a faint line from plant to plant, a start marker, and an arrow
/// along each lit section showing which way it is walked.
class _RoutePainter extends CustomPainter {
  _RoutePainter({required this.route, required this.arrows});

  final List<Offset> route;
  final List<(Offset, Offset)> arrows;

  @override
  void paint(Canvas canvas, Size size) {
    if (route.length > 1) {
      final path = Path()..moveTo(route.first.dx, route.first.dy);
      for (final p in route.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.45),
      );
    }
    if (route.isNotEmpty) {
      canvas.drawCircle(route.first, 7, Paint()..color = Colors.black54);
      canvas.drawCircle(route.first, 5, Paint()..color = Colors.white);
    }

    for (final (a, b) in arrows) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4
        ..color = VineyardPainter.selectionColor;
      canvas.drawLine(
        a,
        b,
        Paint()
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..color = Colors.black54,
      );
      canvas.drawLine(a, b, stroke);
      final d = b - a;
      if (d.distance < 1) continue;
      final unit = d / d.distance;
      final side = Offset(-unit.dy, unit.dx);
      final head = Path()
        ..moveTo(b.dx, b.dy)
        ..lineTo((b - unit * 12 + side * 7).dx, (b - unit * 12 + side * 7).dy)
        ..lineTo((b - unit * 12 - side * 7).dx, (b - unit * 12 - side * 7).dy)
        ..close();
      canvas.drawPath(head, Paint()..color = VineyardPainter.selectionColor);
    }
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.route != route || old.arrows != arrows;
}

/// Asks for a walk order's name. Null if cancelled.
///
/// Names in [taken] are refused: two orders with one name would be
/// impossible to tell apart when choosing one.
Future<String?> askWalkOrderName(
  BuildContext context, {
  required String title,
  String initial = '',
  Set<String> taken = const {},
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _NameDialog(title: title, initial: initial, taken: taken),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.taken,
  });

  final String title;
  final String initial;
  final Set<String> taken;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _text = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _name => _text.text.trim();

  bool get _taken => widget.taken.contains(_name);

  bool get _ok => _name.isNotEmpty && !_taken;

  void _submit() {
    if (_ok) Navigator.pop(context, _name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _text,
      autofocus: true,
      decoration: InputDecoration(
        labelText: 'Name',
        hintText: 'e.g. Top terrace first',
        errorText: _taken ? 'There is already a walk order called that' : null,
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _ok ? _submit : null, child: const Text('Save')),
    ],
  );
}
