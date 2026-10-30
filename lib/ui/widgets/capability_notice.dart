import 'package:flutter/material.dart';

import '../../models/tool_descriptor.dart';

/// Explains what this platform can and cannot do for a tool.
class CapabilityNotice extends StatelessWidget {
  const CapabilityNotice({super.key, required this.capabilities});

  final Capabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, title, tone) = switch (capabilities.support) {
      Support.full => (Icons.info_outline, 'Note', scheme.primary),
      Support.cappedByOs => (
        Icons.shield_outlined,
        'Limited by the OS',
        scheme.tertiary,
      ),
      Support.helperMissing => (
        Icons.build_outlined,
        'Helper not found',
        scheme.error,
      ),
      Support.notOnThisOs => (
        Icons.block_outlined,
        'Not available here',
        scheme.outline,
      ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  capabilities.reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
