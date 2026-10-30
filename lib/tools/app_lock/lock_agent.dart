import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/tool_exception.dart';
import '../../platform/paths.dart';
import '../../platform/runner.dart';
import 'app_lock_config.dart';

/// One app the helper says exists on this Mac.
///
/// A direct mapping of the `list` reply, including the fields the console uses to
/// decide whether a row is a checkbox or a caption: [lockable] false means the
/// helper refuses to close it whatever the config says, and [whyNotLockable] is
/// the sentence that explains why.
class LockableApp {
  const LockableApp({
    required this.bundleId,
    required this.name,
    required this.path,
    this.running = false,
    this.pid,
    this.locked = false,
    this.lockable = true,
    this.whyNotLockable,
    this.unlockedUntil,
  });

  final String bundleId;
  final String name;
  final String path;
  final bool running;
  final int? pid;
  final bool locked;
  final bool lockable;
  final String? whyNotLockable;

  /// Epoch seconds, when the app's idle window ends. A focused app keeps
  /// pushing this forward, so it measures time away rather than time since the
  /// passphrase.
  final double? unlockedUntil;

  bool get isGuarded => !lockable;

  Duration? remaining(DateTime now) {
    final until = unlockedUntil;
    if (until == null) return null;
    final ends = DateTime.fromMillisecondsSinceEpoch((until * 1000).round());
    final left = ends.difference(now);
    return left.isNegative ? null : left;
  }

  LockedApp asLocked() => LockedApp(
    bundleId: bundleId,
    name: name,
    path: path,
    armedAt: DateTime.now().millisecondsSinceEpoch / 1000.0,
  );

  static LockableApp fromJson(Map<String, Object?> json) => LockableApp(
    bundleId: '${json['bundleId'] ?? ''}',
    name: '${json['name'] ?? ''}',
    path: '${json['path'] ?? ''}',
    running: json['running'] as bool? ?? false,
    pid: (json['pid'] as num?)?.toInt(),
    locked: json['locked'] as bool? ?? false,
    lockable: json['lockable'] as bool? ?? true,
    whyNotLockable: json['whyNotLockable'] as String?,
    unlockedUntil: (json['unlockedUntil'] as num?)?.toDouble(),
  );
}

/// An app that is allowed open until its idle window runs out. Written by
/// `grant` and by the agent's own prompt, read by the console.
class Allowance {
  const Allowance({
    required this.bundleId,
    required this.expiresAt,
    required this.grantedBy,
  });

  final String bundleId;

  /// Epoch seconds. Moved forward while the app is in front, so the deadline
  /// only stands still while the app is in the background.
  final double expiresAt;

  /// `console` or `dialog`, which is how the screen can say who let this one open.
  final String grantedBy;

  DateTime get expiry =>
      DateTime.fromMillisecondsSinceEpoch((expiresAt * 1000).round());

  bool isExpired(DateTime now) => expiry.isBefore(now);

  Duration remaining(DateTime now) {
    final left = expiry.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  static Allowance fromJson(Map<String, Object?> json) => Allowance(
    bundleId: '${json['bundleId'] ?? ''}',
    expiresAt: (json['expiresAt'] as num?)?.toDouble() ?? 0,
    grantedBy: '${json['grantedBy'] ?? ''}',
  );
}

/// One thing the agent did, newest last. The state file keeps the last 50; the
/// helper hands back the last 20.
class LockEvent {
  const LockEvent({
    required this.at,
    required this.bundleId,
    required this.action,
    required this.detail,
  });

  final double at;
  final String bundleId;

  /// `closed`, `unlocked`, `refused`, `revoked`, `opened`, `timeout`.
  final String action;
  final String detail;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch((at * 1000).round());

