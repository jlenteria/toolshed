import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/capability_notice.dart';
import '../../ui/widgets/console_parts.dart';
import '../registry.dart';
import 'port_listener.dart';
import 'stop_policy.dart';

/// What is holding which port, and — where the platform allows it — a way to
/// let go. Read fresh on every open; there is no agent behind this list.
class PortScreen extends StatefulWidget {
  const PortScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<PortScreen> createState() => _PortScreenState();
}

class _PortScreenState extends State<PortScreen> {
  List<PortListener>? _listeners;
  String? _error;
  String _query = '';
  bool _loading = true;
  final Set<int> _stopping = {};

  String get _toolId => widget.entry.descriptor.id;

  bool get _canStop => widget.entry.capabilities.can(ToolAction.forceStop);

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
      final listeners = await widget.registry.listening(_toolId);
      if (mounted) setState(() => _listeners = listeners);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// The scan minus the sockets this tool cannot act on: protected system
  /// processes are mem_reaper's to refuse, so listing them would only offer a
  /// button that comes back with "will not stop". Where stopping is not part
  /// of the capability set, the list stays informational and complete.
  List<PortListener> get _freeable {
    final all = _listeners ?? const <PortListener>[];
    if (!_canStop) return all;
    return [
      for (final listener in all)
        if (canFreePort(listener)) listener,
    ];
  }

  List<PortListener> get _shown {
    final all = _freeable;
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return [
      for (final listener in all)
        if (listener.port.toString().contains(query) ||
            listener.processLabel.toLowerCase().contains(query) ||
            listener.addressLabel.toLowerCase().contains(query) ||
            listener.protocolLabel.toLowerCase().contains(query) ||
            (listener.user?.toLowerCase().contains(query) ?? false) ||
            (listener.command?.toLowerCase().contains(query) ?? false))
          listener,
    ];
  }

  Future<void> _free(PortListener listener) async {
    final process = listener.process;
    final pid = listener.pid;
    if (process == null || pid == null) return;

    final immediate = await showDialog<bool>(
      context: context,
      builder: (_) => _FreePortDialog(listener: listener),
    );
    if (immediate == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _stopping.add(pid));
    final outcome = await widget.registry.stopProcess(
      _toolId,
      process,
      immediate: immediate,
    );
    if (!mounted) return;
    setState(() => _stopping.remove(pid));

    final error = widget.registry.byId(_toolId)?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome?.describe(listener.processLabel) ??
              error ??
              'The tool was busy with another request. Try again in a moment.',
        ),
        duration: Duration(seconds: outcome?.isGone ?? false ? 4 : 8),
      ),
    );
    // One process can hold several ports, so re-read instead of removing a row.
    if (outcome?.isGone ?? false) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final listeners = _listeners;
    final shown = _shown;
    final query = _query.trim();
    final hidden = _canStop ? (listeners?.length ?? 0) - _freeable.length : 0;

    return ConsoleScaffold(
      title: 'Ports in use',
      loading: _loading,
      actions: [
        IconButton(
          tooltip: 'Scan again',
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        PageIntro(
          title: 'Listening sockets',
          message:
              'Read with ${widget.entry.descriptor.implPath} every time this '
              'page opens. A process bound on IPv4 and IPv6 appears once.'
              '${_canStop ? ' Sockets held by protected system processes are '
                        'left out.' : ''}',
        ),
        const SizedBox(height: 14),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Port, process, pid or address',
            isDense: true,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        if (!_canStop) ...[
          const SizedBox(height: 12),
          CapabilityNotice(capabilities: widget.entry.capabilities),
        ],
        if (hidden > 0) ...[
          const SizedBox(height: 12),
          InlineNote(
            icon: Icons.shield_outlined,
            text:
                '$hidden socket(s) belong to protected system processes and '
                'are not listed; mem_reaper will not stop them.',
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          FailureBanner(message: _error!),
        ],
        const SizedBox(height: 14),
        if (_loading && listeners == null)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (listeners != null && shown.isEmpty)
          EmptyState(
            icon: Icons.lan_outlined,
            title: query.isEmpty
                ? hidden > 0
                      ? 'Nothing here can be freed.'
                      : 'Nothing is listening.'
                : 'Nothing matches "$query".',
            message: query.isEmpty
                ? hidden > 0
                      ? 'Every listening socket belongs to a protected system '
                            'process.'
                      : 'No TCP listener or bound UDP socket was reported.'
                : 'Try a port number, a process name, a pid or an address.',
          )
        else if (listeners != null)
          Card(
            child: Column(
              children: [
                for (final (i, listener) in shown.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 76),
                  _ListenerRow(
                    listener: listener,
                    stopping:
                        listener.pid != null &&
                        _stopping.contains(listener.pid),
                    onFree: _canStop ? () => _free(listener) : null,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ListenerRow extends StatelessWidget {
  const _ListenerRow({
    required this.listener,
    required this.stopping,
    this.onFree,
  });

  final PortListener listener;
  final bool stopping;
  final VoidCallback? onFree;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Widget? trailing;
    if (stopping) {
      trailing = const SizedBox(
        width: 40,
        height: 40,
        child: Padding(
          padding: EdgeInsets.all(11),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (onFree != null) {
      trailing = IconButton(
        tooltip: 'Free port ${listener.port}',
        icon: const Icon(Icons.link_off_rounded),
        color: scheme.error,
        onPressed: onFree,
      );
    } else {
      trailing = null;
    }

    return ListTile(
      leading: _PortBadge(listener: listener),
      title: Text(
        listener.processLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(listener.subtitle, style: theme.textTheme.bodySmall),
          if (listener.command != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                listener.command!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono(
                  theme.textTheme.bodySmall,
                )?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
      trailing: trailing,
    );
  }
}

class _PortBadge extends StatelessWidget {
  const _PortBadge({required this.listener});

  final PortListener listener;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.secondary.withValues(alpha: 0.18)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${listener.port}',
            style: AppTheme.mono(
              theme.textTheme.titleSmall,
            )?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            listener.protocolLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pops `false` for quit-then-kill, `true` to kill at once, null for Cancel.
class _FreePortDialog extends StatefulWidget {
  const _FreePortDialog({required this.listener});

  final PortListener listener;

  @override
  State<_FreePortDialog> createState() => _FreePortDialogState();
}

class _FreePortDialogState extends State<_FreePortDialog> {
  bool _immediate = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listener = widget.listener;
    return AlertDialog(
      icon: Icon(Icons.link_off_rounded, color: scheme.error),
      title: Text('Free port ${listener.port}?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${listener.processLabel} (pid ${listener.pid}) is holding '
              '${listener.protocolLabel} port ${listener.port} on '
              '${listener.addressLabel}.',
              style: theme.textTheme.labelLarge,
            ),
            if (listener.command != null) ...[
              const SizedBox(height: 4),
              Text(
                listener.command!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono(
                  theme.textTheme.bodySmall,
                )?.copyWith(color: scheme.onSurfaceVariant),
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
          child: const Text('Free port'),
        ),
      ],
    );
  }
}
