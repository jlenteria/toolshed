import 'dart:io';

import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/paths.dart';
import '../../platform/runner.dart';
import '../tool_backend.dart';
import 'cache_locations.dart';
import 'sweep_parsers.dart';
import 'sweep_target.dart';
import 'trash_linux.dart';

/// Finds disposable build caches and moves the chosen ones to the platform
/// Trash.
///
/// Two rules are enforced below the UI, not just in it. Only a directory the
/// scan itself produced may be moved — a known cache path or a `node_modules`
/// found under a project root — and every path must be a real directory that
/// resolves strictly inside the user's home. The Trash makes a mistake
/// recoverable, but the more useful property is that the mistake cannot be
/// made by a stale or malformed target.
abstract class _DevSweeperBackend implements ToolBackend, CacheSweeper {
  _DevSweeperBackend({
    ProcessRunner? runner,
    String? homeOverride,
    Map<String, String>? environment,
  }) : runner = runner ?? const ProcessRunner(),
       home = homeOverride ?? Paths.home,
       environment = environment ?? Platform.environment;

  final ProcessRunner runner;
  final String home;
  final Map<String, String> environment;

  String get scanner;
  String get pathSeparator;
  List<CacheLocation> get cacheLocations;
  List<String> get projectRoots;

  @override
  Future<AgentStatus> status() async =>
      const AgentStatus.notApplicable().withNotes([
        'Scans on demand with $scanner: nothing is installed and nothing runs '
            'in the background.',
      ]);

  @override
  Future<void> start() async => _noAgent('start');

  @override
  Future<void> stop() async => _noAgent('stop');

  @override
  Future<void> install() async => _noAgent('install');

  @override
  Future<void> uninstall() async => _noAgent('uninstall');

  @override
  Future<ToolConfig> readConfig() async => throw const ToolException(
    'NO_SETTINGS',
    'Dev Sweeper has no settings: the cache list is measured fresh each time.',
  );

  @override
  Future<void> writeConfig(ToolConfig config) async =>
      throw const ToolException(
        'NO_SETTINGS',
        'Dev Sweeper has nothing to configure.',
      );

  @override
  Stream<String> tailLog() => Stream<String>.error(
    const ToolException(
      'NO_LOG',
      'Dev Sweeper has no agent, so there is no log to follow.',
    ),
  );

  Never _noAgent(String what) => throw ToolException(
    'NO_AGENT',
    'Dev Sweeper has no background agent to $what.',
  );

  @override
  Future<SweepReport> scanCaches() async {
    final notes = <String>[];
    final locations = [
      for (final location in cacheLocations)
        if (Directory(location.path).existsSync()) location,
    ];
    final modules = await findNodeModules(notes);
    final candidates = <(String, String, String)>[
      for (final location in locations)
        (location.path, location.label, location.ecosystem),
      for (final path in modules) (path, _moduleLabel(path), 'Node'),
    ];
    final sizes = candidates.isEmpty
        ? const <String, int>{}
        : await measure([
            for (final candidate in candidates) candidate.$1,
          ], notes);
    final targets = [
      for (final (path, label, ecosystem) in candidates)
        SweepTarget(
          path: path,
          label: label,
          ecosystem: ecosystem,
          bytes: sizes[path],
        ),
    ]..sort(compareSweepTargets);

    if (targets.isEmpty) {
      notes.add('No build caches were found in the places this tool looks.');
    }
    notes.add(
      'Only build caches and node_modules are listed. Project sources, Xcode '
      'archives and simulator devices are never touched.',
    );
    return SweepReport(targets, notes: notes);
  }

  /// Adds a note for each path `du` did not report, so an unmeasured cache is
  /// visible rather than silently shown as empty.
  Future<Map<String, int>> measure(
    List<String> paths,
    List<String> notes,
  ) async {
    final result = await runner.run('du', [
      '-sk',
      ...paths,
    ], timeout: const Duration(minutes: 2));
    final sizes = parseDuSizes(result.stdout);
    if (sizes.isEmpty && !result.ok) {
      notes.add(
        'Sizes could not be measured${result.blurb.isEmpty ? '' : ': ${result.blurb}'}.',
      );
    } else if (sizes.length < paths.length) {
      final missing = paths.length - sizes.length;
      notes.add(
        '$missing ${missing == 1 ? 'directory' : 'directories'} could not be '
        'measured; ${missing == 1 ? 'its size is' : 'their sizes are'} shown '
        'as unknown.',
      );
    }
    return sizes;
  }

  Future<List<String>> findNodeModules(List<String> notes) async {
    final found = <String>[];
    final seen = <String>{};
    for (final root in projectRoots) {
      if (!Directory(root).existsSync()) continue;
      try {
        final result = await runner.run('find', [
          root,
          '-maxdepth',
          '6',
          '-type',
          'd',
          '-name',
          'node_modules',
          '-prune',
          '-print',
        ], timeout: const Duration(seconds: 30));
        if (!result.ok) {
          notes.add(
            'Could not search $root for node_modules'
            '${result.blurb.isEmpty ? '' : ': ${result.blurb}'}.',
          );
          continue;
        }
        for (final path in parseFoundPaths(result.stdout)) {
          if (seen.add(path)) found.add(path);
        }
      } on ToolException {
        notes.add(
          'Searching $root for node_modules took too long and stopped.',
        );
      }
    }
    return found;
  }

