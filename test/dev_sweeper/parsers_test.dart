import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/dev_sweeper/sweep_parsers.dart';
import 'package:toolshed/tools/dev_sweeper/sweep_target.dart';

SweepTarget _target(
  String path, {
  int? bytes,
  String label = 'cache',
  String ecosystem = 'Tool',
}) => SweepTarget(path: path, label: label, ecosystem: ecosystem, bytes: bytes);

void main() {
  group('parseDuSizes', () {
    test('reads the KiB before the tab, which is what du prints', () {
      final sizes = parseDuSizes(
        ' 1048576\t/Users/me/.gradle/caches\n'
        '5120\t/Users/me/Project/app/node_modules\n',
      );

      expect(sizes, {
        '/Users/me/.gradle/caches': 1048576 * 1024,
        '/Users/me/Project/app/node_modules': 5120 * 1024,
      });
    });

    test('drops the carriage return a Windows-written line can carry', () {
      expect(parseDuSizes('2048\t/tmp/cache\r\n'), {'/tmp/cache': 2048 * 1024});
    });

    test('skips lines that are not a size and a path', () {
      expect(
        parseDuSizes('not-a-size\t/x\nno-tab-line\n\t/missing-size\n'),
        isEmpty,
      );
    });
  });

  group('parsePathSizes', () {
    test('reads the bytes after the tab, which is the PowerShell order', () {
      expect(
        parsePathSizes(
          'C:\\Users\\me\\.gradle\\caches\t2048\r\n'
          'C:\\Users\\me\\AppData\\Local\\Pub\\Cache\t1024\n',
        ),
        {
          'C:\\Users\\me\\.gradle\\caches': 2048,
          'C:\\Users\\me\\AppData\\Local\\Pub\\Cache': 1024,
        },
      );
    });

    test('skips a value that is not a number', () {
      expect(parsePathSizes('C:\\x\tnot-a-number\n'), isEmpty);
    });
  });

  group('parseFoundPaths', () {
    test('keeps one path per non-empty line and trims the end', () {
      expect(parseFoundPaths('/a/node_modules\n\n/b/node_modules  \r\n'), [
        '/a/node_modules',
        '/b/node_modules',
      ]);
    });
  });

  group('formatBytes', () {
    test('uses binary units with one decimal under a hundred', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536 * 1024), '1.5 MB');
      expect(formatBytes(100 * 1024 * 1024 * 1024), '100 GB');
    });
  });

  group('SweepTarget', () {
    test('an unmeasured size is unknown, never zero', () {
      final unknown = _target('/x');
      expect(unknown.sizeLabel, 'size unknown');
      expect(unknown.measurable, isFalse);
      expect(_target('/x', bytes: 0).measurable, isFalse);
      expect(_target('/x', bytes: 1).measurable, isTrue);
    });

    test('searches label, ecosystem and path without case', () {
      final target = _target(
        '/Users/me/.gradle/caches',
        label: 'Gradle caches',
        ecosystem: 'Gradle',
      );
      expect(target.searchText, contains('gradle'));
      expect(target.searchText, contains('/users/me/.gradle/caches'));
    });
  });

  group('compareSweepTargets', () {
    test('largest first, then label, then path', () {
      final targets = [
        _target('/small', bytes: 1024, label: 'small'),
        _target('/big', bytes: 4096, label: 'big'),
        _target('/tie-b', bytes: 2048, label: 'alpha'),
        _target('/tie-a', bytes: 2048, label: 'alpha'),
      ]..sort(compareSweepTargets);

      expect(targets.map((target) => target.path), [
        '/big',
        '/tie-a',
        '/tie-b',
        '/small',
      ]);
    });

    test('labels compare without case', () {
      final targets = [
        _target('/z', bytes: 1024, label: 'Zeta'),
        _target('/a', bytes: 1024, label: 'alpha'),
      ]..sort(compareSweepTargets);

      expect(targets.first.path, '/a');
    });

    test('unknown sizes sort last rather than disappearing', () {
      final targets = [_target('/unknown'), _target('/known', bytes: 1)]
        ..sort(compareSweepTargets);

      expect(targets.map((target) => target.path), ['/known', '/unknown']);
    });
  });

  group('SweepReport', () {
    test('totals what was measured and ignores the unknown', () {
      final report = SweepReport([
        _target('/a', bytes: 1024),
        _target('/b'),
        _target('/c', bytes: 1024),
      ]);

      expect(report.totalBytes, 2048);
    });
  });

  group('SweepOutcome', () {
    test('names the count and the size that moved', () {
      final outcome = SweepOutcome(
        trashed: [_target('/a', bytes: 1024 * 1024)],
        failures: const [],
        freedBytes: 1024 * 1024,
      );

      expect(outcome.requested, 1);
      expect(outcome.anyMoved, isTrue);
      expect(outcome.describe(), 'Moved 1 item (1.0 MB) to the Trash.');
    });

    test('keeps the failures after what did move', () {
      final outcome = SweepOutcome(
        trashed: [
          _target('/a', bytes: 1024 * 1024),
          _target('/b', bytes: 1024 * 1024),
        ],
        failures: [
          SweepFailure(target: _target('/c'), message: 'Permission denied.'),
        ],
        freedBytes: 2 * 1024 * 1024,
      );

      expect(outcome.requested, 3);
      expect(
        outcome.describe(),
        'Moved 2 items (2.0 MB) to the Trash. 1 of 3 could not be moved.',
      );
    });

    test('says nothing moved when the Trash refused everything', () {
      final outcome = SweepOutcome(
        trashed: const [],
        failures: [
          SweepFailure(target: _target('/a'), message: 'Permission denied.'),
        ],
        freedBytes: 0,
      );

      expect(outcome.anyMoved, isFalse);
      expect(outcome.describe(), 'Nothing could be moved. Permission denied.');
    });

    test('says nothing moved when there was nothing to do', () {
      const outcome = SweepOutcome(trashed: [], failures: [], freedBytes: 0);

      expect(outcome.describe(), 'Nothing was moved.');
    });
  });
}
