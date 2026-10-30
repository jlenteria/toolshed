import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/app_lock/app_lock_backend.dart';
import 'package:toolshed/tools/app_lock/app_lock_config.dart';
import 'package:toolshed/tools/app_lock/lock_agent.dart';

import 'fake_lockd.dart';

/// The backend over a helper that is a list of calls.
///
/// Nothing here runs launchctl, deletes a plist or hashes a passphrase: the
/// process boundary is faked and the files live in a scratch directory. What is
/// real is the capability table, because that is what the buttons are drawn
/// from, and the shape of the JSON both sides of that boundary agree on.
void main() {
  late Directory scratch;
  late File configFile;
  late File fakeBinary;
  late FakeLockd lockd;

  MacAppLockBackend backend({String? helper}) => MacAppLockBackend(
    runner: lockd,
    helperPath: helper ?? fakeBinary.path,
    configFile: configFile,
    storeDir: scratch.path,
    homeOverride: scratch.path,
  );

  /// Puts the two files [LockAgentInstaller.isInstalled] looks for, under the
  /// scratch home rather than the real one.
  void makeInstalled() {
    final agents = Directory('${scratch.path}/Library/LaunchAgents')
      ..createSync(recursive: true);
    File(
      '${agents.path}/com.bling.toolshed.lockd.plist',
    ).writeAsStringSync('<plist/>');
    final support = Directory(
      '${scratch.path}/Library/Application Support/toolshed',
    )..createSync(recursive: true);
    File('${support.path}/toolshed-lockd').writeAsStringSync('mach-o');
  }

  /// The failure a call is expected to raise, or null when it did not.
  Future<ToolException?> capture(Future<void> Function() body) async {
    try {
      await body();
      return null;
    } on ToolException catch (e) {
      return e;
    }
  }

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('toolshed-applock');
    configFile = File('${scratch.path}/app_lock.json');
    // The backend only believes in a helper it can see on disk, so the fake
    // binary has to exist even though the fake runner never execs it.
    fakeBinary = File('${scratch.path}/toolshed-lockd')
      ..writeAsStringSync('#!/not/really/a/macho\n');
    lockd = FakeLockd();
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  group('capabilities', () {
    test('with no helper there is nothing to gate the buttons on', () {
      final caps = backend(helper: '/nope/toolshed-lockd').capabilities;
      expect(caps.support, Support.helperMissing);
      expect(caps.actions, isEmpty);
      expect(caps.can(ToolAction.configure), isFalse);
      expect(caps.can(ToolAction.setPassphrase), isFalse);
    });

    test('an uninstalled agent offers install and not start', () {
      final caps = backend().capabilities;
      expect(caps.support, Support.full);
      expect(caps.can(ToolAction.install), isTrue);
      expect(caps.can(ToolAction.start), isFalse);
      expect(caps.can(ToolAction.stop), isFalse);
      expect(caps.can(ToolAction.setPassphrase), isTrue);
      expect(caps.can(ToolAction.tailLogs), isTrue);
    });

    test('an installed agent swaps install for start, stop and uninstall', () {
      makeInstalled();
      final caps = backend().capabilities;
      expect(caps.can(ToolAction.install), isFalse);
      expect(caps.can(ToolAction.start), isTrue);
      expect(caps.can(ToolAction.stop), isTrue);
      expect(caps.can(ToolAction.uninstall), isTrue);
      // An agent runs the binary it bootstrapped with, so an installed one
      // needs a way to take the helper this app carries.
      expect(caps.can(ToolAction.update), isTrue);
    });
  });

  group('status', () {
    test('no watcher and no plist is notInstalled', () async {
      final status = await backend().status();
      expect(status.state, AgentState.notInstalled);
      expect(
        status.notes.any((note) => note.contains('No passphrase is set')),
        isTrue,
      );
    });

    test(
      'a watcher with a pid is running, and the pid is the watcher',
      () async {
        lockd.watching = true;
        lockd.passphrase = true;
        lockd.lockedCount = 2;
        final status = await backend().status();
        expect(status.state, AgentState.running);
        expect(status.pid, 9021);
        expect(
          status.notes.any(
            (note) => note.contains('2 app(s) on the lock list'),
          ),
          isTrue,
        );
        expect(
          status.notes.any((note) => note.contains('120000 PBKDF2')),
          isTrue,
        );
      },
    );

    test('a plist with no process says nothing is being closed', () async {
      makeInstalled();
      final status = await backend().status();
      expect(status.state, AgentState.installedStopped);
      expect(
        status.notes.any(
          (note) =>
              note.contains('installed but not running') &&
              note.contains('nothing is being closed'),
        ),
        isTrue,
      );
    });

    test('a missing helper is a state of its own, before any call', () async {
      final status = await backend(helper: '/nope/toolshed-lockd').status();
      expect(status.state, AgentState.notInstalled);
      expect(lockd.calls, isEmpty);
    });
  });

  group('the lock list', () {
    test('writes what it is given and reads it back', () async {
      final draft = const AppLockConfig(
        unlockMinutes: 30,
        forceQuit: true,
        locked: [
          LockedApp(
            bundleId: 'com.apple.Notes',
            name: 'Notes',
            path: '/System/Applications/Notes.app',
            armedAt: 1.5,
          ),
        ],
      );
      await backend().writeConfig(draft);
      final onDisk =
          jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
      expect(onDisk['version'], 1);
      expect(onDisk['unlockMinutes'], 30);
      expect(await backend().readConfig(), draft);
    });

    test('refuses a config the agent would not obey', () async {
      final bad = const AppLockConfig(
        unlockMinutes: 0,
        locked: [
          LockedApp(
            bundleId: 'com.apple.finder',
            name: 'Finder',
            path: '/System/Library/CoreServices/Finder.app',
          ),
        ],
      );
      final error = await capture(() => backend().writeConfig(bad));
      expect(error?.code, 'INVALID_CONFIG');
      expect(error?.detail, contains('Finder'));
      expect(configFile.existsSync(), isFalse);
    });

    test(
      'a half-written file falls back rather than showing nothing',
      () async {
        configFile.writeAsStringSync('{"enabled": true, "locked": ');
        expect(await backend().readConfig(), AppLockConfig.defaults);
      },
    );

    test('no file at all is the defaults the agent would use', () async {
      expect(await backend().readConfig(), AppLockConfig.defaults);
    });
  });

  group('the guard verbs', () {
    test('a passphrase goes to stdin and never into argv', () async {
      await backend().setPassphrase('correct horse battery');
      expect(lockd.lastStdin, 'correct horse battery');
      expect(
        lockd.argv.expand((args) => args),
        isNot(contains('correct horse battery')),
        reason: 'ps shows argv to every process on the machine',
      );
    });

    test(
      'a short passphrase is refused before the helper is started',
      () async {
        final error = await capture(() => backend().setPassphrase('abc'));
        expect(error?.code, 'PASSPHRASE_TOO_SHORT');
        expect(lockd.calls, isEmpty);
      },
    );

    test('a wrong passphrase is an answer, not a failure', () async {
      lockd.secretOk = false;
      expect(await backend().verifyPassphrase('wrong but long'), isFalse);
      final allowance = await backend().unlock(
        'com.apple.Notes',
        'wrong but long',
      );
      expect(allowance, isNull);
    });

    test(
      'an unlock offers the window from the saved file, not a guess',
      () async {
        await backend().writeConfig(const AppLockConfig(unlockMinutes: 45));
        final allowance = await backend().unlock(
          'com.apple.Notes',
          'long enough',
        );
        expect(allowance, isNotNull);
        expect(lockd.grants['com.apple.Notes'], 45);
        expect(
          lockd.argv.last,
          containsAllInOrder([
            '--bundle',
            'com.apple.Notes',
            '--minutes',
            '45',
          ]),
        );
      },
    );

    test('close passes --force only when the rule says to insist', () async {
      expect(await backend().closeApp('com.apple.Notes'), isTrue);
      expect(lockd.argv.last, isNot(contains('--force')));
      expect(await backend().closeApp('com.apple.Notes', force: true), isTrue);
      expect(lockd.argv.last, contains('--force'));
    });

    test(
      'the test prompt is bounded, so an unanswered dialog cannot hang',
      () async {
        expect(
          await backend().testPrompt(
            'com.apple.Notes',
            name: 'Notes',
            timeoutSeconds: 20,
          ),
          isTrue,
        );
        expect(
          lockd.argv.last,
          containsAllInOrder([
            '--bundle',
            'com.apple.Notes',
            '--name',
            'Notes',
            '--timeout',
            '20',
          ]),
        );
      },
    );

    test('every verb is pointed at the scratch store', () async {
      await backend().lockStatus();
      expect(lockd.argv.single, containsAllInOrder(['status', '--store']));
    });
  });

  group('the log', () {
    test('having not been written yet is not an error state', () async {
      final error = await capture(() => backend().tailLog().first);
      expect(error?.code, 'LOG_NOT_CREATED');
    });

    test(
      'streams the lines the agent appends, and not the ones before',
      () async {
        final log = File('${scratch.path}/Library/Logs/toolshed-lockd.log')
          ..createSync(recursive: true)
          ..writeAsStringSync('an earlier line, already read\n');
        final seen = backend().tailLog().first;
        // The tail takes its offset at subscription time, so only what lands
        // after that is the agent's news.
        await log.writeAsString(
          'closed Notes\n',
          mode: FileMode.append,
          flush: true,
        );
        expect(await seen, 'closed Notes');
      },
    );
  });

  group('reading the helper', () {
    test('the app list carries the guard reasons through', () async {
      lockd.apps = [
        FakeLockd.app('com.apple.Notes', 'Notes', running: true, locked: true),
        FakeLockd.app(
          'com.apple.finder',
          'Finder',
          running: true,
          lockable: false,
          whyNotLockable: 'closing Finder takes the desktop',
        ),
      ];
      final apps = await backend().installedApps();
      expect(apps, hasLength(2));
      expect(apps.first.pid, 4242);
      expect(apps[1].lockable, isFalse);
      expect(apps[1].whyNotLockable, contains('desktop'));
      expect(apps[1].isGuarded, isTrue);
    });

    test('a helper that exits 0 while saying it failed is a refusal', () async {
      final client = LockAgentClient(
        helperPath: '/fake',
        runner: const _BrokenHelper(),
      );
      final error = await capture(client.installedApps);
      expect(error?.code, 'LOCKD_FAILED');
      expect(error?.message, contains('LaunchServices'));
    });

    test(
      'a reply that is not JSON says so with the line it could not read',
      () async {
        final client = LockAgentClient(
          helperPath: '/fake',
          runner: const _NoiseHelper(),
        );
        final error = await capture(client.installedApps);
        expect(error?.code, 'BAD_REPLY');
        expect(error?.detail, contains('not a reply'));
      },
    );
  });
}

/// Exits 0 and prints `{"ok": false}` — how the helper reports a refusal.
class _BrokenHelper extends ProcessRunner {
  const _BrokenHelper();

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async => const ProcResult(
    'toolshed-lockd',
    0,
    '{"ok": false, "error": "LaunchServices would not answer"}',
    '',
  );
}

class _NoiseHelper extends ProcessRunner {
  const _NoiseHelper();

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async => const ProcResult(
    'toolshed-lockd',
    0,
    'not a reply: swift migration warning on stdout',
    '',
  );
}
