/// Parses `launchctl print gui/<uid>/<label>` output.
///
/// Every field regex is anchored to exactly ONE leading tab. The same keys
/// reappear at two tabs inside the `resource coalition` and `jetsam coalition`
/// blocks (`state = active`), and a loose `state = (\w+)` match picks up
/// `active` from a coalition and reports a stopped agent as running.
library;

class LaunchctlInfo {
  const LaunchctlInfo({
    this.state,
    this.pid,
    this.runs,
    this.lastExitCode,
    this.stdoutPath,
    this.stderrPath,
    this.program,
    this.path,
  });

  final String? state;
  final int? pid;
  final int? runs;
  final int? lastExitCode;
  final String? stdoutPath;
  final String? stderrPath;
  final String? program;

  /// Where launchd believes the plist lives.
  final String? path;

  bool get isRunning => state == 'running';

  /// A service that is loaded but whose process has exited still reports a
  /// `pid`-less `state`; `not loaded` is the one case that is not a failure.
  static bool notLoaded(int exitCode, String output) {
    final text = output.toLowerCase();
    // 113 = "Could not find the specified service". Some builds exit 3 here.
    return exitCode == 113 ||
        text.contains('could not find service') ||
        text.contains('bad request');
  }

  /// `bootout` of an already-unloaded agent is not an error worth surfacing.
  static bool alreadyGone(int exitCode, String output) {
    final text = output.toLowerCase();
    return text.contains('could not find service') ||
        text.contains('no such') ||
        exitCode == 3;
  }

  static RegExp _field(String key) =>
      RegExp('^\\t$key = (.+)\$', multiLine: true);

  static String? _string(String out, String key) {
    final m = _field(key).firstMatch(out);
    if (m == null) return null;
    final value = m.group(1)!.trim();
    return value.isEmpty || value == '(unlimited)' ? null : value;
  }

  static int? _int(String out, String key) {
    final raw = _string(out, key);
    if (raw == null) return null;
    return int.tryParse(raw.replaceAll(',', ''));
  }

  static LaunchctlInfo parse(String out) {
    return LaunchctlInfo(
      state: _string(out, 'state'),
      pid: _int(out, 'pid'),
      runs: _int(out, 'runs'),
      lastExitCode: _int(out, 'last exit code'),
      stdoutPath: _string(out, 'stdout path'),
      stderrPath: _string(out, 'stderr path'),
      program: _string(out, 'program'),
      path: _string(out, 'path'),
    );
  }
}
