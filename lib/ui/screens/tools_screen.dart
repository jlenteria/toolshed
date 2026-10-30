import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/agent_status.dart';
import '../../tools/registry.dart';
import '../theme.dart';
import '../widgets/console_parts.dart';
import '../widgets/status_style.dart';
import 'about_screen.dart';
import 'support_screen.dart';
import 'tool_detail_screen.dart';

/// Front page: a status summary and one card per tool.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key, required this.registry});

  final ToolRegistry registry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Image(image: AssetImage('assets/logo.png'), width: 26, height: 26),
            SizedBox(width: 10),
            Text('toolshed'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Re-read every tool',
            icon: const Icon(Icons.refresh),
            onPressed: () => registry.refresh(),
          ),
          PopupMenuButton<String>(
            tooltip: 'About and support',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              final page = switch (value) {
                'about' => const AboutScreen(),
                _ => const SupportScreen(),
              };
              Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => page));
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18),
                    SizedBox(width: 12),
                    Text('About toolshed'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'support',
                child: Row(
                  children: [
                    Icon(Icons.favorite_border, size: 18),
                    SizedBox(width: 12),
                    Text('Support toolshed'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: registry,
        builder: (context, _) {
          final tools = registry.tools;
          if (tools.isEmpty) {
            return const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No tools are registered.',
              message: 'Everything in this console is missing its backend.',
            );
          }
          final busy = tools.any((entry) => entry.busy);
          return Column(
            children: [
              SizedBox(
                height: 2,
                child: busy
                    ? const LinearProgressIndicator(minHeight: 2)
                    : null,
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => registry.refresh(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    children: [
                      ContentColumn(
                        maxWidth: AppTheme.dashboardWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FleetHeader(tools: tools),
                            const SizedBox(height: 20),
                            _ToolGrid(tools: tools, registry: registry),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FleetHeader extends StatelessWidget {
  const _FleetHeader({required this.tools});

  final List<ToolEntry> tools;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    int count(AgentState state) =>
        tools.where((entry) => entry.status?.state == state).length;
    final failing = tools.where((entry) => entry.error != null).length;

    final tiles = [
      StatTile(
        label: 'Tools',
        value: '${tools.length}',
        icon: Icons.widgets_outlined,
        color: scheme.primary,
      ),
      StatTile(
        label: 'Running',
        value: '${count(AgentState.running)}',
        icon: Icons.play_circle_outline,
        color: statusTone(AgentState.running, scheme).foreground,
      ),
      StatTile(
        label: 'Stopped',
        value: '${count(AgentState.installedStopped)}',
        icon: Icons.pause_circle_outline,
        color: statusTone(AgentState.installedStopped, scheme).foreground,
      ),
      StatTile(
        label: 'Attention',
        value: '$failing',
        icon: Icons.report_outlined,
        color: failing > 0 ? scheme.error : scheme.onSurfaceVariant,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageIntro(
          title: 'Your tools',
          message:
              'Background helpers on this machine, and what each one is doing.',
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 640) {
              return Row(
                children: [
                  for (final (i, tile) in tiles.indexed) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: tile),
                  ],
                ],
              );
            }
            final width = (constraints.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final tile in tiles) SizedBox(width: width, child: tile),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ToolGrid extends StatelessWidget {
  const _ToolGrid({required this.tools, required this.registry});

  final List<ToolEntry> tools;
  final ToolRegistry registry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 2 : 1;
        const gap = 12.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Column(
          children: [
            for (var start = 0; start < tools.length; start += columns) ...[
              if (start > 0) const SizedBox(height: gap),
              // IntrinsicHeight makes both cards in a row as tall as the taller
              // one, so their borders line up instead of ragged bottoms.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (
                      var i = start;
                      i < start + columns && i < tools.length;
                      i++
                    ) ...[
                      if (i > start) const SizedBox(width: gap),
                      SizedBox(
                        width: width,
                        child: _ToolCard(entry: tools[i], registry: registry),
                      ),
                    ],
                    // Keeps a lone card in an odd row at one column wide.
                    for (
                      var i = math.min(start + columns, tools.length);
                      i < start + columns;
                      i++
                    ) ...[const SizedBox(width: gap), SizedBox(width: width)],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.entry, required this.registry});

  final ToolEntry entry;
  final ToolRegistry registry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = entry.status;
    final tone = statusTone(status?.state, scheme);
    final meta = [
      if (status?.pid != null) 'pid ${status!.pid}',
      if (entry.config != null) entry.config!.blurb,
    ].join(' · ');

    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ToolDetailScreen(registry: registry, id: entry.descriptor.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(
                icon: toolIcon(entry.descriptor.id),
                color: tone.foreground,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            entry.descriptor.name,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (status != null)
                          StatusPill(
                            label: status.label,
                            color: tone.foreground,
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entry.descriptor.summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          theme.textTheme.labelSmall,
                        )?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    if (entry.error != null) ...[
                      const SizedBox(height: 10),
                      InlineNote(
                        icon: Icons.error_outline,
                        text: entry.error!,
                        tone: scheme.error,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: entry.busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
