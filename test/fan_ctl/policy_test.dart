import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';

/// The policy is the only thing the app sends to a root process, so its
/// validation is the last check before a number reaches a fan register. These
/// tests are about what it refuses.
void main() {
  group('defaults', () {
    test('are a policy that can actually act', () {
      expect(
        FanPolicy.defaults.isValid,
        isTrue,
        reason: '${FanPolicy.defaults.problems}',
      );
      expect(FanPolicy.defaults.enabled, isTrue);
    });

    test(
      'hold a lease, so a client that dies does not leave the fan forced',
      () {
        expect(FanPolicy.defaults.leaseSeconds, 30);
      },
    );

    test('leave ten degrees between the trigger and the thermal guard', () {
      expect(
        FanPolicy.defaults.criticalTempC - FanPolicy.defaults.targetTempC,
        greaterThanOrEqualTo(FanPolicy.minGuardHeadroomC),
      );
    });

    test('is a ToolConfig, so the generic settings plumbing can hold it', () {
      expect(FanPolicy.defaults, isA<ToolConfig>());
    });
  });

  group('problems', () {
    test('rejects a guard with no room under it', () {
      final policy = const FanPolicy(targetTempC: 90, criticalTempC: 95);
      expect(
        policy.problems.single,
        contains('thermal guard must be at least'),
      );
    });

    test(
      'rejects a trigger outside the range where forcing is a supplement',
      () {
        expect(
          const FanPolicy(targetTempC: 30).problems,
          contains(matches(r'trigger temperature must be between')),
        );
        // 101°C is out of range *and* leaves no headroom under the guard, so it
        // earns both complaints.
        expect(const FanPolicy(targetTempC: 101).problems, hasLength(2));
      },
    );

    test('rejects an rpm that is a typo rather than a setting', () {
      expect(const FanPolicy(holdRpm: 100).problems, isNotEmpty);
      expect(const FanPolicy(holdRpm: 9001).problems, isNotEmpty);
      expect(const FanPolicy(holdRpm: FanPolicy.minHoldRpm).isValid, isTrue);
      expect(const FanPolicy(holdRpm: FanPolicy.maxHoldRpm).isValid, isTrue);
    });

    test('rejects a release band of zero, which would oscillate', () {
      expect(
        const FanPolicy(hysteresisC: 0).problems,
        contains(matches('release band')),
      );
    });

    test('rejects a fan index the SMC cannot have', () {
      expect(const FanPolicy(fan: -1).problems, isNotEmpty);
      expect(
        const FanPolicy(fan: FanPolicy.maxFanIndex + 1).problems,
        isNotEmpty,
      );
    });

    test('rejects an interval outside the tick range', () {
      expect(const FanPolicy(intervalSeconds: 0).problems, isNotEmpty);
      expect(const FanPolicy(intervalSeconds: 61).problems, isNotEmpty);
    });

    test('names every problem at once, so one edit can fix them all', () {
      final policy = const FanPolicy(
        targetTempC: 200,
        holdRpm: 50,
        hysteresisC: 0,
        intervalSeconds: 900,
      );
      // Five, not four: a trigger of 200°C is out of range and also leaves the
      // guard underneath it, and both are worth saying.
      expect(policy.problems.length, 5, reason: '${policy.problems}');
      expect(policy.isValid, isFalse);
    });

    test('accepts a lease of zero, which means hold until released', () {
      expect(const FanPolicy(leaseSeconds: 0).isValid, isTrue);
      expect(
        const FanPolicy(leaseSeconds: FanPolicy.maxLeaseSeconds).isValid,
        isTrue,
      );
      expect(const FanPolicy(leaseSeconds: 3601).problems, isNotEmpty);
    });
  });

  group('labels', () {
    test('blurb says what will happen, not that something is configured', () {
      expect(
        const FanPolicy(holdRpm: 3000, rampPerDegree: 200).blurb,
        'above 70°C → 3000 rpm + 200/°C',
      );
      expect(const FanPolicy(enabled: false).blurb, 'policy is off');
    });

    test('lease label distinguishes forever from a countdown', () {
      expect(
        const FanPolicy(leaseSeconds: 0).leaseLabel,
        'held until released, even if this app closes',
      );
      expect(
        const FanPolicy(leaseSeconds: 45).leaseLabel,
        'released 45s after this app stops renewing',
      );
    });
  });

  group('json', () {
    test('round-trips through the wire shape', () {
      const policy = FanPolicy(
        enabled: true,
        fan: 1,
        group: FanSensorGroup.gpu,
        targetTempC: 72.5,
        holdRpm: 3100,
        rampPerDegree: 400,
        hysteresisC: 4.5,
        intervalSeconds: 5,
        criticalTempC: 97,
        leaseSeconds: 120,
      );
      expect(
        FanPolicy.fromJson(jsonDecode(jsonEncode(policy.toJson()))),
        policy,
      );
    });

    test('omitting a field falls back to the default, not to nothing', () {
      final partial = FanPolicy.fromJson({'targetTempC': 80.0});
      expect(partial.targetTempC, 80);
      expect(partial.group, FanSensorGroup.cpu);
      expect(partial.leaseSeconds, FanPolicy.defaults.leaseSeconds);
      expect(partial.isValid, isTrue);
    });

    test(
      'null reads as the defaults, so an absent policy is a usable draft',
      () {
        expect(FanPolicy.fromJson(null), FanPolicy.defaults);
      },
    );

    test('an unknown sensor group watches everything rather than nothing', () {
      expect(FanSensorGroup.fromWire('cpu'), FanSensorGroup.cpu);
      expect(FanSensorGroup.fromWire('package'), FanSensorGroup.all);
      expect(FanSensorGroup.fromWire(null), FanSensorGroup.all);
    });

    test(
      'carries every field the daemon decodes, with the group as its wire name',
      () {
        expect(FanPolicy.defaults.toJson().keys, [
          'enabled',
          'fan',
          'group',
          'targetTempC',
          'holdRpm',
          'rampPerDegree',
          'hysteresisC',
          'intervalSeconds',
          'criticalTempC',
          'leaseSeconds',
        ]);
        expect(
          const FanPolicy(group: FanSensorGroup.heatSink).toJson()['group'],
          'heatSink',
        );
      },
    );
  });

  group('copyWith', () {
    test('leaves untouched fields alone', () {
      final copy = const FanPolicy(fan: 2).copyWith(targetTempC: 88);
      expect(copy.fan, 2);
      expect(copy.targetTempC, 88);
      expect(copy.group, FanSensorGroup.cpu);
    });

    test('can turn a policy off without touching its numbers', () {
      const policy = FanPolicy(targetTempC: 65, holdRpm: 4000);
      expect(
        policy.copyWith(enabled: false),
        const FanPolicy(enabled: false, targetTempC: 65, holdRpm: 4000),
      );
    });
  });

  test('equality compares values, so a saved policy can be recognised', () {
    expect(const FanPolicy(fan: 1), const FanPolicy(fan: 1));
    expect(const FanPolicy(fan: 1) == const FanPolicy(fan: 0), isFalse);
    expect(const FanPolicy(fan: 1).hashCode, const FanPolicy(fan: 1).hashCode);
    expect('${const FanPolicy(leaseSeconds: 60)}', contains('lease 60s'));
  });
}
