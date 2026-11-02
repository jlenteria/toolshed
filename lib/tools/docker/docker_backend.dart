import 'dart:io';

import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/paths.dart';
import '../../platform/runner.dart';
import '../tool_backend.dart';
import 'docker_engine.dart';
import 'docker_models.dart';
import 'docker_parsers.dart';

const String kDockerId = 'docker';

/// A lightweight Docker console, driven entirely through the `docker` CLI.
///
/// This class holds no container logic and belongs to no single engine. It finds
/// the standard `docker` binary, runs `docker ps`/`images`/`system df` and reads
/// what the CLI printed, and it sends lifecycle commands the same way. The
/// engine's context, socket and `DOCKER_HOST` are resolved by the CLI itself —
/// the child inherits this process's environment — so uninstalling one runtime
/// (OrbStack) and installing or starting another (Docker Desktop, a plain
/// `dockerd`, Colima) needs no change here: the next scan finds whichever CLI is
/// now on `PATH` and talks to whatever context is now active.
///
/// A daemon that is not reachable is reported as a failure carrying docker's own
/// message, never as an empty list. The distinction matters: "you have no
/// containers" and "I could not reach the engine you pointed me at" are
/// different truths, and the second one tells the user what to do about it.
class DockerBackend implements ToolBackend, DockerManager {
  DockerBackend({
    ProcessRunner? runner,
    String? dockerPath,
    String? Function()? discover,
    DockerEngineManager? Function()? engineDiscover,
  }) : _runner = runner ?? const ProcessRunner(),
       _requestedPath = dockerPath,
       _discover = discover ?? Paths.dockerBinary,
       _engineDiscover = engineDiscover ?? discoverEngineManager;

  final ProcessRunner _runner;
  final String? _requestedPath;
  final String? Function() _discover;
  final DockerEngineManager? Function() _engineDiscover;

  String? _resolved;
  bool _resolvedOnce = false;

  DockerEngineManager? _engine;
  bool _engineOnce = false;

  /// The `docker` binary this console talks to, resolved once per instance.
  ///
  /// Every button is gated on this being non-null, so an engine that was
  /// uninstalled — leaving a dangling symlink or no binary at all — resolves to
  /// null and the tool lists itself with a reason rather than a broken button. A
  /// requested path that has gone missing falls back to discovery rather than
  /// promising to run a binary that is not there, which is exactly what
  /// switching from OrbStack to another engine looks like mid-session.
  String? get dockerPath {
    if (_resolvedOnce) return _resolved;
    _resolvedOnce = true;
    final requested = _requestedPath;
    if (requested != null && File(requested).existsSync()) {
      return _resolved = requested;
    }
    return _resolved = _discover();
  }

  String get _cli =>
      dockerPath ??
      (throw const ToolException(
        'NO_DOCKER',
        'There is no docker CLI on this machine, so there is nothing to list or '
            'to act on. Install an engine — Docker Desktop, OrbStack, Colima or '
            'a plain dockerd — and this tool will light up.',
      ));

