import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/platform/paths.dart';

/// Where an app finds its helpers.
///
/// The property under test is one sentence: an installed `toolshed.app` works on
/// the machine it is installed on. Everything before the bundle lookup was
/// written for a developer's checkout, and a console that quietly depends on
/// `~/Project/toolshed/build/...` is one that stops working for everyone else —
/// with no error, because the button was enabled a moment ago.
void main() {
  late Directory temp;
  late String bundle;
  late String exe;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('toolshed_paths');
    bundle = '${temp.path}/toolshed.app';
    Directory('$bundle/Contents/MacOS').createSync(recursive: true);
    Directory('$bundle/Contents/Resources').createSync();
    exe = '$bundle/Contents/MacOS/toolshed';
    File(exe).createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  group('the bundle', () {
    test('is where an app that is installed finds its own helper', () {
      expect(
        Paths.bundleResources(executable: exe),
        '$bundle/Contents/Resources',
      );
    });

    test('is nothing when the code is not inside one', () {
      expect(
        Paths.bundleResources(executable: '/usr/local/bin/toolshed-lockd'),
        isNull,
      );
      expect(Paths.bundleResources(executable: 'build/toolshed'), isNull);
    });

    test('is not a bundle without its Resources', () {
      Directory('$bundle/Contents/Resources').deleteSync();
      expect(Paths.bundleResources(executable: exe), isNull);
    });

    test('answers only for a binary that is really in there', () {
      expect(Paths.bundled('toolshed-lockd', executable: exe), isNull);
      File('$bundle/Contents/Resources/toolshed-lockd').createSync();
      expect(
        Paths.bundled('toolshed-lockd', executable: exe),
        '$bundle/Contents/Resources/toolshed-lockd',
      );
    });
  });

  group('the candidate lists', () {
    test('put the bundle copy ahead of any checkout', () {
      File('$bundle/Contents/Resources/toolshed-lockd').createSync();
      File('$bundle/Contents/Resources/toolshed-fand').createSync();
      final lock = Paths.lockHelperCandidates(executable: exe);
      final fan = Paths.fandCandidates(executable: exe);

      expect(
        lock.indexOf('$bundle/Contents/Resources/toolshed-lockd'),
        lessThan(
          lock.indexOf(
            '${Paths.home}/Project/toolshed/build/lockd/toolshed-lockd',
          ),
        ),
      );
      expect(
        fan.indexOf('$bundle/Contents/Resources/toolshed-fand'),
        lessThan(
          fan.indexOf(
            '${Paths.home}/Project/toolshed/build/fanctl/toolshed-fand',
          ),
        ),
      );
    });

    test('read the enforcing copy, install the app copy', () {
      // Two different orders on purpose. Status must be answered by the binary
      // that is enforcing, or the console interprets a protocol it did not ask
      // for. An install must be sourced from the app, or updating toolshed
      // reinstalls the helper the last update left behind and an agent can never
      // be brought forward by the app that manages it.
      File('$bundle/Contents/Resources/toolshed-lockd').createSync();
      File('$bundle/Contents/Resources/toolshed-fand').createSync();

      expect(
        Paths.lockInstallCandidates(executable: exe).first,
        '$bundle/Contents/Resources/toolshed-lockd',
      );
      expect(
        Paths.lockInstallCandidates(executable: exe)[1],
        Paths.lockAgentBinary,
      );
      expect(
        Paths.fanInstallCandidates(executable: exe).first,
        '$bundle/Contents/Resources/toolshed-fand',
      );
      expect(
        Paths.fanInstallCandidates(executable: exe)[1],
        '/usr/local/bin/toolshed-fand',
      );
    });

    test('still let what is enforcing speak for itself', () {
      // The agent's own copy is first for the lock and the daemon's for the fan:
      // the console must interpret a reply with the same protocol version that
      // produced it, which a newer bundle copy would not guarantee.
      expect(
        Paths.lockHelperCandidates(executable: exe).first,
        Paths.lockAgentBinary,
      );
      expect(
        Paths.fandCandidates(executable: exe).first,
        '/usr/local/bin/toolshed-fand',
      );
    });

    test('a helper is resolved from the bundle when nothing is installed', () {
      File('$bundle/Contents/Resources/toolshed-lockd').createSync();
      final installed = File(Paths.lockAgentBinary).existsSync();
      expect(
        Paths.lockHelperPath(executable: exe),
        installed
            ? Paths.lockAgentBinary
            : '$bundle/Contents/Resources/toolshed-lockd',
      );
    });
  });

  group('the child PATH', () {
    final separator = Platform.isWindows ? ';' : ':';
    List<String> dirs(String path) =>
        path.split(separator).where((d) => d.isNotEmpty).toList();

    test('keeps every inherited entry and puts it ahead of the fallbacks', () {
      // subprocessPath de-dupes, so compare against the inherited dirs in
      // first-seen order, not the raw PATH (which repeats entries).
      final inherited = dirs(
        Platform.environment['PATH'] ?? '',
      ).toSet().toList();
      final handed = dirs(Paths.subprocessPath);
      // Nothing the user already had is dropped or reordered.
      expect(handed.length, greaterThanOrEqualTo(inherited.length));
      expect(handed.sublist(0, inherited.length), inherited);
    });

    test('adds the well-known bin dirs a Dock launch strips', () {
      final handed = dirs(Paths.subprocessPath);
      if (Platform.isMacOS) {
        expect(handed, contains('/opt/homebrew/bin'));
      } else if (Platform.isLinux) {
        expect(handed, contains('/usr/local/bin'));
      }
    });

    test('never repeats a directory', () {
      final handed = dirs(Paths.subprocessPath);
      expect(handed.toSet().length, handed.length);
    });
  });
}
