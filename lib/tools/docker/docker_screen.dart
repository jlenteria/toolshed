import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/capability_notice.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'docker_engine.dart';
import 'docker_models.dart';

/// Containers and images read from the `docker` CLI on demand, with the safe
/// lifecycle actions the CLI will honour. There is no agent behind this screen:
/// every row is what the engine said the last time it was asked.
class DockerScreen extends StatefulWidget {
  const DockerScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<DockerScreen> createState() => _DockerScreenState();
}

class _DockerScreenState extends State<DockerScreen> {
  DockerInventory? _inventory;
  String? _error;
  String _query = '';
  bool _loading = true;
  final Set<String> _acting = {};
  bool _pruning = false;
  DockerEngineManager? _engine;
  bool _engineBusy = false;

  String get _toolId => widget.entry.descriptor.id;

  Capabilities get _caps => widget.entry.capabilities;

  bool get _canRead => _caps.can(ToolAction.showDocker);

  /// A manager exists that the console can start or stop, independent of
  /// whether there is a CLI to read through yet.
  bool get _canEngine =>
      _engine != null &&
      (_caps.can(ToolAction.dockerStartEngine) ||
          _caps.can(ToolAction.dockerStopEngine));

  /// The engine is treated as up when the last inventory read succeeded; a
  /// failed or never-run read means Start is the relevant button.
  bool get _engineUp => _inventory != null;

  @override
  void initState() {
    super.initState();
    _engine = widget.registry.dockerEngine(_toolId);
    if (_canRead) {
      _load();
    } else {
      // Nothing to read, so the read bar must not spin forever on a console that
      // is only going to explain why it has no buttons.
      _loading = false;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inventory = await widget.registry.dockerInventory(_toolId);
      if (mounted) setState(() => _inventory = inventory);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  List<DockerContainer> get _shownContainers {
    final all = _inventory?.containers ?? const <DockerContainer>[];
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all.where((c) => c.matches(query)).toList();
  }

  List<DockerImage> get _shownImages {
    final all = _inventory?.images ?? const <DockerImage>[];
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all.where((i) => i.matches(query)).toList();
  }

  List<DockerOp> _opsFor(DockerContainer container) => [
    if (container.isRunning) ...[
      if (_caps.can(ToolAction.dockerStop)) DockerOp.stop,
      if (_caps.can(ToolAction.dockerRestart)) DockerOp.restart,
    ] else ...[
      if (_caps.can(ToolAction.dockerStart)) DockerOp.start,
    ],
    if (_caps.can(ToolAction.dockerRemove)) DockerOp.remove,
  ];

  Future<void> _run(DockerContainer container, DockerOp op) async {
    if (_acting.contains(container.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ContainerActionDialog(container: container, op: op),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _acting.add(container.id));
    final result = await widget.registry.dockerAction(_toolId, container, op);
    if (!mounted) return;
    setState(() => _acting.remove(container.id));

    final error = widget.registry.byId(_toolId)?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result?.describe(container.primaryName) ??
              error ??
              'The tool was busy with another request. Try again in a moment.',
        ),
        duration: Duration(seconds: result == null ? 8 : 4),
      ),
    );
    if (result != null) await _load();
  }

  Future<void> _prune() async {
    if (_pruning) return;
    final dangling = _inventory?.danglingCount ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PruneDialog(dangling: dangling),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _pruning = true);
    final result = await widget.registry.dockerPrune(_toolId);
    if (!mounted) return;
    setState(() => _pruning = false);