  static LockEvent fromJson(Map<String, Object?> json) => LockEvent(
    at: (json['at'] as num?)?.toDouble() ?? 0,
    bundleId: '${json['bundleId'] ?? ''}',
    action: '${json['action'] ?? ''}',
    detail: '${json['detail'] ?? ''}',
  );
}

/// What the helper knows about itself and the lock, from one `status` call.
class LockAgentInfo {
  const LockAgentInfo({
    required this.uid,
    required this.store,
    required this.watching,
    required this.watchPid,
    required this.passphraseSet,
    required this.iterations,
    required this.passphraseSetAt,
    required this.configPresent,
    required this.enabled,
    required this.unlockMinutes,
    required this.forceQuit,
    required this.lockedCount,
    required this.running,
    required this.unlocks,
    required this.events,
  });

  final int uid;
  final String store;

  /// A `watch` process is running for this user. Without it nothing gets closed:
  /// the config file alone is a list of intentions.
  final bool watching;
  final int watchPid;

  final bool passphraseSet;

  /// PBKDF2 rounds the stored hash used, so the console can say what the lock is
  /// actually made of rather than repeating a number from this file.
  final int iterations;
  final double passphraseSetAt;

  final bool configPresent;
  final bool enabled;
  final int unlockMinutes;
  final bool forceQuit;
  final int lockedCount;

  /// Locked apps that are open right now, which is the list a watch would be
  /// closing if it were running.
  final List<LockableApp> running;
  final List<Allowance> unlocks;
  final List<LockEvent> events;

  /// The one state that means the lock is real: something named in the list,
  /// a passphrase to open it with, and a watcher to enforce the rule.
  bool get isEnforcing =>
      watching && passphraseSet && enabled && lockedCount > 0;

  String get gap {
    if (!passphraseSet) {
      return 'No passphrase is set, so nothing can be opened again.';
    }
    if (lockedCount == 0) return 'Nothing is in the lock list yet.';
    if (!enabled) return 'The lock is switched off.';
    if (!watching) {
      return 'The watch agent is not running, so locked apps stay open.';
    }
    return '';
  }

  static LockAgentInfo fromJson(Map<String, Object?> json) {
    Map<String, Object?> section(Object? key) {
      final value = json[key];
      return value is Map ? Map<String, Object?>.from(value) : const {};
    }

    List<Map<String, Object?>> rows(Object? key) {
      final value = json[key];
      if (value is! List) return const [];
      return [
        for (final row in value)
          if (row is Map) Map<String, Object?>.from(row),
      ];
    }

    final secret = section('secret');
    final config = section('config');
    return LockAgentInfo(
      uid: (json['uid'] as num?)?.toInt() ?? 0,
      store: '${json['store'] ?? ''}',
      watching: json['watching'] as bool? ?? false,
      watchPid: (json['watchPid'] as num?)?.toInt() ?? 0,
      passphraseSet: secret['set'] as bool? ?? false,
      iterations: (secret['iterations'] as num?)?.toInt() ?? 0,
      passphraseSetAt: (secret['setAt'] as num?)?.toDouble() ?? 0,
      configPresent: config['present'] as bool? ?? false,
      enabled: config['enabled'] as bool? ?? false,
      unlockMinutes: (config['unlockMinutes'] as num?)?.toInt() ?? 0,
      forceQuit: config['forceQuit'] as bool? ?? false,
      lockedCount: (config['lockedCount'] as num?)?.toInt() ?? 0,
      running: [for (final row in rows('running')) LockableApp.fromJson(row)],
      unlocks: [for (final row in rows('unlocks')) Allowance.fromJson(row)],
      events: [for (final row in rows('events')) LockEvent.fromJson(row)],
    );
  }
}

/// Talks to `toolshed-lockd`, one process per call.
///
/// Every verb prints one JSON line and exits, which is the same shape the fan
/// client uses and the reason there is no socket here: the helper holds no state
/// worth keeping a connection open for, and a per-user agent that died would
/// leave the console talking to nothing.
///
/// The passphrase is only ever written to stdin. It is never an argument — `ps`
/// shows argv to every process on the machine — and it never comes back: `verify`
/// and `grant` answer yes or no.
class LockAgentClient {
  LockAgentClient({
    required this.helperPath,
    ProcessRunner? runner,
    String? storeDir,
  }) : _runner = runner ?? const ProcessRunner(),
       _store = storeDir;

  final String helperPath;
  final ProcessRunner _runner;

