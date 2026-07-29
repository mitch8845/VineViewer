import 'package:flutter/material.dart';

/// Asks whether inserting a plant should renumber the rest of the line.
///
/// Both options are legitimate and the app cannot tell which is right, so it
/// names the cost of each instead of picking. The shift count is the whole
/// point: "this renames 34 plants" is a decision, "numbers after this point
/// will change" is a shrug.
class RenumberDialog extends StatelessWidget {
  const RenumberDialog({
    super.key,
    required this.affected,
    required this.after,
  });

  final int affected;

  /// What the new plant is going in after, as the user sees it.
  final String after;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Insert a plant'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Placing a plant after $after.'),
          const SizedBox(height: 16),
          Text(
            affected == 0
                // Nothing downstream, so both options do the same thing and
                // offering a choice would be noise.
                ? 'It goes on the end, so nothing is renumbered.'
                : 'Shifting renumbers $affected '
                      '${affected == 1 ? 'plant' : 'plants'} further along. Any '
                      'printed map showing their old numbers will be out of '
                      'date.',
          ),
          if (affected > 0) ...[
            const SizedBox(height: 12),
            const Text(
              'Filling a gap instead renumbers nothing, but the new plant takes '
              'the lowest free number rather than one matching where it sits.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (affected > 0)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Fill a gap'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(affected == 0 ? 'Insert' : 'Shift the rest'),
        ),
      ],
    );
  }
}
