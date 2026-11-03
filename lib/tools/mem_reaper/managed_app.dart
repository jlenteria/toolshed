/// How an app can actually be stopped from here. Carried on the model rather
/// than the widget, so no screen can accidentally present a row it has no way
/// of stopping as a direct kill.
enum KillMode {
  /// Nothing can stop it (Windows/Linux, or a process the OS protects).
  none,

  /// mem_reaper stops it: from its own dialog during a scan, or on a request
  /// from the console once you have confirmed there. Its protection rules
  /// apply either way.
  viaReaper,
}

/// One row in a memory ranking.
class ManagedApp {
  const ManagedApp({
    required this.id,
    required this.name,
    this.liveBytes,
    this.killMode = KillMode.none,
    this.detail,
  });

  /// The pid, kept as text because the id of a ranked row comes from whatever
  /// produced it.
  final String id;
  final String name;

  /// Bytes resident *right now*.
  final int? liveBytes;

  /// The executable path, shown as the row's second line.
  final String? detail;

  final KillMode killMode;

  /// The primary column. A live number, else an explicit "no history" — never
  /// a silent zero.
  String get memoryLabel {
    final live = liveBytes;
    if (live != null) return formatBytes(live);
    return 'no history';
  }

  static String formatBytes(int bytes) {
    const units = <(String, int)>[
      ('TB', 1024 * 1024 * 1024 * 1024),
      ('GB', 1024 * 1024 * 1024),
      ('MB', 1024 * 1024),
      ('KB', 1024),
    ];
    for (final (unit, multiplier) in units) {
      if (bytes >= multiplier) {
        return '${(bytes / multiplier).toStringAsFixed(2)} $unit';
      }
    }
    return '$bytes B';
  }
}
