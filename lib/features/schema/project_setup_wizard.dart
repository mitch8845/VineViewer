import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/providers.dart';
import 'field_editor_screen.dart';
import 'identifier_template_editor.dart';

/// First-run setup for a new vineyard.
///
/// There is a required order here, which is why a wizard exists at all: the
/// identifier is composed from fields, so the fields have to exist before it
/// can name them. Everything is reachable afterwards from the fields screen --
/// this is a convenience, not the only path, and every step can be skipped.
class ProjectSetupWizard extends ConsumerStatefulWidget {
  const ProjectSetupWizard({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectSetupWizard> createState() => _ProjectSetupWizardState();
}

class _ProjectSetupWizardState extends ConsumerState<ProjectSetupWizard> {
  int _step = 0;

  /// Objects the user has chosen to create, before they are written.
  final _objects = <_ObjectDraft>[
    // Offered rather than imposed. Most vineyards want both, and a user who
    // wants neither unticks them -- "want neither, get neither" has to be true.
    _ObjectDraft(name: 'Row', drawType: DrawType.polyline, container: true),
    _ObjectDraft(name: 'Block', drawType: DrawType.polygon, container: true),
  ];

  bool _working = false;

  Future<void> _createObjects() async {
    setState(() => _working = true);
    final dao = ref.read(fieldDefsDaoProvider);

    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: widget.projectId,
          kind: 'setup_objects',
          description: 'Set up map objects',
          body: () async {
            for (final draft in _objects) {
              if (!draft.wanted || draft.name.trim().isEmpty) continue;
              await dao.create(
                projectId: widget.projectId,
                name: draft.name.trim(),
                // An object's value is its name, and names are text.
                type: FieldType.text,
                role: FieldRole.object,
                drawType: draft.drawType,
                isContainer: draft.container,
                blankPlaceholder: draft.container ? '0' : null,
              );
            }
          },
        );

    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up this vineyard'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Skip for now'),
          ),
        ],
      ),
      body: Stepper(
        currentStep: _step,
        onStepContinue: () async {
          // Captured before the await, so the analyzer can see it is not a
          // BuildContext reached across the gap.
          final navigator = Navigator.of(context);
          if (_step == 0) await _createObjects();
          if (!mounted) return;
          if (_step < 2) {
            setState(() => _step++);
          } else {
            navigator.pop();
          }
        },
        onStepCancel: _step == 0 ? null : () => setState(() => _step--),
        controlsBuilder: (context, details) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            children: [
              FilledButton(
                onPressed: _working ? null : details.onStepContinue,
                child: Text(_step == 2 ? 'Done' : 'Next'),
              ),
              const SizedBox(width: 8),
              if (details.onStepCancel != null)
                TextButton(
                  onPressed: details.onStepCancel,
                  child: const Text('Back'),
                ),
            ],
          ),
        ),
        steps: [
          Step(
            title: const Text('What do you draw?'),
            isActive: _step >= 0,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nothing is built in except the plant. Rows and blocks exist '
                  'only because you say so -- and you can add terraces, roads '
                  'or posts later just as easily.',
                ),
                const SizedBox(height: 16),
                for (final draft in _objects)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: draft.wanted,
                    onChanged: (v) =>
                        setState(() => draft.wanted = v ?? draft.wanted),
                    title: Text(draft.name),
                    subtitle: Text(
                      draft.drawType == DrawType.polyline
                          ? 'A line. Plants sit along it.'
                          : 'An area. Plants inside belong to it.',
                    ),
                  ),
              ],
            ),
          ),
          Step(
            title: const Text('What do you record?'),
            isActive: _step >= 1,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Health, variety, clone, spray dates -- anything you want to '
                  'note about a plant. You can add these at any time, so there '
                  'is no need to decide now.',
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FieldListScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.list_alt),
                  label: const Text('Add fields'),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('What is a plant called?'),
            isActive: _step >= 2,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pick which parts make up a plant ID and what goes between '
                  'them. Block, then Row, then the plant number, joined by a '
                  'dot gives 3.12.7 -- but it is entirely up to you.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'This comes last because an ID is built from the things '
                  'above, so they have to exist first.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const IdentifierTemplateEditor(),
                    ),
                  ),
                  icon: const Icon(Icons.tag),
                  label: const Text('Choose the ID format'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One object the wizard offers to create.
class _ObjectDraft {
  _ObjectDraft({
    required this.name,
    required this.drawType,
    required this.container,
  });

  final String name;
  final DrawType drawType;
  final bool container;
  bool wanted = true;
}
