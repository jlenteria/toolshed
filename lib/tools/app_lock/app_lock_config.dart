import '../../models/tool_config.dart';

/// One app named in the lock list.
///
/// The bundle id is the identity, because a path moves when someone drags the
/// icon from /Applications to a USB stick, and the lock has to follow the app
/// rather than the folder. The name and path ride along so the agent can say
/// "Notes is locked" and open the right bundle without asking LaunchServices.
class LockedApp {
  const LockedApp({
    required this.bundleId,
    required this.name,
    required this.path,
    this.armedAt = 0,
  });

  final String bundleId;
  final String name;
  final String path;

  /// When this entry was added, as unix seconds. The agent does not use it to
  /// decide anything today, but the field is what a future "only apps launched
  /// after I locked it" rule would need, and writing a file the daemon reads is
  /// the one place a missing key costs a protocol test rather than a bug.
  final double armedAt;

  Map<String, Object?> toJson() => {
    'bundleId': bundleId,
    'name': name,
    'path': path,
    'armedAt': armedAt,
  };

  static LockedApp fromJson(Map<String, Object?> json) => LockedApp(
    bundleId: '${json['bundleId'] ?? ''}',
    name: '${json['name'] ?? ''}',
    path: '${json['path'] ?? ''}',
    armedAt: (json['armedAt'] as num?)?.toDouble() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is LockedApp &&
      other.bundleId == bundleId &&
      other.name == name &&
      other.path == path;

  @override
  int get hashCode => Object.hash(bundleId, name, path);
}

/// The lock list, as the console edits it and the agent obeys it.
///
/// The rule that decides whether a launch gets closed lives in
/// `macos/lockd/main.swift`, not here. A second copy of it in Dart would drift
/// from the process that actually closes windows, and only one of the two can be
/// the one the user sees.
class AppLockConfig implements ToolConfig {
  const AppLockConfig({
    this.enabled = true,
    this.unlockMinutes = 5,
    this.forceQuit = false,
    this.locked = const [],
  });

  static const AppLockConfig defaults = AppLockConfig();

  static const int minUnlockMinutes = 1;
  static const int maxUnlockMinutes = 240;
  static const int maxLockedApps = 40;

  /// Apps the agent will not close whatever this file says. It keeps its own
  /// copy of the list — the config file is hand-editable, and a lock that can be
  /// talked into killing Finder is an outage, not a feature — but the console
  /// refuses to offer them so the user is never surprised by a refusal.
  static const Map<String, String> guardedBundleIds = {
    'com.apple.finder':
        'closing Finder takes the desktop and every window on it',
    'com.apple.dock': 'closing the Dock takes the Dock and the app switcher',
    'com.apple.controlcenter':
        'closing Control Center takes the menu bar extras',
    'com.apple.SystemUIServer': 'closing it takes the menu bar',
    'com.apple.loginwindow': 'closing it ends the login session',
    'com.apple.wallpaper.agent': 'closing it takes the desktop',
    'com.bling.toolshed':
        'toolshed hosts the lock, so locking it would hide the button that '
        'unlocks everything else',
  };

  /// Off means the agent leaves everything alone. It does not delete the list:
  /// switching the lock off for the afternoon should not cost the work of
  /// picking the apps again.
  final bool enabled;

  /// How long a locked app may sit in the background before it is closed again.
  ///
  /// The agent treats this as an inactivity timer, not a stopwatch from the
  /// passphrase: while the app is in front it keeps moving the deadline
  /// forward, so only time actually spent away from the app counts. A fixed
  /// window would close an app somebody is in the middle of using, which is
  /// the one thing a lock must never do.
  final int unlockMinutes;

  /// Ask, or insist. `false` sends the same event ⌘Q sends, so an app with
  /// unsaved work gets to put up its own save dialog; `true` also kills it after
  /// three seconds, which an app ignoring the request would otherwise sit there.
  final bool forceQuit;

