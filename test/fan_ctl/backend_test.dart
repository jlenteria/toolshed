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

  const held = FanPolicy(manualOn: true, holdRpm: 3400, leaseSeconds: 2);

  group('engage', () {
    test('sends the policy once and saves it', () async {
      final daemon = FakeDaemon();
      await backend(daemon).engage(held);

      expect(daemon.cmds, ['apply']);
      expect(daemon.applied.single, held);
      expect(
        FanPolicy.fromJson(
          Map<String, Object?>.from(
            jsonDecode(policyFile().readAsStringSync()) as Map,
          ),
        ),
        held,
      );
    });

    test('renews the lease with the speed it was last engaged with', () async {
      final daemon = FakeDaemon();
      final service = backend(daemon);
      final second = held.copyWith(holdRpm: 2800);

      await service.engage(held);
      await pastRenewal();
      expect(daemon.applied.length, greaterThan(1));

      // The regression this pins: a second engage used to leave the first
      // timer running, so the superseded speed was re-applied seconds after
      // the new one was set.
      await service.engage(second);
      daemon.received.clear();
      await pastRenewal();
      expect(daemon.applied, isNotEmpty);
      expect(
        daemon.applied.every((p) => p.holdRpm == 2800),
        isTrue,
        reason: 'a stale renewal timer re-applied the superseded policy',
      );
    });

    test(
      'refuses a policy the switch has not turned on, without writing',
      () async {
        final daemon = FakeDaemon();
        await expectLater(
          backend(daemon).engage(FanPolicy.defaults),
          throwsA(
            isA<ToolException>().having((e) => e.code, 'code', 'NOT_A_HOLD'),
          ),
        );
        expect(daemon.received, isEmpty);
        expect(policyFile().existsSync(), isFalse);
      },
    );

    test('refuses a broken policy before the daemon sees it', () async {
      final daemon = FakeDaemon();
      await expectLater(
        backend(daemon).engage(held.copyWith(holdRpm: 200)),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'INVALID_POLICY'),
        ),
      );
      expect(daemon.received, isEmpty);
    });

    test(
      'a daemon that does not understand this app is named, not obeyed',
      () async {
        // The one version-skew outcome that would be silent: an old installed
        // helper rejecting the three-key request. A wrong speed nobody mentions
        // is worse than a refusal with a next step.
        final daemon = FakeDaemon(
          refuses: 'that is not a toolshed-fand request',
        );
        await expectLater(
          backend(daemon).engage(held),
          throwsA(
            isA<ToolException>().having(
              (e) => e.code,
              'code',
              'DAEMON_TOO_OLD',
            ),
          ),
        );
      },
    );

    test('a daemon that does not answer leaves nothing renewing', () async {
      final daemon = FakeDaemon(answers: false);
      await expectLater(
        backend(daemon).engage(held),
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

      await backend(daemon).writeConfig(held);

      // Dragging the slider saves the draft. If a save also sent it, moving the
      // number would spin the fan through the daemon mid-gesture and the previous
      // hold's renewal would be undone by it.
      expect(daemon.received, isEmpty);
      expect(
        Map<String, Object?>.from(
          jsonDecode(policyFile().readAsStringSync()) as Map,
        )['holdRpm'],
        3400.0,
      );
    });

    test('leaves an existing hold exactly as it was', () async {
      final daemon = FakeDaemon();
      final service = backend(daemon);
      await service.engage(held);
      await service.writeConfig(held.copyWith(holdRpm: 2800));
      daemon.received.clear();
      await pastRenewal();

      expect(daemon.applied.every((p) => p.holdRpm == 3400), isTrue);
    });

    test('refuses a broken policy without saving it', () async {
      final daemon = FakeDaemon();
      await expectLater(
        backend(daemon).writeConfig(held.copyWith(leaseSeconds: 90000)),
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
        await service.engage(held);

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
        expect(saved['manualOn'], isFalse);
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
        final live = held.copyWith(leaseSeconds: 0);
        await service.engage(live);
        await service.writeConfig(live.copyWith(holdRpm: 2800));

        expect(await service.readConfig(), live);
      },
    );

    test('shows the file again once the hold is released', () async {
      final daemon = FakeDaemon();
      final service = backend(daemon);
      final live = held.copyWith(leaseSeconds: 0);
      await service.engage(live);
      await service.writeConfig(live.copyWith(holdRpm: 2800));
      expect(await service.readConfig(), live);

      await service.releaseControl();
      expect(
        await service.readConfig(),
        live.copyWith(holdRpm: 2800, manualOn: false),
      );
    });

    test('falls back to the file when nothing is answering', () async {
      final daemon = FakeDaemon(answers: false);
      await policyFile().writeAsString(jsonEncode(held.toJson()));

      expect(await backend(daemon).readConfig(), held);
    });
  });
}
