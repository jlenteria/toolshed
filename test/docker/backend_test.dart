import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/docker/docker_backend.dart';
import 'package:toolshed/tools/docker/docker_engine.dart';
import 'package:toolshed/tools/docker/docker_models.dart';

/// A `docker` that answers by subcommand and records the argv it was handed,
/// so the console's commands can be pinned without a real engine — the same
/// seam the port_warden tests use for lsof/ss. The executable is recorded too,
/// because engine start/stop run a manager's binary, not `docker`.
class _FakeRunner extends ProcessRunner {
  _FakeRunner(this.answer);

  final ProcResult Function(List<String> arguments) answer;
  final List<List<String>> calls = [];
  final List<String> executables = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    executables.add(executable);
    calls.add(arguments);
    return answer(arguments);
  }
}

/// A file on disk standing in for the docker binary, so `File.existsSync` in the
/// resolver is true and the resolved path is what reaches the fake runner.
late final String _cliPath;

String jsonLines(List<Map<String, Object?>> rows) =>
    rows.map(jsonEncode).join('\n');

final _running = <String, Object?>{
  'ID': 'a1b2c3d4e5f6aa11',
  'Names': 'web',
  'Image': 'nginx:latest',
  'State': 'running',
  'Status': 'Up 3 hours',
  'RunningFor': '3 hours ago',
  'CreatedAt': '2026-01-01T10:00:00Z',
};
final _exited = <String, Object?>{
  'ID': 'ff00ee00ff00bb22',
  'Names': 'job',
  'Image': 'python:3',
  'State': 'exited',
  'Status': 'Exited (0) 2 hours ago',
  'CreatedAt': '2026-01-01T08:00:00Z',
};
final _image = <String, Object?>{
  'ID': 'sha256:11112222333344445555',
  'Repository': 'nginx',
  'Tag': 'latest',
  'CreatedSince': '2 weeks ago',
  'Size': '142MB',
};

const _colima = DockerEngineManager(
  kind: DockerEngineKind.colima,
  label: 'Colima',
  start: ['/usr/bin/colima', 'start'],
  stop: ['/usr/bin/colima', 'stop'],
);

/// The default answer: a healthy engine with one running and one stopped
/// container and one image.
ProcResult _healthy(List<String> args) {
  if (args.first == 'ps') {
    return ProcResult('docker', 0, jsonLines([_running, _exited]), '');
  }
  if (args.first == 'images') {
    return ProcResult('docker', 0, jsonLines([_image]), '');
  }
  if (args.first == 'system') {
    return ProcResult(
      'docker',
      0,
      jsonLines([
        <String, Object?>{
          'Type': 'Images',
          'Total': '2',
          'Active': '1',
          'Size': '142MB',
          'Reclaimable': '0B (0%)',
        },
      ]),
      '',
    );
  }
  if (args.first == 'info') {
    return const ProcResult('docker', 0, '27.1.1\torb', '');
  }
  return ProcResult('docker', 0, '${args.last}\n', '');
}

