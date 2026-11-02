import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/platform/runner.dart';
import 'package:toolshed/tools/docker/docker_backend.dart';
import 'package:toolshed/tools/docker/docker_engine.dart';
import 'package:toolshed/tools/docker/docker_screen.dart';
import 'package:toolshed/tools/registry.dart';

class _FakeRunner extends ProcessRunner {
  _FakeRunner();

  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    calls.add(arguments);
    if (arguments.first == 'ps') {
      return ProcResult(
        'docker',
        0,
        jsonEncode(<String, Object?>{
          'ID': 'a1b2c3d4e5f6aa11',
          'Names': 'web',
          'Image': 'nginx:latest',
          'State': 'running',
          'Status': 'Up 3 hours',
          'Ports': '0.0.0.0:8080->80/tcp, [::]:8080->80/tcp',
          'CreatedAt': '2026-01-01T10:00:00Z',
        }),
        '',
      );
    }
    if (arguments.first == 'images') {
      return ProcResult(
        'docker',
        0,
        jsonEncode(<String, Object?>{
          'ID': 'sha256:11112222333344445555',
          'Repository': 'nginx',
          'Tag': 'latest',
          'CreatedSince': '2 weeks ago',
          'Size': '142MB',
        }),
        '',
      );
    }
    if (arguments.first == 'system') {
      return const ProcResult('docker', 0, '', '');
    }
    if (arguments.first == 'info') {
      return const ProcResult('docker', 0, '27.1.1\torb', '');
    }
    return const ProcResult('docker', 0, '', '');
  }
}

/// Reads fail while the daemon is down; a `colima start` succeeds and marks the
/// engine up so the following reload reads an empty-but-healthy engine.
class _EngineRunner extends ProcessRunner {
  final List<String> executables = [];
  final List<List<String>> calls = [];
  bool daemonDown = true;

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    executables.add(executable);
    calls.add(arguments);
    if (daemonDown &&
        const {'ps', 'images', 'system', 'info'}.contains(arguments.first)) {
      return const ProcResult(
        'docker',
        1,
        '',
        'Cannot connect to the Docker daemon.',
      );
    }
    if (executable.endsWith('colima')) {
      daemonDown = false;
      return const ProcResult('colima', 0, 'colima is running', '');
    }
    return const ProcResult('docker', 0, '', '');
  }
}

/// Holds every read open until [gate] completes, so the test can observe the
/// console mid-load — the state where the engine button must be disabled.
class _HangingRunner extends ProcessRunner {
  final Completer<void> gate = Completer<void>();

  @override
  Future<ProcResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
  }) async {
    await gate.future;
    return const ProcResult('docker', 1, '', 'Cannot connect to the Docker daemon.');
  }
}

const _colima = DockerEngineManager(
  kind: DockerEngineKind.colima,
  label: 'Colima',
  start: ['/usr/bin/colima', 'start'],
  stop: ['/usr/bin/colima', 'stop'],
);

late final String _cli;

void main() {
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('dockerbin');
    _cli = '${dir.path}/docker';
    File(_cli).writeAsStringSync('#!/bin/sh\n');
  });

  testWidgets('lists containers and frees one through the confirm dialog', (
    tester,
  ) async {
    final runner = _FakeRunner();
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        runner: runner,
        dockerPath: _cli,
        engineDiscover: () => null,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(
        home: DockerScreen(registry: registry, entry: entry),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx:latest'), findsWidgets);

    await tester.tap(find.byTooltip('Stop web'));
    await tester.pumpAndSettle();
    expect(find.text('Stop web?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pumpAndSettle();

    expect(
      runner.calls.any((c) => c.join(' ') == 'stop a1b2c3d4e5f6aa11'),
      isTrue,
    );
    expect(find.text('web stopped.'), findsOneWidget);
  });

  testWidgets('remove is the danger path and asks before sending rm -f', (
    tester,
  ) async {
    final runner = _FakeRunner();
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        runner: runner,
        dockerPath: _cli,
        engineDiscover: () => null,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(
        home: DockerScreen(registry: registry, entry: entry),
      ),
    );
    await tester.pumpAndSettle();

    // Remove lives behind the overflow menu, not the primary button.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(
      runner.calls.any((c) => c.join(' ') == 'rm -f a1b2c3d4e5f6aa11'),
      isTrue,
    );
  });

  testWidgets('with no CLI the screen explains itself and shows no controls', (
    tester,
  ) async {
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        dockerPath: '/nope/docker',
        discover: () => null,
        engineDiscover: () => null,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(
        home: DockerScreen(registry: registry, entry: entry),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Docker is not available here'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Stop web'), findsNothing);
  });

  testWidgets('a stopped engine can be started from the console', (
    tester,
  ) async {
    final runner = _EngineRunner();
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        runner: runner,
        dockerPath: _cli,
        engineDiscover: () => _colima,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(
        home: DockerScreen(registry: registry, entry: entry),
      ),
    );
    await tester.pumpAndSettle();

    // Daemon is down, so the read failed — but the manager is offered anyway.
    expect(find.text('Engine: Colima'), findsOneWidget);
    expect(find.text('Start Colima'), findsOneWidget);

    await tester.tap(find.text('Start Colima'));
    await tester.pumpAndSettle();

    expect(runner.executables, contains('/usr/bin/colima'));
    expect(find.textContaining('Colima started'), findsOneWidget);
    // The reload found the engine up, so the button flipped to Stop.
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('stopping the engine must be confirmed first', (tester) async {
    final runner = _EngineRunner()..daemonDown = false;
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        runner: runner,
        dockerPath: _cli,
        engineDiscover: () => _colima,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(
        home: DockerScreen(registry: registry, entry: entry),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();

    // Nothing sent until the dialog is accepted; the cost is said out loud.
    expect(find.text('Stop Colima?'), findsOneWidget);
    expect(find.textContaining('goes down'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop engine'));
    await tester.pumpAndSettle();

    expect(runner.calls.any((c) => c.join(' ') == 'stop'), isTrue);
  });

  testWidgets('a published port is one clickable link that opens the browser', (
    tester,
  ) async {
    final runner = _FakeRunner();
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        runner: runner,
        dockerPath: _cli,
        engineDiscover: () => null,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(home: DockerScreen(registry: registry, entry: entry)),
    );
    await tester.pumpAndSettle();

    // The v4 and v6 lines for host port 8080 collapse into a single chip.
    expect(find.text('8080 → 80/tcp'), findsOneWidget);

    await tester.tap(find.text('8080 → 80/tcp'));
    await tester.pumpAndSettle();

    expect(
      runner.calls.any((c) => c.contains('http://localhost:8080')),
      isTrue,
    );
    expect(find.textContaining('Opened http://localhost:8080'), findsOneWidget);
  });

  testWidgets('the engine Start/Stop button is disabled while the read loads', (
    tester,
  ) async {
    final runner = _HangingRunner();
    final registry = ToolRegistry.forBackends([
      DockerBackend(
        runner: runner,
        dockerPath: _cli,
        engineDiscover: () => _colima,
      ),
    ]);
    final entry = registry.byId('docker')!;

    await tester.pumpWidget(
      MaterialApp(home: DockerScreen(registry: registry, entry: entry)),
    );
    await tester.pump(); // first frame: the read is still hanging.

    final start = find.widgetWithText(FilledButton, 'Start Colima');
    expect(start, findsOneWidget);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(find.text('Checking the engine…'), findsOneWidget);

    runner.gate.complete();
    await tester.pumpAndSettle(); // the read finished; the choice is real.
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
  });
}
