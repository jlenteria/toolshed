import 'dart:convert';
import 'dart:io';

import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/paths.dart';
import '../../platform/runner.dart';
import '../tool_backend.dart';
import 'arduino_config.dart';
import 'arduino_models.dart';
import 'arduino_parsers.dart';

const String kArduinoId = 'arduino';

/// A lightweight Arduino workbench driven entirely through `arduino-cli`.
///
/// The console holds no toolchain logic of its own. It asks the CLI which ports
/// and boards exist, runs the CLI's own `compile`, `upload` and `monitor`
/// commands, and shows what the toolchain printed. That split is the point: the
/// board definitions, the upload protocol and the compiler flags belong to the
/// installed platforms, and a second copy in Dart would drift the first time a
/// core was updated.
///
/// Nothing runs in the background. A sketch is compiled or uploaded when the
/// button is pressed, and the serial monitor is one `arduino-cli monitor` child
/// whose subscription is the only handle on it — closing the view kills it.
class ArduinoBackend implements ToolBackend, ArduinoWorkbench {
  ArduinoBackend({
    ProcessRunner? runner,
    String? cliPath,
    String? Function()? discover,
    File? configFile,
  }) : _runner = runner ?? const ProcessRunner(),
       _requestedPath = cliPath,
       _discover = discover ?? Paths.arduinoCliBinary,
       _configFile = configFile ?? Paths.arduinoConfigFile;

  final ProcessRunner _runner;
  final String? _requestedPath;
  final String? Function() _discover;
  final File _configFile;

  String? _resolved;
  bool _resolvedOnce = false;

  /// The `arduino-cli` binary this console talks to, resolved once per instance.
  ///
  /// A requested path that has gone missing falls back to discovery rather than
  /// promising to run a binary that is no longer there — the state left behind
  /// by an uninstalled CLI or a moved Homebrew prefix. Every button is gated on
  /// the result, so a machine with no CLI lists the tool with a reason instead of
  /// drawing controls that could only fail.
  String? get cliPath {
    if (_resolvedOnce) return _resolved;
    _resolvedOnce = true;
    final requested = _requestedPath;
    if (requested != null && File(requested).existsSync()) {
      return _resolved = requested;
    }
    return _resolved = _discover();
  }

