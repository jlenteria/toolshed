import 'dart:convert';

import '../../models/tool_exception.dart';

/// What `mem_reaper.py --stop-pid` said it did with one process.
enum StopResult {
  /// It was asked to quit, then killed if it had to be, and it is gone.
  stopped,

  /// It had already exited before the request arrived.
  gone,

  /// The script refused: a protected name or path, or the console itself.
  protected,

  /// It belongs to another user.
  notYours,

  /// The pid now names a different executable from the one the user picked.
  changed,

  /// The signals were sent but it is still there, or it respawned.
  stillRunning,
}

class StopOutcome {
  const StopOutcome({required this.result, this.name, this.reason});

  final StopResult result;
  final String? name;
  final String? reason;

  /// Whether the process the user picked is no longer running.
  bool get isGone => result == StopResult.stopped || result == StopResult.gone;

  /// The script may log a line before its answer (a permission failure, say),
  /// so the answer is the last line that parses as JSON with a `result`.
  factory StopOutcome.parse(String stdout) {
    for (final line in const LineSplitter().convert(stdout).reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      final result = switch (decoded['result']) {
        'stopped' => StopResult.stopped,
        'gone' => StopResult.gone,
        'protected' => StopResult.protected,
        'not_yours' => StopResult.notYours,
        'changed' => StopResult.changed,
        'still_running' => StopResult.stillRunning,
        _ => null,
      };
      if (result == null) continue;
      return StopOutcome(
        result: result,
        name: decoded['name'] as String?,
        reason: decoded['reason'] as String?,
      );
    }
    throw ToolException(
      'BAD_STOP_REPLY',
      'mem_reaper did not say what happened to the process.',
      detail: 'stdout:\n$stdout',
    );
  }

  /// One sentence for a toast, in the script's own terms.
  String describe(String fallbackName) {
    final who = name ?? fallbackName;
    final why = reason == null ? '' : ': $reason';
    return switch (result) {
      StopResult.stopped => 'Stopped $who.',
      StopResult.gone => '$who had already exited.',
      StopResult.protected => 'mem_reaper will not stop $who$why.',
      StopResult.notYours => 'Not stopped$why.',
      StopResult.changed => 'Not stopped$why.',
      StopResult.stillRunning => '$who is still running$why.',
    };
  }
}
