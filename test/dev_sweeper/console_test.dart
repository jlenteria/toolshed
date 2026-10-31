import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/models/agent_status.dart';
import 'package:toolshed/models/tool_config.dart';
import 'package:toolshed/models/tool_descriptor.dart';
import 'package:toolshed/models/tool_exception.dart';
import 'package:toolshed/tools/dev_sweeper/sweep_screen.dart';
import 'package:toolshed/tools/dev_sweeper/sweep_target.dart';
import 'package:toolshed/tools/registry.dart';
import 'package:toolshed/tools/tool_backend.dart';
import 'package:toolshed/ui/theme.dart';
import 'package:toolshed/ui/widgets/console_parts.dart';

const _gradle = SweepTarget(
  path: '/Users/me/.gradle/caches',
  label: 'Gradle caches',
  ecosystem: 'Gradle',
  bytes: 2 * 1024 * 1024 * 1024,
);
const _modules = SweepTarget(
  path: '/Users/me/Project/app/node_modules',
  label: 'Project/app/node_modules',
  ecosystem: 'Node',
  bytes: 5 * 1024 * 1024,
);

class _Sweeper extends ToolBackend implements CacheSweeper {
  _Sweeper({this.canTrash = true, this.trashResult, this.scanError});

  final bool canTrash;
  final SweepOutcome Function(List<SweepTarget>)? trashResult;
  final Object? scanError;

  List<SweepTarget> rows = [_gradle, _modules];
  final List<List<SweepTarget>> moved = [];
  int scans = 0;
  final List<String> notes = ['Only build caches and node_modules are listed.'];

  @override
  ToolDescriptor get descriptor => const ToolDescriptor(
    id: 'dev_sweeper',
    name: 'Dev Sweeper',
    summary: 's',
    implPath: 'du · find · Trash',
  );

  @override
  Capabilities get capabilities => Capabilities(
    support: Support.full,
    actions: {ToolAction.showCaches, if (canTrash) ToolAction.trashCaches},
    reason: 'The Trash is not available in this test.',
  );

  @override
  Future<SweepReport> scanCaches() async {
    scans++;
    if (scanError != null) throw scanError!;
    return SweepReport(List<SweepTarget>.of(rows), notes: notes);
  }

