import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/fan_ctl/fan_backend.dart';
import 'package:toolshed/tools/fan_ctl/fan_screen.dart';
import 'package:toolshed/tools/registry.dart';

import 'fake_daemon.dart';

/// The real console over a daemon that is a list of requests.
///
/// [MacOSFanBackend] is used rather than a stub so the capabilities it computes
/// are the ones the buttons are drawn from. What is fake is the process
/// boundary and the policy file, the only two things a widget test may touch on
/// the machine it runs on.
class Console {
  Console() {
    scratch = Directory.systemTemp.createTempSync('toolshed-console');
    policy = File('${scratch.path}/fan_policy.json');
    daemon = FakeDaemon();
    backend = MacOSFanBackend(
      runner: daemon,
      helperPath: '/fake/toolshed-fand',
      policyFile: policy,
      socketPath: '/fake.sock',
    );
    final registry = ToolRegistry.forBackends([backend]);
    surface = MaterialApp(
      home: FanScreen(registry: registry, entry: registry.tools.first),
    );
  }

  late final Directory scratch;
  late final File policy;
  late final FakeDaemon daemon;
  late final MacOSFanBackend backend;
  late final Widget surface;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    backend.dispose();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }

  bool _disposed = false;
}

/// The info badge that belongs to one named action, so a test points at the
/// badge it means rather than at any other info icon the window draws.
Finder badge(String action) => find.byKey(ValueKey('note:$action'));

void main() {
  late Console console;

  setUp(() {
    console = Console();
    addTearDown(console.dispose);
  });

  Future<void> open(WidgetTester tester, {double width = 1000}) async {
    tester.view.physicalSize = Size(width, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(console.surface);
    await tester.pumpAndSettle();
  }

  /// A control action writes the policy file, and a file write is real I/O that
  /// only finishes on the outer zone's event loop; the fake clock waits forever
  /// for it. The two zones alternate — real time lets an operation run, a pump
  /// lets the continuation start the next one — and the toast the action answers
  /// with is finally aged out, or the test ends holding a timer nobody asked
  /// for.
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

  testWidgets('groups the policy into what starts, does and ends a hold', (
    tester,
  ) async {
    await open(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('WHAT STARTS A HOLD'), findsOneWidget);
    expect(find.text('WHAT A HOLD DOES'), findsOneWidget);
    expect(find.text('WHAT ENDS IT'), findsOneWidget);
    // The fan the read reported, not a placeholder: the console is only worth
    // its numbers if they came from the helper.
    expect(find.textContaining('Fan 0'), findsWidgets);
    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Give back now'), findsOneWidget);
    expect(find.text('Save only'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsAtLeastNWidgets(3));
  });

  testWidgets('each button carries its explanation behind an info badge', (
    tester,
  ) async {
    await open(tester);

    expect(
      find.textContaining('The only button here that touches the fan'),
      findsNothing,
    );

    await tester.tap(badge('engage'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The only button here that touches the fan'),
      findsOneWidget,
    );
    // The open badge fills in, so it is obvious which control is speaking.
    expect(
      find.descendant(of: badge('engage'), matching: find.byIcon(Icons.info)),
      findsOneWidget,
    );

    // Reading the next one closes the previous, so the bar never stacks notes
    // and shifts its own buttons out from under the reader.
    await tester.tap(badge('save'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The only button here that touches the fan'),
      findsNothing,
    );
    expect(
      find.textContaining('Writes these numbers to disk and sends nothing'),
      findsOneWidget,
    );

    await tester.tap(badge('save'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.info), findsNothing);
  });

  testWidgets('the refresh button leaves a bar in the body while it reads', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final gate = Completer<void>();
    console.daemon.hold = gate.future;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed,
      isNull,
      reason: 'a second tap on a read in flight would only queue another one',
    );

    gate.complete();
    await tester.pumpAndSettle();
    console.daemon.hold = null;
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('the bar survives a window too narrow for two buttons', (
    tester,
  ) async {
    await open(tester, width: 380);

    // An overflow in a test is an exception rather than a visual problem to be
    // noticed later, and the action bar is the one row that packs two buttons.
    expect(tester.takeException(), isNull);
    expect(find.text('Give back now'), findsOneWidget);
    expect(find.text('Save only'), findsOneWidget);
  });

  testWidgets('Save only writes the file and sends no verb that moves a fan', (
    tester,
  ) async {
    await open(tester);
    // Opening the console reads the machine, so the test counts the verbs after
    // the tap rather than the whole conversation.
    final opened = console.daemon.cmds.length;

    await tester.tap(find.text('Save only'));
    await settle(tester);

    expect(
      console.daemon.cmds.sublist(opened),
      isNot(anyOf(contains('apply'), contains('clear'))),
      reason: 'a save reached the hardware',
    );
    expect(console.policy.existsSync(), isTrue);
    expect(
      jsonDecode(console.policy.readAsStringSync()),
      containsPair('targetTempC', 70.0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Take control answers with an apply, or with the reason it can\'t',
    (tester) async {
      await open(tester);
      final opened = console.daemon.cmds.length;

      final control = find.widgetWithIcon(FilledButton, Icons.air);
      if (tester.widget<FilledButton>(control).onPressed == null) {
        // On a machine without the root daemon the button is dead, and the console
        // has to say why beside itself rather than let the tap go nowhere.
        expect(find.textContaining('needs the root daemon'), findsOneWidget);
        return;
      }
      await tester.tap(control);
      await settle(tester);

      expect(console.daemon.cmds.sublist(opened), contains('apply'));
      console.dispose();
    },
  );
}
