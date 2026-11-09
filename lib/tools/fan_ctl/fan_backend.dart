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
import 'daemon_client.dart';
import 'daemon_install.dart';
import 'fan_daemon.dart';
import 'fan_policy.dart';
import 'fan_telemetry.dart';

/// macOS fan control: read the SMC as the user, write it through the daemon.
///
/// The split is not a design preference, it is what the machine allows —
/// `IOConnectCallStructMethod` returns `kIOReturnNotPrivileged` for a fan write
/// from any uid but 0, which was measured on this Mac rather than assumed. So
/// this class holds no control law: it moves a policy to the daemon, reports
/// what the daemon says it is doing, and never claims a fan is spinning that it
/// did not see in `F0Ac`.
class MacOSFanBackend implements ToolBackend, FanControl {
  MacOSFanBackend({
    ProcessRunner? runner,
    String? helperPath,
    FanDaemonInstaller? installer,
    File? policyFile,
    String? socketPath,
  }) : _runner = runner ?? const ProcessRunner(),
       _requestedHelper = helperPath,
       _installer = installer ?? FanDaemonInstaller(runner: runner),
       _policyFile = policyFile ?? Paths.fanPolicyFile,
       _socket = socketPath;

  final ProcessRunner _runner;
  final String? _requestedHelper;
  final FanDaemonInstaller _installer;
  final File _policyFile;
  final String? _socket;

  /// Only for a helper found by discovery, so an unbuild checkout says so in
  /// every method rather than crashing on a null path.
  FanDaemonClient? _client;

  String? _notice;

  /// The policy this process is holding the fan with, null when it is not.
  ///
  /// The renewal timer reads this field instead of capturing a policy argument,
  /// so a second engage replaces the numbers rather than starting a second timer
  /// that keeps re-applying the first ones. That race is what made a save look
  /// like it had done nothing: the old timer wrote its own policy back within
  /// half a lease.
  FanPolicy? _active;
  Timer? _renewal;

  @override
  ToolDescriptor get descriptor => ToolDescriptor(
    id: 'fan_ctl',
    name: 'Fan Control',
    summary:
        'Holds every fan at a speed you set, and hands them back to macOS when '
        'you let go.',
    implPath: helperPath ?? 'macos/fanctl/main.swift',
  );

  /// The `toolshed-fand` binary this console is talking to, installed copy
  /// first. Null means the helper has not been built, which every capability
  /// below turns into a reason rather than a dead button.
  String? get helperPath => _requestedHelper ?? Paths.fanHelperPath();

  /// What an install copies: the binary this app carries, so that updating the
  /// app updates the daemon instead of reinstalling whatever the last install
  /// left in `/usr/local/bin`. A helper named for this backend still wins — a
  /// console pointed at one binary must install that one.
  String? get _installSource =>
      _requestedHelper ?? Paths.fanInstallSourcePath() ?? helperPath;

  FanDaemonClient get _daemon {
    final path = helperPath;
    if (path == null) {
      throw const ToolException(
        'NO_HELPER',
        'The fan helper has not been built, so there is nothing to read or '
            'write.',
        detail: 'make fanctl   # swiftc -O macos/fanctl/main.swift',
      );
    }
    return _client ??= FanDaemonClient(
      binaryPath: path,
      runner: _runner,
      socketPath: _socket,
    );
  }

