import 'dart:convert';

import 'fan_policy.dart';

/// One fan, as the SMC reports it.
///
/// The keys are `Fan` in `macos/fanctl/main.swift`. `minRpm`/`maxRpm` are the
/// fan's own floor and ceiling, not the machine's: the daemon clamps every
/// request into them, so a policy can never ask for less cooling than Apple
/// would have applied or more than the impeller can turn.
class FanReading {
  const FanReading({
    required this.id,
    required this.name,
    required this.actualRpm,
    required this.minRpm,
    required this.maxRpm,
    required this.targetRpm,
    required this.mode,
    required this.modeKey,
  });

  final int id;
  final String name;
  final double actualRpm;
  final double minRpm;
  final double maxRpm;

  /// What the fan was last asked for. Null when the key is missing, which on a
  /// Mac in automatic control is normal rather than an error.
  final double? targetRpm;

  /// 0 is Apple's automatic control; anything else means somebody — this tool or
  /// another — is forcing the speed.
  final int mode;

  /// Which spelling of the mode key this Mac actually has, `F0Md` or `F0md`,
  /// because casing varies and the daemon discovered it rather than assumed it.
  final String modeKey;

  bool get isForced => mode != 0;

  /// Where the fan sits between its own floor and ceiling, for a bar that means
  /// something on a machine whose fan spins between 1200 and 7200 rather than 0.
  double get speedFraction {
    if (maxRpm <= minRpm) return 0;
    return ((actualRpm - minRpm) / (maxRpm - minRpm)).clamp(0.0, 1.0);
  }

  factory FanReading.fromJson(Map<String, Object?> json) => FanReading(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name:
        json['name'] as String? ?? 'Fan ${(json['id'] as num?)?.toInt() ?? 0}',
    actualRpm: (json['actualRpm'] as num?)?.toDouble() ?? 0,
    minRpm: (json['minRpm'] as num?)?.toDouble() ?? 0,
    maxRpm: (json['maxRpm'] as num?)?.toDouble() ?? 0,
    targetRpm: (json['targetRpm'] as num?)?.toDouble(),
    mode: (json['mode'] as num?)?.toInt() ?? 0,
    modeKey: json['modeKey'] as String? ?? 'F0Md',
  );
}

/// One temperature sensor.
class TemperatureSensor {
  const TemperatureSensor({
    required this.key,
    required this.celsius,
    required this.type,
  });

  final String key;
  final double celsius;

  /// The SMC's own type code — `flt `, `sp78`, `fpe2` — which is why the daemon
  /// decodes per key instead of assuming every sensor is a float.
  final String type;

  /// Apple's two-character family: `Tp` package, `Tg` GPU, `Th` heat spreader.
  String get family => key.length >= 2 ? key.substring(0, 2) : key;

  factory TemperatureSensor.fromJson(Map<String, Object?> json) =>
      TemperatureSensor(
        key: json['key'] as String? ?? '',
        celsius: (json['celsius'] as num?)?.toDouble() ?? 0,
        type: json['type'] as String? ?? '',
      );
}

/// A snapshot of the hardware, read without privilege.
class FanTelemetry {
  const FanTelemetry({
    required this.at,
    required this.fans,
    required this.sensors,
    required this.groups,
    required this.machine,
    required this.pid,
  });

  static const empty = FanTelemetry(
    at: null,
    fans: [],
    sensors: [],
    groups: {},
    machine: '',
    pid: 0,
  );

  /// When the daemon took the reading. Null when the reply predates the field —
  /// a missing timestamp is not a reason to throw away the numbers with it.
  final DateTime? at;
  final List<FanReading> fans;

  /// Hottest first, which is the order the daemon reads them in.
  final List<TemperatureSensor> sensors;

  /// The warmest sensor in each group, keyed by the group's wire name. Computed
  /// in the daemon because the daemon is the one that decides, and the UI
  /// displaying a different number than the one that triggered a fan would be a
  /// lie about a cause.
  final Map<String, double> groups;
  final String machine;
  final int pid;

  bool get hasFans => fans.isNotEmpty;

  FanReading? fan(int id) {
    for (final fan in fans) {
      if (fan.id == id) return fan;
    }
    return null;
  }

  TemperatureSensor? get hottest => sensors.isEmpty ? null : sensors.first;

  /// The temperature the policy named [group] is acting on, or null when this
  /// Mac has none of that group's sensors.
  double? temperatureFor(FanSensorGroup group) => groups[group.wireName];

  factory FanTelemetry.fromJson(Map<String, Object?> json) {
    final seconds = (json['at'] as num?)?.toInt();
    final groups = json['groups'];
    return FanTelemetry(
      at: seconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      fans: [
        for (final entry in jsonMaps(json['fans'])) FanReading.fromJson(entry),
      ],
      sensors: [
        for (final entry in jsonMaps(json['sensors']))
          TemperatureSensor.fromJson(entry),
      ],
      groups: {
        if (groups is Map)
          for (final entry in groups.entries)
            if (entry.value is num)
              entry.key.toString(): (entry.value as num).toDouble(),
      },
      machine: json['machine'] as String? ?? '',
      pid: (json['pid'] as num?)?.toInt() ?? 0,
    );
  }

  static FanTelemetry parse(String source) {
    final decoded = jsonDecode(source.trim());
    if (decoded is! Map) {
      throw const FormatException('telemetry is not a JSON object');
    }
    return FanTelemetry.fromJson(Map<String, Object?>.from(decoded));
  }
}

/// A list of JSON objects, tolerant of the key being absent or the wrong shape:
/// a firmware that reports no fans is a fact about the machine, not a crash.
List<Map<String, Object?>> jsonMaps(Object? value) => value is List
    ? [
        for (final entry in value)
          if (entry is Map) Map<String, Object?>.from(entry),
      ]
    : const [];