  /// Redirects every verb at a scratch directory, which is what lets a test
  /// exercise the real helper without touching the user's lock list.
  final String? _store;

  List<String> get _storeArgs {
    final store = _store;
    return store == null ? const [] : ['--store', store];
  }

  /// Every app the helper can see, installed or running.
  Future<List<LockableApp>> installedApps() async {
    final reply = await _call(['list', ..._storeArgs]);
    final apps = reply['apps'];
    if (apps is! List) {
      throw const ToolException(
        'BAD_REPLY',
        'The lock helper answered `list` without an app list.',
      );
    }
    return [
      for (final app in apps)
        if (app is Map) LockableApp.fromJson(Map<String, Object?>.from(app)),
    ];
  }

  Future<LockAgentInfo> status() async {
    final reply = await _call(['status', ..._storeArgs]);
    final status = reply['status'];
    if (status is! Map) {
      throw const ToolException(
        'BAD_REPLY',
        'The lock helper answered `status` without a status.',
      );
    }
    return LockAgentInfo.fromJson(Map<String, Object?>.from(status));
  }

  Future<bool> hasPassphrase() async {
    final reply = await _call(['haspass', ..._storeArgs]);
    return reply['set'] as bool? ?? false;
  }

  Future<void> setPassphrase(String passphrase) async {
    _checkLength(passphrase);
    await _callWithStdin(['setpass', ..._storeArgs], passphrase);
  }

  /// Yes when the passphrase matches, no when it does not, and a throw only when
  /// the check could not be made at all. Exit code 2 is the helper's "wrong".
  Future<bool> verifyPassphrase(String passphrase) async {
    _checkLength(passphrase);
    final result = await _runner.runWithStdin(helperPath, [
      'verify',
      ..._storeArgs,
    ], passphrase);
    if (result.exitCode != 0 && result.exitCode != 2) {
      throw _failure(result);
    }
    final reply = _decode(result.stdout);
    return reply['verified'] as bool? ?? false;
  }

  /// Opens one app for [minutes], proving the passphrase first.
  ///
  /// Returns the allowance, or null when the passphrase was wrong. A wrong answer
  /// is recorded in the state file by the helper itself, so the console does not
  /// have to keep its own count of guesses.
  Future<Allowance?> grant(
    String bundleId,
    String passphrase, {
    int? minutes,
  }) async {
    if (bundleId.trim().isEmpty) {
      throw const ToolException('NO_BUNDLE', 'Nothing was named to unlock.');
    }
    final args = ['grant', ..._storeArgs, '--bundle', bundleId];
    if (minutes != null) args.addAll(['--minutes', '$minutes']);
    final result = await _runner.runWithStdin(helperPath, args, passphrase);
    if (result.exitCode != 0 && result.exitCode != 2) {
      throw _failure(result);
    }
    final reply = _decode(result.stdout);
    if (reply['granted'] != true) return null;
    return Allowance(
      bundleId: bundleId,
      expiresAt: (reply['expiresAt'] as num?)?.toDouble() ?? 0,
      grantedBy: 'console',
    );
  }

  /// Drops an allowance, so a locked app goes back on the next tick rather than
  /// when its idle window happens to run out.
  Future<void> revoke(String bundleId) async {
    await _call(['revoke', ..._storeArgs, '--bundle', bundleId]);
  }

  /// Asks one app to quit now, without waiting for the watcher to notice.
  /// Returns false when it was not running.
  Future<bool> closeNow(String bundleId, {bool force = false}) async {
    final args = ['close', ..._storeArgs, '--bundle', bundleId];
    if (force) args.add('--force');
    final reply = await _call(args);
    return reply['closed'] as bool? ?? false;
  }

  /// Raises the helper's own passphrase dialog. Used by the console's "test the
  /// prompt" button, and the only verb that puts a window on the screen.
  Future<bool> showPrompt(
    String bundleId, {
    String? name,
    int? timeoutSeconds,
  }) async {
    final args = ['prompt', ..._storeArgs, '--bundle', bundleId];
    if (name != null) args.addAll(['--name', name]);
    if (timeoutSeconds != null) {
      args.addAll(['--timeout', '$timeoutSeconds']);
    }
    final reply = await _call(args, timeout: const Duration(minutes: 2));
    return reply['opened'] as bool? ?? false;
  }

