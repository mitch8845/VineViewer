import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/daos/field_defs_dao.dart';
import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../../core/models/field_config.dart';
import '../../core/providers.dart';
import '../canvas/canvas_controller.dart';

/// Live list of field definitions for the active project.
final fieldDefsProvider = StreamProvider<List<FieldDef>>((ref) {
  final projectId = ref.watch(activeProjectIdProvider);
  if (projectId == null) return Stream.value(const []);
  return ref.watch(fieldDefsDaoProvider).watchForProject(projectId);
});

/// Manages what can be recorded about a vine.
class FieldListScreen extends ConsumerWidget {
  const FieldListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = ref.watch(fieldDefsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Fields')),
      body: fields.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No fields yet.\n\nA field is anything you want to record '
                    'about a vine: variety, health, spray date.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => _FieldTile(field: list[i]),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('New field'),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    FieldDef? existing,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _FieldEditorSheet(existing: existing),
    );
  }
}

class _FieldTile extends ConsumerWidget {
  const _FieldTile({required this.field});

  final FieldDef field;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.read(fieldDefsDaoProvider).configOf(field);

    return ListTile(
      title: Text(field.name),
      subtitle: Text(
        [
          field.type.name,
          if (field.isStatic) 'static (write-once)',
          if (config.options.isNotEmpty) '${config.options.length} options',
        ].join(' · '),
      ),
      leading: _TypeIcon(type: field.type, config: config),
      trailing: IconButton(
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (context) => _FieldEditorSheet(existing: field),
        ),
      ),
    );
  }
}

class _TypeIcon extends StatelessWidget {
  const _TypeIcon({required this.type, required this.config});

  final FieldType type;
  final FieldConfig config;

  @override
  Widget build(BuildContext context) {
    // A categorical field with colours shows them, since that is the whole
    // point of configuring them -- the map is coloured by these.
    if (config.optionColors.isNotEmpty) {
      final colours = config.options
          .map((o) => _parseColor(config.optionColors[o]))
          .whereType<Color>()
          .take(4)
          .toList();
      if (colours.isNotEmpty) {
        return SizedBox(
          width: 40,
          height: 40,
          child: Wrap(
            children: [
              for (final c in colours)
                Container(width: 20, height: 20, color: c),
            ],
          ),
        );
      }
    }

    return Icon(switch (type) {
      FieldType.text => Icons.notes,
      FieldType.integer || FieldType.decimal => Icons.numbers,
      FieldType.boolean => Icons.check_box_outlined,
      FieldType.date || FieldType.datetime => Icons.event,
      FieldType.categorical => Icons.category_outlined,
      FieldType.multiSelect => Icons.checklist,
      FieldType.rating => Icons.star_outline,
    });
  }
}

