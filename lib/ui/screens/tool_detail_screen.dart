import 'package:flutter/material.dart';

import '../../models/agent_status.dart';
import '../../models/tool_descriptor.dart';
import '../../tools/app_lock/lock_screen.dart';
import '../../tools/dev_sweeper/sweep_screen.dart';
import '../../tools/docker/docker_screen.dart';
import '../../tools/fan_ctl/fan_screen.dart';
import '../../tools/mem_reaper/config_sheet.dart';
import '../../tools/mem_reaper/ranking_screen.dart';
import '../../tools/port_warden/port_screen.dart';
import '../../tools/registry.dart';
import '../../tools/tool_backend.dart';
import '../theme.dart';
import '../widgets/capability_notice.dart';
import '../widgets/console_parts.dart';
import '../widgets/status_style.dart';
import 'logs_panel.dart';

class ToolDetailScreen extends StatelessWidget {
  const ToolDetailScreen({super.key, required this.registry, required this.id});

  final ToolRegistry registry;
  final String id;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final entry = registry.byId(id);
        return Scaffold(
          appBar: AppBar(
            title: Text(entry?.descriptor.name ?? id),
            actions: [
              IconButton(
                tooltip: 'Re-read status',
                icon: const Icon(Icons.refresh),
                onPressed: (entry?.busy ?? false)
                    ? null
                    : () => registry.refresh(id: id),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: entry == null
              ? const EmptyState(
                  icon: Icons.search_off,
                  title: 'That tool is no longer registered.',
                )
              : _Body(entry: entry, registry: registry),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.entry, required this.registry});

  final ToolEntry entry;
  final ToolRegistry registry;

  static bool _hasDetails(AgentStatus? status) =>
      status != null &&
      (status.runs != null ||
          status.lastExitCode != null ||
          (status.plistPath?.isNotEmpty ?? false) ||
          (status.logPath?.isNotEmpty ?? false) ||
          status.notes.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 2,
          child: entry.busy
              ? const LinearProgressIndicator(minHeight: 2)
              : null,
        ),
        Expanded(
          child: ContentColumn(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              children: [
                _Header(entry: entry),
                if (entry.error != null) ...[
                  const SizedBox(height: 12),
                  FailureBanner(message: entry.error!),
                ],
                const SizedBox(height: 18),
                _Controls(registry: registry, entry: entry),
                if (_hasDetails(entry.status)) ...[
                  const SizedBox(height: 26),
                  const SectionLabel('Details'),
                  _Details(status: entry.status!),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry});

  final ToolEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = entry.status ?? const AgentStatus(state: AgentState.unknown);
    final tone = statusTone(shown.state, scheme);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconBadge(
                  icon: toolIcon(entry.descriptor.id),
                  color: tone.foreground,
                  size: 54,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.descriptor.name,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          StatusPill(
                            label: shown.label,
                            color: tone.foreground,
                          ),
                          if (shown.pid != null)
                            Text(
                              'pid ${shown.pid}',
                              style: AppTheme.mono(
                                theme.textTheme.labelMedium,
                              )?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          if (entry.busy)
                            Text(
                              'reading…',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(entry.descriptor.summary, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    entry.capabilities.support == Support.full
                        ? Icons.code_rounded
                        : Icons.south_rounded,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.capabilities.support == Support.full
                          ? 'Driven by ${entry.descriptor.implPath}. This '
                                'console sends commands and shows the answer; '
                                'the decisions live in the helper.'
                          : 'See the note below for what this platform can and '
                                'cannot do.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.status});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = <(String, String)>[
      if (status.runs != null) ('Runs', '${status.runs}'),
      if (status.lastExitCode != null) ('Last exit', '${status.lastExitCode}'),
    ];
    final paths = <(IconData, String, String)>[
      if (status.plistPath?.isNotEmpty ?? false)
        (Icons.description_outlined, 'Plist', status.plistPath!),
      if (status.logPath?.isNotEmpty ?? false)
        (Icons.article_outlined, 'Log', status.logPath!),
    ];

    return SectionCard(
      children: [
        if (stats.isNotEmpty)
          Row(
            children: [
              for (final (i, (label, value)) in stats.indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: StatTile(label: label, value: value),
                ),
              ],
            ],
          ),
        for (final (icon, label, path) in paths)
          Padding(
            padding: EdgeInsets.only(top: stats.isEmpty ? 0 : 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 17, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                SizedBox(
                  width: 40,
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    path,
                    style: AppTheme.mono(theme.textTheme.bodySmall),
                  ),
                ),
              ],
            ),
          ),
        for (final note in status.notes) ...[
          const SizedBox(height: 8),
          InlineNote(
            icon: Icons.lightbulb_outline,
            text: note,
            tone: scheme.tertiary,
          ),
        ],
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final capabilities = entry.capabilities;
    final state = entry.status?.state;
    final can = capabilities.can;
    final primary = <Widget>[];
    final secondary = <Widget>[];
    final busy = entry.busy;
    VoidCallback? guard(VoidCallback body) => busy ? null : body;

    void addPrimary(
      ToolAction action,
      IconData icon,
      String label,
      VoidCallback? onTap, {
      bool filled = true,
      bool danger = false,
    }) {
      if (!can(action)) return;
      primary.add(
        Expanded(
          child: filled
              ? FilledButton.icon(
                  onPressed: onTap,
                  style: danger
                      ? FilledButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                        )
                      : null,
                  icon: Icon(icon),
                  label: Text(label, overflow: TextOverflow.ellipsis),
                )
              : OutlinedButton.icon(
                  onPressed: onTap,
                  icon: Icon(icon),
                  label: Text(label, overflow: TextOverflow.ellipsis),
                ),
        ),
      );
    }

    void addSecondary(
      ToolAction action,
      IconData icon,
      String title,
      String subtitle,
      VoidCallback? onTap,
    ) {
      if (!can(action)) return;
      secondary.add(
        _ActionTile(icon: icon, title: title, subtitle: subtitle, onTap: onTap),
      );
    }

    switch (state) {
      case AgentState.notInstalled:
        addPrimary(
          ToolAction.install,
          Icons.download_outlined,
          'Install the agent',
          guard(() => registry.install(entry.descriptor.id)),
        );
      case AgentState.installedStopped:
        addPrimary(
          ToolAction.start,
          Icons.play_arrow_rounded,
          'Start',
          guard(() => registry.start(entry.descriptor.id)),
        );
      case AgentState.running:
        addPrimary(
          ToolAction.stop,
          Icons.stop_rounded,
          'Stop',
          guard(() => registry.stop(entry.descriptor.id)),
          danger: true,
        );
      case AgentState.unknown:
        addPrimary(
          ToolAction.start,
          Icons.play_arrow_rounded,
          'Start',
          guard(() => registry.start(entry.descriptor.id)),
        );
        addPrimary(
          ToolAction.stop,
          Icons.stop_rounded,
          'Stop',
          guard(() => registry.stop(entry.descriptor.id)),
          filled: false,
        );
      case AgentState.notApplicable:
      case null:
        break;
    }

    final fan = entry.backend is FanControl;
    final lock = entry.backend is AppLockGuard;

    addSecondary(
      ToolAction.reapNow,
      Icons.cleaning_services_outlined,
      'Reap now',
      'Scan and ask me about each one',
      guard(() async {
        final messenger = ScaffoldMessenger.of(context);
        final ok = await registry.reapNow(entry.descriptor.id);
        if (!ok) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Scan finished. Anything over the limit was raised as a dialog '
              'on this Mac.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }),
    );

    addSecondary(
      ToolAction.showRanking,
      Icons.bar_chart_rounded,
      'What is using memory',
      'Apps ranked by footprint',
      () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RankingScreen(registry: registry, entry: entry),
        ),
      ),
    );

    addSecondary(
      ToolAction.showPorts,
      Icons.lan_outlined,
      'Ports in use',
      'What is listening, and the process behind it',
      () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PortScreen(registry: registry, entry: entry),
        ),
      ),
    );

    addSecondary(
      ToolAction.showCaches,
      Icons.delete_sweep_outlined,
      'Reclaim space',
      'Build caches and node_modules you can rebuild',
      () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SweepScreen(registry: registry, entry: entry),
        ),
      ),
    );

    addSecondary(
      ToolAction.showDocker,
      Icons.dns_outlined,
      'Containers & images',
      'What the docker CLI sees, and a safe way to stop or remove it',
      () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DockerScreen(registry: registry, entry: entry),
        ),
      ),
    );

    addSecondary(
      ToolAction.configure,
      switch ((fan, lock)) {
        (true, _) => Icons.settings_input_component,
        (_, true) => Icons.lock_person_outlined,
        _ => Icons.tune_rounded,
      },
      switch ((fan, lock)) {
        (true, _) => 'Fan control',
        (_, true) => 'App lock console',
        _ => 'Settings',
      },
      switch ((fan, lock)) {
        (true, _) => 'The manual switch and the speed it holds',
        (_, true) => 'What is watching, what is locked, and the passphrase',
        _ => 'Thresholds and agent options',
      },
      switch ((fan, lock)) {
        (true, _) => () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FanScreen(registry: registry, entry: entry),
          ),
        ),
        (_, true) => () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LockScreen(registry: registry, entry: entry),
          ),
        ),
        _ => guard(() async {
          final saved = await showConfigSheet(context, registry, entry);
          if (saved == true && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Saved. The agent was reloaded with the new values.',
                ),
              ),
            );
          }
        }),
      },
    );

    addSecondary(
      ToolAction.tailLogs,
      Icons.receipt_long_outlined,
      'Logs',
      'Follow the agent output',
      () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              LogsPanel(registry: registry, id: entry.descriptor.id),
        ),
      ),
    );

    final showNotice =
        !can(ToolAction.start) ||
        !can(ToolAction.stop) ||
        capabilities.support != Support.full;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (primary.isNotEmpty)
          SizedBox(
            height: 48,
            child: Row(
              children: [
                for (final (i, button) in primary.indexed) ...[
                  if (i > 0) const SizedBox(width: 10),
                  button,
                ],
              ],
            ),
          ),
        if (showNotice) ...[
          const SizedBox(height: 12),
          CapabilityNotice(capabilities: capabilities),
        ],
        if (secondary.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionLabel('Actions'),
          Card(
            child: Column(
              children: [
                for (final (i, tile) in secondary.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 64),
                  tile,
                ],
              ],
            ),
          ),
        ],
        if (can(ToolAction.uninstall) &&
            (state == AgentState.running ||
                state == AgentState.installedStopped)) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: guard(() => _confirmUninstall(context)),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(fan ? 'Uninstall the daemon' : 'Uninstall the agent'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmUninstall(BuildContext context) async {
    final fan = entry.backend is FanControl;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(fan ? 'Uninstall the fan daemon?' : 'Uninstall the agent?'),
        content: Text(
          fan
              ? 'This unloads the root daemon, which hands the fan back to '
                    'Apple\'s automatic control on the way out, and removes the '
                    'binary and plist. The plist is copied to /var/tmp first, so '
                    'what was installed can be put back.'
              : 'This stops the background watch. mem_reaper.py keeps working '
                    'when run by hand, and the plist is kept next to where it '
                    'was installed rather than deleted, so you can put it back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (confirmed == true) await registry.uninstall(entry.descriptor.id);
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: onTap != null,
      onTap: onTap,
      leading: IconBadge(icon: icon, color: scheme.primary, size: 36),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
    );
  }
}
