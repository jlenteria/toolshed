import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'arduino_config.dart';

/// Follows one port with `arduino-cli monitor`.
///
/// The subscription is the only handle on the child: cancelling it — which
/// happens on disconnect, when the baud rate changes, and when this page is
/// closed — kills the monitor. There is no agent and no daemon, so a serial view
/// that is not on screen is not holding the port open.
///
/// This is deliberately read-only. Writing to a board's serial port is a
/// different feature with a different failure mode, and the lightweight console
/// sticks to showing what the board says.
class ArduinoSerialScreen extends StatefulWidget {
  const ArduinoSerialScreen({
    super.key,
    required this.registry,
    required this.toolId,
    required this.port,
    required this.baud,
  });

  final ToolRegistry registry;
  final String toolId;
  final String port;
  final int baud;

  @override
  State<ArduinoSerialScreen> createState() => _ArduinoSerialScreenState();
}

class _ArduinoSerialScreenState extends State<ArduinoSerialScreen> {
  static const int _maxLines = 5000;

  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _subscription;
  late int _baud = widget.baud;
  bool _running = false;
  bool _follow = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!mounted) return;
    setState(() {
      _running = true;
      _error = null;
      _lines.clear();
    });
    try {
      _subscription = widget.registry
          .arduinoSerial(widget.toolId, widget.port, _baud)
          .listen(
            (line) {
              if (!mounted) return;
              setState(() {
                _lines.add(line);
                if (_lines.length > _maxLines) {
                  _lines.removeRange(0, _lines.length - _maxLines);
                }
              });
              _scrollToEnd();
            },
            onError: (Object error) {
              if (!mounted) return;
              setState(() {
                _lines.add('$error');
                _error = '$error';
                _running = false;
                _subscription = null;
              });
            },
            onDone: () {
              if (!mounted) return;
              setState(() {
                _running = false;
                _subscription = null;
              });
            },
            cancelOnError: true,
          );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _running = false;
      });
    }
  }

  Future<void> _disconnect() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    if (!mounted) return;
    setState(() => _running = false);
  }

  void _setBaud(int baud) {
    setState(() => _baud = baud);
    if (_running) _connect();
  }

  void _scrollToEnd() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// The port, its state, the baud picker and the toggle. They share one row on
  /// a wide window and two on a narrow one, so resizing the app cannot push the
  /// only way to stop the monitor off screen.
  Widget _toolbar(ThemeData theme, ColorScheme scheme) {
    final port = Row(
      children: [
        IconBadge(icon: Icons.usb, color: scheme.primary, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.port,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono(theme.textTheme.bodyMedium),
              ),
              const SizedBox(height: 2),
              Text(
                _running ? 'Following at $_baud baud' : 'Not following',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final state = StatusPill(
      label: _running ? 'Following' : 'Stopped',
      color: _running ? scheme.primary : scheme.outline,
    );
    final baud = DropdownButton<int>(
      value: _baud,
      isDense: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final rate in ArduinoConfig.baudRates)
          DropdownMenuItem(value: rate, child: Text('$rate')),
      ],
      onChanged: (value) {
        if (value != null) _setBaud(value);
      },
    );
    final toggle = _running
        ? OutlinedButton.icon(
            onPressed: _disconnect,
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('Stop'),
          )
        : FilledButton.icon(
            onPressed: _connect,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Follow'),
          );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: port),
                      state,
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(children: [baud, const Spacer(), toggle]),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: port),
                const SizedBox(width: 8),
                state,
                const SizedBox(width: 10),
                baud,
                const SizedBox(width: 10),
                toggle,
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineStyle = AppTheme.mono(
      theme.textTheme.bodySmall,
    )?.copyWith(height: 1.5, color: scheme.onSurface);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Serial monitor'),
        actions: [
          IconButton(
            tooltip: _follow ? 'Pause auto-scroll' : 'Follow new lines',
            icon: Icon(
              _follow
                  ? Icons.vertical_align_bottom
                  : Icons.pause_circle_outline,
            ),
            onPressed: () {
              setState(() => _follow = !_follow);
              if (_follow) _scrollToEnd();
            },
          ),
          IconButton(
            tooltip: 'Clear the monitor',
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
              _toolbar(theme, scheme),
              if (_error != null) ...[
                const SizedBox(height: 12),
                FailureBanner(message: _error!),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  child: _lines.isEmpty
                      ? EmptyState(
                          icon: Icons.terminal,
                          title: _running
                              ? 'Waiting for data'
                              : 'The monitor is stopped',
                          message: _running
                              ? 'Open the board\'s serial output at $_baud '
                                    'baud. Lines appear here as they arrive.'
                              : 'Press Follow to open ${widget.port} again. '
                                    'The port is released when this page closes.',
                        )
                      : Scrollbar(
                          controller: _scroll,
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(14),
                            itemCount: _lines.length,
                            itemBuilder: (context, index) =>
                                SelectableText(_lines[index], style: lineStyle),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Read-only: this console follows the board\'s output and does '
                'not write to the port. Closing the page stops arduino-cli '
                'monitor and releases the port.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
