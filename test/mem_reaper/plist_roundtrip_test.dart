import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/tools/mem_reaper/macos_backend.dart';
import 'package:toolshed/tools/mem_reaper/mem_reaper_config.dart';
import 'package:toolshed/tools/mem_reaper/plist_args.dart';

const String _label = 'com.bling.memreaper';
const String _script = '/Users/jlenteria/Project/mem_reaper.py';

/// Round-trips a settings edit through the real `plutil`, against a scratch copy
/// of the real agent plist. Nothing here touches
/// `~/Library/LaunchAgents/com.bling.memreaper.plist` — the tearDown
/// compares it byte for byte — and nothing calls launchctl, because bootstrapping
/// this label would collide with the agent that is actually running.
void main() {
  late Directory scratch;
  late String agentsDir;
  late String plistPath;
  late List<int> liveBefore;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('toolshed_plist_roundtrip');
    agentsDir = '${scratch.path}/Library/LaunchAgents';
    Directory(agentsDir).createSync(recursive: true);
    plistPath = '$agentsDir/$_label.plist';
    File('test/fixtures/memreaper.plist').copySync(plistPath);

    final live = File(
      '${Platform.environment['HOME']}/Library/LaunchAgents/$_label.plist',
    );
    liveBefore = live.existsSync() ? live.readAsBytesSync() : const [];
  });

  tearDown(() {
    final live = File(
      '${Platform.environment['HOME']}/Library/LaunchAgents/$_label.plist',
    );
    if (liveBefore.isNotEmpty && live.existsSync()) {
      expect(
        live.readAsBytesSync(),
        liveBefore,
        reason: 'a test must not modify the live agent plist',
      );
    }
    scratch.deleteSync(recursive: true);
  });

  MacOSMemReaperBackend backend() =>
      MacOSMemReaperBackend(homeOverride: scratch.path);

  /// Writes the scratch plist with the given ProgramArguments, as XML that
  /// plutil itself validates.
  void writeAgent(List<String> argv) {
    String esc(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    File(plistPath).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>$_label</string>
\t<key>ProgramArguments</key>
\t<array>
${argv.map((a) => '\t\t<string>${esc(a)}</string>').join('\n')}
\t</array>
\t<key>LimitLoadToSessionType</key>
\t<string>Aqua</string>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<true/>
\t<key>ThrottleInterval</key>
\t<integer>10</integer>
\t<key>StandardOutPath</key>
\t<string>/Users/jlenteria/Library/Logs/mem_reaper.log</string>
</dict>
</plist>
''');
  }

  List<String> programArguments() =>
      (jsonDecode(
                _plutil([
                  '-extract',
                  'ProgramArguments',
                  'json',
                  '-o',
                  '-',
                  plistPath,
                ]),
              )
              as List)
          .map((e) => '$e')
          .toList();

  group('discovery', () {
    test('finds the agent by its arguments, not its file name', () async {
      final agent = (await backend().discover()).agent;
      expect(agent, isNotNull);
      expect(agent!.label, _label);
      expect(agent.argv.interpreter, '/usr/bin/python3');
      expect(agent.argv.script, _script);
      expect(agent.interpreterPath, '/usr/bin/python3');
      expect(agent.logPath, '/Users/jlenteria/Library/Logs/mem_reaper.log');
      expect(agent.throttleInterval, 10);
      expect(
        agent.loadsInAqua,
        isTrue,
        reason: 'without Aqua the confirmation dialogs never appear',
      );
    });

    test(
      'reports a second plist rather than silently controlling one',
      () async {
        File('$agentsDir/extra.plist')
          ..writeAsStringSync(File(plistPath).readAsStringSync())
          ..renameSync('$agentsDir/zzz-extra.plist');
        final discovery = await backend().discover();
        expect(discovery.all, hasLength(2));
        expect(discovery.problems.single, contains('This app controls'));
        expect(
          discovery.problems.single,
          contains('each raise their own dialog'),
        );
      },
    );

    test('warns when the agent would not load in the Aqua session', () async {
      final xml = File(plistPath).readAsStringSync().replaceAll(
        '<string>Aqua</string>',
        '<string>Background</string>',
      );
      File(plistPath).writeAsStringSync(xml);
      final discovery = await backend().discover();
      expect(discovery.problems.single, contains('not Aqua'));
    });

    test('ignores plists that have nothing to do with mem_reaper', () async {
      writeAgent(['python3', '/opt/other.py', '--watch']);
      final discovery = await backend().discover();
      expect(discovery.agent, isNull);
      expect(discovery.problems, isNotEmpty);
    });

    test('a directory with no plists is not an error', () async {
      Directory(agentsDir).deleteSync(recursive: true);
      final discovery = await backend().discover();
      expect(discovery.agent, isNull);
    });
  });

  group('read and write', () {
    test('readConfig returns the values the plist holds', () async {
      expect(
        await backend().readConfig(),
        const MemReaperConfig(
          thresholdMb: 3072,
          intervalSeconds: 30,
          dialogTimeoutSeconds: 45,
        ),
      );
    });

    test('an edit changes exactly the three value slots', () async {
      final agent = (await backend().discover()).agent!;
      await backend().applyToPlist(agent, const {
        MemReaperConfig.thresholdFlag: 2048,
        MemReaperConfig.intervalFlag: 15,
        MemReaperConfig.dialogTimeoutFlag: 60,
      });

      expect(programArguments(), [
        '/usr/bin/python3',
        _script,
        '--service',
        '--threshold-mb',
        '2048',
        '--interval',
        '15',
        '--dialog-timeout',
        '60',
      ]);
      expect(
        _plutil([
          '-extract',
          'ProgramArguments.4',
          'raw',
          '-o',
          '-',
          plistPath,
        ]),
        '2048',
      );
      expect(
        _plutil([
          '-extract',
          'LimitLoadToSessionType',
          'raw',
          '-o',
          '-',
          plistPath,
        ]),
        'Aqua',
      );
      expect(
        _plutil(['-extract', 'KeepAlive', 'raw', '-o', '-', plistPath]),
        'true',
      );
      expect(
        _plutil(['-extract', 'Label', 'raw', '-o', '-', plistPath]),
        _label,
      );
      expect(_plutil(['-lint', plistPath]), contains('OK'));
      expect(
        await backend().readConfig(),
        const MemReaperConfig(
          thresholdMb: 2048,
          intervalSeconds: 15,
          dialogTimeoutSeconds: 60,
        ),
      );
    });

    test(
      'a flag the agent never had is appended after the ones it knows',
      () async {
        writeAgent([
          '/usr/bin/python3',
          _script,
          '--service',
          '--threshold-mb',
          '3072',
        ]);
        final b = backend();
        final agent = (await b.discover()).agent!;
        expect(agent.argv.optionalInt(MemReaperConfig.intervalFlag), isNull);

        await b.applyToPlist(agent, const {
          MemReaperConfig.thresholdFlag: 2048,
          MemReaperConfig.intervalFlag: 15,
        });
        expect(programArguments(), [
          '/usr/bin/python3',
          _script,
          '--service',
          '--threshold-mb',
          '2048',
          '--interval',
          '15',
        ]);
      },
    );

    test(
      'a flag sitting last with no value is refused, file untouched',
      () async {
        writeAgent([
          '/usr/bin/python3',
          _script,
          '--service',
          '--threshold-mb',
          '3072',
          '--interval',
          '30',
          '--dialog-timeout',
        ]);
        final b = backend();
        final agent = (await b.discover()).agent!;
        final before = File(plistPath).readAsBytesSync();
        await expectLater(
          b.applyToPlist(agent, const {MemReaperConfig.dialogTimeoutFlag: 60}),
          throwsA(isA<ToolException>()),
        );
        expect(File(plistPath).readAsBytesSync(), before);
      },
    );

    test('a value that is not a number is reported, never guessed', () async {
      writeAgent([
        '/usr/bin/python3',
        _script,
        '--service',
        '--threshold-mb',
        '3GB',
      ]);
      await expectLater(
        backend().readConfig(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'BAD_INT_ARG'),
        ),
      );
    });

    test('an edit leaves a readable backup beside the plist', () async {
      final agent = (await backend().discover()).agent!;
      final backup = await backend().applyToPlist(agent, const {
        MemReaperConfig.thresholdFlag: 4096,
      });
      expect(File(backup).existsSync(), isTrue);
      expect(File(backup).readAsStringSync(), contains('3072'));
    });
  });

  group('config sheet', () {
    test('rejects the limits mem_reaper.py enforces itself', () {
      // mem_reaper refuses --threshold-mb below 64; the app must not offer it.
      expect(
        const MemReaperConfig(
          thresholdMb: 8,
          intervalSeconds: 30,
          dialogTimeoutSeconds: 45,
        ).isValid,
        isFalse,
      );
      expect(
        const MemReaperConfig(
          thresholdMb: 1024,
          intervalSeconds: 1,
          dialogTimeoutSeconds: 45,
        ).problems,
        hasLength(1),
      );
      expect(
        const MemReaperConfig(
          thresholdMb: 1024,
          intervalSeconds: 30,
          dialogTimeoutSeconds: 0,
        ).problems,
        hasLength(1),
      );
      expect(
        const MemReaperConfig(
          thresholdMb: 1024,
          intervalSeconds: 30,
          dialogTimeoutSeconds: 45,
        ).isValid,
        isTrue,
      );
    });

    test('shows the limit the way the user described it', () {
      expect(
        const MemReaperConfig(
          thresholdMb: 3072,
          intervalSeconds: 30,
          dialogTimeoutSeconds: 45,
        ).thresholdLabel,
        '3.00 GB',
      );
      expect(
        const MemReaperConfig(
          thresholdMb: 768,
          intervalSeconds: 30,
          dialogTimeoutSeconds: 45,
        ).thresholdLabel,
        '768 MB',
      );
    });
  });

  test('the installer template produces a plist this app can read back', () {
    final path = '${scratch.path}/template.plist';
    File(path).writeAsStringSync(
      MacOSMemReaperBackend.plistTemplate(
        python: '/usr/bin/python3',
        script: '/tmp/mem_reaper.py',
        config: MemReaperConfig.defaults,
        logPath: '/tmp/mem_reaper.log',
      ),
    );
    expect(_plutil(['-lint', path]), contains('OK'));
    final args = PlistArgs.fromProgramArguments(
      jsonDecode(
        _plutil(['-extract', 'ProgramArguments', 'json', '-o', '-', path]),
      ),
    );
    expect(
      MacOSMemReaperBackend.configFromArgs(args),
      MemReaperConfig.defaults,
    );
    expect(
      _plutil(['-extract', 'LimitLoadToSessionType', 'raw', '-o', '-', path]),
      'Aqua',
    );
    expect(
      args.argv.first,
      '/usr/bin/python3',
      reason: 'never points the agent at a newer python',
    );
  });

  test('a script path containing XML characters survives the plist', () {
    final path = '${scratch.path}/odd.plist';
    File(path).writeAsStringSync(
      MacOSMemReaperBackend.plistTemplate(
        python: '/usr/bin/python3',
        script: '/tmp/a & b</script>/mem_reaper.py',
        config: MemReaperConfig.defaults,
        logPath: '/tmp/mem_reaper.log',
      ),
    );
    expect(_plutil(['-lint', path]), contains('OK'));
    expect(
      (jsonDecode(
                _plutil([
                  '-extract',
                  'ProgramArguments',
                  'json',
                  '-o',
                  '-',
                  path,
                ]),
              )
              as List)
          .map((e) => '$e'),
      contains('/tmp/a & b</script>/mem_reaper.py'),
    );
  });
}

String _plutil(List<String> args) {
  final result = Process.runSync('plutil', args);
  if (result.exitCode != 0) {
    fail(
      'plutil ${args.join(' ')} exited ${result.exitCode}: ${result.stderr}',
    );
  }
  return '${result.stdout}'.trim();
}
