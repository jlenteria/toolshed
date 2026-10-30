import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/app_lock/lock_agent.dart';

/// The agent's life cycle: the plist it writes, and the launchd answers it
/// trusts.
///
/// The plist is checked with the machine's own `plutil`, because a plist that
/// launchd refuses to read is not a lock, and the Dart side is not the judge of
/// that. Everything else about launchd is faked — a test that bootstrapped a
/// real agent would leave a watcher running on the developer's own login.
void main() {
  late Directory home;
  late Directory agents;
  late _Launchd launchd;

  setUp(() {
    home = Directory.systemTemp.createTempSync('toolshed-lockagent');
    agents = Directory('${home.path}/Library/LaunchAgents')
      ..createSync(recursive: true);
    launchd = _Launchd();
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  LockAgentInstaller installer({bool? selfcheckOk}) => LockAgentInstaller(
    runner: launchd..selfcheckOk = selfcheckOk,
    homeOverride: home.path,
  );

  File sourceBinary() {
    final file = File('${home.path}/toolshed-lockd')
      ..writeAsStringSync('#!/bin/sh\n');
    return file;
  }

  group('the plist', () {
    test('is what plutil and launchd will read', () {
      final plist = File('${home.path}/written.plist');
      plist.writeAsStringSync(
        LockAgentInstaller.plistTemplate(
          binary: '/Applications/Toolshed.app/Contents/MacOS/toolshed-lockd',
          logPath: '/Users/someone/Library/Logs/toolshed-lockd.log',
        ),
      );
      final lint = Process.runSync('plutil', ['-lint', plist.path]);
      expect(lint.stdout, contains('OK'), reason: lint.stderr.toString());

      final json =
          jsonDecode(
                Process.runSync('plutil', [
                      '-convert',
                      'json',
                      '-o',
                      '-',
                      plist.path,
                    ]).stdout
                    as String,
              )
              as Map<String, Object?>;
      expect(json['Label'], 'com.bling.toolshed.lockd');
      expect(json['ProgramArguments'], [
        '/Applications/Toolshed.app/Contents/MacOS/toolshed-lockd',
        'watch',
      ]);
      expect(json['LimitLoadToSessionType'], 'Aqua');
      expect(json['RunAtLoad'], isTrue);
      expect(json['KeepAlive'], isTrue);
      expect(json['ThrottleInterval'], 10);
      expect(
        json['StandardOutPath'],
        '/Users/someone/Library/Logs/toolshed-lockd.log',
      );
      expect(json['StandardErrorPath'], json['StandardOutPath']);
    });

    test(
      'escapes a path with an angle bracket rather than writing bad XML',
      () {
        final plist = LockAgentInstaller.plistTemplate(
          binary: '/tmp/a&b<x',
          logPath: '/tmp/log',
        );
        expect(plist, contains('/tmp/a&amp;b&lt;x'));
        expect(plist, isNot(contains('<x')));
      },
    );
  });

  group('finding an agent already there', () {
    test('reads the plists rather than trusting the label', () async {
      File('${agents.path}/com.other.person.plist').writeAsStringSync(
        LockAgentInstaller.plistTemplate(
          binary: '/usr/local/bin/toolshed-lockd',
          logPath: '/tmp/log',
        ),
      );
      final found = await installer().findPlist();
      expect(found, '${agents.path}/com.other.person.plist');
    });

    test('ignores a plist that runs something else', () async {
      File('${agents.path}/com.apple.whatever.plist').writeAsStringSync(
        LockAgentInstaller.plistTemplate(
          binary: '/usr/bin/true',
          logPath: '/tmp/log',
        ),
      );
      expect(await installer().findPlist(), isNull);
    });

    test('a directory with no plists is not an error', () async {
      agents.deleteSync(recursive: true);
      expect(await installer().findPlist(), isNull);
    });
  });

  group('installing', () {
    test('copies the binary, writes the plist and bootstraps it', () async {
      await installer().install(sourceBinary: sourceBinary().path);
      expect(
        File(
          '${home.path}/Library/Application Support/toolshed/toolshed-lockd',
        ).existsSync(),
        isTrue,
        reason:
            'a LaunchAgent aimed at a build directory stops working the '
            'day the build directory moves',
      );
      expect(launchd.commands, contains('bootstrap'));
      // A loaded watcher keeps the old binary mapped, so a reinstall has to
      // boot it out before the copy; the bootstrap that follows is otherwise
      // refused as already loaded and the old helper keeps running.
      expect(
        launchd.commands.indexOf('bootout'),
        lessThan(launchd.commands.indexOf('bootstrap')),
      );
      expect(
        File('${agents.path}/com.bling.toolshed.lockd.plist').existsSync(),
        isTrue,
      );
    });

    test('refuses a helper that is not there', () async {
      await expectLater(
        installer().install(sourceBinary: '${home.path}/nowhere'),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'NO_HELPER'),
        ),
      );
      expect(agents.listSync(), isEmpty);
    });

    test('refuses a helper that fails its own selfcheck', () async {
      await expectLater(
        installer(
          selfcheckOk: false,
        ).install(sourceBinary: sourceBinary().path),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'HELPER_UNSOUND'),
        ),
      );
      expect(agents.listSync(), isEmpty);
    });

    test('refuses to add a second watcher for one login', () async {
      File('${agents.path}/someone.else.plist').writeAsStringSync(
        LockAgentInstaller.plistTemplate(
          binary: '/usr/local/bin/toolshed-lockd',
          logPath: '/tmp/log',
        ),
      );
      await expectLater(
        installer().install(sourceBinary: sourceBinary().path),
        throwsA(
          isA<ToolException>().having(
            (e) => e.code,
            'code',
            'ALREADY_INSTALLED',
          ),
        ),
      );
    });

    test('keeps a plist it is replacing rather than deleting it', () async {
      final mine = File('${agents.path}/com.bling.toolshed.lockd.plist')
        ..writeAsStringSync('the old one');
      await installer().install(sourceBinary: sourceBinary().path);
      expect(mine.readAsStringSync(), isNot('the old one'));
      expect(
        agents.listSync().whereType<File>().where(
          (f) => f.path.contains('replaced'),
        ),
        hasLength(1),
      );
    });
  });

  group('start, stop and uninstall', () {
    test('there is nothing to start before there is a plist', () async {
      await expectLater(
        installer().start(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'NOT_INSTALLED'),
        ),
      );
    });

    test('start does not claim success until launchd says running', () async {
      await installer().install(sourceBinary: sourceBinary().path);
      launchd.printState = 'state = not running';
      await expectLater(
        installer().start(),
        throwsA(
          isA<ToolException>().having(
            (e) => e.code,
            'code',
            'NOT_RUNNING_AFTER_CHANGE',
          ),
        ),
      );
    });

    test('a service launchd has never heard of is already stopped', () async {
      launchd.bootoutCode = 3;
      launchd.bootoutError = 'Could not find service in domain for user';
      await installer().stop();
      expect(launchd.commands, contains('bootout'));
    });

    test('a real bootout failure is said out loud', () async {
      launchd.bootoutCode = 1;
      launchd.bootoutError = 'I/O error talking to launchd';
      await expectLater(
        installer().stop(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'BOOTOUT_FAILED'),
        ),
      );
    });

    test('uninstall unloads it and keeps the plist as a backup', () async {
      final agent = installer();
      await agent.install(sourceBinary: sourceBinary().path);
      expect(agent.takeNotice(), isNull);

      await agent.uninstall();
      expect(
        File('${agents.path}/com.bling.toolshed.lockd.plist').existsSync(),
        isFalse,
      );
      expect(
        agents.listSync().where((f) => f.path.contains('uninstalled')),
        hasLength(1),
      );
      expect(agent.takeNotice(), contains('kept at'));
      expect(launchd.commands, contains('bootout'));
    });

    test('isInstalled needs both the plist and the binary it points at', () {
      expect(installer().isInstalled, isFalse);
      File(
        '${agents.path}/com.bling.toolshed.lockd.plist',
      ).writeAsStringSync('x');
      expect(installer().isInstalled, isFalse);
      Directory(
        '${home.path}/Library/Application Support/toolshed',
      ).createSync(recursive: true);
      File(
        '${home.path}/Library/Application Support/toolshed/toolshed-lockd',
      ).writeAsStringSync('x');
      expect(installer().isInstalled, isTrue);
    });
  });

  group('the client reads the helper honestly', () {
    test('a reply with no apps is a bad reply, not an empty list', () async {
      final client = LockAgentClient(
        helperPath: '/fake',
        runner: _StubHelper('{"ok": true}'),
      );
      await expectLater(client.installedApps(), throwsA(isA<ToolException>()));
    });

    test(
      'a status with no watching says so, and the gap is the reason',
      () async {
        final info = LockAgentInfo.fromJson({
          'uid': 501,
          'store': '/x',
          'watching': false,
          'watchPid': 0,
          'secret': {'set': true},
          'config': {'present': true, 'enabled': true, 'lockedCount': 3},
        });
        expect(info.isEnforcing, isFalse);
        expect(info.gap, contains('not running'));
      },
    );

    test('enforcing needs all four things', () {
      final info = LockAgentInfo.fromJson({
        'watching': true,
        'watchPid': 12,
        'secret': {'set': true, 'iterations': 120000},
        'config': {'enabled': true, 'lockedCount': 1},
      });
      expect(info.isEnforcing, isTrue);
      expect(info.gap, isEmpty);
      expect(info.watchPid, 12);
    });

    test('an allowance keeps who granted it', () {
      final allowance = Allowance.fromJson({
        'bundleId': 'com.apple.Notes',
        'expiresAt':
            DateTime.now()
                .add(const Duration(minutes: 3))
                .millisecondsSinceEpoch /
            1000.0,
        'grantedBy': 'dialog',
      });
      expect(allowance.isExpired(DateTime.now()), isFalse);
      expect(allowance.grantedBy, 'dialog');
      expect(
        allowance.remaining(DateTime.now()),
        lessThan(const Duration(minutes: 4)),
      );
    });

    test('an expired allowance reads as none', () {
      final app = LockableApp.fromJson({
        'bundleId': 'com.apple.Notes',
        'name': 'Notes',
        'path': '/x',
        'unlockedUntil':
            DateTime.now()
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch /
            1000.0,
      });
      expect(app.remaining(DateTime.now()), isNull);
    });
  });
}

