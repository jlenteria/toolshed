import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';
import '../../platform/folder_picker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/capability_notice.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'arduino_config.dart';
import 'arduino_models.dart';
import 'arduino_serial_screen.dart';
import 'arduino_sketch_screen.dart';

/// The Arduino workbench: a sketch, a board, a port, and the three commands a
/// lightweight IDE needs.
///
/// There is no agent behind this page. Every read and every action is an
/// `arduino-cli` process run when the user asks for it, and the output card is
/// the CLI's own stdout and stderr rather than a summary written in Dart. That
/// is what makes the tool honest about a toolchain the app does not own.
class ArduinoScreen extends StatefulWidget {
  const ArduinoScreen({
    super.key,
    required this.registry,
    required this.entry,
    this.folderPicker = const NativeFolderPicker(),
  });

  final ToolRegistry registry;
  final ToolEntry entry;

  /// The OS folder chooser. Injected so a widget test can pick a path without
  /// opening a real dialog on the machine running the test.
  final FolderPicker folderPicker;

  @override
  State<ArduinoScreen> createState() => _ArduinoScreenState();
}

class _ArduinoScreenState extends State<ArduinoScreen> {
  static const int _maxOutputLines = 2000;

  ArduinoInventory? _inventory;
  ArduinoConfig _config = const ArduinoConfig();
  String? _error;
  bool _loading = true;

  bool _running = false;
  String _runLabel = '';
  bool _runFailed = false;
  final List<String> _output = [];
  final ScrollController _outputScroll = ScrollController();
  StreamSubscription<String>? _subscription;

  String get _toolId => widget.entry.descriptor.id;

  Capabilities get _caps => widget.entry.capabilities;

  bool get _canWork => _caps.can(ToolAction.arduinoCompile);

