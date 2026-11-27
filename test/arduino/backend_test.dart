import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/arduino/arduino_backend.dart';
import 'package:toolshed/tools/arduino/arduino_config.dart';

class _FakeRunner extends ProcessRunner {
  _FakeRunner(this.answer);

  final ProcResult Function(List<String> arguments) answer;
  final List<List<String>> calls = [];
  final List<List<String>> streams = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    calls.add(arguments);
    return answer(arguments);
  }

  @override
  Stream<String> streamLines(String executable, List<String> arguments) {
    streams.add(arguments);
    return Stream<String>.fromIterable(['ok']);
  }
}

class _OtherConfig implements ToolConfig {
  @override
  List<String> get problems => const [];

  @override
  bool get isValid => problems.isEmpty;

  @override
  String get blurb => 'other';
}

void main() {
  late Directory temp;
  late String cli;
  late Directory book;
  late Directory sketch;
  late File configFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('arduino_backend');
    cli = '${temp.path}/arduino-cli';
    File(cli).writeAsStringSync('#!/bin/sh\n');
    book = Directory('${temp.path}/sketchbook')..createSync();
    sketch = Directory('${book.path}/Blink')..createSync();
    File('${sketch.path}/Blink.ino').writeAsStringSync('void setup() {}');
    configFile = File('${temp.path}/arduino.json');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ArduinoBackend backendWith(_FakeRunner runner) => ArduinoBackend(
    runner: runner,
    cliPath: cli,
    discover: () => cli,
    configFile: configFile,
  );

  ProcResult ok([String out = '']) => ProcResult(cli, 0, out, '');

  ProcResult answer(List<String> args) {
    if (args.length >= 2 && args[0] == 'board' && args[1] == 'listall') {
      return ok(
        jsonEncode({
          'boards': [
            {'name': 'Arduino Uno', 'fqbn': 'arduino:avr:uno'},
          ],
        }),
      );
    }
    if (args.length >= 2 && args[0] == 'board' && args[1] == 'list') {
      return ok(
        jsonEncode([
          {
            'address': '/dev/cu.usbmodem14101',
            'protocol': 'serial',
            'protocol_label': 'Serial Port (USB)',
            'boards': [
              {'name': 'Arduino Uno', 'fqbn': 'arduino:avr:uno'},
            ],
          },
        ]),
      );
    }
    if (args.length >= 2 && args[0] == 'core' && args[1] == 'list') {
      return ok(
        jsonEncode([
          {
            'id': 'arduino:avr',
            'name': 'Arduino AVR Boards',
            'installed': '1.8.6',
            'latest': '1.8.6',
          },
        ]),
      );
    }
    if (args.length == 1 && args[0] == 'version') {
      return ok('arduino-cli  Version: 1.1.1 Commit: abc Date: 2025-01-01');
    }
    if (args.length == 3 && args[0] == 'config' && args[1] == 'get') {
      return ok('${book.path}\n');
    }
    if (args.length >= 2 && args[0] == 'sketch' && args[1] == 'new') {
      final target = args[2];
      final name = target.split(Platform.pathSeparator).last;
      Directory(target).createSync(recursive: true);
      File(
        '$target${Platform.pathSeparator}$name.ino',
      ).writeAsStringSync('void setup() {}');
      return ok('Sketch created in: $target');
    }
    return ok();
  }

  group('capabilities', () {
    test(
      'without a CLI the tool is listed with a reason, not buttons',
      () async {
        final backend = ArduinoBackend(
          cliPath: '${temp.path}/missing',
          discover: () => null,
          configFile: configFile,
        );

        expect(backend.capabilities.support, Support.helperMissing);
        expect(backend.capabilities.actions, isEmpty);
        expect(backend.capabilities.reason, contains('arduino-cli'));

        final status = await backend.status();
        expect(status.state, AgentState.notApplicable);
        expect(status.notes.join(' '), contains('No arduino-cli'));
      },
    );

    test('with a CLI every workbench action is offered', () {
      final backend = backendWith(_FakeRunner(answer));

      expect(backend.capabilities.support, Support.full);
      expect(
        backend.capabilities.actions,
        containsAll(<ToolAction>[
          ToolAction.configure,
          ToolAction.arduinoCompile,
          ToolAction.arduinoUpload,
          ToolAction.arduinoSerial,
          ToolAction.arduinoEdit,
          ToolAction.arduinoNewSketch,
        ]),
      );
    });
  });

  group('inventory', () {
    test('reads ports, boards, cores, version and the sketchbook', () async {
      final runner = _FakeRunner(answer);
      final backend = backendWith(runner);

      final inventory = await backend.inventory();

      expect(inventory.version, '1.1.1');
      expect(inventory.ports.single.address, '/dev/cu.usbmodem14101');
      expect(inventory.ports.single.board?.fqbn, 'arduino:avr:uno');
      expect(inventory.boards.single.name, 'Arduino Uno');
      expect(inventory.cores.single.id, 'arduino:avr');
      expect(inventory.installedCoreCount, 1);
      expect(inventory.sketches.single.name, 'Blink');
      expect(inventory.sketchbookPath, book.path);
      expect(inventory.notes, isEmpty);
      expect(
        runner.calls.map((c) => c.join(' ')),
        containsAll([
          'board list --json',
          'board listall --json',
          'core list --json',
          'version',
          'config get directories.user',
        ]),
      );
    });

    test('a failed port read is the CLI error, not an empty list', () async {
      final runner = _FakeRunner((args) {
        if (args.length >= 2 && args[0] == 'board' && args[1] == 'list') {
          return ProcResult(cli, 1, '', 'Cannot find any board');
        }
        return answer(args);
      });
      final backend = backendWith(runner);

      await expectLater(
        backend.inventory(),
        throwsA(
          isA<ToolException>().having(
            (e) => e.message,
            'message',
            contains('Cannot find any board'),
          ),
        ),
      );
    });

    test(
      'a failed optional read leaves a note instead of blanking the page',
      () async {
        final runner = _FakeRunner((args) {
          if (args.length >= 2 && args[0] == 'board' && args[1] == 'list') {
            return answer(args);
          }
          return ProcResult(cli, 1, '', 'old CLI');
        });
        final backend = backendWith(runner);

        final inventory = await backend.inventory();

        expect(inventory.ports, hasLength(1));
        expect(inventory.boards, isEmpty);
        expect(inventory.cores, isEmpty);
        expect(inventory.notes.length, greaterThanOrEqualTo(3));
      },
    );
  });

  group('commands', () {
    test(
      'compile, upload and monitor use the CLI argv a user would type',
      () async {
        final runner = _FakeRunner(answer);
        final backend = backendWith(runner);
        const config = ArduinoConfig(
          sketchPath: '',
          fqbn: 'arduino:avr:uno',
          port: '/dev/cu.usbmodem14101',
        );
        final selected = config.copyWith(sketchPath: sketch.path);

        await backend.compile(selected).toList();
        await backend.upload(selected).toList();
        await backend.monitor(selected.port, 9600).toList();

        expect(runner.streams, [
          ['compile', '--fqbn', 'arduino:avr:uno', sketch.path],
          [
            'upload',
            '-p',
            '/dev/cu.usbmodem14101',
            '--fqbn',
            'arduino:avr:uno',
            sketch.path,
          ],
          [
            'monitor',
            '-p',
            '/dev/cu.usbmodem14101',
            '--config',
            'baudrate=9600',
          ],
        ]);
      },
    );

    test('an incomplete selection refuses without starting a child', () async {
      final runner = _FakeRunner(answer);
      final backend = backendWith(runner);

      await expectLater(
        backend.compile(const ArduinoConfig()),
        emitsError(isA<ToolException>()),
      );
      await expectLater(
        backend.upload(const ArduinoConfig(fqbn: 'arduino:avr:uno')),
        emitsError(isA<ToolException>()),
      );
      await expectLater(
        backend.monitor('', 9600),
        emitsError(isA<ToolException>()),
      );
      expect(runner.streams, isEmpty);
    });
  });

  group('sketches', () {
    test('creates a sketch in the sketchbook through the CLI', () async {
      final runner = _FakeRunner(answer);
      final backend = backendWith(runner);

      final made = await backend.newSketch('NewBlink');

      expect(made.name, 'NewBlink');
      expect(made.directory, '${book.path}/NewBlink');
      expect(File(made.inoPath).existsSync(), isTrue);
      expect(
        runner.calls.map((c) => c.join(' ')),
        contains('sketch new ${book.path}/NewBlink'),
      );
    });

    test('refuses a name that is a path or already exists', () async {
      final runner = _FakeRunner(answer);
      final backend = backendWith(runner);

      await expectLater(
        backend.newSketch('bad/name'),
        throwsA(isA<ToolException>()),
      );
      await expectLater(
        backend.newSketch('Blink'),
        throwsA(isA<ToolException>()),
      );
      expect(
        runner.calls.any((c) => c.isNotEmpty && c.first == 'sketch'),
        isFalse,
      );
    });

    test('reads and writes the primary .ino', () async {
      final backend = backendWith(_FakeRunner(answer));

      final file = await backend.readSketch(sketch.path);
      expect(file.fileName, 'Blink.ino');
      expect(file.contents, 'void setup() {}');

      await backend.writeSketch(sketch.path, 'void loop() {}');
      expect(
        File('${sketch.path}/Blink.ino').readAsStringSync(),
        'void loop() {}',
      );

      await expectLater(
        backend.readSketch('${temp.path}/missing'),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('settings', () {
    test('round-trips the sketch, board, port and baud', () async {
      final backend = backendWith(_FakeRunner(answer));
      const config = ArduinoConfig(
        sketchPath: '/tmp/Blink',
        fqbn: 'arduino:avr:uno',
        port: '/dev/cu.usbmodem14101',
        baud: 9600,
      );

      await backend.writeConfig(config);

      expect(await backend.readConfig(), config);
      expect(configFile.existsSync(), isTrue);
    });

    test('a corrupt settings file is a readable failure', () async {
      final backend = backendWith(_FakeRunner(answer));
      configFile.writeAsStringSync('{not json');

      await expectLater(
        backend.readConfig(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'BAD_CONFIG'),
        ),
      );
    });

    test('writing another tool\'s settings is refused', () async {
      final backend = backendWith(_FakeRunner(answer));

      await expectLater(
        backend.writeConfig(_OtherConfig()),
        throwsA(isA<ToolException>()),
      );
    });
  });

  test(
    'status names the CLI version and the installed platform count',
    () async {
      final backend = backendWith(_FakeRunner(answer));

      final status = await backend.status();

      expect(status.state, AgentState.notApplicable);
      expect(status.notes.join(' '), contains('1.1.1'));
      expect(status.notes.join(' '), contains('1 board platform(s) installed'));
    },
  );
}
