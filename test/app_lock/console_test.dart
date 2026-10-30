import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/app_lock/app_lock_backend.dart';
import 'package:toolshed/tools/app_lock/app_lock_config.dart';
import 'package:toolshed/tools/app_lock/lock_screen.dart';
import 'package:toolshed/tools/registry.dart';

import 'fake_lockd.dart';

/// The App Lock console over a helper that is a list of calls.
///
/// The backend is the real one, so the capability table the buttons are drawn
/// from is the one the tool actually computes; only the process boundary and the
/// three files under a scratch home are pretend.
class Harness {
  Harness({FakeLockd? lockd}) {
    scratch = Directory.systemTemp.createTempSync('toolshed-lock-console');
    configFile = File('${scratch.path}/app_lock.json');
    binary = File('${scratch.path}/toolshed-lockd')
      ..writeAsStringSync('#!/bin/sh\n');
    lock = lockd ?? FakeLockd();
    backend = MacAppLockBackend(
      runner: lock,
      helperPath: binary.path,
      configFile: configFile,
      storeDir: scratch.path,
      homeOverride: scratch.path,
    );
    registry = ToolRegistry.forBackends([backend]);
    surface = MaterialApp(
      home: LockScreen(registry: registry, entry: entry),
    );
  }

  late final Directory scratch;
  late final File configFile;
  late final File binary;
  late final FakeLockd lock;
  late final MacAppLockBackend backend;
  late final ToolRegistry registry;
  late final Widget surface;

  ToolEntry get entry => registry.tools.last;

  /// Puts a lock list on disk, so the console starts from a draft that already
  /// has something in it rather than from the defaults.
  void saveList(AppLockConfig config) {
    configFile.writeAsStringSync(jsonEncode(config.toJson()));
  }

  /// Makes the two files that mean "the agent is installed".
  void makeInstalled() {
    Directory(
      '${scratch.path}/Library/LaunchAgents',
    ).createSync(recursive: true);
    File(
      '${scratch.path}/Library/LaunchAgents/com.bling.toolshed.lockd.plist',
    ).writeAsStringSync('<plist/>');
    final support = Directory(
      '${scratch.path}/Library/Application Support/toolshed',
    )..createSync(recursive: true);
    File('${support.path}/toolshed-lockd').writeAsStringSync('mach-o');
  }

  Future<void> refresh() => registry.refresh(id: 'app_lock');

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }

  bool _disposed = false;
}

Finder badge(String action) => find.byKey(ValueKey('note:$action'));