  @override
  void initState() {
    super.initState();
    final cached = widget.entry.config;
    if (cached is ArduinoConfig) _config = cached;
    if (_canWork) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    // Cancelling the subscription is what kills `arduino-cli compile` or
    // `monitor`; nothing else owns the child.
    _subscription?.cancel();
    _outputScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inventory = await widget.registry.arduinoInventory(_toolId);
      final saved = await widget.registry.arduinoConfig(_toolId);

      // First run convenience: a board that is plugged in and identified is a
      // better default than an empty picker. Nothing is written until the user
      // actually has a selection worth remembering.
      var next = saved;
      if (!next.hasSketch && inventory.sketches.isNotEmpty) {
        next = next.copyWith(sketchPath: inventory.sketches.first.directory);
      }
      if (!next.hasBoard) {
        final detected = inventory.firstDetectedBoard;
        if (detected != null) next = next.copyWith(fqbn: detected.fqbn);
      }
      if (!next.hasPort) {
        final port = inventory.firstPort;
        if (port != null) next = next.copyWith(port: port.address);
      }

      if (!mounted) return;
      setState(() {
        _inventory = inventory;
        _config = next;
      });
      if (next != saved) {
        await widget.registry.arduinoSaveConfig(_toolId, next);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(ArduinoConfig next) async {
    setState(() => _config = next);
    final ok = await widget.registry.arduinoSaveConfig(_toolId, next);
    if (!ok && mounted) {
      final error = widget.registry.byId(_toolId)?.error;
      if (error != null) {
        setState(() => _error = error);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  ArduinoSketch? _selectedSketch() {
    final inventory = _inventory;
    if (inventory == null) return null;
    for (final sketch in inventory.sketches) {
      if (sketch.directory == _config.sketchPath) return sketch;
    }
    return null;
  }

  ArduinoBoard? _selectedBoard() {
    final inventory = _inventory;
    if (inventory == null) return null;
    for (final board in [...inventory.detectedBoards, ...inventory.boards]) {
      if (board.fqbn == _config.fqbn) return board;
    }
    return null;
  }

  ArduinoPort? _selectedPort() {
    final inventory = _inventory;
    if (inventory == null) return null;
    for (final port in inventory.ports) {
      if (port.address == _config.port) return port;
    }
    return null;
  }

  Future<void> _chooseSketch() async {
    final inventory = _inventory;
    if (inventory == null) return;
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _SketchPickerDialog(
        sketches: inventory.sketches,
        sketchbookPath: inventory.sketchbookPath,
        folderPicker: widget.folderPicker,
      ),
    );
    if (path == null || !mounted) return;
    await _save(_config.copyWith(sketchPath: path));
  }

  Future<void> _chooseBoard() async {
    final inventory = _inventory;
    if (inventory == null) return;
    final seen = <String>{};
    final boards = [
      for (final board in [...inventory.detectedBoards, ...inventory.boards])
        if (seen.add(board.fqbn)) board,
    ];
    final picked = await showDialog<ArduinoBoard>(
      context: context,
      builder: (_) => _PickerDialog<ArduinoBoard>(
        title: 'Choose a board',
        items: boards,
        label: (board) => board.name.isEmpty ? board.fqbn : board.name,
        subtitle: (board) => board.fqbn,
        matches: (board, query) => board.matches(query),
        hintText: 'Board name or FQBN',
        emptyMessage:
            'No boards are available. Install a board platform with '
            '`arduino-cli core install arduino:avr` or the platform your board '
            'needs, then scan again.',
      ),
    );
    if (picked != null) await _save(_config.copyWith(fqbn: picked.fqbn));
  }

  Future<void> _choosePort() async {
    final inventory = _inventory;
    if (inventory == null) return;
    final picked = await showDialog<ArduinoPort>(
      context: context,
      builder: (_) => _PortPickerDialog(ports: inventory.ports),
    );
    if (picked == null) return;
    var next = _config.copyWith(port: picked.address);
    // A detected port often names its board; filling the board in is what a
    // user would do next anyway, and it saves a second picker.
    if (!next.hasBoard && picked.board != null) {
      next = next.copyWith(fqbn: picked.board!.fqbn);
    }
    await _save(next);
  }

  Future<void> _newSketch() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewSketchDialog(),
    );
    if (name == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final sketch = await widget.registry.arduinoNewSketch(_toolId, name);
    if (!mounted) return;
    if (sketch == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            widget.registry.byId(_toolId)?.error ??
                'The sketch could not be created.',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }

    await _save(_config.copyWith(sketchPath: sketch.directory));
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('Created ${sketch.name}.')));
    await _load();
    if (!mounted) return;
    await _openEditor();
  }

  Future<void> _openEditor() async {
    if (!_config.hasSketch) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArduinoSketchScreen(
          registry: widget.registry,
          toolId: _toolId,
          sketchPath: _config.sketchPath,
        ),
      ),
    );
    if (mounted) await _load();
  }

  void _openSerial() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArduinoSerialScreen(
          registry: widget.registry,
          toolId: _toolId,
          port: _config.port,
          baud: _config.baud,
        ),
      ),
    );
  }

  Future<void> _compile() =>
      _run('Compiling', () => widget.registry.arduinoCompile(_toolId, _config));

  Future<void> _upload() =>
      _run('Uploading', () => widget.registry.arduinoUpload(_toolId, _config));

  Future<void> _run(String label, Stream<String> Function() start) async {
    if (_running) return;
    setState(() {
      _running = true;
      _runLabel = label;
      _runFailed = false;
      _output.clear();
    });

    try {
      _subscription = start().listen(
        (line) {
          if (!mounted) return;
          setState(() {
            _output.add(line);
            if (_output.length > _maxOutputLines) {
              _output.removeRange(0, _output.length - _maxOutputLines);
            }
          });
          _scrollToEnd();
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _output.add('$error');
            _runFailed = true;
            // `streamLines` throws only after the last line, but a broken pipe
            // can end a stream early. Either way, an error is the end of this
            // run: leave no button saying it is still compiling.
            _running = false;
            _runLabel = '';
            _subscription = null;
          });
          _scrollToEnd();
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _running = false;
            _runLabel = '';
            _subscription = null;
          });
        },
        cancelOnError: true,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _runLabel = '';
        _runFailed = true;
        _output.add('$error');
      });
    }
  }

  Future<void> _cancel() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    if (!mounted) return;
    setState(() {
      _running = false;
      _runLabel = '';
      _output.add('Stopped.');
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputScroll.hasClients) {
        _outputScroll.jumpTo(_outputScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConsoleScaffold(
      title: 'Arduino workbench',
      loading: _loading || _running,
      actions: [
        IconButton(
          tooltip: 'Scan ports and sketches again',
          icon: const Icon(Icons.refresh),
          onPressed: _loading || _running ? null : _load,
        ),
      ],
      children: [
        PageIntro(
          title: 'Sketch, board, port',
          message:
              'Read from ${widget.entry.descriptor.implPath} every time this '
              'page opens. Compile, upload and the serial monitor are the CLI\'s '
              'own commands; the output below is what the toolchain printed.',
        ),
        const SizedBox(height: 14),
        if (!_canWork) ...[
          CapabilityNotice(capabilities: _caps),
          const SizedBox(height: 18),
          EmptyState(
            icon: Icons.developer_board,
            title: 'Arduino CLI is not available here',
            message: _caps.reason,
          ),
        ] else ...[
          // Keep live command output above the configuration cards so it is
          // visible as soon as compile or upload starts.
          _OutputCard(
            output: _output,
            scroll: _outputScroll,
            running: _running,
            runLabel: _runLabel,
            failed: _runFailed,
            onClear: () => setState(() => _output.clear()),
          ),
          const SizedBox(height: 18),
          if (_error != null) ...[
            FailureBanner(message: _error!),
            const SizedBox(height: 14),
          ],
          _SketchCard(
            sketch: _selectedSketch(),
            sketchPath: _config.sketchPath,
            sketchbookPath: _inventory?.sketchbookPath ?? '',
            onChoose: _chooseSketch,
            onGoToFile: _chooseSketch,
            onNew: _newSketch,
            onEdit: _config.hasSketch ? _openEditor : null,
          ),
          const SizedBox(height: 18),
          _TargetCard(
            board: _selectedBoard(),
            fqbn: _config.fqbn,
            port: _selectedPort(),
            portAddress: _config.port,
            baud: _config.baud,
            onChooseBoard: _chooseBoard,
            onChoosePort: _choosePort,
            onBaud: (baud) => _save(_config.copyWith(baud: baud)),
          ),
          const SizedBox(height: 18),
          _BuildCard(
            config: _config,
            running: _running,
            runLabel: _runLabel,
            onCompile: _compile,
            onUpload: _upload,
            onSerial: _openSerial,
            onCancel: _cancel,
          ),
          const SizedBox(height: 18),
          if (_inventory != null && _inventory!.notes.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionLabel('Notes'),
            for (final note in _inventory!.notes) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InlineNote(
                  icon: Icons.info_outline,
                  text: note,
                  tone: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ],
          ],
        ],
      ],
    );
  }
}

class _SketchCard extends StatelessWidget {
  const _SketchCard({
    required this.sketch,
    required this.sketchPath,
    required this.sketchbookPath,
    required this.onChoose,
    required this.onGoToFile,
    required this.onNew,
    required this.onEdit,
  });

  final ArduinoSketch? sketch;
  final String sketchPath;
  final String sketchbookPath;
  final VoidCallback onChoose;
  final VoidCallback onGoToFile;
  final VoidCallback onNew;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = sketch?.name ?? _basename(sketchPath);
    final subtitle =
        sketch?.subtitle ??
        (sketchPath.isEmpty
            ? 'Choose a sketch from the sketchbook.'
            : sketchPath);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          'Sketch',
          trailing: TextButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.note_add_outlined, size: 18),
            label: const Text('New sketch'),
          ),
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: IconBadge(
                  icon: Icons.description_outlined,
                  color: scheme.primary,
                  size: 38,
                ),
                title: Text(
                  title.isEmpty ? 'No sketch selected' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: onChoose,
                      child: const Text('Choose'),
                    ),
                    TextButton.icon(
                      onPressed: onGoToFile,
                      icon: const Icon(Icons.insert_drive_file_outlined),
                      label: const Text('Go to file'),
                    ),
                    IconButton(
                      tooltip: 'Edit the sketch',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: onEdit,
                    ),
                  ],
                ),
              ),
              if (sketchbookPath.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          sketchbookPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.mono(
                            theme.textTheme.labelSmall,
                          )?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({
    required this.board,
    required this.fqbn,
    required this.port,
    required this.portAddress,
    required this.baud,
    required this.onChooseBoard,
    required this.onChoosePort,
    required this.onBaud,
  });

  final ArduinoBoard? board;
  final String fqbn;
  final ArduinoPort? port;
  final String portAddress;
  final int baud;
  final VoidCallback onChooseBoard;
  final VoidCallback onChoosePort;
  final ValueChanged<int> onBaud;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Board & port'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: IconBadge(
                  icon: Icons.developer_board,
                  color: scheme.primary,
                  size: 38,
                ),
                title: Text(
                  board == null
                      ? (fqbn.isEmpty ? 'No board selected' : fqbn)
                      : board!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  board?.fqbn ??
                      (fqbn.isEmpty ? 'The FQBN the compiler needs.' : fqbn),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: onChooseBoard,
                  child: const Text('Choose'),
                ),
              ),
              const Divider(height: 1, indent: 64),
              ListTile(
                leading: IconBadge(
                  icon: Icons.usb,
                  color: scheme.primary,
                  size: 38,
                ),
                title: Text(
                  port?.title ??
                      (portAddress.isEmpty ? 'No port selected' : portAddress),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  port?.subtitle.isNotEmpty == true
                      ? port!.subtitle
                      : (portAddress.isEmpty
                            ? 'Plug in a board, or enter a port by hand.'
                            : portAddress),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: onChoosePort,
                  child: const Text('Choose'),
                ),
              ),
              const Divider(height: 1, indent: 64),
              ListTile(
                leading: IconBadge(
                  icon: Icons.speed,
                  color: scheme.primary,
                  size: 38,
                ),
                title: const Text('Serial baud'),
                subtitle: Text('$baud baud'),
                trailing: DropdownButton<int>(
                  value: baud,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final rate in ArduinoConfig.baudRates)
                      DropdownMenuItem(value: rate, child: Text('$rate')),
                  ],
                  onChanged: (value) {
                    if (value != null) onBaud(value);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BuildCard extends StatelessWidget {
  const _BuildCard({
    required this.config,
    required this.running,
    required this.runLabel,
    required this.onCompile,
    required this.onUpload,
    required this.onSerial,
    required this.onCancel,
  });

  final ArduinoConfig config;
  final bool running;
  final String runLabel;
  final VoidCallback onCompile;
  final VoidCallback onUpload;
  final VoidCallback onSerial;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final missing = [
      if (!config.hasSketch) 'a sketch',
      if (!config.hasBoard) 'a board',
    ];

    final compile = FilledButton.icon(
      onPressed: config.canCompile && !running ? onCompile : null,
      icon: const Icon(Icons.build_outlined),
      label: const Text('Compile'),
    );
    final upload = OutlinedButton.icon(
      onPressed: config.canUpload && !running ? onUpload : null,
      icon: const Icon(Icons.upload_outlined),
      label: const Text('Upload'),
    );
    final serial = OutlinedButton.icon(
      onPressed: config.canMonitor && !running ? onSerial : null,
      icon: const Icon(Icons.terminal),
      label: const Text('Serial monitor'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Build & run'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth < 520) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          compile,
                          const SizedBox(height: 8),
                          upload,
                          const SizedBox(height: 8),
                          serial,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: compile),
                        const SizedBox(width: 10),
                        Expanded(child: upload),
                        const SizedBox(width: 10),
                        Expanded(child: serial),
                      ],
                    );
                  },
                ),
                if (!config.canCompile) ...[
                  const SizedBox(height: 10),
                  InlineNote(
                    icon: Icons.info_outline,
                    text:
                        'Choose ${missing.join(' and ')} before compiling. '
                        'The board picker lists every board whose platform is '
                        'installed.',
                  ),
                ] else if (!config.canUpload) ...[
                  const SizedBox(height: 10),
                  const InlineNote(
                    icon: Icons.usb,
                    text:
                        'Upload and the serial monitor need a port. Plug in a '
                        'board and choose it above — a detected board also fills '
                        'in its FQBN.',
                  ),
                ],
                if (running) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$runLabel…',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text('Stop'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OutputCard extends StatelessWidget {
  const _OutputCard({
    required this.output,
    required this.scroll,
    required this.running,
    required this.runLabel,
    required this.failed,
    required this.onClear,
  });

  final List<String> output;
  final ScrollController scroll;
  final bool running;
  final String runLabel;
  final bool failed;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineStyle = AppTheme.mono(
      theme.textTheme.bodySmall,
    )?.copyWith(height: 1.5, color: scheme.onSurface);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          'Output',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TagChip(label: runLabel, color: scheme.primary),
                ),
              if (failed && !running)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TagChip(label: 'Failed', color: scheme.error),
                ),
              IconButton(
                tooltip: 'Clear the output',
                icon: const Icon(Icons.clear_all_rounded),
                onPressed: output.isEmpty ? null : onClear,
              ),
            ],
          ),
        ),
        Card(
          child: SizedBox(
            height: 260,
            child: output.isEmpty
                ? const EmptyState(
                    icon: Icons.terminal,
                    title: 'Nothing has run yet.',
                    message:
                        'Compile or upload a sketch and the toolchain\'s own '
                        'output appears here, line by line.',
                  )
                : Scrollbar(
                    controller: scroll,
                    child: ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.all(14),
                      itemCount: output.length,
                      itemBuilder: (context, index) =>
                          SelectableText(output[index], style: lineStyle),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _PickerDialog<T> extends StatefulWidget {
  const _PickerDialog({
    required this.title,
    required this.items,
    required this.label,
    required this.subtitle,
    required this.matches,
    required this.hintText,
    required this.emptyMessage,
  });

  final String title;
  final List<T> items;
  final String Function(T item) label;
  final String Function(T item) subtitle;
  final bool Function(T item, String query) matches;
  final String hintText;
  final String emptyMessage;

  @override
  State<_PickerDialog<T>> createState() => _PickerDialogState<T>();
}

class _PickerDialogState<T> extends State<_PickerDialog<T>> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<T> get _shown {
    final query = _query.text.trim();
    if (query.isEmpty) return widget.items;
    return [
      for (final item in widget.items)
        if (widget.matches(item, query)) item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 540,
        height: 500,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: widget.hintText,
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: shown.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: widget.items.isEmpty
                          ? 'Nothing to choose from'
                          : 'No match',
                      message: widget.items.isEmpty
                          ? widget.emptyMessage
                          : 'No entry matches "${_query.text.trim()}".',
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final item = shown[index];
                        return ListTile(
                          title: Text(widget.label(item)),
                          subtitle: Text(widget.subtitle(item)),
                          onTap: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _SketchPickerDialog extends StatefulWidget {
  const _SketchPickerDialog({
    required this.sketches,
    required this.sketchbookPath,
    required this.folderPicker,
  });

  final List<ArduinoSketch> sketches;
  final String sketchbookPath;
  final FolderPicker folderPicker;

  @override
  State<_SketchPickerDialog> createState() => _SketchPickerDialogState();
}

class _SketchPickerDialogState extends State<_SketchPickerDialog> {
  final _query = TextEditingController();
  final _path = TextEditingController();
  bool _picking = false;

  @override
  void dispose() {
    _query.dispose();
    _path.dispose();
    super.dispose();
  }

  List<ArduinoSketch> get _shown {
    final query = _query.text.trim();
    if (query.isEmpty) return widget.sketches;
    return [
      for (final sketch in widget.sketches)
        if (sketch.matches(query)) sketch,
    ];
  }

  void _usePath() {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    Navigator.of(context).pop(path);
  }

  Future<void> _browse() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final folder = await widget.folderPicker.pickFolder(
        title: 'Choose a sketch folder',
        initialDirectory: widget.sketchbookPath.isEmpty
            ? null
            : widget.sketchbookPath,
      );
      if (!mounted) return;
      if (folder != null) Navigator.of(context).pop(folder);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the folder picker: $error')),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _shown;
    return AlertDialog(
      title: const Text('Choose a sketch'),
      content: SizedBox(
        width: 560,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Sketch name',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: shown.isEmpty
                  ? EmptyState(
                      icon: Icons.folder_open_outlined,
                      title: widget.sketches.isEmpty
                          ? 'No sketches in the sketchbook'
                          : 'No match',
                      message: widget.sketches.isEmpty
                          ? '${widget.sketchbookPath.isEmpty ? 'The sketchbook' : widget.sketchbookPath} '
                                'has no sketch folders yet. Use New sketch, or '
                                'type a path below.'
                          : 'No sketch matches "${_query.text.trim()}".',
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final sketch = shown[index];
                        return ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(sketch.name),
                          subtitle: Text(
                            sketch.directory,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () =>
                              Navigator.of(context).pop(sketch.directory),
                        );
                      },
                    ),
            ),
            const Divider(height: 20),
            Text(
              'Go to a file or folder',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _picking ? null : _browse,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: Text(_picking ? 'Opening…' : 'Browse folder…'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                      hintText: '/path/to/Blink or /path/to/Blink/Blink.ino',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _usePath(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _path.text.trim().isEmpty ? null : _usePath,
                  child: const Text('Go to file'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PortPickerDialog extends StatefulWidget {
  const _PortPickerDialog({required this.ports});

  final List<ArduinoPort> ports;

  @override
  State<_PortPickerDialog> createState() => _PortPickerDialogState();
}

class _PortPickerDialogState extends State<_PortPickerDialog> {
  final _query = TextEditingController();
  final _manual = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    _manual.dispose();
    super.dispose();
  }

  List<ArduinoPort> get _shown {
    final query = _query.text.trim();
    if (query.isEmpty) return widget.ports;
    return [
      for (final port in widget.ports)
        if (port.matches(query)) port,
    ];
  }

  void _useManual() {
    final address = _manual.text.trim();
    if (address.isEmpty) return;
    Navigator.of(context).pop(ArduinoPort(address: address));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _shown;
    return AlertDialog(
      title: const Text('Choose a port'),
      content: SizedBox(
        width: 540,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Port or board',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: shown.isEmpty
                  ? EmptyState(
                      icon: Icons.usb_off_outlined,
                      title: widget.ports.isEmpty
                          ? 'No ports detected'
                          : 'No match',
                      message: widget.ports.isEmpty
                          ? 'Plug in a board, or enter its port below. On macOS a '
                                'board usually appears as /dev/cu.usbmodem… or '
                                '/dev/cu.usbserial…; on Windows as COM3.'
                          : 'No port matches "${_query.text.trim()}".',
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final port = shown[index];
                        return ListTile(
                          leading: const Icon(Icons.usb),
                          title: Text(port.title),
                          subtitle: Text(
                            port.subtitle.isEmpty
                                ? port.address
                                : port.subtitle,
                          ),
                          onTap: () => Navigator.of(context).pop(port),
                        );
                      },
                    ),
            ),
            const Divider(height: 20),
            Text(
              'Or enter a port by hand',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manual,
                    decoration: const InputDecoration(
                      hintText: '/dev/cu.usbmodem14101 or COM3',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _useManual(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _manual.text.trim().isEmpty ? null : _useManual,
                  child: const Text('Use'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _NewSketchDialog extends StatefulWidget {
  const _NewSketchDialog();

  @override
  State<_NewSketchDialog> createState() => _NewSketchDialogState();
}

class _NewSketchDialogState extends State<_NewSketchDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.note_add_outlined),
      title: const Text('New sketch'),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Sketch name',
          hintText: 'Blink',
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _create(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _create,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final at = trimmed.lastIndexOf('/');
  return at < 0 ? trimmed : trimmed.substring(at + 1);
}
