import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/agent_status.dart';
import '../../models/tool_descriptor.dart';
import '../../ui/screens/logs_panel.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/capability_notice.dart';
import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'fan_daemon.dart';
import 'fan_policy.dart';
import 'fan_telemetry.dart';

/// The fan console, and it has exactly two controls: a switch and a number.
///
/// There is no temperature in here on purpose. Deciding when a machine needs
/// cooling is macOS's job — `thermalmonitord` has the sensor fleet and the
/// curves for this model — so this screen only ever answers "how fast, while I
/// say so". The rpm shown is the daemon's, and every control exists only once
/// the daemon answers on its socket.
class FanScreen extends StatefulWidget {
  const FanScreen({super.key, required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<FanScreen> createState() => _FanScreenState();
}

class _FanScreenState extends State<FanScreen> {
  static const _pollEvery = Duration(seconds: 2);

  FanTelemetry _telemetry = FanTelemetry.empty;
  FanDaemonStatus? _daemon;
  FanPolicy _draft = FanPolicy.defaults;
  String? _readError;
  bool _reading = true;
  bool _refreshing = false;
  Timer? _poll;

  String get _id => widget.entry.descriptor.id;

  @override
  void initState() {
    super.initState();
    final saved = widget.entry.config;
    if (saved is FanPolicy) _draft = saved;
    _poll = Timer.periodic(_pollEvery, (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Reads are unprivileged; a failure keeps the last good numbers and flags
  /// them stale instead of blanking the screen. The fan list is read only to
  /// learn the range the slider can offer — nothing here displays a temperature.
  Future<void> _refresh() async {
    if (!mounted) return;
    FanTelemetry? telemetry;
    String? error;
    try {
      telemetry = await widget.registry.fanTelemetry(_id);
    } on Object catch (e) {
      error = '$e';
    }
    FanDaemonStatus? daemon;
    try {
      daemon = await widget.registry.fanDaemonStatus(_id);
    } on Object catch (e) {
      error ??= '$e';
    }
    if (!mounted) return;
    setState(() {
      if (telemetry != null) _telemetry = telemetry;
      _daemon = daemon;
      _readError = error;
      _reading = false;
    });
  }

  /// Polls skip the bar; only a user-triggered read shows progress.
  Future<void> _refreshNow() async {
    setState(() => _refreshing = true);
    await _refresh();
    if (mounted) setState(() => _refreshing = false);
  }

  /// Runs one action and always answers with a toast quoting the daemon.
  /// Returns whether it actually took effect, so a control that acts on the
  /// hardware right now can fall back when it did not.
  Future<bool> _act(
    Future<bool> Function() action, {
    required String doing,
    required String Function() outcome,
  }) async {
    final entry = widget.entry;
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (entry.busy) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Fan control is still working on the last action.'),
        ),
      );
      return false;
    }
    final ok = await action();
    await _refresh();
    if (!mounted) return false;
    final failure = entry.error;
    final text = failure ?? (ok ? outcome() : '$doing did not happen.');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: Duration(seconds: ok && failure == null ? 5 : 12),
          backgroundColor: failure == null && ok ? null : scheme.error,
          action: failure == null
              ? null
              : SnackBarAction(
                  label: 'Dismiss',
                  onPressed: () => setState(() => entry.error = null),
                ),
        ),
      );
    return ok && failure == null;
  }

