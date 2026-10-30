import '../../models/tool_config.dart';

/// Which family of SMC temperature sensors the policy watches.
///
/// The names are the wire values the daemon understands, and its `families`
/// table was built from `toolshed-fand keys` on a Mac14,7 — see the comment in
/// `macos/fanctl/main.swift`. Ambient (`Ta`) and battery (`TB`) sensors are in
/// `all` but in no named group, because a warm battery is not a CPU signal.
enum FanSensorGroup {
  cpu('cpu', 'CPU package'),
  gpu('gpu', 'GPU'),
  heatSink('heatSink', 'Heat spreaders'),
  all('all', 'Warmest anywhere');

  const FanSensorGroup(this.wireName, this.label);

  final String wireName;
  final String label;

  static FanSensorGroup fromWire(String? name) => values.firstWhere(
    (group) => group.wireName == name,
    orElse: () => all, // an unknown name watches everything, not nothing
  );
}

/// One temperature-triggered fan policy, and the JSON body the daemon reads.
///
/// The field names here are the field names in `Policy` in
/// `macos/fanctl/main.swift`; the two must stay in step, and `fan_protocol_test`
/// pins the shape. The decision itself lives in the daemon and nowhere in Dart —
/// a second implementation in the UI could disagree with the process that
/// actually writes to the hardware, and only one of them is allowed to be wrong.
class FanPolicy implements ToolConfig {
  const FanPolicy({
    this.enabled = true,
    this.fan = 0,
    this.group = FanSensorGroup.cpu,
    this.targetTempC = 70,
    this.holdRpm = 2400,
    this.rampPerDegree = 250,
    this.hysteresisC = 3,
    this.intervalSeconds = 3,
    this.criticalTempC = 95,
    this.leaseSeconds = 30,
  });

  static const int minFanIndex = 0;
  static const int maxFanIndex = 7;
  static const double minTargetTempC = 45;
  static const double maxTargetTempC = 100;
  static const double minHoldRpm = 500;
  static const double maxHoldRpm = 9000;
  static const double minRampPerDegree = 0;
  static const double maxRampPerDegree = 2000;
  static const double minHysteresisC = 0.5;
  static const double maxHysteresisC = 15;
  static const int minIntervalSeconds = 1;
  static const int maxIntervalSeconds = 60;
  static const int minLeaseSeconds = 0;
  static const int maxLeaseSeconds = 3600;

  /// The daemon hands the fan back to Apple below this much headroom, so a
  /// policy with less room between target and guard does nothing at all.
  static const double minGuardHeadroomC = 10;

  static const FanPolicy defaults = FanPolicy();

  /// Off means the daemon releases the fan and stops deciding, not that the
  /// policy file is deleted.
  final bool enabled;
  final int fan;
  final FanSensorGroup group;

  /// At or above this, the daemon takes the fan out of Apple's automatic
  /// control. Below it, the fan is Apple's business entirely.
  final double targetTempC;

  /// The rpm asked for exactly at the target. Above it, [rampPerDegree] applies.
  /// The number written is always clamped to at least the fan's own minimum, so
  /// a policy cannot ask for less cooling than the machine would have chosen.
  final double holdRpm;
  final double rampPerDegree;

  /// Cooling-off band: once engaged, control is only given back this far below
  /// the target. Without it a machine sitting at the target flips the fan
  /// between two states on every tick.
  final double hysteresisC;
  final int intervalSeconds;

  /// Above this the daemon stops writing and returns the fan to automatic
  /// control, because Apple's curve at that point is steeper than anything
  /// configurable here.
  final double criticalTempC;

  /// Seconds a policy survives without a renewal from the app. 0 holds until
  /// released, which is what you want if the console is meant to keep working
  /// after you close it — and it is why the thermal guard exists.
  final int leaseSeconds;

