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
import '../../core/format.dart';
import '../../core/models/enums.dart';
import '../schema/field_editor_screen.dart';
import 'canvas_controller.dart';
import 'heatmap.dart';
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
    this.actions = const [],
    this.compact = false,
  });

  /// A phone: no dividers, and the title gives way first.
  final bool compact;

  final String title;
  final String subtitle;
  final Widget undo;
  final VoidCallback onLayers;

  /// Whether a layer is changed from its default, so the button can say so.
  final bool layersActive;
  final Widget menu;

  /// Buttons between undo/redo and Layers.
  final List<Widget> actions;

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
          // Gives way before any button does: on a phone the name is cut
          // short rather than undo or the menu falling off the edge.
          Flexible(
            child: ConstrainedBox(
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
          ),
          SizedBox(width: compact ? 4 : 12),
          if (!compact) _VerticalRule(color: scheme.outlineVariant),
          undo,
          if (!compact) _VerticalRule(color: scheme.outlineVariant),
          ...actions,
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
const List<({String title, List<_ToolSpec> tools})> _toolGroups = [
  (
    title: 'Select',
    tools: [
      (tool: CanvasTool.select, icon: Icons.near_me_outlined, label: 'Select'),
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
      (tool: CanvasTool.insertPlant, icon: Icons.playlist_add, label: 'Insert'),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MapSurface(
      radius: 20,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Divided into groups without headings: every tool is labelled,
            // and the headings were a fifth of the rail's height spent on
            // words that said little more than the dividers do.
            for (final (i, group) in _toolGroups.indexed) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 40,
                    child: Divider(height: 1, color: scheme.outlineVariant),
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

/// The tools where a rail does not fit -- a phone, or a tablet held so the
/// rail would run off the bottom: one button showing the tool in use, which
/// opens all of them as a sheet.
///
/// Every tool is still one tap away from the sheet, and the one in use is
/// always on screen, so it is never a mystery what a tap on the map will do.
class ToolPicker extends StatelessWidget {
  const ToolPicker({
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

  static _ToolSpec _specOf(CanvasTool tool) => [
    for (final g in _toolGroups) ...g.tools,
  ].firstWhere((t) => t.tool == tool);

  Future<void> _open(BuildContext context) async {
    final chosen = await showModalBottomSheet<CanvasTool>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in _toolGroups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(group.title, style: theme.textTheme.titleSmall),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final spec in group.tools)
                        _ToolButton(
                          spec: spec,
                          active: spec.tool == active,
                          wide: true,
                          onTap: () => Navigator.pop(context, spec.tool),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (chosen != null) onChanged(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final selecting = active == CanvasTool.select || active == CanvasTool.lasso;
    return MapSurface(
      radius: 20,
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Tools',
            child: _ToolButton(
              spec: _specOf(active),
              active: true,
              more: true,
              onTap: () => _open(context),
            ),
          ),
          if (selecting)
            _ToolButton(
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
        ],
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
    this.wide = false,
    this.more = false,
  });

  final _ToolSpec spec;
  final bool active;
  final VoidCallback onTap;
  final bool compact;

  /// In the tool sheet, where there is room for whole words.
  final bool wide;

  /// Opens the other tools: marked with a small arrow.
  final bool more;

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
            width: wide ? 84 : 62,
            height: compact ? 46 : (wide ? 64 : 54),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(spec.icon, size: compact ? 20 : 23, color: foreground),
                    if (more)
                      Icon(Icons.arrow_drop_down, size: 16, color: foreground),
                  ],
                ),
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
    this.fitOnly = false,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  /// A phone, where pinching is how anyone zooms: just the way back to the
  /// whole vineyard.
  final bool fitOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MapSurface(
      radius: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!fitOnly) ...[
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
          ],
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
  const MapLegend({
    super.key,
    required this.colouring,
    required this.onClose,
    this.hidden = const {},
    this.onToggle,
    this.onOnly,
    this.onShowAll,
    this.heatmap = false,
    this.onHeatmap,
    this.spread = 6,
    this.onSpread,
    this.timeOpen = false,
    this.onTime,
    this.collapsed = false,
    this.onCollapse,
    this.maxWidth = 260,
    this.showHint = true,
  });

  /// "Tap to hide a value": until the filter has been used once, after which
  /// it is just words in the way.
  final bool showHint;

  /// Folded down to its heading, to give the map back.
  final bool collapsed;
  final VoidCallback? onCollapse;
  final double maxWidth;

  final PlantColouring colouring;
  final VoidCallback onClose;

  /// Showing where the ticked values are concentrated, instead of dots.
  final bool heatmap;
  final VoidCallback? onHeatmap;

  /// The heatmap's reach, in vine spacings.
  final double spread;
  final ValueChanged<double>? onSpread;

  final bool timeOpen;
  final VoidCallback? onTime;

  /// Legend entries the filter is hiding, by label.
  final Set<String> hidden;

  /// Hides or shows one entry's plants.
  final ValueChanged<String>? onToggle;

  /// Shows only one entry's plants -- a long press, for "just the dead ones".
  final ValueChanged<String>? onOnly;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = colouring.legend;
    final total = colouring.keyOf.length;
    final showing =
        total - hidden.fold<int>(0, (n, l) => n + (colouring.counts[l] ?? 0));

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      child: MapSurface(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hidden.isEmpty ? Icons.palette_outlined : Icons.filter_alt,
                  size: 16,
                  color: hidden.isEmpty
                      ? scheme.onSurfaceVariant
                      : scheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: GestureDetector(
                    onTap: onCollapse,
                    child: Text(
                      colouring.fieldName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (onCollapse != null)
                  IconButton(
                    tooltip: collapsed ? 'Show the legend' : 'Fold the legend',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      collapsed ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                    ),
                    onPressed: onCollapse,
                  ),
                if (onTime != null)
                  IconButton(
                    tooltip: 'Look back in time',
                    visualDensity: VisualDensity.compact,
                    isSelected: timeOpen,
                    color: timeOpen ? scheme.primary : null,
                    icon: const Icon(Icons.history, size: 20),
                    onPressed: onTime,
                  ),
                if (onHeatmap != null)
                  IconButton(
                    tooltip: heatmap ? 'Show plants' : 'Heatmap',
                    visualDensity: VisualDensity.compact,
                    isSelected: heatmap,
                    color: heatmap ? scheme.primary : null,
                    icon: Icon(
                      heatmap ? Icons.local_fire_department : Icons.blur_on,
                      size: 20,
                    ),
                    onPressed: onHeatmap,
                  ),
                IconButton(
                  tooltip: 'Stop colouring',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
            if (hidden.isNotEmpty && !collapsed)
              Padding(
                padding: const EdgeInsets.only(right: 6, bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Showing ${groupDigits(showing)} of ${groupDigits(total)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 32),
                      ),
                      onPressed: onShowAll,
                      child: const Text('Show all'),
                    ),
                  ],
                ),
              ),
            if (entries.isEmpty && !collapsed)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Text('Nothing recorded yet.'),
              ),
            if (!collapsed)
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in entries)
                        _LegendRow(
                          entry: entry,
                          count: colouring.counts[entry.label] ?? 0,
                          shown: !hidden.contains(entry.label),
                          onTap: onToggle == null
                              ? null
                              : () => onToggle!(entry.label),
                          onLongPress: onOnly == null
                              ? null
                              : () => onOnly!(entry.label),
                        ),
                    ],
                  ),
                ),
              ),
            if (heatmap && !collapsed) ..._heatKey(context),
            if (onToggle != null &&
                showHint &&
                hidden.isEmpty &&
                entries.length > 1 &&
                !heatmap &&
                !collapsed)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 10),
                child: Text(
                  'Tap to hide a value · hold to show only it',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Under a heatmap: what its colours mean, and how far it spreads.
  List<Widget> _heatKey(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return [
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Text(
          hidden.isEmpty
              ? 'Where values are recorded. Untick values to map only the '
                    'rest — hold one to map only it.'
              : 'Where the ticked values are concentrated.',
          style: small,
        ),
      ),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Container(
          height: 10,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            gradient: LinearGradient(
              colors: [
                for (final s in const [0.0, 0.4, 0.75, 1.0])
                  Color(HeatDensity.colorAt(s)),
              ],
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 10, top: 2),
        child: Row(
          children: [
            Text('A few', style: small),
            const Spacer(),
            Text('Most vines', style: small),
          ],
        ),
      ),
      if (onSpread != null)
        Row(
          children: [
            Text('Spread', style: small),
            Expanded(
              child: Slider(
                value: spread,
                min: 2,
                max: 20,
                divisions: 18,
                label: '${spread.round()} vines',
                onChanged: onSpread,
              ),
            ),
          ],
        ),
    ];
  }
}

