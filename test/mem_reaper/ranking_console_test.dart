import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/tools/mem_reaper/managed_app.dart';
import 'package:toolshed/tools/mem_reaper/ranking_screen.dart';
import 'package:toolshed/tools/mem_reaper/stop_outcome.dart';
import 'package:toolshed/tools/registry.dart';
import 'package:toolshed/tools/tool_backend.dart';
import 'package:toolshed/ui/theme.dart';

/// A ranking of four processes and a reaper that records what it was asked.
class _B extends ToolBackend implements MemoryRanking, ProcessReaper {
  final stops = <String>[];
  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: 'mem_reaper',
    name: 'Memory Reaper',
    summary: 's',
    implPath: 'mem_reaper.py',
  );
  @override
  Capabilities get capabilities => const Capabilities(
    support: Support.full,
    actions: {ToolAction.forceStop, ToolAction.showRanking},
    reason: 'r',
  );
  @override
  Future<List<ManagedApp>> ranked({
    int windowDays = 7,
    int limit = 100,
  }) async => [
    for (final (i, (n, gb)) in [
      ('Google Chrome Helper (Renderer)', 3.4),
      ('Xcode', 2.1),
      ('Slack Helper', 1.2),
      ('node', 0.8),
    ].indexed)
      ManagedApp(
        id: '${4000 + i}',
        name: n,
        liveBytes: (gb * 1024 * 1024 * 1024).round(),
        detail: '/Applications/$n.app/Contents/MacOS/$n',
        killMode: KillMode.viaReaper,
      ),
  ];
  @override
  Future<void> reapNow() async {}
  @override
  Future<StopOutcome> stopProcess(
    ManagedApp app, {
    bool immediate = false,
  }) async {
    stops.add('${app.id}:$immediate');
    return StopOutcome(result: StopResult.stopped, name: app.name);
  }

  @override
  Future<AgentStatus> status() async =>
      const AgentStatus(state: AgentState.running);
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
  Future<_B> open(WidgetTester tester) async {
    final backend = _B();
    final registry = ToolRegistry.forBackends([backend]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.of(Brightness.light),
        home: RankingScreen(registry: registry, entry: registry.tools.single),
      ),
    );
    await tester.pumpAndSettle();
    return backend;
  }

  testWidgets('Cancel sends nothing and keeps the row', (tester) async {
    final backend = await open(tester);
    await tester.tap(find.byTooltip('Force stop Xcode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.stops, isEmpty);
    expect(find.text('Xcode'), findsOneWidget);
  });

  testWidgets('a confirmed stop is sent once and the row leaves the list', (
    tester,
  ) async {
    final backend = await open(tester);
    await tester.tap(find.byTooltip('Force stop Xcode'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Force stop'));
    await tester.pumpAndSettle();
    expect(backend.stops, ['4001:true']);
    expect(find.text('Xcode'), findsNothing);
    expect(find.text('Stopped Xcode.'), findsOneWidget);
  });
}
