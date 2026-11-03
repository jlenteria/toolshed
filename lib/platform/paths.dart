import 'dart:io';

/// Locations the app reads and writes. Nothing here is hardcoded to a username:
/// the agent is *found* by scanning ~/Library/LaunchAgents (see
/// MacOSMemReaperBackend.discoverAgent), so a plist installed under a different
/// label is still managed rather than duplicated.
class Paths {
  Paths._();

  static String? _home;

  /// The `Contents/Resources` of the `.app` this code is running inside, or
  /// `null` when it is not inside one (`flutter test`, `dart run`, a helper
  /// invoked from a terminal).
  ///
  /// This is what makes an installed `toolshed.app` self-contained. A tool that
  /// finds its helper in `~/Project/toolshed/build/...` works on the machine
  /// that compiled it and nowhere else, and the console cannot tell the
  /// difference until a button fails.
  static String? bundleResources({String? executable}) {
    const marker = '/Contents/MacOS/';
    final path = executable ?? Platform.resolvedExecutable;
    final at = path.lastIndexOf(marker);
    if (at < 0) return null;
    final dir = '${path.substring(0, at)}/Contents/Resources';
    return Directory(dir).existsSync() ? dir : null;
  }

  /// The helper named [binary] inside the running bundle, when there is one.
  static String? bundled(String binary, {String? executable}) {
    final res = bundleResources(executable: executable);
    if (res == null) return null;
    final file = File('$res/$binary');
    return file.existsSync() ? file.path : null;
  }

  /// The `docker` CLI, wherever the machine's engine put it — or `null` when
  /// there is none.
  ///
  /// Deliberately engine-agnostic: it looks for the standard `docker` binary and
  /// nothing that belongs to a specific runtime. Uninstall OrbStack and install
  /// Docker Desktop (or run a plain `dockerd`, Colima or podman) and this still
  /// resolves, because the thing being found is the CLI the switch installs, not
  /// a path welded to the old engine. A dangling symlink left behind by an
  /// uninstalled engine fails `existsSync` (which follows the link) and is
  /// skipped, so a half-removed OrbStack never wins over a working Docker
  /// Desktop.
  ///
  /// The environment's `PATH` is scanned first — that is where a user's chosen
  /// engine already points — then the well-known install locations. The second
  /// pass exists because an app launched from the Dock does not inherit a login
  /// shell's `PATH`: Homebrew and `/usr/local/bin` would otherwise be invisible
  /// to it even though the CLI is installed.
  static String? dockerBinary() {
    final names = Platform.isWindows
        ? const ['docker.exe', 'docker']
        : const ['docker'];
    for (final dir in _pathDirectories) {
      for (final name in names) {
        final file = File('$dir${Platform.pathSeparator}$name');
        if (file.existsSync()) return file.path;
      }
    }
    for (final candidate in dockerCandidates()) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> get _pathDirectories {
    final path = Platform.environment['PATH'] ?? '';
    if (path.isEmpty) return const [];
    return path
        .split(Platform.isWindows ? ';' : ':')
        .where((d) => d.isNotEmpty)
        .toList();
  }

  /// The named executable resolved to an absolute path, or `null`.
  ///
  /// A synchronous filesystem probe that follows symlinks, so a dangling link
  /// left by a half-uninstalled tool reads as absent rather than as a binary
  /// that will fail the moment it is run. Used to find an engine's own manager
  /// (`colima`, `orbctl`) the same way [dockerBinary] finds the CLI — which
  /// means the same two passes: the environment's `PATH` first, then the
  /// well-known install directories. The second pass matters because an app
  /// launched from the Dock does not inherit a login shell's `PATH`, so
  /// Homebrew's `/opt/homebrew/bin` is invisible to it even though the manager
  /// is installed there; without the fallback the engine card disappears only
  /// in the packaged app and works only under `flutter run`.
  static String? which(String name) {
    final names = Platform.isWindows && !name.endsWith('.exe')
        ? <String>[name, '$name.exe']
        : <String>[name];
    for (final dir in _pathDirectories) {
      for (final candidate in names) {
        final file = File('$dir${Platform.pathSeparator}$candidate');
        if (file.existsSync()) return file.path;
      }
    }
    for (final dir in _wellKnownBinDirectories) {
      for (final candidate in names) {
        final file = File('$dir${Platform.pathSeparator}$candidate');
        if (file.existsSync()) return file.path;
      }
    }
    return null;
  }

  /// Bin directories that a GUI launch strips from `PATH` but that still hold
  /// the usual installs. Scanned by [which] only after `PATH` comes up empty, so
  /// a user's own choice of binary always wins over these defaults.
  static List<String> get _wellKnownBinDirectories {
    if (Platform.isWindows) return const [];
    if (Platform.isMacOS) {
      return const ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];
    }
    return const ['/usr/local/bin', '/usr/bin', '/snap/bin'];
  }

