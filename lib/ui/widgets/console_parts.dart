import 'package:flutter/material.dart';

import '../theme.dart';

/// Uppercase caption that opens a band of related controls.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A heading for a run of related fields, with a hairline carrying on right.
class FieldGroup extends StatelessWidget {
  const FieldGroup(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              margin: const EdgeInsets.only(left: 8),
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// A page title with one explanatory sentence.
class PageIntro extends StatelessWidget {
  const PageIntro({
    super.key,
    required this.title,
    required this.message,
    this.trailing,
  });

  final String title;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(title, style: theme.textTheme.headlineSmall)),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

/// A card whose children stack edge to edge inside standard padding.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(16),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// A failure the user has to be able to read after the toast is gone.
class FailureBanner extends StatelessWidget {
  const FailureBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// One icon-and-sentence fact, used by live-status cards.
class FactRow extends StatelessWidget {
  const FactRow({
    super.key,
    required this.icon,
    required this.text,
    this.color,
    this.mono = false,
  });

  final IconData icon;
  final String text;
  final Color? color;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    final style = mono
        ? AppTheme.mono(theme.textTheme.bodySmall)?.copyWith(color: tint)
        : theme.textTheme.bodySmall?.copyWith(color: tint);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: tint),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// A quiet callout for a hint that belongs beside the control it explains.
class InlineNote extends StatelessWidget {
  const InlineNote({
    super.key,
    required this.icon,
    required this.text,
    this.tone,
  });

  final IconData icon;
  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = tone ?? scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A centred explanation for a list with nothing to show.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 38, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleSmall),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 14), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// A labelled number for a summary or detail strip.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.color,
    this.icon,
  });

  final String label;
  final String value;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: accent),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// A track-and-fill bar; [marker] draws a thin line for a target value.
class MeterBar extends StatelessWidget {
  const MeterBar({
    super.key,
    required this.fraction,
    this.color,
    this.height = 8,
    this.marker,
  });

  final double fraction;
  final Color? color;
  final double height;
  final double? marker;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = color ?? scheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final value = fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0;
        final mark = marker == null || !marker!.isFinite
            ? null
            : marker!.clamp(0.0, 1.0);
        final top = mark == null ? 0.0 : 3.0;
        return SizedBox(
          height: height + (mark == null ? 0 : 6),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: top,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(height),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: top,
                width: width * value,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(height),
                  ),
                ),
              ),
              if (mark != null)
                Positioned(
                  left: (width * mark).clamp(0.0, width - 2),
                  top: 0,
                  child: Container(
                    width: 2,
                    height: height + 6,
                    color: scheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The standard console scaffold: title, actions, a read bar and a column.
class ConsoleScaffold extends StatelessWidget {
  const ConsoleScaffold({
    super.key,
    required this.title,
    required this.actions,
    required this.loading,
    required this.children,
  });

  final String title;
  final List<Widget> actions;
  final bool loading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [...actions, const SizedBox(width: 4)],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 2,
            child: loading ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            child: ContentColumn(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How much weight a button carries.
enum BarTone { filled, outlined, tonal }

/// One button in the action bar and the sentence behind its info badge.
class BarAction {
  const BarAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.note,
    required this.onPressed,
    this.tone = BarTone.filled,
    this.blocked,
  });

  final String key;
  final String label;
  final IconData icon;
  final String note;
  final VoidCallback? onPressed;
  final BarTone tone;

  /// Why this button cannot be used right now, or null when it can.
  final String? blocked;

  bool get enabled => onPressed != null;
}

/// A primary action with its secondary peers and one open explanation.
class ActionBar extends StatelessWidget {
  const ActionBar({
    required this.primary,
    required this.secondary,
    required this.openNote,
    required this.onShowNote,
    super.key,
  });

  final BarAction primary;
  final List<BarAction> secondary;
  final String? openNote;
  final ValueChanged<String> onShowNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actions = <BarAction>[primary, ...secondary];
    BarAction? open;
    for (final action in actions) {
      if (action.key == openNote) open = action;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _barButton(context, primary),
          if (primary.blocked != null) BlockedLine(text: primary.blocked!),
          if (secondary.isNotEmpty) ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 480) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, action) in secondary.indexed) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _barButton(context, action),
                      ],
                    ],
                  );
                }
                return Row(
                  children: [
                    for (final (i, action) in secondary.indexed) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(child: _barButton(context, action)),
                    ],
                  ],
                );
              },
            ),
          ],
          for (final action in secondary)
            if (action.blocked != null) BlockedLine(text: action.blocked!),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open == null
                ? const SizedBox(width: double.infinity)
                : Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 15,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            open.note,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _barButton(BuildContext context, BarAction action) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(44),
    );
    final Widget button = switch (action.tone) {
      BarTone.filled => FilledButton.icon(
        onPressed: action.onPressed,
        icon: Icon(action.icon),
        label: Text(action.label, overflow: TextOverflow.ellipsis),
        style: style,
      ),
      BarTone.outlined => OutlinedButton.icon(
        onPressed: action.onPressed,
        icon: Icon(action.icon),
        label: Text(action.label, overflow: TextOverflow.ellipsis),
        style: style,
      ),
      BarTone.tonal => FilledButton.tonalIcon(
        onPressed: action.onPressed,
        icon: Icon(action.icon),
        label: Text(action.label, overflow: TextOverflow.ellipsis),
        style: style,
      ),
    };
    return Row(
      children: [
        Expanded(child: button),
        InfoBadge(
          key: ValueKey('note:${action.key}'),
          open: action.key == openNote,
          message: action.note,
          onTap: () => onShowNote(action.key),
          dimmed: !action.enabled,
        ),
      ],
    );
  }
}

class InfoBadge extends StatelessWidget {
  const InfoBadge({
    super.key,
    required this.open,
    required this.message,
    required this.onTap,
    required this.dimmed,
  });

  final bool open;
  final String message;
  final VoidCallback onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: message,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            open ? Icons.info : Icons.info_outline,
            size: 16,
            color: open
                ? scheme.primary
                : dimmed
                ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class BlockedLine extends StatelessWidget {
  const BlockedLine({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.do_not_disturb_on_outlined,
            size: 14,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
