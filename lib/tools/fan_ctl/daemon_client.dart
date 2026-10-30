import 'dart:convert';

import '../../models/tool_exception.dart';
import '../../platform/runner.dart';
import 'fan_daemon.dart';
import 'fan_policy.dart';
import 'fan_telemetry.dart';

/// One line of the daemon's reply, as `Reply` in `macos/fanctl/main.swift`.
///
/// The protocol is deliberately small: newline-delimited JSON over a Unix
/// socket, one request per connection. dart:io has no Unix-socket client, so
/// every request here is a `toolshed-fand client --request …` process — the same
/// shelling-out the mem_reaper backend already does for launchctl and plutil.
/// `fan_protocol_test` pins these keys against the Swift structs.
class FanReply {
  const FanReply({required this.ok, this.error, this.status, this.selftest});

  final bool ok;
  final String? error;
  final FanDaemonStatus? status;
  final FanPrivilegeReport? selftest;

  bool get isFailure => !ok;

  factory FanReply.fromJson(Map<String, Object?> json) {
    final status = _asObject(json['status']);
    final selftest = _asObject(json['selftest']);
    return FanReply(
      ok: json['ok'] == true,
      error: json['error'] as String?,
      status: status == null ? null : FanDaemonStatus.fromJson(status),
      selftest: selftest == null ? null : FanPrivilegeReport.fromJson(selftest),
    );
  }

  /// A daemon that is not running answers with nothing at all, and a truncated
  /// answer must not be read as a healthy one.
  static FanReply? tryParse(String source) {
    final decoded = _parseObject(source);
    return decoded == null ? null : FanReply.fromJson(decoded);
  }
}

/// Runs the read-only commands the current user may run without privilege.
enum FanCommand {
  telemetry('telemetry'),
  selftest('selftest');

  const FanCommand(this.wireName);
  final String wireName;
}

/// Talks to `toolshed-fand`: reads go to the SMC directly, control goes through
/// the daemon, because a write from this process is refused by the kernel.
class FanDaemonClient {
  FanDaemonClient({
    required this.binaryPath,
    this.runner = const ProcessRunner(),
    this.socketPath,
  });

  final String binaryPath;
  final ProcessRunner runner;

  /// Only set for a developer instance; a LaunchDaemon uses the default
  /// `/var/run/toolshed-fand.sock`.
  final String? socketPath;

  static const String defaultSocket = '/var/run/toolshed-fand.sock';
  static const Duration _replyTimeout = Duration(seconds: 10);

  /// `{"cmd":"status"}`, plus the policy when the command needs one.
  static String requestJson(String cmd, {FanPolicy? policy}) =>
      jsonEncode({'cmd': cmd, if (policy != null) 'policy': policy.toJson()});

  /// A daemon that is not running is a state, not a failure, so this returns
  /// null instead of throwing — the status line has to be able to say so.
  Future<FanReply?> tryRequest(String cmd, {FanPolicy? policy}) async {
    final result = await runner.run(
      binaryPath,
      clientArgs(cmd, policy: policy),
      timeout: _replyTimeout,
    );
    return FanReply.tryParse(result.stdout);
  }

  /// A command that must have an effect, so an unreachable daemon is an error
  /// with a reason rather than a silently ignored tap.
  Future<FanReply> request(String cmd, {FanPolicy? policy}) async {
    final reply = await tryRequest(cmd, policy: policy);
    if (reply == null) {
      throw ToolException(
        'DAEMON_SILENT',
        'The fan daemon returned nothing for "$cmd".',
        detail: 'socket: ${socketPath ?? defaultSocket}',
      );
    }
    if (reply.isFailure) {
      throw ToolException(
        'DAEMON_REFUSED',
        reply.error ?? 'the daemon refused "$cmd"',
      );
    }
    return reply;
  }

  Future<FanDaemonStatus?> daemonStatus() async =>
      (await tryRequest('status'))?.status;

  /// The daemon's answer to "can you actually write?" — asked from the side of
  /// the machine that is root, so the app never has to claim control works.
  Future<FanPrivilegeReport?> daemonPrivileges() async =>
      (await tryRequest('selftest'))?.selftest;

  Future<FanDaemonStatus?> apply(FanPolicy policy) async =>
      (await request('apply', policy: policy)).status;

  Future<FanDaemonStatus?> clear() async => (await request('clear')).status;

  /// The argv for one round trip. Public so a test can assert that a request
  /// never reaches the shell unquoted and that `--socket` is only ever passed
  /// for a developer instance.
  List<String> clientArgs(String cmd, {FanPolicy? policy}) => [
    'client',
    '--request',
    requestJson(cmd, policy: policy),
    if (socketPath != null) ...['--socket', socketPath!],
  ];

  /// `telemetry`, `selftest` or `selfcheck`, run unprivileged as this user. None
  /// of them writes, so none of them needs the daemon.
  Future<ProcResult> runLocal(FanCommand command) => runner.run(
    binaryPath,
    [command.wireName, '--json'],
    timeout: command == FanCommand.selftest
        ? _replyTimeout
        : const Duration(seconds: 30),
  );

  Future<FanTelemetry> telemetry() async {
    final result = await runLocal(FanCommand.telemetry);
    if (!result.ok) {
      throw ToolException(
        'TELEMETRY_FAILED',
        result.blurb.isEmpty
            ? 'The helper could not read the SMC.'
            : result.blurb,
        detail: 'binary: $binaryPath',
      );
    }
    try {
      return FanTelemetry.parse(result.stdout);
    } on FormatException catch (e) {
      throw ToolException(
        'TELEMETRY_BAD',
        'The helper returned something that is not telemetry: $e',
        detail: result.stdout,
      );
    }
  }

  /// What this *unprivileged* process may do. Exit 1 is the honest answer
  /// "writes are refused", which is a measurement rather than a broken command,
  /// so the JSON is read either way.
  Future<FanPrivilegeReport> privileges() async {
    final result = await runLocal(FanCommand.selftest);
    final decoded = _parseObject(result.stdout);
    if (decoded == null) {
      throw ToolException(
        'SELFTEST_FAILED',
        result.blurb.isEmpty
            ? 'The helper could not test fan writes.'
            : result.blurb,
        detail: 'binary: $binaryPath, exit ${result.exitCode}',
      );
    }
    return FanPrivilegeReport.fromJson(decoded);
  }
}

/// A JSON object, or null when the text is empty or is some other shape.
Map<String, Object?>? _asObject(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

/// The daemon answers with one line; a stray trailing line is not a second
/// reply to interpret.
Map<String, Object?>? _parseObject(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return null;
  try {
    return _asObject(jsonDecode(trimmed.split('\n').first));
  } on FormatException {
    return null;
  }
}
