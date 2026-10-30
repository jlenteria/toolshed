/// The agent has two independent axes: whether its config file exists, and
/// whether launchd has it bootstrapped. `stop` has to be `bootout`, not a kill,
/// because KeepAlive respawns a killed process after ThrottleInterval.
enum AgentState {
  notInstalled,
  installedStopped,
  running,

  /// The device has no agent concept; the tool runs inside the app itself.
  notApplicable,
  unknown,
}

class AgentStatus {
  const AgentStatus({
    required this.state,
    this.pid,
    this.runs,
    this.lastExitCode,
    this.plistPath,
    this.logPath,
    this.notes = const <String>[],
  });

  const AgentStatus.notApplicable()
    : state = AgentState.notApplicable,
      pid = null,
      runs = null,
      lastExitCode = null,
      plistPath = null,
      logPath = null,
      notes = const <String>[];

  final AgentState state;
  final int? pid;
  final int? runs;
  final int? lastExitCode;
  final String? plistPath;
  final String? logPath;
  final List<String> notes;

  bool get isRunning => state == AgentState.running;

  String get label => switch (state) {
    AgentState.notInstalled => 'Not installed',
    AgentState.installedStopped => 'Installed, stopped',
    AgentState.running => 'Running',
    AgentState.notApplicable => 'Runs on this device',
    AgentState.unknown => 'Unknown',
  };

  AgentStatus withNotes(List<String> extra) => AgentStatus(
    state: state,
    pid: pid,
    runs: runs,
    lastExitCode: lastExitCode,
    plistPath: plistPath,
    logPath: logPath,
    notes: <String>[...notes, ...extra],
  );
}
