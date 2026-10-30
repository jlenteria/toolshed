import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/agent_status.dart';
import '../../tools/registry.dart';
import '../theme.dart';
import '../widgets/console_parts.dart';
import '../widgets/status_style.dart';

/// Follows the agent log without spawning `tail`: the reader polls the file, so
/// closing this page cannot orphan a process and a rotated log restarts cleanly.
class LogsPanel extends StatefulWidget {
  const LogsPanel({super.key, required this.registry, required this.id});

  final ToolRegistry registry;
  final String id;

  @override
  State<LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends State<LogsPanel> {
  static const int _maxLines = 2000;

  final _lines = <String>[];
  final _scroll = ScrollController();
  StreamSubscription<String>? _subscription;
  String? _message;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    try {
      _subscription = widget.registry
          .tailLog(widget.id)
          .listen(
            (line) {
              if (!mounted) return;
              setState(() {
                _lines.add(line);
                if (_lines.length > _maxLines) {
                  _lines.removeRange(0, _lines.length - _maxLines);
                }
              });
              if (!_paused) _scrollToEnd();
            },
            onError: (Object error) {
              if (mounted) setState(() => _message = '$error');
            },
          );
    } on Object catch (error) {
      setState(() => _message = '$error');
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _togglePaused() {
    setState(() => _paused = !_paused);
    if (!_paused) _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = widget.registry.byId(widget.id);
    final name = entry?.descriptor.name ?? widget.id;
    final logPath = entry?.status?.logPath;
    final lineStyle = AppTheme.mono(
      theme.textTheme.bodySmall,
    )?.copyWith(height: 1.55, color: scheme.onSurface);

    return Scaffold(
      appBar: AppBar(
        title: Text('$name log'),
        actions: [
          IconButton(
            tooltip: _paused ? 'Resume' : 'Pause',
            icon: Icon(
              _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            ),
            onPressed: _togglePaused,
          ),
          IconButton(
            tooltip: 'Clear this view, not the file',
            icon: const Icon(Icons.clear_all_rounded),
            onPressed: _lines.isEmpty
                ? null
                : () => setState(() => _lines.clear()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ContentColumn(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(name, style: theme.textTheme.titleMedium),
                  ),
                  _FollowChip(paused: _paused, lines: _lines.length),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                logPath ?? 'No log path yet — the agent has not reported one.',
                style: AppTheme.mono(
                  theme.textTheme.labelSmall,
                )?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (_message != null) ...[
                const SizedBox(height: 10),
                InlineNote(
                  icon: Icons.error_outline,
                  text: _message!,
                  tone: scheme.error,
                ),
              ] else ...[
                const SizedBox(height: 6),
                Text(
                  'New lines only, from the moment this page opened.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  child: _lines.isEmpty && _message == null
                      ? _QuietLog(name: name)
                      : Scrollbar(
                          controller: _scroll,
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            itemCount: _lines.length,
                            itemBuilder: (context, index) =>
                                SelectableText(_lines[index], style: lineStyle),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FollowChip extends StatelessWidget {
  const _FollowChip({required this.paused, required this.lines});

  final bool paused;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = lines == 0 && !paused
        ? scheme.onSurfaceVariant
        : paused
        ? scheme.tertiary
        : statusTone(AgentState.running, scheme).foreground;
    return StatusPill(
      label: '${paused ? 'Paused' : 'Following'} · $lines',
      color: color,
    );
  }
}

class _QuietLog extends StatelessWidget {
  const _QuietLog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.hourglass_empty_rounded,
      title: 'Nothing new since this page opened.',
      message:
          '$name writes only when something happens — a start, a decision, a '
          'failure — so a quiet panel is what a healthy agent looks like.',
    );
  }
}
