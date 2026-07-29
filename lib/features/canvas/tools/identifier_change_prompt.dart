import 'package:flutter/material.dart';

import '../../../core/data/label_service.dart';

/// Puts an identifier change to the user before it is written.
///
/// **Four different actions can rename a plant, and only one of them is about
/// naming:**
///
///  * editing the identifier template,
///  * renaming a drawn object -- every plant it holds, and none of them moved,
///  * dragging a boundary so a plant falls inside a different block,
///  * changing an attribute that is part of the identifier.
///
/// All four went through their own ad-hoc handling or, for three of them, none
/// at all. One function instead, so the answer cannot differ by route: a
/// collision is **refused**, a rename is **counted and confirmed**, and a change
/// that renames nothing proceeds without a dialog nobody needed.
///
/// Returns true to go ahead. Refusal returns false and never offers an override
/// -- duplicate identifiers are the one thing this app will not store, because
/// two plants called `3.12.7` makes every record naming that plant worthless.
Future<bool> confirmIdentifierChange(
  BuildContext context, {
  required IdentifierChange change,

  /// What the user is doing, as a title: "Rename Row 12".
  required String action,

  /// The button that goes ahead, e.g. "Rename them".
  String proceedLabel = 'Rename them',

  /// Appended to the refusal, naming the way out. The way out differs by route
  /// -- a different name, a different boundary, a different template -- and a
  /// refusal that does not say what to do instead is just a wall.
  String? refusalAdvice,
}) async {
  if (!change.isSafe) {
    final duplicates = change.duplicates;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('That would give two plants the same ID'),
        content: Text(
          '${duplicates.length} '
          '${duplicates.length == 1 ? 'identifier' : 'identifiers'} would be '
          'held by more than one plant: ${duplicates.take(4).join(', ')}'
          '${duplicates.length > 4 ? '...' : ''}.'
          '\n\nNothing was changed.'
          '${refusalAdvice == null ? '' : '\n\n$refusalAdvice'}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  // Nothing reads differently afterwards, so there is nothing to confirm.
  // Renaming a road no identifier mentions lands in here, and should.
  if (change.changed == 0) return true;

  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(action),
      content: Text(
        'This renames ${change.changed} '
        '${change.changed == 1 ? 'plant' : 'plants'}.\n\n'
        'Their old IDs stay searchable in each plant\'s history, so a paper '
        'record from an earlier season can still be matched up.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(proceedLabel),
        ),
      ],
    ),
  );
  return proceed == true;
}
