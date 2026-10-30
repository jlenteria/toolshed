import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/log_tail.dart';
import '../../platform/paths.dart';
import '../../platform/runner.dart';
import '../tool_backend.dart';
import 'app_lock_config.dart';
import 'lock_agent.dart';

/// macOS app locking, driven through `toolshed-lockd`.
///
/// This class holds no lock logic. It reads and writes one JSON file, hands a
/// passphrase to a short-lived helper on stdin, and reports whether a watcher is
/// alive. The rule that closes a window, the guard list that refuses to close
/// Finder, and the hash comparison are all in the helper — which is the point:
/// the app that *asks* to be let in cannot be the app that decides.
class MacAppLockBackend implements ToolBackend, AppLockGuard {
  MacAppLockBackend({
    ProcessRunner? runner,
    String? helperPath,
    LockAgentInstaller? installer,
    File? configFile,
    String? storeDir,
    String? homeOverride,
  }) : _runner = runner ?? const ProcessRunner(),
       _requestedHelper = helperPath,
       _installer =
           installer ??
           LockAgentInstaller(runner: runner, homeOverride: homeOverride),
       _configFile = configFile ?? Paths.appLockConfigFile,
       _store = storeDir;

  final ProcessRunner _runner;
  final String? _requestedHelper;
  final LockAgentInstaller _installer;
  final File _configFile;

  /// Sent to the helper as `--store`, so a test can run the real binary against a
  /// scratch copy of the lock list.
  final String? _store;

  LockAgentClient? _client;
  String? _notice;

  @override
  ToolDescriptor get descriptor => ToolDescriptor(
    id: 'app_lock',
    name: 'App Lock',
    summary:
        'Watches the apps on your lock list and closes them when they are '
        'launched, and again once they have been idle for the unlock window, '
        'until you type the passphrase.',
    implPath: helperPath ?? 'macos/lockd/main.swift',
  );

  /// The `toolshed-lockd` this console talks to: the installed copy first, so the
  /// console and the agent speak one version of the protocol.
  ///
  /// A path that is not there is reported as no helper at all. Every button on
  /// the screen is gated on this getter, and one that is drawn because a string
  /// was passed in — pointing nowhere — would be a promise to close an app with
  /// nothing to close it with.
  String? get helperPath {
    final requested = _requestedHelper;
    if (requested == null) return Paths.lockHelperPath();
    return File(requested).existsSync() ? requested : null;
  }

  /// What an install copies: the helper this app carries, so that updating
  /// toolshed updates the agent rather than reinstalling the copy the previous
  /// install left in Application Support. A helper named for this backend still
  /// wins, because a console pointed at one binary installs that one.
  String? get _installSource {
    final requested = _requestedHelper;
    if (requested != null) {
      return File(requested).existsSync() ? requested : null;
    }
    final inApp = Paths.lockInstallSourcePath();
    if (inApp != null) return inApp;
    return helperPath;
  }

  LockAgentClient get _helper {
    final path = helperPath;
    if (path == null) {
      throw const ToolException(
        'NO_HELPER',
        'There is no toolshed-lockd binary, so there is nothing to list, to '
            'check or to close with.',
        detail: 'make lockd   # swiftc -O macos/lockd/main.swift',
      );
    }
    return _client ??= LockAgentClient(
      helperPath: path,
      runner: _runner,
      storeDir: _store,
    );
  }

  @override
  Capabilities get capabilities {
    // The list of apps, the passphrase and a `close` right now all work from the
    // helper alone. What needs the agent is the watching, so the actions are
    // gated on what is installed and never on what would be nice.
    if (helperPath == null) {
      return const Capabilities(
        support: Support.helperMissing,
        actions: {},
        reason:
            'App lock is enforced by the native toolshed-lockd helper, and no '
            'binary was found. Build it with `make lockd`.',
      );
    }
    final installed = _installer.isInstalled;
    return Capabilities(
      support: Support.full,
      actions: <ToolAction>{
        ToolAction.configure,
        ToolAction.setPassphrase,
        ToolAction.unlockApp,
        ToolAction.closeApp,
        ToolAction.tailLogs,
        if (installed) ...[
          ToolAction.start,
          ToolAction.stop,
          ToolAction.update,
          ToolAction.uninstall,
        ] else
          ToolAction.install,
      },
      reason: installed
          ? 'App lock runs natively on macOS as your own user: no administrator '
                'password, because the agent only ever touches apps in your own '
                'session.'
          : 'Everything on this screen works already. Installing the watch agent '
                'is what makes the lock stay locked after the first launch.',
    );
  }

  // -------------------------------------------------------------------- status

