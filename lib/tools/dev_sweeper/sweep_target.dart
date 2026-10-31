const String kDevSweeperId = 'dev_sweeper';

/// One directory a build tool can regenerate, and what was measured at scan
/// time.
///
/// A target is a whole directory, not a glob: moving it to the Trash is one
/// reversible step, and a half-deleted cache is worse than a full one because
/// the next build has to guess which half.
class SweepTarget {
  const SweepTarget({
    required this.path,
    required this.label,
    required this.ecosystem,
    this.bytes,
  });

  final String path;

  /// What the row is called: the cache's own name, or a project-relative path
  /// for a discovered `node_modules`.
  final String label;

  /// The tool that owns the directory — Xcode, Gradle, Node, Dart, Go…
  final String ecosystem;

  /// Byte count measured by `du` (or PowerShell), or null when the measurement
  /// failed. Null is shown as unknown, never as zero: an unmeasured 20 GB
  /// cache must not look like an empty one.
  final int? bytes;

  String get searchText => '$label $ecosystem $path'.toLowerCase();

  String get sizeLabel => bytes == null ? 'size unknown' : formatBytes(bytes!);

  bool get measurable => (bytes ?? 0) > 0;
}

class SweepReport {
  const SweepReport(this.targets, {this.notes = const <String>[]});

  final List<SweepTarget> targets;

  /// Everything the scan could not read, and every deliberate omission.
  final List<String> notes;

  int get totalBytes =>
      targets.fold(0, (sum, target) => sum + (target.bytes ?? 0));
}

class SweepFailure {
  const SweepFailure({required this.target, required this.message});

  final SweepTarget target;
  final String message;
}

/// What the Trash did, one entry per requested target.
class SweepOutcome {
  const SweepOutcome({
    required this.trashed,
    required this.failures,
    required this.freedBytes,
  });

  final List<SweepTarget> trashed;
  final List<SweepFailure> failures;

  /// Only what was measured and actually moved; a failed move frees nothing.
  final int freedBytes;

  int get requested => trashed.length + failures.length;

  bool get anyMoved => trashed.isNotEmpty;

  String describe() {
    if (trashed.isEmpty) {
      return failures.isEmpty
          ? 'Nothing was moved.'
          : 'Nothing could be moved. ${failures.first.message}';
    }
    final moved =
        'Moved ${trashed.length} ${trashed.length == 1 ? 'item' : 'items'} '
        '(${formatBytes(freedBytes)}) to the Trash.';
    if (failures.isEmpty) return moved;
    return '$moved ${failures.length} of $requested could not be moved.';
  }
}

/// Largest first, so the scan opens on what is worth reclaiming; unknown sizes
/// sort last but stay listed.
int compareSweepTargets(SweepTarget a, SweepTarget b) {
  final bySize = (b.bytes ?? -1).compareTo(a.bytes ?? -1);
  if (bySize != 0) return bySize;
  final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
  if (byLabel != 0) return byLabel;
  return a.path.compareTo(b.path);
}

/// Binary units, because that is what `du -k` and every build tool report.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
