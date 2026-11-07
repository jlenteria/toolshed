import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/fan_ctl/daemon_client.dart';
import 'package:toolshed/tools/fan_ctl/fan_daemon.dart';
import 'package:toolshed/tools/fan_ctl/fan_policy.dart';
import 'package:toolshed/tools/fan_ctl/fan_telemetry.dart';

/// The two halves of this tool are written in different languages and meet only
/// as JSON over a socket, so the shapes are the contract — and nothing checks
/// them at compile time. If the Swift side renames `holdRpm`, the Dart reader
/// silently falls back to a default and the daemon runs a policy nobody
/// configured, which is a wrong number that looks right.
///
/// So this test reads both real sources and compares them, then feeds the Dart
/// models a payload built from Swift's own key names and checks the values come
/// out. A rename at either end fails here rather than on a fan.
void main() {
  final swift = _read('macos/fanctl/main.swift');
  final clientSource = _read('lib/tools/fan_ctl/daemon_client.dart');

  group('the daemon decodes what the app sends', () {
    test('Policy has exactly the fields FanPolicy writes', () {
      expect(
        swiftFields(swift, 'Policy'),
        FanPolicy.defaults.toJson().keys.toSet(),
      );
    });

    test('Policy reads a request that omits keys instead of refusing it', () {
      // A synthesized Codable decoder throws keyNotFound for an absent key no
      // matter what the property defaults to, so the hand-written initializer
      // is what keeps a leaner or hand-run request working. It is three keys,
      // and three optional reads are the whole of it.
      expect(
        RegExp(r'init\(from decoder: Decoder\) throws').hasMatch(swift),
        isTrue,
        reason: 'Policy must declare its own decoder',
      );
      expect(RegExp(r'decodeIfPresent').allMatches(swift).length, 3);
    });

    test('Request is the envelope the client builds', () {
      expect(swiftFields(swift, 'Request'), {'cmd', 'policy'});
      expect((jsonDecode(FanDaemonClient.requestJson('status')) as Map).keys, {
        'cmd',
      });
      expect(
        (jsonDecode(
                  FanDaemonClient.requestJson(
                    'apply',
                    policy: FanPolicy.defaults,
                  ),
                )
                as Map)
            .keys,
        {'cmd', 'policy'},
      );
    });

    test('every group name Dart reads is a SensorGroup the daemon knows', () {
      expect(
        swiftSensorGroups(swift),
        FanSensorGroup.values.map((group) => group.wireName).toSet(),
      );
    });

    test('engaging forces the fan before it writes the target', () {
      // Measured on a Mac14,7 (Darwin 27): a target written while the fan is
      // still in automatic control does not stick, so the fan stayed at Apple's
      // ~1200 rpm while the daemon reported holding 3000. The mode has to be 1
      // before the speed is written. The ordering cannot be observed here
      // without root and a fan, so this is a source check like the shape checks
      // around it.
      final start = swift.indexOf('func engage(fan: Int, rpm: Double)');
      expect(start, greaterThanOrEqualTo(0), reason: 'no engage in the helper');
      final body = _braced(swift, swift.indexOf('{', start));
      final forced = body.indexOf('(smc.modeKey(fan), 1)');
      final target = body.indexOf('("F\\(fan)Tg", rpm)');
      expect(forced, greaterThanOrEqualTo(0), reason: 'engage never forces');
      expect(
        target,
        greaterThanOrEqualTo(0),
        reason: 'engage never sets a speed',
      );
      expect(
        forced,
        lessThan(target),
        reason: 'the target is written before the fan is forced, so it is lost',
      );
    });

    test('every socket command Dart sends is dispatched by the daemon', () {
      // `ping` is issued by the backend's liveness probe rather than the client,
      // so both files are scanned: a verb only one of them knows is still a verb
      // that has to exist at the other end.
      final sent = {
        ..._dartPattern(
          clientSource,
          RegExp(r"tryRequest\('(\w+)'\)|request\('(\w+)'"),
        ),
        ..._dartPattern(
          _read('lib/tools/fan_ctl/fan_backend.dart'),
          RegExp(r"tryRequest\('(\w+)'\)"),
        ),
      };
      expect(sent, {'apply', 'clear', 'ping', 'selftest', 'status'});
      final dispatched = swiftSocketCommands(swift);
      expect(dispatched, sent, reason: 'the daemon dispatches $dispatched');
    });

    test('every CLI subcommand Dart runs exists in the helper', () {
      final names = {
        for (final command in FanCommand.values) command.wireName,
        ..._dartPattern(
          _read('lib/tools/fan_ctl/daemon_install.dart'),
          RegExp(r"\['(\w+)',\s*'--json'\]"),
        ),
      };
      expect(names, {'telemetry', 'selftest', 'selfcheck'});
      for (final name in names) {
        expect(
          swiftCliCommands(swift),
          contains(name),
          reason: 'the helper has no "$name" subcommand',
        );
      }
    });
  });

  group('the app reads what the daemon replies', () {
    test('FanReading mirrors Swift Fan', () {
      expect(
        swiftFields(swift, 'Fan'),
        _dartJsonKeys(
          source: _read('lib/tools/fan_ctl/fan_telemetry.dart'),
          from: 'factory FanReading.fromJson',
        ),
      );
    });

    test('TemperatureSensor mirrors Swift Sensor', () {
      expect(
        swiftFields(swift, 'Sensor'),
        _dartJsonKeys(
          source: _read('lib/tools/fan_ctl/fan_telemetry.dart'),
          from: 'factory TemperatureSensor.fromJson',
        ),
      );
    });

    test('FanTelemetry mirrors Swift Telemetry', () {
      expect(
        swiftFields(swift, 'Telemetry'),
        _dartJsonKeys(
          source: _read('lib/tools/fan_ctl/fan_telemetry.dart'),
          from: 'factory FanTelemetry.fromJson',
        ),
      );
    });

    test('FanDaemonStatus mirrors Swift Reply.Status', () {
      expect(
        swiftFields(swift, 'Status'),
        _dartJsonKeys(
          source: _read('lib/tools/fan_ctl/fan_daemon.dart'),
          from: 'factory FanDaemonStatus.fromJson',
        ),
      );
    });

    test('FanPrivilegeReport mirrors Swift SelfTestReport', () {
      expect(
        swiftFields(swift, 'SelfTestReport'),
        _dartJsonKeys(
          source: _read('lib/tools/fan_ctl/fan_daemon.dart'),
          from: 'factory FanPrivilegeReport.fromJson',
        ),
      );
    });

    test('FanReply mirrors Swift Reply', () {
      expect(
        swiftFields(swift, 'Reply'),
        _dartJsonKeys(source: clientSource, from: 'factory FanReply.fromJson'),
      );
    });
  });

  group('a Swift-shaped payload arrives as the values it carries', () {
    // Nothing here matches a Dart fallback default: 4242 is not 0, 'Fan 2' is
    // not the generated name, so a key read under the wrong spelling shows up
    // as a default leaking through rather than passing quietly.
    final fan = <String, Object?>{
      'id': 2,
      'name': 'Fan 2',
      'actualRpm': 4321.5,
      'minRpm': 1200.0,
      'maxRpm': 7199.0,
      'targetRpm': 4400.0,
      'mode': 1,
      'modeKey': 'F2md',
    };
    final sensor = <String, Object?>{
      'key': 'Tp09',
      'celsius': 86.25,
      'type': 'sp78',
    };
    final appliedPolicy = const FanPolicy(
      manualOn: true,
      holdRpm: 3200,
      leaseSeconds: 90,
    );
    final status = <String, Object?>{
      'pid': 4242,
      'uid': 0,
      'isRoot': true,
      'fans': [fan],
      'applied': 'holding',
      'appliedRpm': 3350.0,
      'reason': 'manual override: holding at 3350 rpm',
      'lastError': 'write F2Tg declined once',
      'policy': appliedPolicy.toJson(),
      'leaseExpiresAt': 1700000000,
      'startedAt': 1699999000,
      'ticks': 17,
    };
    final selftest = <String, Object?>{
      'uid': 0,
      'isRoot': true,
      'canOpenSmc': true,
      'fanCount': 2,
      'fans': [fan, fan],
      'sensorCount': 113,
      'hottest': sensor,
      'modeKey': 'F0md',
      'writeAccepted': true,
      'writeDetail': null,
      'verdict': 'fan control writes are accepted as uid 0',
    };

    test('and the payload really does use Swift\'s key names', () {
      expect(fan.keys.toSet(), swiftFields(swift, 'Fan'));
      expect(sensor.keys.toSet(), swiftFields(swift, 'Sensor'));
      expect(status.keys.toSet(), swiftFields(swift, 'Status'));
      expect(selftest.keys.toSet(), swiftFields(swift, 'SelfTestReport'));
    });

    test('a fan keeps its own scale and its mode key spelling', () {
      final reading = FanReading.fromJson(fan);
      expect(reading.id, 2);
      expect(reading.name, 'Fan 2');
      expect(reading.actualRpm, 4321.5);
      expect(reading.minRpm, 1200);
      expect(reading.maxRpm, 7199);
      expect(reading.targetRpm, 4400);
      expect(reading.modeKey, 'F2md');
      expect(reading.isForced, isTrue);
      expect(
        reading.speedFraction,
        closeTo((4321.5 - 1200) / (7199 - 1200), 1e-9),
      );
    });

    test('a missing target rpm stays unknown instead of becoming zero', () {
      final reading = FanReading.fromJson(
        Map<String, Object?>.from(fan)..['targetRpm'] = null,
      );
      expect(reading.targetRpm, isNull);
    });

    test(
      'a sensor keeps its SMC type code, which is why decoding is per key',
      () {
        final parsed = TemperatureSensor.fromJson(sensor);
        expect(parsed.key, 'Tp09');
        expect(parsed.family, 'Tp');
        expect(parsed.type, 'sp78');
        expect(parsed.celsius, 86.25);
      },
    );

    test(
      'telemetry carries the groups the daemon computed, not a UI guess',
      () {
        final telemetry = FanTelemetry.parse(
          jsonEncode({
            'at': 1700000000,
            'fans': [fan],
            'sensors': [sensor],
            'groups': {'cpu': 86.25, 'heatSink': 74.0},
            'machine': 'Mac14,7',
            'pid': 99,
          }),
        );
        expect(
          telemetry.at,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
        );
        expect(telemetry.fans.single.name, 'Fan 2');
        expect(telemetry.hottest?.key, 'Tp09');
        expect(telemetry.temperatureFor(FanSensorGroup.cpu), 86.25);
        expect(telemetry.temperatureFor(FanSensorGroup.gpu), isNull);
        expect(telemetry.machine, 'Mac14,7');
        expect(telemetry.pid, 99);
      },
    );

    test(
      'the daemon\'s status arrives whole, including its policy and lease',
      () {
        final parsed = FanDaemonStatus.fromJson(status);
        expect(parsed.pid, 4242);
        expect(parsed.uid, 0);
        expect(parsed.isRoot, isTrue);
        expect(parsed.fans.single.modeKey, 'F2md');
        expect(parsed.applied, 'holding');
        expect(parsed.isHolding, isTrue);
        expect(parsed.appliedRpm, 3350);
        expect(parsed.reason, contains('manual override'));
        expect(parsed.lastError, contains('declined once'));
        expect(
          parsed.policy,
          appliedPolicy,
          reason:
              'every field of the policy the daemon is holding must survive',
        );
        expect(parsed.ticks, 17);
        expect(
          parsed.leaseExpiresAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
        );
      },
    );

    test('a status with nothing applied yet is a state, not a crash', () {
      final bare = Map<String, Object?>.from(status)
        ..['applied'] = 'automatic'
        ..['policy'] = null
        ..['leaseExpiresAt'] = null
        ..['lastError'] = null
        ..['appliedRpm'] = null;
      final parsed = FanDaemonStatus.fromJson(bare);
      expect(parsed.policy, isNull);
      expect(parsed.leaseExpiresAt, isNull);
      expect(parsed.lastError, isNull);
      expect(parsed.appliedRpm, isNull);
      expect(parsed.isHolding, isFalse);
    });

    test('the privilege report keeps an unknown answer unknown', () {
      final parsed = FanPrivilegeReport.fromJson(selftest);
      expect(parsed.fanCount, 2);
      expect(parsed.sensorCount, 113);
      expect(parsed.hottest?.celsius, 86.25);
      expect(parsed.modeKey, 'F0md');
      expect(parsed.canControlFans, isTrue);

      final unknown = FanPrivilegeReport.fromJson(
        Map<String, Object?>.from(selftest)
          ..['writeAccepted'] = null
          ..['writeDetail'] = 'this Mac reports no fans',
      );
      expect(unknown.canControlFans, isFalse, reason: 'null is not acceptance');
      expect(unknown.writeDetail, contains('no fans'));
    });

    test('a reply nests status and selftest the way Reply does', () {
      final reply = FanReply.tryParse(
        '${jsonEncode({'ok': true, 'error': null, 'status': status, 'selftest': selftest})}\n',
      );
      expect(reply, isNotNull);
      expect(reply!.ok, isTrue);
      expect(reply.isFailure, isFalse);
      expect(reply.status?.appliedRpm, 3350);
      expect(reply.selftest?.verdict, contains('uid 0'));
    });

    test('a refusal reads as a refusal', () {
      final reply = FanReply.tryParse(
        '{"ok":false,"error":"apply needs a policy","status":null,"selftest":null}',
      );
      expect(reply!.isFailure, isTrue);
      expect(reply.error, 'apply needs a policy');
      expect(reply.status, isNull);
    });

    test(
      'silence parses as nothing, which is how a dead daemon is spotted',
      () {
        expect(FanReply.tryParse(''), isNull);
        expect(FanReply.tryParse('not json\n'), isNull);
        expect(FanReply.tryParse('[1,2,3]'), isNull);
      },
    );
  });

  test('the lease default is the same number at both ends', () {
    // Swift only uses its default for a request that omits the field — a
    // hand-run apply, or an older client — and a fan forced forever is the one
    // outcome that must not come from a default.
    final declared = RegExp(r'var leaseSeconds: Int = (\d+)').firstMatch(swift);
    expect(int.parse(declared!.group(1)!), FanPolicy.defaults.leaseSeconds);
  });

  test('the socket path is one name shared by both ends', () {
    expect(
      RegExp(r'let defaultSocketPath = "([^"]+)"').firstMatch(swift)!.group(1),
      FanDaemonClient.defaultSocket,
    );
  });
}