    final error = widget.registry.byId(_toolId)?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result == null
              ? (error ?? 'The tool was busy. Try again in a moment.')
              : dangling == 0
              ? 'Nothing to prune — no dangling images were reported.'
              : result.describe('$dangling dangling image(s)'),
        ),
        duration: Duration(seconds: result == null ? 8 : 4),
      ),
    );
    if (result != null) await _load();
  }

  Future<void> _openPort(DockerPortMapping port) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.registry.dockerOpenPort(_toolId, port);
    if (!mounted) return;
    final error = widget.registry.byId(_toolId)?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result?.message ??
              error ??
              'The tool was busy with another request. Try again in a moment.',
        ),
        duration: Duration(seconds: result == null ? 8 : 4),
      ),
    );
  }

  Future<void> _startEngine() => _runEngine(start: true);

  Future<void> _stopEngine() => _runEngine(start: false);

  Future<void> _runEngine({required bool start}) async {
    if (_engineBusy) return;
    final engine = _engine;
    if (engine == null) return;

    // Stopping takes every running container down with the engine, so it is the
    // one that must be confirmed out loud; starting is safe and just runs.
    if (!start) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _StopEngineDialog(engine: engine),
      );
      if (confirmed != true || !mounted) return;
    }

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _engineBusy = true);
    final result = start
        ? await widget.registry.dockerStartEngine(_toolId)
        : await widget.registry.dockerStopEngine(_toolId);
    if (!mounted) return;
    setState(() => _engineBusy = false);

    final error = widget.registry.byId(_toolId)?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result?.message ??
              error ??
              'The tool was busy with another request. Try again in a moment.',
        ),
        duration: Duration(seconds: result == null ? 8 : 4),
      ),
    );
    if (result == null) return;
    if (start) {
      // A CLI is needed to read anything; with one, reload so the console fills
      // in once the engine answers. Without one, the manager has done what it
      // can and the next open of the tool re-detects.
      if (_canRead) await _load();
    } else {
      setState(() => _inventory = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConsoleScaffold(
      title: 'Containers & images',
      loading: _loading || _pruning,
      actions: [
        IconButton(
          tooltip: 'Scan again',
          icon: const Icon(Icons.refresh),
          onPressed: !_canRead || _loading ? null : _load,
        ),
      ],
      children: [
        PageIntro(
          title: 'What the docker CLI sees',
          message:
              'Read with ${widget.entry.descriptor.implPath} every time this '
              'page opens, against this machine\'s current docker context — no '
              'engine is assumed. Start, stop, restart and remove send the '
              'matching docker command; the engine decides the outcome.',
        ),
        const SizedBox(height: 14),
        if (_canEngine) ...[
          _EngineControl(
            engine: _engine!,
            up: _engineUp,
            canStart: _caps.can(ToolAction.dockerStartEngine),
            canStop: _caps.can(ToolAction.dockerStopEngine),
            busy: _engineBusy,
            loading: _loading,
            onStart: _startEngine,
            onStop: _stopEngine,
          ),
          const SizedBox(height: 18),
        ],
        if (!_canRead) ...[
          CapabilityNotice(capabilities: _caps),
          const SizedBox(height: 18),
          EmptyState(
            icon: Icons.dns_outlined,
            title: 'Docker is not available here',
            message: _caps.reason,
          ),
        ] else ...[
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Container or image name, id, image or port',
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            FailureBanner(message: _error!),
          ],
          if (_loading && _inventory == null)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_inventory != null)
            ..._body(context),
        ],
      ],
    );
  }

  List<Widget> _body(BuildContext context) {
    final inventory = _inventory!;
    final query = _query.trim();
    final containers = _shownContainers;
    final images = _shownImages;
    return [
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: StatTile(
              label: 'Running',
              value: '${inventory.runningCount}',
              icon: Icons.play_circle_outline,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatTile(
              label: 'Containers',
              value: '${inventory.containers.length}',
              icon: Icons.dns_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatTile(
              label: 'Images',
              value: '${inventory.images.length}',
              icon: Icons.layers_outlined,
            ),
          ),
        ],
      ),
      if (inventory.notes.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final note in inventory.notes) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InlineNote(
              icon: Icons.info_outline,
              text: note,
              tone: Theme.of(context).colorScheme.tertiary,
            ),
          ),
        ],
      ],
      const SizedBox(height: 22),
      const SectionLabel('Containers'),
      if (inventory.containers.isEmpty)
        const _EmptyLine('No containers on this engine.')
      else if (containers.isEmpty)
        _EmptyLine('No container matches "$query".')
      else
        Card(
          child: Column(
            children: [
              for (final (i, container) in containers.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 16),
                _ContainerRow(
                  container: container,
                  busy: _acting.contains(container.id),
                  ops: _opsFor(container),
                  canOpenPorts: _caps.can(ToolAction.dockerOpenPort),
                  onPrimary: () => _run(
                    container,
                    container.isRunning ? DockerOp.stop : DockerOp.start,
                  ),
                  onMore: (op) => _run(container, op),
                  onOpenPort: _openPort,
                ),
              ],
            ],
          ),
        ),
      const SizedBox(height: 22),
      SectionLabel(
        'Images',
        trailing: _caps.can(ToolAction.dockerPrune)
            ? TextButton.icon(
                onPressed: _pruning ? null : _prune,
                icon: const Icon(Icons.auto_delete_outlined, size: 18),
                label: Text('Prune dangling (${inventory.danglingCount})'),
              )
            : null,
      ),
      if (inventory.images.isEmpty)
        const _EmptyLine('No images on this engine.')
      else if (images.isEmpty)
        _EmptyLine('No image matches "$query".')
      else
        Card(
          child: Column(
            children: [
              for (final (i, image) in images.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 16),
                _ImageRow(image: image),
              ],
            ],
          ),
        ),
      if (inventory.disk.isNotEmpty) ...[
        const SizedBox(height: 22),
        const SectionLabel('Disk usage'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              children: [
                const _DfHeader(),
                for (final line in inventory.disk) _DiskRow(line: line),
              ],
            ),
          ),
        ),
      ],
    ];
  }
}

