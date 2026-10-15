import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/daos/field_defs_dao.dart';
import '../../core/db/database.dart';
import '../../core/geometry/polyline.dart';
import '../../core/geometry/shapes.dart';
import '../../core/models/enums.dart';
import '../../core/models/identifier_template.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/vineyard_screen.dart';
import '../schema/project_setup_wizard.dart';
import '../updater/update_button.dart';
import 'aerial_image.dart';

/// Project picker: the app's entry point.
class ProjectListScreen extends ConsumerWidget {
  const ProjectListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('VineViewer'),
        actions: [
          IconButton(
            tooltip: 'Deleted vineyards',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const _TrashScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Check for updates',
            icon: const Icon(Icons.system_update),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => const AlertDialog(
                content: SizedBox(
                  width: 320,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: UpdateButton(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: projects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load projects: $e')),
        data: (list) => list.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final project = list[i];
                  return ListTile(
                    leading: const Icon(Icons.grass),
                    title: Text(project.name),
                    subtitle: Text(
                      project.imagePath == null
                          ? 'No aerial image'
                          : 'Image ${project.imageWidth}x${project.imageHeight}',
                    ),
                    trailing: PopupMenuButton<_ProjectAction>(
                      tooltip: 'More',
                      onSelected: (action) => switch (action) {
                        _ProjectAction.image => _chooseAerial(
                          context,
                          ref,
                          project.id,
                        ),
                        _ProjectAction.rename => _rename(context, ref, project),
                        _ProjectAction.delete => _delete(context, ref, project),
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _ProjectAction.image,
                          child: ListTile(
                            leading: Icon(Icons.image_outlined),
                            title: Text('Aerial image'),
                          ),
                        ),
                        PopupMenuItem(
                          value: _ProjectAction.rename,
                          child: ListTile(
                            leading: Icon(Icons.drive_file_rename_outline),
                            title: Text('Rename'),
                          ),
                        ),
                        PopupMenuItem(
                          value: _ProjectAction.delete,
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('Delete'),
                          ),
                        ),
                      ],
                    ),
                    onTap: () => _open(context, ref, project.id),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createProject(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New vineyard'),
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, String id) {
    resetProjectScopedState(ref);
    ref.read(activeProjectIdProvider.notifier).state = id;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const VineyardScreen()));
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    Project project,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(
        title: 'Rename vineyard',
        action: 'Rename',
        initial: project.name,
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == project.name) {
      return;
    }
    await ref.read(projectsDaoProvider).rename(project.id, name);
  }

  /// Moves a vineyard to the trash.
  ///
  /// Soft, and said so: the plan reserves typed confirmation for *permanent*
  /// deletion, which only happens from the trash. Here a plain confirm is
  /// enough, because nothing is lost -- and an undo is offered on the spot.
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Project project,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${project.name}"?'),
        content: const Text(
          'It moves to Deleted vineyards, where it can be restored with all '
          'of its plants and history.',
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
    if (ok != true || !context.mounted) return;

    final dao = ref.read(projectsDaoProvider);
    await dao.softDelete(project.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${project.name}".'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => dao.restore(project.id),
          ),
        ),
      );
  }

  Future<void> _createProject(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;

    final id = await ref.read(projectsDaoProvider).create(name: name.trim());
    if (!context.mounted) return;
    resetProjectScopedState(ref);

    // Straight into setup: the identifier is composed from fields, so there is
    // an order to this that a new project cannot discover on its own. Every
    // step is skippable, and all of it is reachable later from the fields
    // screen.
    ref.read(activeProjectIdProvider.notifier).state = id;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectSetupWizard(projectId: id),
      ),
    );
  }

  /// Offers the bundled aerial or a photo from the device.
  ///
  /// The bundled one is listed first: for Five Sisters it is the right answer,
  /// and it works with no file system to navigate.
  Future<void> _chooseAerial(
    BuildContext context,
    WidgetRef ref,
    String projectId,
  ) async {
    final fromDevice = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.grass),
              title: const Text('Five Sisters aerial'),
              subtitle: const Text('The photo that ships with the app'),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              subtitle: const Text('A newer aerial, or another vineyard'),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (fromDevice == null || !context.mounted) return;

    try {
      if (fromDevice) {
        // False means the user backed out of the system picker, which is not
        // worth a message.
        if (!await pickAerialImage(ref, projectId)) return;
      } else {
        await installSampleAerial(ref, projectId);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not set the image: $e')));
    }
  }
}

class _EmptyState extends ConsumerStatefulWidget {
  const _EmptyState();

