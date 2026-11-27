import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/arduino/arduino_models.dart';
import 'package:toolshed/tools/arduino/arduino_parsers.dart';

void main() {
  group('board list', () {
    test('reads the pre-0.19 shape', () {
      final parsed = parseBoardList(
        jsonEncode([
          {
            'address': '/dev/cu.usbmodem14101',
            'protocol': 'serial',
            'protocol_label': 'Serial Port (USB)',
            'boards': [
              {'name': 'Arduino Uno', 'fqbn': 'arduino:avr:uno'},
            ],
          },
          {
            'address': '/dev/cu.usbserial-0001',
            'protocol': 'serial',
            'protocol_label': 'Serial Port',
            'boards': <Object?>[],
          },
        ]),
      );

      expect(parsed.partial, isNull);
      expect(parsed.ports, hasLength(2));
      expect(parsed.ports.first.address, '/dev/cu.usbmodem14101');
      expect(parsed.ports.first.board?.name, 'Arduino Uno');
      expect(parsed.ports.first.board?.fqbn, 'arduino:avr:uno');
      expect(parsed.ports.first.title, 'Arduino Uno · /dev/cu.usbmodem14101');
      expect(parsed.ports.last.boards, isEmpty);
      expect(parsed.ports.last.title, '/dev/cu.usbserial-0001');
    });

    test('reads the current port/matching_boards shape', () {
      final parsed = parseBoardList(
        jsonEncode([
          {
            'matching_boards': [
              {'name': 'Arduino Nano', 'fqbn': 'arduino:avr:nano'},
            ],
            'port': {
              'address': '/dev/ttyACM0',
              'label': 'ttyACM0',
              'protocol': 'serial',
              'protocol_label': 'Serial Port (USB)',
            },
          },
        ]),
      );

      expect(parsed.partial, isNull);
      expect(parsed.ports, hasLength(1));
      expect(parsed.ports.single.address, '/dev/ttyACM0');
      expect(parsed.ports.single.label, 'ttyACM0');
      expect(parsed.ports.single.protocolLabel, 'Serial Port (USB)');
      expect(parsed.ports.single.board?.fqbn, 'arduino:avr:nano');
    });

    test('reads the detected_ports wrapper', () {
      final parsed = parseBoardList(
        jsonEncode({
          'detected_ports': [
            {
              'port': {'address': 'COM3', 'protocol': 'serial'},
              'matching_boards': [
                {'name': 'Arduino Mega', 'fqbn': 'arduino:avr:mega'},
              ],
            },
          ],
        }),
      );

      expect(parsed.partial, isNull);
      expect(parsed.ports.single.address, 'COM3');
      expect(parsed.ports.single.board?.name, 'Arduino Mega');
    });

    test('a malformed answer is a note, not an empty success', () {
      final parsed = parseBoardList('not json at all');

      expect(parsed.ports, isEmpty);
      expect(parsed.partial, contains('valid JSON'));
    });

    test('skips a warning printed before the JSON', () {
      final parsed = parseBoardList(
        'Warning: something noisy\n'
        '[{"address":"/dev/ttyUSB0","protocol":"serial"}]',
      );

      expect(parsed.partial, isNull);
      expect(parsed.ports.single.address, '/dev/ttyUSB0');
    });

    test('an entry with no address is reported, not silently dropped', () {
      final parsed = parseBoardList(
        jsonEncode([
          {'protocol': 'serial'},
          {'address': '/dev/ttyUSB0'},
        ]),
      );

      expect(parsed.ports, hasLength(1));
      expect(parsed.partial, contains('no address'));
    });
  });

  group('board listall', () {
    test('reads the boards wrapper, de-duplicates and sorts', () {
      final parsed = parseAllBoards(
        jsonEncode({
          'boards': [
            {'name': 'Arduino Uno', 'fqbn': 'arduino:avr:uno'},
            {'name': 'Arduino Nano', 'fqbn': 'arduino:avr:nano'},
            {'name': 'Arduino Uno', 'fqbn': 'arduino:avr:uno'},
          ],
        }),
      );

      expect(parsed.partial, isNull);
      expect(parsed.boards.map((b) => b.fqbn), [
        'arduino:avr:nano',
        'arduino:avr:uno',
      ]);
    });

    test('reads a top-level list', () {
      final parsed = parseAllBoards(
        jsonEncode([
          {'name': 'Raspberry Pi Pico', 'fqbn': 'rp2040:rp2040:rpipico'},
        ]),
      );

      expect(parsed.boards.single.name, 'Raspberry Pi Pico');
    });
  });

  group('core list', () {
    test('reads the lowercased keys', () {
      final parsed = parseCores(
        jsonEncode([
          {
            'id': 'arduino:avr',
            'name': 'Arduino AVR Boards',
            'installed': '1.8.6',
            'latest': '1.8.6',
          },
        ]),
      );

      expect(parsed.partial, isNull);
      expect(parsed.cores.single.isInstalled, isTrue);
      expect(parsed.cores.single.label, 'Arduino AVR Boards 1.8.6');
    });

    test('reads the older uppercased keys', () {
      final parsed = parseCores(
        jsonEncode([
          {
            'ID': 'esp32:esp32',
            'Name': 'ESP32',
            'Installed': '3.0.0',
            'Latest': '3.1.0',
          },
        ]),
      );

      expect(parsed.cores.single.id, 'esp32:esp32');
      expect(parsed.cores.single.installed, '3.0.0');
      expect(parsed.cores.single.subtitle, contains('latest 3.1.0'));
    });

    test('reads a cores wrapper', () {
      final parsed = parseCores(
        jsonEncode({
          'cores': [
            {'id': 'arduino:avr', 'installed': '1.8.6'},
          ],
        }),
      );

      expect(parsed.cores.single.id, 'arduino:avr');
    });
  });

  group('version and sketchbook', () {
    test('takes the version out of the version line', () {
      expect(
        parseVersion(
          'arduino-cli  Version: 1.1.1 Commit: abcdef Date: 2025-01-01',
        ),
        '1.1.1',
      );
      expect(parseVersion('arduino-cli 0.35.3'), '0.35.3');
      expect(parseVersion(''), '');
    });

    test('reads a bare path or a keyed path', () {
      expect(
        parseSketchbookPath('/Users/me/Documents/Arduino\n'),
        '/Users/me/Documents/Arduino',
      );
      expect(
        parseSketchbookPath('directories.user: /Users/me/Arduino\n'),
        '/Users/me/Arduino',
      );
      expect(
        parseSketchbookPath(r'C:\Users\me\Documents\Arduino'),
        r'C:\Users\me\Documents\Arduino',
      );
      expect(parseSketchbookPath('Error: no config'), '');
    });
  });

  group('the sketchbook', () {
    late Directory book;

    setUp(() {
      book = Directory.systemTemp.createTempSync('arduino_book');
    });

    tearDown(() {
      if (book.existsSync()) book.deleteSync(recursive: true);
    });

    test('lists folders with a .ino, skips empty and hidden ones', () {
      Directory('${book.path}/Blink').createSync();
      File('${book.path}/Blink/Blink.ino').writeAsStringSync('void setup() {}');
      Directory('${book.path}/Other').createSync();
      File('${book.path}/Other/main.ino').writeAsStringSync('void loop() {}');
      Directory('${book.path}/Empty').createSync();
      Directory('${book.path}/.hidden').createSync();
      File('${book.path}/.hidden/.hidden.ino').writeAsStringSync('');

      final sketches = scanSketchbook(book);

      expect(sketches.map((s) => s.name), ['Blink', 'Other']);
      expect(sketches.first.inoPath, endsWith('Blink.ino'));
      expect(sketches.last.inoPath, endsWith('main.ino'));
    });

    test('a missing sketchbook is empty, not an error', () {
      expect(scanSketchbook(Directory('${book.path}/nope')), isEmpty);
    });

    test('resolves a folder, its .ino, and a fallback .ino', () {
      Directory('${book.path}/Blink').createSync();
      final ino = File('${book.path}/Blink/Blink.ino')
        ..writeAsStringSync('void setup() {}');
      Directory('${book.path}/Other').createSync();
      File('${book.path}/Other/main.ino').writeAsStringSync('void loop() {}');

      expect(resolveSketch('${book.path}/Blink')?.inoPath, ino.path);
      expect(resolveSketch(ino.path)?.directory, '${book.path}/Blink');
      expect(
        resolveSketch('${book.path}/Other')?.inoPath,
        endsWith('main.ino'),
      );
      expect(resolveSketch('${book.path}/nope'), isNull);
      expect(resolveSketch(''), isNull);
    });
  });

  test('a port with several boards says so in its subtitle', () {
    const port = ArduinoPort(
      address: '/dev/ttyUSB0',
      protocolLabel: 'Serial Port',
      boards: [
        ArduinoBoard(name: 'Uno', fqbn: 'arduino:avr:uno'),
        ArduinoBoard(name: 'Nano', fqbn: 'arduino:avr:nano'),
      ],
    );

    expect(port.subtitle, contains('2 matching boards'));
    expect(port.matches('nano'), isTrue);
  });
}