  @override
  Future<SweepOutcome> trashCaches(List<SweepTarget> targets) async {
    final trashed = <SweepTarget>[];
    final failures = <SweepFailure>[];
    for (final target in targets) {
      final refusal = _refusal(target);
      if (refusal != null) {
        failures.add(SweepFailure(target: target, message: refusal));
        continue;
      }
      try {
        await trashOne(target);
        trashed.add(target);
      } on ToolException catch (error) {
        failures.add(SweepFailure(target: target, message: error.message));
      } on FileSystemException catch (error) {
        failures.add(
          SweepFailure(
            target: target,
            message: error.message.isEmpty
                ? 'The move failed.'
                : 'The move failed: ${error.message}',
          ),
        );
      }
    }
    return SweepOutcome(
      trashed: trashed,
      failures: failures,
      freedBytes: trashed.fold(0, (sum, item) => sum + (item.bytes ?? 0)),
    );
  }

  /// The checks the screen cannot be trusted with, run again immediately before
  /// the move.
  String? _refusal(SweepTarget target) {
    if (!_isAllowlisted(target.path)) {
      return 'It was not part of the scan, so it was left alone.';
    }
    if (target.path == home) {
      return 'Refusing to move your home directory.';
    }
    final type = FileSystemEntity.typeSync(target.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      return 'It is a symbolic link, so only the link would move.';
    }
    if (type != FileSystemEntityType.directory) {
      return 'It is no longer a directory, so it was left alone.';
    }
    try {
      final canonicalHome = Directory(home).resolveSymbolicLinksSync();
      final canonical = Directory(target.path).resolveSymbolicLinksSync();
      final prefix = canonicalHome.endsWith(pathSeparator)
          ? canonicalHome
          : '$canonicalHome$pathSeparator';
      if (!canonical.startsWith(prefix)) {
        return 'It resolves outside your home directory, so it was left alone.';
      }
    } on FileSystemException {
      return 'Its path could not be resolved, so it was left alone.';
    }
    return null;
  }

  bool _isAllowlisted(String path) {
    if (path.split(pathSeparator).last == 'node_modules') return true;
    return cacheLocations.any((location) => location.path == path);
  }

  String _moduleLabel(String path) {
    final prefix = home.endsWith(pathSeparator) ? home : '$home$pathSeparator';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  /// The platform's own move to the Trash. Throws [ToolException] with the
  /// tool's real message when it fails.
  Future<void> trashOne(SweepTarget target);
}

/// The macOS Trash is `NSFileManager.trashItemAtURL:`, which records where the
/// item came from so Finder's Put Back works. Finder's AppleScript `delete`
/// would ask for Automation permission and move files one dialog at a time.
const String _macTrashScript = r'''
ObjC.import("Foundation");
function run(argv) {
  var fm = $.NSFileManager.defaultManager;
  var url = $.NSURL.fileURLWithPath(argv[0]);
  var err = $();
  if (!fm.trashItemAtURLResultingItemURLError(url, $(), err)) {
    throw new Error(err.localizedDescription.js);
  }
}
''';

class MacDevSweeperBackend extends _DevSweeperBackend {
  MacDevSweeperBackend({super.runner, super.homeOverride, super.environment});

  @override
  String get scanner => 'du and find';

  @override
  String get pathSeparator => '/';

  @override
  List<CacheLocation> get cacheLocations => macCacheLocations(home: home);

  @override
  List<String> get projectRoots => unixProjectRoots(home);

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kDevSweeperId,
    name: 'Dev Sweeper',
    summary:
        'Finds the build caches and node_modules taking up space, and moves '
        'the ones you pick to the Trash.',
    implPath: 'du · find · Trash',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.showCaches, ToolAction.trashCaches},
    reason:
        'Measures the known cache directories with du and finds project '
        'node_modules with find. Removing moves the selected directories to '
        'the Trash, where they stay recoverable until you empty it.',
  );

  @override
  Future<void> trashOne(SweepTarget target) async {
    final result = await runner.run('osascript', [
      '-l',
      'JavaScript',
      '-e',
      _macTrashScript,
      target.path,
    ], timeout: const Duration(minutes: 2));
    if (!result.ok) {
      throw ToolException(
        'TRASH_FAILED',
        result.blurb.isEmpty
            ? 'osascript exited with code ${result.exitCode}.'
            : result.blurb,
      );
    }
  }
}

class LinuxDevSweeperBackend extends _DevSweeperBackend {
  LinuxDevSweeperBackend({
    super.runner,
    super.homeOverride,
    super.environment,
    this.dataHomeOverride,
  });