  void _checkLength(String passphrase) {
    if (passphrase.length < minPassLength) {
      throw const ToolException(
        'PASSPHRASE_TOO_SHORT',
        'A passphrase under $minPassLength characters is decoration, not a '
            'lock.',
      );
    }
    if (passphrase.length > _maxPassLength) {
      throw const ToolException(
        'PASSPHRASE_TOO_LONG',
        'That is too long to be a passphrase.',
      );
    }
  }

  /// The helper's two lengths, mirrored so a bad one is refused here rather than
  /// after a dialog the user has already filled in. The helper still checks.
  ///
  /// The floor is public because the console renders it in the field's hint: a
  /// screen that says four while the helper refuses at eight is a dialog arguing
  /// with itself, and two literals drift the moment one of them is edited.
  static const int minPassLength = 8;
  static const int _maxPassLength = 512;

  Future<Map<String, Object?>> _call(
    List<String> args, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final result = await _runner.run(helperPath, args, timeout: timeout);
    if (!result.ok) throw _failure(result);
    return _decode(result.stdout);
  }

  Future<Map<String, Object?>> _callWithStdin(
    List<String> args,
    String stdin, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final result = await _runner.runWithStdin(
      helperPath,
      args,
      stdin,
      timeout: timeout,
    );
    if (!result.ok) throw _failure(result);
    return _decode(result.stdout);
  }

  Map<String, Object?> _decode(String stdout) {
    final line = stdout
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (line.isEmpty) {
      throw const ToolException(
        'NO_REPLY',
        'The lock helper exited without saying anything.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw ToolException(
        'BAD_REPLY',
        'The lock helper said something that is not a reply.',
        detail: line,
      );
    }
    if (decoded is! Map) {
      throw ToolException('BAD_REPLY', 'Unexpected reply: $line');
    }
    final reply = Map<String, Object?>.from(decoded);
    if (reply['ok'] == false) {
      throw ToolException(
        'LOCKD_FAILED',
        '${reply['error'] ?? 'the lock helper refused'}',
      );
    }
    return reply;
  }

  ToolException _failure(ProcResult result) => ToolException(
    'LOCKD_FAILED',
    result.blurb.isEmpty
        ? 'toolshed-lockd exited with code ${result.exitCode} and said nothing.'
        : result.blurb,
    detail: 'exit code: ${result.exitCode}\nhelper: $helperPath',
  );
}

/// The LaunchAgent that does the enforcing, and the copy of the helper it runs.
///
/// Per-user and unprivileged on purpose: closing an app in someone else's
/// session needs root and would be a different, worse tool. `~/Library
/// /LaunchAgents` is written by this user and read by their own launchd, so
/// installing needs no password prompt at all.
class LockAgentInstaller {
  LockAgentInstaller({ProcessRunner? runner, String? homeOverride})
    : _runner = runner ?? const ProcessRunner(),
      _home = homeOverride;

  static const String label = 'com.bling.toolshed.lockd';

  final ProcessRunner _runner;
  final String? _home;

  String get _homePath => _home ?? Paths.home;

  String get _plistPath => '$_agentsDir/$label.plist';

  /// Where the agent's plist is, for the status screen to name.
  String get plistPath => _plistPath;

  String get _agentsDir => '$_homePath/Library/LaunchAgents';

  /// Where launchd sends the watcher's own stdout/stderr, which is also where the
  /// helper appends its log lines.
  String get logPath => _home == null
      ? Paths.lockLogPath
      : '$_homePath/Library/Logs/toolshed-lockd.log';

  /// The copy of the helper the agent runs, in the same directory as the lock
  /// list. With a home override the whole layout moves, which is what lets a test
  /// install an agent without touching the real one.
  String get _copiedBinary => _home == null
      ? Paths.lockAgentBinary
      : '$_home/Library/Application Support/toolshed/toolshed-lockd';

