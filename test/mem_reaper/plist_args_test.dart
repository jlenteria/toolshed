import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/tools/mem_reaper/macos_backend.dart';
import 'package:toolshed/tools/mem_reaper/mem_reaper_config.dart';
import 'package:toolshed/tools/mem_reaper/plist_args.dart';

/// The argv list is `plutil -convert json -o -` of the real
/// ~/Library/LaunchAgents/com.bling.memreaper.plist on this machine, so the
/// flag positions below are the ones the app has to survive.
void main() {
  late List<String> argv;

  setUpAll(() {
    final plist =
        jsonDecode(File('test/fixtures/plist.json').readAsStringSync())
            as Map<String, dynamic>;
    argv = (plist['ProgramArguments'] as List).map((e) => '$e').toList();
  });

  test('the live agent has the shape the rest of these tests assume', () {
    expect(argv, [
      '/usr/bin/python3',
      '/Users/jlenteria/Project/mem_reaper.py',
      '--service',
      '--threshold-mb',
      '3072',
      '--interval',
      '30',
      '--dialog-timeout',
      '45',
    ]);
  });

  test('a flag value is found by position, not by hardcoding index 4', () {
    final args = PlistArgs(argv);
    expect(args.valueIndex('--threshold-mb'), 4);
    expect(args.valueIndex('--interval'), 6);
    expect(args.valueIndex('--dialog-timeout'), 8);
    expect(args.interpreter, '/usr/bin/python3');
    expect(args.script, '/Users/jlenteria/Project/mem_reaper.py');
  });

  test('an unknown flag is refused rather than written to a guessed slot', () {
    final args = PlistArgs(argv);
    expect(() => args.valueIndex('--limit'), throwsA(isA<ToolException>()));
    try {
      args.valueIndex('--limit');
    } on ToolException catch (e) {
      expect(e.code, 'FLAG_MISSING');
      // The message has to say what was actually there, or the user cannot fix
      // a plist they can see in a text editor.
      expect(e.detail, contains('--threshold-mb'));
    }
  });

  test('a trailing flag with no value is refused', () {
    final truncated = [...argv.take(7), '--dialog-timeout'];
    final args = PlistArgs(truncated);
    expect(
      () => args.valueIndex('--dialog-timeout'),
      throwsA(isA<ToolException>()),
    );
    expect(
      () => args.withValues({'--dialog-timeout': 60}),
      throwsA(isA<ToolException>()),
    );
  });

  test('writing a value touches exactly one element', () {
    final updated = PlistArgs(
      argv,
    ).withValues({MemReaperConfig.thresholdFlag: 2048});
    expect(updated.length, argv.length);
    final changed = [
      for (var i = 0; i < argv.length; i++)
        if (argv[i] != updated[i]) i,
    ];
    expect(changed, [4], reason: 'only the threshold value slot moves');
    expect(updated[4], '2048');
    expect(
      updated[0],
      '/usr/bin/python3',
      reason: 'the interpreter is never rewritten',
    );
    expect(updated[2], '--service');
  });

  test('new values become strings, because argv entries always are', () {
    final updated = PlistArgs(argv).withValues({
      MemReaperConfig.thresholdFlag: 2048,
      MemReaperConfig.intervalFlag: 45,
    });
    expect(updated, isA<List<String>>());
    expect(updated[4], '2048');
    expect(updated[6], '45');
  });

  test('a flag the agent never had is appended, keeping positions stable', () {
    const withoutTimeout = [
      '/usr/bin/python3',
      '/Users/jlenteria/Project/mem_reaper.py',
      '--service',
      '--threshold-mb',
      '3072',
    ];
    final args = const PlistArgs(withoutTimeout);
    expect(args.optionalInt('--dialog-timeout'), isNull);

    final updated = args.withValues({
      MemReaperConfig.thresholdFlag: 1536,
      MemReaperConfig.dialogTimeoutFlag: 90,
    });
    expect(updated, [
      '/usr/bin/python3',
      '/Users/jlenteria/Project/mem_reaper.py',
      '--service',
      '--threshold-mb',
      '1536',
      '--dialog-timeout',
      '90',
    ]);
    // Re-reading what was just produced must give the same settings back.
    expect(
      MacOSMemReaperBackend.configFromArgs(PlistArgs(updated)).thresholdMb,
      1536,
    );
    expect(
      MacOSMemReaperBackend.configFromArgs(
        PlistArgs(updated),
      ).dialogTimeoutSeconds,
      90,
    );
  });

  test('a missing flag reads as mem_reaper default, not zero', () {
    final config = MacOSMemReaperBackend.configFromArgs(PlistArgs(argv));
    expect(config.thresholdMb, 3072);
    expect(config.intervalSeconds, 30);
    expect(config.dialogTimeoutSeconds, 45);

    final bare = MacOSMemReaperBackend.configFromArgs(
      const PlistArgs(['/usr/bin/python3', '/x/mem_reaper.py', '--service']),
    );
    expect(bare, MemReaperConfig.defaults);
  });

  test('a non-numeric value is reported as the broken plist it is', () {
    final args = PlistArgs([...argv]..[4] = '3GB');
    expect(
      () => MacOSMemReaperBackend.configFromArgs(args),
      throwsA(isA<ToolException>()),
    );
    try {
      MacOSMemReaperBackend.configFromArgs(args);
    } on ToolException catch (e) {
      expect(e.code, 'BAD_INT_ARG');
      expect(e.message, contains('--threshold-mb'));
    }
  });

  test('ProgramArguments must be a list of something', () {
    expect(
      () => PlistArgs.fromProgramArguments(null),
      throwsA(isA<ToolException>()),
    );
    expect(
      () => PlistArgs.fromProgramArguments(<Object>[]),
      throwsA(isA<ToolException>()),
    );
    expect(PlistArgs.fromProgramArguments(['a', 'b', 3]).argv, ['a', 'b', '3']);
  });

  test('top prints memory with the suffixes the parser must handle', () {
    // Real `top` output here uses K and M; G, T and the bare-byte form are
    // handled from the same table mem_reaper.py uses.
    expect(MacOSMemReaperBackend.parseTopSize('1215M'), 1215 * 1024 * 1024);
    expect(
      MacOSMemReaperBackend.parseTopSize('1.2G'),
      (1.2 * 1024 * 1024 * 1024).round(),
    );
    expect(MacOSMemReaperBackend.parseTopSize('512B'), 512);
    expect(MacOSMemReaperBackend.parseTopSize('944K '), 944 * 1024);
    expect(
      MacOSMemReaperBackend.parseTopSize('3T'),
      3 * 1024 * 1024 * 1024 * 1024,
    );
    expect(MacOSMemReaperBackend.parseTopSize('MEM'), isNull);
    expect(MacOSMemReaperBackend.parseTopSize('1:2'), isNull);
    expect(MacOSMemReaperBackend.parseTopSize(''), isNull);
  });

  test('the real captured top output parses into pids and sizes', () {
    final lines = File(
      'test/fixtures/top_mem.txt',
    ).readAsStringSync().split('\n');
    final sizes = <int, int>{};
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final pid = int.tryParse(parts[0]);
      final bytes = MacOSMemReaperBackend.parseTopSize(parts[1]);
      if (pid != null && bytes != null) sizes[pid] = bytes;
    }
    expect(sizes.length, greaterThan(100));
    expect(
      sizes.values.reduce((a, b) => a > b ? a : b),
      greaterThan(1024 * 1024 * 1024),
    );
  });
}
