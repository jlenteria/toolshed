/// How an app can actually be stopped from here. Carried on the model rather
/// than the widget, so no screen can accidentally present a phone row as a
/// direct kill.
enum KillMode {
  /// Nothing can stop it (Windows/Linux, or a process the OS protects).
  none,

  /// mem_reaper stops it: from its own dialog during a scan, or on a request
  /// from the console once you have confirmed there. Its protection rules
  /// apply either way.
  viaReaper,

  /// Android will not let another app stop it; tapping opens the system
  /// App-info page where the user taps Force stop themselves.
  opensAppInfo,
}

/// One row in a memory ranking.
///
/// [liveBytes] and [periodMillis] are deliberately separate and separately
/// formatted. macOS can report a true footprint; a non-rooted phone cannot
/// report any per-app byte figure at all — `UsageStats.totalTimeInForeground`
/// is milliseconds — so the types keep an aggregate from ever being rendered as
/// "GB right now".
class ManagedApp {
  const ManagedApp({
    required this.id,
    required this.name,
    this.liveBytes,
    this.periodMillis,
    this.share,
    this.lastUsedMillis,
    this.launchCount,
    this.killMode = KillMode.none,
    this.detail,
  });

  /// pid on desktop, package name on Android.
  final String id;
  final String name;

  /// Bytes resident *right now*. Only macOS ever sets this.
  final int? liveBytes;

  /// Foreground milliseconds inside the ranking window (Android). A duration,
  /// never a size.
  final int? periodMillis;

  /// 0..1 of the window's total usage, for the percentage bar.
  final double? share;

  /// Epoch millis of the last time in the foreground, or -1 when unknown.
  final int? lastUsedMillis;

  /// Null when the OS does not report it (Android below API 30).
  final int? launchCount;

  /// Path or package name, shown as the row's second line.
  final String? detail;

  final KillMode killMode;

  bool get hasLiveMemory => liveBytes != null;

  /// The primary column. A live number, else a share of the period, else an
  /// explicit "no history" — never a silent zero.
  String get memoryLabel {
    final live = liveBytes;
    if (live != null) return formatBytes(live);
    final part = share;
    if (part != null) return '${(part * 100).toStringAsFixed(1)}%';
    return 'no history';
  }

  /// The secondary column on a phone, where the only real number is time.
  String get periodLabel {
    final millis = periodMillis;
    if (millis == null) return '—';
    return formatDuration(millis);
  }

  /// "4 min ago" style, clamped so a stale value says how stale it is.
  String lastUsedLabel(int nowMillis) {
    final seen = lastUsedMillis;
    if (seen == null || seen <= 0) return 'never recorded';
    return formatAgo(nowMillis - seen);
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

  static String formatDuration(int millis) {
    final minutes = millis ~/ 60000;
    if (minutes < 1) return '${millis ~/ 1000}s';
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h ${minutes % 60}m';
    return '${hours ~/ 24}d ${hours % 24}h';
  }

  static String formatAgo(int millis) {
    if (millis < 0) return 'in the future';
    final minutes = millis ~/ 60000;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return '$hours h ago';
    return '${hours ~/ 24} d ago';
  }
}