// ------------------------------------------------------------------ extraction

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$path is missing; tests run from the project root');
  }
  return file.readAsStringSync();
}

Set<String> _dartPattern(String source, RegExp pattern) => pattern
    .allMatches(source)
    .map((match) => match.group(1) ?? match.group(2)!)
    .toSet();

/// Stored properties of `struct Name`, not counting a struct nested inside it.
///
/// Computed properties are skipped because `Codable` does not encode them, and
/// `static` ones because they are constants rather than wire. A `{` after the
/// type is how a one-line computed getter looks, which is the whole difference
/// between `var isForced: Bool { mode != 0 }` and `var modeKey: String`.
Set<String> swiftFields(String source, String struct) {
  final header = RegExp('struct $struct\\b[^{]*\\{').firstMatch(source);
  if (header == null) throw StateError('no struct $struct in the helper');
  var body = _braced(source, header.end - 1);
  final nested = body.indexOf('struct ');
  if (nested >= 0) body = body.substring(0, nested);
  final stored = <String>{};
  for (final line in body.split('\n')) {
    final declaration = RegExp(r'^\s*(?:let|var)\s+(\w+)\s*:').firstMatch(line);
    if (declaration == null) continue;
    if (line.contains('static')) continue;
    if (line.substring(declaration.end).contains('{')) continue;
    stored.add(declaration.group(1)!);
  }
  if (stored.isEmpty) throw StateError('struct $struct declares no fields');
  return stored;
}

