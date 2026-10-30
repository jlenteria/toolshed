import 'dart:async';

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

/// The fan console. It computes no control law: the rpm shown is the daemon's,
/// and every control button exists only once the daemon answers on its socket.
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
  String? _openNote;
  FanPrivilegeReport? _asUser;
  FanPrivilegeReport? _asDaemon;
  String? _readError;
  bool _reading = true;
  bool _refreshing = false;
  bool _probing = false;
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
  /// them stale instead of blanking the screen.
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
  Future<void> _act(
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
      return;
    }
    final ok = await action();
    await _refresh();
    if (!mounted) return;
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
  }

  String _appliedLine() {
    final live = _daemon;
    if (live == null) return 'the daemon is not answering on its socket';
    final rpm = live.appliedRpm == null
        ? ''
        : ' at ${live.appliedRpm!.toStringAsFixed(0)} rpm';
    return 'fan ${live.applied}$rpm — ${live.reason}';
  }

  String _saveOutcome() {
    final live = _daemon?.policy;
    if (live == null) {
      return 'Saved. Nothing is holding a fan, so these apply when you engage.';
    }
    if (live == _draft) return 'Saved, and the daemon is holding exactly this.';
    return 'Saved to disk. The fan is still being held at ${live.blurb} — '
        'press Take control to hand the daemon these numbers.';
  }

  Future<void> _probeWrites() async {
    setState(() => _probing = true);
    FanPrivilegeReport? user;
    FanPrivilegeReport? daemon;
    String? error;
    try {
      user = await widget.registry.fanPrivileges(_id);
      daemon = await widget.registry.fanDaemonPrivileges(_id);
    } on Object catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _asUser = user ?? _asUser;
      _asDaemon = daemon ?? _asDaemon;
      _readError = error;
      _probing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final fans = _telemetry.fans;
    final fan = _telemetry.fan(_draft.fan);

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
          _ReadsCard(
            telemetry: _telemetry,
            draft: _draft,
            stale: _reading == false && _readError != null,
            onPickGroup: (group) =>
                setState(() => _draft = _draft.copyWith(group: group)),
          ),
          const SizedBox(height: 14),
          _DaemonCard(
            entry: entry,
            daemon: _daemon,
            asUser: _asUser,
            asDaemon: _asDaemon,
            probing: _probing,
            onProbe: _probeWrites,
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
            onLogs: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LogsPanel(registry: widget.registry, id: _id),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _PolicyCard(
            draft: _draft,
            fans: fans,
            fan: fan,
            daemonRunning: _daemon != null,
            canEngage: entry.capabilities.can(ToolAction.engage),
            busy: entry.busy,
            onChanged: (policy) => setState(() => _draft = policy),
            onEngage: () => _act(
              () => widget.registry.engageFan(_id, _draft),
              doing: 'Taking control',
              outcome: () => 'In control: ${_appliedLine()}',
            ),
            onSave: () => _act(
              () => widget.registry.saveConfig(_id, _draft),
              doing: 'Saving',
              outcome: _saveOutcome,
            ),
            onRelease: () => _act(
              () => widget.registry.releaseFan(_id),
              doing: 'Giving the fan back',
              outcome: () =>
                  'Given back. '
                  '${_daemon == null ? 'The fan is back in Apple\'s control.' : _appliedLine()}',
            ),
            openNote: _openNote,
            onShowNote: (key) =>
                setState(() => _openNote = _openNote == key ? null : key),
          ),
          const SizedBox(height: 14),
          if (entry.capabilities.support != Support.full)
            CapabilityNotice(capabilities: entry.capabilities),
          const SizedBox(height: 10),
          Text(
            'Read as uid ${_telemetry.pid} on ${_telemetry.machine}. Fan '
            'writes are refused for any uid but 0, which is why holding needs '
            'the daemon above.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadsCard extends StatelessWidget {
  const _ReadsCard({
    required this.telemetry,
    required this.draft,
    required this.stale,
    required this.onPickGroup,
  });

  final FanTelemetry telemetry;
  final FanPolicy draft;
  final bool stale;
  final ValueChanged<FanSensorGroup> onPickGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sensors = telemetry.sensors;
    final shown = sensors.take(12).toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: SectionLabel('Right now')),
                Text(
                  stale
                      ? 'last read'
                      : telemetry.at == null
                      ? ''
                      : _clockLabel(telemetry.at!),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: stale ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (telemetry.fans.isEmpty)
              Text(
                'This Mac reports no fans the SMC will name, so there is '
                'nothing to hold. Readings below still show what is hot.',
                style: theme.textTheme.bodyMedium,
              )
            else
              for (final fan in telemetry.fans) ...[
                _FanMeter(fan: fan, watching: fan.id == draft.fan),
                const SizedBox(height: 12),
              ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final group in FanSensorGroup.values)
                  _GroupChip(
                    group: group,
                    celsius: telemetry.temperatureFor(group),
                    selected: group == draft.group,
                    onTap: () => onPickGroup(group),
                  ),
              ],
            ),
            if (sensors.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                telemetry.hottest == null
                    ? '${sensors.length} temperature sensors readable.'
                    : 'hottest of ${sensors.length}: '
                          '${telemetry.hottest!.key} at '
                          '${telemetry.hottest!.celsius.toStringAsFixed(1)} C',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final sensor in shown) _SensorRow(sensor: sensor, max: 100),
              if (sensors.length > shown.length)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${sensors.length - shown.length} more sensors, all '
                    'readable without privilege.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _clockLabel(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