  @override
  Capabilities get capabilities {
    // Which actions exist depends on what is installed *now*: offering Engage
    // before the root daemon exists would be a button that can only fail.
    final actions = <ToolAction>{
      if (helperPath != null) ...[
        ToolAction.configure,
        ToolAction.showSensors,
        ToolAction.tailLogs,
        if (_installer.isInstalled) ...[
          ToolAction.start,
          ToolAction.stop,
          ToolAction.update,
          ToolAction.uninstall,
          ToolAction.engage,
          ToolAction.releaseControl,
        ] else
          ToolAction.install,
      ],
    };
    return Capabilities(
      support: switch ((helperPath != null, _installer.isInstalled)) {
        (false, _) => Support.helperMissing,
        // The OS is what caps it here: reads need no privilege, and a fan write
        // from an unprivileged uid is refused by the kernel until the daemon
        // that runs as root is installed.
        (true, false) => Support.cappedByOs,
        (true, true) => Support.full,
      },
      actions: actions,
      reason: helperPath == null
          ? 'Reading the SMC and forcing a fan speed needs the native helper, '
                'and no binary was found. Build it with `make fanctl`.'
          : !_installer.isInstalled
          ? 'Temperature readings work already. Taking control needs the root '
                'daemon installed, because a fan write from your own uid '
                'returns kIOReturnNotPrivileged.'
          : 'Fan control runs natively on macOS.',
    );
  }

  // --------------------------------------------------------------------- reads

  @override
  Future<FanTelemetry> telemetry() => _daemon.telemetry();

  @override
  Future<FanPrivilegeReport> privileges() => _daemon.privileges();

  @override
  Future<FanDaemonStatus?> daemonStatus() => _daemon.daemonStatus();

  @override
  Future<FanPrivilegeReport?> daemonPrivileges() => _daemon.daemonPrivileges();

  // -------------------------------------------------------------------- status

  @override
  Future<AgentStatus> status() async {
    if (helperPath == null) {
      return const AgentStatus(
        state: AgentState.notInstalled,
        notes: [
          'toolshed-fand is not built. Run `make fanctl`, then install the '
              'daemon from this screen.',
        ],
      );
    }
    // A ping is the only liveness test that means anything: it asks the process
    // that owns the fan whether it is there, instead of trusting a launchd
    // database entry for a daemon that may have refused to come up.
    final live = await _daemon.daemonStatus();
    if (live != null) {
      return AgentStatus(
        state: AgentState.running,
        pid: live.pid,
        runs: live.ticks,
        plistPath: FanDaemonPaths.plist,
        logPath: FanDaemonPaths.log,
        notes: [
          'uid ${live.uid}${live.isRoot ? ' (root)' : ' (not root)'}',
          live.reason,
          if (live.appliedRpm != null)
            'holding at ${live.appliedRpm!.toStringAsFixed(0)} rpm',
          if (live.lastError != null) 'last error: ${live.lastError}',
          ?_notice,
        ],
      );
    }
    return AgentStatus(
      state: _installer.isInstalled
          ? AgentState.installedStopped
          : AgentState.notInstalled,
      plistPath: _installer.plistPresent ? FanDaemonPaths.plist : null,
      logPath: File(FanDaemonPaths.log).existsSync()
          ? FanDaemonPaths.log
          : null,
      notes: [
        if (_installer.isInstalled)
          'The daemon is not answering on '
              '${_socket ?? FanDaemonPaths.socket}. It may have refused to '
              'start because this Mac will not let even root write fan speeds — '
              'read ${FanDaemonPaths.log} or ${FanDaemonPaths.launchdLog}.'
        else
          'Not installed. Readings are available now; installing adds control.',
        ?_notice,
      ],
    );
  }

  // ------------------------------------------------------------------- control

  /// Sends the manual hold. The switch is the only state this puts on the wire,
  /// so being asked to engage a policy that is not holding is a bug in the
  /// console rather than something to argue with — and a success message about a
  /// fan that never spun is the one answer this backend must never give.
  @override
  Future<void> engage(FanPolicy policy) async {
    if (!policy.manualOn) {
      throw const ToolException(
        'NOT_A_HOLD',
        'The manual switch is off, so there is nothing to engage. Turn '
            '"Fan manual ON" on.',
      );
    }
    final reason = _refusal(policy);
    if (reason != null) throw ToolException('INVALID_POLICY', reason);
    await _writePolicyFile(policy);
    final FanDaemonStatus? status;
    try {
      status = await _daemon.apply(policy);
    } on ToolException catch (failure) {
      // One refusal means something specific. A daemon installed before this
      // cut-down cannot decode three keys it has never seen, and answers with a
      // complaint about the request's shape rather than about the fan — which is
      // the sign to update the helper, not the sign to edit a number.
      if (failure.message.contains('not a toolshed-fand request')) {
        throw const ToolException(
          'DAEMON_TOO_OLD',
          'The installed fan daemon does not understand this request, so it '
              'predates this app.',
          detail:
              'Press "Update daemon" to put this app\'s helper in its place.',
        );
      }
      rethrow;
    }
    _active = policy;
    _startRenewal();
    _notice = status == null
        ? 'The hold was sent but the daemon did not answer.'
        : null;
  }

