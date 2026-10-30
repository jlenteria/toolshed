import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/port_warden/port_backend.dart';
import 'package:toolshed/tools/port_warden/port_listener.dart';

/// Answers by command and records the argv, so the backend's scan can be
/// checked without a real socket table.
class _Runner extends ProcessRunner {
  _Runner(this.answer);

  final ProcResult Function(String executable, List<String> arguments) answer;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    calls.add([executable, ...arguments]);
    return answer(executable, arguments);
  }
}

const _lsofTcp =
    'node 4321 me 22u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)\n'
    'node 4321 me 23u IPv6 0x2 0t0 TCP [::1]:3000 (LISTEN)\n';
const _ssTcp =
    'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* '
    'users:(("node",pid=4321,fd=22))\n';
const _ssUdp =
    'UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* '
    'users:(("avahi-daemon",pid=812,fd=12))\n';
const _netstat =
    '  TCP    0.0.0.0:3000           0.0.0.0:0              LISTENING       '
    '4321\n'
    '  TCP    127.0.0.1:3000         0.0.0.0:0              LISTENING       '
    '4321\n'
    '  UDP    0.0.0.0:5353           *:*                                   '
    '812\n';
const _tasklist =
    '"node.exe","4321","Console","1","45,678 K"\n'
    '"avahi-daemon.exe","812","Services","0","9,876 K"\n';

void main() {
  group('macOS', () {
    test('reads both stacks with lsof and fills paths from ps', () async {
      final runner = _Runner((executable, arguments) {
        if (executable == 'lsof' && arguments.contains('-iTCP')) {
          return const ProcResult('lsof', 0, _lsofTcp, '');
        }
        if (executable == 'lsof') {
          // Exit 1 with nothing written is lsof's "no matches", not a failure.
          return const ProcResult('lsof', 1, '', '');
        }
        if (executable == 'ps') {
          return const ProcResult('ps', 0, ' 4321 /usr/local/bin/node\n', '');
        }
        throw StateError('unexpected $executable $arguments');
      });
      final backend = MacOSPortWardenBackend(runner: runner);

      final rows = await backend.listening();

      final row = rows.single;
      expect(row.addressLabel, '127.0.0.1, ::1');
      expect(row.pid, 4321);
      expect(row.command, '/usr/local/bin/node');
      expect(runner.calls[0].sublist(1), ['-nP', '-iTCP', '-sTCP:LISTEN']);
      expect(runner.calls[1].sublist(1), ['-nP', '-iUDP']);
      expect(runner.calls[2].sublist(1), ['-p', '4321', '-o', 'pid=,comm=']);
    });

    test('an lsof that writes an error is a failed scan, not no ports', () {
      final runner = _Runner(
        (_, _) =>
            const ProcResult('lsof', 1, '', 'lsof: illegal option character'),
      );
      expect(
        MacOSPortWardenBackend(runner: runner).listening(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'SCAN_FAILED'),
        ),
      );
    });

    test('no matches on either stack is an empty list and no ps', () async {
      final runner = _Runner((_, _) => const ProcResult('lsof', 1, '', ''));

      expect(await MacOSPortWardenBackend(runner: runner).listening(), isEmpty);
      expect(runner.calls, hasLength(2));
    });

    test('offers the free-port action', () {
      expect(
        MacOSPortWardenBackend().capabilities.can(ToolAction.forceStop),
        isTrue,
      );
    });
  });

  group('Linux', () {
    test('reads TCP and UDP with ss', () async {
      final runner = _Runner(
        (_, arguments) => ProcResult(
          'ss',
          0,
          arguments.first == '-ltnp' ? _ssTcp : _ssUdp,
          '',
        ),
      );

      final rows = await LinuxPortWardenBackend(runner: runner).listening();

      expect(rows.map((r) => r.port), [3000, 5353]);
      expect(rows.first.processName, 'node');
      expect(rows.last.protocol, PortProtocol.udp);
      expect(runner.calls[0].sublist(1), ['-ltnp']);
      expect(runner.calls[1].sublist(1), ['-lunp']);
    });

    test('a failed ss is reported, never read as no ports', () {
      final runner = _Runner(
        (_, _) => const ProcResult('ss', 1, '', 'ss: command not found'),
      );
      expect(
        LinuxPortWardenBackend(runner: runner).listening(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'SCAN_FAILED'),
        ),
      );
    });

    test('does not offer a stop the platform has no rules for', () {
      expect(
        LinuxPortWardenBackend().capabilities.can(ToolAction.forceStop),
        isFalse,
      );
    });
  });

  group('Windows', () {
    test('reads netstat and names the owners from tasklist', () async {
      final runner = _Runner((executable, _) {
        if (executable == 'netstat') {
          return const ProcResult('netstat', 0, _netstat, '');
        }
        if (executable == 'tasklist') {
          return const ProcResult('tasklist', 0, _tasklist, '');
        }
        throw StateError('unexpected $executable');
      });

      final rows = await WindowsPortWardenBackend(runner: runner).listening();

      expect(rows.map((r) => '${r.processName}:${r.port}'), [
        'node.exe:3000',
        'avahi-daemon.exe:5353',
      ]);
      expect(runner.calls[0].sublist(1), ['-ano']);
      expect(runner.calls[1].sublist(1), ['/FO', 'CSV', '/NH']);
    });

    test('a failed tasklist still yields the ports', () async {
      final runner = _Runner((executable, _) {
        if (executable == 'netstat') {
          return const ProcResult('netstat', 0, _netstat, '');
        }
        return const ProcResult('tasklist', 1, '', 'access denied');
      });

      final rows = await WindowsPortWardenBackend(runner: runner).listening();

      expect(rows, hasLength(2));
      expect(rows.first.processName, isNull);
    });

    test('does not offer a stop the platform has no rules for', () {
      expect(
        WindowsPortWardenBackend().capabilities.can(ToolAction.forceStop),
        isFalse,
      );
    });
  });

  test(
    'status says the list is read on demand and names the scanner',
    () async {
      final status = await LinuxPortWardenBackend(
        runner: _Runner((_, _) => const ProcResult('ss', 0, '', '')),
      ).status();

      expect(status.state, AgentState.notApplicable);
      expect(status.notes.single, contains('ss'));
    },
  );

  // The parsers against the machine's own lsof: a format change would pass
  // every canned test above and still show an empty page.
  test('a real scan on this Mac finds listeners with owners', () async {
    final rows = await MacOSPortWardenBackend().listening();

    expect(rows, isNotEmpty);
    expect(rows.where((row) => row.hasOwner), isNotEmpty);
    expect(rows.where((row) => row.command != null), isNotEmpty);
  }, skip: !Platform.isMacOS);
}
