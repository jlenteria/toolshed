import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/app_info.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/tools/registry.dart';
import 'package:toolshed/tools/tool_backend.dart';
import 'package:toolshed/ui/screens/tools_screen.dart';
import 'package:toolshed/ui/theme.dart';

/// An inert tool, so the dashboard has a card and needs no hardware.
class _Backend extends ToolBackend {
  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: 'demo',
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
  Future<AgentStatus> status() async =>
      const AgentStatus(state: AgentState.installedStopped);

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
  Future<void> open(WidgetTester tester) async {
    final registry = ToolRegistry.forBackends([_Backend()]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.of(Brightness.light),
        home: ToolsScreen(registry: registry),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the dashboard menu opens About', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('About and support'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About toolshed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Version $appVersion'), findsOneWidget);
    expect(find.textContaining('Zero data collection'), findsOneWidget);
    expect(find.textContaining('No third-party packages'), findsOneWidget);
  });

  testWidgets('the dashboard menu opens Support', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('About and support'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Support toolshed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('optional, voluntary tip'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Never required'), findsOneWidget);
  });
}