  final String? dataHomeOverride;

  FreedesktopTrash get _trash => FreedesktopTrash(
    dataHome:
        dataHomeOverride ??
        (environment['XDG_DATA_HOME'] ?? '$home/.local/share'),
  );

  @override
  String get scanner => 'du and find';

  @override
  String get pathSeparator => '/';

  @override
  List<CacheLocation> get cacheLocations =>
      linuxCacheLocations(home: home, environment: environment);

  @override
  List<String> get projectRoots => unixProjectRoots(home);

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kDevSweeperId,
    name: 'Dev Sweeper',
    summary:
        'Finds the build caches and node_modules taking up space, and moves '
        'the ones you pick to the Trash.',
    implPath: 'du · find · freedesktop trash',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.showCaches, ToolAction.trashCaches},
    reason:
        'Measures the known cache directories with du and finds project '
        'node_modules with find. Removing follows the freedesktop Trash spec, '
        'so the directories can be restored from your file manager.',
  );

  @override
  Future<void> trashOne(SweepTarget target) => _trash.move(target.path);
}

class WindowsDevSweeperBackend extends _DevSweeperBackend {
  WindowsDevSweeperBackend({
    super.runner,
    super.homeOverride,
    super.environment,
  });

  @override
  String get scanner => 'PowerShell';

  @override
  String get pathSeparator => '\\';

  @override
  List<CacheLocation> get cacheLocations =>
      windowsCacheLocations(home: home, environment: environment);

  @override
  List<String> get projectRoots => windowsProjectRoots(home);

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: kDevSweeperId,
    name: 'Dev Sweeper',
    summary:
        'Finds the build caches and node_modules taking up space, and moves '
        'the ones you pick to the Recycle Bin.',
    implPath: 'PowerShell · Recycle Bin',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.showCaches, ToolAction.trashCaches},
    reason:
        'Measures the known cache directories with PowerShell and finds '
        'project node_modules the same way. Removing uses the Windows Recycle '
        'Bin, so a wrong pick can be restored.',
  );

  @override
  Future<Map<String, int>> measure(
    List<String> paths,
    List<String> notes,
  ) async {
    final quoted = paths.map((path) => "'${_psQuote(path)}'").join(',');
    final script =
        '''
\$paths = @($quoted)
foreach (\$p in \$paths) {
  \$sum = (Get-ChildItem -LiteralPath \$p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if (\$null -eq \$sum) { \$sum = 0 }
  Write-Output ("{0}`t{1}" -f \$p, [int64]\$sum)
}
''';
    final result = await runner.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ], timeout: const Duration(minutes: 5));
    final sizes = parsePathSizes(result.stdout);
    if (sizes.isEmpty && !result.ok) {
      notes.add(
        'Sizes could not be measured${result.blurb.isEmpty ? '' : ': ${result.blurb}'}.',
      );
    } else if (sizes.length < paths.length) {
      final missing = paths.length - sizes.length;
      notes.add(
        '$missing ${missing == 1 ? 'directory' : 'directories'} could not be '
        'measured; ${missing == 1 ? 'its size is' : 'their sizes are'} shown '
        'as unknown.',
      );
    }
    return sizes;
  }

  @override
  Future<List<String>> findNodeModules(List<String> notes) async {
    final found = <String>[];
    final seen = <String>{};
    for (final root in projectRoots) {
      if (!Directory(root).existsSync()) continue;
      try {
        final result = await runner.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Get-ChildItem -LiteralPath '${_psQuote(root)}' -Directory "
              '-Recurse -Depth 6 -Filter node_modules '
              '-ErrorAction SilentlyContinue | '
              'Select-Object -ExpandProperty FullName',
        ], timeout: const Duration(seconds: 45));
        if (!result.ok) {
          notes.add(
            'Could not search $root for node_modules'
            '${result.blurb.isEmpty ? '' : ': ${result.blurb}'}.',
          );
          continue;
        }
        for (final path in parseFoundPaths(result.stdout)) {
          if (seen.add(path)) found.add(path);
        }
      } on ToolException {
        notes.add(
          'Searching $root for node_modules took too long and stopped.',
        );
      }
    }
    return found;
  }

  @override
  Future<void> trashOne(SweepTarget target) async {
    final script =
        'Add-Type -AssemblyName Microsoft.VisualBasic; '
        '[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory('
        "'${_psQuote(target.path)}', 'OnlyErrorDialogs', 'SendToRecycleBin')";
    final result = await runner.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ], timeout: const Duration(minutes: 2));
    if (!result.ok) {
      throw ToolException(
        'TRASH_FAILED',
        result.blurb.isEmpty
            ? 'PowerShell exited with code ${result.exitCode}.'
            : result.blurb,
      );
    }
  }

  /// PowerShell single-quoted strings are literal; the only escape is a
  /// doubled quote.
  static String _psQuote(String value) => value.replaceAll("'", "''");
}
