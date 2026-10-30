import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/app_lock/app_lock_config.dart';

void main() {
  const notes = LockedApp(
    bundleId: 'com.apple.Notes',
    name: 'Notes',
    path: '/System/Applications/Notes.app',
    armedAt: 1793243238.0,
  );
  const safari = LockedApp(
    bundleId: 'com.apple.Safari',
    name: 'Safari',
    path: '/Applications/Safari.app',
  );

  group('the lock list', () {
    test('defaults are on, five minutes, and ask-before-insist', () {
      const config = AppLockConfig.defaults;
      expect(config.enabled, isTrue);
      expect(config.unlockMinutes, 5);
      expect(config.forceQuit, isFalse);
      expect(config.locked, isEmpty);
      expect(config.isValid, isTrue);
    });

    test('adding and removing leaves the rest of the draft alone', () {
      const config = AppLockConfig(unlockMinutes: 20, forceQuit: true);
      final withNotes = config.withApp(notes);
      expect(withNotes.unlockMinutes, 20);
      expect(withNotes.forceQuit, isTrue);
      expect(withNotes.isLocked(notes.bundleId), isTrue);
      expect(withNotes.withApp(notes, on: false).locked, isEmpty);
    });

    test('re-adding the same app replaces it rather than doubling it', () {
      const moved = LockedApp(
        bundleId: 'com.apple.Notes',
        name: 'Notes',
        path: '/Volumes/Backup/Notes.app',
        armedAt: 2.0,
      );
      final config = const AppLockConfig().withApp(notes).withApp(moved);
      expect(config.locked, hasLength(1));
      expect(config.isValid, isTrue);
    });

    test('a window outside the range is refused, inside it is not', () {
      expect(
        const AppLockConfig(unlockMinutes: 0).problems,
        anyElement(contains('between 1 and 240 minutes')),
      );
      expect(const AppLockConfig(unlockMinutes: 241).isValid, isFalse);
      expect(const AppLockConfig(unlockMinutes: 240).isValid, isTrue);
    });

    test('the system apps the agent would refuse are not offered', () {
      for (final entry in AppLockConfig.guardedBundleIds.entries) {
        final config = AppLockConfig(
          locked: [
            LockedApp(bundleId: entry.key, name: 'System piece', path: '/x'),
          ],
        );
        expect(
          config.problems,
          anyElement(contains(entry.value)),
          reason:
              'the console has to give the same reason the helper gives, '
              'not a fourth one of its own',
        );
      }
    });

    test('an entry with no bundle id could not be named by the agent', () {
      const blank = LockedApp(bundleId: '  ', name: 'Ghost', path: '/x');
      expect(
        const AppLockConfig(locked: [blank]).problems,
        anyElement(contains('no bundle id')),
      );
    });

    test('a list longer than the file holds is a lock nobody keeps', () {
      final config = AppLockConfig(
        locked: [
          for (var i = 0; i < AppLockConfig.maxLockedApps + 1; i++)
            LockedApp(bundleId: 'a.$i', name: 'App $i', path: '/x'),
        ],
      );
      expect(config.isValid, isFalse);
      expect(config.problems, anyElement(contains('more than the 40')));
    });

    test('the same app twice is a mistake worth naming', () {
      final config = const AppLockConfig(locked: [notes, safari, notes]);
      expect(config.problems, anyElement(contains('twice')));
    });

    test('the one-line blurb does not pretend an empty list is a lock', () {
      expect(AppLockConfig.defaults.blurb, 'Nothing locked yet');
      expect(
        const AppLockConfig(enabled: false, locked: [notes]).blurb,
        'Lock switched off · 1 named',
      );
      expect(
        const AppLockConfig(locked: [notes, safari]).blurb,
        'Notes, Safari · locks after 5 min idle',
      );
      final many = AppLockConfig(
        locked: [
          notes,
          safari,
          for (var i = 0; i < 3; i++)
            LockedApp(bundleId: 'b.$i', name: 'Extra $i', path: '/x'),
        ],
      );
      expect(many.blurb, 'Notes, Safari, Extra 0 +2 · locks after 5 min idle');
    });
  });

  group('the file on disk', () {
    test('survives a round trip', () {
      final config = const AppLockConfig(
        enabled: false,
        unlockMinutes: 90,
        forceQuit: true,
        locked: [notes, safari],
      );
      expect(AppLockConfig.fromJson(config.toJson()), config);
    });

    test('a missing key falls back rather than failing the screen', () {
      // What a future version of the helper would leave behind if this app were
      // downgraded: the keys it does not write are the ones the defaults cover.
      final config = AppLockConfig.fromJson({
        'locked': [notes.toJson()],
      });
      expect(config.enabled, AppLockConfig.defaults.enabled);
      expect(config.unlockMinutes, AppLockConfig.defaults.unlockMinutes);
      expect(config.locked, [notes]);
    });

    test(
      'an entry that is not a map is dropped; one with no id is a problem',
      () {
        final config = AppLockConfig.fromJson({
          'locked': [
            notes.toJson(),
            'nonsense',
            null,
            {'name': 'No id'},
          ],
        });
        expect(config.locked, hasLength(2));
        expect(config.locked.first, notes);
        expect(config.problems, anyElement(contains('no bundle id')));
      },
    );
  });
}
