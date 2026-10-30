import '../../models/agent_status.dart';
import '../../models/tool_config.dart';
import '../../models/tool_descriptor.dart';
import '../../models/tool_exception.dart';
import '../../platform/channel.dart';
import '../tool_backend.dart';
import 'managed_app.dart';
import 'mem_reaper_config.dart';
import 'stop_outcome.dart';

/// The Android face of the same console entry.
///
/// It is not a port of mem_reaper.py. `top`, `footprint`, `launchctl` and
/// `osascript` do not exist here, and Android 14 restricts
/// `killBackgroundProcesses()` to the caller's own processes while
/// `getRunningAppProcesses()` has returned only the caller's processes since
/// Android 8 — so a phone cannot silently stop a game. What this can do is rank
/// apps by usage and hand each row to the system App-info page.
class AndroidMemReaperBackend
    implements ToolBackend, PhoneMemorySource, ProcessReaper {
  const AndroidMemReaperBackend([this._channel = const MemReaperChannel()]);

  final MemReaperChannel _channel;

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: 'mem_reaper',
    name: 'Memory Reaper',
    summary:
        'Ranks the apps using your phone\'s memory and opens the '
        'system page where you force-stop them.',
    implPath: 'built into this app',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.cappedByOs,
    actions: {
      ToolAction.showRanking,
      ToolAction.openAppInfo,
      ToolAction.requestUsageAccess,
    },
    reason:
        'mem_reaper.py is a macOS tool. On Android the OS does not '
        'allow one app to read other apps\' live memory or stop them, so '
        'this ranks apps by usage history and jumps you to the system '
        'Force Stop page.',
  );

  @override
  Future<AgentStatus> status() async {
    final memory = await phoneMemory();
    return AgentStatus(
      state: AgentState.notApplicable,
      notes: [
        if (!memory.usageAccessGranted)
          'Usage Access is not granted, so there is no per-app memory to show.',
        if (memory.retentionDays <= 1)
          'Only about a day of usage history exists on this device.',
        'Device RAM: ${ManagedApp.formatBytes(memory.ramAvailableBytes)} free of '
            '${ManagedApp.formatBytes(memory.ramTotalBytes)}.',
      ],
    );
  }

  @override
  Future<PhoneMemory> phoneMemory() async {
    final raw = await _channel.status();
    return PhoneMemory(
      usageAccessGranted: raw['usageAccessGranted'] == true,
      ramTotalBytes: _int(raw['ramTotalBytes']),
      ramAvailableBytes: _int(raw['ramAvailableBytes']),
      retentionStartMillis: _int(raw['retentionStartMillis']),
      retentionEndMillis: _int(raw['retentionEndMillis']),
    );
  }

  @override
  Future<List<ManagedApp>> ranked({int windowDays = 7, int limit = 100}) async {
    final memory = await phoneMemory();
    if (!memory.usageAccessGranted) {
      throw const ToolException(
        'USAGE_ACCESS_DENIED',
        'Android will not give any app the per-app usage numbers until you '
            'grant Usage Access. Grant it, then reload.',
      );
    }
    // Clamp to what the device actually retains, so a 30-day window on a phone
    // with 3 days of history is not read as "almost nothing used".
    final days = memory.usableWindow(windowDays);
    final rows = await _channel.rankedApps(windowDays: days, limit: limit);
    return rows.map(_toApp).toList(growable: false);
  }

  ManagedApp _toApp(Map<String, Object?> row) {
    final packageName = '${row['packageName'] ?? ''}';
    final share = row['share'];
    final launchCount = row['launchCount'];
    final lastUsed = _intOrNull(row['lastUsedMillis']);
    return ManagedApp(
      id: packageName,
      // A label is whatever the app's author chose, braces and all. It is
      // carried as a string and never parsed or interpolated into anything the
      // system executes.
      name: '${row['label'] ?? packageName}',
      // No byte figure: a non-rooted phone does not have one. Time and share
      // are the honest numbers, and `liveBytes` stays null forever.
      periodMillis: _intOrNull(row['foregroundMillis']),
      share: share is num ? share.toDouble() : null,
      lastUsedMillis: lastUsed != null && lastUsed > 0 ? lastUsed : null,
      // -1 means the OS does not report it (Android below API 30).
      launchCount: launchCount is num && launchCount.toInt() >= 0
          ? launchCount.toInt()
          : null,
      detail: packageName,
      killMode: KillMode.opensAppInfo,
    );
  }

  @override
  Future<void> requestUsageAccess() async {
    final failure = await _channel.openUsageAccess();
    if (failure != null) {
      throw ToolException(
        'USAGE_SETTINGS_UNAVAILABLE',
        failure,
        detail:
            'Some OEM ROMs remove the Usage Access screen. Turn the '
            'permission on under Settings > Apps > Special app access.',
      );
    }
  }

  @override
  Future<void> openAppInfo(String packageName) async {
    final failure = await _channel.openAppDetails(packageName);
    if (failure != null) {
      throw ToolException(
        'APP_INFO_UNAVAILABLE',
        failure,
        detail: 'package: $packageName',
      );
    }
  }

  @override
  Future<List<int>?> appIcon(String packageName, {int sizePx = 96}) =>
      _channel.appIcon(packageName, sizePx);

  // The rest of the console contract has no meaning on a phone. Each of these
  // throws rather than pretending, so a button that reaches here is a bug the
  // user can report with an exact reason instead of a silent no-op.

  @override
  Future<void> start() => _macOnly('start a background service');

  @override
  Future<void> stop() => _macOnly('stop a background service');

  @override
  Future<void> install() => _macOnly('install a background service');

  @override
  Future<void> uninstall() => _macOnly('uninstall a background service');

  @override
  Future<MemReaperConfig> readConfig() => _macOnly('configure thresholds');

  @override
  Future<void> writeConfig(ToolConfig config) =>
      _macOnly('configure thresholds');

  @override
  Future<void> reapNow() => _macOnly('run a scan that stops processes');

  /// Android will not let one app stop another; rows open App info instead.
  @override
  Future<StopOutcome> stopProcess(ManagedApp app, {bool immediate = false}) =>
      _macOnly('force-stop another app');

  @override
  Stream<String> tailLog() => throw const ToolException(
    'NOT_ON_THIS_OS',
    'There is no agent log: nothing runs in the background on Android.',
  );

  Future<Never> _macOnly(String what) async => throw ToolException(
    'NOT_ON_THIS_OS',
    'Cannot $what on Android. mem_reaper.py drives macOS with launchctl, '
        'and Android has no equivalent that a normal app may use.',
  );

  static int _int(Object? value) => _intOrNull(value) ?? 0;

  static int? _intOrNull(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
