import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/tools/fan_ctl/fan_backend.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';

import 'fake_daemon.dart';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('toolshed-fan-backend');
  });
  tearDown(() {
    scratch.deleteSync(recursive: true);
  });

  File policyFile() => File('${scratch.path}/fan_policy.json');

  MacOSFanBackend backend(FakeDaemon daemon) {
    final service = MacOSFanBackend(
      runner: daemon,
      helperPath: '/fake/toolshed-fand',
      policyFile: policyFile(),
      socketPath: '/fake.sock',
    );
    // An engaged service renews on a timer; a test that engaged and finished
    // would otherwise leave it applying a policy to a fake nobody is watching.
    addTearDown(service.dispose);
    return service;
  }

  /// The renewal fires at half the lease, so anything on a 2 s lease has had a
  /// chance to repeat by now.
  Future<void> pastRenewal() =>
      Future<void>.delayed(const Duration(milliseconds: 1400));

  group('engage', () {
    test('sends the policy once and saves it', () async {
      final daemon = FakeDaemon();
      final policy = FanPolicy.defaults.copyWith(
        enabled: true,
        targetTempC: 64,
        leaseSeconds: 2,
      );
      await backend(daemon).engage(policy);

      expect(daemon.cmds, ['apply']);
      expect(daemon.applied.single, policy);
      expect(
        FanPolicy.fromJson(
          Map<String, Object?>.from(
            jsonDecode(policyFile().readAsStringSync()) as Map,
          ),
        ),
        policy,
      );
    });

    test(
      'renews the lease with the numbers it was last engaged with',
      () async {
        final daemon = FakeDaemon();
        final service = backend(daemon);
        final first = FanPolicy.defaults.copyWith(
          enabled: true,
          targetTempC: 64,
          leaseSeconds: 2,
        );
        final second = first.copyWith(targetTempC: 58);

        await service.engage(first);
        await pastRenewal();
        expect(daemon.applied.length, greaterThan(1));

        // The regression this pins: a second engage used to leave the first
        // timer running, so the fan was handed back the old threshold seconds
        // after the new one was set.
        await service.engage(second);
        daemon.received.clear();
        await pastRenewal();
        expect(daemon.applied, isNotEmpty);
        expect(
          daemon.applied.every((p) => p.targetTempC == 58),
          isTrue,
          reason: 'a stale renewal timer re-applied the superseded policy',
        );
      },
    );

    test('refuses a policy that is switched off, without writing', () async {
      final daemon = FakeDaemon();
      await expectLater(
        backend(daemon).engage(FanPolicy.defaults.copyWith(enabled: false)),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'POLICY_DISABLED'),
        ),
      );
      expect(daemon.received, isEmpty);
      expect(policyFile().existsSync(), isFalse);
    });

    test('refuses a broken policy before the daemon sees it', () async {
      final daemon = FakeDaemon();
      final broken = FanPolicy.defaults.copyWith(targetTempC: 130, fan: 9);
      await expectLater(
        backend(daemon).engage(broken),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'INVALID_POLICY'),
        ),
      );
      expect(daemon.received, isEmpty);
    });

    test('a daemon that does not answer leaves nothing renewing', () async {
      final daemon = FakeDaemon(answers: false);
      await expectLater(
        backend(
          daemon,
        ).engage(FanPolicy.defaults.copyWith(enabled: true, leaseSeconds: 2)),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'DAEMON_SILENT'),
        ),
      );
      await pastRenewal();
      expect(daemon.cmds, ['apply'], reason: 'one attempt, then the failure');
    });
  });

  group('save without engaging', () {
    test('writes the file and touches no hardware at all', () async {
      final daemon = FakeDaemon();
      final policy = FanPolicy.defaults.copyWith(
        enabled: true,
        targetTempC: 64,
      );

      await backend(daemon).writeConfig(policy);

      // The button says "without engaging". An enabled policy used to be sent
      // to the daemon here, which made Engage and Save the same action and let
      // a save be undone by the previous hold's renewal.
      expect(daemon.received, isEmpty);
      expect(
        Map<String, Object?>.from(
          jsonDecode(policyFile().readAsStringSync()) as Map,
        )['targetTempC'],
        64.0,
      );
    });

    test('leaves an existing hold exactly as it was', () async {
      final daemon = FakeDaemon();
      final service = backend(daemon);
      final holding = FanPolicy.defaults.copyWith(
        enabled: true,
        targetTempC: 64,
        leaseSeconds: 2,
      );
      await service.engage(holding);
      await service.writeConfig(holding.copyWith(targetTempC: 58));
      daemon.received.clear();
      await pastRenewal();

      expect(daemon.applied.every((p) => p.targetTempC == 64), isTrue);
    });

    test('refuses a broken policy without saving it', () async {
      final daemon = FakeDaemon();
      await expectLater(
        backend(
          daemon,
        ).writeConfig(FanPolicy.defaults.copyWith(hysteresisC: 40)),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'INVALID_POLICY'),
        ),
      );
      expect(policyFile().existsSync(), isFalse);
    });
  });

  group('release', () {
    test(
      'clears the daemon, stops renewing and switches the file off',
      () async {
        final daemon = FakeDaemon();
        final service = backend(daemon);
        await service.engage(
          FanPolicy.defaults.copyWith(enabled: true, leaseSeconds: 2),
        );

        await service.releaseControl();

        expect(daemon.cmds.last, 'clear');
        daemon.received.clear();
        await pastRenewal();
        expect(
          daemon.received,
          isEmpty,
          reason: 'a released hold kept renewing',
        );
        final saved = Map<String, Object?>.from(
          jsonDecode(policyFile().readAsStringSync()) as Map,
        );
        expect(saved['enabled'], isFalse);
      },
    );

    test(
      'reports a daemon that is not answering instead of claiming release',
      () async {
        final daemon = FakeDaemon(answers: false);
        await expectLater(
          backend(daemon).releaseControl(),
          throwsA(
            isA<ToolException>().having((e) => e.code, 'code', 'DAEMON_SILENT'),
          ),
        );
      },
    );
  });

  group('readConfig', () {
    test(
      'prefers what the daemon is holding over the file behind it',
      () async {
        final daemon = FakeDaemon();
        final service = backend(daemon);
        final live = FanPolicy.defaults.copyWith(
          enabled: true,
          targetTempC: 64,
          leaseSeconds: 0,
        );
        await service.engage(live);
        await service.writeConfig(live.copyWith(targetTempC: 58));

        expect(await service.readConfig(), live);
      },
    );

    test('shows the file again once the hold is released', () async {
      final daemon = FakeDaemon();
      final service = backend(daemon);
      final live = FanPolicy.defaults.copyWith(
        enabled: true,
        targetTempC: 64,
        leaseSeconds: 0,
      );
      await service.engage(live);
      await service.writeConfig(live.copyWith(targetTempC: 58));
      expect(await service.readConfig(), live);

      await service.releaseControl();
      expect(
        await service.readConfig(),
        live.copyWith(targetTempC: 58, enabled: false),
      );
    });

    test('falls back to the file when nothing is answering', () async {
      final daemon = FakeDaemon(answers: false);
      final saved = FanPolicy.defaults.copyWith(targetTempC: 61);
      await policyFile().writeAsString(jsonEncode(saved.toJson()));

      expect(await backend(daemon).readConfig(), saved);
    });
  });
}
