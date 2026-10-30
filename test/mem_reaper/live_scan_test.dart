import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/mem_reaper/macos_backend.dart';

/// A runner that answers from canned output and records what was asked, so the
/// live scan can be checked without racing a real `top`.
class _CannedRunner extends ProcessRunner {
  _CannedRunner(this.responses);

  final Map<String, String> responses;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    calls.add([executable, ...arguments]);
    final out = responses[executable];
    if (out == null) {
      throw StateError('the scan did not expect to run $executable');
    }
    return ProcResult(executable, 0, out, '');
  }

  List<String>? argumentsFor(String executable) {
    for (final call in calls) {
      if (call.first == executable) return call.sublist(1);
    }
    return null;
  }
}

void main() {
  final top = File('test/fixtures/top_mem.txt').readAsStringSync();

  group('live scan', () {
    test('ps is given one -o holding the whole format list', () async {
      // Splitting 'pid=,uid=,comm=' across arguments makes ps read 'uid=' as a
      // user operand and fail with "illegal argument", which is a scan that
      // never worked rather than a phone with nothing running.
      final runner = _CannedRunner({'id': '501\n', 'top': top, 'ps': ''});
      final backend = MacOSMemReaperBackend(runner: runner);
      await backend.ranked();
      expect(runner.argumentsFor('ps'), ['-axo', 'pid=,uid=,comm=']);
    });

    test('sizes from top join ownership from ps on pid', () async {
      final runner = _CannedRunner({
        'id': '501\n',
        'top': top,
        'ps':
            '  28961   501 /Applications/Demo.app/Contents/MacOS/Demo\n'
            '   14154     0 /sbin/launchd\n'
            '   16915   501 /usr/bin/true\n',
      });
      final backend = MacOSMemReaperBackend(runner: runner);
      final apps = await backend.ranked();

      // 14154 belongs to another user, so only our two sized rows survive,
      // biggest first.
      expect(apps.map((a) => a.id), ['28961', '16915']);
      expect(apps.first.name, 'Demo');
      expect(apps.first.liveBytes, 1215 * 1024 * 1024);
      expect(apps.last.liveBytes, 988 * 1024 * 1024);
    });

    test(
      'a process with no top row is dropped rather than shown as zero',
      () async {
        final runner = _CannedRunner({
          'id': '501\n',
          'top': 'PID    MEM\n9999 1.00G\n',
          'ps': '  8888   501 /usr/bin/other\n',
        });
        final backend = MacOSMemReaperBackend(runner: runner);
        expect(await backend.ranked(), isEmpty);
      },
    );
  });
}