/// Parses `#RRGGBB` into a Color, tolerating junk.
Color? _parseColor(String? hex) {
  if (hex == null) return null;
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

String _toHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Creates or edits a field definition.
class _FieldEditorSheet extends ConsumerStatefulWidget {
  const _FieldEditorSheet({this.existing});

  final FieldDef? existing;

  @override
  ConsumerState<_FieldEditorSheet> createState() => _FieldEditorSheetState();
}

class _FieldEditorSheetState extends ConsumerState<_FieldEditorSheet> {
  late final TextEditingController _name;
  late FieldType _type;
  late bool _isStatic;
  late List<String> _options;
  late Map<String, String> _optionColors;
  final _optionInput = TextEditingController();
  List<String> _problems = const [];

  bool get _isNew => widget.existing == null;

  /// Swatches rather than a full colour picker: these are read outdoors at a
  /// glance, so distinguishable beats precise, and a wheel is fiddly with a
  /// finger.
  static const _swatches = [
    Color(0xFF2E7D32), // green
    Color(0xFF66BB6A), // light green
    Color(0xFFFBC02D), // amber
    Color(0xFFEF6C00), // orange
    Color(0xFFD32F2F), // red
    Color(0xFF6A1B9A), // purple
    Color(0xFF1565C0), // blue
    Color(0xFF546E7A), // grey
  ];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _type = existing?.type ?? FieldType.categorical;
    _isStatic = existing?.isStatic ?? false;

    final config = existing == null
        ? FieldConfig.empty
        : FieldConfig.parse(existing.config);
    _options = [...config.options];
    _optionColors = {...config.optionColors};
  }

  @override
  void dispose() {
    _name.dispose();
    _optionInput.dispose();
    super.dispose();
  }

  FieldConfig get _config => FieldConfig(
    options: _options,
    optionColors: _optionColors,
  );

  Future<void> _save() async {
    final dao = ref.read(fieldDefsDaoProvider);
    final projectId = ref.read(activeProjectIdProvider);
    if (projectId == null) return;

    final result = _isNew
        ? await dao.create(
            projectId: projectId,
            name: _name.text,
            type: _type,
            isStatic: _isStatic,
            config: _config,
          )
        // Type is deliberately not passed: it is immutable once created (D5),
        // and the editor disables the control rather than offering something
        // that would throw.
        : await dao.update(
            widget.existing!.id,
            name: _name.text,
            isStatic: _isStatic,
            config: _config,
          );

    switch (result) {
      case FieldDefInvalid(:final problems):
        setState(() => _problems = problems);
      case FieldDefSaved():
        if (mounted) Navigator.pop(context);
    }
  }

  void _addOption() {
    final value = _optionInput.text.trim();
    if (value.isEmpty || _options.contains(value)) return;
    setState(() {
      _options = [..._options, value];
      // Cycle the swatches so a new option is never invisible against the
      // previous one.
      _optionColors[value] = _toHex(
        _swatches[(_options.length - 1) % _swatches.length],
      );
      _optionInput.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isNew ? 'New field' : 'Edit ${widget.existing!.name}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'Import matches spreadsheet columns to this name',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<FieldType>(
              initialValue: _type,
              decoration: InputDecoration(
                labelText: 'Type',
                helperText: _isNew
                    ? null
                    : 'Type cannot be changed once a field exists',
              ),
              // D5: changing a type would reinterpret every value already
              // recorded. The supported path is a new field.
              onChanged: _isNew
                  ? (t) => setState(() => _type = t ?? _type)
                  : null,
              items: [
                for (final type in FieldType.values)
                  DropdownMenuItem(value: type, child: Text(type.name)),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isStatic,
              onChanged: (v) => setState(() => _isStatic = v),
              title: const Text('Write-once'),
              subtitle: const Text(
                'For facts that do not change: variety, rootstock, plant date',
              ),
            ),
            if (_type.hasOptions) ...[
              const Divider(height: 32),
              Text(
                'Options',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Text(
                'Each option gets a colour, which is what colours the map.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              for (final option in _options)
                _OptionRow(
                  option: option,
                  color: _parseColor(_optionColors[option]),
                  swatches: _swatches,
                  onColor: (c) =>
                      setState(() => _optionColors[option] = _toHex(c)),
                  onDelete: () => setState(() {
                    _options = _options.where((o) => o != option).toList();
                    _optionColors.remove(option);
                  }),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _optionInput,
                      decoration: const InputDecoration(
                        labelText: 'Add an option',
                      ),
                      onSubmitted: (_) => _addOption(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _addOption,
                  ),
                ],
              ),
            ],
            if (_problems.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final problem in _problems)
                Text(
                  problem,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _save,
                  child: Text(_isNew ? 'Create' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.color,
    required this.swatches,
    required this.onColor,
    required this.onDelete,
  });

  final String option;
  final Color? color;
  final List<Color> swatches;
  final ValueChanged<Color> onColor;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(option)),
          for (final swatch in swatches)
            GestureDetector(
              onTap: () => onColor(swatch),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: swatch.toARGB32() == color?.toARGB32()
                      ? Border.all(width: 3)
                      : null,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
