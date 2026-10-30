import '../models/agent_status.dart';
import '../models/tool_config.dart';
import '../models/tool_descriptor.dart';
import '../models/tool_exception.dart';
import 'app_lock/lock_agent.dart';
import 'fan_ctl/fan_daemon.dart';
import 'fan_ctl/fan_policy.dart';
import 'fan_ctl/fan_telemetry.dart';
import 'mem_reaper/managed_app.dart';
import 'mem_reaper/stop_outcome.dart';
import 'port_warden/port_listener.dart';

/// One tool, as the console sees it.
///
/// The app holds no kill logic of its own. `PROTECTED_NAMES`, the ancestor walk
/// and the respawn guard live in mem_reaper.py; a second copy in Dart would
/// drift and could log the user out of their session. The same rule holds for
/// fan control: the decision law lives in the daemon, not here.
abstract class ToolBackend {
  ToolDescriptor get descriptor;

  Capabilities get capabilities;

  Future<AgentStatus> status();

  /// `launchctl bootstrap` / `bootout`. Stop is bootout and never a kill: the
  /// agent's plist has KeepAlive, so killing the pid just respawns it after
  /// ThrottleInterval and looks like a button that does nothing.
  Future<void> start();

  Future<void> stop();

  /// File presence in `~/Library/LaunchAgents`. Only used when the plist is
  /// missing — the app manages the agent that already exists rather than
  /// installing a second label, which would mean two dialogs per memory hog.
  Future<void> install();

  Future<void> uninstall();

  /// The settings as they are now — for a daemon-backed tool that means the
  /// live policy when the daemon has one, and the saved intent otherwise.
  Future<ToolConfig> readConfig();

  /// Must leave the agent running with the new values applied, not just rewrite
  /// the file on disk.
  Future<void> writeConfig(ToolConfig config);

  Stream<String> tailLog();
}

/// A backend whose settings are one concrete shape.
///
/// [ToolBackend] is deliberately not generic: two tools with two type
/// parameters would push the choice into every caller, including the registry
/// that holds a list of mixed backends. So the interface takes any [ToolConfig]
/// and each backend narrows here, with a message that says what happened rather
/// than a cast failure inside a shell command.
T expectConfig<T extends ToolConfig>(ToolConfig config, String toolName) {
  if (config is! T) {
    throw ToolException(
      'WRONG_CONFIG',
      'Those are not $toolName settings, so nothing was written.',
      detail: 'expected $T, got ${config.runtimeType}',
    );
  }
  return config;
}

/// Backends that can stop one of your processes on request.
///
/// Split out from [ProcessReaper] because freeing a port needs the stop and
/// nothing else: the rules about what is safe to stop are the same either way,
/// and both run them in mem_reaper.py.
abstract class ProcessStopper {
  /// Stops [app] now. The caller has already confirmed with the user; the
  /// protection rules still run in mem_reaper.py, and its verdict is returned.
  /// [immediate] skips the polite SIGTERM and goes straight to SIGKILL.
  Future<StopOutcome> stopProcess(ManagedApp app, {bool immediate = false});
}

/// Backends that can also run a full memory scan.
abstract class ProcessReaper implements ProcessStopper {
  /// One-shot scan that confirms through mem_reaper's own modal.
  Future<void> reapNow();
}

/// Backends that can list the ports the OS reports as listening.
abstract class PortInspector {
  Future<List<PortListener>> listening();
}

/// Backends that drive a fan: read the hardware, and hold or release it.
///
/// The three reads need no privilege; the two writes only work through the root
/// daemon, which is why they are `Future<void>` here and the daemon's own answer
/// is what [ToolBackend.status] reports.
abstract class FanControl {
  Future<FanTelemetry> telemetry();

  /// What *this* process may do — measured by running `selftest`, never
  /// assumed from a table of Mac models.
  Future<FanPrivilegeReport> privileges();

  /// The daemon's live state, or null when it is not reachable.
  Future<FanDaemonStatus?> daemonStatus();

  /// What the daemon answers about its own privileges, which is the only
  /// answer that means anything for a write.
  Future<FanPrivilegeReport?> daemonPrivileges();

  Future<void> engage(FanPolicy policy);

  Future<void> releaseControl();
}

/// Backends that gate apps behind a passphrase.
///
/// Everything here is a call to `toolshed-lockd`: the console lists apps, hands
/// over a passphrase and reads back yes or no, but the rule that closes a window
/// belongs to the agent. That split is the whole point — a rule the app could
/// change would not be a lock the app could not talk itself out of.
abstract class AppLockGuard {
  /// Every app the helper can see, installed or running, with its lock state.
  Future<List<LockableApp>> installedApps();

  /// What the helper says about the passphrase, the config and the watcher.
  Future<LockAgentInfo> lockStatus();

  Future<void> setPassphrase(String passphrase);

  Future<bool> verifyPassphrase(String passphrase);

  /// Proves the passphrase and opens [bundleId] for the configured window.
  /// Null means the passphrase was wrong.
  Future<Allowance?> unlock(String bundleId, String passphrase);

  Future<void> revokeUnlock(String bundleId);

  /// Asks (or forces) one app to quit now. False when it was not running.
  Future<bool> closeApp(String bundleId, {bool force = false});

  /// Raises the agent's own dialog, so the console can check that a passphrase
  /// the user typed actually opens something before they rely on it.
  Future<bool> testPrompt(String bundleId, {String? name, int? timeoutSeconds});
}

/// Backends that can list what is eating memory on this device.
///
/// Implemented by both platforms, but the numbers mean different things: macOS
/// sets [ManagedApp.liveBytes] (true footprint), Android only sets
/// [ManagedApp.aggregateBytes] and [ManagedApp.share] (a usage-stats total over
/// a window). The ranking screen renders whichever fields are present.
abstract class MemoryRanking {
  Future<List<ManagedApp>> ranked({int windowDays = 7, int limit = 100});
}

/// The Android-only extras: the usage-access gate and the system-page jumps.
///
/// Split out from [ToolBackend] so the macOS backend never has to implement
/// methods that cannot mean anything on a desktop.
abstract class PhoneMemorySource implements MemoryRanking {
  Future<PhoneMemory> phoneMemory();

  Future<void> requestUsageAccess();

  /// Jumps to the system App-info page. Android will not let another app call
  /// Force stop, so this is as far as the phone path goes.
  Future<void> openAppInfo(String packageName);

  Future<List<int>?> appIcon(String packageName, {int sizePx = 96});
}

class PhoneMemory {
  const PhoneMemory({
    required this.usageAccessGranted,
    required this.ramTotalBytes,
    required this.ramAvailableBytes,
    required this.retentionStartMillis,
    required this.retentionEndMillis,
  });

  final bool usageAccessGranted;

  /// Live device totals from /proc/meminfo — permission-free, unlike
  /// ActivityManager.getMemoryInfo (deprecated at API 34).
  final int ramTotalBytes;
  final int ramAvailableBytes;

  /// How far back usage history goes, so a 30-day window on a phone with 3 days
  /// of history can say so instead of showing near-zero numbers.
  final int retentionStartMillis;
  final int retentionEndMillis;

  int get retentionDays =>
      ((retentionEndMillis - retentionStartMillis) / (24 * 60 * 60 * 1000))
          .floor();

  /// Effective largest window the history can actually fill.
  int usableWindow(int days) {
    if (retentionDays <= 0) return days;
    return days > retentionDays ? retentionDays : days;
  }
}
