import 'package:flutter/material.dart';

import '../../models/agent_status.dart';

/// The icon that identifies a tool, independent of its state.
IconData toolIcon(String id) => switch (id) {
  'mem_reaper' => Icons.memory_rounded,
  'port_warden' => Icons.lan_outlined,
  'dev_sweeper' => Icons.delete_sweep_outlined,
  'fan_ctl' => Icons.air_rounded,
  'app_lock' => Icons.lock_outline_rounded,
  'docker' => Icons.dns_outlined,
  _ => Icons.handyman_outlined,
};

/// Icon and colours for an agent state, shared by every screen.
class StatusTone {
  const StatusTone({
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final Color foreground;
  final Color background;
}

StatusTone statusTone(AgentState? state, ColorScheme scheme) {
  final running = scheme.brightness == Brightness.dark
      ? const Color(0xFF78D99A)
      : const Color(0xFF1E7B45);
  final stopped = scheme.brightness == Brightness.dark
      ? const Color(0xFFF2C14E)
      : const Color(0xFF8A6100);
  return switch (state) {
    AgentState.running => StatusTone(
      icon: Icons.monitor_heart_outlined,
      foreground: running,
      background: running.withValues(alpha: 0.14),
    ),
    AgentState.installedStopped => StatusTone(
      icon: Icons.pause_circle_outline,
      foreground: stopped,
      background: stopped.withValues(alpha: 0.14),
    ),
    AgentState.notInstalled => StatusTone(
      icon: Icons.link_off,
      foreground: scheme.onSurfaceVariant,
      background: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
    ),
    AgentState.notApplicable => StatusTone(
      icon: Icons.computer,
      foreground: scheme.primary,
      background: scheme.primary.withValues(alpha: 0.12),
    ),
    AgentState.unknown || null => StatusTone(
      icon: Icons.help_outline,
      foreground: scheme.error,
      background: scheme.error.withValues(alpha: 0.12),
    ),
  };
}

/// Rounded, tinted square holding an icon; the visual anchor of a tool row.
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 44,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Icon(icon, color: color, size: size * 0.5),
    );
  }
}

/// Small coloured pill with a dot and the state's label.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact label for one fact about a row, e.g. a pid or an idle window.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
