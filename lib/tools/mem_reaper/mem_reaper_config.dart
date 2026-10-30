import '../../models/tool_config.dart';

/// The three settings the app exposes. Each maps to a flag/value pair inside
/// the agent plist's ProgramArguments array.
class MemReaperConfig implements ToolConfig {
  const MemReaperConfig({
    required this.thresholdMb,
    required this.intervalSeconds,
    required this.dialogTimeoutSeconds,
  });

  /// Mirrors the floor mem_reaper.py enforces itself: a tiny limit would offer to
  /// kill half the session.
  static const int minThresholdMb = 64;
  static const int maxThresholdMb = 65536;
  static const int minIntervalSeconds = 5;
  static const int maxIntervalSeconds = 3600;
  static const int minDialogTimeoutSeconds = 5;
  static const int maxDialogTimeoutSeconds = 600;

  /// The plist flags these settings live in, and mem_reaper.py's own defaults
  /// for the case where a hand-written plist left a flag out.
  static const String thresholdFlag = '--threshold-mb';
  static const String intervalFlag = '--interval';
  static const String dialogTimeoutFlag = '--dialog-timeout';

  static const MemReaperConfig defaults = MemReaperConfig(
    thresholdMb: 1024,
    intervalSeconds: 30,
    dialogTimeoutSeconds: 45,
  );

  final int thresholdMb;
  final int intervalSeconds;
  final int dialogTimeoutSeconds;

  /// The first message the user would see, rather than a snackbar per field.
  @override
  List<String> get problems => [
    if (thresholdMb < minThresholdMb || thresholdMb > maxThresholdMb)
      'Limit must be between $minThresholdMb MB and '
          '${maxThresholdMb ~/ 1024} GB. A very low limit offers to kill '
          'half your session.',
    if (intervalSeconds < minIntervalSeconds ||
        intervalSeconds > maxIntervalSeconds)
      'Check interval must be between $minIntervalSeconds seconds and '
          '${maxIntervalSeconds ~/ 60} minutes.',
    if (dialogTimeoutSeconds < minDialogTimeoutSeconds ||
        dialogTimeoutSeconds > maxDialogTimeoutSeconds)
      'Dialog timeout must be between ${minDialogTimeoutSeconds}s and '
          '${maxDialogTimeoutSeconds ~/ 60} minutes.',
  ];

  @override
  bool get isValid => problems.isEmpty;

  double get thresholdGb => thresholdMb / 1024;

  String get thresholdLabel => thresholdMb >= 1024
      ? '${thresholdGb.toStringAsFixed(2)} GB'
      : '$thresholdMb MB';

  @override
  String get blurb => 'over $thresholdLabel, checked every ${intervalSeconds}s';

  MemReaperConfig copyWith({
    int? thresholdMb,
    int? intervalSeconds,
    int? dialogTimeoutSeconds,
  }) => MemReaperConfig(
    thresholdMb: thresholdMb ?? this.thresholdMb,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    dialogTimeoutSeconds: dialogTimeoutSeconds ?? this.dialogTimeoutSeconds,
  );

  @override
  bool operator ==(Object other) =>
      other is MemReaperConfig &&
      other.thresholdMb == thresholdMb &&
      other.intervalSeconds == intervalSeconds &&
      other.dialogTimeoutSeconds == dialogTimeoutSeconds;

  @override
  int get hashCode =>
      Object.hash(thresholdMb, intervalSeconds, dialogTimeoutSeconds);

  @override
  String toString() =>
      'MemReaperConfig(${thresholdMb}MB, ${intervalSeconds}s, dialog ${dialogTimeoutSeconds}s)';
}