/// Scale is the fan's own floor–ceiling range, so an idling fan is not empty.
class _FanMeter extends StatelessWidget {
  const _FanMeter({required this.fan, required this.watching});

  final FanReading fan;
  final bool watching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = fan.isForced ? scheme.tertiary : scheme.primary;
    final target = fan.targetRpm == null || fan.maxRpm <= fan.minRpm
        ? null
        : ((fan.targetRpm! - fan.minRpm) / (fan.maxRpm - fan.minRpm)).clamp(
            0.0,
            1.0,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              watching ? Icons.air : Icons.air_outlined,
              size: 18,
              color: watching ? color : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(fan.name, style: theme.textTheme.titleSmall)),
            Text(
              '${fan.actualRpm.toStringAsFixed(0)} rpm',
              style: AppTheme.mono(
                theme.textTheme.titleSmall,
              )?.copyWith(color: color),
            ),
          ],
        ),
        const SizedBox(height: 6),
        MeterBar(fraction: fan.speedFraction, marker: target, color: color),
        const SizedBox(height: 6),
        Text(
          'floor ${fan.minRpm.toStringAsFixed(0)} · ceiling '
          '${fan.maxRpm.toStringAsFixed(0)} · last asked '
          '${fan.targetRpm == null ? 'unknown' : '${fan.targetRpm!.toStringAsFixed(0)} rpm'}'
          ' · ${fan.isForced ? 'forced by someone' : "Apple's automatic control"}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.group,
    required this.celsius,
    required this.selected,
    required this.onTap,
  });

  final FanSensorGroup group;
  final double? celsius;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(
        '${group.label}${celsius == null ? ' — none here' : ' ${celsius!.toStringAsFixed(0)}C'}',
      ),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _SensorRow extends StatelessWidget {
  const _SensorRow({required this.sensor, required this.max});

  final TemperatureSensor sensor;
  final double max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fraction = max <= 0 ? 0.0 : (sensor.celsius / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              sensor.key,
              style: AppTheme.mono(
                theme.textTheme.bodySmall,
              )?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: MeterBar(
              fraction: fraction,
              height: 7,
              color: Color.lerp(
                scheme.secondary,
                scheme.error,
                fraction * fraction,
              ),
            ),
          ),
          SizedBox(
            width: 58,
            child: Text(
              '${sensor.celsius.toStringAsFixed(1)} C',
              textAlign: TextAlign.right,
              style: AppTheme.mono(theme.textTheme.bodySmall),
            ),
          ),
        ],
      ),
    );
  }
}

class _DaemonCard extends StatelessWidget {
  const _DaemonCard({
    required this.entry,
    required this.daemon,
    required this.asUser,
    required this.asDaemon,
    required this.probing,
    required this.onProbe,
    required this.onInstall,
    required this.onStart,
    required this.onStop,
    required this.onLogs,
  });

