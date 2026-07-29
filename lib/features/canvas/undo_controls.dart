import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/undo_service.dart';
import '../../core/providers.dart';
import 'canvas_controller.dart';

/// Whether undo and redo are currently available, and for what.
///
/// A stream rather than a future: the buttons have to light up the moment an
/// edit lands, and every edit writes to `operations`, which drift watches.
final undoAvailabilityProvider = StreamProvider<UndoAvailability>((ref) {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return Stream.value(UndoAvailability.none);
  return ref.watch(undoServiceProvider).watch(projectId);
});

/// Undo and redo, for the map screen's app bar.
class UndoControls extends ConsumerWidget {
  const UndoControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available =
        ref.watch(undoAvailabilityProvider).valueOrNull ??
        UndoAvailability.none;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          // The description names the gesture rather than the table it touched:
          // "Delete row 12 (40 plants)", not "revert 41 rows".
          tooltip: available.canUndo
              ? 'Undo: ${available.undo!.description}'
              : 'Nothing to undo',
          icon: const Icon(Icons.undo),
          onPressed: available.canUndo
              ? () => _run(context, ref, undo: true)
              : null,
        ),
        IconButton(
          tooltip: available.canRedo
              ? 'Redo: ${available.redo!.description}'
              : 'Nothing to redo',
          icon: const Icon(Icons.redo),
          onPressed: available.canRedo
              ? () => _run(context, ref, undo: false)
              : null,
        ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref, {
    required bool undo,
  }) async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final service = ref.read(undoServiceProvider);
    final operation = undo
        ? await service.undo(projectId)
        : await service.redo(projectId);
    if (operation == null || !context.mounted) return;

    // Undo is silent otherwise. On a 3,000-plant map an operation can easily
    // change something off screen, and a button that appears to do nothing is
    // one the user stops trusting.
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('${undo ? 'Undid' : 'Redid'} ${operation.description}'),
        ),
      );
  }
}
