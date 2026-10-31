import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/dev_sweeper/dev_sweeper_backend.dart';
import 'package:toolshed/tools/dev_sweeper/sweep_target.dart';

/// Answers by command and records the argv, so a scan or a Trash move can be
/// checked without touching the real ones.
class _Runner extends ProcessRunner {
  _Runner(this.answer);

  final ProcResult Function(String executable, List<String> arguments) answer;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    calls.add([executable, ...arguments]);
    return answer(executable, arguments);
  }
}

Future<Directory> temporaryHome() async {
  final dir = await Directory.systemTemp.createTemp('toolshed-sweep-');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return dir;
}

SweepTarget target(String path, {int? bytes = 4096}) =>
    SweepTarget(path: path, label: 'cache', ecosystem: 'Tool', bytes: bytes);

void main() {
  group('macOS scan', () {
    test(
      'measures known caches and project node_modules, largest first',
      () async {
        final home = await temporaryHome();
        final gradle = '${home.path}/.gradle/caches';
        final modules = '${home.path}/Project/app/node_modules';
        await Directory(gradle).create(recursive: true);
        await Directory(modules).create(recursive: true);
        final sizes = {gradle: 2048000, modules: 5120};
        final runner = _Runner((executable, arguments) {
          if (executable == 'du') {
            return ProcResult(
              'du',
              0,
              [
                for (final path in arguments.skip(1)) '${sizes[path]}\t$path',
              ].join('\n'),
              '',
            );
          }
          if (executable == 'find') {
            // A duplicate line proves the scan does not list a module twice.
            return ProcResult('find', 0, '$modules\n$modules\n', '');
          }
          throw StateError('unexpected $executable $arguments');
        });

        final report = await MacDevSweeperBackend(
          runner: runner,
          homeOverride: home.path,
        ).scanCaches();

        expect(report.targets.map((target) => target.label).toList(), [
          'Gradle caches',
          'Project/app/node_modules',
        ]);
        expect(report.targets.first.bytes, 2048000 * 1024);
        expect(report.targets.first.sizeLabel, '2.0 GB');
        expect(report.targets.last.bytes, 5120 * 1024);
        expect(report.targets.last.sizeLabel, '5.0 MB');
        expect(report.targets.last.ecosystem, 'Node');
        expect(report.totalBytes, 2102394880);

        expect(runner.calls[0].sublist(1), [
          '${home.path}/Project',
          '-maxdepth',
          '6',
          '-type',
          'd',
          '-name',
          'node_modules',
          '-prune',
          '-print',
        ]);
        expect(runner.calls[1].sublist(1), ['-sk', gradle, modules]);
        expect(report.notes, hasLength(1));
        expect(report.notes.single, contains('Only build caches'));
      },
    );

    test('an unmeasured cache is unknown, with a note saying so', () async {
      final home = await temporaryHome();
      final gradle = '${home.path}/.gradle/caches';
      await Directory(gradle).create(recursive: true);
      final runner = _Runner(
        (_, _) => const ProcResult('du', 1, '', 'du: cannot read directory'),
      );

      final report = await MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      ).scanCaches();

      final row = report.targets.single;
      expect(row.bytes, isNull);
      expect(row.sizeLabel, 'size unknown');
      expect(
        report.notes,
        contains('Sizes could not be measured: du: cannot read directory.'),
      );
    });

    test('a partial measurement names how many sizes are unknown', () async {
      final home = await temporaryHome();
      final gradle = '${home.path}/.gradle/caches';
      final npm = '${home.path}/.npm/_cacache';
      await Directory(gradle).create(recursive: true);
      await Directory(npm).create(recursive: true);
      final runner = _Runner(
        (_, _) => ProcResult('du', 0, '2048\t$gradle\n', ''),
      );

      final report = await MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      ).scanCaches();

      expect(
        report.notes,
        contains(
          '1 directory could not be measured; its size is shown as unknown.',
        ),
      );
      final unmeasured = report.targets.singleWhere(
        (target) => target.path == npm,
      );
      expect(unmeasured.bytes, isNull);
    });

    test('nothing to find is an empty list, not a failed scan', () async {
      final home = await temporaryHome();
      final runner = _Runner(
        (executable, arguments) =>
            throw StateError('unexpected $executable $arguments'),
      );

      final report = await MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      ).scanCaches();

      expect(report.targets, isEmpty);
      expect(runner.calls, isEmpty);
      expect(report.notes, hasLength(2));
      expect(report.notes.first, contains('No build caches were found'));
      expect(report.notes.last, contains('Only build caches'));
    });

    test('a find that fails is a note beside an empty list', () async {
      final home = await temporaryHome();
      await Directory('${home.path}/Project').create(recursive: true);
      final runner = _Runner(
        (_, _) =>
            const ProcResult('find', 1, '', 'find: Project: Permission denied'),
      );

      final report = await MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      ).scanCaches();

      expect(report.targets, isEmpty);
      expect(
        report.notes.first,
        'Could not search ${home.path}/Project for node_modules: '
        'find: Project: Permission denied.',
      );
    });

    test('a find that runs too long is a note, not a crash', () async {
      final home = await temporaryHome();
      await Directory('${home.path}/Project').create(recursive: true);
      final runner = _Runner(
        (_, _) => throw const ToolException('TIMEOUT', 'find took too long'),
      );

      final report = await MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      ).scanCaches();

      expect(report.targets, isEmpty);
      expect(
        report.notes.first,
        'Searching ${home.path}/Project for node_modules took too long and '
        'stopped.',
      );
    });

    test('offers the sweep, and has no agent, settings or log', () async {
      final backend = MacDevSweeperBackend(
        runner: _Runner((_, _) => throw StateError('no command expected')),
        homeOverride: '/Users/me',
      );

      expect(backend.capabilities.support, Support.full);
      expect(backend.capabilities.actions, {
        ToolAction.showCaches,
        ToolAction.trashCaches,
      });
      expect(backend.descriptor.implPath, 'du · find · Trash');

      final status = await backend.status();
      expect(status.state, AgentState.notApplicable);
      expect(status.notes.single, contains('du and find'));

      await expectLater(
        backend.start(),
        throwsA(
          isA<ToolException>().having(
            (error) => error.code,
            'code',
            'NO_AGENT',
          ),
        ),
      );
      await expectLater(
        backend.readConfig(),
        throwsA(
          isA<ToolException>().having(
            (error) => error.code,
            'code',
            'NO_SETTINGS',
          ),
        ),
      );
      await expectLater(backend.tailLog(), emitsError(isA<ToolException>()));
    });
  });

  group('macOS Trash', () {
    test('moves a known cache and counts only what moved', () async {
      final home = await temporaryHome();
      final gradle = '${home.path}/.gradle/caches';
      await Directory(gradle).create(recursive: true);
      final runner = _Runner(
        (_, _) => const ProcResult('osascript', 0, '', ''),
      );
      final backend = MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      );

      final outcome = await backend.trashCaches([target(gradle)]);

      expect(outcome.failures, isEmpty);
      expect(outcome.trashed.single.path, gradle);
      expect(outcome.freedBytes, 4096);
      expect(outcome.describe(), 'Moved 1 item (4.0 KB) to the Trash.');
      final call = runner.calls.single;
      expect(call[0], 'osascript');
      expect(call.sublist(1, 4), ['-l', 'JavaScript', '-e']);
      expect(call[4], contains('trashItemAtURLResultingItemURLError'));
      expect(call[5], gradle);
    });

    test('a Trash that refuses is reported with its own words', () async {
      final home = await temporaryHome();
      final gradle = '${home.path}/.gradle/caches';
      await Directory(gradle).create(recursive: true);
      final runner = _Runner(
        (_, _) => const ProcResult(
          'osascript',
          1,
          '',
          'The item could not be moved.',
        ),
      );

      final outcome = await MacDevSweeperBackend(
        runner: runner,
        homeOverride: home.path,
      ).trashCaches([target(gradle)]);

      expect(outcome.trashed, isEmpty);
      expect(outcome.freedBytes, 0);
      expect(outcome.failures.single.target.path, gradle);
      expect(outcome.failures.single.message, 'The item could not be moved.');
      expect(
        outcome.describe(),
        'Nothing could be moved. The item could not be moved.',
      );
    });

    test(
      'a runner that cannot start the Trash is a failure, not a crash',
      () async {
        final home = await temporaryHome();
        final gradle = '${home.path}/.gradle/caches';
        await Directory(gradle).create(recursive: true);
        final runner = _Runner(
          (_, _) => throw const ToolException(
            'EXEC_FAILED',
            'Could not run osascript: denied',
          ),
        );

        final outcome = await MacDevSweeperBackend(
          runner: runner,
          homeOverride: home.path,
        ).trashCaches([target(gradle)]);

        expect(outcome.trashed, isEmpty);
        expect(
          outcome.failures.single.message,
          'Could not run osascript: denied',
        );
      },
    );

    group('refuses', () {
      late Directory home;
      late _Runner runner;
      late MacDevSweeperBackend backend;

      setUp(() async {
        home = await temporaryHome();
        runner = _Runner((_, _) => const ProcResult('osascript', 0, '', ''));
        backend = MacDevSweeperBackend(runner: runner, homeOverride: home.path);
      });

      Future<SweepFailure> refused(SweepTarget requested) async {
        final outcome = await backend.trashCaches([requested]);
        expect(outcome.trashed, isEmpty);
        expect(outcome.freedBytes, 0);
        expect(runner.calls, isEmpty);
        return outcome.failures.single;
      }

      test('a path the scan did not produce', () async {
        final keep = '${home.path}/Project/keep';
        await Directory(keep).create(recursive: true);

        final failure = await refused(target(keep));

        expect(
          failure.message,
          'It was not part of the scan, so it was left alone.',
        );
      });

      test('a node_modules that is a symbolic link', () async {
        final real = '${home.path}/Project/app/real';
        await Directory(real).create(recursive: true);
        final link = '${home.path}/Project/app/node_modules';
        await Link(link).create(real);

        final failure = await refused(target(link));

        expect(
          failure.message,
          'It is a symbolic link, so only the link would move.',
        );
      });

      test('a node_modules that resolves outside home', () async {
        final outside = '${home.path}-outside/node_modules';
        await Directory(outside).create(recursive: true);
        addTearDown(() async {
          final directory = Directory('${home.path}-outside');
          if (directory.existsSync()) await directory.delete(recursive: true);
        });

        final failure = await refused(target(outside));

        expect(
          failure.message,
          'It resolves outside your home directory, so it was left alone.',
        );
      });

      test('a file where the cache used to be', () async {
        final gradle = '${home.path}/.gradle/caches';
        await Directory('${home.path}/.gradle').create(recursive: true);
        await File(gradle).writeAsString('not a directory');

        final failure = await refused(target(gradle));

        expect(
          failure.message,
          'It is no longer a directory, so it was left alone.',
        );
      });

      test('home itself', () async {
        final nested = Directory('${home.path}/node_modules');
        await nested.create();
        final nestedBackend = MacDevSweeperBackend(
          runner: runner,
          homeOverride: nested.path,
        );

        final outcome = await nestedBackend.trashCaches([target(nested.path)]);

        expect(outcome.trashed, isEmpty);
        expect(runner.calls, isEmpty);
        expect(
          outcome.failures.single.message,
          'Refusing to move your home directory.',
        );
      });
    });
  });

  group('Linux Trash', () {
    test('moves a cache into a scratch freedesktop Trash', () async {
      final home = await temporaryHome();
      final gradle = '${home.path}/.gradle/caches';
      await Directory(gradle).create(recursive: true);
      await File('$gradle/blob.bin').writeAsBytes([1, 2, 3]);
      final data = '${home.path}/data';
      final backend = LinuxDevSweeperBackend(
        homeOverride: home.path,
        dataHomeOverride: data,
        environment: const {},
      );

      final outcome = await backend.trashCaches([target(gradle)]);

      expect(outcome.failures, isEmpty);
      expect(outcome.freedBytes, 4096);
      expect(Directory(gradle).existsSync(), isFalse);
      expect(File('$data/Trash/files/caches/blob.bin').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(File('$data/Trash/info/caches.trashinfo').existsSync(), isTrue);
    });

    test('honours XDG_DATA_HOME when no override is given', () async {
      final home = await temporaryHome();
      final gradle = '${home.path}/.gradle/caches';
      await Directory(gradle).create(recursive: true);
      final backend = LinuxDevSweeperBackend(
        homeOverride: home.path,
        environment: {'XDG_DATA_HOME': '${home.path}/xdg'},
      );

      final outcome = await backend.trashCaches([target(gradle)]);

      expect(outcome.failures, isEmpty);
      expect(
        Directory('${home.path}/xdg/Trash/files/caches').existsSync(),
        isTrue,
      );
    });
  });

  group('Windows', () {
    test('measures with PowerShell and quotes an apostrophe twice', () async {
      final runner = _Runner(
        (_, _) => const ProcResult(
          'powershell',
          0,
          "/tmp/O'Brien\\cache\t2048\n",
          '',
        ),
      );
      final backend = WindowsDevSweeperBackend(
        runner: runner,
        homeOverride: r'C:\Users\me',
        environment: const {'LOCALAPPDATA': r'C:\Users\me\AppData\Local'},
      );
      final notes = <String>[];

      final sizes = await backend.measure(["/tmp/O'Brien\\cache"], notes);

      expect(sizes, {"/tmp/O'Brien\\cache": 2048});
      expect(notes, isEmpty);
      final script = runner.calls.single[4];
      expect(script, contains("'/tmp/O''Brien\\cache'"));
      expect(script, contains('Measure-Object'));
    });

    test('sends a directory to the Recycle Bin, never a delete', () async {
      final runner = _Runner(
        (_, _) => const ProcResult('powershell', 0, '', ''),
      );
      final backend = WindowsDevSweeperBackend(
        runner: runner,
        homeOverride: r'C:\Users\me',
        environment: const {},
      );

      await backend.trashOne(target(r"C:\Users\me\O'Brien\node_modules"));

      final call = runner.calls.single;
      expect(call[0], 'powershell');
      final script = call[4];
      expect(
        script,
        contains(
          r"DeleteDirectory('C:\Users\me\O''Brien\node_modules', "
          "'OnlyErrorDialogs', 'SendToRecycleBin')",
        ),
      );
    });

    test('a refused move carries the PowerShell message', () async {
      final runner = _Runner(
        (_, _) => const ProcResult('powershell', 1, '', 'Access is denied.'),
      );
      final backend = WindowsDevSweeperBackend(
        runner: runner,
        homeOverride: r'C:\Users\me',
        environment: const {},
      );

      await expectLater(
        backend.trashOne(target(r'C:\Users\me\.gradle\caches')),
        throwsA(
          isA<ToolException>()
              .having((error) => error.code, 'code', 'TRASH_FAILED')
              .having((error) => error.message, 'message', 'Access is denied.'),
        ),
      );
    });

    test('offers the sweep and names the Recycle Bin', () async {
      final backend = WindowsDevSweeperBackend(
        runner: _Runner((_, _) => throw StateError('no command expected')),
        homeOverride: r'C:\Users\me',
        environment: const {},
      );

      expect(backend.capabilities.support, Support.full);
      expect(backend.capabilities.actions, {
        ToolAction.showCaches,
        ToolAction.trashCaches,
      });
      expect(backend.descriptor.implPath, 'PowerShell · Recycle Bin');
      expect(backend.descriptor.summary, contains('Recycle Bin'));
    });
  });
}
