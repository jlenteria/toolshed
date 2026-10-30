import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/platform/paths.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';
import 'package:toolshed/tools/fan_ctl/fan_telemetry.dart';

/// The helper is the part of this tool that touches hardware, and its decision
/// table is the part that decides what the hardware does. Both can be measured
/// without root and without writing anything, so this runs the real binary.
///
/// `selftest` is deliberately not invoked here: it writes the mode key to
/// measure a privilege, which belongs behind a button a person presses, not in a
/// suite that runs on save.
void main() {
  final binary = Paths.fanHelperPath();
  final skip = binary == null
      ? 'no toolshed-fand built yet: make fanctl'
      : false;

  group('the built helper', () {
    test('agrees with its own policy table, with nothing to override', () {
      final result = Process.runSync(binary!, ['selfcheck', '--json']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(report['failures'], isEmpty, reason: '${report['failures']}');
      expect((report['checks'] as num).toInt(), greaterThan(0));
    }, skip: skip);

    test('reads the machine without privilege', () {
      final result = Process.runSync(binary!, ['telemetry', '--json']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final telemetry = FanTelemetry.parse(result.stdout as String);

      expect(telemetry.machine, isNotEmpty);
      expect(telemetry.pid, greaterThan(0));
      expect(telemetry.at, isNotNull);

      for (final fan in telemetry.fans) {
        expect(fan.maxRpm, greaterThanOrEqualTo(fan.minRpm));
        expect(fan.minRpm, greaterThanOrEqualTo(0));
        expect(fan.name, isNotEmpty);
      }

      var previous = double.infinity;
      for (final sensor in telemetry.sensors) {
        expect(
          sensor.celsius,
          lessThanOrEqualTo(previous),
          reason: 'sensors are meant to come back hottest first',
        );
        previous = sensor.celsius;
        expect(sensor.key, isNotEmpty);
      }

      // Every group name the daemon reports has to be one the policy can name,
      // which is the whole reason the two enums are pinned together.
      for (final key in telemetry.groups.keys) {
        expect(
          FanSensorGroup.values.map((group) => group.wireName),
          contains(key),
        );
      }
      for (final group in FanSensorGroup.values) {
        final celsius = telemetry.temperatureFor(group);
        if (celsius != null) expect(celsius, greaterThan(0));
      }
    }, skip: skip);

    test('the group maxima really are the maxima of the sensors it sent', () {
      final telemetry = FanTelemetry.parse(
        Process.runSync(binary!, ['telemetry', '--json']).stdout as String,
      );
      if (telemetry.sensors.isEmpty) return;
      expect(
        telemetry.temperatureFor(FanSensorGroup.all),
        telemetry.hottest?.celsius,
      );
    }, skip: skip);
  });
}
