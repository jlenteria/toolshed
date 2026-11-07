import 'fan_policy.dart';
import 'fan_telemetry.dart';

/// What the daemon is doing right now — the only account of the hardware that
/// comes from the process which actually writes to it.
///
/// Mirrors `Reply.Status` in `macos/fanctl/main.swift`. Nothing is decided here,
/// so the reason string below is the daemon's own sentence about why it acted,
/// not a guess made in the UI about hardware it cannot touch.
class FanDaemonStatus {
  const FanDaemonStatus({
    required this.pid,
    required this.uid,
    required this.isRoot,
    required this.fans,
    required this.applied,
    required this.appliedRpm,
    required this.reason,
    required this.lastError,
    required this.policy,
    required this.leaseExpiresAt,
    required this.startedAt,
    required this.ticks,
  });

  final int pid;
  final int uid;

  /// False only for a developer instance started with
  /// `TOOLSHED_FAND_ALLOW_UNPRIVILEGED`; a real daemon that is not root cannot
  /// have come up at all.
  final bool isRoot;
  final List<FanReading> fans;

  /// `automatic`, `holding`, or `not configured`.
  final String applied;
  final double? appliedRpm;

  /// The daemon's own sentence about why it is in this state. The UI shows this
  /// instead of re-deriving a reason the decision-maker already gave.
  final String reason;
  final String? lastError;
  final FanPolicy? policy;
  final DateTime? leaseExpiresAt;
  final DateTime startedAt;
  final int ticks;

  bool get isHolding => applied == 'holding';

  /// A hold is in force either while a fan is being held or while the lease that
  /// would let it be held still has time to run. With the switch off and no lease
  /// there is nothing armed, and the file behind the daemon is what the console
  /// should show instead of a leftover hold.
  bool get isArmed => isHolding || leaseExpiresAt != null;

  bool get leaseRunningOut {
    final expires = leaseExpiresAt;
    if (expires == null) return false;
    return expires.difference(DateTime.now()).inSeconds <= 10;
  }

  factory FanDaemonStatus.fromJson(Map<String, Object?> json) {
    final expires = (json['leaseExpiresAt'] as num?)?.toInt();
    final started = (json['startedAt'] as num?)?.toInt() ?? 0;
    final policy = json['policy'];
    return FanDaemonStatus(
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      uid: (json['uid'] as num?)?.toInt() ?? -1,
      isRoot: json['isRoot'] == true,
      fans: [
        for (final fan in jsonMaps(json['fans'])) FanReading.fromJson(fan),
      ],
      applied: json['applied'] as String? ?? 'unknown',
      appliedRpm: (json['appliedRpm'] as num?)?.toDouble(),
      reason: json['reason'] as String? ?? 'the daemon said nothing',
      lastError: json['lastError'] as String?,
      policy: policy is Map
          ? FanPolicy.fromJson(Map<String, Object?>.from(policy))
          : null,
      leaseExpiresAt: expires == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expires * 1000),
      startedAt: DateTime.fromMillisecondsSinceEpoch(started * 1000),
      ticks: (json['ticks'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `SelfTestReport` — what one process measured about its own privileges.
///
/// Two of these exist per run: the app's, as the logged-in user, and the
/// daemon's, as root. The app shows both, because the honest answer to "does
/// fan control work here" is a measurement and the two answers differ.
class FanPrivilegeReport {
  const FanPrivilegeReport({
    required this.uid,
    required this.isRoot,
    required this.canOpenSmc,
    required this.fanCount,
    required this.fans,
    required this.sensorCount,
    required this.hottest,
    required this.modeKey,
    required this.writeAccepted,
    required this.writeDetail,
    required this.verdict,
  });

  final int uid;
  final bool isRoot;
  final bool canOpenSmc;
  final int fanCount;
  final List<FanReading> fans;
  final int sensorCount;
  final TemperatureSensor? hottest;

  /// Which spelling of the mode key this Mac answers to, discovered rather than
  /// assumed.
  final String modeKey;

  /// Null when there was nothing to test — no SMC, or no fan to write to.
  final bool? writeAccepted;
  final String? writeDetail;
  final String verdict;

  bool get canControlFans => writeAccepted == true;

  factory FanPrivilegeReport.fromJson(Map<String, Object?> json) {
    final hottest = json['hottest'];
    return FanPrivilegeReport(
      uid: (json['uid'] as num?)?.toInt() ?? -1,
      isRoot: json['isRoot'] == true,
      canOpenSmc: json['canOpenSmc'] == true,
      fanCount: (json['fanCount'] as num?)?.toInt() ?? 0,
      fans: [
        for (final fan in jsonMaps(json['fans'])) FanReading.fromJson(fan),
      ],
      sensorCount: (json['sensorCount'] as num?)?.toInt() ?? 0,
      hottest: hottest is Map
          ? TemperatureSensor.fromJson(Map<String, Object?>.from(hottest))
          : null,
      modeKey: json['modeKey'] as String? ?? 'F0Md',
      writeAccepted: json['writeAccepted'] as bool?,
      writeDetail: json['writeDetail'] as String?,
      verdict: json['verdict'] as String? ?? 'no verdict',
    );
  }
}
