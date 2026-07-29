import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/daos/field_defs_dao.dart';
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
        title: const Text('PlantViewer'),
        actions: [
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
                    trailing: IconButton(
                      tooltip: 'Aerial image',
                      icon: const Icon(Icons.image_outlined),
                      onPressed: () => _chooseAerial(context, ref, project.id),
                    ),
                    onTap: () => _open(context, ref, project.id, project.name),
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

  void _open(BuildContext context, WidgetRef ref, String id, String name) {
    ref.read(activeProjectIdProvider.notifier).state = id;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VineyardScreen(projectName: name),
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

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            onPressed: () => _seedDemo(ref),
            icon: const Icon(Icons.science_outlined),
            label: const Text('Create 4,000-plant test vineyard'),
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
    final projects = ref.read(projectsDaoProvider);
    final layout = ref.read(layoutDaoProvider);
    final fields = ref.read(fieldDefsDaoProvider);

    final projectId = await projects.create(name: 'Performance test');

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
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New vineyard'),
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
          child: const Text('Create'),
        ),
      ],
    );
  }
}
