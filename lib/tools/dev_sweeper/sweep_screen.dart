import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/capability_notice.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'sweep_target.dart';

/// The caches worth reclaiming, measured fresh on every open. Nothing is
/// selected until the user ticks it, and nothing leaves the disk until the
/// confirmation dialog says exactly how much is about to move.
class SweepScreen extends StatefulWidget {
  const SweepScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<SweepScreen> createState() => _SweepScreenState();
}

class _SweepScreenState extends State<SweepScreen> {
  SweepReport? _report;
  final Set<String> _selected = {};
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _moving = false;

  String get _toolId => widget.entry.descriptor.id;

  bool get _canTrash => widget.entry.capabilities.can(ToolAction.trashCaches);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.registry.sweepTargets(_toolId);
      if (!mounted) return;
      setState(() {
        _report = report;
        _selected.removeWhere(
          (path) => !report.targets.any((target) => target.path == path),
        );
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  List<SweepTarget> get _visible {
    final all = _report?.targets ?? const <SweepTarget>[];
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return [
      for (final target in all)
        if (target.searchText.contains(query)) target,
    ];
  }

  List<SweepTarget> get _selectedTargets => [
    for (final target in _report?.targets ?? const <SweepTarget>[])
      if (_selected.contains(target.path)) target,
  ];

  int get _selectedBytes =>
      _selectedTargets.fold(0, (sum, target) => sum + (target.bytes ?? 0));

  List<(String, List<SweepTarget>)> _groups(List<SweepTarget> targets) {
    final grouped = <String, List<SweepTarget>>{};
    for (final target in targets) {
      grouped.putIfAbsent(target.ecosystem, () => []).add(target);
    }
    final keys = grouped.keys.toList()
      ..sort((a, b) {
        final byBytes = _groupBytes(
          grouped[b]!,
        ).compareTo(_groupBytes(grouped[a]!));
        return byBytes != 0 ? byBytes : a.compareTo(b);
      });
    return [for (final key in keys) (key, grouped[key]!)];
  }

  static int _groupBytes(List<SweepTarget> targets) =>
      targets.fold(0, (sum, target) => sum + (target.bytes ?? 0));

  void _toggleAll(bool select) {
    setState(() {
      if (select) {
        for (final target in _visible) {
          _selected.add(target.path);
        }
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _move() async {
    final selected = _selectedTargets;
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _ConfirmSweepDialog(targets: selected, totalBytes: _selectedBytes),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _moving = true;
      _error = null;
    });
    final outcome = await widget.registry.trashCaches(_toolId, selected);
    if (!mounted) return;
    setState(() => _moving = false);

    if (outcome == null) {
      final error = widget.registry.byId(_toolId)?.error;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error ??
                'The tool was busy with another request. Try again in a '
                    'moment.',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(outcome.describe()),
        duration: Duration(seconds: outcome.failures.isEmpty ? 5 : 9),
      ),
    );
    await _load();
    if (!mounted) return;
    if (outcome.failures.isNotEmpty) {
      setState(() {
        _error = [
          for (final failure in outcome.failures)
            '${failure.target.path}: ${failure.message}',
        ].join('\n');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final visible = _visible;
    final groups = _groups(visible);
    final query = _query.trim();
    final selected = _selectedTargets;
    final selectedBytes = _selectedBytes;

    return ConsoleScaffold(
      title: 'Reclaim space',
      loading: _loading || _moving,
      actions: [
        IconButton(
          tooltip: 'Scan again',
          icon: const Icon(Icons.refresh),
          onPressed: _loading || _moving ? null : _load,
        ),
      ],
      children: [
        PageIntro(
          title: 'Build caches',
          message:
              'Scanned with ${widget.entry.descriptor.implPath} every time this '
              'page opens. Each row is a whole directory that a build tool '
              'regenerates; moving it to the Trash is reversible until the '
              'Trash is emptied.',
        ),
        if (!_canTrash) ...[
          const SizedBox(height: 12),
          CapabilityNotice(capabilities: widget.entry.capabilities),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          FailureBanner(message: _error!),
        ],
        const SizedBox(height: 14),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Cache, ecosystem or path',
            isDense: true,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        if (report != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Found',
                  value: formatBytes(report.totalBytes),
                  icon: Icons.inventory_2_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Items',
                  value: '${report.targets.length}',
                  icon: Icons.folder_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Selected',
                  value: formatBytes(selectedBytes),
                  icon: Icons.delete_sweep_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: visible.isEmpty || _moving
                    ? null
                    : () => _toggleAll(true),
                icon: const Icon(Icons.checklist_rounded, size: 18),
                label: Text(query.isEmpty ? 'Select all' : 'Select shown'),
              ),
              TextButton.icon(
                onPressed: selected.isEmpty || _moving
                    ? null
                    : () => _toggleAll(false),
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: const Text('Clear'),
              ),
              if (selected.isNotEmpty)
                Text(
                  '${selected.length} selected',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: selected.isEmpty || _moving || !_canTrash ? null : _move,
            icon: _moving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_sweep_outlined),
            label: Text(
              selected.isEmpty
                  ? 'Move to the Trash'
                  : 'Move ${selected.length} '
                        '${selected.length == 1 ? 'item' : 'items'} '
                        '(${formatBytes(selectedBytes)}) to the Trash',
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (_loading && report == null)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (report != null && visible.isEmpty)
          EmptyState(
            icon: Icons.folder_off_outlined,
            title: query.isEmpty
                ? 'Nothing to reclaim.'
                : 'Nothing matches "$query".',
            message: query.isEmpty
                ? 'No known build cache or project node_modules was found in '
                      'the places this tool looks.'
                : 'Try a cache name, an ecosystem such as Node, or part of a '
                      'path.',
          )
        else
          for (final (ecosystem, targets) in groups) ...[
            SectionLabel(
              ecosystem,
              trailing: TagChip(
                label: formatBytes(_groupBytes(targets)),
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            Card(
              child: Column(
                children: [
                  for (final (i, target) in targets.indexed) ...[
                    if (i > 0) const Divider(height: 1, indent: 56),
                    _SweepRow(
                      target: target,
                      selected: _selected.contains(target.path),
                      enabled: _canTrash && !_moving,
                      onChanged: (value) => setState(() {
                        if (value) {
                          _selected.add(target.path);
                        } else {
                          _selected.remove(target.path);
                        }
                      }),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
        if (report != null)
          for (final note in report.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InlineNote(icon: Icons.info_outline, text: note),
            ),
      ],
    );
  }
}

class _SweepRow extends StatelessWidget {
  const _SweepRow({
    required this.target,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final SweepTarget target;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return CheckboxListTile(
      value: selected,
      onChanged: enabled ? (value) => onChanged(value ?? false) : null,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: Text(
        target.sizeLabel,
        style: AppTheme.mono(theme.textTheme.bodyMedium)?.copyWith(
          color: target.measurable ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      title: Text(target.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Tooltip(
        message: target.path,
        child: Text(
          target.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.mono(
            theme.textTheme.bodySmall,
          )?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Names the count and the size before anything moves. The Trash is reversible
/// but not free: the space only comes back when it is emptied.
class _ConfirmSweepDialog extends StatelessWidget {
  const _ConfirmSweepDialog({required this.targets, required this.totalBytes});

  final List<SweepTarget> targets;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = targets.take(4).toList();
    return AlertDialog(
      icon: Icon(Icons.delete_sweep_outlined, color: scheme.error),
      title: Text(
        'Move ${targets.length} ${targets.length == 1 ? 'item' : 'items'} to '
        'the Trash?',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatBytes(totalBytes)} will be moved, not deleted. The '
              'space comes back when you empty the Trash, and each build '
              'recreates what it needs.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final target in preview)
              FactRow(
                icon: Icons.folder_outlined,
                text: '${target.label} — ${target.sizeLabel}',
                mono: false,
              ),
            if (targets.length > preview.length)
              FactRow(
                icon: Icons.more_horiz,
                text: 'and ${targets.length - preview.length} more',
              ),
            const SizedBox(height: 10),
            Text(
              'Do not sweep a cache while its tool is mid-build.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          child: const Text('Move to Trash'),
        ),
      ],
    );
  }
}
