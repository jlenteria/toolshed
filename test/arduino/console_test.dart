import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/tools/arduino/arduino_backend.dart';
import 'package:toolshed/tools/arduino/arduino_config.dart';
import 'package:toolshed/tools/arduino/arduino_models.dart';
import 'package:toolshed/tools/arduino/arduino_screen.dart';
import 'package:toolshed/tools/arduino/arduino_serial_screen.dart';
import 'package:toolshed/tools/arduino/arduino_sketch_screen.dart';
import 'package:toolshed/tools/registry.dart';
import 'package:toolshed/tools/tool_backend.dart';

/// An in-memory workbench, so a widget test is about the screen and not about
/// the real file system. The backend itself is covered by backend_test.dart,
/// where real I/O is not competing with a fake async clock.
class _FakeBackend implements ToolBackend, ArduinoWorkbench {
  _FakeBackend({this.supported = true});

  final bool supported;
  ArduinoConfig config = const ArduinoConfig();
  String file = 'void setup() {}';
  final List<List<String>> compileCalls = [];
  final List<String> monitorCalls = [];

  static const _sketch = ArduinoSketch(
    name: 'Blink',
    directory: '/tmp/Arduino/Blink',
    inoPath: '/tmp/Arduino/Blink/Blink.ino',
  );

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kArduinoId,
    name: 'Arduino Bench',
    summary: 'A lightweight Arduino IDE.',
    implPath: 'arduino-cli',
  );

  @override
  Capabilities get capabilities => supported
      ? const Capabilities(
          support: Support.full,
          actions: <ToolAction>{
            ToolAction.configure,
            ToolAction.arduinoCompile,
            ToolAction.arduinoUpload,
            ToolAction.arduinoSerial,
            ToolAction.arduinoEdit,
            ToolAction.arduinoNewSketch,
          },
          reason: 'Driven by arduino-cli.',
        )
      : const Capabilities(
          support: Support.helperMissing,
          actions: <ToolAction>{},
          reason: 'No arduino-cli was found.',
        );

  @override
  Future<AgentStatus> status() async => const AgentStatus.notApplicable();

  @override
  Future<ToolConfig> readConfig() async => config;

  @override
  Future<void> writeConfig(ToolConfig next) async {
    config = expectConfig<ArduinoConfig>(next, 'Arduino');
  }

  @override
  Future<ArduinoInventory> inventory() async => const ArduinoInventory(
    version: '1.1.1',
    ports: [
      ArduinoPort(
        address: '/dev/cu.usbmodem14101',
        protocol: 'serial',
        protocolLabel: 'Serial Port (USB)',
        boards: [ArduinoBoard(name: 'Arduino Uno', fqbn: 'arduino:avr:uno')],
      ),
    ],
    boards: [ArduinoBoard(name: 'Arduino Uno', fqbn: 'arduino:avr:uno')],
    cores: [
      ArduinoCore(
        id: 'arduino:avr',
        name: 'Arduino AVR Boards',
        installed: '1.8.6',
        latest: '1.8.6',
      ),
    ],
    sketches: [_sketch],
    sketchbookPath: '/tmp/Arduino',
  );

  @override
  Future<ArduinoSketch> newSketch(String name) async => _sketch;

  @override
  Future<ArduinoSketchFile> readSketch(String path) async =>
      ArduinoSketchFile(path: _sketch.inoPath, contents: file);

  @override
  Future<void> writeSketch(String path, String contents) async {
    file = contents;
  }

  @override
  Stream<String> compile(ArduinoConfig config) {
    compileCalls.add(['compile', '--fqbn', config.fqbn, config.sketchPath]);
    return Stream<String>.fromIterable([
      'Sketch uses 924 bytes (2%) of program storage space.',
    ]);
  }

  @override
  Stream<String> upload(ArduinoConfig config) => const Stream<String>.empty();

  @override
  Stream<String> monitor(String port, int baud) {
    monitorCalls.add('$port@$baud');
    return Stream<String>.fromIterable(['hello from the board']);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> install() async {}

  @override
  Future<void> uninstall() async {}

  @override
  Stream<String> tailLog() => const Stream<String>.empty();
}

void main() {
  (ToolRegistry, ToolEntry) harness(ToolBackend backend) {
    final registry = ToolRegistry.forBackends([backend]);
    return (registry, registry.byId(kArduinoId)!);
  }

  testWidgets(
    'without a CLI the screen explains itself and shows no controls',
    (tester) async {
      final (registry, entry) = harness(_FakeBackend(supported: false));

      await tester.pumpWidget(
        MaterialApp(
          home: ArduinoScreen(registry: registry, entry: entry),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Arduino CLI is not available here'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Compile'), findsNothing);
    },
  );

  testWidgets('shows the detected target and streams a compile', (
    tester,
  ) async {
    final backend = _FakeBackend();
    final (registry, entry) = harness(backend);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ArduinoScreen(registry: registry, entry: entry),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blink'), findsWidgets);
    expect(find.text('Arduino Uno'), findsWidgets);
    expect(find.textContaining('/dev/cu.usbmodem14101'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Compile'));
    await tester.pumpAndSettle();

    expect(backend.compileCalls, hasLength(1));
    expect(backend.compileCalls.single, [
      'compile',
      '--fqbn',
      'arduino:avr:uno',
      '/tmp/Arduino/Blink',
    ]);
    expect(
      find.text('Sketch uses 924 bytes (2%) of program storage space.'),
      findsOneWidget,
    );
  });

  testWidgets('follows the selected port in the serial monitor', (
    tester,
  ) async {
    final backend = _FakeBackend();
    final (registry, _) = harness(backend);

    await tester.pumpWidget(
      MaterialApp(
        home: ArduinoSerialScreen(
          registry: registry,
          toolId: kArduinoId,
          port: '/dev/cu.usbmodem14101',
          baud: 115200,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello from the board'), findsOneWidget);
    expect(backend.monitorCalls, ['/dev/cu.usbmodem14101@115200']);
  });

  testWidgets('opens the primary .ino and saves it back', (tester) async {
    final backend = _FakeBackend();
    final (registry, _) = harness(backend);

    await tester.pumpWidget(
      MaterialApp(
        home: ArduinoSketchScreen(
          registry: registry,
          toolId: kArduinoId,
          sketchPath: '/tmp/Arduino/Blink',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'void setup() {}');

    await tester.enterText(find.byType(TextField), 'void loop() {}');
    await tester.pump();
    await tester.tap(find.byTooltip('Save the sketch'));
    await tester.pumpAndSettle();

    expect(backend.file, 'void loop() {}');
  });
}