  /// The switch is not a draft: flipping it ON acts on the hardware immediately
  /// — starting the daemon if it is merely stopped, then holding — and flipping
  /// it off releases the fans. If the daemon refuses, the switch falls back
  /// where it was and the toast quotes the reason.
  Future<void> _setManual(bool on) async {
    final entry = widget.entry;
    if (on) {
      if (_daemon == null && entry.capabilities.can(ToolAction.start)) {
        await _act(
          () => widget.registry.start(_id),
          doing: 'Starting the fan daemon',
          outcome: () => 'The daemon is up.',
        );
        if (!mounted) return;
      }
      final policy = _draft.heldManually(_draft.holdRpm);
      final didIt = await _act(
        () => widget.registry.engageFan(_id, policy),
        doing: 'Turning the fans on',
        outcome: () => 'Fans on: ${_appliedLine()}',
      );
      if (didIt && mounted) setState(() => _draft = policy);
      return;
    }
    final didIt = await _act(
      () => widget.registry.releaseFan(_id),
      doing: 'Turning the fans off',
      outcome: () =>
          'Fans off. '
          '${_daemon == null ? 'They are back in macOS\'s control.' : _appliedLine()}',
    );
    if (didIt && mounted) {
      setState(() => _draft = _draft.copyWith(manualOn: false));
    }
  }

  /// Whether the fans are being held right now. With a manual-only policy the
  /// daemon's own answer is the whole story: `holding` means it forced a fan.
  bool get _manualLive => _draft.manualOn && (_daemon?.isHolding ?? false);

  /// Where the slider may go, taken from the fans this Mac actually reports.
  /// The daemon clamps per fan on the way out, so the widest agreed span is the
  /// honest range: a speed that suits one fan and is clamped for another is
  /// still a speed the operator meant.
  ({double floor, double ceiling}) get _range {
    final fans = _telemetry.fans;
    final floor = fans.isEmpty
        ? FanPolicy.minHoldRpm
        : fans.map((fan) => fan.minRpm).reduce(math.min);
    final ceiling = fans.isEmpty
        ? FanPolicy.maxHoldRpm
        : fans.map((fan) => fan.maxRpm).reduce(math.max);
    return (
      floor: floor.clamp(FanPolicy.minHoldRpm, FanPolicy.maxHoldRpm),
      ceiling: ceiling.clamp(FanPolicy.minHoldRpm, FanPolicy.maxHoldRpm),
    );
  }

  /// A drag only moves the number on screen; releasing it is the decision.
  void _dragRpm(double rpm) =>
      setState(() => _draft = _draft.copyWith(holdRpm: rpm));

  /// Releasing the slider is the commit. While a hold is live it moves the fans;
  /// while it is not, the number is only remembered, so no write happens behind
  /// a switch that is off.
  Future<void> _commitRpm(double rpm) async {
    setState(() => _draft = _draft.copyWith(holdRpm: rpm));
    if (!_manualLive) {
      // Quiet on purpose: a save with the switch off cannot change a fan, so the
      // only thing worth saying is the reason it did not, which the banner above
      // already carries.
      await widget.registry.saveConfig(_id, _draft);
      return;
    }
    await _act(
      () => widget.registry.engageFan(_id, _draft.heldManually(rpm)),
      doing: 'Moving the hold',
      outcome: () => 'Holding: ${_appliedLine()}',
    );
  }

  String _appliedLine() {
    final live = _daemon;
    if (live == null) return 'the daemon is not answering on its socket';
    final rpm = live.appliedRpm == null
        ? ''
        : ' at ${live.appliedRpm!.toStringAsFixed(0)} rpm';
    return '${live.applied}$rpm — ${live.reason}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final range = _range;

    return ListenableBuilder(
      listenable: widget.registry,
      builder: (context, _) => ConsoleScaffold(
        title: 'Fan control',
        loading: _reading || _refreshing,
        actions: [
          IconButton(
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _reading || _refreshing ? null : _refreshNow,
          ),
        ],
        children: [
          if (_readError != null) ...[
            FailureBanner(message: _readError!),
            const SizedBox(height: 12),
          ],
          if (entry.error != null) ...[
            FailureBanner(message: entry.error!),
            const SizedBox(height: 12),
          ],
          _HoldCard(
            draft: _draft,
            live: _manualLive,
            daemon: _daemon,
            range: range,
            fansReported: _telemetry.fans.isNotEmpty,
            busy: entry.busy,
            onToggle: _setManual,
            onDragRpm: _dragRpm,
            onCommitRpm: _commitRpm,
            appliedLine: _appliedLine(),
          ),
          const SizedBox(height: 14),
          _DaemonCard(
            entry: entry,
            daemon: _daemon,
            onInstall: () => _act(
              () => widget.registry.install(_id),
              doing: 'Installing',
              outcome: () => 'The daemon is up. ${_appliedLine()}',
            ),
            onStart: () => _act(
              () => widget.registry.start(_id),
              doing: 'Starting',
              outcome: () => 'Started. ${_appliedLine()}',
            ),
            onStop: () => _act(
              () => widget.registry.stop(_id),
              doing: 'Stopping',
              outcome: () =>
                  'Stopped. '
                  '${_daemon == null ? 'No fan is being held.' : _appliedLine()}',
            ),
            onUpdate: () => _act(
              () => widget.registry.updateAgent(_id),
              doing: 'Updating the daemon',
              outcome: () =>
                  'The daemon is now running the helper this app carries.',
            ),
            onLogs: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LogsPanel(registry: widget.registry, id: _id),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (entry.capabilities.support != Support.full)
            CapabilityNotice(capabilities: entry.capabilities),
          const SizedBox(height: 10),
          Text(
            'A fan write from your own uid is refused by the kernel, so holding '
            'needs the root daemon above. Cooling on temperature is left to '
            'macOS: this tool only ever holds, and only above the fan\'s own '
            'idle floor.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The switch and the number, which is the entire tool.
class _HoldCard extends StatelessWidget {
  const _HoldCard({
    required this.draft,
    required this.live,
    required this.daemon,
    required this.range,
    required this.fansReported,
    required this.busy,
    required this.onToggle,
    required this.onDragRpm,
    required this.onCommitRpm,
    required this.appliedLine,
  });

  final FanPolicy draft;
  final bool live;
  final FanDaemonStatus? daemon;
  final ({double floor, double ceiling}) range;
  final bool fansReported;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onDragRpm;
  final ValueChanged<double> onCommitRpm;
  final String appliedLine;

  /// The daemon rewrites a fan's registers only past this much movement, so a
  /// reported speed inside it is the same hold, not a refused write.
  static const double _writeToleranceRpm = 25;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final span = range.ceiling - range.floor;
    final held = daemon?.appliedRpm;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              value: live,
              onChanged: busy ? null : onToggle,
              title: const Text('Fan manual ON'),
              subtitle: Text(
                live
                    ? 'On — every fan is being held at the speed below, '
                          'whatever the sensors say. Flip off to let them go.'
                    : 'Off, and the fans are macOS\'s. Flipping on spins them '
                          'immediately and needs the root daemon below.',
                style: theme.textTheme.bodySmall,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'Hold at',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${draft.holdRpm.toStringAsFixed(0)} rpm',
                  style: AppTheme.mono(
                    theme.textTheme.bodyMedium,
                  )?.copyWith(color: scheme.primary),
                ),
              ],
            ),
            if (span > 0)
              Slider(
                // A drag moves the number on screen; letting go moves the fans.
                value: draft.holdRpm.clamp(range.floor, range.ceiling),
                min: range.floor,
                max: range.ceiling,
                divisions: (span / 100).clamp(1, 200).round(),
                label: '${draft.holdRpm.toStringAsFixed(0)} rpm',
                onChanged: busy ? null : onDragRpm,
                onChangeEnd: busy ? null : onCommitRpm,
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(
                  'This fan\'s floor and ceiling leave no room for a slider.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Text(
              fansReported
                  ? 'These fans turn between ${range.floor.toStringAsFixed(0)} '
                        'and ${range.ceiling.toStringAsFixed(0)} rpm; a speed '
                        'outside one fan\'s range is clamped to it.'
                  : 'No fan has been reported yet, so the range shown is the '
                        'configurable band rather than this machine\'s.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            FactRow(
              icon: live ? Icons.air : Icons.air_outlined,
              color: live ? scheme.primary : scheme.onSurfaceVariant,
              text: live ? appliedLine : 'Not holding. ${draft.leaseLabel}.',
            ),
            if (live &&
                held != null &&
                (held - draft.holdRpm).abs() > _writeToleranceRpm)
              FactRow(
                icon: Icons.info_outline,
                color: scheme.tertiary,
                text:
                    'The daemon reports ${held.toStringAsFixed(0)} rpm for a '
                    'request of ${draft.holdRpm.toStringAsFixed(0)} — that is '
                    'the fan\'s own range, not a lost write.',
              ),
          ],
        ),
      ),
    );
  }
}