class _ContainerRow extends StatelessWidget {
  const _ContainerRow({
    required this.container,
    required this.busy,
    required this.ops,
    required this.canOpenPorts,
    required this.onPrimary,
    required this.onMore,
    required this.onOpenPort,
  });

  final DockerContainer container;
  final bool busy;
  final List<DockerOp> ops;
  final bool canOpenPorts;
  final VoidCallback onPrimary;
  final ValueChanged<DockerOp> onMore;
  final ValueChanged<DockerPortMapping> onOpenPort;

  IconData get _primaryIcon =>
      container.isRunning ? Icons.stop_circle_outlined : Icons.play_circle_fill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = container.isRunning;

    final leading = busy
        ? const SizedBox(
            width: 40,
            height: 40,
            child: Padding(
              padding: EdgeInsets.all(11),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : IconBadge(
            icon: Icons.dns_outlined,
            color: running ? scheme.primary : scheme.onSurfaceVariant,
            size: 40,
          );

    final overflow = ops.where((op) {
      // The primary button already covers start/stop; the menu carries the rest.
      final isPrimary =
          (running && op == DockerOp.stop) ||
          (!running && op == DockerOp.start);
      return !isPrimary;
    }).toList();

    return ListTile(
      leading: leading,
      title: Row(
        children: [
          Flexible(
            child: Text(
              container.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(width: 8),
          TagChip(
            label: container.stateLabel,
            color: running ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(container.subtitle, style: theme.textTheme.bodySmall),
          if (container.portMappings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final port in container.portMappings)
                    _PortChip(
                      mapping: port,
                      clickable: canOpenPorts && port.isPublished,
                      onOpen: () => onOpenPort(port),
                    ),
                ],
              ),
            )
          else if (container.ports.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                container.ports,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono(
                  theme.textTheme.bodySmall,
                )?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip:
                '${container.isRunning ? 'Stop' : 'Start'} ${container.primaryName}',
            icon: Icon(_primaryIcon, color: scheme.primary),
            onPressed: busy ? null : onPrimary,
          ),
          if (overflow.isNotEmpty && !busy)
            PopupMenuButton<DockerOp>(
              tooltip: 'More',
              onSelected: onMore,
              itemBuilder: (_) => [
                for (final op in overflow)
                  PopupMenuItem(
                    value: op,
                    child: Row(
                      children: [
                        Icon(
                          op == DockerOp.remove
                              ? Icons.delete_outline
                              : Icons.refresh,
                          size: 18,
                          color: op == DockerOp.remove ? scheme.error : null,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          op.label,
                          style: op == DockerOp.remove
                              ? TextStyle(color: scheme.error)
                              : null,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// One container port. A published port is a link — tapping it asks the OS to
/// open `http://localhost:<hostPort>` in the default browser — while an exposed
/// port that was never published is shown but not clickable, because nothing on
/// the host can reach it. The clickable state is only offered when the platform
/// advertised a browser handler.
class _PortChip extends StatelessWidget {
  const _PortChip({
    required this.mapping,
    required this.clickable,
    required this.onOpen,
  });

  final DockerPortMapping mapping;
  final bool clickable;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = clickable ? scheme.primary : scheme.onSurfaceVariant;

    final IconData icon;
    final String tooltip;
    if (clickable) {
      icon = Icons.open_in_new;
      tooltip = 'Open ${mapping.url} in the browser';
    } else if (mapping.isPublished) {
      icon = Icons.public;
      tooltip = '${mapping.hostIp}:${mapping.hostPort} → '
          '${mapping.containerPort}/${mapping.proto} — no browser handler here';
    } else {
      icon = Icons.lock_outline;
      tooltip = '${mapping.containerPort}/${mapping.proto} is only exposed '
          'inside the container and not published on the host';
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: clickable ? onOpen : null,
          borderRadius: BorderRadius.circular(6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: color.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 5),
                  Text(
                    mapping.label,
                    style: AppTheme.mono(
                      theme.textTheme.bodySmall,
                    )?.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageRow extends StatelessWidget {
  const _ImageRow({required this.image});

  final DockerImage image;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      leading: Icon(
        image.isDangling
            ? Icons.image_not_supported_outlined
            : Icons.image_outlined,
        color: image.isDangling ? scheme.onSurfaceVariant : scheme.primary,
      ),
      title: Text(
        image.ref,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.mono(theme.textTheme.titleSmall),
      ),
      subtitle: Text(image.subtitle, style: theme.textTheme.bodySmall),
      trailing: image.isDangling
          ? TagChip(label: 'dangling', color: scheme.onSurfaceVariant)
          : null,
    );
  }
}

class _DfHeader extends StatelessWidget {
  const _DfHeader();

  @override
  Widget build(BuildContext context) {
    const labels = ['Type', 'Total', 'Active', 'Size', 'Reclaimable'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          for (final (i, label) in labels.indexed)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                label.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiskRow extends StatelessWidget {
  const _DiskRow({required this.line});

  final DockerDiskLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = [line.total, line.active, line.size, line.reclaimable];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(line.type, style: theme.textTheme.bodyMedium),
          ),
          for (final value in values)
            Expanded(
              flex: 2,
              child: Text(
                value,
                style: AppTheme.mono(theme.textTheme.bodySmall),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Pops `true` to send the action, null to cancel. Remove names the cost; the
/// engine still has the final word.
class _ContainerActionDialog extends StatelessWidget {
  const _ContainerActionDialog({required this.container, required this.op});

  final DockerContainer container;
  final DockerOp op;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remove = op == DockerOp.remove;
    return AlertDialog(
      icon: Icon(
        remove ? Icons.delete_outline : Icons.info_outline,
        color: remove ? scheme.error : scheme.primary,
      ),
      title: Text('${op.label} ${container.primaryName}?'),
      content: Text(
        remove
            ? 'The container and its writable layer are removed. This cannot '
                  'be undone from here — a fresh ${container.image} starts from '
                  'the image again.'
            : 'docker ${op.name} is sent to the engine, which reports the '
                  'result. ${container.image}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: remove
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          child: Text(op.label),
        ),
      ],
    );
  }
}

class _PruneDialog extends StatelessWidget {
  const _PruneDialog({required this.dangling});

  final int dangling;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.auto_delete_outlined, color: scheme.primary),
      title: const Text('Prune dangling images?'),
      content: Text(
        dangling == 0
            ? 'No dangling (untagged) images were reported, so this would '
                  'remove nothing.'
            : 'docker image prune removes only untagged, unused images. '
                  'Anything still referenced by a tag or a container stays.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Prune'),
        ),
      ],
    );
  }
}

/// The engine itself: which manager owns it, and a button to bring it up or
/// take it down. Shown whenever a manager is installed — including when there
/// is no CLI to read through and when the daemon is simply switched off, which
/// is the state where running the engine by hand used to be the only way out.
class _EngineControl extends StatelessWidget {
  const _EngineControl({
    required this.engine,
    required this.up,
    required this.canStart,
    required this.canStop,
    required this.busy,
    required this.loading,
    required this.onStart,
    required this.onStop,
  });

  final DockerEngineManager engine;
  final bool up;
  final bool canStart;
  final bool canStop;
  final bool busy;

  /// The inventory read is still in flight, so whether the engine is up is not
  /// yet known — the button is shown but disabled rather than offering a Start
  /// that might be about to flip to Stop.
  final bool loading;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 24,
        height: 24,
        child: Padding(
          padding: EdgeInsets.all(3),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (up && canStop) {
      trailing = TextButton.icon(
        onPressed: loading ? null : onStop,
        icon: Icon(Icons.stop_circle_outlined, size: 18, color: scheme.error),
        label: Text('Stop', style: TextStyle(color: scheme.error)),
      );
    } else if (!up && canStart) {
      trailing = FilledButton.icon(
        onPressed: loading ? null : onStart,
        icon: const Icon(Icons.play_arrow, size: 18),
        label: Text('Start ${engine.label}'),
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.power_settings_new,
              color: up ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Engine: ${engine.label}',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    up
                        ? 'The engine is running.'
                        : loading
                        ? 'Checking the engine…'
                        : 'The engine is stopped or unreachable.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// Stopping the engine is the one Docker action here that takes the whole
/// machine's containers down, so it is named plainly before it is confirmed.
class _StopEngineDialog extends StatelessWidget {
  const _StopEngineDialog({required this.engine});

  final DockerEngineManager engine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.power_settings_new, color: scheme.error),
      title: Text('Stop ${engine.label}?'),
      content: Text(
        'This stops the engine itself, not a single container. Everything '
        'running on it goes down and stays down until you start it again. '
        'The console runs `${engine.stop.join(' ')}`.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          child: const Text('Stop engine'),
        ),
      ],
    );
  }
}