/// One legend entry, doubling as its filter checkbox.
class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.entry,
    required this.count,
    required this.shown,
    this.onTap,
    this.onLongPress,
  });

  final LegendEntry entry;
  final int count;
  final bool shown;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final faded = shown ? 1.0 : 0.45;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        // Tall enough to hit with a thumb: this is a control now, not a key.
        padding: const EdgeInsets.fromLTRB(0, 5, 8, 5),
        child: Row(
          children: [
            Icon(
              shown ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: shown ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Opacity(
              opacity: faded,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: entry.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black26),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: shown ? null : scheme.onSurfaceVariant,
                  decoration: shown ? null : TextDecoration.lineThrough,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              groupDigits(count),
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
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
            if (colourBy != null) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                secondary: const Icon(Icons.local_fire_department_outlined),
                title: const Text('Heatmap'),
                subtitle: const Text(
                  'Where values are concentrated, instead of plant dots',
                ),
                value: ref.watch(heatmapProvider),
                onChanged: (v) => ref.read(heatmapProvider.notifier).state = v,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.history),
                title: const Text('Look back in time'),
                subtitle: const Text(
                  'A slider to see the values as they were on any day',
                ),
                value: ref.watch(timeSliderProvider),
                onChanged: (v) {
                  ref.read(timeSliderProvider.notifier).state = v;
                  if (!v) ref.read(asOfDayProvider.notifier).state = null;
                },
              ),
            ],
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
