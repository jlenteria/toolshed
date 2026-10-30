import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/fan_ctl/daemon_client.dart';
import 'package:toolshed/tools/fan_ctl/daemon_install.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';

/// The installer hands a shell script to root. Two things have to be true about
/// that script and neither is checked by the compiler: it must be exactly the
/// script that was written — one escaping layer per character `do shell script`
/// reads, and there are two — and the LaunchDaemon it lays down must be a plist
/// launchd will accept.
///
/// So both are measured here against the real `osascript` and the real `plutil`,
/// in a scratch directory. Nothing in this file touches /Library, runs launchctl,
/// or asks for a password: the privileged flag is off, which runs the same script
/// as the current user.
void main() {
  const label = FanDaemonPaths.label;

  group('the LaunchDaemon', () {
    test('is valid XML naming the right job and program', () {
      final scratch = Directory.systemTemp.createTempSync(
        'toolshed_fand_plist',
      );
      addTearDown(() => scratch.deleteSync(recursive: true));
      final path = '${scratch.path}/$label.plist';
      File(path).writeAsStringSync(FanDaemonInstaller.plistTemplate());

      final linted = Process.runSync('plutil', ['-lint', path]);
      expect(linted.exitCode, 0, reason: '${linted.stdout}${linted.stderr}');

      final shown = Process.runSync('plutil', [
        '-convert',
        'json',
        '-o',
        '-',
        path,
      ]);
      expect(shown.exitCode, 0, reason: shown.stderr.toString());
      final plist = jsonDecode(shown.stdout as String) as Map<String, Object?>;
      expect(plist['Label'], label);
      expect(plist['ProgramArguments'], [FanDaemonPaths.binary, 'serve']);
      expect(plist['RunAtLoad'], true);
      expect(plist['KeepAlive'], {'Crashed': true, 'SuccessfulExit': false});
      expect(plist['StandardErrorPath'], FanDaemonPaths.launchdLog);
    });

    test('respawns a crash but not a clean exit', () {
      // SuccessfulExit false is the whole Stop button: the daemon's SIGTERM
      // handler releases the fan and exits 0, and a respawn after that would take
      // control back seconds after the user let go. A crash still comes back,
      // because a fresh daemon hands any forced fan to Apple as it starts.
      final plist = FanDaemonInstaller.plistTemplate();
      expect(plist, contains('<key>Crashed</key><true/>'));
      expect(plist, contains('<key>SuccessfulExit</key><false/>'));
      expect(plist, contains('<key>RunAtLoad</key><true/>'));
      expect(plist, contains('<key>ThrottleInterval</key>'));
    });

    test('writes only to root-owned locations', () {
      // A root daemon must not be startable from a file another process can
      // rewrite, so none of these may live in a home directory or in /tmp.
      for (final path in [
        FanDaemonPaths.binary,
        FanDaemonPaths.plist,
        FanDaemonPaths.log,
        FanDaemonPaths.launchdLog,
      ]) {
        expect(path, startsWith('/'), reason: '$path is not absolute');
        expect(
          path,
          isNot(anyOf(startsWith('/tmp'), startsWith('/Users'))),
          reason: '$path is not root-owned',
        );
      }
      expect(FanDaemonPaths.binary, endsWith('toolshed-fand'));
    });

    test('agrees with the client on where the socket is', () {
      expect(FanDaemonPaths.socket, FanDaemonClient.defaultSocket);
    });
  });

  group('the two escaping layers agree', () {
    late Directory scratch;
    late String out;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('toolshed_fand_escape');
      out = '${scratch.path}/out';
    });

    tearDown(() => scratch.deleteSync(recursive: true));

    /// Run [script] through a real `do shell script`, unprivileged, and leave
    /// `/bin/sh` to write [payload] to [out] verbatim.
    void roundTrip(String payload) {
      final quoted = "'${payload.replaceAll("'", r"'\''")}'";
      final result = Process.runSync('osascript', [
        '-e',
        FanDaemonInstaller.appleScript(
          'printf %s $quoted > $out',
          privileged: false,
        ),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }

    test('a plist full of quotes, tabs and newlines arrives unchanged', () {
      final expected = FanDaemonInstaller.plistTemplate();
      roundTrip(expected);
      expect(File(out).readAsStringSync(), expected);
    });

    test('backslashes, dollar signs and both quote styles survive', () {
      const awkward =
          r'a\tb$e "double" '
          "'single'"
          ' and a newline\nend';
      roundTrip(awkward);
      expect(File(out).readAsStringSync(), awkward);
    });

    test('a path containing a space stays one argument', () {
      final spaced = '${scratch.path}/a b';
      final result = Process.runSync('osascript', [
        '-e',
        FanDaemonInstaller.appleScript(
          "mkdir -p '$spaced' && test -d '$spaced' && rmdir '$spaced'",
          privileged: false,
        ),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test(
      'the privileged form is the same script plus the authorization clause',
      () {
        const script = 'echo one; echo two';
        final plain = FanDaemonInstaller.appleScript(script, privileged: false);
        final elevated = FanDaemonInstaller.appleScript(script);
        expect(plain, 'do shell script "echo one; echo two"');
        expect(elevated, startsWith(plain));
        expect(elevated, contains('with administrator privileges'));
      },
    );

    test('the prompt says why root is needed, in the user\'s terms', () {
      final elevated = FanDaemonInstaller.appleScript('true');
      expect(elevated, contains('with prompt'));
      expect(elevated, contains('kIOReturnNotPrivileged'));
    });

    test('quotes in a script are escaped rather than ending the string', () {
      final escaped = FanDaemonInstaller.appleScript('grep "ok" file');
      expect(escaped, contains(r'\"ok\"'));
    });
  });

  group('launchd verbs', () {
    test('stop both unloads and disables, so it survives a reboot', () {
      final script = FanDaemonInstaller.bootoutScript;
      expect(script, contains('launchctl bootout system/$label'));
      expect(script, contains('launchctl disable system/$label'));
      // A job that was never loaded is already in the state the button asked for.
      expect(script, contains('|| true'));
    });

    test('start enables, bootstraps tolerantly, then kickstarts', () {
      final script = FanDaemonInstaller.bootstrapScript;
      expect(script, contains('launchctl enable system/$label'));
      expect(script, contains('launchctl bootstrap system'));
      expect(script, contains('|| true'));
      expect(script, contains('launchctl kickstart -k system/$label'));
      expect(script, contains("'${FanDaemonPaths.plist}'"));
    });
  });

  group('install gates on the helper\'s own verdict', () {
    test('there is no helper to install', () async {
      final installer = FanDaemonInstaller(runner: _RecordingRunner());
      await expectLater(
        installer.install(sourceBinary: '/nonexistent/toolshed-fand'),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'NO_HELPER'),
        ),
      );
    });

    test(
      'a helper that fails selfcheck never becomes a LaunchDaemon',
      () async {
        final binary = _fakeHelper(passes: false);
        final runner = _RecordingRunner(failSelfcheck: true);
        await expectLater(
          FanDaemonInstaller(runner: runner).install(sourceBinary: binary.path),
          throwsA(
            isA<ToolException>().having(
              (e) => e.code,
              'code',
              'HELPER_UNSOUND',
            ),
          ),
        );
        expect(runner.invocations, hasLength(1));
        expect(runner.invocations.single, endsWith('selfcheck --json'));
      },
    );

    test(
      'a sound helper is handed over once, with the root checks inline',
      () async {
        final binary = _fakeHelper(passes: true);
        final runner = _RecordingRunner();
        await FanDaemonInstaller(
          runner: runner,
        ).install(sourceBinary: binary.path);
        expect(runner.invocations, hasLength(2));
        expect(runner.invocations.first, endsWith('selfcheck --json'));
        expect(runner.invocations.last, startsWith('osascript -e '));

        final script = runner.invocations.last;
        expect(script, contains('install -o root -g wheel -m 0755'));
        // Verified before launchd is asked to run it, so a binary that came out
        // owned by anyone but root is never started.
        expect(script, contains(r'stat -f %Su'));
        expect(script, contains('plutil -lint'));
        expect(script, contains('with administrator privileges'));
      },
    );

    test(
      'a dismissed prompt is reported as a cancellation, not a failure',
      () async {
        final runner = _RecordingRunner(
          osascriptExit: 1,
          osascriptStderr: '0:12: execution error: User canceled. (-128)',
        );
        await expectLater(
          FanDaemonInstaller(runner: runner).start(),
          throwsA(
            isA<ToolException>().having((e) => e.code, 'code', 'AUTH_CANCELED'),
          ),
        );
      },
    );
  });

  group('the client envelope', () {
    test('carries a policy only when the command needs one', () {
      expect(FanDaemonClient.requestJson('ping'), '{"cmd":"ping"}');
      expect(FanDaemonClient.requestJson('clear'), '{"cmd":"clear"}');
      final apply = FanDaemonClient.requestJson(
        'apply',
        policy: FanPolicy.defaults,
      );
      expect(apply, startsWith('{"cmd":"apply","policy":'));
      expect(apply, contains('"leaseSeconds":30'));
    });

    test('names a socket only when it is not the default', () {
      const binary = '/usr/local/bin/toolshed-fand';
      expect(FanDaemonClient(binaryPath: binary).clientArgs('status'), [
        'client',
        '--request',
        '{"cmd":"status"}',
      ]);
      expect(
        FanDaemonClient(
          binaryPath: binary,
          socketPath: '/tmp/dev.sock',
        ).clientArgs('status'),
        [
          'client',
          '--request',
          '{"cmd":"status"}',
          '--socket',
          '/tmp/dev.sock',
        ],
      );
    });

    test(
      'a read is one process with the json flag, never a socket request',
      () async {
        final runner = _RecordingRunner();
        await FanDaemonClient(
          binaryPath: '/usr/local/bin/toolshed-fand',
          runner: runner,
        ).runLocal(FanCommand.telemetry);
        expect(runner.invocations.single, endsWith('telemetry --json'));
      },
    );
  });
}

File _fakeHelper({required bool passes}) {
  final scratch = Directory.systemTemp.createTempSync('toolshed_fand_helper');
  final binary = File('${scratch.path}/toolshed-fand')
    ..writeAsStringSync(
      passes
          ? '#!/bin/sh\necho \'{"checks":13,"failures":[]}\'\n'
          : '#!/bin/sh\necho \'{"checks":13,"failures":["lease"]}\'\nexit 1\n',
    );
  Process.runSync('chmod', ['755', binary.path]);
  addTearDown(() => scratch.deleteSync(recursive: true));
  return binary;
}

/// Answers every command without running anything, and records what was asked.
class _RecordingRunner extends ProcessRunner {
  _RecordingRunner({
    this.osascriptExit = 0,
    this.osascriptStderr = '',
    this.failSelfcheck = false,
  });

  final int osascriptExit;
  final String osascriptStderr;
  final bool failSelfcheck;

  final List<String> invocations = <String>[];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    invocations.add([executable, ...arguments].join(' '));
    if (executable != 'osascript') {
      return failSelfcheck
          ? const ProcResult('helper', 1, '{"failures":["lease"]}', 'unsound')
          : const ProcResult('helper', 0, '{"checks":13,"failures":[]}', '');
    }
    return ProcResult(executable, osascriptExit, '', osascriptStderr);
  }
}