void main() {
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('dockerbin');
    _cliPath = '${dir.path}/docker';
    File(_cliPath).writeAsStringSync('#!/bin/sh\n');
  });

  DockerBackend backend(_FakeRunner runner) =>
      DockerBackend(runner: runner, dockerPath: _cliPath);

  group('capabilities', () {
    test('a resolved CLI advertises the full action set', () {
      final caps = DockerBackend(dockerPath: _cliPath).capabilities;
      expect(caps.support, Support.full);
      expect(caps.can(ToolAction.showDocker), isTrue);
      expect(caps.can(ToolAction.dockerRemove), isTrue);
      expect(caps.can(ToolAction.dockerPrune), isTrue);
      expect(caps.can(ToolAction.dockerOpenPort), isTrue);
    });

    test('no CLI on disk and none discovered means nothing to gate on', () {
      final caps = DockerBackend(
        dockerPath: '/nope/docker',
        discover: () => null,
        engineDiscover: () => null,
      ).capabilities;
      expect(caps.support, Support.helperMissing);
      expect(caps.actions, isEmpty);
      expect(caps.can(ToolAction.showDocker), isFalse);
    });

    test('no engine manager advertised means no start/stop-engine actions', () {
      final caps = DockerBackend(
        dockerPath: _cliPath,
        engineDiscover: () => null,
      ).capabilities;
      expect(caps.can(ToolAction.showDocker), isTrue);
      expect(caps.can(ToolAction.dockerStartEngine), isFalse);
      expect(caps.can(ToolAction.dockerStopEngine), isFalse);
    });

    test(
      'a discovered manager advertises the engine actions alongside the CLI',
      () {
        final caps = DockerBackend(
          dockerPath: _cliPath,
          engineDiscover: () => _colima,
        ).capabilities;
        expect(caps.support, Support.full);
        expect(caps.can(ToolAction.showDocker), isTrue);
        expect(caps.can(ToolAction.dockerStartEngine), isTrue);
        expect(caps.can(ToolAction.dockerStopEngine), isTrue);
      },
    );

    test('a manager alone, with no CLI, still offers to start the engine', () {
      // The recovery path: OrbStack was stopped, nothing on PATH yet, but
      // Colima is installed — the console can bring the engine up.
      final caps = DockerBackend(
        dockerPath: '/nope/docker',
        discover: () => null,
        engineDiscover: () => _colima,
      ).capabilities;
      expect(caps.support, Support.full);
      expect(caps.can(ToolAction.showDocker), isFalse);
      expect(caps.can(ToolAction.dockerStartEngine), isTrue);
    });

    test(
      'a vanished requested path falls back to discovery, not a dead button',
      () {
        // Simulates OrbStack's shim being uninstalled: the requested path is gone,
        // so discovery decides — and here discovery finds the replacement engine.
        final caps = DockerBackend(
          dockerPath: '/nope/docker',
          discover: () => _cliPath,
        ).capabilities;
        expect(caps.support, Support.full);
      },
    );
  });

  group('inventory', () {
    test('issues ps, images and df and maps all three', () async {
      final runner = _FakeRunner(_healthy);
      final inventory = await backend(runner).inventory();

      expect(runner.calls[0], ['ps', '-a', '--format', '{{json .}}']);
      expect(runner.calls[1], ['images', '--format', '{{json .}}']);
      expect(runner.calls[2], ['system', 'df', '--format', '{{json .}}']);
      expect(inventory.containers.map((c) => c.primaryName), ['web', 'job']);
      expect(inventory.runningCount, 1);
      expect(inventory.images.single.repository, 'nginx');
      expect(inventory.disk.single.type, 'Images');
    });

    test('a ps failure is reported, never read as "no containers"', () {
      final runner = _FakeRunner(
        (_) => const ProcResult(
          'docker',
          1,
          '',
          'Cannot connect to the Docker daemon at unix:///var/run/docker.sock.',
        ),
      );
      expect(
        backend(runner).inventory(),
        throwsA(
          isA<ToolException>()
              .having((e) => e.code, 'code', 'DOCKER_FAILED')
              .having((e) => e.message, 'message', contains('daemon')),
        ),
      );
    });

    test('a df failure degrades to a note, not a lost console', () async {
      ProcResult answer(List<String> args) {
        if (args.first == 'system') {
          return const ProcResult('docker', 1, '', 'error during connect');
        }
        return _healthy(args);
      }

      final inventory = await backend(_FakeRunner(answer)).inventory();
      expect(inventory.containers, hasLength(2));
      expect(inventory.disk, isEmpty);
      expect(inventory.notes.any((n) => n.contains('disk')), isTrue);
    });

    test('without a CLI it refuses before starting a process', () {
      final runner = _FakeRunner(_healthy);
      final noCli = DockerBackend(
        runner: runner,
        dockerPath: '/nope/docker',
        discover: () => null,
      );
      expect(
        noCli.inventory(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'NO_DOCKER'),
        ),
      );
      expect(runner.calls, isEmpty);
    });
  });

  group('container actions', () {
    final web = const DockerContainer(id: 'a1b2c3d4e5f6', names: ['web']);

    test('start, stop and restart send the matching subcommand', () async {
      const verbs = {
        'start': 'started',
        'stop': 'stopped',
        'restart': 'restarted',
      };
      for (final (op, sub) in const [
        (DockerOp.start, 'start'),
        (DockerOp.stop, 'stop'),
        (DockerOp.restart, 'restart'),
      ]) {
        final runner = _FakeRunner(_healthy);
        final result = await backend(runner).containerAction(web, op);
        expect(runner.calls.single, [sub, 'a1b2c3d4e5f6']);
        expect(result.message, 'web ${verbs[sub]}.');
      }
    });

    test('remove sends rm -f and names the container', () async {
      final runner = _FakeRunner(_healthy);
      final result = await backend(
        runner,
      ).containerAction(web, DockerOp.remove);
      expect(runner.calls.single, ['rm', '-f', 'a1b2c3d4e5f6']);
      expect(result.message, 'web removed.');
    });

    test(
      'a failing rm surfaces the engine error rather than a false success',
      () {
        ProcResult answer(List<String> args) => args.first == 'rm'
            ? const ProcResult('docker', 1, '', 'Error: No such container: web')
            : _healthy(args);
        expect(
          backend(_FakeRunner(answer)).containerAction(web, DockerOp.remove),
          throwsA(
            isA<ToolException>().having(
              (e) => e.message,
              'message',
              contains('No such container'),
            ),
          ),
        );
      },
    );
  });

  group('open port', () {
    test('hands the browser the localhost URL for a published port', () async {
      final runner = _FakeRunner(_healthy);
      final result = await backend(runner).openPort(
        const DockerPortMapping(
          containerPort: '80',
          proto: 'tcp',
          hostIp: '*',
          hostPort: '24400',
        ),
      );
      expect(result.message, contains('http://localhost:24400'));
      // The URL reaches an OS opener as a single argument, never a docker call.
      expect(
        runner.calls.any((c) => c.contains('http://localhost:24400')),
        isTrue,
      );
      expect(runner.executables.any((e) => e != _cliPath), isTrue);
    });

    test('refuses an unpublished port without launching anything', () {
      final runner = _FakeRunner(_healthy);
      expect(
        backend(runner).openPort(
          const DockerPortMapping(containerPort: '8080', proto: 'tcp'),
        ),
        throwsA(
          isA<ToolException>().having(
            (e) => e.code,
            'code',
            'NOT_PUBLISHED',
          ),
        ),
      );
      expect(runner.calls, isEmpty);
    });
  });

  group('prune', () {
    test('reports what the CLI says it reclaimed', () async {
      ProcResult answer(List<String> args) => args.contains('prune')
          ? const ProcResult(
              'docker',
              0,
              'Deleted Images:\n...\nTotal reclaimed space: 1.5GB\n',
              '',
            )
          : _healthy(args);
      final runner = _FakeRunner(answer);
      final result = await backend(runner).pruneImages();
      expect(runner.calls.single, ['image', 'prune', '-f']);
      expect(result.reclaimed, '1.5GB');
    });

    test('a failed prune is a DOCKER_FAILED', () {
      ProcResult answer(List<String> args) => args.contains('prune')
          ? const ProcResult('docker', 1, '', 'permission denied')
          : _healthy(args);
      expect(
        backend(_FakeRunner(answer)).pruneImages(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'DOCKER_FAILED'),
        ),
      );
    });
  });

  group('status', () {
    test(
      'an answering daemon reports its version and context-agnostic note',
      () async {
        final status = await backend(_FakeRunner(_healthy)).status();
        expect(status.state, AgentState.notApplicable);
        expect(status.notes.first, contains('27.1.1'));
        expect(status.notes.any((n) => n.contains('context')), isTrue);
      },
    );

    test(
      'an unreachable daemon is named as such, not as no containers',
      () async {
        ProcResult answer(List<String> args) => args.first == 'info'
            ? const ProcResult(
                'docker',
                1,
                '',
                'Cannot connect to the Docker daemon at unix:///run/docker.sock.',
              )
            : _healthy(args);
        final status = await backend(_FakeRunner(answer)).status();
        expect(status.notes.first, contains('daemon did not answer'));
      },
    );

    test('no CLI says install an engine', () async {
      final status = await DockerBackend(
        runner: _FakeRunner(_healthy),
        dockerPath: '/nope/docker',
        discover: () => null,
      ).status();
      expect(status.notes.first, contains('No docker CLI'));
    });
  });

  group('engine start/stop', () {
    test("start runs the manager's own command and reports its line", () async {
      final runner = _FakeRunner(
        (_) =>
            const ProcResult('colima', 0, 'time="..." level=info msg=done', ''),
      );
      final b = DockerBackend(
        runner: runner,
        dockerPath: _cliPath,
        engineDiscover: () => _colima,
      );
      final result = await b.startEngine();
      expect(runner.executables.single, '/usr/bin/colima');
      expect(runner.calls.single, ['start']);
      expect(result.message, contains('Colima started'));
    });

    test('stop runs the stop argv and names the cost', () async {
      final runner = _FakeRunner((_) => const ProcResult('colima', 0, '', ''));
      final b = DockerBackend(
        runner: runner,
        dockerPath: _cliPath,
        engineDiscover: () => _colima,
      );
      final result = await b.stopEngine();
      expect(runner.calls.single, ['stop']);
      expect(result.message, contains('stopped'));
    });

    test('a failing start surfaces ENGINE_FAILED, not a false success', () {
      final runner = _FakeRunner(
        (_) => const ProcResult('colima', 1, '', 'failed to start the VM'),
      );
      final b = DockerBackend(
        runner: runner,
        dockerPath: _cliPath,
        engineDiscover: () => _colima,
      );
      expect(
        b.startEngine(),
        throwsA(
          isA<ToolException>()
              .having((e) => e.code, 'code', 'ENGINE_FAILED')
              .having((e) => e.message, 'message', contains('failed to start')),
        ),
      );
    });

    test('with no manager it refuses before running anything', () {
      final runner = _FakeRunner(_healthy);
      final b = DockerBackend(
        runner: runner,
        dockerPath: _cliPath,
        engineDiscover: () => null,
      );
      expect(
        b.startEngine(),
        throwsA(
          isA<ToolException>().having((e) => e.code, 'code', 'NO_ENGINE'),
        ),
      );
      expect(runner.calls, isEmpty);
    });
  });

  test('it has no agent to install and no settings to write', () {
    final b = DockerBackend(dockerPath: _cliPath);
    expect(b.start(), throwsA(isA<ToolException>()));
    expect(b.install(), throwsA(isA<ToolException>()));
    expect(b.readConfig(), throwsA(isA<ToolException>()));
  });
}