  @override
  List<String> get problems => [
    if (fan < minFanIndex || fan > maxFanIndex)
      'Fan index must be between $minFanIndex and $maxFanIndex.',
    if (targetTempC < minTargetTempC || targetTempC > maxTargetTempC)
      'The trigger temperature must be between $minTargetTempC°C and '
          '${maxTargetTempC.toInt()}°C. Below that the fan would be forced '
          'almost always, which replaces Apple\'s control rather than adding '
          'to it.',
    if (holdRpm < minHoldRpm || holdRpm > maxHoldRpm)
      'The fan speed must be between ${minHoldRpm.toInt()} and '
          '${maxHoldRpm.toInt()} rpm. Anything outside that is a typo, not a '
          'setting — the daemon clamps to the fan\'s real range anyway.',
    if (rampPerDegree < minRampPerDegree || rampPerDegree > maxRampPerDegree)
      'The ramp must be between ${minRampPerDegree.toInt()} and '
          '${maxRampPerDegree.toInt()} rpm per degree.',
    if (hysteresisC < minHysteresisC || hysteresisC > maxHysteresisC)
      'The release band must be at least $minHysteresisC°C. With none, a '
          'machine sitting at the trigger flips the fan twice a second.',
    if (intervalSeconds < minIntervalSeconds ||
        intervalSeconds > maxIntervalSeconds)
      'The check interval must be between ${minIntervalSeconds}s and '
          '${maxIntervalSeconds}s.',
    if (criticalTempC - targetTempC < minGuardHeadroomC)
      'The thermal guard must be at least $minGuardHeadroomC°C above the '
          'trigger: at ${criticalTempC.toStringAsFixed(0)}°C the daemon hands '
          'the fan back to Apple before your policy has any room to act.',
    if (leaseSeconds < minLeaseSeconds || leaseSeconds > maxLeaseSeconds)
      'The lease must be between ${minLeaseSeconds}s and '
          '${maxLeaseSeconds ~/ 60} minutes.',
  ];

  @override
  bool get isValid => problems.isEmpty;

  @override
  String get blurb => enabled
      ? 'above ${targetTempC.toStringAsFixed(0)}°C → '
            '${holdRpm.toStringAsFixed(0)} rpm + '
            '${rampPerDegree.toStringAsFixed(0)}/°C'
      : 'policy is off';

  /// Shown next to the lease field, because 0 means something different from
  /// every other value and silently holding forever would be a surprise.
  String get leaseLabel => leaseSeconds == 0
      ? 'held until released, even if this app closes'
      : 'released ${leaseSeconds}s after this app stops renewing';

  FanPolicy copyWith({
    bool? enabled,
    int? fan,
    FanSensorGroup? group,
    double? targetTempC,
    double? holdRpm,
    double? rampPerDegree,
    double? hysteresisC,
    int? intervalSeconds,
    double? criticalTempC,
    int? leaseSeconds,
  }) => FanPolicy(
    enabled: enabled ?? this.enabled,
    fan: fan ?? this.fan,
    group: group ?? this.group,
    targetTempC: targetTempC ?? this.targetTempC,
    holdRpm: holdRpm ?? this.holdRpm,
    rampPerDegree: rampPerDegree ?? this.rampPerDegree,
    hysteresisC: hysteresisC ?? this.hysteresisC,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    criticalTempC: criticalTempC ?? this.criticalTempC,
    leaseSeconds: leaseSeconds ?? this.leaseSeconds,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'fan': fan,
    'group': group.wireName,
    'targetTempC': targetTempC,
    'holdRpm': holdRpm,
    'rampPerDegree': rampPerDegree,
    'hysteresisC': hysteresisC,
    'intervalSeconds': intervalSeconds,
    'criticalTempC': criticalTempC,
    'leaseSeconds': leaseSeconds,
  };

  /// Missing fields fall back to the defaults rather than failing: the daemon
  /// gains settings over time and an older reply should still read.
  factory FanPolicy.fromJson(Map<String, Object?>? json) {
    if (json == null) return defaults;
    double? number(String key) => (json[key] as num?)?.toDouble();
    return defaults.copyWith(
      enabled: json['enabled'] as bool?,
      fan: (json['fan'] as num?)?.toInt(),
      group: json.containsKey('group')
          ? FanSensorGroup.fromWire(json['group'] as String?)
          : null,
      targetTempC: number('targetTempC'),
      holdRpm: number('holdRpm'),
      rampPerDegree: number('rampPerDegree'),
      hysteresisC: number('hysteresisC'),
      intervalSeconds: (json['intervalSeconds'] as num?)?.toInt(),
      criticalTempC: number('criticalTempC'),
      leaseSeconds: (json['leaseSeconds'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FanPolicy &&
      other.enabled == enabled &&
      other.fan == fan &&
      other.group == group &&
      other.targetTempC == targetTempC &&
      other.holdRpm == holdRpm &&
      other.rampPerDegree == rampPerDegree &&
      other.hysteresisC == hysteresisC &&
      other.intervalSeconds == intervalSeconds &&
      other.criticalTempC == criticalTempC &&
      other.leaseSeconds == leaseSeconds;

  @override
  int get hashCode => Object.hash(
    enabled,
    fan,
    group,
    targetTempC,
    holdRpm,
    rampPerDegree,
    hysteresisC,
    intervalSeconds,
    criticalTempC,
    leaseSeconds,
  );

  @override
  String toString() =>
      'FanPolicy(${group.wireName} ${targetTempC}C -> ${holdRpm}rpm'
      '+$rampPerDegree/C, guard ${criticalTempC}C, lease ${leaseSeconds}s, '
      '${enabled ? 'on' : 'off'})';
}
