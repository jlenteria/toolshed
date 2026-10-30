@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/app_lock/lock_agent.dart';

/// The Dart client against the Swift helper, in a scratch store.
///
/// These are the tests that say the two halves actually agree on a word:
/// `fake_lockd.dart` is what the Dart side believes the protocol is, and only
/// the real binary can say whether it is. Everything runs with `--store` at a
/// temporary directory, so no lock list, hash or allowance of the user's is
/// read or written, and no verb that puts a window on the screen is called —
/// `prompt` is the one command that needs someone at the keyboard, and
/// `console_test.dart` covers the button that reaches it.
void main() {
  final binary = _helperBinary();
  late Directory scratch;
  late LockAgentClient client;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('toolshed-lockd-proto');
    client = LockAgentClient(
      helperPath: binary ?? '/absent/toolshed-lockd',
      storeDir: scratch.path,
    );
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  if (binary == null) {
    test('protocol tests need the helper', () {}, skip: true);
    return;
  }

  /// Past the guard above the binary exists, and a local naming it is a `String`
  /// the closures below can use without asserting.
  final helper = binary;

  group('the helper answers', () {
    test('selfcheck passes its own decision table', () async {
      final result = await const ProcessRunner().run(binary, [
        'selfcheck',
        '--store',
        scratch.path,
      ]);
      expect(result.exitCode, 0, reason: result.blurb);
      expect(result.stdout, contains('all checks passed'));
    });

    test('a fresh store has nothing set and nothing locked', () async {
      final info = await client.status();
      final uid = int.parse(
        (await const ProcessRunner().run('id', ['-u'])).stdout.trim(),
      );
      expect(info.watching, isFalse);
      expect(info.watchPid, 0);
      expect(info.passphraseSet, isFalse);
      expect(info.lockedCount, 0);
      expect(info.configPresent, isFalse);
      expect(info.events, isEmpty);
      expect(info.uid, uid);
      expect(info.store, scratch.path);
    });

    test('the app list is apps, with a bundle id on every one', () async {
      final apps = await client.installedApps();
      expect(apps, isNotEmpty);
      expect(
        apps.every((app) => app.bundleId.isNotEmpty),
        isTrue,
        reason: 'an entry the agent cannot name is an entry it cannot close',
      );
      final ids = apps.map((app) => app.bundleId).toSet();
      // The guard list is not offered at all: the agent never closes Finder,
      // the Dock, the menu bar, the session or toolshed, so listing them would
      // be checkboxes it refuses to honour.
      for (final guarded in [
        'com.apple.finder',
        'com.apple.dock',
        'com.apple.controlcenter',
        'com.apple.SystemUIServer',
        'com.apple.loginwindow',
        'com.bling.toolshed',
      ]) {
        expect(
          ids,
          isNot(contains(guarded)),
          reason: '$guarded is never closed',
        );
      }
      // Background services are not desktop apps, so they are not candidates.
      expect(ids, isNot(contains('com.apple.AccessibilityUIServer')));
      expect(
        apps.every((app) => app.lockable),
        isTrue,
        reason: 'everything left on the list is something the agent can close',
      );
    });
  });

  group('the passphrase', () {
    test('is stored as a salted hash and never as itself', () async {
      const phrase = 'a passphrase that must not be on disk';
      await client.setPassphrase(phrase);
      expect(await client.hasPassphrase(), isTrue);

      final secret = File('${scratch.path}/app_lock_secret.json');
      expect(secret.existsSync(), isTrue);
      final text = secret.readAsStringSync();
      expect(text, isNot(contains(phrase)));
      final json = jsonDecode(text) as Map<String, Object?>;
      expect(
        json.keys,
        containsAll(['saltHex', 'hashHex', 'iterations', 'kdf']),
      );
      expect('${json['saltHex']}', matches(RegExp(r'^[0-9a-f]{16,}$')));
      expect('${json['hashHex']}', matches(RegExp(r'^[0-9a-f]{32,}$')));
      expect(json['iterations'], greaterThan(0));
      expect(
        (await client.status()).iterations,
        json['iterations'],
        reason: 'the console quotes the file, not a constant it kept itself',
      );

      // 0600 — read and write for the owner only. A hash anyone on the machine
      // can read is a hash anyone on the machine can try offline.
      expect(secret.statSync().mode & 0x1FF, 0x180);
    });

    test('verify says yes to the phrase and no to another one', () async {
      await client.setPassphrase('the right long phrase');
      expect(await client.verifyPassphrase('the right long phrase'), isTrue);
      expect(await client.verifyPassphrase('the wrong long phrase'), isFalse);
    });

    test('a short phrase is refused before the helper is asked', () async {
      await expectLater(
        client.setPassphrase('abc'),
        throwsA(
          isA<ToolException>().having(
            (e) => e.code,
            'code',
            'PASSPHRASE_TOO_SHORT',
          ),
        ),
      );
      expect(
        File('${scratch.path}/app_lock_secret.json').existsSync(),
        isFalse,
      );
    });
  });

  group('a window on one app', () {
    test(
      'is granted for the minutes asked for, and can be ended early',
      () async {
        await client.setPassphrase('long enough to be a phrase');
        final bundle = 'com.example.NotAThing';

        final wrong = await client.grant(bundle, 'not the phrase');
        expect(wrong, isNull);

        final grant = await client.grant(
          bundle,
          'long enough to be a phrase',
          minutes: 12,
        );
        expect(grant, isNotNull);
        expect(
          grant!.expiresAt,
          greaterThan(DateTime.now().millisecondsSinceEpoch / 1000.0),
        );
        expect(
          grant.remaining(DateTime.now()),
          lessThanOrEqualTo(const Duration(minutes: 12)),
        );

        final info = await client.status();
        expect(info.unlocks.map((u) => u.bundleId), contains(bundle));

        await client.revoke(bundle);
        final after = await client.status();
        expect(after.unlocks.map((u) => u.bundleId), isNot(contains(bundle)));
      },
    );

    test(
      'closing an app that is not running is an answer, not a failure',
      () async {
        expect(await client.closeNow('com.example.NotAThing'), isFalse);
      },
    );

    test('a grant with no bundle named is refused here, not there', () async {
      await expectLater(
        client.grant('  ', 'long enough to be a phrase'),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('the state file', () {
    test('records what the helper did, including a wrong guess', () async {
      await client.setPassphrase('long enough to be a phrase');
      await client.grant('com.example.NotAThing', 'nope nope nope');
      final events = (await client.status()).events;
      expect(events, isNotEmpty);
      expect(events.map((e) => e.action), contains('refused'));
      expect(events.last.detail, 'wrong passphrase');
      expect(events.last.time.isAfter(DateTime(2020)), isTrue);
    });
  });

  group('the watcher it reports', () {
    /// The answer a lock console is built on: "is anything enforcing this list
    /// right now". A process-table scan alone got this wrong for a scratch
    /// store — it reported the machine's agent as though it were watching a
    /// directory it had never been pointed at — so the pid belongs to the store
    /// and the table only checks that the pid is still what it claims.
    ///
    /// The tests below never depend on whether this machine has an agent
    /// installed, which is the point of writing them against a scratch store.
    test('is not a number in a file, once that process is gone', () async {
      final state = File('${scratch.path}/app_lock_state.json');

      // A live pid that is not a watcher (launchd) and a pid no process holds.
      for (final claimed in [1, 999999]) {
        state.writeAsStringSync(
          jsonEncode({'updatedAt': 0, 'watchPid': claimed}),
        );
        final info = await client.status();
        expect(info.watching, isFalse, reason: 'pid $claimed is not watching');
        expect(info.watchPid, 0);
      }
    });

    test('is a watcher running against this very store', () async {
      final watcher = await Process.start(helper, [
        'watch',
        '--store',
        scratch.path,
      ]);
      watcher.stdout.drain<void>();
      watcher.stderr.drain<void>();
      addTearDown(() {
        try {
          watcher.kill(ProcessSignal.sigkill);
        } on Object {
          // Already gone.
        }
      });

      var info = await client.status();
      for (var attempt = 0; attempt < 25 && !info.watching; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        info = await client.status();
      }
      expect(info.watching, isTrue, reason: 'the watcher never named itself');
      expect(info.watchPid, watcher.pid);

      // And it is nobody else's watcher: the default store may not claim a
      // process that was pointed away from it.
      final elsewhere = await const ProcessRunner().run(helper, ['status']);
      final claimed =
          ((jsonDecode(elsewhere.stdout) as Map)['status'] as Map)['watchPid'];
      expect(claimed, isNot(watcher.pid));
    });
  });
}

String? _helperBinary() {
  for (final candidate in [
    'build/lockd/toolshed-lockd',
    '${Directory.current.path}/build/lockd/toolshed-lockd',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}
