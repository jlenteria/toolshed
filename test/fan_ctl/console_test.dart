import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/fan_ctl/fan_backend.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';
import 'package:toolshed/tools/fan_ctl/fan_screen.dart';
import 'package:toolshed/tools/registry.dart';

import 'fake_daemon.dart';

/// The real console over a daemon that is a list of requests.
///
/// [MacOSFanBackend] is used rather than a stub so the capabilities the buttons
/// are drawn from are the ones the backend computed. What is fake is the process
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

  /// Cancelling a hold's renewal timer is the point: the widget test verifies
  /// that nothing is still ticking before it runs its own tear-downs.
  bool _disposed = false;

  /// Verbs the daemon was sent after the console finished opening, so a test
  /// counts the taps rather than the reads the screen does by itself.
  List<String> verbsSince(int mark) => [
    for (final request in daemon.received.skip(mark)) request['cmd']! as String,
  ];

  Map<String, Object?> savedPolicy() =>
      Map<String, Object?>.from(jsonDecode(policy.readAsStringSync()) as Map);
}

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

  Future<void> flipSwitch(WidgetTester tester) async {
    await tester.tap(find.byType(Switch));
    await settle(tester);
  }

  testWidgets('the whole tool is one switch and one number', (tester) async {
    await open(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Fan manual ON'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);

    // The control law this console used to ship, and the buttons that carried
    // it. Anything left of them is a control that no longer has anything to do.
    expect(find.text('Take control'), findsNothing);
    expect(find.text('Save only'), findsNothing);
    expect(find.text('Give back now'), findsNothing);
    expect(find.text('Test writes'), findsNothing);
    expect(find.text('WHAT STARTS A HOLD'), findsNothing);
  });

  testWidgets('nothing in the tree reads a temperature', (tester) async {
    await open(tester);
    await flipSwitch(tester);

    // The helper still reports sensors, and the fake feeds them in, because the
    // slider's floor and ceiling come from the fans beside them. Not one of
    // those numbers may reach the screen: this tool does not act on heat.
    expect(find.textContaining('°'), findsNothing);
    expect(find.textContaining('TCMz'), findsNothing);
    expect(find.textContaining('celsius'), findsNothing);
    expect(find.textContaining('CPU package'), findsNothing);
    expect(tester.takeException(), isNull);
    console.dispose();
  });

  testWidgets('the slider spans the range the helper reports', (tester) async {
    await open(tester);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 1199, reason: 'Fan 0 of this Mac idles at 1199 rpm');
    expect(slider.max, 7199);
    expect(find.textContaining('between 1199 and 7199 rpm'), findsOneWidget);
  });

  testWidgets('flipping the switch on issues one apply that says manual', (
    tester,
  ) async {
    await open(tester);
    final mark = console.daemon.received.length;

    await flipSwitch(tester);

    expect(console.verbsSince(mark), contains('apply'));
    final applied = FanPolicy.fromJson(
      console.daemon.applied.first.toJson().cast<String, Object?>(),
    );
    expect(applied.manualOn, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('every fan is being held'), findsOneWidget);
    console.dispose();
  });

  testWidgets('flipping it back off releases the fans and says so on disk', (
    tester,
  ) async {
    await open(tester);
    await flipSwitch(tester);
    final mark = console.daemon.received.length;

    await flipSwitch(tester);

    expect(console.verbsSince(mark), contains('clear'));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(console.savedPolicy()['manualOn'], isFalse);
    expect(find.textContaining('Not holding.'), findsOneWidget);
  });

  testWidgets(
    'moving the number with the switch off saves and touches nothing',
    (tester) async {
      await open(tester);
      final mark = console.daemon.received.length;

      await tester.drag(find.byType(Slider), const Offset(120, 0));
      await settle(tester);

      expect(
        console.verbsSince(mark),
        isNot(anyOf(contains('apply'), contains('clear'))),
        reason: 'a slider behind an off switch reached the hardware',
      );
      expect(
        (console.savedPolicy()['holdRpm'] as num).toDouble(),
        greaterThan(FanPolicy.defaults.holdRpm),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('moving the number while holding re-applies it', (tester) async {
    await open(tester);
    await flipSwitch(tester);
    final mark = console.daemon.received.length;

    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await settle(tester);

    expect(console.verbsSince(mark), contains('apply'));
    expect(
      console.daemon.applied.last.holdRpm,
      greaterThan(FanPolicy.defaults.holdRpm),
    );
    expect(tester.takeException(), isNull);
    console.dispose();
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

  testWidgets('the bar survives a window too narrow for the daemon buttons', (
    tester,
  ) async {
    await open(tester, width: 380);

    // An overflow in a test is an exception rather than a visual problem to be
    // noticed later, and the action row is the one place that packs buttons.
    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Update daemon'), findsOneWidget);
  });
}