  /// The `PATH` to hand a child process: the inherited one first, then the
  /// well-known bin directories, de-duplicated.
  ///
  /// A binary discovered through an absolute path still shells out to its own
  /// siblings by name — `colima` runs `lima`, both in `/opt/homebrew/bin`. When
  /// the app was launched from the Dock that directory is not on its `PATH`, so
  /// the child would fail to find its helper even though the parent reached the
  /// tool fine. Appending (never prepending) the known dirs means a user's own
  /// `PATH` entries always win; this only fills what the launch stripped.
  static String get subprocessPath {
    final separator = Platform.isWindows ? ';' : ':';
    final inherited = (Platform.environment['PATH'] ?? '')
        .split(separator)
        .where((d) => d.isNotEmpty);
    final seen = <String>{};
    final dirs = <String>[];
    for (final dir in <String>[...inherited, ..._wellKnownBinDirectories]) {
      if (seen.add(dir)) dirs.add(dir);
    }
    return dirs.join(separator);
  }

  /// Known engine locations, in the order a switch is most likely to have
  /// installed one of them. Only used after a `PATH` scan comes up empty.
  static List<String> dockerCandidates() {
    if (Platform.isWindows) {
      return const [
        r'C:\Program Files\Docker\Docker\resources\bin\docker.exe',
        r'C:\Program Files\Docker\Docker\resources\cli\docker.exe',
      ];
    }
    if (Platform.isMacOS) {
      return [
        '/usr/local/bin/docker',
        '/opt/homebrew/bin/docker',
        '/usr/bin/docker',
        '$home/.orbstack/bin/docker',
      ];
    }
    return const [
      '/usr/bin/docker',
      '/usr/local/bin/docker',
      '/snap/bin/docker',
    ];
  }

  static String get home {
    if (_home != null) return _home!;
    final env = Platform.environment;
    final candidate = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    if (candidate == null || candidate.isEmpty) {
      throw StateError('Cannot resolve the home directory.');
    }
    return _home = candidate;
  }

  static Directory get launchAgents => Directory('$home/Library/LaunchAgents');

