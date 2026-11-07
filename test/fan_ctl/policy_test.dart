import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';

/// The policy is the only thing the app sends to a root process, so its
/// validation is the last check before a number reaches a fan register.
void main() {
  group('defaults', () {
    test('are a policy that can actually act', () {
      expect(
        FanPolicy.defaults.isValid,
        isTrue,
        reason: '${FanPolicy.defaults.problems}',
      );
      expect(FanPolicy.defaults.manualOn, isFalse);
    });

    test(
      'hold a lease, so a client that dies does not leave the fan forced',
      () {
        expect(FanPolicy.defaults.leaseSeconds, 30);
      },
    );

    test('is a ToolConfig, so the generic settings plumbing can hold it', () {
      expect(FanPolicy.defaults, isA<ToolConfig>());
    });
  });

  group('problems', () {
    test('rejects an rpm that is a typo rather than a setting', () {
      expect(const FanPolicy(holdRpm: 100).problems, isNotEmpty);
      expect(const FanPolicy(holdRpm: 9001).problems, isNotEmpty);
      expect(const FanPolicy(holdRpm: FanPolicy.minHoldRpm).isValid, isTrue);
      expect(const FanPolicy(holdRpm: FanPolicy.maxHoldRpm).isValid, isTrue);
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
      expect(const FanPolicy(holdRpm: 3000).blurb, 'the fans are Apple\'s');
      expect(
        const FanPolicy(manualOn: true, holdRpm: 3000).blurb,
        'all fans held at 3000 rpm',
      );
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
        manualOn: true,
        holdRpm: 3100,
        leaseSeconds: 120,
      );
      expect(
        FanPolicy.fromJson(jsonDecode(jsonEncode(policy.toJson()))),
        policy,
      );
    });

    test('omitting a field falls back to the default, not to nothing', () {
      final partial = FanPolicy.fromJson({'holdRpm': 4200.0});
      expect(partial.holdRpm, 4200);
      expect(partial.manualOn, isFalse);
      expect(partial.leaseSeconds, FanPolicy.defaults.leaseSeconds);
      expect(partial.isValid, isTrue);
    });

    test(
      'null reads as the defaults, so an absent policy is a usable draft',
      () {
        expect(FanPolicy.fromJson(null), FanPolicy.defaults);
      },
    );

    test('carries exactly the three keys the daemon decodes', () {
      expect(FanPolicy.defaults.toJson().keys, [
        'manualOn',
        'holdRpm',
        'leaseSeconds',
      ]);
    });
  });

  group('heldManually', () {
    test('turns the switch on and keeps the number asked for', () {
      expect(
        const FanPolicy().heldManually(3000),
        const FanPolicy(manualOn: true, holdRpm: 3000),
      );
    });

    test('clamps a slider value that is beyond the wire band', () {
      expect(const FanPolicy().heldManually(50).holdRpm, FanPolicy.minHoldRpm);
      expect(
        const FanPolicy().heldManually(9999).holdRpm,
        FanPolicy.maxHoldRpm,
      );
    });
  });

  group('copyWith', () {
    test('leaves untouched fields alone', () {
      final copy = const FanPolicy(leaseSeconds: 60).copyWith(holdRpm: 3500);
      expect(copy.leaseSeconds, 60);
      expect(copy.holdRpm, 3500);
      expect(copy.manualOn, isFalse);
    });
  });

  test('equality compares values, so a saved policy can be recognised', () {
    expect(const FanPolicy(holdRpm: 3000), const FanPolicy(holdRpm: 3000));
    expect(
      const FanPolicy(holdRpm: 3000) == const FanPolicy(holdRpm: 2400),
      isFalse,
    );
    expect(
      const FanPolicy(holdRpm: 3000).hashCode,
      const FanPolicy(holdRpm: 3000).hashCode,
    );
    expect('${const FanPolicy(leaseSeconds: 60)}', contains('lease 60s'));
  });
}