  @override
  Future<void> releaseControl() async {
    // Off means off, and the local half runs before the daemon is asked: if
    // the daemon cannot be reached, a still-running renewal would keep
    // re-applying the hold forever — the one outcome 'turn off' must not have.
    // Without renewals the daemon's own lease expires and the fans go back to
    // Apple on their own, so releasing locally first is what still hands them
    // back when nothing confirms the release.
    _active = null;
    _stopRenewal();
    try {
      await _daemon.clear();
    } finally {
      // "Released" and "a policy that pins the fans again at the next launchd
      // reload" cannot both be true — not even when the daemon did not answer.
      final saved = await _readPolicyFile();
      await _writePolicyFile(saved.copyWith(manualOn: false));
    }
  }

  /// The lease is what keeps a hold honest: it expires unless the app that asked
  /// for it keeps renewing. So renewing is the app's job while it is open, and
  /// the reason the hold does not outlive a crash.
  void _startRenewal() {
    _stopRenewal();
    final policy = _active;
    if (policy == null || policy.leaseSeconds <= 0) return;
    final every = Duration(
      seconds: (policy.leaseSeconds / 2).ceil().clamp(1, 3600),
    );
    _renewal = Timer.periodic(every, (_) async {
      final current = _active;
      if (current == null) return;
      // Re-apply, not ping: only `apply` moves the renewal timestamp in the
      // daemon, and a reply we cannot read must not look like a renewal.
      await _daemon.tryRequest('apply', policy: current);
    });
  }

  void _stopRenewal() {
    _renewal?.cancel();
    _renewal = null;
  }

  /// Stops holding on this side. The daemon keeps whatever it was told until its
  /// lease expires or someone releases it — closing the app must not be the only
  /// way to let go of a fan that has leaseSeconds of 0.
  void dispose() {
    _active = null;
    _stopRenewal();
  }

  @override
  Future<void> start() async {
    await _installer.start();
    if (!await _waitUntilListening()) {
      throw const ToolException(
        'DAEMON_QUIET',
        'launchd reports the daemon loaded, but it never answered on the '
            'socket.',
        detail: 'read ${FanDaemonPaths.log} and ${FanDaemonPaths.launchdLog}',
      );
    }
  }

  @override
  Future<void> stop() async {
    // Release before unloading: bootout sends SIGTERM, and while the daemon's
    // handler does hand the fan back, a stop that also proves the fan is free is
    // a stop the user can see.
    final live = await _daemon.daemonStatus();
    if (live != null && live.isHolding) {
      await _daemon.clear();
    }
    _active = null;
    _stopRenewal();
    await _installer.stop();
  }

  @override
  Future<void> install() async {
    final helper = _installSource;
    if (helper == null) {
      throw const ToolException(
        'NO_HELPER',
        'There is no toolshed-fand binary to install. Build it with '
            '`make fanctl` first.',
      );
    }
    await _installer.install(sourceBinary: helper);
    if (!await _waitUntilListening()) {
      throw const ToolException(
        'DAEMON_QUIET',
        'The daemon was installed but never answered on the socket, so fan '
            'writes are not available on this Mac.',
        detail: 'read ${FanDaemonPaths.log} and ${FanDaemonPaths.launchdLog}',
      );
    }
  }

