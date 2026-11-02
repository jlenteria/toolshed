import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/docker/docker_parsers.dart';

/// Builds the exact one-object-per-line stream `--format '{{json .}}'` prints.
String jsonLines(List<Map<String, Object?>> rows) =>
    rows.map(jsonEncode).join('\n');

void main() {
  group('containers', () {
    final running = <String, Object?>{
      'ID': 'a1b2c3d4e5f6aa11',
      'Names': 'web',
      'Image': 'nginx:latest',
      'ImageID': 'sha256:deadbeef',
      'Command': '"nginx -g daemon off;"',
      'State': 'running',
      'Status': 'Up 3 hours',
      'Ports': '0.0.0.0:8080->80/tcp',
      'RunningFor': '3 hours ago',
      'CreatedAt': '2026-01-01T10:00:00Z',
      'Labels': 'com.docker.compose.project=demo,env=prod',
    };
    final exited = <String, Object?>{
      'ID': 'ff00ee00ff00bb22',
      'Names': 'job',
      'Image': 'python:3',
      'State': 'exited',
      'Status': 'Exited (0) 2 hours ago',
      'RunningFor': '5 hours ago',
      'CreatedAt': '2026-01-01T08:00:00Z',
      'Labels': '',
    };

    test('maps the CLI fields and sorts running first', () {
      // Exited comes first in the input to prove the sort, not the order, wins.
      final parsed = parseContainers(jsonLines([exited, running]));
      expect(parsed.containers.map((c) => c.primaryName), ['web', 'job']);

      final web = parsed.containers.first;
      expect(web.isRunning, isTrue);
      expect(web.stateLabel, 'Running');
      expect(web.idShort, 'a1b2c3d4e5f6');
      expect(web.ports, '0.0.0.0:8080->80/tcp');
      expect(web.labels['env'], 'prod');
      expect(web.labels['com.docker.compose.project'], 'demo');

      expect(parsed.containers.last.isRunning, isFalse);
      expect(parsed.containers.last.stateLabel, 'Exited');
    });

    test('splits multiple names and tolerates a missing Size key', () {
      final row = <String, Object?>{
        'ID': 'cafe1234deadbeef',
        'Names': 'api-1,api-2',
        'State': 'running',
        'Status': 'Up 1 minute',
      };
      final container = parseContainers(jsonLines([row])).containers.single;
      expect(container.names, ['api-1', 'api-2']);
      expect(container.name, 'api-1, api-2');
      expect(container.size, isEmpty);
    });

    test(
      'a blank line is skipped and a truncated line is noted, not thrown',
      () {
        final good = jsonEncode(<String, Object?>{
          'ID': 'abcdefabcdefaaaa',
          'Names': 'ok',
          'State': 'running',
          'Status': 'Up',
        });
        final raw = '$good\n\n{"ID":"zzz","Names":"trunca';
        final parsed = parseContainers(raw);
        expect(parsed.containers.map((c) => c.primaryName), ['ok']);
        expect(parsed.partial, contains('truncated'));
      },
    );

    test('an empty output is an empty list, not a failure', () {
      expect(parseContainers('').containers, isEmpty);
    });
  });

  group('ports', () {
    test('splits a published v4 mapping into its host and container halves',
        () {
      final ports = parsePorts('0.0.0.0:24400->80/tcp');
      expect(ports, hasLength(1));
      final p = ports.single;
      expect(p.isPublished, isTrue);
      expect(p.hostIp, '*');
      expect(p.hostPort, '24400');
      expect(p.containerPort, '80');
      expect(p.proto, 'tcp');
      expect(p.url, 'http://localhost:24400');
    });

    test('a dual-stack bind collapses to one browsable port', () {
      // Docker prints `0.0.0.0` and `[::]` lines for the same host port.
      final ports = parsePorts('0.0.0.0:8080->80/tcp, [::]:8080->80/tcp');
      expect(ports, hasLength(1));
      expect(ports.single.url, 'http://localhost:8080');
    });

    test('an exposed-only port is kept but never browsable', () {
      final ports = parsePorts('8080/tcp');
      expect(ports.single.isPublished, isFalse);
      expect(ports.single.url, isNull);
      expect(ports.single.label, '8080/tcp');
    });

    test('mixes published and internal ports and defaults a missing proto', () {
      final ports = parsePorts('0.0.0.0:443->443/udp, 9000');
      expect(ports.map((p) => p.isPublished), [true, false]);
      expect(ports.first.url, 'http://localhost:443');
      expect(ports.last.proto, 'tcp');
    });

    test('a non-numeric host port is not treated as published', () {
      // Guards the browser hand: only digits ever reach the URL.
      expect(parsePorts('0.0.0.0:http->80/tcp').single.isPublished, isFalse);
    });

    test('an empty ports field yields no mappings', () {
      expect(parsePorts(''), isEmpty);
      expect(parsePorts('   '), isEmpty);
    });

    test('a container carries its parsed mappings alongside the raw string', () {
      final row = <String, Object?>{
        'ID': 'aaaabbbbccccdddd',
        'Names': 'web',
        'State': 'running',
        'Status': 'Up',
        'Ports': '0.0.0.0:8080->80/tcp, [::]:8080->80/tcp',
      };
      final container = parseContainers(jsonLines([row])).containers.single;
      expect(container.ports, '0.0.0.0:8080->80/tcp, [::]:8080->80/tcp');
      expect(container.portMappings, hasLength(1));
      expect(container.portMappings.single.url, 'http://localhost:8080');
    });
  });

  group('images', () {
    final tagged = <String, Object?>{
      'ID': 'sha256:11112222333344445555',
      'Repository': 'nginx',
      'Tag': 'latest',
      'CreatedSince': '2 weeks ago',
      'CreatedAt': '2025-12-20T00:00:00Z',
      'Size': '142MB',
    };
    final dangling = <String, Object?>{
      'ID': 'sha256:aaaabbbbccccddddeeee',
      'Repository': '<none>',
      'Tag': '<none>',
      'CreatedSince': '3 days ago',
      'CreatedAt': '2025-12-30T00:00:00Z',
      'Size': '98MB',
    };

    test('marks dangling images and pushes them to the bottom', () {
      // Dangling input first to prove the sort moves it last.
      final parsed = parseImages(jsonLines([dangling, tagged]));
      expect(parsed.images.map((i) => i.isDangling), [false, true]);
      expect(parsed.images.first.ref, 'nginx:latest');
      expect(parsed.images.last.ref, contains('dangling'));
      // sha256 ids are shortened to the 12 hex chars after the prefix.
      expect(parsed.images.first.idShort, '111122223333');
      expect(parsed.images.last.idShort, 'aaaabbbbcccc');
    });

    test('a fully empty repo/tag is dangling too', () {
      final parsed = parseImages(
        jsonLines([
          <String, Object?>{
            'ID': 'sha256:1234567890abcdef',
            'Repository': '',
            'Tag': '',
          },
        ]),
      );
      expect(parsed.images.single.isDangling, isTrue);
    });
  });

  group('system df', () {
    test('maps each resource line', () {
      final parsed = parseSystemDf(
        jsonLines([
          <String, Object?>{
            'Type': 'Images',
            'Total': '12',
            'Active': '4',
            'Size': '2.1GB',
            'Reclaimable': '500MB (23%)',
          },
          <String, Object?>{
            'Type': 'Containers',
            'Total': '5',
            'Active': '2',
            'Size': '1.2GB',
            'Reclaimable': '800MB (66%)',
          },
        ]),
      );
      expect(parsed.disk.map((d) => d.type), ['Images', 'Containers']);
      expect(parsed.disk.first.reclaimable, '500MB (23%)');
    });
  });
}
