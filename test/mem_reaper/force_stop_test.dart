import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/paths.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/mem_reaper/macos_backend.dart';
import 'package:toolshed/tools/mem_reaper/managed_app.dart';
import 'package:toolshed/tools/mem_reaper/stop_outcome.dart';

/// Records every command and answers each from a queue, so the test can pin the
/// argv the backend builds and the fallback it takes on a usage error.
class _QueueRunner extends ProcessRunner {
  _QueueRunner(this.replies);

  final List<ProcResult> replies;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    calls.add([executable, ...arguments]);
    return replies.removeAt(0);
  }
}

const _app = ManagedApp(
  id: '4242',
  name: 'Demo',
  liveBytes: 3 * 1024 * 1024 * 1024,
  detail: '/Applications/Demo.app/Contents/MacOS/Demo',
  killMode: KillMode.viaReaper,
);

void main() {
  final script = Paths.scriptPath();
  final python = Paths.interpreter();

  group('the reply', () {
    test('is the last JSON line, after anything the script logged', () {
      final outcome = StopOutcome.parse(
        '[10:00:00]       ! permission denied -- owned by uid 0\n'
        '{"result": "still_running", "pid": 1, "name": "x", "reason": "r"}\n',
      );
      expect(outcome.result, StopResult.stillRunning);
      expect(outcome.isGone, isFalse);
      expect(outcome.describe('x'), 'x is still running: r.');
    });

    test('a reply with no verdict is a failure, never a success', () {
      expect(
        () => StopOutcome.parse('Traceback (most recent call last):\n'),
        throwsA(isA<ToolException>()),
      );
      expect(
        () => StopOutcome.parse('{"result": "maybe"}'),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('the backend', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('stop_home'));
    tearDown(() => home.deleteSync(recursive: true));

    test(
      'sends the pid, the path it expects and the force flag to mem_reaper',
      () async {
        final runner = _QueueRunner([
          const ProcResult(
            'python3',
            0,
            '{"result": "stopped", "pid": 4242}',
            '',
          ),
        ]);
        final backend = MacOSMemReaperBackend(
          runner: runner,
          homeOverride: home.path,
        );
        final outcome = await backend.stopProcess(_app, immediate: true);

        expect(outcome.result, StopResult.stopped);
        final call = runner.calls.single;
        expect(call[1], endsWith('mem_reaper.py'));
        expect(call.sublist(2), [
          '--stop-pid',
          '4242',
          '--expect-path',
          '/Applications/Demo.app/Contents/MacOS/Demo',
          '--force',
        ]);
      },
      skip: script == null || python == null ? 'no mem_reaper.py here' : false,
    );

    test(
      'a script that rejects the flag is reported, not read as a stop',
      () async {
        final candidates = Paths.scriptCandidates().where(
          (s) => File(s).existsSync(),
        );
        final runner = _QueueRunner([
          for (final _ in candidates)
            const ProcResult('python3', 2, '', 'unrecognized arguments'),
        ]);
        final backend = MacOSMemReaperBackend(
          runner: runner,
          homeOverride: home.path,
        );
        await expectLater(
          backend.stopProcess(_app),
          throwsA(
            isA<ToolException>().having((e) => e.code, 'code', 'OLD_SCRIPT'),
          ),
        );
      },
      skip: script == null || python == null ? 'no mem_reaper.py here' : false,
    );

    test('a row that is not a pid is refused before anything runs', () async {
      final runner = _QueueRunner([]);
      final backend = MacOSMemReaperBackend(
        runner: runner,
        homeOverride: home.path,
      );
      await expectLater(
        backend.stopProcess(
          const ManagedApp(id: 'com.example.app', name: 'Phone row'),
        ),
        throwsA(isA<ToolException>()),
      );
      expect(runner.calls, isEmpty);
    });
  });

  // The real script against a real child. The state file is a scratch one, so
  // the respawn guard in the user's home never learns about these stops.
  group(
    'mem_reaper.py --stop-pid',
    () {
      late Directory scratch;
      setUp(() => scratch = Directory.systemTemp.createTempSync('stop_state'));
      tearDown(() => scratch.deleteSync(recursive: true));

      Future<StopOutcome> stop(int pid, {String? expectPath}) async {
        final result = await Process.run(python!, [
          script!,
          '--state-file',
          '${scratch.path}/state.json',
          '--stop-pid',
          '$pid',
          '--grace',
          '1',
          if (expectPath != null) ...['--expect-path', expectPath],
        ]);
        return StopOutcome.parse(result.stdout as String);
      }

      Future<String> comm(int pid) async =>
          ((await Process.run('ps', ['-p', '$pid', '-o', 'comm='])).stdout
                  as String)
              .trim();

      test('stops a process of yours, then reports it already gone', () async {
        final child = await Process.start('sleep', ['30']);
        final outcome = await stop(
          child.pid,
          expectPath: await comm(child.pid),
        );
        expect(outcome.result, StopResult.stopped);
        expect(await child.exitCode, isNot(0));
        expect((await stop(child.pid)).result, StopResult.gone);
      });

      test('refuses when the pid now names another executable', () async {
        final child = await Process.start('sleep', ['30']);
        try {
          final outcome = await stop(child.pid, expectPath: '/bin/not-sleep');
          expect(outcome.result, StopResult.changed);
          expect(
            child.kill(ProcessSignal.sigcont),
            isTrue,
            reason: 'still alive',
          );
        } finally {
          child.kill(ProcessSignal.sigkill);
        }
      });

      test(
        'refuses the console that asked, and another user\'s process',
        () async {
          // This test process is the script's ancestor, as toolshed would be.
          expect((await stop(pid)).result, StopResult.protected);
          expect((await stop(1)).result, StopResult.notYours);
        },
      );
    },
    skip: !Platform.isMacOS || script == null || python == null,
  );
}