  final List<LockedApp> locked;

  bool isLocked(String bundleId) => locked.any((a) => a.bundleId == bundleId);

  AppLockConfig copyWith({
    bool? enabled,
    int? unlockMinutes,
    bool? forceQuit,
    List<LockedApp>? locked,
  }) => AppLockConfig(
    enabled: enabled ?? this.enabled,
    unlockMinutes: unlockMinutes ?? this.unlockMinutes,
    forceQuit: forceQuit ?? this.forceQuit,
    locked: locked ?? this.locked,
  );

  /// Add or remove one app, leaving the rest of the draft alone.
  AppLockConfig withApp(LockedApp app, {bool on = true}) {
    final next = [
      for (final entry in locked)
        if (entry.bundleId != app.bundleId) entry,
    ];
    if (on) next.add(app);
    return copyWith(locked: next);
  }

  @override
  List<String> get problems {
    final reasons = <String>[];
    if (unlockMinutes < minUnlockMinutes || unlockMinutes > maxUnlockMinutes) {
      reasons.add(
        'The unlock window has to be between $minUnlockMinutes and '
        '$maxUnlockMinutes minutes, not $unlockMinutes.',
      );
    }
    if (locked.length > maxLockedApps) {
      reasons.add(
        '${locked.length} apps is more than the $maxLockedApps this list holds. '
        'A lock over every app on the Mac is a lock you will switch off.',
      );
    }
    for (final app in locked) {
      if (app.bundleId.trim().isEmpty) {
        reasons.add(
          'One entry has no bundle id, so the agent could not name it.',
        );
      }
      final guard = guardedBundleIds[app.bundleId];
      if (guard != null) {
        reasons.add('${app.name} cannot be locked: $guard.');
      }
    }
    final ids = locked.map((a) => a.bundleId).toSet();
    if (ids.length != locked.length) {
      reasons.add('The same app is in the list twice.');
    }
    return reasons;
  }

  @override
  bool get isValid => problems.isEmpty;

  @override
  String get blurb {
    if (!enabled) return 'Lock switched off · ${locked.length} named';
    if (locked.isEmpty) return 'Nothing locked yet';
    final apps = locked.map((a) => a.name).take(3).join(', ');
    final more = locked.length > 3 ? ' +${locked.length - 3}' : '';
    return '$apps$more · locks after $unlockMinutes min idle';
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'enabled': enabled,
    'unlockMinutes': unlockMinutes,
    'forceQuit': forceQuit,
    'locked': [for (final app in locked) app.toJson()],
  };

  /// Missing keys fall back rather than failing, the same way the fan policy
  /// reads a reply from an older daemon: a config written by a future version
  /// should still open.
  static AppLockConfig fromJson(Map<String, Object?> json) {
    final entries = (json['locked'] as List?) ?? const [];
    return AppLockConfig(
      enabled: json['enabled'] as bool? ?? defaults.enabled,
      unlockMinutes:
          (json['unlockMinutes'] as num?)?.toInt() ?? defaults.unlockMinutes,
      forceQuit: json['forceQuit'] as bool? ?? defaults.forceQuit,
      locked: [
        for (final entry in entries)
          if (entry is Map)
            LockedApp.fromJson(Map<String, Object?>.from(entry)),
      ],
    );
  }

  /// Two configs are the same when the agent could not tell them apart. The
  /// console needs this to say whether what is on disk is what is on screen.
  @override
  bool operator ==(Object other) =>
      other is AppLockConfig &&
      other.enabled == enabled &&
      other.unlockMinutes == unlockMinutes &&
      other.forceQuit == forceQuit &&
      other.locked.length == locked.length &&
      other.locked.asMap().entries.every(
        (entry) => entry.value == locked[entry.key],
      );

  @override
  int get hashCode => Object.hash(enabled, unlockMinutes, forceQuit, locked);
}
