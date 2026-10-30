import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';
import '../../ui/widgets/console_parts.dart';
import '../registry.dart';
import '../tool_backend.dart';
import 'managed_app.dart';

/// One list with two meanings: macOS rows carry a live footprint, phone rows
/// carry a cumulative share and duration because Android exposes no per-app RAM.
class RankingScreen extends StatefulWidget {
  const RankingScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  static const List<int> _windows = [1, 3, 7, 14, 30];

  List<ManagedApp>? _apps;
  PhoneMemory? _phone;
  int _windowDays = 7;
  String? _error;
  bool _loading = true;
  final Set<String> _stopping = {};

  bool get _isPhone => widget.entry.capabilities.support == Support.cappedByOs;

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
      final source = widget.registry.phoneSource(widget.entry.descriptor.id);
      if (_isPhone && source != null) {
        _phone = await source.phoneMemory();
        final days = _phone!.usableWindow(_windowDays);
        _apps = await widget.registry.ranked(widget.entry, windowDays: days);
      } else {
        _apps = await widget.registry.ranked(widget.entry);
      }
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
    final phone = _phone;

    return ConsoleScaffold(
      title: _isPhone ? 'App usage' : 'Memory right now',
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
          title: _isPhone
              ? 'Phone memory — last $_windowDays days'
              : 'What is using memory now',
          message: _isPhone
              ? 'Android does not expose live per-app memory to other apps. '
                    'This is a cumulative total over the period, not current RAM.'
              : 'Read from top\'s MEM column, the physical footprint — the same '
                    'number Activity Monitor shows. RSS would understate it, '
                    'because macOS compresses idle pages.',
        ),
        if (_isPhone && phone != null) ...[
          const SizedBox(height: 12),
          _PhoneRam(phone: phone),
        ],
        if (_isPhone) ...[
          const SizedBox(height: 12),
          _WindowPicker(
            windows: _windows,
            selected: _windowDays,
            retentionDays: phone?.retentionDays,
            onChanged: (days) {
              setState(() => _windowDays = days);
              _load();
            },
          ),
        ],
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
          EmptyState(
            icon: Icons.memory_rounded,
            title: _isPhone ? 'No usage history.' : 'Nothing over the floor.',
            message: _isPhone
                ? 'Grant Usage Access or widen the window. A missing record is '
                      'not the same as an unused app.'
                : 'No process was over the reporting floor.',
          )
        else if (apps != null)
          Card(
            child: Column(
              children: [
                for (final (i, app) in apps.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _AppRow(
                    app: app,
                    registry: widget.registry,
                    toolId: widget.entry.descriptor.id,
                    isPhone: _isPhone,
                    nowMillis: DateTime.now().millisecondsSinceEpoch,
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

class _PhoneRam extends StatelessWidget {
  const _PhoneRam({required this.phone});

  final PhoneMemory phone;

  @override
  Widget build(BuildContext context) {
    if (phone.ramTotalBytes <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return InlineNote(
      icon: Icons.smartphone_outlined,
      text:
          'Device RAM: ${ManagedApp.formatBytes(phone.ramAvailableBytes)} free '
          'of ${ManagedApp.formatBytes(phone.ramTotalBytes)}. That is the whole '
          'phone — Android gives no app a per-app figure.',
      tone: scheme.tertiary,
    );
  }
}

class _WindowPicker extends StatelessWidget {
  const _WindowPicker({
    required this.windows,
    required this.selected,
    required this.onChanged,
    this.retentionDays,
  });

  final List<int> windows;
  final int selected;
  final ValueChanged<int> onChanged;
  final int? retentionDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final days in windows)
              ChoiceChip(
                label: Text('$days d'),
                selected: days == selected,
                onSelected: (_) => onChanged(days),
              ),
          ],
        ),
        if (retentionDays != null && retentionDays! < selected)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Only about $retentionDays day'
              '${retentionDays == 1 ? '' : 's'} of history exist on this '
              'device, so the window was narrowed to match.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.registry,
    required this.toolId,
    required this.isPhone,
    required this.nowMillis,
    this.stopping = false,
    this.onForceStop,
  });

  final ManagedApp app;
  final ToolRegistry registry;
  final String toolId;
  final bool isPhone;
  final int nowMillis;
  final bool stopping;
  final VoidCallback? onForceStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final share = app.share;

    return ListTile(
      title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isPhone
                ? [
                    app.lastUsedLabel(nowMillis),
                    if (app.periodMillis != null) '${app.periodLabel} in use',
                    if (app.launchCount != null) '${app.launchCount} opens',
                  ].join(' · ')
                : 'pid ${app.id}',
            style: theme.textTheme.bodySmall,
          ),
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
          if (share != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: MeterBar(
                fraction: share,
                height: 5,
                color: scheme.primary,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(app.memoryLabel, style: theme.textTheme.titleSmall),
              if (share != null)
                Text(
                  'of period',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
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
      onTap: app.killMode == KillMode.opensAppInfo
          ? () => _openAppInfo(context)
          : null,
    );
  }

  Future<void> _openAppInfo(BuildContext context) async {
    final source = registry.phoneSource(toolId);
    if (source == null) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await source.openAppInfo(app.id);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Could not open the system page for ${app.name}:\n$error',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Android will not let another app stop it, so the system page is '
          'open. Tap Force stop there.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
    navigator.pop();
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
