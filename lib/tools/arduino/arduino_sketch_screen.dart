import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';

/// A plain-text editor for one sketch's primary `.ino`.
///
/// This is deliberately not a code editor with completion, indexing or a
/// language server: it reads the file, lets it be changed, and writes it back.
/// The compiler is the source of truth for whether the sketch is any good, and
/// its output is one page back in the workbench.
class ArduinoSketchScreen extends StatefulWidget {
  const ArduinoSketchScreen({
    super.key,
    required this.registry,
    required this.toolId,
    required this.sketchPath,
  });

  final ToolRegistry registry;
  final String toolId;

  /// A sketch folder or its `.ino`; the backend resolves either.
  final String sketchPath;

  @override
  State<ArduinoSketchScreen> createState() => _ArduinoSketchScreenState();
}

class _ArduinoSketchScreenState extends State<ArduinoSketchScreen> {
  final _controller = TextEditingController();
  String _path = '';
  String _saved = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;

  bool get _dirty => _controller.text != _saved;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await widget.registry.arduinoReadSketch(
        widget.toolId,
        widget.sketchPath,
      );
      if (!mounted) return;
      setState(() {
        _path = file.path;
        _saved = file.contents;
        _controller.text = file.contents;
        _controller.selection = TextSelection.collapsed(
          offset: file.contents.length,
        );
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    final contents = _controller.text;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.registry.arduinoSaveSketch(
      widget.toolId,
      _path.isEmpty ? widget.sketchPath : _path,
      contents,
    );
    if (!mounted) return;
    if (ok) {
      setState(() => _saved = contents);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved ${_basename(_path)}.'),
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      setState(() {
        _error =
            widget.registry.byId(widget.toolId)?.error ??
            'The sketch could not be saved.';
      });
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<bool> _confirmDiscard() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_outlined),
        title: const Text('Discard unsaved changes?'),
        content: Text(
          '${_basename(_path)} has changes that have not been saved. Leave the '
          'editor and lose them?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = _controller.text.isEmpty
        ? 1
        : _controller.text.split('\n').length;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _path.isEmpty ? 'Sketch' : _basename(_path),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (_dirty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: StatusPill(label: 'Unsaved', color: scheme.tertiary),
                ),
              ),
            IconButton(
              tooltip: 'Save the sketch',
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              onPressed: _dirty && !_saving ? _save : null,
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
                        _path.isEmpty ? widget.sketchPath : _path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          theme.textTheme.labelSmall,
                        )?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$lines line${lines == 1 ? '' : 's'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  FailureBanner(message: _error!),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : CallbackShortcuts(
                          bindings: {
                            const SingleActivator(
                              LogicalKeyboardKey.keyS,
                              meta: true,
                            ): _save,
                            const SingleActivator(
                              LogicalKeyboardKey.keyS,
                              control: true,
                            ): _save,
                          },
                          child: Focus(
                            autofocus: true,
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: TextField(
                                  controller: _controller,
                                  expands: true,
                                  maxLines: null,
                                  minLines: null,
                                  textAlignVertical: TextAlignVertical.top,
                                  style: AppTheme.mono(
                                    theme.textTheme.bodyMedium,
                                  )?.copyWith(height: 1.55),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    hintText:
                                        'void setup() {\n'
                                        '  // ...\n'
                                        '}\n',
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Save with $_saveShortcut. The sketch is written '
                  'back to the file above; compiling is still the workbench\'s '
                  'job.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The save shortcut as the platform writes it, without importing `dart:io`
/// into a screen that has no other reason to know the OS.
String get _saveShortcut =>
    defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS
    ? '⌘S'
    : 'Ctrl+S';

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final at = normalized.lastIndexOf('/');
  return at < 0 ? normalized : normalized.substring(at + 1);
}
