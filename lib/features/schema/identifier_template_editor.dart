import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/label_service.dart';
import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/identifier_template.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/tools/identifier_change_prompt.dart';

/// Composes what a plant is called.
///
/// v2 hardcoded `block.row.plant`. Here you pick the parts and the character
/// between them, and see the result against a real plant from the project --
/// a template is far easier to judge as `3.12.7` than as a list of field names.
class IdentifierTemplateEditor extends ConsumerStatefulWidget {
  const IdentifierTemplateEditor({super.key});

  @override
  ConsumerState<IdentifierTemplateEditor> createState() =>
      _IdentifierTemplateEditorState();
}

class _IdentifierTemplateEditorState
    extends ConsumerState<IdentifierTemplateEditor> {
  final _delimiter = TextEditingController(text: '.');
  List<IdPart> _parts = const [];

  /// Fields that may be parts, and what to call them.
  List<FieldDef> _available = const [];

  /// Everything needed to render a preview, fetched once.
  IdentifierData? _data;

  bool _loading = true;
  String? _refusal;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _delimiter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final labels = ref.read(labelServiceProvider);
    final template = await labels.templateFor(projectId);
    final fields = await ref.read(fieldDefsDaoProvider).forProject(projectId);
    final data = await labels.dataFor(projectId);

    if (!mounted) return;
    setState(() {
      _delimiter.text = template.delimiter;
      _parts = [...template.parts];
      // Only container objects and attributes can be parts. A road is drawn but
      // holds no plants, so there is nothing for it to contribute -- it has a
      // name and no composed identifier.
      _available = [
        for (final f in fields)
          if (f.role == FieldRole.attribute || f.isContainer) f,
      ];
      _data = data;
      _loading = false;
    });
  }

  IdentifierTemplate get _template =>
      IdentifierTemplate(delimiter: _delimiter.text, parts: _parts);

  String _nameOf(IdPart part) => switch (part) {
    PlantPart() => 'Plant number',
    FieldPart(:final fieldDefId) =>
      _available
              .where((f) => f.id == fieldDefId)
              .map((f) => f.name)
              .firstOrNull ??
          'a deleted field',
  };

  /// The template rendered against a real plant, or null if there are none yet.
  String? get _preview {
    final data = _data;
    if (data == null || data.plantNumbers.isEmpty) return null;
    final rendered = LabelService.render(data, _template);
    return rendered[data.plantNumbers.keys.first]?.text;
  }

  Future<void> _save() async {
    final projectId = ref.read(activeProjectIdProvider);
    final data = _data;
    if (projectId == null || data == null) return;

    final labels = ref.read(labelServiceProvider);
    final current = await labels.templateFor(projectId);

    // Rendered under both templates and compared before anything is written.
    // This is the whole reason fetching and rendering are separate.
    final change = LabelService.compare(
      LabelService.render(data, current),
      LabelService.render(data, _template),
    );

    // Kept inline as well as in the dialog: this screen has room to show the
    // refusal next to the template that caused it, which a dismissed dialog
    // cannot do.
    if (!change.isSafe) {
      setState(
        () => _refusal =
            'That would give ${change.duplicates.length} '
            '${change.duplicates.length == 1 ? 'identifier' : 'identifiers'} '
            'to more than one plant: ${change.duplicates.take(3).join(', ')}'
            '${change.duplicates.length > 3 ? '...' : ''}. '
            'Add a part that tells them apart.',
      );
      return;
    }

    if (!mounted) return;
    final ok = await confirmIdentifierChange(
      context,
      change: change,
      action: 'Change plant IDs',
      refusalAdvice: 'Add a part that tells them apart.',
    );
    if (!ok || !mounted) return;
    await ref
        .read(operationRecorderProvider)
        .run(
          projectId: projectId,
          kind: 'set_identifier',
          description: 'Change plant ID format',
          body: () => ref
              .read(projectsDaoProvider)
              .setIdentifierTemplate(projectId, _template),
        );

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final preview = _preview;
    final used = {
      for (final p in _parts)
        if (p is FieldPart) p.fieldDefId,
    };
    final unused = [
      for (final f in _available)
        if (!used.contains(f.id)) f,
    ];
    final hasPlant = _parts.any((p) => p is PlantPart);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plant ID format'),
        actions: [
          TextButton(
            onPressed: _parts.isEmpty ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('A plant will look like'),
                  const SizedBox(height: 8),
                  Text(
                    preview ?? _parts.map(_nameOf).join(_delimiter.text),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (preview == null) ...[
                    const SizedBox(height: 4),
                    const Text(
                      'No plants drawn yet, so this shows the parts rather '
                      'than a real ID.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Text(
            'Parts, in order',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // onReorderItem, not onReorder: it hands back an index already
            // corrected for the removed item, so the usual off-by-one dance is
            // not only unnecessary here but wrong.
            onReorderItem: (from, to) => setState(() {
              _parts = [..._parts];
              _parts.insert(to, _parts.removeAt(from));
              _refusal = null;
            }),
            children: [
              for (final part in _parts)
                ListTile(
                  key: ValueKey(part),
                  leading: const Icon(Icons.drag_handle),
                  title: Text(_nameOf(part)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _parts = [..._parts]..remove(part);
                      _refusal = null;
                    }),
                  ),
                ),
            ],
          ),
          if (_parts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Add at least one part.'),
            ),

          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (!hasPlant)
                ActionChip(
                  avatar: const Icon(Icons.tag, size: 18),
                  label: const Text('Plant number'),
                  onPressed: () => setState(() {
                    _parts = [..._parts, const PlantPart()];
                    _refusal = null;
                  }),
                ),
              for (final field in unused)
                ActionChip(
                  avatar: Icon(
                    field.isContainer ? Icons.gesture : Icons.notes,
                    size: 18,
                  ),
                  label: Text(field.name),
                  onPressed: () => setState(() {
                    _parts = [..._parts, FieldPart(field.id)];
                    _refusal = null;
                  }),
                ),
            ],
          ),

          const SizedBox(height: 24),
          TextField(
            controller: _delimiter,
            decoration: const InputDecoration(
              labelText: 'Between the parts',
              helperText: 'A dot gives 3.12.7. An ampersand gives 3&12&7.',
            ),
            maxLength: 3,
            onChanged: (_) => setState(() => _refusal = null),
          ),

          if (_refusal != null) ...[
            const SizedBox(height: 8),
            Text(
              _refusal!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
