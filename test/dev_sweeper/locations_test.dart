import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/dev_sweeper/cache_locations.dart';

void main() {
  group('macOS cache locations', () {
    final locations = macCacheLocations(home: '/Users/me');
    final paths = locations.map((location) => location.path).toList();

    test('covers the build tools a Mac developer uses', () {
      expect(
        paths,
        containsAll([
          '/Users/me/Library/Developer/Xcode/DerivedData',
          '/Users/me/Library/Developer/CoreSimulator/Caches',
          '/Users/me/Library/Caches/CocoaPods',
          '/Users/me/Library/Caches/Homebrew',
          '/Users/me/.gradle/caches',
          '/Users/me/.npm/_cacache',
          '/Users/me/Library/pnpm/store',
          '/Users/me/.pub-cache',
          '/Users/me/Library/Caches/go-build',
          '/Users/me/.cargo/registry/cache',
        ]),
      );
    });

    test('never offers an archive, a simulator device or home itself', () {
      expect(paths, isNot(contains('/Users/me')));
      expect(paths.where((path) => path.contains('Archives')), isEmpty);
      expect(paths.where((path) => path.contains('Devices')), isEmpty);
    });

    test('every location has a label and an owning tool', () {
      for (final location in locations) {
        expect(location.label, isNotEmpty);
        expect(location.ecosystem, isNotEmpty);
      }
    });
  });

  group('Linux cache locations', () {
    test('honours XDG_DATA_HOME and XDG_CACHE_HOME', () {
      final paths = linuxCacheLocations(
        home: '/home/me',
        environment: const {
          'XDG_DATA_HOME': '/data',
          'XDG_CACHE_HOME': '/cache',
        },
      ).map((location) => location.path).toList();

      expect(paths, contains('/cache/yarn'));
      expect(paths, contains('/data/pnpm/store'));
      expect(paths, contains('/cache/go-build'));
      expect(paths, contains('/cache/Homebrew'));
      expect(paths, isNot(contains('/home/me/.cache/yarn')));
    });

    test('falls back to the freedesktop defaults', () {
      final paths = linuxCacheLocations(
        home: '/home/me',
      ).map((location) => location.path).toList();

      expect(
        paths,
        containsAll([
          '/home/me/.cache/yarn',
          '/home/me/.local/share/pnpm/store',
          '/home/me/.cache/go-build',
        ]),
      );
    });
  });

  group('Windows cache locations', () {
    test('honours LOCALAPPDATA for the per-user stores', () {
      final paths = windowsCacheLocations(
        home: r'C:\Users\me',
        environment: const {'LOCALAPPDATA': r'D:\Local'},
      ).map((location) => location.path).toList();

      expect(paths, contains(r'D:\Local\npm-cache\_cacache'));
      expect(paths, contains(r'D:\Local\Pub\Cache'));
      expect(paths, contains(r'D:\Local\go-build'));
      expect(paths, contains(r'C:\Users\me\.nuget\packages'));
    });

    test('defaults to AppData\\Local under home', () {
      final paths = windowsCacheLocations(
        home: r'C:\Users\me',
      ).map((location) => location.path).toList();

      expect(paths, contains(r'C:\Users\me\AppData\Local\go-build'));
    });
  });

  group('project roots', () {
    test('unix looks in checkout folders, never home itself', () {
      final roots = unixProjectRoots('/Users/me');

      expect(roots, contains('/Users/me/Project'));
      expect(roots, contains('/Users/me/Developer'));
      expect(roots, isNot(contains('/Users/me')));
      expect(roots, everyElement(startsWith('/Users/me/')));
    });

    test('Windows includes source\\repos under the checkout folders', () {
      final roots = windowsProjectRoots(r'C:\Users\me');

      expect(roots, contains(r'C:\Users\me\source\repos'));
      expect(roots, isNot(contains(r'C:\Users\me')));
    });
  });
}
