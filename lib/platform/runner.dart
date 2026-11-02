import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/tool_exception.dart';
import 'paths.dart';

class ProcResult {
  const ProcResult(this.executable, this.exitCode, this.stdout, this.stderr);

  final String executable;
  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// launchctl and plutil write the useful part to stderr even on success, and
  /// write nothing on some failures, so fall back across both.
  String get blurb =>
      [stderr.trim(), stdout.trim()].where((s) => s.isNotEmpty).join('\n');
}

/// Thin wrapper over [Process.run].
///
/// Everything the app does natively is a short-lived command, so there is no
/// long-lived child to leak. [run] never throws for a non-zero exit — the
/// caller has to interpret codes 3 and 113 as "already in the desired state",
/// which it can only do with the result in hand.
class ProcessRunner {
  const ProcessRunner();

  /// The environment handed to every child: the parent's, with a `PATH` that
  /// also covers the well-known bin directories a Dock launch strips. See
  /// [Paths.subprocessPath] — a tool found by absolute path still execs its own
  /// siblings by name, and those must be reachable.
  static Map<String, String> get _childEnvironment => {
    'PATH': Paths.subprocessPath,
  };

  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    ProcessResult raw;
    try {
      raw = await Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: _childEnvironment,
        runInShell: false,
      ).timeout(timeout);
    } on TimeoutException {
      throw ToolException(
        'TIMEOUT',
        '$executable took longer than $timeout and was abandoned.',
      );
    } on ProcessException catch (e) {
      throw ToolException(
        'EXEC_FAILED',
        'Could not run $executable: ${e.message}',
        detail: 'message: ${e.message}\nexecutable: ${e.executable}\n',
      );
    }
    return ProcResult(
      executable,
      raw.exitCode,
      raw.stdout as String,
      raw.stderr as String,
    );
  }

  /// [run] with a stdin, for the one kind of argument that must not be one.
  ///
  /// `ps` shows every process's argv to every user on the machine, so a
  /// passphrase passed as `--passphrase x` is written down in plain text for as
  /// long as the helper runs. The helper's `setpass`, `verify` and `grant` read
  /// it from stdin instead and this is the only way to reach them. [input] is
  /// written and closed before the output is read, so a command that waits for
  /// EOF cannot hang.
  Future<ProcResult> runWithStdin(
    String executable,
    List<String> arguments,
    String input, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Process child;
    try {
      child = await Process.start(
        executable,
        arguments,
        environment: _childEnvironment,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      throw ToolException(
        'EXEC_FAILED',
        'Could not run $executable: ${e.message}',
        detail: 'message: ${e.message}\nexecutable: ${e.executable}\n',
      );
    }
    try {
      final done = _gather(child, executable, timeout);
      child.stdin.add(utf8.encode(input));
      await child.stdin.close();
      return await done;
    } on Object {
      child.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  static Future<ProcResult> _gather(
    Process child,
    String executable,
    Duration timeout,
  ) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final reading = <Future<void>>[
      child.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(out.write),
      child.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(err.write),
    ];
    try {
      final code = await child.exitCode.timeout(
        timeout,
        onTimeout: () {
          throw ToolException(
            'TIMEOUT',
            '$executable took longer than $timeout and was abandoned.',
          );
        },
      );
      // Both pipes must be drained before the result comes back: exitCode can
      // resolve a moment before the last chunk lands, and a truncated reply
      // would be reported as a malformed one.
      await Future.wait(reading);
      return ProcResult(executable, code, out.toString(), err.toString());
    } on Object {
      child.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  /// Throws a [ToolException] carrying the command's own stderr when the exit
  /// code is not in [acceptable].
  Future<ProcResult> runChecked(
    String executable,
    List<String> arguments, {
    Set<int> acceptable = const {0},
    String? failureHint,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final result = await run(executable, arguments, timeout: timeout);
    if (!acceptable.contains(result.exitCode)) {
      throw ToolException(
        'COMMAND_FAILED',
        result.blurb.isEmpty
            ? '$executable ${arguments.join(' ')} failed'
            : result.blurb,
        detail: [
          'command: $executable ${arguments.join(' ')}',
          'exit code: ${result.exitCode}',
          ?failureHint,
        ].join('\n'),
      );
    }
    return result;
  }
}