/// The raw values of `enum SensorGroup: String, CaseIterable`.
Set<String> swiftSensorGroups(String source) {
  final header = RegExp('enum SensorGroup\\b[^{]*\\{').firstMatch(source);
  if (header == null) throw StateError('no SensorGroup in the helper');
  final body = _braced(source, header.end - 1);
  final names = <String>{};
  for (final match in RegExp(
    r'^\s*case\s+([\w\s,]+)$',
    multiLine: true,
  ).allMatches(body)) {
    for (final name in match.group(1)!.split(',')) {
      if (name.trim().isNotEmpty) names.add(name.trim());
    }
  }
  if (names.isEmpty) throw StateError('SensorGroup declares no cases');
  return names;
}

/// The commands the socket handler switches on, up to its `default`, so the
/// helper's own CLI subcommands cannot be mistaken for protocol verbs.
Set<String> swiftSocketCommands(String source) => _dartPattern(
  _until(source.indexOf('switch request.cmd'), 'default:', source),
  RegExp(r'case "(\w+)":'),
);

/// The subcommands `main` switches on.
Set<String> swiftCliCommands(String source) => _dartPattern(
  _until(source.indexOf('switch command {'), 'default:', source),
  RegExp(r'case "(\w+)":'),
);

String _until(int start, String marker, String source) {
  if (start < 0) throw StateError('the dispatch on "$marker" is missing');
  final stop = source.indexOf(marker, start);
  return stop < 0 ? source.substring(start) : source.substring(start, stop);
}

/// Every JSON key the Dart reader starting at [from] asks for.
///
/// The region ends at the closing of the constructor itself, so a key mentioned
/// by a neighbouring member cannot be swept into this one.
Set<String> _dartJsonKeys({required String source, required String from}) {
  final start = source.indexOf(from);
  if (start < 0) throw StateError('$from is missing from the Dart source');
  final rest = source.substring(start + from.length);
  final close = RegExp(r'\n  (?:\}|\);)').firstMatch(rest);
  final body = rest.substring(0, close?.start ?? rest.length);
  final keys = RegExp(
    r"""\['(\w+)'\]""",
  ).allMatches(body).map((match) => match.group(1)!).toSet();
  keys.addAll(
    RegExp(
      r"\bnumber\('(\w+)'\)",
    ).allMatches(body).map((match) => match.group(1)!),
  );
  if (keys.isEmpty) throw StateError('$from reads no JSON keys');
  return keys;
}

String _braced(String source, int openBrace) {
  var depth = 0;
  for (var i = openBrace; i < source.length; i++) {
    if (source[i] == '{') {
      depth++;
    } else if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(openBrace + 1, i);
    }
  }
  throw StateError('unbalanced braces at offset $openBrace');
}
