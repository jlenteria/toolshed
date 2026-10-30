import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/tools/registry.dart';
import 'package:toolshed/tools/tool_backend.dart';
import 'package:toolshed/ui/screens/tool_detail_screen.dart';
import 'package:toolshed/ui/screens/tools_screen.dart';

/// A tool whose status read can be held open, so the screen has a moment in
/// which "loading" is visible at all. Everything else is inert: these tests are
/// about the shell, not about a helper.
class _GatedBackend extends ToolBackend {
  _GatedBackend(this.id);

  final String id;

  /// One gate per read, consumed in order. A read with no gate answers at once.
  final List<Completer<void>> gates = [];

  @override
  ToolDescriptor get descriptor => ToolDescriptor(
    id: id,
    name: 'Demo',
    summary: 'A tool with no hardware behind it.',
    implPath: 'demo.swift',
  );

  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {},
    reason: 'nothing to do here',
  );

  @override
  Future<AgentStatus> status() async {
    if (gates.isNotEmpty) await gates.removeAt(0).future;
    return const AgentStatus(state: AgentState.installedStopped);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> install() async {}

  @override
  Future<void> uninstall() async {}

  @override
  Future<ToolConfig> readConfig() async => throw UnimplementedError();

  @override
  Future<void> writeConfig(ToolConfig config) async {}

  @override
  Stream<String> tailLog() => const Stream<String>.empty();
}

void main() {
  test('a refresh keeps the entry busy until the read lands', () async {
    final backend = _GatedBackend('demo');
    final registry = ToolRegistry.forBackends([backend]);
    final entry = registry.tools.single;
    final gate = Completer<void>();
    backend.gates.add(gate);

    final refreshing = registry.refresh(id: 'demo');
    expect(
      entry.busy,
      isTrue,
      reason: 'the bar in the body is drawn from this flag',
    );

    gate.complete();
    await refreshing;
    expect(entry.busy, isFalse);
    expect(entry.status?.state, AgentState.installedStopped);
  });

  testWidgets('the detail refresh draws a bar in the body until it lands', (
    tester,
  ) async {
    final backend = _GatedBackend('demo');
    final registry = ToolRegistry.forBackends([backend]);
    await tester.pumpWidget(
      MaterialApp(
        home: ToolDetailScreen(registry: registry, id: 'demo'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final gate = Completer<void>();
    backend.gates.add(gate);
    await tester.tap(find.byTooltip('Re-read status'));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('the front page draws a bar and card spinners while it reads', (
    tester,
  ) async {
    final backend = _GatedBackend('demo');
    final registry = ToolRegistry.forBackends([backend]);
    await tester.pumpWidget(MaterialApp(home: ToolsScreen(registry: registry)));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final gate = Completer<void>();
    backend.gates.add(gate);
    await tester.tap(find.byTooltip('Re-read every tool'));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