  final ToolEntry entry;
  final FanDaemonStatus? daemon;
  final FanPrivilegeReport? asUser;
  final FanPrivilegeReport? asDaemon;
  final bool probing;
  final VoidCallback onProbe;
  final VoidCallback onInstall;
  final VoidCallback onStart;
  final VoidCallback onStop;
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
                    : 'The helper is not installed and running, so readings '
                          'are all this screen can offer. Start it to get '
                          'control.',
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
              if (live.appliedRpm != null)
                FactRow(
                  icon: Icons.speed_rounded,
                  text:
                      'holding at ${live.appliedRpm!.toStringAsFixed(0)} rpm, '
                      '${live.ticks} ticks since it came up',
                ),
              if (live.leaseExpiresAt != null)
                _LeaseLine(expiresAt: live.leaseExpiresAt!),
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
                OutlinedButton.icon(
                  onPressed: probing ? null : onProbe,
                  icon: probing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fact_check_outlined),
                  label: const Text('Test writes'),
                ),
                if (entry.capabilities.can(ToolAction.tailLogs))
                  TextButton.icon(
                    onPressed: onLogs,
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Log'),
                  ),
              ],
            ),
            if (asUser != null || asDaemon != null) ...[
              const SizedBox(height: 10),
              _ProbeLine(label: 'as uid ${asUser?.uid ?? '?'}', report: asUser),
              _ProbeLine(label: 'as the daemon', report: asDaemon),
            ],
          ],
        ),
      ),
    );
  }
}

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
                '${expiring ? 'closing this app will release the fan' : 'the app holds as long as it is open and renewing'}',
    );
  }

  static String _duration(Duration d) => d.inMinutes > 0
      ? '${d.inMinutes}m ${d.inSeconds % 60}s'
      : '${d.inSeconds}s';
}

class _ProbeLine extends StatelessWidget {
  const _ProbeLine({required this.label, required this.report});

  final String label;
  final FanPrivilegeReport? report;

  @override
  Widget build(BuildContext context) {
    final value = report;
    if (value == null) return const SizedBox.shrink();
    final ok = value.canControlFans;
    return FactRow(
      icon: ok ? Icons.check_circle_outline : Icons.do_not_disturb_on_outlined,
      color: ok ? Colors.green : Theme.of(context).colorScheme.error,
      text:
          '$label: ${value.verdict}'
          '${value.writeDetail == null ? '' : ' (${value.writeDetail})'}',
    );
  }
}

/// The editor writes a [FanPolicy] and nothing else; the numbers reach the fan
/// only when Take control sends them on.
class _PolicyCard extends StatelessWidget {
  const _PolicyCard({
    required this.draft,
    required this.fans,
    required this.fan,
    required this.daemonRunning,
    required this.canEngage,
    required this.busy,
    required this.onChanged,
    required this.onEngage,
    required this.onSave,
    required this.onRelease,
    required this.openNote,
    required this.onShowNote,
  });

  final FanPolicy draft;
  final List<FanReading> fans;
  final FanReading? fan;
  final bool daemonRunning;
  final bool canEngage;
  final bool busy;
  final ValueChanged<FanPolicy> onChanged;
  final VoidCallback onEngage;
  final VoidCallback onSave;
  final VoidCallback onRelease;
  final String? openNote;
  final ValueChanged<String> onShowNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final problems = draft.problems;

    String? engageBlock;
    if (problems.isNotEmpty) {
      engageBlock = 'Those settings need fixing first.';
    } else if (!draft.enabled) {
      engageBlock =
          'Turn "Policy enabled" on — the daemon ignores a policy that is off, '
          'so taking control now would change nothing.';
    } else if (fans.isNotEmpty && fan == null) {
      engageBlock = 'Pick a fan above first.';
    } else if (!canEngage) {
      engageBlock =
          'Taking control needs the root daemon installed above: a fan write '
          'from your own uid is refused by the kernel.';
    } else if (!daemonRunning) {
      engageBlock =
          'The daemon is installed but not answering. Start it above.';
    }
    final releaseBlock = daemonRunning
        ? null
        : 'Nothing is holding a fan, so there is nothing to give back.';