  @override
  ConsumerState<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends ConsumerState<_EmptyState> {
  /// Set while seeding. Building 4,000 plants takes seconds on the tablet, and
  /// with no feedback a second tap built a second vineyard.
  bool _seeding = false;

  Future<void> _seed() async {
    if (_seeding) return;
    setState(() => _seeding = true);
    try {
      await _seedDemo(ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not build the test vineyard: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _seeding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.grass, size: 64),
          const SizedBox(height: 12),
          const Text('No vineyards yet.'),
          const SizedBox(height: 24),
          // The performance gate needs a layout at realistic scale long before
          // anyone has drawn one by hand, so seeding is a first-class action
          // rather than a hidden debug flag.
          OutlinedButton.icon(
            onPressed: _seeding ? null : _seed,
            icon: _seeding
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science_outlined),
            label: Text(
              _seeding
                  ? 'Building 4,000 plants...'
                  : 'Create 4,000-plant test vineyard',
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a realistic 4,000-plant vineyard for the performance gate.
  ///
  /// Sets up the v3 model from scratch -- a Row field, a Block field, and the
  /// `Block.Row.Plant` template -- so the seeded project exercises exactly what
  /// a hand-drawn one would, including identifier rendering and containment.
  Future<void> _seedDemo(WidgetRef ref) async {
    final projectId = await ref
        .read(projectsDaoProvider)
        .create(name: 'Performance test');

    // One operation, so the whole layout is one press of undo -- the plan's
    // undo stress test is exactly this, and it was not journaled at all.
    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'seed_demo',
          description: 'Build the 4,000-plant test layout',
          body: () => _seedLayout(ref, projectId),
        );
  }

  Future<void> _seedLayout(WidgetRef ref, String projectId) async {
    final projects = ref.read(projectsDaoProvider);
    final layout = ref.read(layoutDaoProvider);
    final fields = ref.read(fieldDefsDaoProvider);

    final rowField = await fields.create(
      projectId: projectId,
      name: 'Row',
      type: FieldType.text,
      role: FieldRole.object,
      drawType: DrawType.polyline,
      isContainer: true,
      blankPlaceholder: '0',
    );
    final blockField = await fields.create(
      projectId: projectId,
      name: 'Block',
      type: FieldType.text,
      role: FieldRole.object,
      drawType: DrawType.polygon,
      isContainer: true,
      blankPlaceholder: '0',
    );
    if (rowField is! FieldDefSaved || blockField is! FieldDefSaved) return;

    await projects.setIdentifierTemplate(
      projectId,
      IdentifierTemplate(
        delimiter: '.',
        parts: [
          FieldPart(blockField.id),
          FieldPart(rowField.id),
          const PlantPart(),
        ],
      ),
    );

    // Rows of wildly varying length (9-72 plants), not a uniform grid: a grid
    // would flatter the spatial index and hide the cost of clustering.
    //
    // **Rows are added until 4,000 plants are placed**, however many that takes.
    // An earlier version capped it at 75 rows to mirror the real vineyard, which
    // averaged ~40 plants a row and so produced about 3,030 -- a button labelled
    // "4,000-plant" that quietly built three-quarters of one. The gate is meant
    // to have headroom over the real 3,025, so the count is what matters and the
    // row total follows from it.
    const target = 4000;
    final random = math.Random(42);
    final rows = <({double y, int count})>[];
    var placed = 0;
    while (placed < target) {
      final count = math.min(9 + random.nextInt(64), target - placed);
      rows.add((y: 100.0 + rows.length * 45, count: count));
      placed += count;
    }

    // One block around the lot, so every plant has a container value and the
    // identifier has all three parts to render.
    final widest = rows.fold(0.0, (w, r) => math.max(w, r.count * 14.0));
    await layout.createObject(
      projectId: projectId,
      fieldDefId: blockField.id,
      label: '1',
      geometry: PolygonShape([
        const Offset(50, 50),
        Offset(150 + widest, 50),
        Offset(150 + widest, 150 + rows.length * 45),
        Offset(50, 150 + rows.length * 45),
      ]),
    );

    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final carrier = await layout.createObject(
        projectId: projectId,
        fieldDefId: rowField.id,
        label: '${r + 1}',
        geometry: PolylineShape(
          Polyline([Offset(100, row.y), Offset(100 + row.count * 14.0, row.y)]),
        ),
      );
      await layout.placePlantsAlongCarrier(
        carrierId: carrier,
        offsets: [for (var i = 0; i < row.count; i++) i * 14.0],
      );
    }
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    this.title = 'New vineyard',
    this.action = 'Create',
    this.initial = '',
  });

  final String title;
  final String action;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.action),
        ),
      ],
    );
  }
}

enum _ProjectAction { image, rename, delete }

/// Deleted vineyards: restore, or remove for good.
///
/// Permanent removal asks for the name to be typed, as the plan requires. It
/// takes every plant, observation and drawing with it, and it is the one
/// action in the app with no undo.
class _TrashScreen extends ConsumerStatefulWidget {
  const _TrashScreen();

  @override
  ConsumerState<_TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<_TrashScreen> {
  late Future<List<Project>> _deleted = _load();

  Future<List<Project>> _load() => ref.read(projectsDaoProvider).deleted();

  void _reload() => setState(() => _deleted = _load());

  Future<void> _purge(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _PurgeDialog(name: project.name),
    );
    if (confirmed != true) return;
    await ref.read(projectsDaoProvider).purge(project.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deleted vineyards')),
      body: FutureBuilder<List<Project>>(
        future: _deleted,
        builder: (context, snapshot) {
          final list = snapshot.data;
          if (list == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (list.isEmpty) {
            return const Center(child: Text('Nothing has been deleted.'));
          }
          return ListView(
            children: [
              for (final project in list)
                ListTile(
                  leading: const Icon(Icons.grass),
                  title: Text(project.name),
                  subtitle: Text(
                    'Deleted ${_date(project.deletedAt ?? project.updatedAt)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () async {
                          await ref
                              .read(projectsDaoProvider)
                              .restore(project.id);
                          _reload();
                        },
                        child: const Text('Restore'),
                      ),
                      IconButton(
                        tooltip: 'Delete for good',
                        icon: const Icon(Icons.delete_forever_outlined),
                        onPressed: () => _purge(project),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _date(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}

class _PurgeDialog extends StatefulWidget {
  const _PurgeDialog({required this.name});

  final String name;

  @override
  State<_PurgeDialog> createState() => _PurgeDialogState();
}

class _PurgeDialogState extends State<_PurgeDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _typed.text.trim() == widget.name.trim();
    return AlertDialog(
      title: const Text('Delete for good?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Every plant, observation and drawing in "${widget.name}" will be '
            'erased. This cannot be undone.\n\nType the name to confirm.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.name),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: matches ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete for good'),
        ),
      ],
    );
  }
}