  @override
  Future<SweepOutcome> trashCaches(List<SweepTarget> targets) async {
    moved.add(targets);
    final outcome =
        trashResult?.call(targets) ??
        SweepOutcome(
          trashed: targets,
          failures: const [],
          freedBytes: targets.fold(0, (sum, row) => sum + (row.bytes ?? 0)),
        );
    final gone = {for (final row in outcome.trashed) row.path};
    rows = [
      for (final row in rows)
        if (!gone.contains(row.path)) row,
    ];
    return outcome;
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
  Future<_Sweeper> open(
    WidgetTester tester, {
    bool canTrash = true,
    SweepOutcome Function(List<SweepTarget>)? trashResult,
    Object? scanError,
  }) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = _Sweeper(
      canTrash: canTrash,
      trashResult: trashResult,
      scanError: scanError,
    );
    final registry = ToolRegistry.forBackends([backend]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.of(Brightness.light),
        home: SweepScreen(registry: registry, entry: registry.tools.single),
      ),
    );
    await tester.pumpAndSettle();
    return backend;
  }

  testWidgets('lists every cache measured, grouped largest first', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Gradle caches'), findsOneWidget);
    expect(find.text('Project/app/node_modules'), findsOneWidget);
    expect(find.text('/Users/me/.gradle/caches'), findsOneWidget);
    expect(find.widgetWithText(StatTile, '2'), findsOneWidget);
    expect(find.widgetWithText(StatTile, '2.0 GB'), findsOneWidget);
    expect(find.text('2.0 GB'), findsNWidgets(3));
    expect(find.text('5.0 MB'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('GRADLE')).dy,
      lessThan(tester.getTopLeft(find.text('NODE')).dy),
    );
    expect(
      find.text('Only build caches and node_modules are listed.'),
      findsOneWidget,
    );
  });

  testWidgets('nothing is selected until it is ticked', (tester) async {
    await open(tester);

    expect(find.text('Move to the Trash'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.tap(find.text('Gradle caches'));
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
    expect(find.widgetWithText(StatTile, '2.0 GB'), findsNWidgets(2));
    expect(find.text('Move 1 item (2.0 GB) to the Trash'), findsOneWidget);
  });

  testWidgets('a confirmed move sends exactly the ticked target and rescans', (
    tester,
  ) async {
    final backend = await open(tester);

    await tester.tap(find.text('Gradle caches'));
    await tester.pump();
    await tester.tap(find.text('Move 1 item (2.0 GB) to the Trash'));
    await tester.pumpAndSettle();

    expect(find.text('Move 1 item to the Trash?'), findsOneWidget);
    expect(find.textContaining('will be moved, not deleted'), findsOneWidget);
    expect(find.text('Gradle caches — 2.0 GB'), findsOneWidget);

    await tester.tap(find.text('Move to Trash'));
    await tester.pumpAndSettle();

    expect(backend.moved, hasLength(1));
    expect(backend.moved.single.single.path, '/Users/me/.gradle/caches');
    expect(backend.scans, 2);
    expect(find.text('Gradle caches'), findsNothing);
    expect(find.text('Project/app/node_modules'), findsOneWidget);
    expect(find.text('Moved 1 item (2.0 GB) to the Trash.'), findsOneWidget);
  });

  testWidgets('Cancel sends nothing and keeps the row', (tester) async {
    final backend = await open(tester);

    await tester.tap(find.text('Gradle caches'));
    await tester.pump();
    await tester.tap(find.text('Move 1 item (2.0 GB) to the Trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(backend.moved, isEmpty);
    expect(backend.scans, 1);
    expect(find.text('Gradle caches'), findsOneWidget);
  });

  testWidgets('Select shown selects only what the search left visible', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'node');
    await tester.pump();
    expect(find.text('Gradle caches'), findsNothing);
    expect(find.text('Project/app/node_modules'), findsOneWidget);

    await tester.tap(find.text('Select shown'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    expect(find.text('Gradle caches'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Move 1 item (5.0 MB) to the Trash'), findsOneWidget);
  });

  testWidgets('Scan again picks up a cache that appeared since the open', (
    tester,
  ) async {
    final backend = await open(tester);
    backend.rows = [
      ...backend.rows,
      const SweepTarget(
        path: '/Users/me/.pub-cache',
        label: 'Pub cache',
        ecosystem: 'Dart',
        bytes: 300 * 1024 * 1024,
      ),
    ];

    await tester.tap(find.byTooltip('Scan again'));
    await tester.pumpAndSettle();

    expect(backend.scans, 2);
    expect(find.text('Pub cache'), findsOneWidget);
    expect(find.text('DART'), findsOneWidget);
  });

  testWidgets('an empty scan says so rather than showing zeroes', (
    tester,
  ) async {
    final backend = await open(tester);
    backend.rows = [];

    await tester.tap(find.byTooltip('Scan again'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing to reclaim.'), findsOneWidget);
    expect(find.text('Gradle caches'), findsNothing);
  });

  testWidgets('a failed scan is a banner, not an empty list', (tester) async {
    await open(
      tester,
      scanError: const ToolException('SCAN_FAILED', 'du is missing'),
    );

    final banner = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(banner.data, '[SCAN_FAILED] du is missing');
    expect(find.text('Nothing to reclaim.'), findsNothing);
  });

  testWidgets('a failed move keeps the rows and names the path and reason', (
    tester,
  ) async {
    await open(
      tester,
      trashResult: (targets) => SweepOutcome(
        trashed: const [],
        failures: [
          for (final target in targets)
            SweepFailure(target: target, message: 'Permission denied.'),
        ],
        freedBytes: 0,
      ),
    );

    await tester.tap(find.text('Gradle caches'));
    await tester.pump();
    await tester.tap(find.text('Move 1 item (2.0 GB) to the Trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Trash'));
    await tester.pumpAndSettle();

    expect(
      find.text('Nothing could be moved. Permission denied.'),
      findsOneWidget,
    );
    expect(find.text('Gradle caches'), findsOneWidget);
    final banner = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(banner.data, '/Users/me/.gradle/caches: Permission denied.');
  });

  testWidgets('without the trash action the rows are read-only and explained', (
    tester,
  ) async {
    await open(tester, canTrash: false);

    expect(
      find.text('The Trash is not available in this test.'),
      findsOneWidget,
    );
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox).first).onChanged,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
