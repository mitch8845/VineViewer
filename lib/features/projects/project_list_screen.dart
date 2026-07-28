import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geometry/polyline.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/vineyard_screen.dart';
import '../updater/update_button.dart';

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

    await ref.read(projectsDaoProvider).create(name: name.trim());
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
            label: const Text('Create 4,000-vine test vineyard'),
          ),
        ],
      ),
    );
  }

  Future<void> _seedDemo(WidgetRef ref) async {
    final projects = ref.read(projectsDaoProvider);
    final layout = ref.read(layoutDaoProvider);

    final projectId = await projects.create(name: 'Performance test');
    final blockId = await layout.createBlock(projectId: projectId, label: '1');

    // Mirrors the real vineyard's shape: 75 rows of wildly varying length
    // (9-72 vines), not a uniform grid. A uniform grid would flatter the
    // spatial index and hide clustering costs.
    final random = math.Random(42);
    var placed = 0;
    for (var r = 0; r < 75 && placed < 4000; r++) {
      final count = math.min(9 + random.nextInt(64), 4000 - placed);
      final y = 100.0 + r * 45;
      final path = Polyline([Offset(100, y), Offset(100 + count * 14.0, y)]);

      final rowId = await layout.createRow(
        projectId: projectId,
        label: '${r + 1}',
        blockId: blockId,
        path: path,
      );
      await layout.placeVinesAlongRow(
        rowId: rowId,
        offsets: [for (var i = 0; i < count; i++) i * 14.0],
      );
      placed += count;
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

/// Picks an aerial image and records its pixel dimensions.
///
/// Dimensions are stored rather than read on demand because every coordinate
/// in the project lives in this image's pixel space, and the canvas needs them
/// before the image itself has finished decoding.
Future<void> pickProjectImage(WidgetRef ref, String projectId) async {
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    withData: false,
  );
  final path = result?.files.single.path;
  if (path == null) return;

  int? width;
  int? height;
  try {
    final codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
    );
    final frame = await codec.getNextFrame();
    width = frame.image.width;
    height = frame.image.height;
    // Only the dimensions are wanted here; the canvas decodes its own copy.
    frame.image.dispose();
  } catch (_) {
    // An unreadable image still gets recorded, so the path is visible and the
    // user can see what went wrong rather than the pick silently doing nothing.
  }

  await ref
      .read(projectsDaoProvider)
      .setImage(projectId, imagePath: path, width: width, height: height);
}
