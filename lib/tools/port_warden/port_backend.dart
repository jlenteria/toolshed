import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/runner.dart';
import '../mem_reaper/macos_backend.dart';
import '../mem_reaper/managed_app.dart';
import '../mem_reaper/stop_outcome.dart';
import '../tool_backend.dart';
import 'listener_parsers.dart';
import 'port_listener.dart';

const String kPortWardenId = 'port_warden';

/// Lists the sockets the OS reports as listening, and — on macOS — frees a
/// port by handing its owner to mem_reaper.py.
///
/// The scan is read-only and holds no rules: it reports what the OS printed.
/// The stop path holds none either: `--stop-pid` re-checks the protected
/// names, the ancestor walk, the owner and the executable at that pid before
/// it signals anything, so port warden cannot stop something the memory list
/// would refuse.
abstract class _PortWardenBackend implements ToolBackend, PortInspector {
  _PortWardenBackend({ProcessRunner? runner})
    : _runner = runner ?? const ProcessRunner();

  final ProcessRunner _runner;

  /// The command this platform's list is read from. Named in status and in the
  /// screen's header so it is clear what the app is trusting.
  String get scanner;

  @override
  Future<AgentStatus> status() async =>
      const AgentStatus.notApplicable().withNotes([
        'Read on demand with $scanner: nothing is installed and nothing runs '
            'in the background.',
      ]);

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
    'Port Warden has no settings: the socket table is read fresh each time.',
  );

  @override
  Future<void> writeConfig(ToolConfig config) async =>
      throw const ToolException(
        'NO_SETTINGS',
        'Port Warden has no settings to write.',
      );

  @override
  Stream<String> tailLog() => Stream<String>.error(
    const ToolException(
      'NO_LOG',
      'Port Warden has no agent, so there is no log to follow.',
    ),
  );

  Never _noAgent(String what) => throw ToolException(
    'NO_AGENT',
    'Port Warden has no background agent to $what.',
  );
}

class MacOSPortWardenBackend extends _PortWardenBackend
    implements ProcessStopper {
  MacOSPortWardenBackend({super.runner})
    : _reaper = MacOSMemReaperBackend(runner: runner);

  final MacOSMemReaperBackend _reaper;

  @override
  String get scanner => 'lsof';

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kPortWardenId,
    name: 'Port Warden',
    summary:
        'Shows which process is listening on each port, and frees a port by '
        'stopping the process that owns it.',
    implPath: 'lsof',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.showPorts, ToolAction.forceStop},
    reason:
        'Reads the socket table with lsof. Freeing a port hands the owner '
        'to mem_reaper.py, so its protected-process rules decide what may be '
        'stopped.',
  );

  @override
  Future<List<PortListener>> listening() async {
    final tcp = await _lsof(['-nP', '-iTCP', '-sTCP:LISTEN']);
    final udp = await _lsof(['-nP', '-iUDP']);
    return _withCommands([...parseLsof(tcp), ...parseLsof(udp)]);
  }

  /// lsof exits 1 with no output when nothing matched, and that is an empty
  /// answer. Anything it wrote to stderr — a flag it did not take, a permission
  /// failure — is a failed scan and must not look like "no ports".
  Future<String> _lsof(List<String> arguments) async {
    final result = await _runner.run(
      'lsof',
      arguments,
      timeout: const Duration(seconds: 20),
    );
    if (result.exitCode == 0) return result.stdout;
    if (result.stdout.trim().isEmpty && result.stderr.trim().isEmpty) {
      return '';
    }
    throw ToolException(
      'SCAN_FAILED',
      result.blurb.isEmpty
          ? 'lsof exited with code ${result.exitCode}.'
          : result.blurb,
      detail: 'command: lsof ${arguments.join(' ')}',
    );
  }

  /// Fills each row's executable path from one `ps`, which is what
  /// `--stop-pid --expect-path` needs to refuse a pid that was reused. A `ps`
  /// failure only costs that guard; the list still renders.
  Future<List<PortListener>> _withCommands(List<PortListener> listeners) async {
    final pids = <int>{
      for (final listener in listeners)
        if (listener.pid != null) listener.pid!,
    };
    if (pids.isEmpty) return listeners;
    final ps = await _runner.run('ps', [
      '-p',
      pids.join(','),
      '-o',
      'pid=,comm=',
    ], timeout: const Duration(seconds: 10));
    if (!ps.ok) return listeners;

    final commands = <int, String>{};
    final row = RegExp(r'^\s*(\d+)\s+(.+?)\s*$');
    for (final line in ps.stdout.split('\n')) {
      final match = row.firstMatch(line);
      if (match == null) continue;
      final pid = int.tryParse(match.group(1)!);
      if (pid != null) commands[pid] = match.group(2)!;
    }
    return [
      for (final listener in listeners)
        listener.copyWith(command: commands[listener.pid]),
    ];
  }

  @override
  Future<StopOutcome> stopProcess(ManagedApp app, {bool immediate = false}) =>
      _reaper.stopProcess(app, immediate: immediate);
}