  @override
  Future<void> uninstall() async {
    _active = null;
    _stopRenewal();
    await _installer.uninstall();
    final kept = _installer.lastBackup;
    if (kept != null) _notice = 'The plist was kept at $kept.';
  }

  /// The daemon unlinks the socket when it exits, so a reachable socket is proof
  /// of a live process — but bootstrap and kickstart are asynchronous, hence the
  /// short wait rather than a single attempt.
  Future<bool> _waitUntilListening() async {
    for (var attempt = 0; attempt < 12; attempt++) {
      if (await _daemon.tryRequest('ping') != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  // ------------------------------------------------------------------- settings

  @override
  Future<ToolConfig> readConfig() async {
    // Live first, but only while the live policy is in force: while a lease is
    // running the daemon is the thing driving the fan, and the file behind it
    // describes a setting that is not in effect. Once nothing is armed, the file
    // is what the user last saved, and showing the leftovers of a released hold
    // would quietly undo their edits at the next launch.
    final live = await _daemon.daemonStatus();
    final armed = live?.isArmed ?? false;
    if (armed && live!.policy != null) return live.policy!;
    return _readPolicyFile();
  }

  /// "Save without engaging" means exactly that: the file is written and the
  /// hardware is not touched.
  ///
  /// It used to apply the policy whenever `enabled` was set, which meant the two
  /// buttons did the same thing and a save could be undone seconds later by the
  /// renewal timer of an earlier engage. A hold now only ever starts at Engage,
  /// so the console can say which of the two the numbers on screen describe.
  @override
  Future<void> writeConfig(ToolConfig config) async {
    final policy = expectConfig<FanPolicy>(config, 'fan control');
    final reason = _refusal(policy);
    if (reason != null) {
      throw ToolException('INVALID_POLICY', reason);
    }
    await _writePolicyFile(policy);
    _notice = null;
  }

  /// The one place the app checks the policy, so a bad number is refused before
  /// it reaches a root process that would otherwise clamp it quietly.
  static String? _refusal(FanPolicy policy) {
    final problems = policy.problems;
    if (problems.isEmpty) return null;
    return 'Those settings were not sent to the daemon:\n'
        '${problems.join('\n')}';
  }

  Future<FanPolicy> _readPolicyFile() async {
    final file = _policyFile;
    if (!file.existsSync()) return FanPolicy.defaults;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return FanPolicy.fromJson(
        decoded is Map ? Map<String, Object?>.from(decoded) : null,
      );
    } on FormatException {
      // A half-written file is a reason to fall back, not to refuse to show
      // anything: the defaults are what the daemon would use with no policy.
      return FanPolicy.defaults;
    }
  }

  Future<void> _writePolicyFile(FanPolicy policy) async {
    await _policyFile.parent.create(recursive: true);
    // Write-and-rename would be the textbook answer; File.writeAsString truncates
    // in place, which is fine here because only this app reads the file and the
    // daemon never does.
    await _policyFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(policy.toJson())}\n',
    );
  }

  // ----------------------------------------------------------------------- log

  @override
  Stream<String> tailLog() async* {
    final file = File(FanDaemonPaths.log);
    if (!file.existsSync()) {
      throw ToolException(
        'LOG_NOT_CREATED',
        'No log at ${file.path} yet — it appears once the daemon has written '
            'something.',
        detail: _installer.isInstalled
            ? 'The daemon is installed; start it to get a first line.'
            : 'The daemon is not installed.',
      );
    }
    // Opened once here so a permission problem is reported as a reason rather
    // than as a stream that produced nothing and then died.
    try {
      file.openSync(mode: FileMode.read).closeSync();
    } on FileSystemException catch (e) {
      throw ToolException(
        'LOG_UNREADABLE',
        'The daemon log exists but this user cannot read it: '
            '${e.osError?.message ?? e.message}',
        detail: file.path,
      );
    }
    yield* tailAppendedLines(file.path);
  }
}