  bool get plistPresent => File(_plistPath).existsSync();

  bool get binaryPresent => File(_copiedBinary).existsSync();

  bool get isInstalled => plistPresent && binaryPresent;

  /// Is a watch already loaded, by this app or by a plist someone wrote by hand?
  /// Found by reading the plists rather than trusting the label, the same way the
  /// mem_reaper backend discovers its agent, so a renamed plist is managed rather
  /// than duplicated.
  Future<String?> findPlist() async {
    final dir = Directory(_agentsDir);
    if (!dir.existsSync()) return null;
    final plists =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.plist'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in plists) {
      final argv = await _argvOf(file.path);
      if (argv.any((a) => a.contains('toolshed-lockd'))) return file.path;
    }
    return null;
  }

  Future<List<String>> _argvOf(String plistPath) async {
    final result = await _runner.run('plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      plistPath,
    ]);
    if (!result.ok) return const [];
    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! Map) return const [];
      final args = decoded['ProgramArguments'];
      return args is List ? [for (final a in args) '$a'] : const [];
    } on FormatException {
      return const [];
    }
  }

  /// Copies the helper next to the lock list, writes the plist, lints it, and
  /// bootstraps it.
  ///
  /// The copy is the point: a LaunchAgent aimed at a build directory stops
  /// working the day that directory is moved, and an app lock that quietly
  /// stopped enforcing looks exactly like an app lock that is working.
  Future<void> install({required String sourceBinary}) async {
    if (!File(sourceBinary).existsSync()) {
      throw ToolException(
        'NO_HELPER',
        'There is no toolshed-lockd at $sourceBinary to install.',
        detail: 'Build it with `make lockd`.',
      );
    }
    // Refuse to hand launchd a binary that fails its own decision table: the
    // one mistake a self-starting agent cannot take back.
    final check = await _runner.run(sourceBinary, ['selfcheck']);
    if (!check.ok) {
      throw ToolException(
        'HELPER_UNSOUND',
        'Refused to install a lock helper that did not pass its own selfcheck.',
        detail: 'binary: $sourceBinary\n${check.blurb}',
      );
    }

    final existing = await findPlist();
    if (existing != null && existing != _plistPath) {
      throw ToolException(
        'ALREADY_INSTALLED',
        'A lock agent is already installed at $existing. Start or stop that one '
            '— the app will not add a second, because two watchers would each '
            'raise their own dialog for one launch.',
      );
    }

    final store = Directory(_copiedBinary).parent;
    if (!store.existsSync()) store.createSync(recursive: true);
    // A loaded watcher keeps the binary it bootstrapped with mapped, so copying
    // a new helper over it would change the file and not the process — and the
    // bootstrap at the end would be refused as already loaded. Booting the old
    // one out first is what makes an update reach the agent. This also covers
    // the Stop/Start pair: stop() tolerates a service that was never loaded.
    await stop();
    // The app's own helper is what gets copied, unless there is no bundle to copy
    // from and the installed copy is being reinstalled where it already is.
    // Copying a file onto itself is how a binary ends up zero bytes long.
    final source = File(sourceBinary).absolute.path;
    if (source != File(_copiedBinary).absolute.path) {
      await File(sourceBinary).copy(_copiedBinary);
    }
    // The copy inherits the source mode, but a LaunchAgent that could not exec
    // its own binary would fail in launchd's log rather than here.
    await _runner.run('chmod', ['0755', _copiedBinary]);

    final logParent = Directory(File(logPath).parent.path);
    if (!logParent.existsSync()) logParent.createSync(recursive: true);

    final file = File(_plistPath);
    if (file.existsSync()) {
      final kept = await _backup(file.path, 'replaced');
      _notice = 'The plist that was there is kept at $kept.';
    }
    await file.writeAsString(
      plistTemplate(binary: _copiedBinary, logPath: logPath),
    );

    final lint = await _runner.run('plutil', ['-lint', file.path]);
    if (!lint.ok) {
      await file.delete();
      throw ToolException(
        'PLIST_INVALID',
        'The plist this app wrote did not pass plutil -lint, so it was deleted '
            'rather than handed to launchd.',
        detail: lint.blurb,
      );
    }
    await start();
  }

  String? _notice;

  String? takeNotice() {
    final value = _notice;
    _notice = null;
    return value;
  }

  Future<void> start() async {
    final plist = await findPlist();
    if (plist == null) {
      throw ToolException(
        'NOT_INSTALLED',
        'There is no lock agent in $_agentsDir to start, so nothing would close '
            'a locked app.',
      );
    }
    final uid = await _uid();
    final result = await _runner.run('launchctl', [
      'bootstrap',
      'gui/$uid',
      plist,
    ]);
    if (!result.ok && !result.blurb.toLowerCase().contains('already')) {
      throw ToolException(
        'BOOTSTRAP_FAILED',
        result.blurb.isEmpty ? 'launchctl bootstrap failed.' : result.blurb,
        detail:
            'command: launchctl bootstrap gui/$uid $plist\n'
            'exit code: ${result.exitCode}',
      );
    }
    await _expectRunning(uid);
  }

  /// bootout rather than a kill: the plist has KeepAlive, so a killed watcher is
  /// respawned by launchd and the button would look broken.
  Future<void> stop() async {
    final uid = await _uid();
    final result = await _runner.run('launchctl', [
      'bootout',
      'gui/$uid/$label',
    ]);
    if (!result.ok && !_alreadyGone(result)) {
      throw ToolException(
        'BOOTOUT_FAILED',
        result.blurb,
        detail:
            'command: launchctl bootout gui/$uid/$label\n'
            'exit code: ${result.exitCode}',
      );
    }
  }

  Future<void> uninstall() async {
    final uid = await _uid();
    await _runner.run('launchctl', ['bootout', 'gui/$uid/$label']);
    final plist = await findPlist();
    if (plist != null) {
      final kept = await _backup(plist, 'uninstalled');
      _notice = 'The agent was unloaded and its plist kept at $kept.';
    }
  }

  Future<String> _backup(String path, String tag) async {
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final target = '$path.$tag-$stamp';
    await File(path).copy(target);
    if (tag == 'uninstalled') await File(path).delete();
    return target;
  }

  Future<void> _expectRunning(int uid) async {
    var last = 'launchctl print returned nothing useful.';
    for (var attempt = 0; attempt < 10; attempt++) {
      final result = await _runner.run('launchctl', [
        'print',
        'gui/$uid/$label',
      ]);
      if (result.ok) {
        final text = result.stdout;
        if (text.contains('pid = ') && text.contains('state = running')) return;
        last = 'exit: ${result.exitCode}';
      } else {
        last = result.blurb;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw ToolException(
      'NOT_RUNNING_AFTER_CHANGE',
      'The agent was submitted but never reached `state = running` within 5s.',
      detail: 'target: gui/$uid/$label\nlast seen: $last',
    );
  }

  Future<int> _uid() async {
    final result = await _runner.run('id', ['-u']);
    final uid = int.tryParse(result.stdout.trim());
    if (uid == null) {
      throw const ToolException(
        'NO_UID',
        'Could not determine your uid, so the app cannot address the launchd gui '
            'domain.',
      );
    }
    return uid;
  }

  static bool _alreadyGone(ProcResult result) {
    final text = result.blurb.toLowerCase();
    return result.exitCode == 3 ||
        text.contains('no such service') ||
        text.contains('not found') ||
        text.contains('already unloaded');
  }

  /// The agent's whole command line is `watch`: it reads the lock list, the
  /// passphrase and its allowances from the app-support directory, so changing any
  /// of them needs no reload, and no re-bootstrap.
  static String plistTemplate({
    required String binary,
    required String logPath,
  }) =>
      '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>$label</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>${_esc(binary)}</string>
\t\t<string>watch</string>
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
\t<string>${_esc(logPath)}</string>
\t<key>StandardErrorPath</key>
\t<string>${_esc(logPath)}</string>
</dict>
</plist>
''';

  static String _esc(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
