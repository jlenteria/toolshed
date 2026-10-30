import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/port_warden/listener_parsers.dart';
import 'package:toolshed/tools/port_warden/port_listener.dart';

void main() {
  group('lsof', () {
    test('reads pid, user and address, and drops the (LISTEN) suffix', () {
      final rows = parseLsof(
        'COMMAND     PID      USER   FD   TYPE             DEVICE SIZE/OFF '
        'NODE NAME\n'
        'node      12345 jlenteria   22u  IPv6 0x1 0t0  TCP *:3000 (LISTEN)\n',
      );

      final row = rows.single;
      expect(row.port, 3000);
      expect(row.protocol, PortProtocol.tcp);
      expect(row.pid, 12345);
      expect(row.processName, 'node');
      expect(row.user, 'jlenteria');
      expect(row.addresses, ['*']);
      expect(row.addressLabel, 'all interfaces');
    });

    test('merges the same process bound on IPv4, IPv6 and loopback', () {
      final rows = parseLsof(
        'node 12345 me 22u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)\n'
        'node 12345 me 23u IPv6 0x2 0t0 TCP [::1]:3000 (LISTEN)\n'
        'node 12345 me 24u IPv6 0x3 0t0 TCP *:3000 (LISTEN)\n',
      );

      final row = rows.single;
      expect(row.addresses, containsAll(['127.0.0.1', '::1', '*']));
      expect(row.addressLabel, 'all interfaces, 127.0.0.1, ::1');
    });

    test('keeps a bound UDP socket and skips a connected one', () {
      final rows = parseLsof(
        'avahi 812 me 12u IPv4 0x1 0t0 UDP *:5353\n'
        'mDNSRe 900 me 13u IPv4 0x2 0t0 UDP 127.0.0.1:50000->8.8.8.8:53\n',
      );

      expect(rows, hasLength(1));
      expect(rows.single.protocol, PortProtocol.udp);
      expect(rows.single.port, 5353);
      expect(rows.single.processName, 'avahi');
    });

    test('a command name with spaces does not shift the columns', () {
      final rows = parseLsof(
        'My App 900 root 10u IPv4 0x1 0t0 TCP 127.0.0.1:4000 (LISTEN)\n',
      );

      final row = rows.single;
      expect(row.processName, 'My App');
      expect(row.pid, 900);
      expect(row.user, 'root');
      expect(row.port, 4000);
    });

    test('the header and short lines are ignored', () {
      expect(
        parseLsof('COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'),
        isEmpty,
      );
    });
  });

  group('ss', () {
    test('merges one process reported on two stacks', () {
      final rows = parseSs(
        'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
        'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* '
        'users:(("node",pid=4321,fd=22))\n'
        'LISTEN 0 128 [::]:3000 [::]:* users:(("node",pid=4321,fd=23))\n',
      );

      final row = rows.single;
      expect(row.port, 3000);
      expect(row.pid, 4321);
      expect(row.processName, 'node');
      expect(row.addresses, containsAll(['127.0.0.1', '::']));
      expect(row.addressLabel, 'all interfaces, 127.0.0.1');
    });

    test('keeps a socket whose owner is hidden as a row with no pid', () {
      final rows = parseSs(
        'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'
        'LISTEN 0 128 [::]:22 [::]:*\n',
      );

      final row = rows.single;
      expect(row.port, 22);
      expect(row.hasOwner, isFalse);
      expect(row.processLabel, 'owner not visible');
      expect(row.process, isNull);
    });

    test('reads UDP as UNCONN and strips the interface scope', () {
      final rows = parseSs(
        'UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* '
        'users:(("systemd-resolve",pid=700,fd=13))\n',
      );

      final row = rows.single;
      expect(row.protocol, PortProtocol.udp);
      expect(row.addresses, ['127.0.0.53']);
      expect(row.processName, 'systemd-resolve');
    });

    test('two owners of one address become two rows', () {
      final rows = parseSs(
        'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* '
        'users:(("node",pid=1,fd=3),("node",pid=2,fd=4))\n',
      );

      expect(rows.map((r) => r.pid).toSet(), {1, 2});
      expect(rows, hasLength(2));
    });
  });

  group('netstat', () {
    const text =
        'Active Connections\n'
        '\n'
        '  Proto  Local Address          Foreign Address        State           '
        'PID\n'
        '  TCP    0.0.0.0:3000           0.0.0.0:0              LISTENING       '
        '1234\n'
        '  TCP    127.0.0.1:3000         0.0.0.0:0              LISTENING       '
        '1234\n'
        '  TCP    192.168.1.5:55555      93.184.216.34:443      ESTABLISHED     '
        '999\n'
        '  TCP    [::]:3000              [::]:0                 LISTENING       '
        '1234\n'
        '  UDP    0.0.0.0:5353           *:*                                    '
        '812\n';

    test(
      'keeps listeners and bound UDP, and drops established connections',
      () {
        final rows = parseNetstat(text);

        expect(rows, hasLength(2));
        final http = rows.firstWhere((r) => r.port == 3000);
        expect(http.protocol, PortProtocol.tcp);
        expect(http.pid, 1234);
        expect(http.addresses, containsAll(['0.0.0.0', '127.0.0.1', '::']));
        final mdns = rows.firstWhere((r) => r.port == 5353);
        expect(mdns.protocol, PortProtocol.udp);
        expect(mdns.pid, 812);
      },
    );

    test('tasklist names are attached by pid', () {
      final names = parseTasklist(
        '"node.exe","1234","Console","1","45,678 K"\n'
        '"svchost.exe","812","Services","0","9,876 K"\n',
      );
      expect(names, {1234: 'node.exe', 812: 'svchost.exe'});

      final named = attachProcessNames(parseNetstat(text), names);
      expect(named.firstWhere((r) => r.port == 3000).processName, 'node.exe');
      expect(
        named.firstWhere((r) => r.port == 5353).processName,
        'svchost.exe',
      );
    });
  });

  group('rows', () {
    test('sort by port, then TCP before UDP', () {
      final rows = mergeListeners([
        const PortListener(
          port: 5353,
          protocol: PortProtocol.udp,
          addresses: ['*'],
          pid: 2,
        ),
        const PortListener(
          port: 3000,
          protocol: PortProtocol.tcp,
          addresses: ['*'],
          pid: 1,
        ),
        const PortListener(
          port: 3000,
          protocol: PortProtocol.udp,
          addresses: ['*'],
          pid: 3,
        ),
      ]);

      expect(rows.map((r) => '${r.protocolLabel}:${r.port}'), [
        'TCP:3000',
        'UDP:3000',
        'UDP:5353',
      ]);
    });

    test('a stop needs a pid and carries the executable path', () {
      const listener = PortListener(
        port: 3000,
        protocol: PortProtocol.tcp,
        addresses: ['*'],
        pid: 4321,
        processName: 'node',
        command: '/usr/local/bin/node',
      );

      final app = listener.process!;
      expect(app.id, '4321');
      expect(app.detail, '/usr/local/bin/node');
      expect(listener.subtitle, 'TCP · all interfaces · pid 4321');
    });
  });
}
