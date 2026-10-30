import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/log_tail.dart';
import '../../platform/paths.dart';
import '../../platform/runner.dart';
import '../tool_backend.dart';
import 'launchctl_parse.dart';
import 'managed_app.dart';
import 'mem_reaper_config.dart';
import 'plist_args.dart';
import 'stop_outcome.dart';

/// The label the agent is installed under, and the one the pre-existing agent
/// was renamed to. `install` writes this same label and never a second one: two
/// agents watching the same processes means two dialogs per memory hog.
const String kMemReaperAgentLabel = 'com.bling.memreaper';

class DiscoveredAgent {
  const DiscoveredAgent({
    required this.label,
    required this.plistPath,
    required this.argv,
    required this.interpreterPath,
    this.logPath,
    this.sessionType,
    this.throttleInterval = 10,
  });

  final String label;
  final String plistPath;
  final PlistArgs argv;

  /// ProgramArguments[0] as the plist declares it.
  final String interpreterPath;

  final String? logPath;

  /// Must stay `Aqua`, or the confirmation dialogs never appear.
  final String? sessionType;

  final int throttleInterval;

  bool get loadsInAqua => sessionType == 'Aqua';
}

class Discovery {
  const Discovery(this.agent, this.all, this.problems);

  final DiscoveredAgent? agent;
  final List<DiscoveredAgent> all;
  final List<String> problems;
}

