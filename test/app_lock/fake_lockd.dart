import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/platform/runner.dart';

/// `toolshed-lockd`, replaced by the calls it was made with.
///
/// The boundary is the same one the fan tests use — the [ProcessRunner] —
/// because every verb of the helper is a short-lived process that prints one
/// JSON line. What this fake must not do is invent a protocol: each reply below
/// is the shape `macos/lockd/main.swift` actually emits, and
/// `protocol_test.dart` runs the real binary against the same expectations.
class FakeLockd extends ProcessRunner {
  FakeLockd({
    this.passphrase = false,
    this.watching = false,
    this.apps = const [],
    this.lockedCount = 0,
    this.enabled = true,
    this.unlockMinutes = 5,
    this.forceQuit = false,
    this.secretOk = true,
  });

  /// Verbs in the order they were sent, e.g. `['status', 'setpass']`.
  final List<String> calls = [];

  /// Full argv of each call, for a test that has to check a flag was passed.
  final List<List<String>> argv = [];

  /// The passphrase handed to `setpass`, `verify` or `grant` on stdin — the one
  /// argument that must never appear in [argv].
  String? lastStdin;

  bool passphrase;
  bool watching;

  /// What the helper refuses to see at all, so the guard list can be tested
  /// without a LaunchServices database.
  List<Map<String, Object?>> apps;

  int lockedCount;
  bool enabled;
  int unlockMinutes;
  bool forceQuit;

  /// When false, `verify` answers "no" — the helper's exit code 2, not an error.
  bool secretOk;

  /// The passphrase the fake was told to store, so a wrong check can be made
  /// without a hash.
  String? stored;

  /// bundleId -> minutes, from `grant`.
  final Map<String, int> grants = {};
  final List<String> revoked = [];
  final List<String> closed = [];
  final List<String> prompted = [];

  /// Makes the next `close` answer that the app was not running.
  bool runningForClose = true;

  /// When set, every verb waits for it before answering — a helper that is
  /// still reading, held open long enough for a test to see the progress bar.
  Future<void>? hold;

  static Map<String, Object?> app(
    String bundleId,
    String name, {
    bool running = false,
    bool locked = false,
    bool lockable = true,
    String? whyNotLockable,
    double? unlockedUntil,
  }) => {
    'bundleId': bundleId,
    'name': name,
    'path': '/Applications/$name.app',
    'running': running,
    if (running) 'pid': 4242,
    'locked': locked,
    'lockable': lockable,
    'whyNotLockable': ?whyNotLockable,
    'unlockedUntil': ?unlockedUntil,
  };

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    await hold;
    return _handle(executable, arguments, stdin: null);
  }

  @override
  Future<ProcResult> runWithStdin(
    String executable,
    List<String> arguments,
    String input, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    lastStdin = input;
    await hold;
    return _handle(executable, arguments, stdin: input);
  }

  ProcResult _handle(
    String executable,
    List<String> arguments, {
    String? stdin,
  }) {
    final verb = arguments.first;
    calls.add(verb);
    argv.add(arguments);

    /// `--store <dir>` is how the client is pointed at a scratch directory in
    /// tests, so the fake has to step over it like the real helper does.
    String flag(String name, {String? orElse}) {
      final at = arguments.indexOf(name);
      return at == -1 ? orElse! : arguments[at + 1];
    }

    switch (verb) {
      case 'list':
        return _json({'ok': true, 'apps': apps, 'store': '/fake/store'});
      case 'status':
        return _json({
          'ok': true,
          'status': {
            'uid': 501,
            'store': '/fake/store',
            'watching': watching,
            'watchPid': watching ? 9021 : 0,
            'secret': {
              'set': passphrase,
              'iterations': passphrase ? 120000 : 0,
              'setAt': passphrase ? 1793243238.0 : 0,
            },
            'config': {
              'present': true,
              'enabled': enabled,
              'unlockMinutes': unlockMinutes,
              'forceQuit': forceQuit,
              'lockedCount': lockedCount,
            },
            'running': [
              for (final app in apps)
                if (app['running'] == true && app['locked'] == true) app,
            ],
            'unlocks': [
              for (final entry in grants.entries)
                {
                  'bundleId': entry.key,
                  'expiresAt':
                      DateTime.now()
                          .add(Duration(minutes: entry.value))
                          .millisecondsSinceEpoch /
                      1000.0,
                  'grantedBy': 'console',
                },
            ],
            'events': [
              {
                'at': 1793243200.0,
                'bundleId': 'com.apple.Notes',
                'action': 'closed',
                'detail': 'Notes launched while locked',
              },
            ],
          },
        });
      case 'haspass':
        return _json({'ok': true, 'set': passphrase});
      case 'setpass':
        stored = stdin;
        passphrase = stdin != null && stdin.length >= 4;
        return _json({
          'ok': passphrase,
          if (!passphrase) 'error': 'a passphrase under 8 characters',
          'iterations': 120000,
        });
      case 'verify':
        final yes = secretOk && stdin != null && stdin.length >= 4;
        return _json({'ok': true, 'verified': yes}, exitCode: yes ? 0 : 2);
      case 'grant':
        final bundle = flag('--bundle');
        final minutes = int.tryParse(flag('--minutes', orElse: '5')) ?? 5;
        final yes = secretOk && stdin != null && stdin.length >= 4;
        if (yes) grants[bundle] = minutes;
        return _json({
          'ok': true,
          'granted': yes,
          if (yes) 'expiresAt': 1793243238.0 + minutes * 60,
        });
      case 'revoke':
        revoked.add(flag('--bundle'));
        grants.remove(flag('--bundle'));
        return _json({'ok': true, 'revoked': true});
      case 'close':
        final bundle = flag('--bundle');
        closed.add(bundle);
        if (runningForClose) return _json({'ok': true, 'closed': true});
        return _json({'ok': true, 'closed': false});
      case 'prompt':
        prompted.add(flag('--bundle'));
        return _json({'ok': true, 'opened': true});
      case 'selfcheck':
        return _json({'ok': true, 'checks': 12, 'failures': 0});
      default:
        return _json({
          'ok': false,
          'error': 'the fake has no answer for "$verb"',
        });
    }
  }

  ProcResult _json(Map<String, Object?> body, {int exitCode = 0}) => ProcResult(
    'toolshed-lockd',
    exitCode,
    jsonEncode(body),
    exitCode == 0 ? '' : 'wrong passphrase',
  );
}