  String get _cli =>
      cliPath ??
      (throw const ToolException(
        'NO_ARDUINO_CLI',
        'There is no arduino-cli on this machine, so there is nothing to '
            'compile or upload with. Install it from arduino.github.io/arduino-cli '
            'and this tool will light up.',
      ));

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kArduinoId,
    name: 'Arduino Bench',
    summary:
        'A lightweight Arduino IDE: pick a sketch, board and port, compile and '
        'upload it, and follow the serial monitor, through the arduino-cli you '
        'already have.',
    implPath: 'arduino-cli',
  );

  @override
  Capabilities get capabilities {
    if (cliPath == null) {
      return const Capabilities(
        support: Support.helperMissing,
        actions: <ToolAction>{},
        reason:
            'The Arduino toolchain is driven by arduino-cli, and none was found '
            'on this machine. Install the CLI and a board platform — '
            '`arduino-cli core install arduino:avr` is the usual start — and '
            'this console will find both.',
      );
    }
    return const Capabilities(
      support: Support.full,
      actions: <ToolAction>{
        // The console itself: selecting a sketch, board and port, and opening
        // the editor and serial monitor.
        ToolAction.configure,
        ToolAction.arduinoEdit,
        ToolAction.arduinoNewSketch,
        // The three toolchain actions. The CLI decides whether each succeeds;
        // the console only offers the ones this platform can run.
        ToolAction.arduinoCompile,
        ToolAction.arduinoUpload,
        ToolAction.arduinoSerial,
      },
      reason:
          'Compiles and uploads through arduino-cli, using the board platforms '
          'and ports that CLI already knows about. Nothing is installed here '
          'and nothing runs in the background: compile, upload and the serial '
          'monitor are commands run on demand, and the toolchain\'s own output '
          'is what the console shows.',
    );
  }

  @override
  Future<AgentStatus> status() async {
    final cli = cliPath;
    if (cli == null) {
      return const AgentStatus.notApplicable().withNotes([
        'No arduino-cli was found on PATH or in the usual install locations, so '
            'there is nothing to compile with. Install the CLI and a board '
            'platform and this tool lights up.',
      ]);
    }

    try {
      final version = await _run(cli, const [
        'version',
      ], timeout: const Duration(seconds: 10));
      final cores = await _run(cli, const [
        'core',
        'list',
        '--json',
      ], timeout: const Duration(seconds: 20));

      final notes = <String>[];
      if (version.ok) {
        final parsed = parseVersion(version.stdout);
        notes.add(
          'arduino-cli ${parsed.isEmpty ? '' : '$parsed '}— read on demand; '
          'nothing is installed here and nothing runs in the background.',
        );
      } else {
        notes.add(
          'arduino-cli is present but did not answer: '
          '${_firstLine(version.blurb)}',
        );
      }

      if (cores.ok) {
        final parsed = parseCores(cores.stdout);
        final installed = parsed.cores.where((c) => c.isInstalled).length;
        notes.add(
          installed == 0
              ? 'No board platforms are installed yet. Install one with '
                    '`arduino-cli core install arduino:avr` (or the platform '
                    'your board needs) before compiling.'
              : '$installed board platform(s) installed — their boards are what '
                    'the board picker offers.',
        );
      } else {
        notes.add(
          'Installed board platforms could not be read: '
          '${_firstLine(cores.blurb)}',
        );
      }

      notes.add(
        'The sketchbook, board list and port list are read from the CLI each '
        'time this page opens, so a board plugged in while the console is open '
        'appears on the next scan.',
      );
      return const AgentStatus.notApplicable().withNotes(notes);
    } on ToolException catch (error) {
      return const AgentStatus.notApplicable().withNotes([
        'arduino-cli did not answer: $error',
      ]);
    }
  }

  @override
  Future<ArduinoInventory> inventory() async {
    final cli = _cli;
    final notes = <String>[];

    // The connected ports are the one read the console cannot work without: a
    // failure here is the CLI's own message, not a silently empty list.
    final portResult = await _mustOk(
      cli,
      const ['board', 'list', '--json'],
      what: 'arduino-cli board list',
      timeout: const Duration(seconds: 20),
    );
    final ports = parseBoardList(portResult.stdout);
    if (ports.partial != null) notes.add('ports: ${ports.partial}');

    // Everything below is useful but not essential. A platform that is too old
    // to answer one of these should leave a note, not blank the page.
    var boards = const <ArduinoBoard>[];
    final allBoards = await _run(cli, const [
      'board',
      'listall',
      '--json',
    ], timeout: const Duration(seconds: 30));
    if (allBoards.ok) {
      final parsed = parseAllBoards(allBoards.stdout);
      boards = parsed.boards;
      if (parsed.partial != null) notes.add('boards: ${parsed.partial}');
    } else {
      notes.add(
        'The board list could not be read: ${_firstLine(allBoards.blurb)}',
      );
    }

    var cores = const <ArduinoCore>[];
    final coreResult = await _run(cli, const [
      'core',
      'list',
      '--json',
    ], timeout: const Duration(seconds: 20));
    if (coreResult.ok) {
      final parsed = parseCores(coreResult.stdout);
      cores = parsed.cores;
      if (parsed.partial != null) notes.add('cores: ${parsed.partial}');
    } else {
      notes.add(
        'Installed platforms could not be read: '
        '${_firstLine(coreResult.blurb)}',
      );
    }

    var version = '';
    final versionResult = await _run(cli, const [
      'version',
    ], timeout: const Duration(seconds: 10));
    if (versionResult.ok) {
      version = parseVersion(versionResult.stdout);
    } else {
      notes.add('The CLI version could not be read.');
    }

    final sketchbook = await _sketchbookPath(cli);
    final sketches = sketchbook.isEmpty
        ? const <ArduinoSketch>[]
        : scanSketchbook(Directory(sketchbook));
    if (sketchbook.isEmpty) {
      notes.add(
        'No sketchbook directory was reported, so no sketches are listed. New '
        'sketches will be created in the default Arduino folder.',
      );
    } else if (sketches.isEmpty && !Directory(sketchbook).existsSync()) {
      notes.add(
        'The sketchbook at $sketchbook does not exist yet; a new sketch will '
        'create it.',
      );
    }

    if (cores.isNotEmpty && !cores.any((c) => c.isInstalled)) {
      notes.add(
        'No board platform is installed, so there are no FQBNs to compile for. '
        'Install one with `arduino-cli core install arduino:avr` or the '
        'platform your board needs.',
      );
    }

    return ArduinoInventory(
      version: version,
      ports: ports.ports,
      boards: boards,
      cores: cores,
      sketches: sketches,
      sketchbookPath: sketchbook,
      notes: notes,
    );
  }

  /// Where `arduino-cli` keeps sketches, with the IDE's default as a fallback
  /// when the CLI has no configuration yet. The fallback is also what a first
  /// `sketch new` writes into, so an unconfigured machine still works.
  Future<String> _sketchbookPath(String cli) async {
    final result = await _run(cli, const [
      'config',
      'get',
      'directories.user',
    ], timeout: const Duration(seconds: 10));
    if (result.ok) {
      final path = parseSketchbookPath(result.stdout);
      if (path.isNotEmpty) return path;
    }
    return _defaultSketchbook;
  }

  /// The IDE's own first-run default: `~/Documents/Arduino` on macOS and
  /// Windows, `~/Arduino` on Linux. Only used when the CLI has no configuration
  /// yet, and then also used by `sketch new` so the created sketch is one the
  /// next scan will find.
  static String get _defaultSketchbook {
    final sep = Platform.pathSeparator;
    if (Platform.isLinux) return '${Paths.home}${sep}Arduino';
    return '${Paths.home}${sep}Documents${sep}Arduino';
  }

  @override
  Future<ArduinoSketch> newSketch(String name) async {
    final cli = _cli;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ToolException(
        'BAD_NAME',
        'A sketch needs a name before it can be created.',
      );
    }
    if (trimmed == '.' ||
        trimmed == '..' ||
        trimmed.startsWith('.') ||
        RegExp(r'[\\/:*?"<>|]').hasMatch(trimmed)) {
      throw ToolException(
        'BAD_NAME',
        '"$trimmed" is not a sketch name. Use letters, digits, spaces, dots, '
            'dashes or underscores — no path separators.',
      );
    }

    final sketchbook = await _sketchbookPath(cli);
    final book = Directory(sketchbook);
    try {
      book.createSync(recursive: true);
    } on FileSystemException catch (error) {
      throw ToolException(
        'CREATE_FAILED',
        'Could not create the sketchbook at $sketchbook: ${error.message}',
      );
    }

    final target = '${book.path}${Platform.pathSeparator}$trimmed';
    if (Directory(target).existsSync()) {
      throw ToolException(
        'SKETCH_EXISTS',
        'There is already a sketch at $target. Choose another name, or open '
            'the existing one.',
      );
    }

    final result = await _run(cli, [
      'sketch',
      'new',
      target,
    ], timeout: const Duration(seconds: 30));
    if (!result.ok) {
      throw ToolException(
        'ARDUINO_FAILED',
        _firstLine(result.blurb).isEmpty
            ? 'arduino-cli sketch new failed.'
            : _firstLine(result.blurb),
        detail:
            'command: arduino-cli sketch new $target\n'
            'exit code: ${result.exitCode}',
      );
    }

    final sketch = resolveSketch(target);
    if (sketch == null) {
      throw ToolException(
        'NO_SKETCH',
        'The CLI reported success, but no .ino file appeared at $target.',
      );
    }
    return sketch;
  }

  @override
  Future<ArduinoSketchFile> readSketch(String path) async {
    final sketch = resolveSketch(path);
    if (sketch == null) {
      throw ToolException(
        'NO_SKETCH',
        'There is no sketch at "$path". A sketch is a folder with a matching '
            '.ino file inside it.',
      );
    }
    final file = File(sketch.inoPath);
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw ToolException(
          'NO_SKETCH',
          '${sketch.inoPath} is not a file that can be edited.',
        );
      }
      // A sketch is source, not a log. Refusing an enormous file keeps a
      // mistaken path from putting a whole disk image in a text field.
      if (stat.size > 2 * 1024 * 1024) {
        throw ToolException(
          'TOO_LARGE',
          '${sketch.inoPath} is larger than 2 MB, so it was not opened.',
        );
      }
      return ArduinoSketchFile(
        path: sketch.inoPath,
        contents: await file.readAsString(),
      );
    } on FileSystemException catch (error) {
      throw ToolException(
        'READ_FAILED',
        'Could not read ${sketch.inoPath}: ${error.message}',
      );
    }
  }

  @override
  Future<void> writeSketch(String path, String contents) async {
    final sketch = resolveSketch(path);
    if (sketch == null) {
      throw ToolException(
        'NO_SKETCH',
        'There is no sketch at "$path", so there is nothing to save.',
      );
    }
    try {
      await File(sketch.inoPath).writeAsString(contents, flush: true);
    } on FileSystemException catch (error) {
      throw ToolException(
        'WRITE_FAILED',
        'Could not save ${sketch.inoPath}: ${error.message}',
      );
    }
  }

  @override
  Stream<String> compile(ArduinoConfig config) {
    final sketch = resolveSketch(config.sketchPath);
    if (sketch == null) {
      return _refuse(
        'NO_SKETCH',
        'Choose a sketch before compiling. "${config.sketchPath}" does not name '
            'a folder with a .ino file in it.',
      );
    }
    final fqbn = config.fqbn.trim();
    if (fqbn.isEmpty) {
      return _refuse(
        'NO_BOARD',
        'Choose a board before compiling; the toolchain needs an FQBN.',
      );
    }
    final cli = cliPath;
    if (cli == null) {
      return _refuse(
        'NO_ARDUINO_CLI',
        'There is no arduino-cli on this machine, so there is nothing to '
            'compile with.',
      );
    }
    return _runner.streamLines(cli, [
      'compile',
      '--fqbn',
      fqbn,
      sketch.directory,
    ]);
  }

  @override
  Stream<String> upload(ArduinoConfig config) {
    final sketch = resolveSketch(config.sketchPath);
    if (sketch == null) {
      return _refuse(
        'NO_SKETCH',
        'Choose a sketch before uploading. "${config.sketchPath}" does not name '
            'a folder with a .ino file in it.',
      );
    }
    final fqbn = config.fqbn.trim();
    if (fqbn.isEmpty) {
      return _refuse(
        'NO_BOARD',
        'Choose a board before uploading; the toolchain needs an FQBN.',
      );
    }
    final port = config.port.trim();
    if (port.isEmpty) {
      return _refuse(
        'NO_PORT',
        'Choose the port the board is on before uploading.',
      );
    }
    final cli = cliPath;
    if (cli == null) {
      return _refuse(
        'NO_ARDUINO_CLI',
        'There is no arduino-cli on this machine, so there is nothing to '
            'upload with.',
      );
    }
    return _runner.streamLines(cli, [
      'upload',
      '-p',
      port,
      '--fqbn',
      fqbn,
      sketch.directory,
    ]);
  }

  @override
  Stream<String> monitor(String port, int baud) {
    final address = port.trim();
    if (address.isEmpty) {
      return _refuse('NO_PORT', 'Choose the port to open the monitor on.');
    }
    final cli = cliPath;
    if (cli == null) {
      return _refuse(
        'NO_ARDUINO_CLI',
        'There is no arduino-cli on this machine, so there is no monitor to '
            'open.',
      );
    }
    return _runner.streamLines(cli, [
      'monitor',
      '-p',
      address,
      '--config',
      'baudrate=$baud',
    ]);
  }

  @override
  Future<ArduinoConfig> readConfig() async {
    if (!await _configFile.exists()) return const ArduinoConfig();
    try {
      final raw = await _configFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('settings are not a JSON object');
      }
      return ArduinoConfig.fromJson(decoded);
    } on FormatException {
      throw ToolException(
        'BAD_CONFIG',
        'The saved Arduino settings could not be read, so nothing was selected. '
            'Choose a sketch and board again.',
        detail: _configFile.path,
      );
    } on FileSystemException catch (error) {
      throw ToolException(
        'READ_FAILED',
        'Could not read ${_configFile.path}: ${error.message}',
      );
    }
  }

  @override
  Future<void> writeConfig(ToolConfig config) async {
    final arduino = expectConfig<ArduinoConfig>(config, 'Arduino');
    try {
      await _configFile.parent.create(recursive: true);
      await _configFile.writeAsString(
        jsonEncode(arduino.toJson()),
        flush: true,
      );
    } on FileSystemException catch (error) {
      throw ToolException(
        'WRITE_FAILED',
        'Could not save the Arduino settings to ${_configFile.path}: '
            '${error.message}',
      );
    }
  }

  Future<ProcResult> _mustOk(
    String cli,
    List<String> args, {
    required String what,
    required Duration timeout,
  }) async {
    final result = await _run(cli, args, timeout: timeout);
    if (result.ok) return result;
    throw ToolException(
      'ARDUINO_FAILED',
      _firstLine(result.blurb).isEmpty
          ? '$what exited with code ${result.exitCode}.'
          : _firstLine(result.blurb),
      detail:
          'command: arduino-cli ${args.join(' ')}\n'
          'exit code: ${result.exitCode}',
    );
  }

  Future<ProcResult> _run(
    String cli,
    List<String> args, {
    required Duration timeout,
  }) => _runner.run(cli, args, timeout: timeout);

  Stream<String> _refuse(String code, String message) =>
      Stream<String>.error(ToolException(code, message));

  @override
  Future<void> start() async => _noAgent('start');

  @override
  Future<void> stop() async => _noAgent('stop');

  @override
  Future<void> install() async => _noAgent('install');

  @override
  Future<void> uninstall() async => _noAgent('uninstall');

  @override
  Stream<String> tailLog() => Stream<String>.error(
    const ToolException(
      'NO_LOG',
      'Arduino Bench is not an agent this app runs, so there is no log to '
          'follow. Compile and upload output appears in the console itself.',
    ),
  );

  Never _noAgent(String what) => throw ToolException(
    'NO_AGENT',
    'Arduino Bench has no background agent for this app to $what. It runs '
        'arduino-cli on demand.',
  );

  static String _firstLine(String text) {
    final trimmed = text.trim();
    final at = trimmed.indexOf('\n');
    return at < 0 ? trimmed : trimmed.substring(0, at).trim();
  }
}
