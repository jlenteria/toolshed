import 'package:flutter/material.dart';

import '../../ui/widgets/console_parts.dart';
import '../../ui/widgets/status_style.dart';
import '../registry.dart';
import 'mem_reaper_config.dart';

/// The settings that live in the agent's ProgramArguments. Saving rewrites the
/// plist and reloads the service, so launchd picks up the new command line.
Future<bool?> showConfigSheet(
  BuildContext context,
  ToolRegistry registry,
  ToolEntry entry,
) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ConfigForm(registry: registry, entry: entry),
  );
}

class _ConfigForm extends StatefulWidget {
  const _ConfigForm({required this.registry, required this.entry});

  final ToolRegistry registry;
  final ToolEntry entry;

  @override
  State<_ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends State<_ConfigForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _threshold;
  late final TextEditingController _interval;
  late final TextEditingController _dialogTimeout;
  String? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final current = widget.entry.config;
    if (current == null) {
      _loadError =
          widget.entry.error ??
          'The current settings could not be read. These are mem_reaper\'s '
              'defaults, and saving would write them to the agent.';
    }
    final values = current is MemReaperConfig
        ? current
        : MemReaperConfig.defaults;
    _threshold = TextEditingController(text: '${values.thresholdMb}');
    _interval = TextEditingController(text: '${values.intervalSeconds}');
    _dialogTimeout = TextEditingController(
      text: '${values.dialogTimeoutSeconds}',
    );
  }

  @override
  void dispose() {
    _threshold.dispose();
    _interval.dispose();
    _dialogTimeout.dispose();
    super.dispose();
  }

  MemReaperConfig get _draft => MemReaperConfig(
    thresholdMb: int.tryParse(_threshold.text.trim()) ?? -1,
    intervalSeconds: int.tryParse(_interval.text.trim()) ?? -1,
    dialogTimeoutSeconds: int.tryParse(_dialogTimeout.text.trim()) ?? -1,
  );

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final draft = _draft;
    if (!draft.isValid) return;
    setState(() => _saving = true);
    final ok = await widget.registry.saveConfig(
      widget.entry.descriptor.id,
      draft,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final draft = _draft;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconBadge(
                  icon: Icons.tune_rounded,
                  color: scheme.primary,
                  size: 38,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'mem_reaper settings',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'These become the agent\'s command line.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_loadError != null) ...[
              const SizedBox(height: 12),
              InlineNote(
                icon: Icons.error_outline,
                text: _loadError!,
                tone: scheme.error,
              ),
            ],
            const SizedBox(height: 6),
            const FieldGroup('Threshold'),
            TextFormField(
              controller: _threshold,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Stop anything over',
                suffixText: 'MB',
                helperText: '1024 MB = 1 GB, 3072 MB = 3 GB',
              ),
              validator: (value) => _validate(
                value,
                MemReaperConfig.minThresholdMb,
                MemReaperConfig.maxThresholdMb,
                'the limit mem_reaper itself refuses to go below',
              ),
            ),
            const FieldGroup('Timing'),
            TextFormField(
              controller: _interval,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Check every',
                suffixText: 'seconds',
              ),
              validator: (value) => _validate(
                value,
                MemReaperConfig.minIntervalSeconds,
                MemReaperConfig.maxIntervalSeconds,
                '5 s at the shortest',
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _dialogTimeout,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Give up on a dialog after',
                suffixText: 'seconds',
                helperText: 'An unanswered dialog never kills anything',
              ),
              validator: (value) => _validate(
                value,
                MemReaperConfig.minDialogTimeoutSeconds,
                MemReaperConfig.maxDialogTimeoutSeconds,
                '5 s at the shortest',
              ),
            ),
            const SizedBox(height: 16),
            InlineNote(
              icon: Icons.save_outlined,
              text:
                  'Save as over ${draft.thresholdLabel}, checking every '
                  '${draft.intervalSeconds}s, dialog timeout '
                  '${draft.dialogTimeoutSeconds}s. The agent reloads.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Save and reload the agent'),
            ),
          ],
        ),
      ),
    );
  }

  static String? _validate(
    String? value,
    int minimum,
    int maximum,
    String floorHint,
  ) {
    final parsed = int.tryParse((value ?? '').trim());
    if (parsed == null) return 'Enter a whole number.';
    if (parsed < minimum || parsed > maximum) {
      return 'Must be between $minimum and $maximum ($floorHint).';
    }
    return null;
  }
}
