import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/agent_status.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'docker_models.dart';

/// Follows one container's stdout and stderr with `docker logs --follow`.
///
/// Logs belong to the container, not to a port, so a port being debugged is
/// reached through the container that publishes it. The subscription is the
/// only handle on the child: cancelling it — which happens when this page is
/// closed — kills the `docker` process, so a log view never leaks a follower.
class DockerLogsScreen extends StatefulWidget {
  const DockerLogsScreen({
    super.key,
    required this.registry,
    required this.toolId,
    required this.container,
  });

  final ToolRegistry registry;
  final String toolId;
  final DockerContainer container;

  @override
  State<DockerLogsScreen> createState() => _DockerLogsScreenState();
}

class _DockerLogsScreenState extends State<DockerLogsScreen> {
  static const int _maxLines = 2000;

  final _lines = <String>[];
  final _scroll = ScrollController();
  StreamSubscription<String>? _subscription;
  String? _message;
  bool _paused = false;
  bool _done = false;

  DockerContainer get _container => widget.container;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    try {
      _subscription = widget.registry
          .dockerLogs(widget.toolId, _container)
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
            onDone: () {
              if (mounted) setState(() => _done = true);
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
    // Cancelling is what stops `docker logs --follow`; nothing else owns it.
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
    final lineStyle = AppTheme.mono(
      theme.textTheme.bodySmall,
    )?.copyWith(height: 1.55, color: scheme.onSurface);
    final ports = _container.portMappings.isNotEmpty
        ? _container.portMappings.map((p) => p.label).join(', ')
        : _container.ports;

    return Scaffold(
      appBar: AppBar(
        title: Text('Logs · ${_container.primaryName}'),
        actions: [
          IconButton(
            tooltip: _paused ? 'Resume' : 'Pause',
            icon: Icon(
              _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            ),
            onPressed: _togglePaused,
          ),
          IconButton(
            tooltip: 'Clear this view, not the container',
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
                    child: Text(
                      _container.primaryName,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  _FollowChip(
                    paused: _paused,
                    done: _done,
                    lines: _lines.length,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'docker logs --follow --tail 200 ${_container.idShort}',
                style: AppTheme.mono(
                  theme.textTheme.labelSmall,
                )?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (_container.subtitle.isNotEmpty || ports.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  [
                    if (_container.subtitle.isNotEmpty) _container.subtitle,
                    if (ports.isNotEmpty) ports,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
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
                  _done
                      ? 'The container stopped writing; the lines above are its '
                            'tail.'
                      : 'Following new lines as the container writes them.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  child: _lines.isEmpty && _message == null
                      ? _QuietLog(name: _container.primaryName)
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
  const _FollowChip({
    required this.paused,
    required this.done,
    required this.lines,
  });

  final bool paused;
  final bool done;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = done
        ? scheme.onSurfaceVariant
        : paused
        ? scheme.tertiary
        : lines == 0
        ? scheme.onSurfaceVariant
        : statusTone(AgentState.running, scheme).foreground;
    final label = done
        ? 'Ended · $lines'
        : '${paused ? 'Paused' : 'Following'} · $lines';
    return StatusPill(label: label, color: color);
  }
}

class _QuietLog extends StatelessWidget {
  const _QuietLog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.hourglass_empty_rounded,
      title: 'Nothing to show yet.',
      message:
          '$name has not written anything — or it wrote more than the last 200 '
          'lines and the follow has not caught up. A quiet container is what a '
          'healthy one often looks like.',
    );
  }
}