    final holdFloor = fan == null
        ? FanPolicy.minHoldRpm
        : (fan!.minRpm > FanPolicy.minHoldRpm
              ? fan!.minRpm
              : FanPolicy.minHoldRpm);
    final holdCeiling = fan?.maxRpm ?? FanPolicy.maxHoldRpm;
    final guardFloor = (draft.targetTempC + FanPolicy.minGuardHeadroomC).clamp(
      FanPolicy.minTargetTempC,
      110.0,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionLabel('Policy'),
            SwitchListTile(
              value: draft.enabled,
              onChanged: busy
                  ? null
                  : (on) => onChanged(draft.copyWith(enabled: on)),
              title: const Text('Policy enabled'),
              subtitle: Text(
                draft.enabled
                    ? 'The daemon decides every ${draft.intervalSeconds}s.'
                    : 'The fan stays in Apple\'s control. Saved settings do '
                          'nothing until this is on.',
                style: theme.textTheme.bodySmall,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const FieldGroup('What starts a hold'),
            if (fans.isNotEmpty)
              _FanPicker(
                fans: fans,
                selected: draft.fan,
                busy: busy,
                onChanged: (id) => onChanged(draft.copyWith(fan: id)),
              )
            else
              Text(
                'Nothing has reported a fan yet, so there is nothing to '
                'select; this policy still names fan ${draft.fan}. The list '
                'comes from the same read as the meters above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (fans.isNotEmpty && fan == null) ...[
              const SizedBox(height: 6),
              Text(
                'Fan ${draft.fan} is not on this machine. Pick one above — '
                'a policy for an impeller that does not exist is a write the '
                'daemon refuses.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            _SliderRow(
              label: 'Take control at',
              value: draft.targetTempC,
              display: '${draft.targetTempC.toStringAsFixed(0)} C',
              min: FanPolicy.minTargetTempC,
              max: FanPolicy.maxTargetTempC,
              divisions:
                  ((FanPolicy.maxTargetTempC - FanPolicy.minTargetTempC) * 2)
                      .round(),
              helper:
                  'Below it the fan is Apple\'s business; the daemon leaves '
                  'the registers alone.',
              onChanged: (v) => onChanged(draft.copyWith(targetTempC: v)),
            ),
            _SliderRow(
              label: 'Give back below',
              value: draft.hysteresisC,
              display:
                  '${(draft.targetTempC - draft.hysteresisC).toStringAsFixed(1)} C',
              min: FanPolicy.minHysteresisC,
              max: FanPolicy.maxHysteresisC,
              divisions:
                  ((FanPolicy.maxHysteresisC - FanPolicy.minHysteresisC) * 2)
                      .round(),
              helper:
                  'Your release band. Without it a machine sitting at the '
                  'threshold flips control twice a second.',
              onChanged: (v) => onChanged(draft.copyWith(hysteresisC: v)),
            ),
            const FieldGroup('What a hold does'),
            _SliderRow(
              label: 'Hold at',
              value: draft.holdRpm.clamp(holdFloor, holdCeiling),
              display: '${draft.holdRpm.toStringAsFixed(0)} rpm',
              min: holdFloor,
              max: holdCeiling,
              divisions: (holdCeiling - holdFloor) > 100
                  ? ((holdCeiling - holdFloor) / 100).round()
                  : null,
              helper:
                  'Asked for exactly at the threshold; the fan\'s own floor '
                  'and ceiling clamp whatever is set here.',
              onChanged: (v) => onChanged(draft.copyWith(holdRpm: v)),
            ),
            _SliderRow(
              label: 'Add per degree over it',
              value: draft.rampPerDegree,
              display: '+${draft.rampPerDegree.toStringAsFixed(0)} rpm',
              min: FanPolicy.minRampPerDegree,
              max: FanPolicy.maxRampPerDegree,
              divisions: (FanPolicy.maxRampPerDegree / 50).round(),
              helper:
                  'Zero holds one speed; a ramp keeps the response '
                  'proportional instead of binary.',
              onChanged: (v) => onChanged(draft.copyWith(rampPerDegree: v)),
            ),
            _SliderRow(
              label: 'Check every',
              value: draft.intervalSeconds.toDouble(),
              display: '${draft.intervalSeconds}s',
              min: FanPolicy.minIntervalSeconds.toDouble(),
              max: FanPolicy.maxIntervalSeconds.toDouble(),
              divisions:
                  FanPolicy.maxIntervalSeconds - FanPolicy.minIntervalSeconds,
              onChanged: (v) =>
                  onChanged(draft.copyWith(intervalSeconds: v.round())),
            ),
            const FieldGroup('What ends it'),
            _SliderRow(
              label: 'Never above',
              value: draft.criticalTempC.clamp(guardFloor, 110),
              display: '${draft.criticalTempC.toStringAsFixed(0)} C',
              min: guardFloor,
              max: 110,
              divisions: ((110 - guardFloor) * 2).round(),
              helper:
                  'The thermal guard. Past it the daemon stops writing and '
                  'leaves the fan to Apple.',
              onChanged: (v) => onChanged(draft.copyWith(criticalTempC: v)),
            ),
            _LeasePicker(
              value: draft.leaseSeconds,
              onChanged: (seconds) =>
                  onChanged(draft.copyWith(leaseSeconds: seconds)),
            ),
            if (problems.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final problem in problems)
                FactRow(
                  icon: Icons.warning_amber_rounded,
                  color: scheme.error,
                  text: problem,
                ),
            ],
            const SizedBox(height: 14),
            ActionBar(
              openNote: openNote,
              onShowNote: onShowNote,
              primary: BarAction(
                key: 'engage',
                label: 'Take control',
                icon: Icons.air,
                note:
                    'Sends these numbers to the root daemon and keeps its '
                    'lease alive while this window is open. The only button '
                    'here that touches the fan.',
                blocked: engageBlock,
                onPressed: engageBlock != null || busy ? null : onEngage,
              ),
              secondary: [
                BarAction(
                  key: 'release',
                  label: 'Give back now',
                  icon: Icons.snooze_rounded,
                  tone: BarTone.outlined,
                  note:
                      'Hands the fan back to Apple immediately and stops the '
                      'renewal. These settings are kept, just disarmed.',
                  blocked: releaseBlock,
                  onPressed: releaseBlock != null || busy ? null : onRelease,
                ),
                BarAction(
                  key: 'save',
                  label: 'Save only',
                  icon: Icons.save_outlined,
                  tone: BarTone.tonal,
                  note:
                      'Writes these numbers to disk and sends nothing. They '
                      'take effect the next time you take control.',
                  blocked: problems.isNotEmpty
                      ? 'Those settings need fixing first.'
                      : null,
                  onPressed: busy || problems.isNotEmpty ? null : onSave,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FanPicker extends StatelessWidget {
  const _FanPicker({
    required this.fans,
    required this.selected,
    required this.busy,
    required this.onChanged,
  });

  final List<FanReading> fans;
  final int selected;
  final bool busy;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Fan to hold',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final fan in fans)
              ChoiceChip(
                label: Text(
                  '${fan.name} · ${fan.minRpm.toStringAsFixed(0)}–'
                  '${fan.maxRpm.toStringAsFixed(0)} rpm',
                ),
                selected: fan.id == selected,
                onSelected: busy ? null : (_) => onChanged(fan.id),
              ),
          ],
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.display,
    required this.min,
    required this.max,
    this.divisions,
    this.helper,
    required this.onChanged,
  });

  final String label;
  final double value;
  final String display;
  final double min;
  final double max;
  final int? divisions;
  final String? helper;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final span = max - min;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                display,
                style: AppTheme.mono(
                  theme.textTheme.bodyMedium,
                )?.copyWith(color: scheme.primary),
              ),
            ],
          ),
        ),
        if (span > 0)
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
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
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text(
              helper!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _LeasePicker extends StatelessWidget {
  const _LeasePicker({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  static const Map<int, String> _choices = {
    0: 'Hold until released',
    30: '30 s',
    120: '2 min',
    600: '10 min',
    3600: '1 hour',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = FanPolicy(leaseSeconds: value);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Give up if this app stops renewing',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in _choices.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: entry.key == value,
                  onSelected: (_) => onChanged(entry.key),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            policy.leaseLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
