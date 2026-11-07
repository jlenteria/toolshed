import '../../models/tool_config.dart';

/// Which family of SMC temperature sensors a reading belongs to.
///
/// These are the wire names in the daemon's `telemetry` output — its `families`
/// table was built from `toolshed-fand keys` on a Mac14,7, and
/// `fan_protocol_test` pins the two lists together. Nothing decides anything with
/// them any more: cooling on temperature is macOS's job, so what is left here is
/// the vocabulary for reading the machine, not for reacting to it. Ambient (`Ta`)
/// and battery (`TB`) sensors are in `all` but in no named group, because a warm
/// battery is not a CPU signal.
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
    orElse: () => all, // an unknown name means everything, not nothing
  );
}

/// A hand on the fan: hold every fan at one speed, or hand them back to Apple.
///
/// That is the whole model, and it is deliberately not a control law. There is no
/// trigger temperature, no ramp and no hysteresis here or in the daemon, because
/// `thermalmonitord` has the sensor fleet, the load history and the curves for
/// this exact machine, and a threshold typed into a console loses that argument.
///
/// The field names are the field names in `Policy` in `macos/fanctl/main.swift`;
/// the two must stay in step, and `fan_protocol_test` pins the shape.
class FanPolicy implements ToolConfig {
  const FanPolicy({
    this.manualOn = false,
    this.holdRpm = 2_400,
    this.leaseSeconds = 30,
  });

  static const double minHoldRpm = 500;
  static const double maxHoldRpm = 9_000;
  static const int minLeaseSeconds = 0;
  static const int maxLeaseSeconds = 3_600;

  static const FanPolicy defaults = FanPolicy();

  /// The switch. On means the daemon holds every fan it can read at [holdRpm],
  /// whatever the sensors say; off means the fans are Apple's again. It is not a
  /// draft flag — flipping it acts on the hardware through the daemon.
  final bool manualOn;

  /// The speed asked of every fan. The number written is clamped into each fan's
  /// own floor and ceiling by the daemon, so a request cannot leave the machine
  /// quieter than Apple's idle or faster than the impeller can turn.
  final double holdRpm;

  /// Seconds a hold survives without a renewal from the app. This is the only
  /// thing that ends a hold by itself now that no temperature can, which is why
  /// the default is a lease rather than forever: a console that is killed and
  /// never closed must not leave the fans pinned.
  final int leaseSeconds;

  @override
  List<String> get problems => [
    if (holdRpm < minHoldRpm || holdRpm > maxHoldRpm)
      'The fan speed must be between ${minHoldRpm.toInt()} and '
          '${maxHoldRpm.toInt()} rpm. Anything outside that is a typo, not a '
          'setting — the daemon clamps to the fan\'s real range anyway.',
    if (leaseSeconds < minLeaseSeconds || leaseSeconds > maxLeaseSeconds)
      'The lease must be between ${minLeaseSeconds}s and '
          '${maxLeaseSeconds ~/ 60} minutes.',
  ];

  @override
  bool get isValid => problems.isEmpty;

  @override
  String get blurb => manualOn
      ? 'all fans held at ${holdRpm.toStringAsFixed(0)} rpm'
      : 'the fans are Apple\'s';

  /// Shown under the switch, because what happens when the console closes is the
  /// question a person holding a fan actually has.
  String get leaseLabel => leaseSeconds == 0
      ? 'held until released, even if this app closes'
      : 'released ${leaseSeconds}s after this app stops renewing';

  /// The policy the manual switch sends: [rpm] clamped into the configurable
  /// band, with this draft's lease. The fan's own range is not consulted here —
  /// the daemon clamps per fan, and saying "fan 1 only turns 2000 to 4000" is
  /// its sentence, not one the UI gets to guess.
  FanPolicy heldManually(double rpm) =>
      copyWith(manualOn: true, holdRpm: rpm.clamp(minHoldRpm, maxHoldRpm));

  FanPolicy copyWith({bool? manualOn, double? holdRpm, int? leaseSeconds}) =>
      FanPolicy(
        manualOn: manualOn ?? this.manualOn,
        holdRpm: holdRpm ?? this.holdRpm,
        leaseSeconds: leaseSeconds ?? this.leaseSeconds,
      );

  Map<String, Object?> toJson() => {
    'manualOn': manualOn,
    'holdRpm': holdRpm,
    'leaseSeconds': leaseSeconds,
  };

  /// Missing fields fall back to the defaults rather than failing: the daemon
  /// gains settings over time and an older reply should still read.
  factory FanPolicy.fromJson(Map<String, Object?>? json) {
    if (json == null) return defaults;
    return defaults.copyWith(
      manualOn: json['manualOn'] as bool?,
      holdRpm: (json['holdRpm'] as num?)?.toDouble(),
      leaseSeconds: (json['leaseSeconds'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FanPolicy &&
      other.manualOn == manualOn &&
      other.holdRpm == holdRpm &&
      other.leaseSeconds == leaseSeconds;

  @override
  int get hashCode => Object.hash(manualOn, holdRpm, leaseSeconds);

  @override
  String toString() =>
      'FanPolicy(${manualOn ? 'manual ${holdRpm}rpm' : 'automatic'}, '
      'lease ${leaseSeconds}s)';
}
