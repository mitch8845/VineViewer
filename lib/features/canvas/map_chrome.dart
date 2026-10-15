/// The controls that float over the map.
///
/// The map is the screen; everything else sits on it in compact panels, so as
/// much of the vineyard as possible stays visible while you work. Separate
/// from `vineyard_screen.dart`, which owns what the gestures *do*, so this file
/// is only about what the screen looks like.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/models/enums.dart';
import '../schema/field_editor_screen.dart';
import 'canvas_controller.dart';
import 'plant_colouring.dart';
import 'vineyard_canvas.dart';

/// A floating surface over the map: rounded, raised, opaque.
class MapSurface extends StatelessWidget {
  const MapSurface({
    super.key,
    required this.child,
    this.radius = 16,
    this.color,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color ?? scheme.surface,
      elevation: 4,
      shadowColor: Colors.black54,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A full-height side panel: the plant inspector's home.
class MapPanel extends StatelessWidget {
  const MapPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MapSurface(radius: 20, child: child);
}

// --------------------------------------------------------------- top bar

/// Back, the vineyard's name and size, undo/redo, layers, and the rest.
class MapTopBar extends StatelessWidget {
  const MapTopBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.undo,
    required this.onLayers,
    required this.layersActive,
    required this.menu,
  });

  final String title;
  final String subtitle;
  final Widget undo;
  final VoidCallback onLayers;

  /// Whether a layer is changed from its default, so the button can say so.
  final bool layersActive;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MapSurface(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Back to vineyards',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _VerticalRule(color: scheme.outlineVariant),
          undo,
          _VerticalRule(color: scheme.outlineVariant),
          IconButton(
            tooltip: 'Map layers',
            isSelected: layersActive,
            icon: const Icon(Icons.layers_outlined),
            selectedIcon: const Icon(Icons.layers),
            onPressed: onLayers,
          ),
          menu,
        ],
      ),
    );
  }
}

class _VerticalRule extends StatelessWidget {
  const _VerticalRule({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 28,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: color,
  );
}

// -------------------------------------------------------------- tool rail

typedef _ToolSpec = ({CanvasTool tool, IconData icon, String label});

/// The tools, grouped by what they are for.
///
/// Vertical down the left edge, where a thumb holding the tablet already is,
/// and where it costs the map width rather than height -- a landscape tablet
/// has width to spare. Ten tools in one undifferentiated row were hard to scan;
/// four labelled groups say what each is for.
class ToolRail extends StatelessWidget {
  const ToolRail({
    super.key,
    required this.active,
    required this.onChanged,
    required this.sticky,
    required this.onToggleSticky,
  });

  final CanvasTool active;
  final ValueChanged<CanvasTool> onChanged;
  final bool sticky;
  final VoidCallback onToggleSticky;