  /// The manager that can start/stop the engine here, resolved once.
  ///
  /// Independent of [dockerPath]: an engine that is switched off still has a
  /// manager to switch it on, and asking it is what makes the console useful in
  /// exactly that moment. Null when the machine runs a bare `dockerd` or has no
  /// engine to reach.
  @override
  DockerEngineManager? get engineManager {
    if (_engineOnce) return _engine;
    _engineOnce = true;
    return _engine = _engineDiscover();
  }

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kDockerId,
    name: 'Docker',
    summary:
        'Lists your containers and images and lets you start, stop, restart or '
        'remove a container and prune dangling images, through the docker CLI.',
    implPath: 'docker',
  );

  @override
  Capabilities get capabilities {
    final cli = dockerPath;
    final engine = engineManager;

    if (cli == null && engine == null) {
      return const Capabilities(
        support: Support.helperMissing,
        actions: {},
        reason:
            'Docker is driven by the docker command-line tool, and none was '
            'found on this machine. It is engine-agnostic — OrbStack, Docker '
            'Desktop, Colima or a plain dockerd all work — but one of them '
            'has to be installed.',
      );
    }

    final actions = <ToolAction>{
      // The container reads and lifecycle only make sense with a CLI to speak
      // through.
      if (cli != null) ...const {
        ToolAction.showDocker,
        ToolAction.dockerStart,
        ToolAction.dockerStop,
        ToolAction.dockerRestart,
        ToolAction.dockerRemove,
        ToolAction.dockerPrune,
        ToolAction.dockerOpenPort,
      },
      // Bringing the engine up or down is a manager's job, advertised whenever
      // one is installed — including when the daemon is currently off.
      if (engine != null) ...const {
        ToolAction.dockerStartEngine,
        ToolAction.dockerStopEngine,
      },
    };

    return Capabilities(
      support: Support.full,
      actions: actions,
      reason: cli != null
          ? 'Reads containers and images with the docker CLI on demand. Start, '
                'stop, restart, remove and prune send the matching docker '
                'command to whatever context the CLI currently points at; the '
                'engine decides whether each one succeeds. A published port '
                'opens in the browser.'
                '${engine == null ? '' : ' Starting or stopping the engine runs '
                          '${engine.label}\'s own command.'}'
          : 'No docker CLI was found yet, but ${engine!.label} is installed '
                'here. Start it from this console and the CLI it brings with it '
                'lights the rest of the tool up.',
    );
  }

  @override
  Future<AgentStatus> status() async {
    final cli = dockerPath;
    if (cli == null) {
      return const AgentStatus.notApplicable().withNotes([
        'No docker CLI was found on PATH or in the usual install locations, so '
            'there is nothing to read. Install an engine and this tool lights '
            'up.',
      ]);
    }
    final result = await _run(cli, const [
      'info',
      '--format',
      '{{.ServerVersion}}\t{{.Name}}',
    ], timeout: const Duration(seconds: 15));
    if (result.ok) {
      final fields = result.stdout.trim().split('\t');
      final version = fields.isNotEmpty ? fields[0].trim() : '';
      final host = fields.length > 1 ? fields[1].trim() : '';
      return const AgentStatus.notApplicable().withNotes([
        'Docker ${version.isEmpty ? 'engine' : 'v$version'}'
            '${host.isEmpty ? '' : ' on $host'} — read on demand with the '
            'docker CLI; nothing is installed here and nothing runs in the '
            'background.',
        'It uses this machine\'s current docker context, so switching between '
            'OrbStack, Docker Desktop or a plain dockerd needs no change here.',
      ]);
    }
    final engine = engineManager;
    return const AgentStatus.notApplicable().withNotes([
      'The docker CLI is present, but its daemon did not answer: '
          '${_firstLine(result.blurb)}',
      if (engine != null)
        'A manager for it was found — ${engine.label} — so the console can '
            'start the engine for you. Otherwise point the context at an '
            'engine that is already running.'
      else
        'Start an engine, or point the context at one that is running.',
    ]);
  }

  @override
  Future<DockerInventory> inventory() async {
    final cli = _cli;
    final ps = await _mustOk(cli, const [
      'ps',
      '-a',
      '--format',
      '{{json .}}',
    ], what: 'docker ps');
    final imgs = await _mustOk(cli, const [
      'images',
      '--format',
      '{{json .}}',
    ], what: 'docker images');
    final containers = parseContainers(ps);
    final images = parseImages(imgs);

    // Disk usage is the one reader that can fail on an otherwise healthy engine
    // (some drivers do not report build cache), so it degrades to an empty table
    // with a note rather than taking the whole console down.
    List<DockerDiskLine> disk = const [];
    final notes = <String>[
      if (containers.partial != null) 'containers: ${containers.partial}',
      if (images.partial != null) 'images: ${images.partial}',
    ];
    try {
      final df = await _run(cli, const [
        'system',
        'df',
        '--format',
        '{{json .}}',
      ], timeout: const Duration(seconds: 20));
      if (df.ok) {
        final parsed = parseSystemDf(df.stdout);
        disk = parsed.disk;
        if (parsed.partial != null) notes.add('disk: ${parsed.partial}');
      } else {
        notes.add('disk usage was unavailable: ${_firstLine(df.blurb)}');
      }
    } on ToolException {
      notes.add('disk usage could not be read.');
    }

    return DockerInventory(
      containers: containers.containers,
      images: images.images,
      disk: disk,
      notes: notes,
    );
  }

  @override
  Future<DockerActionResult> containerAction(
    DockerContainer container,
    DockerOp op,
  ) async {
    final cli = _cli;
    final args = switch (op) {
      DockerOp.start => ['start', container.id],
      DockerOp.stop => ['stop', container.id],
      DockerOp.restart => ['restart', container.id],
      DockerOp.remove => ['rm', '-f', container.id],
    };
    final result = await _run(cli, args, timeout: const Duration(seconds: 60));
    if (!result.ok) {
      throw ToolException(
        'DOCKER_FAILED',
        _firstLine(result.blurb).isEmpty
            ? 'docker ${args.join(' ')} failed.'
            : _firstLine(result.blurb),
        detail:
            'command: docker ${args.join(' ')}\nexit code: ${result.exitCode}',
      );
    }
    final verb = switch (op) {
      DockerOp.start => 'started',
      DockerOp.stop => 'stopped',
      DockerOp.restart => 'restarted',
      DockerOp.remove => 'removed',
    };
    return DockerActionResult(message: '${container.primaryName} $verb.');
  }

  @override
  Future<DockerActionResult> pruneImages() async {
    final cli = _cli;
    final result = await _run(cli, const [
      'image',
      'prune',
      '-f',
    ], timeout: const Duration(seconds: 120));
    if (!result.ok) {
      throw ToolException(
        'DOCKER_FAILED',
        _firstLine(result.blurb).isEmpty
            ? 'docker image prune failed.'
            : _firstLine(result.blurb),
        detail: 'command: docker image prune -f\nexit code: ${result.exitCode}',
      );
    }
    final match = RegExp(
      r'Total reclaimed space:\s*(.+)',
    ).firstMatch(result.stdout);
    return DockerActionResult(
      message: 'Dangling images pruned.',
      reclaimed: match?.group(1)?.trim() ?? '',
    );
  }

  @override
  Future<DockerActionResult> openPort(DockerPortMapping port) async {
    final url = port.url;
    if (url == null) {
      throw ToolException(
        'NOT_PUBLISHED',
        '${port.label} is exposed inside the container but not published on a '
            'host port, so there is nothing for a browser to reach.',
      );
    }
    // The URL is not free text: the console built it from a digits-only host
    // port, so the browser receives exactly http://localhost:<port>. No shell is
    // involved — the OS handler is handed the URL as one argument.
    final (opener, args) = _browserOpener(url);
    final result = await _runner.run(
      opener,
      args,
      timeout: const Duration(seconds: 20),
    );
    if (!result.ok) {
      throw ToolException(
        'OPEN_FAILED',
        _firstLine(result.blurb).isEmpty
            ? 'Could not open $url in the browser.'
            : _firstLine(result.blurb),
        detail: 'command: $opener ${args.join(' ')}\nexit code: ${result.exitCode}',
      );
    }
    return DockerActionResult(message: 'Opened $url.');
  }

  /// The platform's own "open this URL in the default browser" command. macOS
  /// and Linux have a single-argument handler; Windows' `start` is a cmd
  /// builtin, so it runs through `cmd /c` with an empty window-title argument
  /// (without it `start` would treat the URL as the title and not open it).
  static (String, List<String>) _browserOpener(String url) {
    if (Platform.isWindows) return ('cmd', <String>['/c', 'start', '', url]);
    if (Platform.isLinux) return ('xdg-open', <String>[url]);
    return ('open', <String>[url]);
  }

  @override
  Future<DockerActionResult> startEngine() => _engineOp(start: true);

  @override
  Future<DockerActionResult> stopEngine() => _engineOp(start: false);

  /// Runs the discovered manager's own command. No engine logic is duplicated
  /// here: `colima start` and `open -a Docker` are handed to the process runner
  /// and whatever the manager prints is what the console reports.
  Future<DockerActionResult> _engineOp({required bool start}) async {
    final engine = engineManager;
    if (engine == null) {
      throw const ToolException(
        'NO_ENGINE',
        'There is no engine manager here to start or stop. This machine either '
            'has no Docker engine installed, or runs one the console cannot '
            'reach (a plain dockerd started by hand).',
      );
    }
    final argv = start ? engine.start : engine.stop;
    // A cold engine can take a minute or more to boot its VM, so start gets a
    // long leash; the console reloads once the command returns and the daemon
    // answers on the next scan.
    final result = await _runner.run(
      argv.first,
      argv.sublist(1),
      timeout: const Duration(seconds: 180),
    );
    if (!result.ok) {
      throw ToolException(
        'ENGINE_FAILED',
        _firstLine(result.blurb).isEmpty
            ? '${engine.label} ${start ? 'start' : 'stop'} failed.'
            : _firstLine(result.blurb),
        detail: 'command: ${argv.join(' ')}\nexit code: ${result.exitCode}',
      );
    }
    return DockerActionResult(
      message: start
          ? '${engine.label} started — the engine will answer on the next '
                'scan.'
          : '${engine.label} stopped — every container on it is down.',
    );
  }

  /// Runs docker and returns stdout, throwing docker's own message on a
  /// non-zero exit. An empty-but-successful stdout is a legitimately empty
  /// answer and is returned as such, exactly like the port scanners distinguish
  /// "no listeners" from "lsof failed."
  Future<String> _mustOk(
    String cli,
    List<String> args, {
    required String what,
  }) async {
    final result = await _run(cli, args, timeout: const Duration(seconds: 30));
    if (result.ok) return result.stdout;
    throw ToolException(
      'DOCKER_FAILED',
      _firstLine(result.blurb).isEmpty
          ? '$what exited with code ${result.exitCode}.'
          : _firstLine(result.blurb),
      detail: 'command: docker ${args.join(' ')}',
    );
  }

  Future<ProcResult> _run(
    String cli,
    List<String> args, {
    required Duration timeout,
  }) => _runner.run(cli, args, timeout: timeout);

  @override
  Future<void> start() async => _noAgent('start');

  @override
  Future<void> stop() async => _noAgent('stop');

  @override
  Future<void> install() async => _noAgent('install');

  @override
  Future<void> uninstall() async => _noAgent('uninstall');

  @override
  Future<ToolConfig> readConfig() async => throw const ToolException(
    'NO_SETTINGS',
    'Docker has no settings here: containers and images are read fresh from '
        'the engine each time the console opens.',
  );

  @override
  Future<void> writeConfig(ToolConfig config) async =>
      throw const ToolException(
        'NO_SETTINGS',
        'Docker has no settings to write.',
      );

  @override
  Stream<String> tailLog() => Stream<String>.error(
    const ToolException(
      'NO_LOG',
      'Docker is not an agent this app runs, so there is no log to follow.',
    ),
  );

  Never _noAgent(String what) => throw ToolException(
    'NO_AGENT',
    'Docker has no background agent for this app to $what. It drives the '
        'docker CLI on demand.',
  );

  static String _firstLine(String text) {
    final trimmed = text.trim();
    final at = trimmed.indexOf('\n');
    return at < 0 ? trimmed : trimmed.substring(0, at).trim();
  }
}