  /// Where mem_reaper.py lives, preferring whatever the installed agent already
  /// points at so the app drives the same copy that is running.
  static String? scriptPath({String? fromPlist, String? executable}) {
    if (fromPlist != null && File(fromPlist).existsSync()) return fromPlist;
    for (final candidate in scriptCandidates(executable: executable)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// The app bundle's copy first, so an installed toolshed installs its agent
  /// from what it carries rather than from a checkout; then the checkout, for
  /// `flutter test` and a helper run by hand; then the places an agent
  /// installed before `scripts/` existed still points at.
  static List<String> scriptCandidates({String? executable}) => [
    ?bundled('mem_reaper.py', executable: executable),
    '$home/Project/toolshed/scripts/mem_reaper.py',
    '$home/Project/mem_reaper.py',
    '$home/mem_reaper.py',
    '$home/.local/bin/mem_reaper.py',
    '/usr/local/bin/mem_reaper.py',
    '/opt/homebrew/bin/mem_reaper.py',
  ];

  /// `python3` the app shells out to for `--confirm-gui`, matched to the
  /// interpreter the plist itself declares.
  static String? interpreter({String? fromPlist}) {
    if (fromPlist != null && File(fromPlist).existsSync()) return fromPlist;
    for (final candidate in const [
      '/usr/bin/python3',
      '/usr/local/bin/python3',
      '/opt/homebrew/bin/python3',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// The `toolshed-fand` helper.
  ///
  /// The installed copy is listed first so the app reads the SMC with the same
  /// binary the LaunchDaemon runs: two versions of the protocol on one machine
  /// would mean the app interpreting a reply it did not ask for. The copy inside
  /// the bundle is next, which is what makes an installed app work on a machine
  /// with no checkout; the build tree is the developer's fallback, not a
  /// requirement.
  static String? fanHelperPath({String? executable}) {
    for (final candidate in fandCandidates(executable: executable)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> fandCandidates({String? executable}) => [
    '/usr/local/bin/toolshed-fand',
    ?bundled('toolshed-fand', executable: executable),
    '$home/Project/toolshed/build/fanctl/toolshed-fand',
    'build/fanctl/toolshed-fand',
    '/opt/homebrew/bin/toolshed-fand',
  ];

  /// What an install should copy, which is not what the app should *read*.
  ///
  /// Reading prefers the installed binary so the console speaks the protocol of
  /// the daemon that is answering. Installing has the opposite interest: the copy
  /// inside the app is the one the app was built and tested with, and preferring
  /// an already-installed leftover would reinstall last year's helper forever.
  /// This is the order that lets an update actually reach the hardware.
  static String? fanInstallSourcePath({String? executable}) {
    for (final candidate in fanInstallCandidates(executable: executable)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> fanInstallCandidates({String? executable}) => [
    ?bundled('toolshed-fand', executable: executable),
    '/usr/local/bin/toolshed-fand',
    '$home/Project/toolshed/build/fanctl/toolshed-fand',
    'build/fanctl/toolshed-fand',
    '/opt/homebrew/bin/toolshed-fand',
  ];

  /// The fan policy the user last saved. Deliberately in the user's library and
  /// not in the daemon's: the file is what the user asked for, the daemon's
  /// memory is what is actually running, and only the second one needs root.
  static File get fanPolicyFile =>
      File('$home/Library/Application Support/toolshed/fan_policy.json');

  /// `~/Library/Application Support/toolshed` — the one directory every toolshed
  /// agent reads its state from, so the lock list, the passphrase hash and the
  /// fan policy live side by side and one backup covers all three.
  static Directory get appSupport =>
      Directory('$home/Library/Application Support/toolshed');

  /// The `toolshed-lockd` helper the *agent* runs: a copy in the app-support
  /// directory rather than the build tree, because a LaunchAgent that points at
  /// `~/Project/toolshed/build/...` stops working the moment the checkout moves
  /// or gets deleted, and an app lock that silently stopped enforcing is worse
  /// than one that was never installed.
  static String get lockAgentBinary => '${appSupport.path}/toolshed-lockd';

  static File get appLockConfigFile => File('${appSupport.path}/app_lock.json');

  static String get lockLogPath => '$home/Library/Logs/toolshed-lockd.log';

  /// The helper the *console* runs for `list`/`status`/`grant`.
  ///
  /// The installed copy wins, for the same reason the fan client prefers it: two
  /// binaries with different protocol versions on one machine means the app
  /// interpreting a reply it did not ask for. After it comes the copy the app
  /// bundle ships, so an installed toolshed can install its agent without a
  /// checkout; the build tree is only a developer's convenience.
  static String? lockHelperPath({String? executable}) {
    for (final candidate in lockHelperCandidates(executable: executable)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> lockHelperCandidates({String? executable}) => [
    lockAgentBinary,
    ?bundled('toolshed-lockd', executable: executable),
    '$home/Project/toolshed/build/lockd/toolshed-lockd',
    'build/lockd/toolshed-lockd',
    '/usr/local/bin/toolshed-lockd',
  ];

  /// What an install should copy: the app's own helper, for the reason the fan
  /// installer gives. Preferring the copy already in Application Support would
  /// mean a reinstall installs the binary the previous install left behind, and
  /// an agent could never be updated by updating the app.
  static String? lockInstallSourcePath({String? executable}) {
    for (final candidate in lockInstallCandidates(executable: executable)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> lockInstallCandidates({String? executable}) => [
    ?bundled('toolshed-lockd', executable: executable),
    lockAgentBinary,
    '$home/Project/toolshed/build/lockd/toolshed-lockd',
    'build/lockd/toolshed-lockd',
    '/usr/local/bin/toolshed-lockd',
  ];

  static int? uid() {
    // `id -u` because dart:io does not expose it and the launchd domain is
    // addressed as gui/<uid>.
    final result = Process.runSync('id', ['-u']);
    if (result.exitCode != 0) return null;
    return int.tryParse('${result.stdout}'.trim());
  }
}