  @override
  Future<AgentStatus> status() async {
    if (helperPath == null) {
      return const AgentStatus(
        state: AgentState.notInstalled,
        notes: [
          'toolshed-lockd is not built. Run `make lockd`, then install the agent '
              'from this screen.',
        ],
      );
    }
    final info = await _helper.status();
    final state = switch ((info.watching, _installer.isInstalled)) {
      (true, _) => AgentState.running,
      (false, true) => AgentState.installedStopped,
      (false, false) => AgentState.notInstalled,
    };
    return AgentStatus(
      state: state,
      pid: info.watching ? info.watchPid : null,
      plistPath: _installer.plistPresent ? _installer.plistPath : null,
      logPath: File(_installer.logPath).existsSync()
          ? _installer.logPath
          : null,
      notes: [
        if (!info.passphraseSet)
          'No passphrase is set. Until one is, the agent leaves every locked '
              'app alone rather than closing it with nothing to reopen it.'
        else
          'Passphrase set · ${info.iterations} PBKDF2 rounds',
        '${info.lockedCount} app(s) on the lock list',
        if (!info.watching && _installer.isInstalled)
          'The agent is installed but not running, so nothing is being closed.',
        if (info.gap.isNotEmpty) info.gap,
        ?_notice,
      ],
    );
  }

  // --------------------------------------------------------------- the helper

  @override
  Future<List<LockableApp>> installedApps() => _helper.installedApps();

  @override
  Future<LockAgentInfo> lockStatus() => _helper.status();

  @override
  Future<void> setPassphrase(String passphrase) =>
      _helper.setPassphrase(passphrase);

  @override
  Future<bool> verifyPassphrase(String passphrase) =>
      _helper.verifyPassphrase(passphrase);

  @override
  Future<Allowance?> unlock(String bundleId, String passphrase) async {
    final config = await readConfig();
    final allowance = await _helper.grant(
      bundleId,
      passphrase,
      minutes: config.unlockMinutes,
    );
    // A wrong passphrase is an answer, not a failure, but it is worth saying
    // which window was offered so the screen can show it after a correct one.
    _notice = allowance == null
        ? 'That passphrase did not match, so nothing was opened.'
        : null;
    return allowance;
  }

  @override
  Future<void> revokeUnlock(String bundleId) => _helper.revoke(bundleId);

  @override
  Future<bool> closeApp(String bundleId, {bool force = false}) =>
      _helper.closeNow(bundleId, force: force);

  @override
  Future<bool> testPrompt(
    String bundleId, {
    String? name,
    int? timeoutSeconds,
  }) =>
      _helper.showPrompt(bundleId, name: name, timeoutSeconds: timeoutSeconds);

  // ---------------------------------------------------------------- start/stop

  @override
  Future<void> install() async {
    final helper = _installSource;
    if (helper == null) {
      throw const ToolException(
        'NO_HELPER',
        'There is no toolshed-lockd binary to install. Build it with '
            '`make lockd` first.',
      );
    }
    await _installer.install(sourceBinary: helper);
    _notice = _installer.takeNotice();
  }

  @override
  Future<void> start() async {
    await _installer.start();
    _notice = _installer.takeNotice();
  }

  /// bootout, not a kill: KeepAlive would respawn a killed watcher within
  /// ThrottleInterval, and a Stop button that is undone ten seconds later is
  /// worse than one that says it stopped.
  @override
  Future<void> stop() async {
    await _installer.stop();
    _notice = _installer.takeNotice();
  }

  @override
  Future<void> uninstall() async {
    await _installer.uninstall();
    _notice = _installer.takeNotice();
  }

  // ------------------------------------------------------------------ settings

  @override
  Future<AppLockConfig> readConfig() async {
    final file = _configFile;
    if (!file.existsSync()) return AppLockConfig.defaults;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return AppLockConfig.fromJson(
        decoded is Map ? Map<String, Object?>.from(decoded) : const {},
      );
    } on FormatException {
      // A half-written file is a reason to fall back to defaults, not to show
      // nothing: the agent reads the same file and would use its own defaults.
      return AppLockConfig.defaults;
    }
  }

  /// Writes the list and leaves the agent alone, deliberately: the watcher
  /// re-reads this file when its modification time changes, within about a
  /// second, so saving needs no reload and none of the open allowances are lost.
  @override
  Future<void> writeConfig(ToolConfig incoming) async {
    final config = expectConfig<AppLockConfig>(incoming, 'app lock');
    if (!config.isValid) {
      throw ToolException(
        'INVALID_CONFIG',
        'Those settings were not written.',
        detail: config.problems.join('\n'),
      );
    }
    await _configFile.parent.create(recursive: true);
    await _configFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(config.toJson())}\n',
    );
    _notice = null;
  }

  // ----------------------------------------------------------------------- log

  @override
  Stream<String> tailLog() async* {
    final path = _installer.logPath;
    if (!File(path).existsSync()) {
      throw ToolException(
        'LOG_NOT_CREATED',
        'No log at $path yet — it appears once the agent has written something.',
        detail: _installer.isInstalled
            ? 'The agent is installed; start it to get a first line.'
            : 'The agent is not installed.',
      );
    }
    try {
      File(path).openSync(mode: FileMode.read).closeSync();
    } on FileSystemException catch (e) {
      throw ToolException(
        'LOG_UNREADABLE',
        'The agent log exists but this user cannot read it: '
            '${e.osError?.message ?? e.message}',
        detail: path,
      );
    }
    yield* tailAppendedLines(path);
  }
}