/// launchd, plutil and id, answered from a list of what to say.
class _Launchd extends ProcessRunner {
  final List<List<String>> received = [];

  bool? selfcheckOk;
  String printState = 'pid = 9021\nstate = running';
  int bootoutCode = 0;
  String bootoutError = '';

  List<String> get commands => [
    for (final args in received)
      if (args.first == 'launchctl') args[1] else args.first,
  ];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    received.add(arguments);
    if (arguments.contains('selfcheck')) {
      return ProcResult(
        executable,
        selfcheckOk == false ? 1 : 0,
        selfcheckOk == false ? 'FAIL a decision is wrong' : 'all checks passed',
        '',
      );
    }
    if (executable.endsWith('plutil')) {
      if (arguments.contains('-lint')) {
        return const ProcResult('plutil', 0, '', 'OK');
      }
      // The convert is done by the machine's own plutil: what a plist says is
      // not something this file should be guessing with a regex.
      final result = Process.runSync('plutil', arguments);
      return ProcResult(
        'plutil',
        result.exitCode,
        result.stdout as String,
        result.stderr as String,
      );
    }
    if (executable == 'chmod' || executable == 'cp') {
      return const ProcResult('chmod', 0, '', '');
    }
    if (executable == 'id') return const ProcResult('id', 0, '501\n', '');
    if (executable == 'launchctl') {
      switch (arguments.first) {
        case 'bootstrap':
          return const ProcResult('launchctl', 0, '', '');
        case 'bootout':
          return ProcResult('launchctl', bootoutCode, '', bootoutError);
        case 'print':
          return ProcResult('launchctl', 0, printState, '');
      }
    }
    return ProcResult(
      executable,
      1,
      '',
      'the fake has no answer for $arguments',
    );
  }
}

class _StubHelper extends ProcessRunner {
  _StubHelper(this.stdout);

  final String stdout;

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async => ProcResult(executable, 0, stdout, '');
}
