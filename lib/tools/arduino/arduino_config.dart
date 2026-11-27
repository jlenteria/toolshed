import '../../models/tool_config.dart';

/// The four settings the Arduino console remembers: which sketch, which board,
/// which port, and the baud rate the serial monitor opens at.
///
/// They are kept in a small JSON file rather than in the Arduino CLI's own
/// config because they are this console's working set, not the toolchain's
/// configuration. Losing the file costs one selection, not a platform install.
class ArduinoConfig extends ToolConfig {
  const ArduinoConfig({
    this.sketchPath = '',
    this.fqbn = '',
    this.port = '',
    this.baud = defaultBaud,
  });

  static const int defaultBaud = 115200;

  /// The rates the Arduino IDE offers by default, plus the fast ones common on
  /// ESP32 and RP2040 boards.
  static const List<int> baudRates = [
    300,
    1200,
    2400,
    4800,
    9600,
    19200,
    38400,
    57600,
    74880,
    115200,
    230400,
    250000,
    500000,
    1000000,
    2000000,
  ];

  final String sketchPath;
  final String fqbn;
  final String port;
  final int baud;

  bool get hasSketch => sketchPath.trim().isNotEmpty;

  bool get hasBoard => fqbn.trim().isNotEmpty;

  bool get hasPort => port.trim().isNotEmpty;

  /// Compiling needs a sketch and a board; the port is only for upload.
  bool get canCompile => hasSketch && hasBoard;

  bool get canUpload => canCompile && hasPort;

  bool get canMonitor => hasPort;

  /// Only the two things that make a compile impossible. A port is deliberately
  /// not required here: choosing a sketch and a board before the board is
  /// plugged in is a legitimate way to work.
  @override
  List<String> get problems => [
    if (!hasSketch) 'Choose a sketch to compile or upload.',
    if (!hasBoard) 'Choose a board so the sketch has a target.',
  ];

  @override
  String get blurb {
    final sketch = hasSketch ? _basename(sketchPath) : 'No sketch';
    final board = hasBoard ? fqbn : 'No board';
    final shownPort = hasPort ? port : 'No port';
    return '$sketch · $board · $shownPort';
  }

  ArduinoConfig copyWith({
    String? sketchPath,
    String? fqbn,
    String? port,
    int? baud,
  }) => ArduinoConfig(
    sketchPath: sketchPath ?? this.sketchPath,
    fqbn: fqbn ?? this.fqbn,
    port: port ?? this.port,
    baud: baud ?? this.baud,
  );

  Map<String, Object?> toJson() => {
    'sketchPath': sketchPath,
    'fqbn': fqbn,
    'port': port,
    'baud': baud,
  };

  factory ArduinoConfig.fromJson(Map<String, dynamic> json) {
    final baud = _int(json['baud']) ?? defaultBaud;
    return ArduinoConfig(
      sketchPath: _string(json['sketchPath']),
      fqbn: _string(json['fqbn']),
      port: _string(json['port']),
      baud: baudRates.contains(baud) ? baud : defaultBaud,
    );
  }

  static String _string(Object? value) => value == null ? '' : '$value';

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final at = trimmed.lastIndexOf('/');
    return at < 0 ? trimmed : trimmed.substring(at + 1);
  }

  @override
  bool operator ==(Object other) =>
      other is ArduinoConfig &&
      other.sketchPath == sketchPath &&
      other.fqbn == fqbn &&
      other.port == port &&
      other.baud == baud;

  @override
  int get hashCode => Object.hash(sketchPath, fqbn, port, baud);

  @override
  String toString() => 'ArduinoConfig($sketchPath, $fqbn, $port, $baud)';
}