void main() {
  late Harness harness;

  setUp(() {
    harness = Harness();
    addTearDown(harness.dispose);
  });

  Future<void> open(WidgetTester tester, {double width = 1000}) async {
    tester.view.physicalSize = Size(width, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness.surface);
    await tester.pumpAndSettle();
  }

  /// The same two-zone alternation the fan console test needs: a real file write
  /// only finishes on the outer event loop, while the fake clock that ages the
  /// toast out never advances on its own.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 4; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 15));
  }

  Future<void> typePassphrase(WidgetTester tester, String phrase) async {
    final fields = find.byType(TextField);
    // The three passphrase boxes come first; the app filter is further down.
    await tester.enterText(fields.at(0), phrase);
    await tester.enterText(fields.at(1), phrase);
    await tester.pump();
  }

  testWidgets('says what is watching, and what is missing', (tester) async {
    await open(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('PASSPHRASE · NOT SET'), findsOneWidget);
    expect(find.text('RULES'), findsOneWidget);
    expect(find.text('APPS · 0 LOCKED'), findsOneWidget);
    expect(find.text('Save the lock'), findsOneWidget);
    expect(find.text('Install agent'), findsOneWidget);
    // The gap is stated before anything is promised: no passphrase means the
    // agent would leave every locked app alone.
    expect(find.textContaining('No passphrase is set'), findsWidgets);
    expect(find.byIcon(Icons.info_outline), findsAtLeastNWidgets(4));
  });

  testWidgets('an installed, running agent swaps the offer for a stop', (
    tester,
  ) async {
    harness.makeInstalled();
    harness.lock.watching = true;
    harness.lock.passphrase = true;
    harness.lock.lockedCount = 2;
    await open(tester);

    expect(find.text('Stop agent'), findsOneWidget);
    expect(find.text('Install agent'), findsNothing);
    // The agent runs the binary it bootstrapped with, so an installed lock
    // needs the update button to take a newer helper from the app.
    expect(find.text('Update agent'), findsOneWidget);
    expect(find.text('PASSPHRASE · SET'), findsOneWidget);
    expect(find.textContaining('Locking 2 app(s)'), findsOneWidget);
    expect(find.textContaining('Watcher alive, pid 9021'), findsOneWidget);
  });

  testWidgets('each button carries its explanation behind an info badge', (
    tester,
  ) async {
    await open(tester);

    expect(
      find.textContaining('Sends it to toolshed-lockd on stdin'),
      findsNothing,
    );
    await tester.tap(badge('setpass'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sends it to toolshed-lockd on stdin'),
      findsOneWidget,
    );
    expect(
      find.descendant(of: badge('setpass'), matching: find.byIcon(Icons.info)),
      findsOneWidget,
    );

    // Opening the next note closes the previous one, so the bar never stacks.
    await tester.tap(badge('save'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sends it to toolshed-lockd on stdin'),
      findsNothing,
    );
    expect(find.textContaining('Writes app_lock.json'), findsOneWidget);
  });

  testWidgets('the bar survives a window too narrow for two buttons', (
    tester,
  ) async {
    await open(tester, width: 380);
    expect(tester.takeException(), isNull);
    expect(find.text('Save the lock'), findsOneWidget);
    expect(find.text('Agent log'), findsOneWidget);
  });

  testWidgets('a passphrase is stored, cleared from the fields, and never '
      'printed back', (tester) async {
    await open(tester);
    const phrase = 'a phrase nobody else should find';

    await typePassphrase(tester, phrase);
    await tester.tap(find.text('Save passphrase'));
    await settle(tester);

    expect(harness.lock.lastStdin, phrase);
    expect(
      harness.lock.argv.any((args) => args.contains(phrase)),
      isFalse,
      reason: 'argv is readable by every process on the machine',
    );
    // The fields are empty again, and no widget on the screen holds the words.
    expect(find.text(phrase), findsNothing);
    expect(find.textContaining('not kept anywhere'), findsOneWidget);
    expect(harness.lock.calls, contains('setpass'));
  });

  testWidgets('a too-short phrase is refused without a call to the helper', (
    tester,
  ) async {
    await open(tester);
    final attempts = harness.lock.calls.where((verb) => verb == 'setpass');

    await typePassphrase(tester, 'abc');
    expect(
      find.textContaining('Under 8 characters is decoration'),
      findsWidgets,
    );
    expect(find.text('Save passphrase'), findsOneWidget);
    // Blocked, not merely disabled-and-silent: the reason is on the row.
    await tester.tap(find.text('Save passphrase'));
    await settle(tester);
    expect(attempts, isEmpty);
  });

  testWidgets('checking a wrong phrase answers no, out loud', (tester) async {
    harness.lock.passphrase = true;
    harness.lock.secretOk = false;
    await open(tester);

    await tester.enterText(find.byType(TextField).at(2), 'the wrong long one');
    await tester.pump();
    await tester.tap(find.text('Check it'));
    await settle(tester);

    expect(find.text('That does not match.'), findsOneWidget);
    expect(harness.lock.calls, contains('verify'));
  });

  testWidgets('checking an app writes the list and closes nothing', (
    tester,
  ) async {
    harness.lock.apps = [
      FakeLockd.app('com.apple.Notes', 'Notes'),
      FakeLockd.app('com.apple.Music', 'Music', running: true),
    ];
    await open(tester);

    final row = find.ancestor(
      of: find.text('Notes'),
      matching: find.byType(Container),
    );
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await settle(tester);
    expect(find.text('APPS · 1 LOCKED'), findsOneWidget);

    await tester.tap(find.text('Save the lock'));
    await settle(tester);

    final onDisk =
        jsonDecode(harness.configFile.readAsStringSync())
            as Map<String, Object?>;
    final locked = (onDisk['locked'] as List).cast<Map<String, Object?>>();
    expect(locked.single['bundleId'], 'com.apple.Notes');
    expect(
      harness.lock.calls.where((verb) => verb == 'close'),
      isEmpty,
      reason: 'saving a list is not a command to close anything',
    );
    expect(find.textContaining('Saved'), findsOneWidget);
  });

  testWidgets(
    'an open locked app gets a close button that actually closes it',
    (tester) async {
      harness
        ..saveList(
          const AppLockConfig(
            locked: [
              LockedApp(
                bundleId: 'com.apple.Notes',
                name: 'Notes',
                path: '/System/Applications/Notes.app',
              ),
            ],
          ),
        )
        ..lock.apps = [
          FakeLockd.app(
            'com.apple.Notes',
            'Notes',
            running: true,
            locked: true,
          ),
        ];
      await tester.runAsync(harness.refresh);
      await open(tester);

      expect(find.text('Close all 1 now'), findsOneWidget);
      await tester.tap(find.text('Close all 1 now'));
      await settle(tester);

      expect(harness.lock.closed, ['com.apple.Notes']);
      expect(find.textContaining('Asked 1 of 1'), findsOneWidget);
    },
  );

  testWidgets('the guarded system apps are offered nothing but a reason', (
    tester,
  ) async {
    harness.lock.apps = [
      FakeLockd.app(
        'com.apple.finder',
        'Finder',
        running: true,
        lockable: false,
        whyNotLockable:
            'closing Finder takes the desktop and every window on it',
      ),
    ];
    await open(tester);

    expect(find.textContaining('Never closed by the agent'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).onChanged,
      isNull,
      reason: 'a checkbox the agent would ignore is not a control',
    );
  });

  testWidgets('a filter narrows the list rather than emptying the page', (
    tester,
  ) async {
    harness.lock.apps = [
      FakeLockd.app('com.apple.Notes', 'Notes'),
      FakeLockd.app('com.apple.Music', 'Music'),
    ];
    await open(tester);

    expect(find.text('Notes'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'musi');
    await tester.pump();
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Notes'), findsNothing);
  });

  testWidgets('the refresh button leaves a bar in the body while it reads', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final gate = Completer<void>();
    harness.lock.hold = gate.future;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed,
      isNull,
      reason: 'the list read is the slow half; a second tap would queue it',
    );

    gate.complete();
    await tester.pumpAndSettle();
    harness.lock.hold = null;
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