/// Drives mem_reaper.py through launchd. macOS only, and deliberately holding
/// no kill logic of its own.
class MacOSMemReaperBackend
    implements ToolBackend, MemoryRanking, ProcessReaper {
  MacOSMemReaperBackend({ProcessRunner? runner, String? homeOverride})
    : _runner = runner ?? const ProcessRunner(),
      _home = homeOverride;

  final ProcessRunner _runner;
  final String? _home;

  DiscoveredAgent? _agent;
  String? _uid;
  String? _notice;

  @override
  ToolDescriptor get descriptor => ToolDescriptor(
    id: 'mem_reaper',
    name: 'Memory Reaper',
    summary:
        'Force-stops your own processes over a memory limit, asking '
        'you to confirm each one with a macOS dialog.',
    implPath: _agent?.argv.script ?? Paths.scriptPath() ?? 'mem_reaper.py',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {
      ToolAction.start,
      ToolAction.stop,
      ToolAction.install,
      ToolAction.uninstall,
      ToolAction.configure,
      ToolAction.tailLogs,
      ToolAction.reapNow,
      ToolAction.forceStop,
      ToolAction.showRanking,
    },
    reason: 'mem_reaper runs natively on macOS.',
  );

  String get _agentsDir =>
      _home == null ? Paths.launchAgents.path : '$_home/Library/LaunchAgents';

  Future<String> _uidOrFail() async {
    if (_uid != null) return _uid!;
    final result = await _runner.run('id', ['-u']);
    final uid = int.tryParse(result.stdout.trim());
    if (uid == null) {
      throw const ToolException(
        'NO_UID',
        'Could not determine your uid, so the app cannot address the launchd '
            'gui domain.',
      );
    }
    return _uid = '$uid';
  }

  // ---------------------------------------------------------------- discovery

  /// Finds the plist that actually runs mem_reaper by looking for a
  /// ProgramArguments entry ending in `mem_reaper.py` rather than trusting a
  /// file name, and reports duplicates — a second plist claiming the same Label
  /// is the likeliest reason a bootstrap would fail.
  Future<Discovery> discover() async {
    final problems = <String>[];
    final found = <DiscoveredAgent>[];

    final dir = Directory(_agentsDir);
    if (!dir.existsSync()) {
      _agent = null;
      return Discovery(null, const [], ['$_agentsDir does not exist.']);
    }

    final plists =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.plist'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in plists) {
      final plist = await _readPlistJson(file.path);
      if (plist == null) {
        problems.add('${_basename(file.path)} is not readable as a plist.');
        continue;
      }
      final argv = _argvFrom(plist);
      if (argv == null || !argv.argv.any((a) => a.endsWith('mem_reaper.py'))) {
        continue;
      }
      final label =
          _stringOrNull(plist['Label']) ??
          _basename(file.path).replaceAll('.plist', '');
      found.add(
        DiscoveredAgent(
          label: label,
          plistPath: file.path,
          argv: argv,
          logPath: _stringOrNull(plist['StandardOutPath']),
          interpreterPath: _stringOrNull(plist['Program']) ?? argv.interpreter,
          sessionType: _stringOrNull(plist['LimitLoadToSessionType']),
          throttleInterval: (plist['ThrottleInterval'] as num?)?.toInt() ?? 10,
        ),
      );
    }

    if (found.isEmpty) {
      _agent = null;
      if (plists.isNotEmpty) {
        problems.add(
          'None of the ${plists.length} plists in $_agentsDir run '
          'mem_reaper.py.',
        );
      }
      return Discovery(null, const [], problems);
    }

    _agent = found.first;
    if (found.length > 1) {
      problems.add(
        '${found.length} plists reference mem_reaper.py '
        '(${found.map((a) => a.label).join(', ')}). This app controls '
        '"${found.first.label}" and leaves the others alone — it will not '
        'load a second one, because two agents watching the same processes '
        'each raise their own dialog.',
      );
    }
    if (!found.first.loadsInAqua) {
      problems.add(
        'LimitLoadToSessionType is '
        '"${found.first.sessionType ?? 'unset'}", not Aqua — the agent runs '
        'but its confirmation dialogs will not show.',
      );
    }
    return Discovery(_agent, found, problems);
  }

  Future<Map<String, Object?>?> _readPlistJson(String path) async {
    final result = await _runner.run('plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      path,
    ]);
    if (!result.ok) return null;
    try {
      final decoded = jsonDecode(result.stdout);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  PlistArgs? _argvFrom(Map<String, Object?> plist) {
    final value = plist['ProgramArguments'];
    if (value is List && value.isNotEmpty) {
      return PlistArgs(value.map((e) => '$e').toList(growable: false));
    }
    // A plist with only `Program` has no flags to manage, but it can still be
    // the agent. One element keeps the shape uniform; a write then appends.
    final program = _stringOrNull(plist['Program']);
    return program == null ? null : PlistArgs([program]);
  }

  static String _basename(String path) => path.split('/').last;

  static String? _stringOrNull(Object? value) {
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  Future<DiscoveredAgent> _requireAgent() async {
    final agent = (await discover()).agent;
    if (agent == null) {
      throw ToolException(
        'NOT_INSTALLED',
        'No agent in $_agentsDir runs mem_reaper.py, so there is nothing to '
            'control. Install one first.',
      );
    }
    return agent;
  }

  // ------------------------------------------------------------------- status

  @override
  Future<AgentStatus> status() async {
    final discovery = await discover();
    final agent = discovery.agent;
    if (agent == null) {
      _notice = null;
      return AgentStatus(
        state: AgentState.notInstalled,
        notes: [
          ...discovery.problems,
          'Install an agent to start watching memory.',
        ],
      );
    }

    final uid = await _uidOrFail();
    final result = await _runner.run('launchctl', [
      'print',
      'gui/$uid/${agent.label}',
    ]);
    final notes = <String>[...discovery.problems, ?_notice];

    if (LaunchctlInfo.notLoaded(
      result.exitCode,
      '${result.stdout}${result.stderr}',
    )) {
      return AgentStatus(
        state: AgentState.installedStopped,
        plistPath: agent.plistPath,
        logPath: agent.logPath,
        notes: [...notes, 'Press Start to bootstrap it into the gui session.'],
      );
    }
    if (!result.ok) {
      return AgentStatus(
        state: AgentState.unknown,
        plistPath: agent.plistPath,
        logPath: agent.logPath,
        notes: [...notes, result.blurb],
      );
    }

    final info = LaunchctlInfo.parse(result.stdout);
    final AgentState state;
    if (info.isRunning && info.pid != null) {
      state = AgentState.running;
    } else if (info.isRunning) {
      state = AgentState.unknown;
      notes.add(
        'launchctl says running with no pid — the agent is either '
        'spawning or wedged. Read the log.',
      );
    } else {
      state = AgentState.installedStopped;
    }
    if (info.lastExitCode != null && info.lastExitCode != 0) {
      notes.add(
        'Last exit code was ${info.lastExitCode}: mem_reaper stopped on '
        'its own. Read the log before starting it again.',
      );
    }
    return AgentStatus(
      state: state,
      pid: info.pid,
      runs: info.runs,
      lastExitCode: info.lastExitCode,
      plistPath: agent.plistPath,
      logPath: agent.logPath ?? info.stdoutPath,
      notes: notes,
    );
  }

  // -------------------------------------------------------------- start / stop

  @override
  Future<void> start() async {
    final agent = await _requireAgent();
    final uid = await _uidOrFail();
    _notice = null;
    final result = await _runner.run('launchctl', [
      'bootstrap',
      'gui/$uid',
      agent.plistPath,
    ]);
    // 503 already-bootstrapped is the state we wanted.
    if (!result.ok && !result.blurb.toLowerCase().contains('already')) {
      throw ToolException(
        'BOOTSTRAP_FAILED',
        result.blurb.isEmpty ? 'launchctl bootstrap failed.' : result.blurb,
        detail:
            'command: launchctl bootstrap gui/$uid ${agent.plistPath}\n'
            'exit code: ${result.exitCode}\n'
            'If a second plist declares Label ${agent.label}, that is the '
            'collision to fix.',
      );
    }
    await _expectRunning(agent);
  }

  @override
  Future<void> stop() async {
    final agent = await _requireAgent();
    final uid = await _uidOrFail();
    _notice = null;
    // bootout, never a kill: KeepAlive respawns a killed process within
    // ThrottleInterval, which would make the button look broken.
    final result = await _runner.run('launchctl', [
      'bootout',
      'gui/$uid/${agent.label}',
    ]);
    if (!result.ok &&
        !LaunchctlInfo.alreadyGone(result.exitCode, result.blurb)) {
      throw ToolException(
        'BOOTOUT_FAILED',
        result.blurb,
        detail:
            'command: launchctl bootout gui/$uid/${agent.label}\n'
            'exit code: ${result.exitCode}',
      );
    }
  }

  Future<void> _expectRunning(DiscoveredAgent agent) async {
    final uid = await _uidOrFail();
    final target = 'gui/$uid/${agent.label}';
    var last = 'launchctl print returned nothing useful.';
    for (var attempt = 0; attempt < 10; attempt++) {
      final result = await _runner.run('launchctl', ['print', target]);
      if (result.ok) {
        final info = LaunchctlInfo.parse(result.stdout);
        if (info.isRunning && info.pid != null) {
          _notice = 'Agent is running as pid ${info.pid}.';
          return;
        }
        last =
            'state = ${info.state ?? 'unknown'}, pid = ${info.pid ?? 'none'}';
      } else {
        last = result.blurb;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw ToolException(
      'NOT_RUNNING_AFTER_CHANGE',
      'The agent was submitted but never reached `state = running` with a pid '
          'within 5s.',
      detail:
          'target: $target\nlast seen: $last\n'
          'ThrottleInterval is ${agent.throttleInterval}s, so launchd may be '
          'rate-limiting a crash loop. Read the log.',
    );
  }

  // ------------------------------------------------------------ install/remove

  @override
  Future<void> install() async {
    final existing = (await discover()).agent;
    if (existing != null) {
      throw ToolException(
        'ALREADY_INSTALLED',
        'An agent is already installed as "${existing.label}". Start or stop '
            'that one — the app will not add a second, because two agents would '
            'each raise their own dialog for the same process.',
      );
    }
    final script = Paths.scriptPath();
    if (script == null) {
      throw ToolException(
        'SCRIPT_NOT_FOUND',
        'mem_reaper.py was not found in any usual place, so there is nothing to '
            'install an agent for.',
        detail: 'looked in:\n  ${Paths.scriptCandidates().join('\n  ')}',
      );
    }
    // Never rewritten to a newer python: the plist points at /usr/bin/python3,
    // and mem_reaper only runs on that 3.9 because of its
    // `from __future__ import annotations`.
    final python = Paths.interpreter();
    if (python == null) {
      throw const ToolException(
        'NO_PYTHON',
        'No python3 was found. The app will not point an agent at an '
            'interpreter that does not exist.',
      );
    }

    final logPath = '${_home ?? Paths.home}/Library/Logs/mem_reaper.log';
    final dir = Directory(_agentsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/$kMemReaperAgentLabel.plist');
    if (file.existsSync()) {
      // A plist that discovery did not recognise still must not be overwritten
      // without a copy left behind.
      final kept = await _backup(file.path, 'was-not-mem-reaper');
      _notice = 'The unrelated plist that was there is kept at $kept.';
    }
    await file.writeAsString(
      plistTemplate(
        python: python,
        script: script,
        config: MemReaperConfig.defaults,
        logPath: logPath,
      ),
    );

    final lint = await _runner.run('plutil', ['-lint', file.path]);
    if (!lint.ok) {
      await file.delete();
      throw ToolException(
        'PLIST_INVALID',
        'The plist the app wrote did not pass plutil -lint, so it was deleted '
            'rather than handed to launchd.',
        detail: lint.blurb,
      );
    }
    final logParent = File(logPath).parent;
    if (!logParent.existsSync()) logParent.createSync(recursive: true);

    await start();
  }

  @override
  Future<void> uninstall() async {
    final agent = await _requireAgent();
    final uid = await _uidOrFail();
    await _runner.run('launchctl', ['bootout', 'gui/$uid/${agent.label}']);
    // Renamed rather than removed outright: the plist is the only record of how
    // the agent was configured, and a stray delete cannot be undone.
    final kept = await _backup(agent.plistPath, 'uninstalled');
    _notice = 'The agent was unloaded and its plist kept at $kept.';
    _agent = null;
  }

  Future<String> _backup(String path, String tag) async {
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final target = '$path.$tag-$stamp';
    await File(path).copy(target);
    if (tag == 'uninstalled') await File(path).delete();
    return target;
  }

  static String plistTemplate({
    required String python,
    required String script,
    required MemReaperConfig config,
    required String logPath,
  }) {
    String esc(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final args = [
      python,
      script,
      '--service',
      MemReaperConfig.thresholdFlag,
      '${config.thresholdMb}',
      MemReaperConfig.intervalFlag,
      '${config.intervalSeconds}',
      MemReaperConfig.dialogTimeoutFlag,
      '${config.dialogTimeoutSeconds}',
    ];
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>${esc(kMemReaperAgentLabel)}</string>
\t<key>ProgramArguments</key>
\t<array>
${args.map((a) => '\t\t<string>${esc(a)}</string>').join('\n')}
\t</array>
\t<key>LimitLoadToSessionType</key>
\t<string>Aqua</string>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<true/>
\t<key>ThrottleInterval</key>
\t<integer>10</integer>
\t<key>StandardOutPath</key>
\t<string>${esc(logPath)}</string>
\t<key>StandardErrorPath</key>
\t<string>${esc(logPath)}</string>
</dict>
</plist>
''';
  }

  // ------------------------------------------------------------------ settings

  @override
  Future<MemReaperConfig> readConfig() async =>
      configFromArgs((await _requireAgent()).argv);

  /// A flag the plist omits means the agent runs on mem_reaper's own default,
  /// not that the value is zero.
  static MemReaperConfig configFromArgs(PlistArgs args) => MemReaperConfig(
    thresholdMb:
        args.optionalInt(MemReaperConfig.thresholdFlag) ??
        MemReaperConfig.defaults.thresholdMb,
    intervalSeconds:
        args.optionalInt(MemReaperConfig.intervalFlag) ??
        MemReaperConfig.defaults.intervalSeconds,
    dialogTimeoutSeconds:
        args.optionalInt(MemReaperConfig.dialogTimeoutFlag) ??
        MemReaperConfig.defaults.dialogTimeoutSeconds,
  );

  static Map<String, Object> valuesOf(MemReaperConfig config) => {
    MemReaperConfig.thresholdFlag: config.thresholdMb,
    MemReaperConfig.intervalFlag: config.intervalSeconds,
    MemReaperConfig.dialogTimeoutFlag: config.dialogTimeoutSeconds,
  };

  /// The plist half of [writeConfig]: back up, replace, validate, restore on
  /// failure. Split out so it can be exercised on a scratch copy of a real
  /// plist without handing launchd a duplicate label. Returns the backup path.
  ///
  /// The whole array is rewritten in one go. `-replace ProgramArguments.<i>
  /// -string` was tried first and is wrong: it inserts at the index instead of
  /// replacing it, which turned the nine-element command line into a
  /// twelve-element one with the old values still in it.
  Future<String> applyToPlist(
    DiscoveredAgent agent,
    Map<String, Object> values,
  ) async {
    // Computed before anything is written: a flag with no value slot throws
    // here, leaving the plist untouched rather than half-edited.
    final argv = jsonEncode(agent.argv.withValues(values));
    final backup = await _backup(agent.plistPath, 'pre-edit');

    await _runner.runChecked('plutil', [
      '-replace',
      'ProgramArguments',
      '-json',
      argv,
      agent.plistPath,
    ], failureHint: 'writing the agent command line\nbackup: $backup');

    final lint = await _runner.run('plutil', ['-lint', agent.plistPath]);
    if (!lint.ok) {
      await File(backup).copy(agent.plistPath);
      throw ToolException(
        'PLIST_INVALID',
        'The edited plist failed plutil -lint, so the original was restored and '
            'launchd never saw the broken file.',
        detail: '${lint.blurb}\nbackup: $backup',
      );
    }
    return backup;
  }

  @override
  Future<void> writeConfig(ToolConfig incoming) async {
    final config = expectConfig<MemReaperConfig>(incoming, 'mem_reaper');
    if (!config.isValid) {
      throw ToolException(
        'INVALID_CONFIG',
        'Those settings were not written.',
        detail: config.problems.join('\n'),
      );
    }
    final agent = await _requireAgent();
    final backup = await applyToPlist(agent, valuesOf(config));

    // launchd reads ProgramArguments only at bootstrap, so saving means
    // reloading the agent. The bootout is unconditional: leaving a bootstrapped
    // service in place would make the next bootstrap a no-op and the new values
    // would never take effect.
    final uid = await _uidOrFail();
    final target = 'gui/$uid/${agent.label}';
    await _runner.run('launchctl', ['bootout', target]);
    var boot = await _runner.run('launchctl', [
      'bootstrap',
      'gui/$uid',
      agent.plistPath,
    ]);
    if (!boot.ok) {
      // One retry after a second bootout: a half-torn-down service is the usual
      // reason a fresh bootstrap complains.
      await _runner.run('launchctl', ['bootout', target]);
      await Future<void>.delayed(const Duration(seconds: 1));
      boot = await _runner.run('launchctl', [
        'bootstrap',
        'gui/$uid',
        agent.plistPath,
      ]);
    }
    if (!boot.ok) {
      throw ToolException(
        'RELOAD_FAILED',
        boot.blurb.isEmpty ? 'launchctl bootstrap failed.' : boot.blurb,
        detail:
            '${agent.plistPath} was updated (backup: $backup) but the agent '
            'could not be reloaded.\n'
            'A second plist declaring Label ${agent.label} would do exactly '
            'this.\ncommand: launchctl bootstrap gui/$uid ${agent.plistPath}\n'
            'exit code: ${boot.exitCode}',
      );
    }
    await _expectRunning(agent);
  }

  // ---------------------------------------------------------------- reap/scan

  @override
  Future<void> reapNow() async {
    final agent = await _requireAgent();
    final script = agent.argv.script;
    if (script == null || !File(script).existsSync()) {
      throw ToolException(
        'SCRIPT_MISSING',
        'mem_reaper.py is not at ${script ?? 'the path in the plist'}, so the '
            'app cannot run a scan.',
      );
    }
    final config = configFromArgs(agent.argv);
    // One-shot scan, confirming through mem_reaper's own modal. Every decision
    // — protected names, the ancestor walk, the respawn guard — stays in Python.
    final process = await Process.start(agent.interpreterPath, [
      script,
      '--confirm-gui',
      MemReaperConfig.thresholdFlag,
      '${config.thresholdMb}',
      MemReaperConfig.dialogTimeoutFlag,
      '${config.dialogTimeoutSeconds}',
    ]);
    // Both pipes must be drained or the child blocks writing to them.
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    final code = await process.exitCode;
    if (code != 0) {
      throw ToolException(
        'SCAN_FAILED',
        'mem_reaper exited with code $code.',
        detail: 'Run it in a terminal to see why.',
      );
    }
  }

  /// Hands one pid to `mem_reaper.py --stop-pid`. Works with or without an
  /// installed agent: the agent's own script and interpreter are preferred so
  /// the rules applied are the ones that are running, and its `--protect`
  /// entries are passed along so the console honours them too.
  @override
  Future<StopOutcome> stopProcess(
    ManagedApp app, {
    bool immediate = false,
  }) async {
    final pid = int.tryParse(app.id);
    if (pid == null) {
      throw ToolException(
        'BAD_PID',
        '"${app.id}" is not a process id, so nothing was stopped.',
      );
    }
    final agent = (await discover()).agent;
    // The agent's copy first; then the app's own, because an agent installed
    // from an older script would answer the new flag with a usage error.
    final scripts = <String>{
      if (agent?.argv.script case final String s when File(s).existsSync()) s,
      for (final s in Paths.scriptCandidates())
        if (File(s).existsSync()) s,
    };
    final python = Paths.interpreter(fromPlist: agent?.interpreterPath);
    if (scripts.isEmpty || python == null) {
      throw ToolException(
        'SCRIPT_MISSING',
        scripts.isEmpty
            ? 'mem_reaper.py was not found, so the app cannot stop a process: '
                  'the rules about what is safe to stop live there.'
            : 'No python3 was found to run mem_reaper.py with.',
      );
    }
    final protect = <String>[];
    final argv = agent?.argv.argv ?? const <String>[];
    for (var i = 0; i + 1 < argv.length; i++) {
      if (argv[i] == '--protect') protect.addAll(['--protect', argv[i + 1]]);
    }
    ProcResult? last;
    for (final script in scripts) {
      last = await _runner.run(python, [
        script,
        '--stop-pid',
        '$pid',
        if (app.detail != null) ...['--expect-path', app.detail!],
        if (immediate) '--force',
        ...protect,
      ], timeout: const Duration(seconds: 20));
      // 2 is argparse refusing the flag: try the next copy, never a guess.
      if (last.exitCode != 2) return StopOutcome.parse(last.stdout);
    }
    throw ToolException(
      'OLD_SCRIPT',
      'No mem_reaper.py on this machine understands --stop-pid, so nothing '
          'was stopped.',
      detail: '${last?.blurb}\ntried: ${scripts.join(', ')}',
    );
  }

  @override
  Future<List<ManagedApp>> ranked({int windowDays = 7, int limit = 100}) =>
      _liveProcesses(limit: limit);

  /// Live footprints from `top`'s MEM column, which is the number Activity
  /// Monitor shows. `ps` RSS cannot be used here: macOS compresses idle pages,
  /// so a 1.5 GB hog reports around 1 MB.
  Future<List<ManagedApp>> _liveProcesses({int limit = 100}) async {
    final top = await _runner.run('top', [
      '-l',
      '1',
      '-n',
      '9999',
      '-o',
      'mem',
      '-stats',
      'pid,mem',
    ], timeout: const Duration(seconds: 25));
    if (!top.ok) {
      throw ToolException(
        'SCAN_FAILED',
        top.blurb.isEmpty ? 'top exited with code ${top.exitCode}.' : top.blurb,
      );
    }

    // One cheap call covers every process, so ownership comes from `ps` and the
    // size from `top`, joined on pid.
    final sizes = <int, int>{};
    for (final line in top.stdout.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final pid = int.tryParse(parts[0]);
      final bytes = parseTopSize(parts[1]);
      if (pid != null && bytes != null) sizes[pid] = bytes;
    }

    // One -o takes the whole comma-separated format list: `['-axo', 'pid=',
    // 'uid=', ...]` makes ps read 'uid=' as a user operand and fail with
    // "illegal argument".
    final ps = await _runner.run('ps', [
      '-axo',
      'pid=,uid=,comm=',
    ], timeout: const Duration(seconds: 25));
    if (!ps.ok) {
      throw ToolException(
        'SCAN_FAILED',
        ps.blurb.isEmpty ? 'ps failed.' : ps.blurb,
      );
    }
    final uid = int.parse(await _uidOrFail());
    final apps = <ManagedApp>[];
    for (final line in ps.stdout.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final pid = int.tryParse(parts[0]);
      if (pid == null || int.tryParse(parts[1]) != uid) continue;
      final bytes = sizes[pid];
      if (bytes == null) continue;
      final path = parts.sublist(2).join(' ');
      final name = path.split('/').last.trim();
      apps.add(
        ManagedApp(
          id: '$pid',
          name: name.isEmpty ? path : name,
          liveBytes: bytes,
          detail: path,
          killMode: KillMode.viaReaper,
        ),
      );
    }
    apps.sort((a, b) => (b.liveBytes ?? 0).compareTo(a.liveBytes ?? 0));
    return apps.take(limit).toList(growable: false);
  }

  /// `top` prints memory as `1234K`, `3.2M`, `1.2G`, `512B` or a bare byte
  /// count. Returns null for the header and summary lines.
  static final RegExp _sizePattern = RegExp(r'^([\d.]+)\s*([KMGT]?)B?$');

  static int? parseTopSize(String text) {
    final match = _sizePattern.firstMatch(text.trim().toUpperCase());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    const multipliers = {
      '': 1,
      'K': 1024,
      'M': 1024 * 1024,
      'G': 1024 * 1024 * 1024,
      'T': 1024 * 1024 * 1024 * 1024,
    };
    final multiplier = multipliers[match.group(2)];
    return multiplier == null ? null : (value * multiplier).round();
  }

  // --------------------------------------------------------------------- logs

  /// Lines added to the agent log from now on.
  ///
  /// Throws instead of yielding prose when there is nothing to follow, so the
  /// panel never has to guess which strings are data and which are status. It
  /// starts at the current end of file: this is a service log that can already
  /// be large, and the panel exists to show what just happened.
  @override
  Stream<String> tailLog() async* {
    final agent = (await discover()).agent;
    if (agent == null) {
      throw const ToolException(
        'NO_LOG',
        'No mem_reaper agent is installed, so there is no log to follow.',
      );
    }
    final path = agent.logPath;
    // launchd substitutes %s / %c in log paths; resolving those wrongly would
    // show the wrong file, so the app only follows a plain path.
    if (path == null || path.contains('%')) {
      throw ToolException(
        'NO_LOG_PATH',
        'The plist has no plain StandardOutPath, so the app cannot follow the '
            'log.',
        detail:
            'label: ${agent.label}\n'
            'run: launchctl print gui/<uid>/${agent.label}',
      );
    }
    if (!File(path).existsSync()) {
      throw ToolException(
        'LOG_NOT_CREATED',
        'No log at $path yet — it appears once mem_reaper has written something.',
      );
    }
    yield* tailAppendedLines(path);
  }
}
