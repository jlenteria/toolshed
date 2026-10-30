import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/tools/mem_reaper/managed_app.dart';
import 'package:toolshed/tools/mem_reaper/stop_outcome.dart';
import 'package:toolshed/tools/port_warden/port_listener.dart';
import 'package:toolshed/tools/port_warden/port_screen.dart';
import 'package:toolshed/tools/registry.dart';
import 'package:toolshed/tools/tool_backend.dart';
import 'package:toolshed/ui/theme.dart';

/// Four sockets and a stopper that records what it was asked. Two of them —
/// one with no visible owner and one Apple system daemon — are exactly what
/// mem_reaper refuses, so the screen must leave them out.
class _B extends ToolBackend implements PortInspector, ProcessStopper {
  _B({this.stoppable = true});

  final bool stoppable;
  final stops = <String>[];
  List<PortListener> rows = [
    const PortListener(
      port: 3000,
      protocol: PortProtocol.tcp,
      addresses: ['*'],
      pid: 4321,
      processName: 'node',
      user: 'me',
      command: '/usr/local/bin/node',
    ),
    const PortListener(
      port: 5432,
      protocol: PortProtocol.tcp,
      addresses: ['127.0.0.1'],
      pid: 812,
      processName: 'postgres',
      user: 'me',
    ),
    const PortListener(
      port: 5353,
      protocol: PortProtocol.udp,
      addresses: ['0.0.0.0'],
    ),
    const PortListener(
      port: 5000,
      protocol: PortProtocol.tcp,
      addresses: ['*'],
      pid: 637,
      processName: 'ControlCenter',
      user: 'me',
      command:
          '/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/'
          'ControlCenter',
    ),
  ];

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: 'port_warden',
    name: 'Port Warden',
    summary: 's',
    implPath: 'lsof',
  );

  @override
  Capabilities get capabilities => Capabilities(
    support: Support.full,
    actions: {ToolAction.showPorts, if (stoppable) ToolAction.forceStop},
    reason: 'No stop here.',
  );

  @override
  Future<List<PortListener>> listening() async => rows;

  @override
  Future<StopOutcome> stopProcess(
    ManagedApp app, {
    bool immediate = false,
  }) async {
    stops.add('${app.id}:$immediate');
    rows = rows.where((row) => '${row.pid}' != app.id).toList();
    return StopOutcome(result: StopResult.stopped, name: app.name);
  }

  @override
  Future<AgentStatus> status() async => const AgentStatus.notApplicable();

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
  Future<_B> open(WidgetTester tester, {bool stoppable = true}) async {
    final backend = _B(stoppable: stoppable);
    final registry = ToolRegistry.forBackends([backend]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.of(Brightness.light),
        home: PortScreen(registry: registry, entry: registry.tools.single),
      ),
    );
    await tester.pumpAndSettle();
    return backend;
  }

  testWidgets('one row per process and port, with the owner and address', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('node'), findsOneWidget);
    expect(find.text('postgres'), findsOneWidget);
    expect(find.text('3000'), findsOneWidget);
    expect(find.text('TCP · all interfaces · pid 4321 · me'), findsOneWidget);
    expect(find.text('/usr/local/bin/node'), findsOneWidget);
    // The ownerless socket and ControlCenter are not in the list at all.
    expect(find.text('owner not visible'), findsNothing);
    expect(find.text('ControlCenter'), findsNothing);
    expect(
      find.text(
        '2 socket(s) belong to protected system processes and are not listed; '
        'mem_reaper will not stop them.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('sockets the agent would refuse are left out, not disabled', (
    tester,
  ) async {
    await open(tester);

    expect(find.byTooltip('Free port 5353'), findsNothing);
    expect(find.byTooltip('Free port 5000'), findsNothing);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    expect(find.byTooltip('Free port 3000'), findsOneWidget);
    // Both listed sockets can be acted on, which is the point of the filter.
    expect(find.byIcon(Icons.link_off_rounded), findsNWidgets(2));
  });

  testWidgets('the search narrows by port or process name', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '5432');
    await tester.pump();

    expect(find.text('postgres'), findsOneWidget);
    expect(find.text('node'), findsNothing);

    await tester.enterText(find.byType(TextField), 'postgres');
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'postgres'), findsOneWidget);
  });

  testWidgets('Cancel sends nothing and keeps the row', (tester) async {
    final backend = await open(tester);

    await tester.tap(find.byTooltip('Free port 3000'));
    await tester.pumpAndSettle();
    expect(find.text('Free port 3000?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(backend.stops, isEmpty);
    expect(find.text('node'), findsOneWidget);
  });

  testWidgets('a confirmed free is sent once and the table is read again', (
    tester,
  ) async {
    final backend = await open(tester);

    await tester.tap(find.byTooltip('Free port 3000'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Free port'));
    await tester.pumpAndSettle();

    expect(backend.stops, ['4321:true']);
    expect(find.text('node'), findsNothing);
    expect(find.text('Stopped node.'), findsOneWidget);
  });

  testWidgets('without the stop action there are no free buttons', (
    tester,
  ) async {
    await open(tester, stoppable: false);

    expect(find.byTooltip('Free port 3000'), findsNothing);
    expect(find.text('No stop here.'), findsOneWidget);
    // Nothing can be stopped on this platform, so the table stays a full
    // report of what is listening rather than a list of controllable rows.
    expect(find.text('owner not visible'), findsOneWidget);
    expect(find.text('ControlCenter'), findsOneWidget);
    expect(find.textContaining('are not listed'), findsNothing);
  });
}
