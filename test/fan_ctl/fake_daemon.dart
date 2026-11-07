import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';

/// The daemon, replaced by the list of requests it was sent.
///
/// Everything the backend does to the hardware goes out as a
/// `toolshed-fand client --request '<json>'` process, so intercepting the
/// [ProcessRunner] is the real boundary: nothing here can pass for a fan write
/// that would not have reached a socket.
class FakeDaemon extends ProcessRunner {
  /// Set to make the daemon answer every control request the way an old helper
  /// answers a request shape it has never seen: a refusal about the envelope,
  /// not about the fan.
  FakeDaemon({this.answers = true, this.refuses, String? telemetry})
    : telemetryStdout = telemetry ?? _idleMachine;

  final List<Map<String, Object?>> received = [];
  final String telemetryStdout;
  final String? refuses;
  bool answers;

  /// When set, every call waits for it before answering — a helper that is
  /// still reading, held open long enough for a test to see the progress bar.
  Future<void>? hold;

  /// What the fake is holding, so a later `status` reports the policy from the
  /// last `apply` rather than the (absent) policy of the status request.
  Map<String, Object?>? _held;

  List<String> get cmds => [for (final r in received) r['cmd'] as String];

  List<FanPolicy> get applied => [
    for (final r in received)
      if (r['cmd'] == 'apply')
        FanPolicy.fromJson(Map<String, Object?>.from(r['policy']! as Map)),
  ];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    await hold;
    if (arguments.first == 'telemetry') {
      return ProcResult(executable, 0, telemetryStdout, '');
    }
    if (arguments.first != 'client') {
      return ProcResult(
        executable,
        1,
        '',
        'these tests never run "${arguments.join(' ')}"',
      );
    }
    final request =
        jsonDecode(arguments[arguments.indexOf('--request') + 1])
            as Map<String, Object?>;
    received.add(request);
    if (!answers) {
      // What an unreachable socket looks like from the client: exit 1, no line.
      // Nothing changes on the far side when the request never lands.
      return ProcResult(executable, 1, '', 'connection refused');
    }
    switch (request['cmd']) {
      case 'apply':
        final refusal = refuses;
        if (refusal != null) {
          return ProcResult(
            executable,
            1,
            jsonEncode({'ok': false, 'error': refusal}),
            '',
          );
        }
        _held = Map<String, Object?>.from(request['policy']! as Map);
      case 'clear':
        _held = null;
    }
    return ProcResult(
      executable,
      0,
      jsonEncode({
        'ok': true,
        'status': {
          'pid': 7,
          'uid': 0,
          'isRoot': true,
          'applied': _held == null ? 'automatic' : 'holding',
          'appliedRpm': _held?['holdRpm'],
          'reason': 'fake daemon',
          'startedAt': 0,
          'ticks': 1,
          'policy': _held,
          'fans': <Object?>[],
        },
      }),
      '',
    );
  }
}

/// Numbers from a real Mac14,7 at idle, so a rendered console shows a fan with
/// a floor and a ceiling rather than an empty card.
const _idleMachine = '''
{
  "at": 1793243238,
  "machine": "Mac14,7",
  "pid": 501,
  "fans": [
    {"id": 0, "name": "Fan 0", "actualRpm": 0, "minRpm": 1199,
     "maxRpm": 7199, "targetRpm": 0, "mode": 0, "modeKey": "F0Md"}
  ],
  "sensors": [
    {"key": "TCMz", "celsius": 50.7, "type": "sp78"},
    {"key": "TCp9", "celsius": 48.2, "type": "sp78"},
    {"key": "TH0B", "celsius": 46.8, "type": "sp78"},
    {"key": "TG0B", "celsius": 44.8, "type": "sp78"}
  ],
  "groups": {"all": 50.7, "cpu": 50.7, "gpu": 44.8, "heatSink": 46.8}
}
''';