class LinuxPortWardenBackend extends _PortWardenBackend {
  LinuxPortWardenBackend({super.runner});

  @override
  String get scanner => 'ss';

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kPortWardenId,
    name: 'Port Warden',
    summary: 'Shows which process is listening on each port, read from ss.',
    implPath: 'ss',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.showPorts},
    reason:
        'Reads the socket table with ss. Freeing a port is not offered here: '
        'the rules for which processes are safe to stop live in mem_reaper.py, '
        'which is macOS-only.',
  );

  @override
  Future<List<PortListener>> listening() async {
    final tcp = await _scan(['-ltnp']);
    final udp = await _scan(['-lunp']);
    return [...parseSs(tcp), ...parseSs(udp)];
  }

  Future<String> _scan(List<String> arguments) async {
    final result = await _runner.run(
      'ss',
      arguments,
      timeout: const Duration(seconds: 15),
    );
    if (result.ok) return result.stdout;
    throw ToolException(
      'SCAN_FAILED',
      result.blurb.isEmpty
          ? 'ss exited with code ${result.exitCode}.'
          : result.blurb,
      detail:
          'command: ss ${arguments.join(' ')}\n'
          'ss is part of iproute2; without it this tool cannot read the '
          'socket table.',
    );
  }
}

class WindowsPortWardenBackend extends _PortWardenBackend {
  WindowsPortWardenBackend({super.runner});

  @override
  String get scanner => 'netstat';

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kPortWardenId,
    name: 'Port Warden',
    summary:
        'Shows which process is listening on each port, read from netstat.',
    implPath: 'netstat',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.showPorts},
    reason:
        'Reads the socket table with netstat. Freeing a port is not offered '
        'here: the rules for which processes are safe to stop live in '
        'mem_reaper.py, which is macOS-only.',
  );

  @override
  Future<List<PortListener>> listening() async {
    final result = await _runner.run('netstat', [
      '-ano',
    ], timeout: const Duration(seconds: 30));
    if (!result.ok) {
      throw ToolException(
        'SCAN_FAILED',
        result.blurb.isEmpty
            ? 'netstat exited with code ${result.exitCode}.'
            : result.blurb,
        detail: 'command: netstat -ano',
      );
    }
    final rows = parseNetstat(result.stdout);
    final names = await _taskNames();
    return attachProcessNames(rows, names);
  }

  /// netstat prints pids and no image names; tasklist supplies the names. A
  /// failed tasklist only costs the names — the ports are still the answer.
  Future<Map<int, String>> _taskNames() async {
    try {
      final result = await _runner.run('tasklist', [
        '/FO',
        'CSV',
        '/NH',
      ], timeout: const Duration(seconds: 30));
      return result.ok ? parseTasklist(result.stdout) : const {};
    } on ToolException {
      return const {};
    }
  }
}