  static const List<({String title, List<_ToolSpec> tools})> _groups = [
    (
      title: 'Select',
      tools: [
        (
          tool: CanvasTool.select,
          icon: Icons.near_me_outlined,
          label: 'Select',
        ),
        (tool: CanvasTool.lasso, icon: Icons.gesture, label: 'Lasso'),
      ],
    ),
    (
      title: 'Plant',
      tools: [
        (
          tool: CanvasTool.placePlant,
          icon: Icons.add_circle_outline,
          label: 'Plant',
        ),
        (
          tool: CanvasTool.insertPlant,
          icon: Icons.playlist_add,
          label: 'Insert',
        ),
        (tool: CanvasTool.pointArray, icon: Icons.more_horiz, label: 'Space'),
      ],
    ),
    (
      title: 'Draw',
      tools: [
        (
          tool: CanvasTool.drawObject,
          icon: Icons.polyline_outlined,
          label: 'Draw',
        ),
        (tool: CanvasTool.array, icon: Icons.view_week_outlined, label: 'Run'),
        (tool: CanvasTool.split, icon: Icons.content_cut, label: 'Split'),
      ],
    ),
    (
      title: 'Edit',
      tools: [
        (tool: CanvasTool.move, icon: Icons.open_with, label: 'Move'),
        (tool: CanvasTool.reshape, icon: Icons.format_shapes, label: 'Reshape'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MapSurface(
      radius: 20,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, group) in _groups.indexed) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 40,
                    child: Divider(height: 1, color: scheme.outlineVariant),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2, top: 2),
                child: Text(
                  group.title.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9.5,
                    letterSpacing: 1.1,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final spec in group.tools)
                _ToolButton(
                  spec: spec,
                  active: spec.tool == active,
                  onTap: () => onChanged(spec.tool),
                ),
              // Sticky select belongs with selecting, not up in a toolbar:
              // it changes what the two tools above it do.
              if (group.title == 'Select')
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Tooltip(
                    message: sticky
                        ? 'Adding to the selection -- tap to replace instead'
                        : 'Add to the selection instead of replacing it',
                    child: _ToolButton(
                      spec: (
                        tool: CanvasTool.select,
                        icon: Icons.library_add_outlined,
                        label: 'Add',
                      ),
                      active: sticky,
                      compact: true,
                      accent: true,
                      onTap: onToggleSticky,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.spec,
    required this.active,
    required this.onTap,
    this.compact = false,
    this.accent = false,
  });

  final _ToolSpec spec;
  final bool active;
  final VoidCallback onTap;
  final bool compact;

  /// A toggle rather than a tool: shown in the secondary colour when on.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = !active
        ? Colors.transparent
        : accent
        ? scheme.secondaryContainer
        : scheme.primaryContainer;
    final foreground = !active
        ? scheme.onSurfaceVariant
        : accent
        ? scheme.onSecondaryContainer
        : scheme.onPrimaryContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          // Large targets: this gets used outdoors, possibly with gloves, and
          // a mis-tap in a drawing tool creates data.
          child: SizedBox(
            width: 62,
            height: compact ? 46 : 54,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(spec.icon, size: compact ? 20 : 23, color: foreground),
                const SizedBox(height: 2),
                Text(
                  spec.label,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- map controls

/// Zoom and fit, bottom right.
class MapControls extends StatelessWidget {
  const MapControls({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MapSurface(
      radius: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Zoom in',
            icon: const Icon(Icons.add),
            onPressed: onZoomIn,
          ),
          SizedBox(
            width: 32,
            child: Divider(height: 1, color: scheme.outlineVariant),
          ),
          IconButton(
            tooltip: 'Zoom out',
            icon: const Icon(Icons.remove),
            onPressed: onZoomOut,
          ),
          SizedBox(
            width: 32,
            child: Divider(height: 1, color: scheme.outlineVariant),
          ),
          IconButton(
            tooltip: 'Fit the whole vineyard',
            icon: const Icon(Icons.fit_screen_outlined),
            onPressed: onFit,
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- banner

/// What the current tool wants, at the top of the map.
///
/// Dark, so it reads over any aerial and is clearly not part of it. The tools
/// that create data need saying out loud: a reshape drag that grabs nothing
/// looks identical to a broken tool otherwise.
class MapBanner extends StatelessWidget {
  const MapBanner({
    super.key,
    required this.icon,
    required this.text,
    this.actions = const [],
  });

  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: MapSurface(
        color: scheme.inverseSurface,
        padding: EdgeInsets.fromLTRB(16, 6, actions.isEmpty ? 16 : 6, 6),
        child: Theme(
          data: Theme.of(context).copyWith(
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: scheme.onInverseSurface,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: scheme.inversePrimary),
              const SizedBox(width: 12),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    text,
                    style: TextStyle(
                      color: scheme.onInverseSurface,
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...[const SizedBox(width: 8), ...actions],
            ],
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------- selection bars

/// A floating bar for what is selected when it is not a single plant: a
/// group of plants, or a drawn object.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    required this.actions,
    required this.onClose,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MapSurface(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ...actions,
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Clear selection',
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// A round badge holding a count or an icon, for the selection bar.
class SelectionBadge extends StatelessWidget {
  const SelectionBadge({super.key, this.text, this.icon, this.color});

  final String? text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = color ?? scheme.primaryContainer;
    final foreground = color == null
        ? scheme.onPrimaryContainer
        : (ThemeData.estimateBrightnessForColor(background) == Brightness.dark
              ? Colors.white
              : Colors.black87);
    return Container(
      constraints: const BoxConstraints(minWidth: 40),
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, color: foreground, size: 20)
          : Text(
              text ?? '',
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
    );
  }
}

// ------------------------------------------------------------------ legend

/// Explains what the plant colours mean.
///
/// Bottom-left beside the tools, clear of the inspector, so both can be read
/// at once -- colouring by health and then tapping the red ones is the whole
/// workflow.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key, required this.colouring, required this.onClose});

  final PlantColouring colouring;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = colouring.legend;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 240,
        maxHeight: MediaQuery.of(context).size.height * 0.45,
      ),
      child: MapSurface(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.palette_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    colouring.fieldName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Stop colouring',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Text('Nothing recorded yet.'),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: entry.color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.black26,
                                  width: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                entry.label,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ layers sheet

/// What the map shows: plant IDs, the aerial, colouring, diagnostics.
///
/// Gathered in one place instead of a row of unlabelled toggles across the
/// top of the screen, each of which had to be learned by its tooltip.
class LayersSheet extends ConsumerWidget {
  const LayersSheet({super.key, required this.hasImage});

  final bool hasImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final showIds = ref.watch(showLabelsProvider);
    final opacity = ref.watch(aerialOpacityProvider);
    final colourBy = ref.watch(colorByFieldProvider);
    final stats = ref.watch(showFrameStatsProvider);
    final fields = [
      for (final f in ref.watch(fieldDefsProvider).valueOrNull ?? <FieldDef>[])
        if (f.role == FieldRole.attribute) f,
    ];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'Map layers',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.label_outline),
              title: const Text('Plant IDs'),
              subtitle: const Text('Shown once you zoom in close enough'),
              value: showIds,
              onChanged: (v) => ref.read(showLabelsProvider.notifier).state = v,
            ),
            ListTile(
              leading: const Icon(Icons.satellite_alt_outlined),
              title: const Text('Aerial photo'),
              subtitle: hasImage
                  ? Slider(
                      value: opacity,
                      divisions: 10,
                      label: '${(opacity * 100).round()}%',
                      onChanged: (v) =>
                          ref.read(aerialOpacityProvider.notifier).state = v,
                    )
                  : const Text('None set -- choose one from the vineyard list'),
              trailing: hasImage ? Text('${(opacity * 100).round()}%') : null,
            ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Colour plants by',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Nothing'),
                    selected: colourBy == null,
                    onSelected: (_) =>
                        ref.read(colorByFieldProvider.notifier).state = null,
                  ),
                  for (final field in fields)
                    ChoiceChip(
                      label: Text(field.name),
                      selected: colourBy == field.id,
                      onSelected: (_) =>
                          ref.read(colorByFieldProvider.notifier).state =
                              field.id,
                    ),
                ],
              ),
            ),
            if (fields.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('Add a field to colour plants by it.'),
              ),
            const Divider(height: 32),
            SwitchListTile(
              secondary: const Icon(Icons.speed_outlined),
              title: const Text('Frame stats'),
              subtitle: const Text('For checking performance on the tablet'),
              value: stats,
              onChanged: (v) =>
                  ref.read(showFrameStatsProvider.notifier).state = v,
            ),
          ],
        ),
      ),
    );
  }
}