/// The root daemon. Holding a fan is the only thing it can do, and nothing here
/// can be done without it.
class _DaemonCard extends StatelessWidget {
  const _DaemonCard({
    required this.entry,
    required this.daemon,
    required this.onInstall,
    required this.onStart,
    required this.onStop,
    required this.onUpdate,
    required this.onLogs,
  });

  final ToolEntry entry;
  final FanDaemonStatus? daemon;
  final VoidCallback onInstall;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onUpdate;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final live = daemon;
    final status = entry.status ?? const AgentStatus(state: AgentState.unknown);
    final tone = statusTone(status.state, scheme);
    final busy = entry.busy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(icon: tone.icon, color: tone.foreground, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'The daemon that writes',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(label: status.label, color: tone.foreground),
              ],
            ),
            const SizedBox(height: 12),
            if (live == null)
              Text(
                entry.capabilities.can(ToolAction.install)
                    ? 'Nothing is answering on the socket, so no fan can be '
                          'held. Installing writes a root LaunchDaemon and asks '
                          'for your password once.'
                    : 'The helper is not running, so the fans are macOS\'s and '
                          'there is nothing to hold. Start it to get control.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text(
                'pid ${live.pid}, uid ${live.uid} — ${live.applied}',
                style: AppTheme.mono(theme.textTheme.bodyMedium),
              ),
              const SizedBox(height: 4),
              Text(
                live.reason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (live.leaseExpiresAt != null) ...[
                const SizedBox(height: 6),
                _LeaseLine(expiresAt: live.leaseExpiresAt!),
              ],
              if (live.lastError != null) ...[
                const SizedBox(height: 8),
                FailureBanner(message: live.lastError!),
              ],
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (entry.capabilities.can(ToolAction.install))
                  FilledButton.icon(
                    onPressed: busy ? null : onInstall,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Install and start'),
                  ),
                if (live == null && entry.capabilities.can(ToolAction.start))
                  OutlinedButton.icon(
                    onPressed: busy ? null : onStart,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start'),
                  ),
                if (live != null)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onStop,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Stop'),
                  ),
                // The daemon runs the binary copied at install time, so an app
                // rebuilt since then is talking to an older helper — one that
                // cannot even read this console's request. Update closes that
                // gap without uninstalling, which would leave the socket
                // unanswered.
                if (entry.capabilities.can(ToolAction.update))
                  OutlinedButton.icon(
                    onPressed: busy ? null : onUpdate,
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('Update daemon'),
                  ),
                if (entry.capabilities.can(ToolAction.tailLogs))
                  TextButton.icon(
                    onPressed: onLogs,
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Log'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The lease is what answers "what happens when I close this?" — with no
/// temperature able to end a hold, it is the only thing that gives the fans back
/// if the app dies rather than being closed.
class _LeaseLine extends StatelessWidget {
  const _LeaseLine({required this.expiresAt});

  final DateTime expiresAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = expiresAt.difference(DateTime.now());
    final expiring = remaining.inSeconds <= 10;
    return FactRow(
      icon: Icons.timer_outlined,
      color: expiring ? theme.colorScheme.error : null,
      text: remaining.isNegative
          ? 'lease expired'
          : 'lease renews in ${_duration(remaining)} — '
                '${expiring ? 'closing this app will release the fans' : 'the hold lasts as long as this app is open and renewing'}',
    );
  }

  static String _duration(Duration d) => d.inMinutes > 0
      ? '${d.inMinutes}m ${d.inSeconds % 60}s'
      : '${d.inSeconds}s';
}
