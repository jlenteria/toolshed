import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';
import '../../ui/widgets/console_parts.dart';
import '../registry.dart';
import 'managed_app.dart';

/// The processes using memory right now, largest first, each with the force
/// stop mem_reaper offers for it.
class RankingScreen extends StatefulWidget {
  const RankingScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  List<ManagedApp>? _apps;
  String? _error;
  bool _loading = true;
  final Set<String> _stopping = {};

  bool _canStop(ManagedApp app) =>
      app.killMode == KillMode.viaReaper &&
      widget.entry.capabilities.can(ToolAction.forceStop);

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
      _apps = await widget.registry.ranked(widget.entry);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _forceStop(ManagedApp app) async {
    final immediate = await showDialog<bool>(
      context: context,
      builder: (_) => _ForceStopDialog(app: app),
    );
    if (immediate == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final id = widget.entry.descriptor.id;
    setState(() => _stopping.add(app.id));
    final outcome = await widget.registry.stopProcess(
      id,
      app,
      immediate: immediate,
    );
    if (!mounted) return;
    setState(() {
      _stopping.remove(app.id);
      if (outcome?.isGone ?? false) {
        _apps = [...?_apps?.where((other) => other.id != app.id)];
      }
    });
    final error = widget.registry.byId(id)?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome?.describe(app.name) ??
              error ??
              'The tool was busy with another request. Try again in a moment.',
        ),
        duration: Duration(seconds: outcome?.isGone ?? false ? 4 : 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;

    return ConsoleScaffold(
      title: 'Memory right now',
      loading: _loading,
      actions: [
        IconButton(
          tooltip: 'Scan again',
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        const PageIntro(
          title: 'What is using memory now',
          message:
              'Read from top\'s MEM column, the physical footprint — the same '
              'number Activity Monitor shows. RSS would understate it, because '
              'macOS compresses idle pages.',
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          FailureBanner(message: _error!),
        ],
        const SizedBox(height: 14),
        if (_loading && apps == null)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (apps != null && apps.isEmpty)
          const EmptyState(
            icon: Icons.memory_rounded,
            title: 'Nothing over the floor.',
            message: 'No process was over the reporting floor.',
          )
        else if (apps != null)
          Card(
            child: Column(
              children: [
                for (final (i, app) in apps.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _AppRow(
                    app: app,
                    stopping: _stopping.contains(app.id),
                    onForceStop: _canStop(app) ? () => _forceStop(app) : null,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, this.stopping = false, this.onForceStop});

  final ManagedApp app;
  final bool stopping;
  final VoidCallback? onForceStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListTile(
      title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('pid ${app.id}', style: theme.textTheme.bodySmall),
          if (app.detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                app.detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(app.memoryLabel, style: theme.textTheme.titleSmall),
          if (onForceStop != null) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 40,
              height: 40,
              child: stopping
                  ? const Padding(
                      padding: EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Force stop ${app.name}',
                      icon: const Icon(Icons.stop_circle_outlined),
                      color: scheme.error,
                      onPressed: onForceStop,
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Pops `false` for quit-then-kill, `true` to kill at once, null for Cancel.
class _ForceStopDialog extends StatefulWidget {
  const _ForceStopDialog({required this.app});

  final ManagedApp app;

  @override
  State<_ForceStopDialog> createState() => _ForceStopDialogState();
}

class _ForceStopDialogState extends State<_ForceStopDialog> {
  bool _immediate = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final app = widget.app;
    return AlertDialog(
      icon: Icon(Icons.stop_circle_outlined, color: scheme.error),
      title: Text('Force stop ${app.name}?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'pid ${app.id} · ${app.memoryLabel}',
              style: theme.textTheme.labelLarge,
            ),
            if (app.detail != null) ...[
              const SizedBox(height: 2),
              Text(
                app.detail!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              _immediate
                  ? 'It is killed at once, with no chance to save. Anything '
                        'unsaved in it is lost.'
                  : 'It is asked to quit first and killed if it is still there '
                        'after 3 seconds. Unsaved work may be lost.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'mem_reaper still refuses system processes, other users\' '
              'processes and toolshed itself.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _immediate,
              onChanged: (value) => setState(() => _immediate = value ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: const Text('Kill immediately, without asking it to quit'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_immediate),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          child: const Text('Force stop'),
        ),
      ],
    );
  }
}
